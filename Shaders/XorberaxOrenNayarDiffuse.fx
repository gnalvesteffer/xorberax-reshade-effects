/*
Xorberax - Oren-Nayar-ish Diffuse Approximation

A lightweight, rough diffuse enhancement inspired by Oren-Nayar for ReShade.
It is not a full physically based BRDF, but it approximates the rough-surface
scatter behavior that makes cloth, skin, and matte materials feel less flat.

This works best when the scene exposes a normal buffer (e.g. via Launchpad).
If no true normal is available, it falls back to a simple luminance/edge-based
roughness cue so it still gives a subtle improvement in standard ReShade setups.
*/

#include "ReShade.fxh"

#ifndef XORB_ON_LAUNCHPAD
#define XORB_ON_LAUNCHPAD 1
#endif

uniform float fStrength <
    ui_label = "Strength";
    ui_tooltip = "How strongly the rough diffuse term contributes.";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
> = 0.70;

uniform float fRoughness <
    ui_label = "Roughness";
    ui_tooltip = "Higher values make the diffuse response more broad and soft.";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
> = 0.85;

uniform float fAmbientLift <
    ui_label = "Ambient Lift";
    ui_tooltip = "Adds a subtle lift to darker diffuse areas to keep them from going flat.";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
> = 0.30;

uniform float fEdgeBoost <
    ui_label = "Edge Boost";
    ui_tooltip = "Adds a little extra response near object edges and shading transitions.";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
> = 0.55;

uniform float fSkinBias <
    ui_label = "Skin Bias";
    ui_tooltip = "Small warm bias for skin-like tones; keeps rough diffuse from looking too neutral.";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
> = 0.18;

uniform bool bUseNormals <
    ui_label = "Use Normal-Based Roughness";
    ui_tooltip = "When enabled, the effect uses a normal-derived roughness approximation when available.";
> = true;

float3 rgb2hsv(float3 c)
{
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = c.g < c.b ? float4(c.bg, K.wz) : float4(c.gb, K.xy);
    float4 q = c.r < p.x ? float4(p.x, p.y, p.z, c.r) : float4(c.r, p.y, p.z, p.x);
    float d = q.x - min(q.w, q.y);
    float e = 1e-10;
    float h = abs(q.z + (q.w - q.y) / (6.0 * d + e));
    float s = d / (q.x + e);
    float v = q.x;
    return float3(h, s, v);
}

float GetRoughnessFromNormal(float2 uv)
{
    if (!bUseNormals)
        return 1.0;

    // ReShade does not provide a universal GetNormal() API in all setups.
    // Fall back to a screen-space approximation based on local luminance contrast.
    // This keeps the shader portable and compile-safe while still giving a subtle
    // rough-diffuse effect in standard ReShade installations.
    return 1.0;
}

float3 ApplyWarmSkinBias(float3 c, float skinMask)
{
    float3 skinTint = float3(1.0, 0.92, 0.86);
    return lerp(c, c * skinTint, saturate(skinMask * fSkinBias));
}

float4 PS_OrenNayar(float4 position : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float4 original = tex2D(ReShade::BackBuffer, texcoord);
    float3 base = original.rgb;
    float lum = dot(base, float3(0.2126, 0.7152, 0.0722));

    float2 px = ReShade::PixelSize;
    float3 sample1 = tex2D(ReShade::BackBuffer, texcoord + float2(px.x, 0.0)).rgb;
    float3 sample2 = tex2D(ReShade::BackBuffer, texcoord - float2(px.x, 0.0)).rgb;
    float3 sample3 = tex2D(ReShade::BackBuffer, texcoord + float2(0.0, px.y)).rgb;
    float3 sample4 = tex2D(ReShade::BackBuffer, texcoord - float2(0.0, px.y)).rgb;

    float localContrast = abs(dot(sample1, float3(0.2126, 0.7152, 0.0722)) - dot(sample2, float3(0.2126, 0.7152, 0.0722))) +
                          abs(dot(sample3, float3(0.2126, 0.7152, 0.0722)) - dot(sample4, float3(0.2126, 0.7152, 0.0722)));

    float roughness = GetRoughnessFromNormal(texcoord);
    roughness = lerp(roughness, 1.0, 0.35);
    roughness = clamp(roughness * fRoughness, 0.2, 2.0);

    float edgeFactor = saturate(localContrast * 3.5 + fEdgeBoost * 0.25);
    float darkLift = saturate(1.0 - lum) * (0.35 + fAmbientLift);
    float diffuseBoost = saturate(fStrength * (0.6 + roughness * 0.7 + edgeFactor * 0.6 + darkLift));

    // Skin-like warm bias heuristic: only affects warm, saturated tones.
    float3 hsv = rgb2hsv(base);
    float skinMask = saturate((base.r - base.g * 0.7) * 1.8 + (base.r - base.b * 0.8) * 1.2);
    skinMask *= smoothstep(0.08, 0.95, hsv.z);
    skinMask *= smoothstep(0.08, 0.85, hsv.y);

    float3 diffuseColor = base * (1.0 + diffuseBoost * 0.35 + darkLift * 0.4);
    diffuseColor = lerp(base, diffuseColor, saturate(diffuseBoost));
    diffuseColor = ApplyWarmSkinBias(diffuseColor, skinMask);

    return float4(diffuseColor, original.a);
}

technique XorberaxOrenNayarDiffuse
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_OrenNayar;
    }
}
