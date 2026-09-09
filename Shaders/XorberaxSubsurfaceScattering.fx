/*
Xorberax - Subsurface Scattering

A lightweight, screen-space approximation of subsurface scattering for soft materials
such as skin, wax, cloth, and translucent plastic. It works by blurring the scene color
with a depth-aware kernel, then reintroducing that soft, color-bleeding result as a subtle
scatter layer.

This is intentionally stylized and conservative: it uses a depth-aware blur instead of a
full real-time diffusion solve, so it stays cheap and stable in games without a dedicated
scattering pass. Highlights remain protected by default so bright surfaces do not turn
into a muddy haze.
*/

#include "ReShade.fxh"

uniform float fStrength <
    ui_label = "Strength";
    ui_tooltip = "How much the soft scattering layer contributes to the final image.";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
> = 0.10;

uniform float fRadius <
    ui_label = "Radius";
    ui_tooltip = "Sampling radius used for the diffusion blur. Higher values create a softer, wider scatter.";
    ui_type = "slider";
    ui_min = 0.5;
    ui_max = 10.0;
    ui_step = 0.05;
> = 1.08;

uniform float fFalloff <
    ui_label = "Falloff";
    ui_tooltip = "Controls how quickly the scattering kernel falls off with distance from the center pixel.";
    ui_type = "slider";
    ui_min = 0.5;
    ui_max = 12.0;
    ui_step = 0.05;
> = 1.92;

uniform float fScatterColorBleed <
    ui_label = "Color Bleed";
    ui_tooltip = "Extra warmth/softness in the scattered color so the effect feels like light bleeding through a translucent layer.";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 1.5;
    ui_step = 0.01;
> = 0.62;

uniform float fHighlightProtect <
    ui_label = "Highlight Protect";
    ui_tooltip = "Luma threshold above which the scatter layer starts to fade out to preserve bright specular areas.";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
> = 0.23;

uniform float fEdgeThreshold <
    ui_label = "Depth Edge Threshold";
    ui_tooltip = "Maximum depth difference allowed before the sample is rejected from the blur, reducing bleeding across silhouettes.";
    ui_type = "slider";
    ui_min = 0.0001;
    ui_max = 0.05;
    ui_step = 0.0005;
> = 0.0087;

uniform float fMixBias <
    ui_label = "Mix Bias";
    ui_tooltip = "Adds a little extra blend in darker areas to keep the effect from looking too weak on shadowed surfaces.";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
> = 0.41;

uniform float fShadowTransmission <
    ui_label = "Shadow Transmission";
    ui_tooltip = "Extra light transmission in shadowed skin and cloth, helping the subsurface layer read through darker areas.";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
> = 1.61;

uniform float fClothScatterBoost <
    ui_label = "Cloth Scatter Boost";
    ui_tooltip = "Boosts the scatter response for darker, cloth-like materials so garments read as more translucent.";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
> = 0.84;

uniform bool bUseSkinTint <
    ui_label = "Warm Skin Tint";
    ui_tooltip = "Applies a slightly warm scatter tint to help skin-like materials feel more organic.";
> = true;

uniform float3 cTint <
    ui_label = "Scatter Tint";
    ui_tooltip = "Custom tint used by the scattering layer when warm tint is enabled.";
    ui_type = "color";
> = float3(1.0, 0.85, 0.75);

float3 ApplySubsurface(float3 baseColor, float3 scatterColor, float scatterWeight)
{
    float3 finalColor = lerp(baseColor, scatterColor, scatterWeight);
    return saturate(finalColor);
}

float4 PS_Subsurface(float4 position : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float4 original = tex2D(ReShade::BackBuffer, texcoord);
    float3 baseColor = original.rgb;
    float baseDepth = ReShade::GetLinearizedDepth(texcoord);

    const float3 lumaWeights = float3(0.2126, 0.7152, 0.0722);
    float baseLum = dot(baseColor, lumaWeights);

    float3 blurred = float3(0.0, 0.0, 0.0);
    float totalWeight = 0.0;

    int radius = max(1, int(fRadius));
    float sampleStep = max(0.5, fRadius / max(1.0, float(radius)));

    for (int y = -radius; y <= radius; ++y)
    {
        for (int x = -radius; x <= radius; ++x)
        {
            float2 offset = float2(x, y) * ReShade::PixelSize * sampleStep;
            float2 sampleUV = texcoord + offset;

            float3 sampleColor = tex2D(ReShade::BackBuffer, sampleUV).rgb;
            float sampleDepth = ReShade::GetLinearizedDepth(sampleUV);

            float dist2 = dot(float2(x, y), float2(x, y));
            float depthDelta = abs(sampleDepth - baseDepth);
            float depthMask = 1.0 - saturate(depthDelta / max(fEdgeThreshold, 1e-5));
            float gaussian = exp(-dist2 / max(fFalloff, 0.01));
            float weight = gaussian * depthMask;

            blurred += sampleColor * weight;
            totalWeight += weight;
        }
    }

    float3 blurredColor = blurred / max(totalWeight, 1e-5);

    float highlightMask = 1.0 - smoothstep(fHighlightProtect, fHighlightProtect + 0.4, baseLum);
    float darkMask = saturate(1.0 - baseLum * 1.35);
    float shadowTransmission = saturate((0.85 - baseLum) / 0.85);
    float clothMask = saturate((1.0 - baseLum) / 1.0);

    float avgLum = dot(blurredColor, float3(0.2126, 0.7152, 0.0722));
    float lightFromNeighbors = saturate((avgLum - baseLum) * 1.8 + shadowTransmission * 0.8);

    float darkBoost = 1.0 + fMixBias * darkMask;
    float transmissionBoost = 1.0 + fShadowTransmission * shadowTransmission;
    float clothScatterBoost = 1.0 + fClothScatterBoost * clothMask;

    float3 scatterTint = bUseSkinTint ? cTint : float3(1.0, 1.0, 1.0);
    float r = baseColor.r;
    float g = baseColor.g;
    float b = baseColor.b;
    float brightness = max(r, max(g, b));
    float warmRed = saturate((r - g * 0.65) * 1.7 + (r - b * 0.65) * 1.4);
    float skinHueGate = saturate((r > g * 0.82 && r > b * 0.80) ? 1.0 : 0.0);
    float chromaGate = saturate((brightness - min(r, min(g, b))) * 2.5);
    float skinMask = warmRed * skinHueGate * chromaGate;
    skinMask *= smoothstep(0.05, 1.0, brightness);
    skinMask = saturate(skinMask * 1.8);

    float3 transmittedColor = blurredColor * (0.5 + 1.2 * shadowTransmission + 0.8 * lightFromNeighbors);
    float3 warmTintedColor = transmittedColor * lerp(float3(1.0, 1.0, 1.0), scatterTint, saturate(0.8 + fScatterColorBleed * 0.9 + shadowTransmission * 0.7));
    transmittedColor = lerp(transmittedColor, warmTintedColor, skinMask);
    transmittedColor = lerp(baseColor, transmittedColor, saturate((1.0 - baseLum) * 0.9 + lightFromNeighbors));

    float softMask = saturate(fStrength * highlightMask * darkBoost * transmissionBoost * clothScatterBoost);
    float transmissionWeight = softMask * (0.35 + 1.0 * shadowTransmission + 0.8 * lightFromNeighbors + 0.5 * clothMask);
    float3 finalColor = lerp(baseColor, transmittedColor, saturate(transmissionWeight));

    // Keep bright highlights and clean silhouettes from being flattened by the scatter.
    float brightProtectMask = 1.0 - smoothstep(0.68, 1.0, baseLum);
    float silhouetteProtect = 1.0 - saturate(abs(baseDepth - 1.0) * 8.0);
    finalColor = lerp(finalColor, baseColor, 1.0 - brightProtectMask * (0.6 + 0.4 * silhouetteProtect));

    return float4(finalColor, original.a);
}

technique XorberaxSubsurfaceScattering
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_Subsurface;
    }
}
