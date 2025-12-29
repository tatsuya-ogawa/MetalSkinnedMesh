//
//  Shaders.metal
//  MetalSkinnedMesh
//
//  Created by Tatsuya Ogawa on 2025/12/28.
//

// File for Metal kernel and shader functions

#include <metal_stdlib>
#include <simd/simd.h>

// Including header shared between this Metal shader code and Swift/C code executing Metal API commands
#import "ShaderTypes.h"

using namespace metal;

typedef struct
{
    float3 position [[attribute(VertexAttributePosition)]];
    float2 texCoord [[attribute(VertexAttributeTexcoord)]];
    float3 normal [[attribute(VertexAttributeNormal)]];
    float4 tangent [[attribute(VertexAttributeTangent)]];
    ushort4 jointIndices [[attribute(VertexAttributeJointIndices)]];
    float4 jointWeights [[attribute(VertexAttributeJointWeights)]];
} Vertex;

typedef struct
{
    float4 position [[position]];
    float2 texCoord;
    float3 viewPos;
    float3 viewNormal;
    float3 viewTangent;
    float3 viewBitangent;
} ColorInOut;

vertex ColorInOut vertexShader(Vertex in [[stage_in]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                               constant float4x4 *jointMatrices [[ buffer(BufferIndexJointMatrices) ]])
{
    ColorInOut out;

    float4 position = float4(in.position, 1.0);

    float4 skinnedPosition = float4(0.0);
    float3 skinnedNormal = float3(0.0);
    float3 skinnedTangent = float3(0.0);
    float4 weights = in.jointWeights;
    if (weights.x + weights.y + weights.z + weights.w < 0.0001) {
        weights = float4(1.0, 0.0, 0.0, 0.0);
    }

    float4 n4 = float4(in.normal, 0.0);
    float4 t4 = float4(in.tangent.xyz, 0.0);

    skinnedPosition += weights.x * (jointMatrices[in.jointIndices.x] * position);
    skinnedPosition += weights.y * (jointMatrices[in.jointIndices.y] * position);
    skinnedPosition += weights.z * (jointMatrices[in.jointIndices.z] * position);
    skinnedPosition += weights.w * (jointMatrices[in.jointIndices.w] * position);

    skinnedNormal += weights.x * (jointMatrices[in.jointIndices.x] * n4).xyz;
    skinnedNormal += weights.y * (jointMatrices[in.jointIndices.y] * n4).xyz;
    skinnedNormal += weights.z * (jointMatrices[in.jointIndices.z] * n4).xyz;
    skinnedNormal += weights.w * (jointMatrices[in.jointIndices.w] * n4).xyz;

    skinnedTangent += weights.x * (jointMatrices[in.jointIndices.x] * t4).xyz;
    skinnedTangent += weights.y * (jointMatrices[in.jointIndices.y] * t4).xyz;
    skinnedTangent += weights.z * (jointMatrices[in.jointIndices.z] * t4).xyz;
    skinnedTangent += weights.w * (jointMatrices[in.jointIndices.w] * t4).xyz;

    float4 viewPos = uniforms.modelViewMatrix * skinnedPosition;
    out.position = uniforms.projectionMatrix * viewPos;
    out.viewPos = viewPos.xyz;

    float3 viewNormal = (uniforms.modelViewMatrix * float4(skinnedNormal, 0.0)).xyz;
    float3 viewTangent = (uniforms.modelViewMatrix * float4(skinnedTangent, 0.0)).xyz;
    viewNormal = normalize(viewNormal);
    viewTangent = normalize(viewTangent);
    float3 viewBitangent = normalize(cross(viewNormal, viewTangent) * in.tangent.w);
    out.viewNormal = viewNormal;
    out.viewTangent = viewTangent;
    out.viewBitangent = viewBitangent;
    
    // Flip Y coordinate for USDZ textures (OpenGL style UV -> Metal style)
    out.texCoord = float2(in.texCoord.x, 1.0 - in.texCoord.y);

    return out;
}

fragment float4 fragmentShader(ColorInOut in [[stage_in]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                               texture2d<half> baseColorMap [[ texture(TextureIndexBaseColor) ]],
                               texture2d<half> normalMap [[ texture(TextureIndexNormal) ]],
                               texture2d<half> metallicMap [[ texture(TextureIndexMetallic) ]],
                               texture2d<half> roughnessMap [[ texture(TextureIndexRoughness) ]],
                               texture2d<half> aoMap [[ texture(TextureIndexAmbientOcclusion) ]],
                               texture2d<half> emissiveMap [[ texture(TextureIndexEmissive) ]],
                               texture2d<half> opacityMap [[ texture(TextureIndexOpacity) ]])
{
    constexpr sampler colorSampler(mip_filter::linear,
                                   mag_filter::linear,
                                   min_filter::linear);

    float4 baseColorSample = float4(baseColorMap.sample(colorSampler, in.texCoord.xy));
    float3 emissiveSample = float3(emissiveMap.sample(colorSampler, in.texCoord.xy).rgb);
    float metallic = metallicMap.sample(colorSampler, in.texCoord.xy).r;
    float roughness = roughnessMap.sample(colorSampler, in.texCoord.xy).r;
    float ao = aoMap.sample(colorSampler, in.texCoord.xy).r;
    float opacity = opacityMap.sample(colorSampler, in.texCoord.xy).r;

    float3 n = normalize(in.viewNormal);
    float3 t = in.viewTangent;
    float3 b = in.viewBitangent;
    if (length(t) > 0.0001 && length(b) > 0.0001) {
        t = normalize(t);
        b = normalize(b);
        float3 mapN = float3(normalMap.sample(colorSampler, in.texCoord.xy).rgb);
        mapN = mapN * 2.0 - 1.0;
        float3x3 tbn = float3x3(t, b, n);
        n = normalize(tbn * mapN);
    }

    float3 v = normalize(-in.viewPos);
    float3 l = normalize(uniforms.lightDirection);
    float3 h = normalize(v + l);

    float nDotL = clamp(dot(n, l), 0.0, 1.0);
    float nDotV = clamp(dot(n, v), 0.0, 1.0);
    float nDotH = clamp(dot(n, h), 0.0, 1.0);
    float vDotH = clamp(dot(v, h), 0.0, 1.0);

    roughness = clamp(roughness, 0.04, 1.0);
    float alpha = roughness * roughness;
    float alpha2 = alpha * alpha;
    float denom = (nDotH * nDotH) * (alpha2 - 1.0) + 1.0;
    float d = alpha2 / (3.14159265 * denom * denom);

    float k = (roughness + 1.0);
    k = (k * k) / 8.0;
    float gV = nDotV / (nDotV * (1.0 - k) + k);
    float gL = nDotL / (nDotL * (1.0 - k) + k);
    float g = gV * gL;

    float3 f0 = mix(float3(0.04), baseColorSample.rgb, metallic);
    float3 f = f0 + (1.0 - f0) * pow(clamp(1.0 - vDotH, 0.0, 1.0), 5.0);

    float3 specular = (d * g) * f / max(4.0 * nDotV * nDotL, 0.001);
    float3 kS = f;
    float3 kD = (1.0 - kS) * (1.0 - metallic);
    float3 diffuse = kD * baseColorSample.rgb / 3.14159265;

    float3 radiance = uniforms.lightColor;
    float3 color = (diffuse + specular) * radiance * nDotL;
    float3 ambient = uniforms.ambientColor * baseColorSample.rgb * ao;
    color = ambient + color + emissiveSample;

    return float4(color, baseColorSample.a * opacity);
}
