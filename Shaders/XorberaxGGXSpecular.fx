/*
Xorberax - GGX Specular Approximation

A lightweight, screen-space GGX-style specular highlight pass for ReShade.
It is intentionally pragmatic: it tries to emulate a microfacet highlight,
while staying stable and portable in setups without a full PBR pipeline.

This version is designed as a real highlight layer, not a full BRDF system.
It uses local contrast and a roughness estimate to approximate a GGX-like lobe,
which works well for cloth, armor, skin sheen, and metallic highlights in a
screen-space post process.
*/

#include "ReShade.fxh"

uniform float fStrength <
    ui_label = "Strength";
    ui_tooltip = "Overall strength of the GGX-style highlight.";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
> = 0.50;

uniform float fRoughness <
    ui_label = "Roughness";
    ui_tooltip = "Higher roughness broadens the highlight and softens the specular lobe.";
    ui_type = "slider";
    ui_min = 0.05;
    ui_max = 1.5;
    ui_step = 0.01;
> = 0.55;

uniform float fIntensity <
    ui_label = "Intensity";
    ui_tooltip = "How bright the highlight gets in lit areas.";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 3.0;
    ui_step = 0.01;
> = 1.20;

uniform float fFresnel <
    ui_label = "Fresnel";
    ui_tooltip = "Adds edge-based highlight strength to make specular shimmer more believable.";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
> = 0.85;

uniform float fShadowCutoff <
    ui_label = "Shadow Cutoff";
    ui_tooltip = "Amount of shadowing before specular is suppressed.";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
> = 0.20;

uniform float fEdgeBoost <
    ui_label = "Edge Boost";
    ui_tooltip = "Boosts highlight response near material edges and contrast transitions.";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
> = 0.45;

uniform float3 cSpecTint <
    ui_label = "Specular Tint";
    ui_tooltip = "Color tint applied to the highlight.";
    ui_type = "color";
> = float3(1.0, 0.95, 0.90);

float3 rgb2hsv(float3 c)
{
    float4 K = float4(0.0, -1.0/3.0, 2.0/3.0, -1.0);
    float4 p = c.g < c.b ? float4(c.bg, K.wz) : float4(c.gb, K.xy);
    float4 q = c.r < p.x ? float4(p.x, p.y, p.z, c.r) : float4(c.r, p.y, p.z, p.x);
    float d = q.x - min(q.w, q.y);
    float e = 1e-10;
    float h = abs(q.z + (q.w - q.y) / (6.0 * d + e));
    float s = d / (q.x + e);
    float v = q.x;
    return float3(h, s, v);
}

float3 hsv2rgb(float3 c)
{
    float h = c.x;
    float s = c.y;
    float v = c.z;
    float3 rgb = saturate(abs(frac(h + float3(0.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0) - 1.0);
    rgb = v * lerp(float3(1.0, 1.0, 1.0), rgb, s);
    return rgb;
}

float GetRoughnessApprox(float2 uv)
{
    float2 px = ReShade::PixelSize;
    float3 center = tex2D(ReShade::BackBuffer, uv).rgb;
    float3 up = tex2D(ReShade::BackBuffer, uv + float2(0.0, px.y)).rgb;
    float3 right = tex2D(ReShade::BackBuffer, uv + float2(px.x, 0.0)).rgb;
    float3 down = tex2D(ReShade::BackBuffer, uv - float2(0.0, px.y)).rgb;
    float3 left = tex2D(ReShade::BackBuffer, uv - float2(px.x, 0.0)).rgb;

    float lumC = dot(center, float3(0.2126, 0.7152, 0.0722));
    float lumU = dot(up, float3(0.2126, 0.7152, 0.0722));
    float lumR = dot(right, float3(0.2126, 0.7152, 0.0722));
    float lumD = dot(down, float3(0.2126, 0.7152, 0.0722));
    float lumL = dot(left, float3(0.2126, 0.7152, 0.0722));

    float edge = abs(lumU - lumD) + abs(lumR - lumL);
    return clamp(0.25 + edge * 12.0 + fRoughness * 0.25, 0.15, 1.5);
}

float edgeFactor(float2 uv, float2 px, float lum)
{
    float3 c0 = tex2D(ReShade::BackBuffer, uv + float2(px.x, 0.0)).rgb;
    float3 c1 = tex2D(ReShade::BackBuffer, uv - float2(px.x, 0.0)).rgb;
    float3 c2 = tex2D(ReShade::BackBuffer, uv + float2(0.0, px.y)).rgb;
    float3 c3 = tex2D(ReShade::BackBuffer, uv - float2(0.0, px.y)).rgb;

    float l0 = dot(c0, float3(0.2126, 0.7152, 0.0722));
    float l1 = dot(c1, float3(0.2126, 0.7152, 0.0722));
    float l2 = dot(c2, float3(0.2126, 0.7152, 0.0722));
    float l3 = dot(c3, float3(0.2126, 0.7152, 0.0722));

    float diff = abs(l0 - l1) + abs(l2 - l3) + abs(lum - l0) + abs(lum - l2);
    return saturate(diff * 2.5);
}

float4 PS_GGXSpecular(float4 position : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float4 original = tex2D(ReShade::BackBuffer, uv);
    float3 base = original.rgb;
    float luma = dot(base, float3(0.2126, 0.7152, 0.0722));

    // Approximate a directional lighting term from local contrast and luminance.
    float2 px = ReShade::PixelSize;
    float localLight = 0.0;
    for (int y = -1; y <= 1; ++y)
    {
        for (int x = -1; x <= 1; ++x)
        {
            float2 off = float2(x, y) * px;
            float3 sampleCol = tex2D(ReShade::BackBuffer, uv + off).rgb;
            float sLum = dot(sampleCol, float3(0.2126, 0.7152, 0.0722));
            localLight += sLum;
        }
    }
    localLight /= 9.0;

    float lightMask = saturate((localLight - luma) * 1.5 + 0.35);
    float shadowMask = saturate(1.0 - step(fShadowCutoff, luma));
    float roughness = GetRoughnessApprox(uv);

    // GGX-like normalization, but kept lightweight and screen-space.
    float a = max(0.05, roughness * roughness);
    float a2 = a * a;
    float nDotV = saturate(0.7 + lightMask * 0.3);
    float ndotl = saturate(lightMask * 1.2 + 0.25);

    // Approximate normal distribution as a broad lobe.
    float alpha = max(0.05, 1.0 - roughness);
    float ggx = pow(saturate(1.0 - abs(ndotl - nDotV)), 1.5 / max(a2, 0.05));
    float fresnel = pow(1.0 - nDotV, 2.5) * fFresnel;
    float edgeSpec = edgeFactor(uv, px, luma) * fEdgeBoost;

    float baseSpec = ggx * fresnel * (1.0 + edgeSpec) * fIntensity;
    float finalSpec = saturate(baseSpec * lightMask * fStrength * (1.0 - shadowMask * 0.6 + 0.2));

    float3 specColor = cSpecTint * (0.7 + finalSpec * 1.6);
    float3 finalColor = base + specColor * finalSpec;

    return float4(finalColor, original.a);
}

technique XorberaxGGXSpecular
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_GGXSpecular;
    }
}
