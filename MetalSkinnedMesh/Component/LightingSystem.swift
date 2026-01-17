//
//  LightSystem.swift
//  MetalSkinnedMesh
//
//  Created by Tatsuya Ogawa on 2025/12/29.
//

import Foundation
import simd

final class LightingSystem: NSObject, GameSystem {
    struct SpotLight {
        var position: SIMD3<Float>
        var target: SIMD3<Float>
        var color: SIMD3<Float>
        var intensity: Float
        var innerConeAngle: Float
        var outerConeAngle: Float
        var shadowNear: Float
        var shadowFar: Float
        var castsShadow: Bool
        var castsVolume: Bool

        var direction: SIMD3<Float> {
            let dir = target - position
            let length = simd_length(dir)
            if length > 0.0001 {
                return dir / length
            }
            return SIMD3<Float>(0, -1, 0)
        }
    }

    // Keep in sync with MaxLights in ShaderTypes.h
    let maxLights: Int = 16

    private var _activeLightCount: Int = 4
    var activeLightCount: Int {
        get { _activeLightCount }
        set { _activeLightCount = max(0, min(newValue, maxLights)) }
    }

    var lights: [SpotLight] = []
    var shadowEnabled: Bool = true
    var orbitEnabled: Bool = false
    var orbitAffectsPrimary: Bool = true
    var orbitSpeedScale: Float = 1.0

    var target = SIMD3<Float>(repeating: 0) { didSet { syncPrimaryLight() } }
    var lightPosition = SIMD3<Float>(1, 1, 1) { didSet { syncPrimaryLight() } }
    var lightColor = SIMD3<Float>(1, 1, 1) { didSet { syncPrimaryLight() } }
    var lightIntensity: Float = 1.0 { didSet { syncPrimaryLight() } }
    var innerConeAngle: Float = radians_from_degrees(12) { didSet { syncPrimaryLight() } }
    var outerConeAngle: Float = radians_from_degrees(20) { didSet { syncPrimaryLight() } }
    var shadowNear: Float = 90.0 { didSet { syncPrimaryLight() } }
    var shadowFar: Float = 50.0 { didSet { syncPrimaryLight() } }
    var primaryCastsShadow: Bool = true { didSet { syncPrimaryLight() } }
    var primaryCastsVolume: Bool = true { didSet { syncPrimaryLight() } }

    var ambientIntensity: Float = 0.5
    var attenuationPower: Float = 2.0
    var ambientTint = SIMD3<Float>(repeating: 1)
    private var _shadowStrength: Float = 1.0
    var shadowStrength: Float {
        get { _shadowStrength }
        set { _shadowStrength = max(0.0, min(newValue, 1.0)) }
    }

    private struct OrbitState {
        var angle: Float
        var angularVelocity: Float
        var radius: Float
        var height: Float
        var phase: Float
    }

    private var orbitStates: [OrbitState] = []
    private var orbitCenter = SIMD3<Float>(repeating: 0)
    private var orbitBaseRadius: Float = 1.0

    override init() {
        super.init()
        syncPrimaryLight()
    }

    func update(deltaTime: TimeInterval, frameIndex: Int) {
        guard orbitEnabled else { return }
        let dt = Float(min(deltaTime, 0.1))
        let activeCount = min(lights.count, activeLightCount)
        guard activeCount > 0 else { return }

        if orbitStates.count != lights.count {
            configureRandomOrbits(center: orbitCenter, radius: orbitBaseRadius)
        }

        let startIndex = orbitAffectsPrimary ? 0 : min(1, activeCount)
        if startIndex >= activeCount { return }

        let twoPi = Float.pi * 2.0
        for i in startIndex..<activeCount {
            var state = orbitStates[i]
            state.angle = fmod(state.angle + state.angularVelocity * dt * orbitSpeedScale, twoPi)
            orbitStates[i] = state

            let x = cosf(state.angle) * state.radius
            let z = sinf(state.angle) * state.radius
            let y = state.height + sinf(state.angle + state.phase) * state.height * 0.15

            lights[i].position = orbitCenter + SIMD3<Float>(x, y, z)
            lights[i].target = orbitCenter
        }
    }

    var ambientColor: SIMD3<Float> {
        ambientTint * ambientIntensity
    }

    func ensureDefaultFillLight(center: SIMD3<Float>, radius: Float) {
        syncPrimaryLight()
        guard lights.count < maxLights, lights.count < 2 else { return }
        let offset = max(radius, 0.001)
        let fill = SpotLight(position: center + SIMD3<Float>(-offset, offset * 0.6, -offset),
                             target: center,
                             color: SIMD3<Float>(0.6, 0.7, 1.0),
                             intensity: 0.35,
                             innerConeAngle: radians_from_degrees(14),
                             outerConeAngle: radians_from_degrees(24),
                             shadowNear: 0.1,
                             shadowFar: max(offset * 6.0, 10.0),
                             castsShadow: false,
                             castsVolume: false)
        lights.append(fill)
    }

    func configureRandomOrbits(center: SIMD3<Float>, radius: Float) {
        orbitCenter = center
        orbitBaseRadius = max(radius, 0.001)
        orbitStates = []
        orbitStates.reserveCapacity(lights.count)

        for _ in lights.indices {
            let r = orbitBaseRadius * Float.random(in: 0.7...1.3)
            let height = orbitBaseRadius * Float.random(in: 0.3...1.1)
            let speed = Float.random(in: 0.4...1.2) * (Bool.random() ? 1.0 : -1.0)
            let angle = Float.random(in: 0.0...(Float.pi * 2.0))
            let phase = Float.random(in: 0.0...(Float.pi * 2.0))
            orbitStates.append(OrbitState(angle: angle,
                                          angularVelocity: speed,
                                          radius: r,
                                          height: height,
                                          phase: phase))
        }
    }

    private func syncPrimaryLight() {
        let inner = min(innerConeAngle, outerConeAngle)
        let outer = max(innerConeAngle, outerConeAngle)
        let primary = SpotLight(position: lightPosition,
                                target: target,
                                color: lightColor,
                                intensity: lightIntensity,
                                innerConeAngle: inner,
                                outerConeAngle: outer,
                                shadowNear: shadowNear,
                                shadowFar: shadowFar,
                                castsShadow: primaryCastsShadow,
                                castsVolume: primaryCastsVolume)
        if lights.isEmpty {
            lights = [primary]
        } else {
            lights[0] = primary
        }
    }
}
