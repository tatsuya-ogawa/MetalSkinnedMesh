//
//  Renderable.swift
//  MetalSkinnedMesh
//

import Metal
import MetalKit
import simd

protocol Renderable: AnyObject {
    func encodeShadow(renderEncoder: MTLRenderCommandEncoder,
                      frameIndex: Int,
                      shadowMatrix: matrix_float4x4)
    func encodeOpaque(renderEncoder: MTLRenderCommandEncoder,
                      frameIndex: Int,
                      viewMatrix: matrix_float4x4,
                      projectionMatrix: matrix_float4x4,
                      lightManager: LightManager)
    func encodeTransparent(renderEncoder: MTLRenderCommandEncoder,
                           frameIndex: Int,
                           viewMatrix: matrix_float4x4,
                           projectionMatrix: matrix_float4x4,
                           lightManager: LightManager)
    func drawableSizeWillChange(_ size: CGSize)
}

extension Renderable {
    func encodeShadow(renderEncoder: MTLRenderCommandEncoder,
                      frameIndex: Int,
                      shadowMatrix: matrix_float4x4) {
        // Default: no shadow casting.
    }

    func encodeOpaque(renderEncoder: MTLRenderCommandEncoder,
                      frameIndex: Int,
                      viewMatrix: matrix_float4x4,
                      projectionMatrix: matrix_float4x4,
                      lightManager: LightManager) {
        // Default: no opaque rendering.
    }

    func encodeTransparent(renderEncoder: MTLRenderCommandEncoder,
                           frameIndex: Int,
                           viewMatrix: matrix_float4x4,
                           projectionMatrix: matrix_float4x4,
                           lightManager: LightManager) {
        // Default: no transparent rendering.
    }

    func drawableSizeWillChange(_ size: CGSize) {
        // Default: no-op.
    }
}
