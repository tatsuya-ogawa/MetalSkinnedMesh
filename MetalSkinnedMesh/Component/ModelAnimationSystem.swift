//
//  ModelAnimationSystem.swift
//  MetalSkinnedMesh
//
//  Created by Tatsuya Ogawa on 2025/12/28.
//

import Metal
import MetalKit
import ModelIO
import simd

let alignedUniformsSize = (MemoryLayout<Uniforms>.size + 0xFF) & -0x100
let maxBuffersInFlight = 3

enum RendererError: Error {
    case badVertexDescriptor
    case meshNotFound
}

// Submesh with its texture
private struct MaterialTextures {
    let baseColor: MTLTexture
    let normal: MTLTexture
    let metallic: MTLTexture
    let roughness: MTLTexture
    let ambientOcclusion: MTLTexture
    let emissive: MTLTexture
    let opacity: MTLTexture
}

private struct SubmeshData {
    let submesh: MTKSubmesh
    let textures: MaterialTextures
    let isTransparent: Bool
}

private struct MeshSkinning {
    let jointPaths: [String]
    let jointMatricesBuffers: [MTLBuffer]
    let geometryBindTransform: matrix_float4x4
    let geometryBindTransformInverse: matrix_float4x4
    var jointToSkeletonIndex: [Int]
}

// Mesh with all its submeshes
private struct MeshData {
    let mtkMesh: MTKMesh
    let submeshes: [SubmeshData]
    var skinning: MeshSkinning?
}

private struct AssetLoadResult {
    let meshes: [MeshData]
    let bindComponent: MDLAnimationBindComponent?
    let skeleton: MDLSkeleton?
    let packedAnimation: MDLPackedJointAnimation?
    let assetStartTime: TimeInterval
    let assetEndTime: TimeInterval
    let boundsCenter: SIMD3<Float>
    let boundsRadius: Float
}

final class ModelAnimationSystem: NSObject, GameSystem, RenderSystem {
    
    public let device: MTLDevice
    var dynamicUniformBuffer: MTLBuffer
    var pipelineState: MTLRenderPipelineState
    var transparentPipelineState: MTLRenderPipelineState
    var depthState: MTLDepthStencilState
    var transparentDepthState: MTLDepthStencilState
    fileprivate var defaultMaterialTextures: MaterialTextures
    var defaultJointMatricesBuffer: MTLBuffer
    
    private var currentUniformBufferOffset = 0
    private var currentFrameIndex = 0
    var uniforms: UnsafeMutablePointer<Uniforms>
    
    var rotation: Float = 0
    private(set) var modelMatrix: matrix_float4x4 = matrix_identity_float4x4
    
    // All meshes from the USDZ
    fileprivate var meshes: [MeshData] = []
    private(set) var meshCenter = SIMD3<Float>(repeating: 0)
    private(set) var meshRadius: Float = 1
    
    /// Called when asset loading is complete with initial camera setup info
    var onLoadCompleted: ((_ meshRadius: Float) -> Void)?
    
    // Skinning data
    var animationBindComponent: MDLAnimationBindComponent?
    var skeleton: MDLSkeleton?
    var animation: MDLPackedJointAnimation?
    var animJointToSkeletonIndex: [Int] = []
    var previousAnimationRotations: [simd_quatf] = []
    var jointParentIndices: [Int] = []
    var restTransforms: [matrix_float4x4] = []
    var inverseBindTransforms: [matrix_float4x4] = []
    var assetStartTime: TimeInterval = 0
    var assetEndTime: TimeInterval = 0
    private(set) var isAutoAnimation = true
    var manualAnimationTime: TimeInterval = 0
    private var autoAnimationTime: TimeInterval = 0
    private var autoStepAccumulator: TimeInterval = 0
    var stepDelta: TimeInterval = 1.0 / 30.0
    
    let textureLoader: MTKTextureLoader
    private let resourceName: String
    private let resourceExtension: String
    private let lightSystem: LightingSystem
    
    @MainActor
    init?(metalKitView: MTKView,
          resourceName: String = "robot",
          resourceExtension: String = "usdz",
          lightSystem: LightingSystem) {
        self.device = metalKitView.device!
        self.textureLoader = MTKTextureLoader(device: device)
        self.resourceName = resourceName
        self.resourceExtension = resourceExtension
        self.lightSystem = lightSystem
        
        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight
        guard let buffer = self.device.makeBuffer(length: uniformBufferSize, options: [.storageModeShared]) else { return nil }
        dynamicUniformBuffer = buffer
        dynamicUniformBuffer.label = "UniformBuffer"
        
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents()).bindMemory(to: Uniforms.self, capacity: 1)
        
        metalKitView.depthStencilPixelFormat = MTLPixelFormat.depth32Float_stencil8
        metalKitView.colorPixelFormat = MTLPixelFormat.bgra8Unorm_srgb
        metalKitView.sampleCount = 1
        
        let mtlVertexDescriptor = ModelAnimationSystem.buildMetalVertexDescriptor()
        
        do {
            pipelineState = try ModelAnimationSystem.buildRenderPipelineWithDevice(device: device,
                                                                       metalKitView: metalKitView,
                                                                       mtlVertexDescriptor: mtlVertexDescriptor,
                                                                       enableBlending: false)
            transparentPipelineState = try ModelAnimationSystem.buildRenderPipelineWithDevice(device: device,
                                                                       metalKitView: metalKitView,
                                                                       mtlVertexDescriptor: mtlVertexDescriptor,
                                                                       enableBlending: true)
        } catch {
            return nil
        }
        
        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = .less
        depthStateDescriptor.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: depthStateDescriptor) else { return nil }
        depthState = state
        
        let transparentDepthStateDescriptor = MTLDepthStencilDescriptor()
        transparentDepthStateDescriptor.depthCompareFunction = .less
        transparentDepthStateDescriptor.isDepthWriteEnabled = false
        guard let transState = device.makeDepthStencilState(descriptor: transparentDepthStateDescriptor) else { return nil }
        transparentDepthState = transState
        
        // Create default textures for PBR slots
        guard let defaultBaseColor = ModelAnimationSystem.createSolidTexture(device: device,
                                                                            color: SIMD4<UInt8>(255, 255, 255, 255),
                                                                            sRGB: true),
              let defaultNormal = ModelAnimationSystem.createSolidTexture(device: device,
                                                                          color: SIMD4<UInt8>(128, 128, 255, 255),
                                                                          sRGB: false),
              let defaultMetallic = ModelAnimationSystem.createSolidTexture(device: device,
                                                                            color: SIMD4<UInt8>(0, 0, 0, 255),
                                                                            sRGB: false),
              let defaultRoughness = ModelAnimationSystem.createSolidTexture(device: device,
                                                                             color: SIMD4<UInt8>(255, 255, 255, 255),
                                                                             sRGB: false),
              let defaultAO = ModelAnimationSystem.createSolidTexture(device: device,
                                                                      color: SIMD4<UInt8>(255, 255, 255, 255),
                                                                      sRGB: false),
              let defaultEmissive = ModelAnimationSystem.createSolidTexture(device: device,
                                                                            color: SIMD4<UInt8>(0, 0, 0, 255),
                                                                            sRGB: true),
              let defaultOpacity = ModelAnimationSystem.createSolidTexture(device: device,
                                                                           color: SIMD4<UInt8>(255, 255, 255, 255),
                                                                           sRGB: false) else {
            return nil
        }
        defaultMaterialTextures = MaterialTextures(baseColor: defaultBaseColor,
                                                   normal: defaultNormal,
                                                   metallic: defaultMetallic,
                                                   roughness: defaultRoughness,
                                                   ambientOcclusion: defaultAO,
                                                   emissive: defaultEmissive,
                                                   opacity: defaultOpacity)

        // Create a default identity joint matrix buffer for non-skinned meshes
        let jointBufferLength = MemoryLayout<matrix_float4x4>.stride
        guard let jointBuffer = device.makeBuffer(length: jointBufferLength, options: [.storageModeShared]) else {
            return nil
        }
        defaultJointMatricesBuffer = jointBuffer
        var identity = matrix_identity_float4x4
        defaultJointMatricesBuffer.contents().copyMemory(from: &identity, byteCount: jointBufferLength)
        
        super.init()
        
        // Load the asset
        do {
            let result = try loadAsset(device: device, mtlVertexDescriptor: mtlVertexDescriptor)
            self.meshes = result.meshes
            self.configureSkinning(with: result)
            // Note: onLoadCompleted will be called after init returns,
            // so the caller should set the callback before this point if needed
            // For synchronous load, caller can read meshRadius directly after init
        } catch {
            return nil
        }
    }
    
    /// Call this after init to notify load completion (for synchronous loading)
    func notifyLoadCompleted() {
        onLoadCompleted?(meshRadius)
    }
    
    private static func createSolidTexture(device: MTLDevice,
                                           color: SIMD4<UInt8>,
                                           sRGB: Bool) -> MTLTexture? {
        let pixelFormat: MTLPixelFormat = sRGB ? .rgba8Unorm_srgb : .rgba8Unorm
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixel = color
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                        mipmapLevel: 0,
                        withBytes: &pixel,
                        bytesPerRow: 4)
        return texture
    }

    private func loadTexture(from material: MDLMaterial,
                             semantic: MDLMaterialSemantic,
                             sRGB: Bool) -> MTLTexture? {
        guard let property = material.property(with: semantic) else { return nil }
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            .generateMipmaps: NSNumber(value: true),
            .SRGB: NSNumber(value: sRGB)
        ]

        if property.type == .texture, let mdlTexture = property.textureSamplerValue?.texture {
            return try? textureLoader.newTexture(texture: mdlTexture, options: options)
        }
        if property.type == .string, let urlString = property.stringValue,
           let url = URL(string: urlString) {
            return try? textureLoader.newTexture(URL: url, options: options)
        }
        return nil
    }
    
    private func loadAsset(device: MTLDevice, mtlVertexDescriptor: MTLVertexDescriptor) throws -> AssetLoadResult {
        let metalAllocator = MTKMeshBufferAllocator(device: device)
        let mdlVertexDescriptor = MTKModelIOVertexDescriptorFromMetal(mtlVertexDescriptor)
        
        guard let attributes = mdlVertexDescriptor.attributes as? [MDLVertexAttribute] else {
            throw RendererError.badVertexDescriptor
        }
        
        attributes[VertexAttribute.position.rawValue].name = MDLVertexAttributePosition
        attributes[VertexAttribute.texcoord.rawValue].name = MDLVertexAttributeTextureCoordinate
        attributes[VertexAttribute.normal.rawValue].name = MDLVertexAttributeNormal
        attributes[VertexAttribute.tangent.rawValue].name = MDLVertexAttributeTangent
        attributes[VertexAttribute.jointIndices.rawValue].name = MDLVertexAttributeJointIndices
        attributes[VertexAttribute.jointIndices.rawValue].initializationValue = vector_float4(0, 0, 0, 0)
        attributes[VertexAttribute.jointWeights.rawValue].name = MDLVertexAttributeJointWeights
        attributes[VertexAttribute.jointWeights.rawValue].initializationValue = vector_float4(1, 0, 0, 0)
        
        guard let assetURL = Bundle.main.url(forResource: resourceName, withExtension: resourceExtension) else {
            throw RendererError.meshNotFound
        }
        
        let asset = MDLAsset(url: assetURL,
                             vertexDescriptor: nil,
                             bufferAllocator: metalAllocator)
        asset.loadTextures()
        
        
        // Find skeleton and animation from asset hierarchy
        var foundSkeleton: MDLSkeleton?
        var foundPackedAnimation: MDLPackedJointAnimation?
        
        func findSkeletonAndAnimation(in object: MDLObject) {
            
            // Check if this object is a skeleton
            if let skeleton = object as? MDLSkeleton {
                foundSkeleton = skeleton
            }
            
            // Check if this object is a packed joint animation
            if let animation = object as? MDLPackedJointAnimation {
                foundPackedAnimation = animation
            }
            
            // Check if this is a mesh and has animation bind component
            if let mesh = object as? MDLMesh {
                for component in mesh.components {
                    if let animBind = component as? MDLAnimationBindComponent {
                        if let skel = animBind.skeleton {
                            if foundSkeleton == nil {
                                foundSkeleton = skel
                            }
                        }
                        if let anim = animBind.jointAnimation as? MDLPackedJointAnimation {
                            if foundPackedAnimation == nil {
                                foundPackedAnimation = anim
                            }
                        }
                    }
                }
            }
            
            // Recurse into children
            for child in object.children.objects {
                findSkeletonAndAnimation(in: child)
            }
        }
        
        for i in 0..<asset.count {
            findSkeletonAndAnimation(in: asset.object(at: i))
        }
        
        // Also check asset.animations
        for anim in Array(asset.animations.objects) {
            if let packedAnim = anim as? MDLPackedJointAnimation {
                if foundPackedAnimation == nil {
                    foundPackedAnimation = packedAnim
                }
            }
        }
        
        
        // Collect all meshes recursively
        var mdlMeshes: [MDLMesh] = []
        func collectMeshes(from object: MDLObject) {
            if let mesh = object as? MDLMesh {
                mdlMeshes.append(mesh)
            }
            for child in object.children.objects {
                collectMeshes(from: child)
            }
            if let instance = object.instance {
                collectMeshes(from: instance)
            }
        }
        
        for index in 0..<asset.count {
            collectMeshes(from: asset.object(at: index))
        }
        
        guard !mdlMeshes.isEmpty else {
            throw RendererError.meshNotFound
        }
        
        
        // Calculate bounds from all meshes
        var minBounds = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maxBounds = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        
        var meshDataArray: [MeshData] = []
        var bindComponent: MDLAnimationBindComponent?
        
        for mdlMesh in mdlMeshes {
            // Update bounds
            let bounds = mdlMesh.boundingBox
            let meshMin = SIMD3<Float>(bounds.minBounds)
            let meshMax = SIMD3<Float>(bounds.maxBounds)
            minBounds = SIMD3<Float>(Swift.min(minBounds.x, meshMin.x),
                                     Swift.min(minBounds.y, meshMin.y),
                                     Swift.min(minBounds.z, meshMin.z))
            maxBounds = SIMD3<Float>(Swift.max(maxBounds.x, meshMax.x),
                                     Swift.max(maxBounds.y, meshMax.y),
                                     Swift.max(maxBounds.z, meshMax.z))
            
            // Check for animation bind component
            let meshBindComponent = mdlMesh.components.first(where: { $0 is MDLAnimationBindComponent }) as? MDLAnimationBindComponent
            if bindComponent == nil {
                bindComponent = meshBindComponent
            }
            
            if mdlMesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal) == nil {
                mdlMesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.0)
            }
            if mdlMesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeTangent) == nil {
                mdlMesh.addTangentBasis(forTextureCoordinateAttributeNamed: MDLVertexAttributeTextureCoordinate,
                                        normalAttributeNamed: MDLVertexAttributeNormal,
                                        tangentAttributeNamed: MDLVertexAttributeTangent)
            }

            // Set vertex descriptor
            mdlMesh.vertexDescriptor = mdlVertexDescriptor
            
            // Create MTKMesh
            let mtkMesh = try MTKMesh(mesh: mdlMesh, device: device)
            
            // Process submeshes and extract textures
            var submeshDataArray: [SubmeshData] = []
            var skinning: MeshSkinning? = nil
            if let meshBindComponent = meshBindComponent {
                let rawJointPaths = meshBindComponent.jointPaths ?? []
                let jointPaths = rawJointPaths.isEmpty ? (foundSkeleton?.jointPaths ?? []) : rawJointPaths
                let geometryBindTransform = matrix4x4_from_double(meshBindComponent.geometryBindTransform)
                let geometryBindTransformInverse = simd_inverse(geometryBindTransform)
                let jointCount = max(1, jointPaths.count)
                let bufferLength = jointCount * MemoryLayout<matrix_float4x4>.stride
                var jointBuffers: [MTLBuffer] = []
                jointBuffers.reserveCapacity(maxBuffersInFlight)
                for _ in 0..<maxBuffersInFlight {
                    if let jointBuffer = device.makeBuffer(length: bufferLength, options: [.storageModeShared]) {
                        jointBuffers.append(jointBuffer)
                    }
                }
                if !jointBuffers.isEmpty {
                    skinning = MeshSkinning(jointPaths: jointPaths,
                                            jointMatricesBuffers: jointBuffers,
                                            geometryBindTransform: geometryBindTransform,
                                            geometryBindTransformInverse: geometryBindTransformInverse,
                                            jointToSkeletonIndex: [])
                }
            }
            
            guard let mdlSubmeshes = mdlMesh.submeshes as? [MDLSubmesh] else {
                for submesh in mtkMesh.submeshes {
                    submeshDataArray.append(SubmeshData(submesh: submesh, textures: defaultMaterialTextures, isTransparent: false))
                }
                meshDataArray.append(MeshData(mtkMesh: mtkMesh,
                                              submeshes: submeshDataArray,
                                              skinning: skinning))
                continue
            }
            
            for (submeshIndex, mdlSubmesh) in mdlSubmeshes.enumerated() {
                let mtkSubmesh = mtkMesh.submeshes[submeshIndex]
                var textures = defaultMaterialTextures
                var isTransparent = false

                if let material = mdlSubmesh.material {
                    let baseColor = loadTexture(from: material, semantic: .baseColor, sRGB: true)
                    let normal = loadTexture(from: material, semantic: .tangentSpaceNormal, sRGB: false)
                        ?? loadTexture(from: material, semantic: .objectSpaceNormal, sRGB: false)
                    let metallic = loadTexture(from: material, semantic: .metallic, sRGB: false)
                    let roughness = loadTexture(from: material, semantic: .roughness, sRGB: false)
                    let ao = loadTexture(from: material, semantic: .ambientOcclusion, sRGB: false)
                    let emissive = loadTexture(from: material, semantic: .emission, sRGB: true)
                    let opacity = loadTexture(from: material, semantic: .opacity, sRGB: false)

                    textures = MaterialTextures(
                        baseColor: baseColor ?? defaultMaterialTextures.baseColor,
                        normal: normal ?? defaultMaterialTextures.normal,
                        metallic: metallic ?? defaultMaterialTextures.metallic,
                        roughness: roughness ?? defaultMaterialTextures.roughness,
                        ambientOcclusion: ao ?? defaultMaterialTextures.ambientOcclusion,
                        emissive: emissive ?? defaultMaterialTextures.emissive,
                        opacity: opacity ?? defaultMaterialTextures.opacity
                    )
                    
                    // Determine transparency
                    if opacity != nil {
                        isTransparent = true
                    } else if let opacityProp = material.property(with: .opacity),
                              opacityProp.type == .float {
                        if opacityProp.floatValue < 1.0 {
                            isTransparent = true
                        }
                    }
                }

                submeshDataArray.append(SubmeshData(submesh: mtkSubmesh, textures: textures, isTransparent: isTransparent))
            }
            
            meshDataArray.append(MeshData(mtkMesh: mtkMesh,
                                          submeshes: submeshDataArray,
                                          skinning: skinning))
        }
        
        let boundsCenter = (minBounds + maxBounds) * 0.5
        let extents = maxBounds - minBounds
        let boundsRadius = max(length(extents) * 0.5, 0.001)
        
        
        return AssetLoadResult(
            meshes: meshDataArray,
            bindComponent: bindComponent,
            skeleton: foundSkeleton,
            packedAnimation: foundPackedAnimation,
            assetStartTime: asset.startTime,
            assetEndTime: asset.endTime,
            boundsCenter: boundsCenter,
            boundsRadius: boundsRadius
        )
    }
    
    private func configureSkinning(with result: AssetLoadResult) {
        animationBindComponent = result.bindComponent
        assetStartTime = result.assetStartTime
        assetEndTime = result.assetEndTime
        meshCenter = result.boundsCenter
        meshRadius = max(result.boundsRadius, 0.001)
        manualAnimationTime = assetStartTime
        autoAnimationTime = assetStartTime
        autoStepAccumulator = 0
        
        
        // Use skeleton from AssetLoadResult (found via hierarchy traversal)
        // or fall back to bindComponent.skeleton
        var foundSkeleton = result.skeleton
        var foundAnimation = result.packedAnimation
        
        if foundSkeleton == nil, let bindComponent = result.bindComponent {
            foundSkeleton = bindComponent.skeleton
        }
        if foundAnimation == nil, let bindComponent = result.bindComponent {
            foundAnimation = bindComponent.jointAnimation as? MDLPackedJointAnimation
        }
        
        guard let skeleton = foundSkeleton else {
            restTransforms = []
            inverseBindTransforms = []
            jointParentIndices = []
            return
        }
        
        self.skeleton = skeleton
        animation = foundAnimation
        
        
        let jointPaths = skeleton.jointPaths
        let pathToIndex = buildPathIndexMap(from: jointPaths)
        let tailToIndex = buildTailIndexMap(from: jointPaths)
        jointParentIndices = jointPaths.map { path in
            guard let parentPath = parentJointPath(for: path),
                  let parentIndex = pathToIndex[parentPath] else {
                return -1
            }
            return parentIndex
        }
        
        restTransforms = skeleton.jointRestTransforms.matrixFloat4x4Array
        if restTransforms.count != jointPaths.count {
            restTransforms = Array(repeating: matrix_identity_float4x4, count: jointPaths.count)
        }
        
        let bindTransforms = skeleton.jointBindTransforms.matrixFloat4x4Array
        if bindTransforms.count == jointPaths.count {
            inverseBindTransforms = bindTransforms.map { simd_inverse($0) }
        } else {
            inverseBindTransforms = Array(repeating: matrix_identity_float4x4, count: jointPaths.count)
        }
        
        if let animation = animation {
            animJointToSkeletonIndex = animation.jointPaths.map {
                mapJointPathToSkeletonIndex($0, pathToIndex: pathToIndex, tailToIndex: tailToIndex)
            }
            previousAnimationRotations = Array(repeating: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                               count: animation.jointPaths.count)
            
            if assetEndTime <= assetStartTime {
                let minTime = Swift.min(animation.translations.minimumTime,
                                        Swift.min(animation.rotations.minimumTime,
                                                  animation.scales.minimumTime))
                let maxTime = Swift.max(animation.translations.maximumTime,
                                        Swift.max(animation.rotations.maximumTime,
                                                  animation.scales.maximumTime))
                assetStartTime = minTime
                assetEndTime = maxTime
                manualAnimationTime = assetStartTime
                autoAnimationTime = assetStartTime
                autoStepAccumulator = 0
            }
        }

        for index in meshes.indices {
            guard var skinning = meshes[index].skinning else { continue }
            var jointPathsForMesh = skinning.jointPaths

            if jointPathsForMesh.isEmpty {
                jointPathsForMesh = jointPaths
                let jointCount = jointPathsForMesh.count
                if jointCount > 0 {
                    let bufferLength = jointCount * MemoryLayout<matrix_float4x4>.stride
                    var jointBuffers: [MTLBuffer] = []
                    jointBuffers.reserveCapacity(maxBuffersInFlight)
                    for _ in 0..<maxBuffersInFlight {
                        if let newBuffer = device.makeBuffer(length: bufferLength, options: [.storageModeShared]) {
                            jointBuffers.append(newBuffer)
                        }
                    }
                    if !jointBuffers.isEmpty {
                        skinning = MeshSkinning(jointPaths: jointPathsForMesh,
                                                jointMatricesBuffers: jointBuffers,
                                                geometryBindTransform: skinning.geometryBindTransform,
                                                geometryBindTransformInverse: skinning.geometryBindTransformInverse,
                                                jointToSkeletonIndex: [])
                    } else {
                        jointPathsForMesh = skinning.jointPaths
                    }
                }
            }

            if jointPathsForMesh.isEmpty {
                skinning.jointToSkeletonIndex = []
            } else {
                skinning.jointToSkeletonIndex = jointPathsForMesh.map {
                    mapJointPathToSkeletonIndex($0, pathToIndex: pathToIndex, tailToIndex: tailToIndex)
                }
            }

            meshes[index].skinning = skinning
        }
    }
    
    private func parentJointPath(for path: String) -> String? {
        let normalized = normalizeJointPath(path)
        guard let lastSlash = normalized.lastIndex(of: "/") else { return nil }
        let parent = String(normalized[..<lastSlash])
        return parent.isEmpty ? nil : parent
    }

    private func normalizeJointPath(_ path: String) -> String {
        let parts = path.split(separator: "/").filter { !$0.isEmpty }
        return parts.joined(separator: "/")
    }

    private func buildPathIndexMap(from jointPaths: [String]) -> [String: Int] {
        let normalizedPaths = jointPaths.map { normalizeJointPath($0) }
        var map: [String: Int] = [:]
        for (index, path) in normalizedPaths.enumerated() where !path.isEmpty {
            map[path] = index
        }

        var suffixCounts: [String: Int] = [:]
        for path in normalizedPaths where !path.isEmpty {
            let parts = path.split(separator: "/")
            guard parts.count > 1 else { continue }
            for start in 1..<parts.count {
                let suffix = parts[start...].joined(separator: "/")
                suffixCounts[suffix, default: 0] += 1
            }
        }

        for (index, path) in normalizedPaths.enumerated() where !path.isEmpty {
            let parts = path.split(separator: "/")
            guard parts.count > 1 else { continue }
            for start in 1..<parts.count {
                let suffix = parts[start...].joined(separator: "/")
                if suffixCounts[suffix] == 1 && map[suffix] == nil {
                    map[suffix] = index
                }
            }
        }

        return map
    }

    private func buildTailIndexMap(from jointPaths: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        let tails = jointPaths.map { path -> String in
            let normalized = normalizeJointPath(path)
            return normalized.split(separator: "/").last.map(String.init) ?? normalized
        }
        for tail in tails where !tail.isEmpty {
            counts[tail, default: 0] += 1
        }
        var map: [String: Int] = [:]
        for (index, tail) in tails.enumerated() where !tail.isEmpty {
            if counts[tail] == 1 {
                map[tail] = index
            }
        }
        return map
    }

    private func mapJointPathToSkeletonIndex(_ jointPath: String,
                                             pathToIndex: [String: Int],
                                             tailToIndex: [String: Int]) -> Int {
        let normalized = normalizeJointPath(jointPath)
        if let index = pathToIndex[normalized] {
            return index
        }
        let tail = normalized.split(separator: "/").last.map(String.init) ?? normalized
        if let index = tailToIndex[tail] {
            return index
        }
        return -1
    }
    
    class func buildMetalVertexDescriptor() -> MTLVertexDescriptor {
        let mtlVertexDescriptor = MTLVertexDescriptor()
        
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].format = .float3
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue
        
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].format = .float2
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].bufferIndex = BufferIndex.meshTexcoords.rawValue

        mtlVertexDescriptor.attributes[VertexAttribute.normal.rawValue].format = .float3
        mtlVertexDescriptor.attributes[VertexAttribute.normal.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.normal.rawValue].bufferIndex = BufferIndex.meshNormals.rawValue

        mtlVertexDescriptor.attributes[VertexAttribute.tangent.rawValue].format = .float4
        mtlVertexDescriptor.attributes[VertexAttribute.tangent.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.tangent.rawValue].bufferIndex = BufferIndex.meshTangents.rawValue
        
        mtlVertexDescriptor.attributes[VertexAttribute.jointIndices.rawValue].format = .ushort4
        mtlVertexDescriptor.attributes[VertexAttribute.jointIndices.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.jointIndices.rawValue].bufferIndex = BufferIndex.meshJointIndices.rawValue
        
        mtlVertexDescriptor.attributes[VertexAttribute.jointWeights.rawValue].format = .float4
        mtlVertexDescriptor.attributes[VertexAttribute.jointWeights.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.jointWeights.rawValue].bufferIndex = BufferIndex.meshJointWeights.rawValue
        
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stride = 12
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepFunction = .perVertex
        
        mtlVertexDescriptor.layouts[BufferIndex.meshTexcoords.rawValue].stride = 8
        mtlVertexDescriptor.layouts[BufferIndex.meshTexcoords.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshTexcoords.rawValue].stepFunction = .perVertex

        mtlVertexDescriptor.layouts[BufferIndex.meshNormals.rawValue].stride = 12
        mtlVertexDescriptor.layouts[BufferIndex.meshNormals.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshNormals.rawValue].stepFunction = .perVertex

        mtlVertexDescriptor.layouts[BufferIndex.meshTangents.rawValue].stride = 16
        mtlVertexDescriptor.layouts[BufferIndex.meshTangents.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshTangents.rawValue].stepFunction = .perVertex
        
        mtlVertexDescriptor.layouts[BufferIndex.meshJointIndices.rawValue].stride = 8
        mtlVertexDescriptor.layouts[BufferIndex.meshJointIndices.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshJointIndices.rawValue].stepFunction = .perVertex
        
        mtlVertexDescriptor.layouts[BufferIndex.meshJointWeights.rawValue].stride = 16
        mtlVertexDescriptor.layouts[BufferIndex.meshJointWeights.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshJointWeights.rawValue].stepFunction = .perVertex
        
        return mtlVertexDescriptor
    }
    
    @MainActor
    class func buildRenderPipelineWithDevice(device: MTLDevice,
                                             metalKitView: MTKView,
                                             mtlVertexDescriptor: MTLVertexDescriptor,
                                             enableBlending: Bool) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        
        let vertexFunction = library?.makeFunction(name: "vertexShader")
        let fragmentFunction = library?.makeFunction(name: "fragmentShader")
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = enableBlending ? "TransparentRenderPipeline" : "OpaqueRenderPipeline"
        pipelineDescriptor.rasterSampleCount = metalKitView.sampleCount
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor
        
        pipelineDescriptor.colorAttachments[0].pixelFormat = metalKitView.colorPixelFormat
        
        if enableBlending {
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        } else {
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = false
        }
        
        pipelineDescriptor.depthAttachmentPixelFormat = metalKitView.depthStencilPixelFormat
        pipelineDescriptor.stencilAttachmentPixelFormat = metalKitView.depthStencilPixelFormat
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    func update(deltaTime: TimeInterval, frameIndex: Int) {
        currentFrameIndex = frameIndex % maxBuffersInFlight
        currentUniformBufferOffset = alignedUniformsSize * currentFrameIndex
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents() + currentUniformBufferOffset)
            .bindMemory(to: Uniforms.self, capacity: 1)
        updateGameState(deltaTime: deltaTime, frameIndex: currentFrameIndex)
    }

    private func updateGameState(deltaTime: TimeInterval, frameIndex: Int) {
        if isAutoAnimation {
            updateAutoAnimationTime(deltaTime: deltaTime)
        }

        let centerTranslation = matrix4x4_translation(-meshCenter.x, -meshCenter.y, -meshCenter.z)
        modelMatrix = centerTranslation

        updateSkinning(frameIndex: frameIndex)
    }
    
    private func updateSkinning(frameIndex: Int) {
        guard !restTransforms.isEmpty, !inverseBindTransforms.isEmpty else { return }

        let skeletonJointCount = restTransforms.count
        var localTransforms = restTransforms
        if localTransforms.count != skeletonJointCount {
            localTransforms = Array(repeating: matrix_identity_float4x4, count: skeletonJointCount)
        }

        if let animation = animation {
            let time = currentAnimationTime()
            let translations = animation.translations.float3Array(atTime: time)
            let rotations = animation.rotations.floatQuaternionArray(atTime: time)
            let scales = animation.scales.float3Array(atTime: time)
            let animCount = Swift.min(translations.count,
                                      Swift.min(rotations.count,
                                                Swift.min(scales.count, animJointToSkeletonIndex.count)))

            if previousAnimationRotations.count < rotations.count {
                let extra = Array(repeating: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                  count: rotations.count - previousAnimationRotations.count)
                previousAnimationRotations.append(contentsOf: extra)
            }

            for i in 0..<animCount {
                let jointIndex = animJointToSkeletonIndex[i]
                if jointIndex >= 0 && jointIndex < localTransforms.count {
                    var rotation = rotations[i]
                    
                    // Properly normalize quaternion (including real part)
                    let qLength = sqrt(rotation.real * rotation.real + 
                                      rotation.imag.x * rotation.imag.x + 
                                      rotation.imag.y * rotation.imag.y + 
                                      rotation.imag.z * rotation.imag.z)
                    if qLength > 0.0001 {
                        rotation = simd_quatf(ix: rotation.imag.x / qLength,
                                             iy: rotation.imag.y / qLength,
                                             iz: rotation.imag.z / qLength,
                                             r: rotation.real / qLength)
                    } else {
                        // Invalid quaternion - use identity
                        rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                    }
                    
                    if previousAnimationRotations.indices.contains(i) {
                        let previous = previousAnimationRotations[i]
                        let dotProduct = rotation.real * previous.real +
                                        rotation.imag.x * previous.imag.x +
                                        rotation.imag.y * previous.imag.y +
                                        rotation.imag.z * previous.imag.z
                        if dotProduct < 0 {
                            rotation = simd_quatf(ix: -rotation.imag.x,
                                                 iy: -rotation.imag.y,
                                                 iz: -rotation.imag.z,
                                                 r: -rotation.real)
                        }
                        previousAnimationRotations[i] = rotation
                    }
                    localTransforms[jointIndex] = matrix4x4_trs(translation: translations[i],
                                                                rotation: rotation,
                                                                scale: scales[i])
                }
            }
        }

        let globalTransforms = buildGlobalTransforms(from: localTransforms)
        let skeletonCount = min(globalTransforms.count, inverseBindTransforms.count)
        if skeletonCount == 0 { return }

        var skinMatrices = Array(repeating: matrix_identity_float4x4, count: skeletonCount)
        for i in 0..<skeletonCount {
            skinMatrices[i] = simd_mul(globalTransforms[i], inverseBindTransforms[i])
        }

        for index in meshes.indices {
            guard let skinning = meshes[index].skinning else { continue }
            let jointCount = skinning.jointToSkeletonIndex.count
            guard jointCount > 0 else { continue }
            guard !skinning.jointMatricesBuffers.isEmpty else { continue }
            let bufferIndex = frameIndex % skinning.jointMatricesBuffers.count
            let jointBuffer = skinning.jointMatricesBuffers[bufferIndex]
            let bufferPointer = jointBuffer.contents()
                .bindMemory(to: matrix_float4x4.self, capacity: jointCount)
            for jointIndex in 0..<jointCount {
                let skeletonIndex = skinning.jointToSkeletonIndex[jointIndex]
                let skinMatrix: matrix_float4x4
                if skeletonIndex >= 0 && skeletonIndex < skinMatrices.count {
                    skinMatrix = skinMatrices[skeletonIndex]
                } else {
                    skinMatrix = matrix_identity_float4x4
                }
                let finalMatrix = simd_mul(skinning.geometryBindTransformInverse,
                                           simd_mul(skinMatrix, skinning.geometryBindTransform))
                bufferPointer[jointIndex] = finalMatrix
            }
        }
    }
    
    private func currentAnimationTime() -> TimeInterval {
        if isAutoAnimation {
            return currentAutoAnimationTime()
        }
        return wrappedAnimationTime(manualAnimationTime)
    }

    private func currentAutoAnimationTime() -> TimeInterval {
        return autoAnimationTime
    }

    private func wrappedAnimationTime(_ time: TimeInterval) -> TimeInterval {
        let duration = max(0.0, assetEndTime - assetStartTime)
        guard duration > 0.0001 else { return assetStartTime }
        let offset = (time - assetStartTime).truncatingRemainder(dividingBy: duration)
        return assetStartTime + (offset >= 0 ? offset : offset + duration)
    }

    func setAutoAnimation(_ isAuto: Bool) {
        let currentTime = isAutoAnimation ? currentAutoAnimationTime() : manualAnimationTime
        isAutoAnimation = isAuto
        if isAuto {
            autoAnimationTime = wrappedAnimationTime(currentTime)
            autoStepAccumulator = 0
        } else {
            manualAnimationTime = wrappedAnimationTime(currentTime)
        }
    }

    func stepAnimation(by delta: TimeInterval) {
        guard !isAutoAnimation else { return }
        manualAnimationTime = wrappedAnimationTime(manualAnimationTime + delta)
    }

    func stepAnimation() {
        stepAnimation(by: stepDelta)
    }

    func stepAnimationBackward() {
        stepAnimation(by: -stepDelta)
    }

    private func updateAutoAnimationTime(deltaTime: TimeInterval) {
        var delta = deltaTime
        if delta > 0.25 {
            delta = 0.0
        }
        autoStepAccumulator += delta
        let step = max(stepDelta, 0.0001)
        while autoStepAccumulator >= step {
            autoAnimationTime = wrappedAnimationTime(autoAnimationTime + step)
            autoStepAccumulator -= step
        }
    }

    func animationFrameInfo(fps: Double) -> (frame: Int, totalFrames: Int, time: TimeInterval) {
        let time = isAutoAnimation ? currentAutoAnimationTime() : manualAnimationTime
        let duration = max(0.0, assetEndTime - assetStartTime)
        guard duration > 0.0001, fps > 0 else {
            return (frame: 0, totalFrames: 0, time: time)
        }
        let totalFrames = Int(round(duration * fps))
        let offset = max(0.0, time - assetStartTime)
        let frame = Int(round(offset * fps)) % max(totalFrames, 1)
        return (frame: frame, totalFrames: totalFrames, time: time)
    }
    
    private func buildGlobalTransforms(from localTransforms: [matrix_float4x4]) -> [matrix_float4x4] {
        var globalTransforms = Array(repeating: matrix_identity_float4x4, count: localTransforms.count)
        var computed = Array(repeating: false, count: localTransforms.count)
        
        func compute(_ index: Int) {
            if computed[index] { return }
            let parentIndex = jointParentIndices.indices.contains(index) ? jointParentIndices[index] : -1
            if parentIndex >= 0 && parentIndex < localTransforms.count {
                compute(parentIndex)
                globalTransforms[index] = simd_mul(globalTransforms[parentIndex], localTransforms[index])
            } else {
                globalTransforms[index] = localTransforms[index]
            }
            computed[index] = true
        }
        
        for i in 0..<localTransforms.count { compute(i) }
        return globalTransforms
    }
    
    func draw(renderEncoder: MTLRenderCommandEncoder,
              frameIndex: Int,
              viewMatrix: matrix_float4x4,
              projectionMatrix: matrix_float4x4) {
        // Compute modelViewMatrix using provided camera matrices
        uniforms[0].projectionMatrix = projectionMatrix
        uniforms[0].modelViewMatrix = simd_mul(viewMatrix, modelMatrix)
        uniforms[0].lightDirection = lightSystem.lightDirectionInView(viewMatrix: viewMatrix)
        uniforms[0].lightColor = lightSystem.lightColor
        uniforms[0].ambientColor = lightSystem.ambientColor
        
        renderEncoder.pushDebugGroup("Draw Model")
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)
        
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset: currentUniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setFragmentBuffer(dynamicUniformBuffer, offset: currentUniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        
        // Pass 1: Opaque
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthState)
        drawMeshes(renderEncoder: renderEncoder, frameIndex: frameIndex, transparentPass: false)
        
        // Pass 2: Transparent
        renderEncoder.setRenderPipelineState(transparentPipelineState)
        renderEncoder.setDepthStencilState(transparentDepthState)
        drawMeshes(renderEncoder: renderEncoder, frameIndex: frameIndex, transparentPass: true)

        renderEncoder.popDebugGroup()
    }
    
    private func drawMeshes(renderEncoder: MTLRenderCommandEncoder, frameIndex: Int, transparentPass: Bool) {
        for meshData in meshes {
            let mtkMesh = meshData.mtkMesh
            let jointBuffer: MTLBuffer
            if let skinning = meshData.skinning, !skinning.jointMatricesBuffers.isEmpty {
                let bufferIndex = frameIndex % skinning.jointMatricesBuffers.count
                jointBuffer = skinning.jointMatricesBuffers[bufferIndex]
            } else {
                jointBuffer = defaultJointMatricesBuffer
            }
            renderEncoder.setVertexBuffer(jointBuffer, offset: 0, index: BufferIndex.jointMatrices.rawValue)

            for (bufferIndex, vertexBuffer) in mtkMesh.vertexBuffers.enumerated() {
                renderEncoder.setVertexBuffer(vertexBuffer.buffer, offset: vertexBuffer.offset, index: bufferIndex)
            }

            for submeshData in meshData.submeshes {
                // Filter based on transparency
                if submeshData.isTransparent != transparentPass {
                    continue
                }
                
                let submesh = submeshData.submesh
                let textures = submeshData.textures
                renderEncoder.setFragmentTexture(textures.baseColor,
                                                 index: TextureIndex.baseColor.rawValue)
                renderEncoder.setFragmentTexture(textures.normal,
                                                 index: TextureIndex.normal.rawValue)
                renderEncoder.setFragmentTexture(textures.metallic,
                                                 index: TextureIndex.metallic.rawValue)
                renderEncoder.setFragmentTexture(textures.roughness,
                                                 index: TextureIndex.roughness.rawValue)
                renderEncoder.setFragmentTexture(textures.ambientOcclusion,
                                                 index: TextureIndex.ambientOcclusion.rawValue)
                renderEncoder.setFragmentTexture(textures.emissive,
                                                 index: TextureIndex.emissive.rawValue)
                renderEncoder.setFragmentTexture(textures.opacity,
                                                 index: TextureIndex.opacity.rawValue)

                renderEncoder.drawIndexedPrimitives(
                    type: submesh.primitiveType,
                    indexCount: submesh.indexCount,
                    indexType: submesh.indexType,
                    indexBuffer: submesh.indexBuffer.buffer,
                    indexBufferOffset: submesh.indexBuffer.offset
                )
            }
        }
    }

    func drawableSizeWillChange(_ size: CGSize) {
        // CameraSystem handles projection updates.
    }
}

// MARK: - Matrix Utilities

func matrix4x4_from_double(_ matrix: matrix_double4x4) -> matrix_float4x4 {
    return matrix_float4x4(
        SIMD4<Float>(Float(matrix.columns.0.x), Float(matrix.columns.0.y), Float(matrix.columns.0.z), Float(matrix.columns.0.w)),
        SIMD4<Float>(Float(matrix.columns.1.x), Float(matrix.columns.1.y), Float(matrix.columns.1.z), Float(matrix.columns.1.w)),
        SIMD4<Float>(Float(matrix.columns.2.x), Float(matrix.columns.2.y), Float(matrix.columns.2.z), Float(matrix.columns.2.w)),
        SIMD4<Float>(Float(matrix.columns.3.x), Float(matrix.columns.3.y), Float(matrix.columns.3.z), Float(matrix.columns.3.w))
    )
}

func matrix4x4_trs(translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>) -> matrix_float4x4 {
    let translationMatrix = matrix4x4_translation(translation.x, translation.y, translation.z)
    let rotationMatrix = matrix_float4x4(rotation)
    let scaleMatrix = matrix_float4x4(diagonal: SIMD4<Float>(scale.x, scale.y, scale.z, 1))
    return simd_mul(translationMatrix, simd_mul(rotationMatrix, scaleMatrix))
}

func matrix4x4_rotation(radians: Float, axis: SIMD3<Float>) -> matrix_float4x4 {
    let unitAxis = normalize(axis)
    let ct = cosf(radians)
    let st = sinf(radians)
    let ci = 1 - ct
    let x = unitAxis.x, y = unitAxis.y, z = unitAxis.z
    return matrix_float4x4(columns: (
        vector_float4(ct + x * x * ci, y * x * ci + z * st, z * x * ci - y * st, 0),
        vector_float4(x * y * ci - z * st, ct + y * y * ci, z * y * ci + x * st, 0),
        vector_float4(x * z * ci + y * st, y * z * ci - x * st, ct + z * z * ci, 0),
        vector_float4(0, 0, 0, 1)
    ))
}

func matrix4x4_translation(_ x: Float, _ y: Float, _ z: Float) -> matrix_float4x4 {
    return matrix_float4x4(columns: (
        vector_float4(1, 0, 0, 0),
        vector_float4(0, 1, 0, 0),
        vector_float4(0, 0, 1, 0),
        vector_float4(x, y, z, 1)
    ))
}

func matrix_perspective_right_hand(fovyRadians fovy: Float, aspectRatio: Float, nearZ: Float, farZ: Float) -> matrix_float4x4 {
    let ys = 1 / tanf(fovy * 0.5)
    let xs = ys / aspectRatio
    let zs = farZ / (nearZ - farZ)
    return matrix_float4x4(columns: (
        vector_float4(xs, 0, 0, 0),
        vector_float4(0, ys, 0, 0),
        vector_float4(0, 0, zs, -1),
        vector_float4(0, 0, zs * nearZ, 0)
    ))
}

func radians_from_degrees(_ degrees: Float) -> Float {
    return (degrees / 180) * .pi
}

// MARK: - Model I/O Extensions

extension MDLMatrix4x4Array {
    var matrixFloat4x4Array: [matrix_float4x4] {
        return self.float4x4Array.map { matrix_float4x4($0) }
    }
}
