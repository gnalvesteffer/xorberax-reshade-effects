// Xorberax_BlendCapture.fx
// Blend the previously captured image (from Xorberax_Capture.fx) with the current backbuffer.
// Place this technique after other effects to composite the capture with processed image.

#include "ReShade.fxh"

// parameters
uniform float fBlendOpacity <
    ui_label = "Capture Opacity";
    ui_tooltip = "Opacity of the captured (original) image when blending. 0 = none, 1 = fully captured image.";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
> = 0.5;

uniform int iBlendMode <
    ui_label = "Blend Mode";
    ui_tooltip = "Blending mode used to combine the captured image with the current image.";
    ui_type = "combo";
    ui_items = "Normal\0Add\0Multiply\0Screen\0Overlay\0SoftLight\0HardLight\0Luma\0Color\0Hue\0Saturation\0Structure\0";
> = 0;

uniform float fStructureStrength <
    ui_label = "Structure Strength";
    ui_tooltip = "Amount of high-frequency structure/detail to restore from the captured image.";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 3.0;
    ui_step = 0.01;
> = 1.0;

// sampler for captured texture (created by Xorberax_Capture.fx)
texture texCapture { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler CaptureSampler { Texture = texCapture; };

#define LUMA float3(0.2126, 0.7152, 0.0722)

float3 BlendNormal(float3 baseCol, float3 capCol)
{
    return capCol;
}

float3 BlendAdd(float3 baseCol, float3 capCol)
{
    return saturate(baseCol + capCol);
}

float3 BlendMultiply(float3 baseCol, float3 capCol)
{
    return baseCol * capCol;
}

float3 BlendScreen(float3 baseCol, float3 capCol)
{
    return 1.0 - (1.0 - baseCol) * (1.0 - capCol);
}

float3 BlendOverlay(float3 baseCol, float3 capCol)
{
    float3 result;
    for (int i = 0; i < 3; i++) {
        float b = baseCol[i];
        float c = capCol[i];
        result[i] = b < 0.5 ? (2.0 * b * c) : (1.0 - 2.0 * (1.0 - b) * (1.0 - c));
    }
    return result;
}

float3 BlendSoftLight(float3 b, float3 c)
{
    float3 r;
    for (int i = 0; i < 3; i++) {
        float bb = b[i];
        float cc = c[i];
        if (cc <= 0.5)
            r[i] = bb - (1.0 - 2.0 * cc) * bb * (1.0 - bb);
        else
            r[i] = bb + (2.0 * cc - 1.0) * (sqrt(bb) - bb);
    }
    return r;
}

float3 BlendHardLight(float3 b, float3 c)
{
    float3 r;
    for (int i = 0; i < 3; i++) {
        float bb = b[i];
        float cc = c[i];
        r[i] = cc < 0.5 ? (2.0 * bb * cc) : (1.0 - 2.0 * (1.0 - bb) * (1.0 - cc));
    }
    return r;
}

float3 BlendLuma(float3 baseCol, float3 capCol)
{
    // Replace luminance of base with luminance of capture, preserve chroma
    const float3 luma = float3(0.2126, 0.7152, 0.0722);
    float baseY = dot(baseCol, luma);
    float capY = dot(capCol, luma);
    return saturate((baseCol - baseY) + capY);
}

// HSV helpers for Hue/Saturation/Color modes
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
    rgb = v * lerp(float3(1.0,1.0,1.0), rgb, s);
    return rgb;
}

float3 BlendColor(float3 baseCol, float3 capCol)
{
    // keep hue/sat from cap, luminance from base
    float3 capHSV = rgb2hsv(capCol);
    float baseY = dot(baseCol, float3(0.2126, 0.7152, 0.0722));
    float3 rgbFromCap = hsv2rgb(capHSV);
    // scale rgbFromCap to have base luminance
    float capY = dot(rgbFromCap, float3(0.2126, 0.7152, 0.0722));
    float3 outCol = rgbFromCap * (baseY / max(capY, 1e-6));
    return saturate(outCol);
}

float3 BlendHue(float3 baseCol, float3 capCol)
{
    float3 baseHSV = rgb2hsv(baseCol);
    float3 capHSV = rgb2hsv(capCol);
    float3 outHSV = float3(capHSV.x, baseHSV.y, baseHSV.z);
    return hsv2rgb(outHSV);
}

float3 BlendSaturation(float3 baseCol, float3 capCol)
{
    float3 baseHSV = rgb2hsv(baseCol);
    float3 capHSV = rgb2hsv(capCol);
    float3 outHSV = float3(baseHSV.x, capHSV.y, baseHSV.z);
    return hsv2rgb(outHSV);
}

float4 PS_Blend(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float4 cur = tex2D(ReShade::BackBuffer, texcoord);
    float4 cap = tex2D(CaptureSampler, texcoord);

    float3 blended;

    if (iBlendMode == 0) {
        blended = BlendNormal(cur.rgb, cap.rgb);
    } else if (iBlendMode == 1) {
        blended = BlendAdd(cur.rgb, cap.rgb);
    } else if (iBlendMode == 2) {
        blended = BlendMultiply(cur.rgb, cap.rgb);
    } else if (iBlendMode == 3) {
        blended = BlendScreen(cur.rgb, cap.rgb);
    } else if (iBlendMode == 4) {
        blended = BlendOverlay(cur.rgb, cap.rgb);
    } else if (iBlendMode == 5) {
        blended = BlendSoftLight(cur.rgb, cap.rgb);
    } else if (iBlendMode == 6) {
        blended = BlendHardLight(cur.rgb, cap.rgb);
    } else if (iBlendMode == 7) {
        blended = BlendLuma(cur.rgb, cap.rgb);
    } else if (iBlendMode == 8) {
        blended = BlendColor(cur.rgb, cap.rgb);
    } else if (iBlendMode == 9) {
        blended = BlendHue(cur.rgb, cap.rgb);
    } else /* if (iBlendMode == 10) */ {
        blended = BlendSaturation(cur.rgb, cap.rgb);
    }

    // Structure/detail restoration: inject high-frequency luminance from captured image
    if (iBlendMode == 11) {
        // 3x3 box blur of captured image luminance
        float2 o = ReShade::PixelSize;
        float3 sum = float3(0.0, 0.0, 0.0);
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                sum += tex2D(CaptureSampler, texcoord + float2(x, y) * o).rgb;
            }
        }
        float3 blur = sum / 9.0;
        float capY = dot(cap.rgb, LUMA);
        float blurY = dot(blur, LUMA);
        float hp = capY - blurY; // high-frequency luminance

        float curY = dot(cur.rgb, LUMA);
        float newY = curY + hp * fStructureStrength;
        float s = newY / max(curY, 1e-6);
        blended = cur.rgb * s;
    }

    // final mix between the processed image (cur) and the blended result (based on capture)
    float3 outColor = lerp(cur.rgb, blended, fBlendOpacity);

    return float4(outColor, cur.a);
}

technique Xorberax_BlendCapture_After < ui_tooltip = "Xorberax_BlendCapture_After: blends the image saved by Xorberax_Capture.fx with the current image. Place this after effects you want to mix with the original capture."; >
{
    pass {
        VertexShader = PostProcessVS;
        PixelShader = PS_Blend;
        ClearRenderTargets = true;
    }
}
