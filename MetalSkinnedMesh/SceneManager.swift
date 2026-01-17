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

// MARK: - Scene

/// Scene wraps camera, game systems, and render systems together
/// Renderer focuses on MTL resource management, Scene handles the game/render logic composition
final class SceneManager {
    private weak var view: MTKView?
    let cameraSystem: CameraSystem
    let lightManager: LightManager
    private(set) var gameSystems: [GameSystem]
    private(set) var renderables: [Renderable]
    
    init(view: MTKView,
         cameraSystem: CameraSystem,
         lightManager: LightManager,
         gameSystems: [GameSystem] = [],
         renderables: [Renderable] = []) {
        self.view = view
        self.cameraSystem = cameraSystem
        self.lightManager = lightManager
        self.gameSystems = gameSystems
        self.renderables = renderables
    }
    
    func addGameSystem(_ system: GameSystem) {
        gameSystems.append(system)
    }
    
    func addRenderable(_ renderable: Renderable) {
        renderables.append(renderable)
    }
    
    /// Convenience: add a system that implements both GameSystem and Renderable
    func addSystem(_ system: GameSystem & Renderable) {
        gameSystems.append(system)
        renderables.append(system)
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
        for renderable in renderables {
            renderable.drawableSizeWillChange(size)
        }
    }
    
    func draw(renderEncoder: MTLRenderCommandEncoder, frameIndex: Int) {
        lightManager.updateFrame(viewMatrix: viewMatrix, frameIndex: frameIndex)
        for renderable in renderables {
            renderable.encodeOpaque(renderEncoder: renderEncoder,
                                    frameIndex: frameIndex,
                                    viewMatrix: viewMatrix,
                                    projectionMatrix: projectionMatrix,
                                    lightManager: lightManager)
        }
        for renderable in renderables {
            renderable.encodeTransparent(renderEncoder: renderEncoder,
                                         frameIndex: frameIndex,
                                         viewMatrix: viewMatrix,
                                         projectionMatrix: projectionMatrix,
                                         lightManager: lightManager)
        }
    }
    
    func encodeShadowPasses(commandBuffer: MTLCommandBuffer, frameIndex: Int) {
        lightManager.encodeShadowPasses(commandBuffer: commandBuffer,
                                        frameIndex: frameIndex,
                                        renderables: renderables)
    }
}
