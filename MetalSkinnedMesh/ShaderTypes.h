//
//  ShaderTypes.h
//  MetalSkinnedMesh
//
//  Created by Tatsuya Ogawa on 2025/12/28.
//

//
//  Header containing types and enum constants shared between Metal shaders and Swift/ObjC source
//
#ifndef ShaderTypes_h
#define ShaderTypes_h

#ifdef __METAL_VERSION__
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
typedef metal::int32_t EnumBackingType;
#else
#import <Foundation/Foundation.h>
typedef NSInteger EnumBackingType;
#endif

#include <simd/simd.h>

typedef NS_ENUM(EnumBackingType, BufferIndex)
{
    BufferIndexMeshPositions    = 0,
    BufferIndexMeshTexcoords    = 1,
    BufferIndexMeshNormals      = 2,
    BufferIndexMeshTangents     = 3,
    BufferIndexMeshJointIndices = 4,
    BufferIndexMeshJointWeights = 5,
    BufferIndexUniforms         = 6,
    BufferIndexJointMatrices    = 7
};

typedef NS_ENUM(EnumBackingType, VertexAttribute)
{
    VertexAttributePosition     = 0,
    VertexAttributeTexcoord     = 1,
    VertexAttributeNormal       = 2,
    VertexAttributeTangent      = 3,
    VertexAttributeJointIndices = 4,
    VertexAttributeJointWeights = 5
};

typedef NS_ENUM(EnumBackingType, TextureIndex)
{
    TextureIndexBaseColor       = 0,
    TextureIndexNormal          = 1,
    TextureIndexMetallic        = 2,
    TextureIndexRoughness       = 3,
    TextureIndexAmbientOcclusion = 4,
    TextureIndexEmissive        = 5,
    TextureIndexOpacity         = 6
};

typedef struct
{
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 modelViewMatrix;
    vector_float3 lightDirection;
    float padding0;
    vector_float3 lightColor;
    float padding1;
    vector_float3 ambientColor;
    float padding2;
} Uniforms;

#endif /* ShaderTypes_h */
