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
typedef uint LightCountType;
#else
#import <Foundation/Foundation.h>
typedef NSInteger EnumBackingType;
#include <stdint.h>
typedef uint32_t LightCountType;
#endif

#include <simd/simd.h>

#define MaxLights 16

typedef NS_ENUM(EnumBackingType, BufferIndex)
{
    BufferIndexMeshPositions    = 0,
    BufferIndexMeshTexcoords    = 1,
    BufferIndexMeshNormals      = 2,
    BufferIndexMeshTangents     = 3,
    BufferIndexMeshJointIndices = 4,
    BufferIndexMeshJointWeights = 5,
    BufferIndexUniforms         = 6,
    BufferIndexJointMatrices    = 7,
    BufferIndexLights           = 8,
    BufferIndexShadowUniforms   = 9,
    BufferIndexVolumeUniforms   = 10,
    BufferIndexBoneColors       = 11
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
    TextureIndexOpacity         = 6,
    TextureIndexShadowMap       = 7
};

typedef struct
{
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 modelViewMatrix;
    matrix_float4x4 modelMatrix;
    vector_float4 ambientColor;
    LightCountType lightCount;
    vector_float4 padding0;
} Uniforms;

typedef struct
{
    vector_float4 position;     // xyz: view-space position, w: intensity
    vector_float4 direction;    // xyz: view-space direction, w: outer cone cos
    vector_float4 color;        // rgb: light color, w: inner cone cos
    vector_float4 shadowParams; // x: shadow enabled, y: bias, z: slope scale, w: shadow map inv size
    matrix_float4x4 shadowMatrix;
} LightData;

typedef struct
{
    matrix_float4x4 lightViewProjectionMatrix;
    matrix_float4x4 modelMatrix;
} ShadowUniforms;

typedef struct
{
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 modelViewMatrix;
    vector_float4 color;   // rgb + intensity
    vector_float4 params;  // x: length, y: radius, z: edge softness, w: alpha
} VolumeUniforms;

#endif /* ShaderTypes_h */
