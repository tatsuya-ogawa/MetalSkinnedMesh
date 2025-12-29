//
//  Scene.swift
//  MetalSkinnedMesh
//
//  Created by Tatsuya Ogawa on 2025/12/29.
//

import Metal
import MetalKit
import simd

// MARK: - Protocols

protocol GameSystem: AnyObject {
    func update(deltaTime: TimeInterval, frameIndex: Int)
}

protocol RenderSystem: AnyObject {
    func draw(renderEncoder: MTLRenderCommandEncoder,
              frameIndex: Int,
              viewMatrix: matrix_float4x4,
              projectionMatrix: matrix_float4x4)
    func drawableSizeWillChange(_ size: CGSize)
}

// MARK: - Scene

/// Scene wraps camera, game systems, and render systems together
/// Renderer focuses on MTL resource management, Scene handles the game/render logic composition
final class SceneManager {
    private weak var view: MTKView?
    let cameraSystem: CameraSystem
    private(set) var gameSystems: [GameSystem]
    private(set) var renderSystems: [RenderSystem]
    
    init(view: MTKView,
         cameraSystem: CameraSystem,
         gameSystems: [GameSystem] = [],
         renderSystems: [RenderSystem] = []) {
        self.view = view
        self.cameraSystem = cameraSystem
        self.gameSystems = gameSystems
        self.renderSystems = renderSystems
    }
    
    func addGameSystem(_ system: GameSystem) {
        gameSystems.append(system)
    }
    
    func addRenderSystem(_ system: RenderSystem) {
        renderSystems.append(system)
    }
    
    /// Convenience: add a system that implements both GameSystem and RenderSystem
    func addSystem(_ system: GameSystem & RenderSystem) {
        gameSystems.append(system)
        renderSystems.append(system)
    }
    
    var viewMatrix: matrix_float4x4 {
        cameraSystem.viewMatrix
    }
    
    var projectionMatrix: matrix_float4x4 {
        cameraSystem.projectionMatrix
    }
    
    // MARK: - Game Loop
    
    func tick(deltaTime: TimeInterval, frameIndex: Int) {
        // Update all systems
        cameraSystem.update(deltaTime: deltaTime, frameIndex: frameIndex)
        for system in gameSystems {
            system.update(deltaTime: deltaTime, frameIndex: frameIndex)
        }
        // Trigger draw
        view?.draw()
    }
    
    // MARK: - Render
    
    func drawableSizeWillChange(_ size: CGSize) {
        cameraSystem.drawableSizeWillChange(size)
        for system in renderSystems {
            system.drawableSizeWillChange(size)
        }
    }
    
    func draw(renderEncoder: MTLRenderCommandEncoder, frameIndex: Int) {
        for system in renderSystems {
            system.draw(renderEncoder: renderEncoder,
                       frameIndex: frameIndex,
                       viewMatrix: viewMatrix,
                       projectionMatrix: projectionMatrix)
        }
    }
}
