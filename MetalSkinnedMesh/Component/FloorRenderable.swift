//
//  FloorRenderable.swift
//  MetalSkinnedMesh
//

import Metal
import MetalKit
import simd

final class FloorRenderable: Renderable {
    private struct FloorVertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
    }

    private let device: MTLDevice
    private let vertexBuffer: MTLBuffer
    private let vertexCount: Int
    private let uniformBuffer: MTLBuffer
    private var uniforms: UnsafeMutablePointer<Uniforms>
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let modelMatrix: matrix_float4x4

    private var currentUniformBufferOffset: Int = 0

    @MainActor
    init?(metalKitView: MTKView, radius: Float) {
        guard let device = metalKitView.device else { return nil }
        self.device = device

        let safeRadius = max(radius, 0.001)
        let halfSize = max(safeRadius * 2.0, 0.5) * 1.5
        let vertices = FloorRenderable.buildVertices(halfSize: halfSize)
        self.vertexCount = vertices.count
        let dataSize = vertices.count * MemoryLayout<FloorVertex>.stride
        guard let buffer = device.makeBuffer(bytes: vertices,
                                             length: dataSize,
                                             options: [.storageModeShared]) else {
            return nil
        }
        self.vertexBuffer = buffer
        self.vertexBuffer.label = "FloorVertexBuffer"

        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight
        guard let uniformBuffer = device.makeBuffer(length: uniformBufferSize,
                                                    options: [.storageModeShared]) else {
            return nil
        }
        self.uniformBuffer = uniformBuffer
        self.uniformBuffer.label = "FloorUniformBuffer"
        self.uniforms = UnsafeMutableRawPointer(uniformBuffer.contents()).bindMemory(to: Uniforms.self, capacity: 1)

        do {
            self.pipelineState = try FloorRenderable.buildPipeline(device: device,
                                                                   metalKitView: metalKitView)
        } catch {
            return nil
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            return nil
        }
        self.depthState = depthState

        self.modelMatrix = matrix4x4_translation(0, -safeRadius, 0)
    }

    func encodeOpaque(renderEncoder: MTLRenderCommandEncoder,
                      frameIndex: Int,
                      viewMatrix: matrix_float4x4,
                      projectionMatrix: matrix_float4x4,
                      lightManager: LightManager) {
        let frame = frameIndex % maxBuffersInFlight
        currentUniformBufferOffset = alignedUniformsSize * frame
        uniforms = UnsafeMutableRawPointer(uniformBuffer.contents() + currentUniformBufferOffset)
            .bindMemory(to: Uniforms.self, capacity: 1)

        uniforms[0].projectionMatrix = projectionMatrix
        uniforms[0].modelViewMatrix = simd_mul(viewMatrix, modelMatrix)
        uniforms[0].modelMatrix = modelMatrix
        lightManager.applyLightUniforms(uniforms)
        uniforms[0].padding0 = SIMD4<Float>(0,
                                            0,
                                            lightManager.shadowStrength,
                                            lightManager.attenuationPower)

        renderEncoder.pushDebugGroup("Draw Floor")
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthState)
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)

        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBuffer(uniformBuffer,
                                      offset: currentUniformBufferOffset,
                                      index: BufferIndex.uniforms.rawValue)
        renderEncoder.setFragmentBuffer(uniformBuffer,
                                        offset: currentUniformBufferOffset,
                                        index: BufferIndex.uniforms.rawValue)
        lightManager.bindLightResources(renderEncoder: renderEncoder)

        renderEncoder.drawPrimitives(type: .triangle,
                                     vertexStart: 0,
                                     vertexCount: vertexCount)
        renderEncoder.popDebugGroup()
    }

    @MainActor
    private static func buildPipeline(device: MTLDevice,
                                      metalKitView: MTKView) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let vertexFunction = library?.makeFunction(name: "floorVertexShader")
        let fragmentFunction = library?.makeFunction(name: "floorFragmentShader")

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<FloorVertex>.stride
        vertexDescriptor.layouts[0].stepRate = 1
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "FloorPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.rasterSampleCount = metalKitView.sampleCount
        pipelineDescriptor.colorAttachments[0].pixelFormat = metalKitView.colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = metalKitView.depthStencilPixelFormat
        pipelineDescriptor.stencilAttachmentPixelFormat = metalKitView.depthStencilPixelFormat

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    private static func buildVertices(halfSize: Float) -> [FloorVertex] {
        let y: Float = 0
        let n = SIMD3<Float>(0, 1, 0)
        let p0 = SIMD3<Float>(-halfSize, y, -halfSize)
        let p1 = SIMD3<Float>(halfSize, y, -halfSize)
        let p2 = SIMD3<Float>(halfSize, y, halfSize)
        let p3 = SIMD3<Float>(-halfSize, y, halfSize)

        return [
            FloorVertex(position: p0, normal: n),
            FloorVertex(position: p2, normal: n),
            FloorVertex(position: p1, normal: n),
            FloorVertex(position: p0, normal: n),
            FloorVertex(position: p3, normal: n),
            FloorVertex(position: p2, normal: n)
        ]
    }
}
