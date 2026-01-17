//
//  LightManager.swift
//  MetalSkinnedMesh
//

import Metal
import MetalKit
import simd

final class LightManager {
    private let device: MTLDevice
    private let lightingSystem: LightingSystem
    private let maxLights: Int
    private let shadowMapSize: Int
    private let lightDataStride: Int
    
    private let lightDataBuffer: MTLBuffer
    private var currentLightBufferOffset: Int = 0
    private var lightDataPointer: UnsafeMutablePointer<LightData>!
    
    private var shadowMapTexture: MTLTexture
    private var shadowMatrices: [matrix_float4x4]
    
    private let shadowBias: Float = 0.00015
    private let shadowSlopeScale: Float = 0.5
    
    private var currentLightCount: Int = 0
    var shadowStrength: Float { lightingSystem.shadowStrength }
    var attenuationPower: Float { lightingSystem.attenuationPower }
    
    @MainActor
    init?(metalKitView: MTKView,
          lightingSystem: LightingSystem,
          shadowMapSize: Int = 1024) {
        self.device = metalKitView.device!
        self.lightingSystem = lightingSystem
        self.maxLights = lightingSystem.maxLights
        self.shadowMapSize = shadowMapSize
        self.lightDataStride = MemoryLayout<LightData>.stride
        self.shadowMatrices = Array(repeating: matrix_identity_float4x4, count: maxLights)
        
        let lightBufferLength = lightDataStride * maxLights * maxBuffersInFlight
        guard let lightBuffer = device.makeBuffer(length: lightBufferLength, options: [.storageModeShared]) else {
            return nil
        }
        lightDataBuffer = lightBuffer
        lightDataBuffer.label = "LightDataBuffer"
        
        guard let shadowTexture = LightManager.makeShadowMapTexture(device: device,
                                                                    size: shadowMapSize,
                                                                    arrayLength: maxLights) else {
            return nil
        }
        shadowMapTexture = shadowTexture
        shadowMapTexture.label = "ShadowMapArray"
    }
    
    func updateFrame(viewMatrix: matrix_float4x4, frameIndex: Int) {
        let desiredCount = min(lightingSystem.lights.count, lightingSystem.activeLightCount)
        let lightCount = min(desiredCount, maxLights)
        currentLightCount = lightCount
        
        currentLightBufferOffset = lightDataStride * maxLights * (frameIndex % maxBuffersInFlight)
        lightDataPointer = UnsafeMutableRawPointer(lightDataBuffer.contents() + currentLightBufferOffset)
            .bindMemory(to: LightData.self, capacity: maxLights)
        
        updateShadowMatrices(lightCount: lightCount)
        
        for i in 0..<maxLights {
            if i < lightCount {
                let light = lightingSystem.lights[i]
                let viewPos4 = simd_mul(viewMatrix, SIMD4<Float>(light.position, 1))
                let viewDir4 = simd_mul(viewMatrix, SIMD4<Float>(light.direction, 0))
                let viewDir = normalize(SIMD3<Float>(viewDir4.x, viewDir4.y, viewDir4.z))
                
                let outerCos = cos(light.outerConeAngle)
                let innerCos = cos(light.innerConeAngle)
                let shadowEnabled: Float = (light.castsShadow && lightingSystem.shadowEnabled) ? 1.0 : 0.0
                let shadowParams = SIMD4<Float>(shadowEnabled,
                                                shadowBias,
                                                shadowSlopeScale,
                                                1.0 / Float(shadowMapSize))
                let shadowMatrix = shadowMatrices[i]
                
                lightDataPointer[i] = LightData(position: SIMD4<Float>(viewPos4.x, viewPos4.y, viewPos4.z, light.intensity),
                                                direction: SIMD4<Float>(viewDir.x, viewDir.y, viewDir.z, outerCos),
                                                color: SIMD4<Float>(light.color.x, light.color.y, light.color.z, innerCos),
                                                shadowParams: shadowParams,
                                                shadowMatrix: shadowMatrix)
            } else {
                lightDataPointer[i] = .zero
            }
        }
    }
    
    func applyLightUniforms(_ uniforms: UnsafeMutablePointer<Uniforms>) {
        uniforms[0].ambientColor = SIMD4<Float>(lightingSystem.ambientColor, 1.0)
        uniforms[0].lightCount = UInt32(currentLightCount)
    }
    
    func bindLightResources(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setFragmentBuffer(lightDataBuffer,
                                        offset: currentLightBufferOffset,
                                        index: BufferIndex.lights.rawValue)
        if lightingSystem.shadowEnabled {
            renderEncoder.setFragmentTexture(shadowMapTexture, index: TextureIndex.shadowMap.rawValue)
        } else {
            renderEncoder.setFragmentTexture(nil, index: TextureIndex.shadowMap.rawValue)
        }
    }
    
    func encodeShadowPasses(commandBuffer: MTLCommandBuffer,
                            frameIndex: Int,
                            renderables: [Renderable]) {
        guard lightingSystem.shadowEnabled else { return }
        
        let desiredCount = min(lightingSystem.lights.count, lightingSystem.activeLightCount)
        let lightCount = min(desiredCount, maxLights)
        guard lightCount > 0 else { return }
        
        updateShadowMatrices(lightCount: lightCount)
        
        let viewport = MTLViewport(originX: 0,
                                   originY: 0,
                                   width: Double(shadowMapSize),
                                   height: Double(shadowMapSize),
                                   znear: 0.0,
                                   zfar: 1.0)
        
        for i in 0..<lightCount {
            let light = lightingSystem.lights[i]
            guard light.castsShadow else { continue }
            guard let descriptor = makeShadowRenderPassDescriptor(slice: i),
                  let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                continue
            }
            renderEncoder.label = "Shadow Pass \(i)"
            renderEncoder.setViewport(viewport)
            renderEncoder.setDepthBias(shadowBias, slopeScale: shadowSlopeScale, clamp: 0)
            
            for renderable in renderables {
                renderable.encodeShadow(renderEncoder: renderEncoder,
                                        frameIndex: frameIndex,
                                        shadowMatrix: shadowMatrices[i])
            }
            renderEncoder.endEncoding()
        }
    }
    
    private func updateShadowMatrices(lightCount: Int) {
        if shadowMatrices.count != maxLights {
            shadowMatrices = Array(repeating: matrix_identity_float4x4, count: maxLights)
        }
        for i in 0..<lightCount {
            let light = lightingSystem.lights[i]
            shadowMatrices[i] = makeLightViewProjectionMatrix(light: light)
        }
    }
    
    private func makeShadowRenderPassDescriptor(slice: Int) -> MTLRenderPassDescriptor? {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.depthAttachment.texture = shadowMapTexture
        descriptor.depthAttachment.slice = slice
        descriptor.depthAttachment.level = 0
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.storeAction = .store
        descriptor.depthAttachment.clearDepth = 1.0
        return descriptor
    }
    
    private func makeLightViewProjectionMatrix(light: LightingSystem.SpotLight) -> matrix_float4x4 {
        let rawDirection = light.direction
        let direction = simd_length(rawDirection) > 0.0001 ? normalize(rawDirection) : SIMD3<Float>(0, -1, 0)
        let center = light.target
        let fov = light.outerConeAngle * 2.0
        let nearZ = light.shadowNear
        let farZ = light.shadowFar
        let up: SIMD3<Float>
        if abs(simd_dot(direction, SIMD3<Float>(0, 1, 0))) > 0.99 {
            up = SIMD3<Float>(0, 0, 1)
        } else {
            up = SIMD3<Float>(0, 1, 0)
        }
        let view = matrix_look_at(eye: light.position,
                                  center: center,
                                  up: up)
        let projection = matrix_perspective_right_hand(fovyRadians: fov,
                                                       aspectRatio: 1.0,
                                                       nearZ: nearZ,
                                                       farZ: farZ)
        return simd_mul(projection, view)
    }
    
    private static func makeShadowMapTexture(device: MTLDevice,
                                             size: Int,
                                             arrayLength: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                  width: size,
                                                                  height: size,
                                                                  mipmapped: false)
        descriptor.textureType = .type2DArray
        descriptor.arrayLength = max(arrayLength, 1)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }
}
