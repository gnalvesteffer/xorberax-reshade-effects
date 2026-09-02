/*
Xorberax - Pseudo Per-Object Motion Blur
Uses Launchpad motion vectors and depth/normal heuristics.
*/

// MB_SAMPLES must be a compile-time constant (not a uniform) so the tap
// loop below can be fully unrolled - this is required because texture
// derivative/gradient instructions are illegal inside a loop whose
// iteration count the compiler can't resolve at compile time.
// Adjust this via ReShade's "preprocessor definitions" UI, not a slider.
#ifndef MB_SAMPLES
    #define MB_SAMPLES 16
#endif

uniform float MB_STRENGTH <
ui_label = "Strength";
ui_tooltip = "Multiplier for blur length";

> = 1.0;

uniform float MB_DEPTH_THRESHOLD <
ui_label = "Depth Threshold";
ui_min = 0.0;
ui_max = 1.0;
ui_tooltip = "Depth difference tolerance for weighting";

> = 0.02;

uniform float MB_NORMAL_POWER <
ui_label = "Normal Falloff";
ui_min = 0.1;
ui_max = 64.0;
ui_tooltip = "Higher reduces cross-object blending using normals";

> = 8.0;

uniform float MB_MOTION_SIM_POWER <
ui_label = "Motion Similarity";
ui_min = 0.1;
ui_max = 64.0;
ui_tooltip = "Higher reduces blending across differing motion";

> = 8.0;

uniform float MB_MAX_RADIUS_PIX <
ui_label = "Max Radius (px)";
ui_min = 1.0;
ui_max = 1024.0;

> = 128.0;

uniform float MB_JITTER <
ui_label = "Jitter";
ui_min = 0.0;
ui_max = 4.0;
ui_tooltip = "Adds noise to sample positions to reduce banding";

> = 1.0;

uniform int MB_DISTRIBUTION <
ui_type = "combo";
ui_items = "Linear\0Centered\0Quartic\0";
ui_label = "Sample Distribution";

> = 1;

uniform int MB_DEBUG <
ui_type = "combo";
ui_items = "Off\0Motion Vectors\0Weight Mask\0";
ui_label = "Debug";

> = 0;

texture DepthInputTex : DEPTH;
sampler DepthInput { Texture = DepthInputTex; };

uniform float FRAMETIME < source = "frametime"; >;

#include ".\MartysMods\mmx_global.fxh"
#include ".\MartysMods\mmx_math.fxh"
#include ".\MartysMods\mmx_depth.fxh"
#include ".\MartysMods\mmx_deferred.fxh"

texture ColorInputTex : COLOR;

sampler ColorInput
{
Texture = ColorInputTex;
};

struct VSOUT
{
float4 vpos : SV_Position;
float2 uv : TEXCOORD0;
};

VSOUT FullscreenVS(uint id : SV_VertexID)
{
    VSOUT o;
    FullscreenTriangleVS(id, o.vpos, o.uv);
    return o;
}

float sample_weight(
float centerDepth,
float sampleDepth,
float3 nCenter,
float3 nSample)
{
float depthDifference = abs(sampleDepth - centerDepth);


float depthWeight = exp(
    -depthDifference /
    max(MB_DEPTH_THRESHOLD, 0.000001)
);

float normalDot = saturate(
    dot(nCenter, nSample)
);

float normalWeight = pow(
    normalDot,
    MB_NORMAL_POWER
);

return depthWeight * normalWeight;


}

// Local copy of Marty's LAUNCHPAD.fx showmotion() debug visualizer -
// that function lives only in the .fx technique file, not in any of
// the shared .fxh headers, so it isn't visible to this shader.
float3 xorberax_showmotion(float2 motion)
{
    float angle = atan2(motion.y, motion.x);
    float dist = length(motion);
    float3 rgb = saturate(
        3 * abs(2 * frac(angle / 6.283 + float3(0, -1.0 / 3.0, 1.0 / 3.0)) - 1) - 1
    );
    return lerp(0.5, rgb, saturate(log(1 + dist * 3000.0 / FRAMETIME)));
}

void PseudoPerObjectMBPS(
VSOUT IN,
out float4 OUT : SV_Target0)
{
float2 uv = IN.uv;


float3 centerColor = tex2D(
    ColorInput,
    uv
).rgb;


float2 vel_uv = Deferred::get_motion(uv);

float2 pix =
    vel_uv *
    BUFFER_SCREEN_SIZE.xy;

float pixLen = length(pix);


if (pixLen < 0.000001)
{
    OUT = float4(centerColor, 1.0);
    return;
}


float clampedLength = min(
    pixLen * MB_STRENGTH,
    MB_MAX_RADIUS_PIX
);


float2 dir_pix =
    pix *
    (clampedLength / pixLen);


float2 dir_uv =
    dir_pix /
    BUFFER_SCREEN_SIZE.xy;


float centerDepth =
    Depth::get_linear_depth(uv);

float3 centerNormal =
    Deferred::get_normals(uv);


if (MB_DEBUG == 1)
{
    OUT = float4(
        xorberax_showmotion(
            vel_uv *
            BUFFER_SCREEN_SIZE.xy
        ),
        1.0
    );

    return;
}


float3 accum =
    centerColor;

float wsum =
    1.0;


// MB_SAMPLES is a preprocessor define (compile-time constant), so this
// loop bound is fully known at compile time - the compiler can unroll
// based on the `MB_SAMPLES` define. No attribute is required here.
for (int i = 0; i < MB_SAMPLES; i++)
{
    float fi =
        float(i) /
        float(max(1, MB_SAMPLES - 1));


    float t;


    if (MB_DISTRIBUTION == 0)
    {
        t =
            (fi - 0.5) *
            2.0;
    }
    else if (MB_DISTRIBUTION == 1)
    {
        t =
            (fi - 0.5) *
            2.0;
    }
    else
    {
        float centered =
            (fi - 0.5) *
            2.0;

        float signValue;

        if (centered < 0.0)
            signValue = -1.0;
        else
            signValue = 1.0;

        t =
            pow(abs(centered), 4.0) *
            signValue;
    }


    float2 jitterCoord =
        uv * 12.9898 +
        float2(
            fi * 78.233,
            fi * 78.233
        );

    float jitterDot =
        dot(
            jitterCoord,
            float2(
                127.1,
                311.7
            )
        );

    float jitterNoise =
        frac(
            sin(jitterDot) *
            43758.5453
        );

    float jitter =
        (jitterNoise - 0.5) *
        MB_JITTER /
        float(MB_SAMPLES);


    float2 sampleUV =
        uv +
        dir_uv *
        (t + jitter);


    if (!Math::inside_screen(sampleUV))
        continue;


    float sampleDepth =
        Depth::get_linear_depth(sampleUV);

    float3 sampleNormal =
        Deferred::get_normals(sampleUV);


    float w =
        sample_weight(
            centerDepth,
            sampleDepth,
            centerNormal,
            sampleNormal
        );


    float2 velSample =
        Deferred::get_motion(sampleUV);

    float motionDiff =
        length(
            velSample -
            vel_uv
        );

    float motionWeight =
        exp(
            -motionDiff *
            MB_MOTION_SIM_POWER
        );

    w *= motionWeight;


    float3 sampleColor =
        tex2Dlod(
            ColorInput,
            float4(sampleUV, 0, 0)
        ).rgb;


    accum +=
        sampleColor *
        w;

    wsum +=
        w;
}


float3 result =
    accum /
    max(wsum, 0.000001);


if (MB_DEBUG == 2)
{
    float2 debugOffset =
        dir_uv * 0.5;

    float debugDepth =
        Depth::get_linear_depth(
            uv + debugOffset
        );

    float depthDifference =
        abs(
            debugDepth -
            centerDepth
        );

    float maskValue =
        exp(
            -depthDifference /
            max(
                MB_DEPTH_THRESHOLD,
                0.000001
            )
        );

    OUT = float4(
        maskValue,
        maskValue,
        maskValue,
        1.0
    );

    return;
}


OUT = float4(
    result,
    1.0
);


}

technique XorberaxPseudoPerObjectMotionBlur
<
ui_label = "Xorberax: Pseudo Per-Object Motion Blur";

>

{
    // Match DLSS5_Feed: Launchpad only computes the MotionVectorsTex / normals
    // when a consumer requests them via the shared PredicationBuffer.
    IPC_REQUEST_FEATURE(MARTYSMODS_IPC_FEATURE_OPTICALFLOW | MARTYSMODS_IPC_FEATURE_NORMALS)

    pass
    {
        VertexShader = FullscreenVS;
        PixelShader = PseudoPerObjectMBPS;
    }
}
