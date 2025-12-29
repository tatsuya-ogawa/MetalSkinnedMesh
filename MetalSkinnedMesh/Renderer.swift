//
//  Renderer.swift
//  MetalSkinnedMesh
//
//  Created by Tatsuya Ogawa on 2025/12/28.
//

import Metal
import MetalKit

/// Renderer focuses on MTL resource management (command queue, semaphore, frame sync)
/// Scene composition is delegated to Scene class
final class Renderer: NSObject, MTKViewDelegate {

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let inFlightSemaphore = DispatchSemaphore(value: maxBuffersInFlight)
    private let scene: SceneManager
    private(set) var frameIndex: Int = 0

    init?(metalKitView: MTKView, scene: SceneManager) {
        self.device = metalKitView.device!
        guard let queue = self.device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.scene = scene
        super.init()
    }

    func beginFrame() -> Int {
        _ = inFlightSemaphore.wait(timeout: .distantFuture)
        frameIndex = (frameIndex + 1) % maxBuffersInFlight
        return frameIndex
    }

    func draw(in view: MTKView) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }

        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            commandBuffer.commit()
            return
        }

        renderEncoder.label = "Primary Render Encoder"
        scene.draw(renderEncoder: renderEncoder, frameIndex: frameIndex)
        renderEncoder.endEncoding()

        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        scene.drawableSizeWillChange(size)
    }
}
