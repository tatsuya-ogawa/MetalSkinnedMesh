//
//  LightSystem.swift
//  MetalSkinnedMesh
//
//  Created by Tatsuya Ogawa on 2025/12/29.
//

import Foundation
import simd

/// Simple light controller with position-based direction and ambient intensity.
final class LightingSystem: NSObject, GameSystem {
    var target = SIMD3<Float>(repeating: 0)
    var lightPosition = SIMD3<Float>(1, 1, 1)
    var lightColor = SIMD3<Float>(1, 1, 1)
    var ambientIntensity: Float = 0.8
    var ambientTint = SIMD3<Float>(repeating: 1)

    func update(deltaTime: TimeInterval, frameIndex: Int) {
        // No-op for now. Hook for future animation or user-driven updates.
    }

    var ambientColor: SIMD3<Float> {
        ambientTint * ambientIntensity
    }

    func lightDirectionInView(viewMatrix: matrix_float4x4) -> SIMD3<Float> {
        let directionWorld = lightDirectionWorld()
        let viewDir4 = simd_mul(viewMatrix, SIMD4<Float>(directionWorld, 0))
        let viewDir = SIMD3<Float>(viewDir4.x, viewDir4.y, viewDir4.z)
        let length = simd_length(viewDir)
        return length > 0.0001 ? viewDir / length : SIMD3<Float>(0, 1, 0)
    }

    private func lightDirectionWorld() -> SIMD3<Float> {
        let dir = target - lightPosition
        let length = simd_length(dir)
        if length > 0.0001 {
            return dir / length
        }
        let fallbackLength = simd_length(lightPosition)
        if fallbackLength > 0.0001 {
            return lightPosition / fallbackLength
        }
        return SIMD3<Float>(0, 1, 0)
    }
}
