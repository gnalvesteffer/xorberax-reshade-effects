// Xorberax AGX Tonemap
// A compact, filmic tonemap inspired by AGX contrast shaping.

#include "ReShade.fxh"

uniform float AGX_EXPOSURE <
    ui_label = "Exposure";
    ui_min = 0.0;
    ui_max = 4.0;
    ui_step = 0.01;
> = 1.0;

uniform float AGX_CONTRAST <
    ui_label = "Contrast";
    ui_min = 0.5;
    ui_max = 2.0;
    ui_step = 0.01;
> = 1.0;

uniform float AGX_SATURATION <
    ui_label = "Saturation";
    ui_min = 0.0;
    ui_max = 2.0;
    ui_step = 0.01;
> = 1.0;

uniform float AGX_WHITE <
    ui_label = "White Point";
    ui_min = 0.5;
    ui_max = 4.0;
    ui_step = 0.01;
> = 1.0;

texture ColorInputTex : COLOR;
sampler ColorInput { Texture = ColorInputTex; };

struct VSOUT
{
    float4 vpos : SV_Position;
    float2 uv : TEXCOORD0;
};

VSOUT FullscreenVS(uint id : SV_VertexID)
{
    VSOUT o;
    o.uv = id.xx == uint2(2, 1) ? -1.0.xx : 1.0.xx;
    o.vpos = float4(o.uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return o;
}

float3 srgb_encode(float3 x)
{
    float3 lo = x * 12.92;
    float3 hi = 1.055 * pow(saturate(x), 1.0 / 2.4) - 0.055;
    return lerp(hi, lo, step(x, 0.0031308));
}

float3 agx_curve(float3 x)
{
    x = max(x, 0.0);
    float3 a = x * (x * (1.35 * AGX_CONTRAST) + 0.05);
    x = a / (a + 0.27);
    return x;
}

float4 AGXTonemapPS(VSOUT i) : SV_Target0
{
    float3 col = tex2D(ColorInput, i.uv).rgb;
    col *= AGX_EXPOSURE;

    // Mild color desaturation to preserve the AGX feel while keeping it robust.
    float lum = dot(col, float3(0.2126, 0.7152, 0.0722));
    col = lerp(lum.xxx, col, AGX_SATURATION);

    // AGX-inspired filmic shape and white limit.
    col = agx_curve(col) / max(agx_curve(AGX_WHITE.xxx), 0.0001);

    // Final display gamma encode.
    col = srgb_encode(col);
    return float4(col, 1.0);
}

technique XorberaxAGXTonemap
{
    pass
    {
        VertexShader = FullscreenVS;
        PixelShader = AGXTonemapPS;
    }
}
