//
//  VolumetricLightSystem.swift
//  MetalSkinnedMesh
//

import Metal
import MetalKit
import simd

final class VolumetricLightSystem: NSObject, Renderable {
    private struct VolumeVertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
    }

    private struct VolumeUniforms {
        var projectionMatrix: matrix_float4x4
        var modelViewMatrix: matrix_float4x4
        var color: SIMD4<Float>
        var params: SIMD4<Float>
    }

    private let device: MTLDevice
    private let lightSystem: LightingSystem
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let vertexBuffer: MTLBuffer
    private let vertexCount: Int

    var isEnabled: Bool = true
    var alpha: Float = 0.28
    var intensityScale: Float = 1.0
    var edgeSoftness: Float = 1.0

    @MainActor
    init?(metalKitView: MTKView, lightSystem: LightingSystem, radialSegments: Int = 32) {
        self.device = metalKitView.device!
        self.lightSystem = lightSystem

        guard let (buffer, count) = VolumetricLightSystem.buildConeMesh(device: device,
                                                                         radialSegments: radialSegments) else {
            return nil
        }
        self.vertexBuffer = buffer
        self.vertexCount = count

        do {
            self.pipelineState = try VolumetricLightSystem.buildPipeline(device: device,
                                                                         metalKitView: metalKitView)
        } catch {
            return nil
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .lessEqual
        depthDescriptor.isDepthWriteEnabled = false
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            return nil
        }
        self.depthState = depthState

        super.init()
    }

    func encodeTransparent(renderEncoder: MTLRenderCommandEncoder,
                           frameIndex: Int,
                           viewMatrix: matrix_float4x4,
                           projectionMatrix: matrix_float4x4,
                           lightManager: LightManager) {
        guard isEnabled else { return }

        renderEncoder.pushDebugGroup("Volumetric Lights")
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthState)
        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        let activeCount = min(lightSystem.activeLightCount, lightSystem.lights.count)
        if activeCount == 0 {
            renderEncoder.popDebugGroup()
            return
        }

        for index in 0..<activeCount {
            let light = lightSystem.lights[index]
            if !light.castsVolume {
                continue
            }
            let length = max(light.shadowFar, 0.1)
            let radius = max(tanf(light.outerConeAngle) * length, 0.01)
            let modelMatrix = makeConeModelMatrix(position: light.position,
                                                  direction: light.direction,
                                                  length: length,
                                                  radius: radius)
            var uniforms = VolumeUniforms(projectionMatrix: projectionMatrix,
                                          modelViewMatrix: simd_mul(viewMatrix, modelMatrix),
                                          color: SIMD4<Float>(light.color, light.intensity * intensityScale),
                                          params: SIMD4<Float>(length, radius, edgeSoftness, alpha))
            renderEncoder.setVertexBytes(&uniforms,
                                         length: MemoryLayout<VolumeUniforms>.stride,
                                         index: BufferIndex.volumeUniforms.rawValue)
            renderEncoder.setFragmentBytes(&uniforms,
                                           length: MemoryLayout<VolumeUniforms>.stride,
                                           index: BufferIndex.volumeUniforms.rawValue)
            renderEncoder.drawPrimitives(type: .triangle,
                                         vertexStart: 0,
                                         vertexCount: vertexCount)
        }

        renderEncoder.popDebugGroup()
    }

    func drawableSizeWillChange(_ size: CGSize) {
        // No-op for now.
    }

    @MainActor
    private static func buildPipeline(device: MTLDevice,
                                      metalKitView: MTKView) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let vertexFunction = library?.makeFunction(name: "volumeVertexShader")
        let fragmentFunction = library?.makeFunction(name: "volumeFragmentShader")

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<VolumeVertex>.stride
        vertexDescriptor.layouts[0].stepRate = 1
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "VolumetricLightPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = metalKitView.colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = metalKitView.depthStencilPixelFormat
        pipelineDescriptor.stencilAttachmentPixelFormat = metalKitView.depthStencilPixelFormat

        let colorAttachment = pipelineDescriptor.colorAttachments[0]
        colorAttachment?.isBlendingEnabled = true
        colorAttachment?.rgbBlendOperation = .add
        colorAttachment?.alphaBlendOperation = .add
        colorAttachment?.sourceRGBBlendFactor = .sourceAlpha
        colorAttachment?.destinationRGBBlendFactor = .one
        colorAttachment?.sourceAlphaBlendFactor = .one
        colorAttachment?.destinationAlphaBlendFactor = .one

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    private static func buildConeMesh(device: MTLDevice,
                                      radialSegments: Int) -> (MTLBuffer, Int)? {
        let segments = max(radialSegments, 3)
        var vertices: [VolumeVertex] = []
        vertices.reserveCapacity(segments * 3)

        let apex = SIMD3<Float>(0, 0, 0)
        for i in 0..<segments {
            let a0 = Float(i) / Float(segments) * (Float.pi * 2.0)
            let a1 = Float(i + 1) / Float(segments) * (Float.pi * 2.0)
            let x0 = cosf(a0)
            let y0 = sinf(a0)
            let x1 = cosf(a1)
            let y1 = sinf(a1)

            let p0 = SIMD3<Float>(x0, y0, 1.0)
            let p1 = SIMD3<Float>(x1, y1, 1.0)

            let n0 = normalize(SIMD3<Float>(x0, y0, -1.0))
            let n1 = normalize(SIMD3<Float>(x1, y1, -1.0))
            let na = normalize(n0 + n1)

            vertices.append(VolumeVertex(position: apex, normal: na))
            vertices.append(VolumeVertex(position: p0, normal: n0))
            vertices.append(VolumeVertex(position: p1, normal: n1))
        }

        let dataSize = vertices.count * MemoryLayout<VolumeVertex>.stride
        guard let buffer = device.makeBuffer(bytes: vertices,
                                             length: dataSize,
                                             options: [.storageModeShared]) else {
            return nil
        }
        buffer.label = "VolumetricConeMesh"
        return (buffer, vertices.count)
    }

    private func makeConeModelMatrix(position: SIMD3<Float>,
                                     direction: SIMD3<Float>,
                                     length: Float,
                                     radius: Float) -> matrix_float4x4 {
        let zAxis = SIMD3<Float>(0, 0, 1)
        let dir = normalize(direction)
        let dotValue = max(-1.0, min(1.0, dot(zAxis, dir)))
        let angle = acosf(dotValue)
        let axis = cross(zAxis, dir)

        let rotation: matrix_float4x4
        if angle < 0.0001 {
            rotation = matrix_identity_float4x4
        } else if simd_length(axis) < 0.0001 {
            rotation = matrix4x4_rotation(radians: Float.pi, axis: SIMD3<Float>(0, 1, 0))
        } else {
            rotation = matrix4x4_rotation(radians: angle, axis: normalize(axis))
        }

        let scale = matrix_float4x4(diagonal: SIMD4<Float>(radius, radius, length, 1))
        let translation = matrix4x4_translation(position.x, position.y, position.z)
        return simd_mul(translation, simd_mul(rotation, scale))
    }
}
