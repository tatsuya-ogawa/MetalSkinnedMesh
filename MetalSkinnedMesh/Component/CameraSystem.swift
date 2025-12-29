//
//  CameraSystem.swift
//  MetalSkinnedMesh
//
//  Created by Tatsuya Ogawa on 2025/12/28.
//

import MetalKit
import simd

final class CameraSystem: NSObject, GameSystem, RenderSystem {
    private(set) var projectionMatrix: matrix_float4x4 = matrix_identity_float4x4
    private(set) var viewMatrix: matrix_float4x4 = matrix_identity_float4x4

    private var fovRadians: Float
    private var aspectRatio: Float = 1.0
    private var targetRadius: Float = 1.0
    private var cameraDistance: Float = 8.0
    private var target = SIMD3<Float>(repeating: 0)
    private var yaw: Float = 0
    private var pitch: Float = 0
    private let minPitch: Float = radians_from_degrees(-85)
    private let maxPitch: Float = radians_from_degrees(85)
    private let orbitSensitivity: Float = 0.005

    init(fovDegrees: Float = 65) {
        self.fovRadians = radians_from_degrees(fovDegrees)
        super.init()
        updateViewMatrix()
        updateProjectionMatrix()
    }

    func setTarget(radius: Float) {
        targetRadius = max(radius, 0.001)
        target = SIMD3<Float>(repeating: 0)
        updateViewMatrix()
    }

    func setTarget(center: SIMD3<Float>, radius: Float) {
        targetRadius = max(radius, 0.001)
        target = center
        updateViewMatrix()
    }

    func orbit(deltaX: Float, deltaY: Float) {
        yaw += deltaX * orbitSensitivity
        pitch += deltaY * orbitSensitivity
        pitch = min(max(pitch, minPitch), maxPitch)
        updateViewMatrix()
    }

    func update(deltaTime: TimeInterval, frameIndex: Int) {
        // Camera is static unless target/size changes.
    }

    func draw(renderEncoder: MTLRenderCommandEncoder,
              frameIndex: Int,
              viewMatrix: matrix_float4x4,
              projectionMatrix: matrix_float4x4) {
        // Camera system does not render geometry.
    }

    func drawableSizeWillChange(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        aspectRatio = Float(size.width) / Float(size.height)
        updateProjectionMatrix()
    }

    private func updateViewMatrix() {
        cameraDistance = max(targetRadius / tan(fovRadians * 0.5) * 1.5, targetRadius * 2.5)
        let x = cos(pitch) * sin(yaw) * cameraDistance
        let y = sin(pitch) * cameraDistance
        let z = cos(pitch) * cos(yaw) * cameraDistance
        let eye = target + SIMD3<Float>(x, y, z)
        viewMatrix = matrix_look_at(eye: eye, center: target, up: SIMD3<Float>(0, 1, 0))
    }

    private func updateProjectionMatrix() {
        projectionMatrix = matrix_perspective_right_hand(fovyRadians: fovRadians,
                                                         aspectRatio: aspectRatio,
                                                         nearZ: 0.1,
                                                         farZ: 1000.0)
    }
}

private func matrix_look_at(eye: SIMD3<Float>,
                            center: SIMD3<Float>,
                            up: SIMD3<Float>) -> matrix_float4x4 {
    let zAxis = normalize(eye - center)
    let xAxis = normalize(cross(up, zAxis))
    let yAxis = cross(zAxis, xAxis)

    let translation = SIMD3<Float>(
        -dot(xAxis, eye),
        -dot(yAxis, eye),
        -dot(zAxis, eye)
    )

    return matrix_float4x4(columns: (
        SIMD4<Float>(xAxis.x, yAxis.x, zAxis.x, 0),
        SIMD4<Float>(xAxis.y, yAxis.y, zAxis.y, 0),
        SIMD4<Float>(xAxis.z, yAxis.z, zAxis.z, 0),
        SIMD4<Float>(translation.x, translation.y, translation.z, 1)
    ))
}
