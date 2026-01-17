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

static inline float sampleShadowPCF(depth2d_array<float, access::sample> shadowMap,
                                    sampler shadowSampler,
                                    float4 shadowPosition,
                                    uint lightIndex,
                                    float bias,
                                    float invShadowMapSize);

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
    float3 worldPos;
    float3 viewNormal;
    float3 viewTangent;
    float3 viewBitangent;
} ColorInOut;

typedef struct
{
    float4 position [[position]];
} ShadowInOut;

typedef struct
{
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
} VolumeVertex;

typedef struct
{
    float4 position [[position]];
    float3 viewPos;
    float3 viewNormal;
    float3 localPos;
} VolumeOut;

typedef struct
{
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
} FloorVertex;

typedef struct
{
    float4 position [[position]];
    float3 viewPos;
    float3 worldPos;
    float3 viewNormal;
} FloorOut;

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

    float4 worldPos = uniforms.modelMatrix * skinnedPosition;
    float4 viewPos = uniforms.modelViewMatrix * skinnedPosition;
    out.position = uniforms.projectionMatrix * viewPos;
    out.viewPos = viewPos.xyz;
    out.worldPos = worldPos.xyz;

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

vertex ShadowInOut shadowVertexShader(Vertex in [[stage_in]],
                                      constant ShadowUniforms & shadowUniforms [[ buffer(BufferIndexShadowUniforms) ]],
                                      constant float4x4 *jointMatrices [[ buffer(BufferIndexJointMatrices) ]])
{
    ShadowInOut out;

    float4 position = float4(in.position, 1.0);

    float4 skinnedPosition = float4(0.0);
    float4 weights = in.jointWeights;
    if (weights.x + weights.y + weights.z + weights.w < 0.0001) {
        weights = float4(1.0, 0.0, 0.0, 0.0);
    }

    skinnedPosition += weights.x * (jointMatrices[in.jointIndices.x] * position);
    skinnedPosition += weights.y * (jointMatrices[in.jointIndices.y] * position);
    skinnedPosition += weights.z * (jointMatrices[in.jointIndices.z] * position);
    skinnedPosition += weights.w * (jointMatrices[in.jointIndices.w] * position);

    float4 worldPos = shadowUniforms.modelMatrix * skinnedPosition;
    out.position = shadowUniforms.lightViewProjectionMatrix * worldPos;

    return out;
}

vertex VolumeOut volumeVertexShader(VolumeVertex in [[stage_in]],
                                    constant VolumeUniforms & uniforms [[ buffer(BufferIndexVolumeUniforms) ]])
{
    VolumeOut out;
    float4 viewPos = uniforms.modelViewMatrix * float4(in.position, 1.0);
    out.position = uniforms.projectionMatrix * viewPos;
    out.viewPos = viewPos.xyz;
    out.viewNormal = normalize((uniforms.modelViewMatrix * float4(in.normal, 0.0)).xyz);
    out.localPos = in.position;
    return out;
}

fragment float4 volumeFragmentShader(VolumeOut in [[stage_in]],
                                     constant VolumeUniforms & uniforms [[ buffer(BufferIndexVolumeUniforms) ]])
{
    float3 v = normalize(-in.viewPos);
    float softness = max(uniforms.params.z, 0.01);
    float viewFactor = pow(clamp(1.0 - abs(dot(in.viewNormal, v)), 0.0, 1.0), softness);

    float height = clamp(in.localPos.z, 0.0, 1.0);
    float axialFade = smoothstep(1.0, 0.0, height);

    float alpha = uniforms.params.w * axialFade * viewFactor;
    float3 color = uniforms.color.rgb * uniforms.color.w;
    return float4(color * alpha, alpha);
}

vertex FloorOut floorVertexShader(FloorVertex in [[stage_in]],
                                  constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]])
{
    FloorOut out;
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    float4 viewPos = uniforms.modelViewMatrix * float4(in.position, 1.0);
    out.position = uniforms.projectionMatrix * viewPos;
    out.viewPos = viewPos.xyz;
    out.worldPos = worldPos.xyz;
    out.viewNormal = normalize((uniforms.modelViewMatrix * float4(in.normal, 0.0)).xyz);
    return out;
}

fragment float4 floorFragmentShader(FloorOut in [[stage_in]],
                                    constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                                    constant LightData *lights [[ buffer(BufferIndexLights) ]],
                                    depth2d_array<float, access::sample> shadowMap [[ texture(TextureIndexShadowMap) ]])
{
    constexpr sampler shadowSampler(coord::normalized,
                                    filter::linear,
                                    address::clamp_to_edge);

    float3 albedo = float3(0.18, 0.18, 0.2);
    float3 n = normalize(in.viewNormal);
    float3 v = normalize(-in.viewPos);
    float nDotV = clamp(dot(n, v), 0.0, 1.0);

    float3 color = float3(0.0);
    float debugShadow = 1.0;
    uint lightCount = min(uniforms.lightCount, (uint)MaxLights);
    for (uint i = 0; i < lightCount; i++) {
        LightData light = lights[i];
        float intensity = light.position.w;
        if (intensity <= 0.0001) {
            continue;
        }

        float3 lightPos = light.position.xyz;
        float3 lightDir = normalize(light.direction.xyz);
        float3 toLight = lightPos - in.viewPos;
        float distance = length(toLight);
        float3 l = distance > 0.0001 ? (toLight / distance) : lightDir;
        float nDotL = clamp(dot(n, l), 0.0, 1.0);
        if (nDotL <= 0.0) {
            continue;
        }

        float cosTheta = dot(lightDir, normalize(-l));
        float outerCos = light.direction.w;
        float innerCos = light.color.w;
        float spot = smoothstep(outerCos, innerCos, cosTheta);
        if (spot <= 0.0001) {
            continue;
        }

        float attenuationPower = max(uniforms.padding0.w, 0.0);
        float safeDistance = max(distance, 0.0001);
        float attenuation = 1.0 / max(pow(safeDistance, attenuationPower), 0.01);
        float3 radiance = light.color.rgb * intensity * attenuation * spot;

        float shadow = 1.0;
        if (light.shadowParams.x > 0.5) {
            float bias = light.shadowParams.y + light.shadowParams.z * (1.0 - nDotL);
            float4 shadowPos = light.shadowMatrix * float4(in.worldPos, 1.0);
            shadow = sampleShadowPCF(shadowMap, shadowSampler, shadowPos, i, bias, light.shadowParams.w);
            debugShadow = min(debugShadow, shadow);
        }
        float shadowStrength = clamp(uniforms.padding0.z, 0.0, 1.0);
        shadow = mix(1.0, shadow, shadowStrength);

        color += albedo * radiance * nDotL * shadow;
    }

    float ambientShadow = mix(1.0, debugShadow, clamp(uniforms.padding0.z, 0.0, 1.0) * 0.6);
    float3 ambient = uniforms.ambientColor.rgb * albedo * 0.8 * ambientShadow;
    color = ambient + color;

    return float4(color, 1.0);
}

fragment float4 fragmentShader(ColorInOut in [[stage_in]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                               constant LightData *lights [[ buffer(BufferIndexLights) ]],
                               texture2d<half> baseColorMap [[ texture(TextureIndexBaseColor) ]],
                               texture2d<half> normalMap [[ texture(TextureIndexNormal) ]],
                               texture2d<half> metallicMap [[ texture(TextureIndexMetallic) ]],
                               texture2d<half> roughnessMap [[ texture(TextureIndexRoughness) ]],
                               texture2d<half> aoMap [[ texture(TextureIndexAmbientOcclusion) ]],
                               texture2d<half> emissiveMap [[ texture(TextureIndexEmissive) ]],
                               texture2d<half> opacityMap [[ texture(TextureIndexOpacity) ]],
                               depth2d_array<float, access::sample> shadowMap [[ texture(TextureIndexShadowMap) ]])
{
    constexpr sampler colorSampler(mip_filter::linear,
                                   mag_filter::linear,
                                   min_filter::linear);
    constexpr sampler shadowSampler(coord::normalized,
                                    filter::linear,
                                    address::clamp_to_edge);

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
    float nDotV = clamp(dot(n, v), 0.0, 1.0);

    roughness = clamp(roughness, 0.04, 1.0);
    float alpha = roughness * roughness;
    float alpha2 = alpha * alpha;
    float k = (roughness + 1.0);
    k = (k * k) / 8.0;
    float gV = nDotV / (nDotV * (1.0 - k) + k);
    float3 f0 = mix(float3(0.04), baseColorSample.rgb, metallic);

    float3 color = float3(0.0);
    float minShadow = 1.0;
    uint lightCount = min(uniforms.lightCount, (uint)MaxLights);
    for (uint i = 0; i < lightCount; i++) {
        LightData light = lights[i];
        float intensity = light.position.w;
        if (intensity <= 0.0001) {
            continue;
        }

        float3 lightPos = light.position.xyz;
        float3 lightDir = normalize(light.direction.xyz);
        float3 toLight = lightPos - in.viewPos;
        float distance = length(toLight);
        float3 l = distance > 0.0001 ? (toLight / distance) : lightDir;
        float3 h = normalize(v + l);
        float nDotL = clamp(dot(n, l), 0.0, 1.0);
        if (nDotL <= 0.0) {
            continue;
        }

        float cosTheta = dot(lightDir, normalize(-l));
        float outerCos = light.direction.w;
        float innerCos = light.color.w;
        float spot = smoothstep(outerCos, innerCos, cosTheta);
        if (spot <= 0.0001) {
            continue;
        }

        float attenuationPower = max(uniforms.padding0.w, 0.0);
        float safeDistance = max(distance, 0.0001);
        float attenuation = 1.0 / max(pow(safeDistance, attenuationPower), 0.01);
        float3 radiance = light.color.rgb * intensity * attenuation * spot;

        float nDotH = clamp(dot(n, h), 0.0, 1.0);
        float vDotH = clamp(dot(v, h), 0.0, 1.0);

        float denom = (nDotH * nDotH) * (alpha2 - 1.0) + 1.0;
        float d = alpha2 / (3.14159265 * denom * denom);

        float gL = nDotL / (nDotL * (1.0 - k) + k);
        float g = gV * gL;

        float3 f = f0 + (1.0 - f0) * pow(clamp(1.0 - vDotH, 0.0, 1.0), 5.0);

        float3 specular = (d * g) * f / max(4.0 * nDotV * nDotL, 0.001);
        float3 kS = f;
        float3 kD = (1.0 - kS) * (1.0 - metallic);
        float3 diffuse = kD * baseColorSample.rgb / 3.14159265;

        float shadow = 1.0;
        if (light.shadowParams.x > 0.5) {
            float bias = light.shadowParams.y + light.shadowParams.z * (1.0 - nDotL);
            float4 shadowPos = light.shadowMatrix * float4(in.worldPos, 1.0);
            shadow = sampleShadowPCF(shadowMap, shadowSampler, shadowPos, i, bias, light.shadowParams.w);
        }
        float shadowStrength = clamp(uniforms.padding0.z, 0.0, 1.0);
        shadow = mix(1.0, shadow, shadowStrength);
        minShadow = min(minShadow, shadow);

        color += (diffuse + specular) * radiance * nDotL * shadow;
    }

    float ambientShadow = mix(1.0, minShadow, clamp(uniforms.padding0.z, 0.0, 1.0) * 0.4);
    float3 ambient = uniforms.ambientColor.rgb * baseColorSample.rgb * ao * ambientShadow;
    color = ambient + color + emissiveSample;

    return float4(color, baseColorSample.a * opacity);
}

static inline float sampleShadowPCF(depth2d_array<float, access::sample> shadowMap,
                                    sampler shadowSampler,
                                    float4 shadowPosition,
                                    uint lightIndex,
                                    float bias,
                                    float invShadowMapSize)
{
    float3 proj = shadowPosition.xyz / shadowPosition.w;
    if (proj.z <= 0.0 || proj.z >= 1.0) {
        return 1.0;
    }
    float2 uv = float2(proj.x * 0.5 + 0.5, 0.5 - 0.5 * proj.y);
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return 1.0;
    }

    float2 texel = float2(invShadowMapSize);
    float sum = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 offset = float2(x, y) * texel;
            float depth = shadowMap.sample(shadowSampler, uv + offset, lightIndex);
            sum += depth >= (proj.z - bias) ? 1.0 : 0.0;
        }
    }
    return sum * (1.0 / 9.0);
}
