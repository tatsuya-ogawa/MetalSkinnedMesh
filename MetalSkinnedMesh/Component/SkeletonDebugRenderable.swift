//
//  SkeletonDebugRenderable.swift
//  MetalSkinnedMesh
//

import Metal
import MetalKit
import simd

final class SkeletonDebugRenderable: Renderable {
    private struct BoneLineVertex {
        var position: SIMD3<Float>
        var color: SIMD4<Float>
    }

    private weak var modelSystem: ModelAnimationSystem?
    private let device: MTLDevice
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var vertexBuffer: MTLBuffer?
    private var vertexCapacity: Int = 0
    private var vertexCount: Int = 0

    var isEnabled: Bool = false
    var lineAlpha: Float = 0.9

    @MainActor
    init?(metalKitView: MTKView, modelSystem: ModelAnimationSystem) {
        guard let device = metalKitView.device else { return nil }
        self.device = device
        self.modelSystem = modelSystem

        do {
            self.pipelineState = try SkeletonDebugRenderable.buildPipeline(device: device,
                                                                           metalKitView: metalKitView)
        } catch {
            return nil
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = false
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            return nil
        }
        self.depthState = depthState
    }

    func encodeTransparent(renderEncoder: MTLRenderCommandEncoder,
                           frameIndex: Int,
                           viewMatrix: matrix_float4x4,
                           projectionMatrix: matrix_float4x4,
                           lightManager: LightManager) {
        guard isEnabled, let modelSystem = modelSystem else { return }
        let globals = modelSystem.currentGlobalTransforms
        let parents = modelSystem.jointParentIndices
        let visibility = modelSystem.jointVisibility
        guard !globals.isEmpty, globals.count == parents.count else { return }
        guard visibility.count == globals.count else { return }

        var vertices: [BoneLineVertex] = []
        vertices.reserveCapacity(globals.count * 2)

        let colors = modelSystem.skeletonBoneColors
        let skeletonToMesh = modelSystem.skeletonToMeshTransform
        let fallbackColor = SIMD4<Float>(0.6, 0.6, 0.6, lineAlpha)

        for i in 0..<globals.count {
            let parentIndex = parents[i]
            if parentIndex < 0 || parentIndex >= globals.count { continue }
            if !visibility[i] || !visibility[parentIndex] {
                continue
            }
            let parentPos = meshPosition(from: globals[parentIndex],
                                         skeletonToMesh: skeletonToMesh)
            let childPos = meshPosition(from: globals[i],
                                        skeletonToMesh: skeletonToMesh)
            var color = i < colors.count ? colors[i] : fallbackColor
            color.w = lineAlpha
            vertices.append(BoneLineVertex(position: parentPos, color: color))
            vertices.append(BoneLineVertex(position: childPos, color: color))
        }

        updateVertexBuffer(vertices)
        guard vertexCount > 0, let vertexBuffer = vertexBuffer else { return }

        let modelMatrix = modelSystem.modelMatrix
        var uniforms = Uniforms(projectionMatrix: projectionMatrix,
                                modelViewMatrix: simd_mul(viewMatrix, modelMatrix),
                                modelMatrix: modelMatrix,
                                ambientColor: SIMD4<Float>(repeating: 0),
                                lightCount: 0,
                                padding0: SIMD4<Float>(repeating: 0))

        renderEncoder.pushDebugGroup("Draw Skeleton")
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthState)
        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setVertexBytes(&uniforms,
                                     length: MemoryLayout<Uniforms>.stride,
                                     index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertexCount)
        renderEncoder.popDebugGroup()
    }

    private func updateVertexBuffer(_ vertices: [BoneLineVertex]) {
        vertexCount = vertices.count
        guard vertexCount > 0 else { return }

        if vertexCount > vertexCapacity {
            vertexCapacity = max(vertexCount, vertexCapacity * 2, 64)
            let length = vertexCapacity * MemoryLayout<BoneLineVertex>.stride
            vertexBuffer = device.makeBuffer(length: length, options: [.storageModeShared])
            vertexBuffer?.label = "BoneLineVertexBuffer"
        }

        guard let buffer = vertexBuffer else { return }
        let byteCount = vertexCount * MemoryLayout<BoneLineVertex>.stride
        vertices.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                buffer.contents().copyMemory(from: base, byteCount: byteCount)
            }
        }
    }

    private func meshPosition(from transform: matrix_float4x4,
                              skeletonToMesh: matrix_float4x4) -> SIMD3<Float> {
        let origin = SIMD4<Float>(0, 0, 0, 1)
        let meshSpace = simd_mul(skeletonToMesh, simd_mul(transform, origin))
        return SIMD3<Float>(meshSpace.x, meshSpace.y, meshSpace.z)
    }

    @MainActor
    private static func buildPipeline(device: MTLDevice,
                                      metalKitView: MTKView) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let vertexFunction = library?.makeFunction(name: "boneLineVertexShader")
        let fragmentFunction = library?.makeFunction(name: "boneLineFragmentShader")

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float4
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<BoneLineVertex>.stride
        vertexDescriptor.layouts[0].stepRate = 1
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "SkeletonLinePipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.rasterSampleCount = metalKitView.sampleCount
        pipelineDescriptor.colorAttachments[0].pixelFormat = metalKitView.colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = metalKitView.depthStencilPixelFormat
        pipelineDescriptor.stencilAttachmentPixelFormat = metalKitView.depthStencilPixelFormat

        let colorAttachment = pipelineDescriptor.colorAttachments[0]
        colorAttachment?.isBlendingEnabled = true
        colorAttachment?.rgbBlendOperation = .add
        colorAttachment?.alphaBlendOperation = .add
        colorAttachment?.sourceRGBBlendFactor = .sourceAlpha
        colorAttachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colorAttachment?.sourceAlphaBlendFactor = .sourceAlpha
        colorAttachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
}
