/*
Xorberax - Sky Ambient & Rim Light

Infers a crude "hemisphere" environmental light from the frame itself:
- Downsamples the top band of the screen (assumed sky/background) into a
  tiny mipped render target, then reads its smallest mip as a single
  averaged "sky color".
- Does the same for the bottom band as a stand-in "ground/bounce color".
- Blends between the two per-pixel using the surface normal's vertical
  component, giving a cheap hemisphere fill light for scenes that only
  ship a single directional sun color with no sky/ambient term.
- Within each band, the lookup position varies with the normal's up/down
  tilt (zenith-ish vs horizon-ish, and mirrored for ground/nadir) and
  with the pixel's own screen column, so sky/ground color variation
  (e.g. brighter near the sun, a darker cloud bank on one side) comes
  through instead of a single flat averaged blob. "Sky/Ground Detail"
  controls how much of that spatial variation survives the mip blur -
  turned all the way up it collapses back to one flat average.
- Adds a rim light in the same inferred color, driven by how edge-on the
  surface normal is to the camera.

This is a heuristic, NOT a real environment probe: there is no scene
geometry or camera-orientation data available to a screen-space effect,
so "sky" here just means "top band of the current frame" and "up" just
means the vertical axis of whatever space Launchpad's normals are in.
That is usually close enough to true world-up to read correctly, but it
will drift on heavy camera roll or extreme up/down look angles.

CONFIRMED AGAINST LAUNCHPAD SOURCE (MartysMods_LAUNCHPAD.fx / mmx_camera.fxh):
Deferred::get_normals(uv) reads a real per-pixel view-space normal that
Launchpad reconstructs from depth (via Camera::uv_to_proj), refines with
a best-fit/weighted cross-product scheme, bilaterally smooths, and
optionally perturbs from local texture/albedo contrast when the user
sets Launchpad's own "Normal Map Mode" to Textured. No extra work is
needed here to get the smoothed/textured version - Deferred::get_normals
always returns whatever Launchpad's own settings currently produce.

Camera::uv_to_proj builds position.y straight from uv.y with no separate
camera-rotation matrix applied, and it comes out NEGATIVE at the top of
the screen and POSITIVE at the bottom - i.e. this is a Y-DOWN view space,
so "faces upward" corresponds to normal.y < 0, not > 0. The hemisphere
blend below accounts for that. The Z sign is not relied on directly -
rim uses abs(normal.z), which is orientation-agnostic either way.

The "Flip Sky/Ground Axis" toggle is kept as a manual override for the
one thing this can't see: camera roll. Launchpad's view space still
assumes an unrolled camera, so on games/scenes with heavy banked camera
roll the up/down split can drift - flip (or eventually blend by an
actual roll angle, if you ever expose one) to correct for that case.
*/

// XORB_CAPTURE_SIZE must be a compile-time constant (not a uniform)
// because it sets the dimensions of the capture render targets below -
// texture Width/Height cannot depend on a runtime-adjustable uniform.
// Adjust this via ReShade's "preprocessor definitions" UI, not a slider.
#ifndef XORB_CAPTURE_SIZE
    #define XORB_CAPTURE_SIZE 64
#endif

// log2(64) + 1 = 7 mip levels, so the smallest mip is a single texel -
// i.e. the full average color of whatever was captured into mip 0.
#define XORB_CAPTURE_MIPS 7
#define XORB_CAPTURE_FINAL_MIP 6.0

uniform float UI_SKY_REGION <
ui_label = "Sky Sample Height";
ui_tooltip = "Fraction of the top of the screen treated as sky/background";
ui_min = 0.05;
ui_max = 0.6;

> = 0.35;

uniform float UI_GROUND_REGION <
ui_label = "Ground Sample Height";
ui_tooltip = "Fraction of the bottom of the screen treated as ground/bounce";
ui_min = 0.05;
ui_max = 0.6;

> = 0.35;

uniform float UI_AMBIENT_STRENGTH <
ui_label = "Ambient Fill Strength";
ui_tooltip = "Overall multiplier for the inferred hemisphere fill light";
ui_min = 0.0;
ui_max = 3.0;

> = 0.01;

uniform float UI_SKY_BRIGHTNESS_RESPONSE <
ui_label = "Sky Brightness Response";
ui_tooltip = "How strongly the captured sky/ground brightness scales the\nfill and rim intensity - keeps night scenes from getting a fake glow";
ui_min = 0.0;
ui_max = 8.0;

> = 2.0;

uniform float UI_SHADOW_BIAS <
ui_label = "Shadow Bias";
ui_tooltip = "Higher values concentrate the ambient fill into darker/shadowed pixels";
ui_min = 0.0;
ui_max = 6.0;

> = 2.5;

uniform float UI_HIGHLIGHT_PROTECT_START <
ui_label = "Highlight Protect Start";
ui_tooltip = "Scene luma at which the ambient fill starts fading out.\nRaise this if brightly sunlit ground still looks washed/hazed";
ui_min = 0.0;
ui_max = 1.0;

> = 0.35;

uniform float UI_HIGHLIGHT_PROTECT_END <
ui_label = "Highlight Protect End";
ui_tooltip = "Scene luma above which the ambient fill is fully removed";
ui_min = 0.0;
ui_max = 1.0;

> = 0.65;

uniform float UI_RIM_STRENGTH <
ui_label = "Rim Strength";
ui_min = 0.0;
ui_max = 4.0;

> = 1.0;

uniform float UI_RIM_POWER <
ui_label = "Rim Falloff";
ui_tooltip = "Higher narrows the rim to more edge-on surfaces";
ui_min = 0.1;
ui_max = 16.0;

> = 5.0;

uniform float UI_RIM_DETAIL_BLEND <
ui_label = "Rim Detail Blend";
ui_tooltip = "How much rim lighting follows high-frequency normal detail (0 = ignore detail, 1 = fully follow)";
ui_min = 0.0;
ui_max = 1.0;

> = 0.5;

uniform float UI_RIM_INWARD_STRENGTH <
ui_label = "Rim Inward Strength";
ui_tooltip = "How much rim light spreads inward on object surfaces near edges";
ui_min = 0.0;
ui_max = 3.0;

> = 1.0;

uniform float UI_RIM_INWARD_POWER <
ui_label = "Rim Inward Power";
ui_tooltip = "Exponent controlling falloff of inward spread (higher keeps it tighter to edges)";
ui_min = 0.1;
ui_max = 4.0;

> = 1.0;

uniform float UI_RIM_INWARD_MAX <
ui_label = "Rim Inward Max";
ui_tooltip = "Maximum multiplier applied by inward spread (1.0 = no additional rim)";
ui_min = 1.0;
ui_max = 4.0;

> = 2.0;

uniform float UI_RIM_DEPTH_EDGE_THRESHOLD <
ui_label = "Rim Depth Edge Threshold";
ui_tooltip = "Depth gradient threshold to consider a pixel part of a silhouette edge";
ui_min = 0.0001;
ui_max = 0.05;

> = 0.002;

uniform float UI_RIM_DEPTH_EDGE_SOFTNESS <
ui_label = "Rim Edge Softness";
ui_tooltip = "Softness around the depth-edge threshold for smoother rim falloff";
ui_min = 0.0;
ui_max = 0.02;

> = 0.300;

uniform float UI_RIM_DEPTH_SCALE <
ui_label = "Rim Depth Scale";
ui_tooltip = "Scale the measured depth gradient so rim applies to more/less of the depth (0.1 = subtle, 10 = very broad)";
ui_min = 0.1;
ui_max = 10.0;

> = 1.0;

uniform float UI_RIM_EDGE_SPREAD <
ui_label = "Rim Edge Spread";
ui_tooltip = "How far around a silhouette to sample depth for a softer rim (higher = softer/wider)";
ui_min = 0.5;
ui_max = 8.0;

> = 2.0;

uniform float UI_RIM_DEPTH_BLUR_SCALE <
ui_label = "Rim Depth Blur Scale";
ui_tooltip = "How aggressively the edge mask spreads across pixels of similar depth (higher = more inward spread)";
ui_min = 0.0;
ui_max = 200.0;

> = 100.0;

uniform int UI_RIM_EDGE_SAMPLES <
ui_label = "Rim Edge Samples";
ui_tooltip = "Number of neighbor samples to average for depth-edge (higher = smoother but slower)";
ui_min = 1;
ui_max = 16;

> = 8;

uniform int UI_RIM_BLEND_MODE <
ui_type = "combo";
ui_items = "Add\0SoftLight\0Screen\0Overlay\0";
ui_label = "Rim Blend Mode";

> = 0;

uniform float UI_CAPTURE_DETAIL_MIP <
ui_label = "Sky/Ground Detail";
ui_tooltip = "Mip level read from the sky/ground capture. Low = more real\nspatial variation (can get noisy on a small capture). High = one\nflat averaged color, same as before this slider existed.";
ui_min = 0.0;
ui_max = XORB_CAPTURE_FINAL_MIP;

> = 10.0;

uniform float UI_SKY_DEPTH_CUTOFF <
ui_label = "Sky Depth Cutoff";
ui_tooltip = "Linear depth above which pixels are treated as skybox and\nexcluded from receiving fill/rim (their own normals are usually unreliable)";
ui_min = 0.8;
ui_max = 1.0;

> = 0.98;

uniform bool UI_FLIP_UP_AXIS <
ui_label = "Flip Sky/Ground Axis";
ui_tooltip = "Enable if sky/ground colors read as inverted for this game";

> = false;

uniform int UI_DEBUG <
ui_type = "combo";
ui_items = "Off\0Sky Capture\0Ground Capture\0Shadow Mask\0Rim Mask\0Normals\0Highlight Protect\0";
ui_label = "Debug";

> = 0;

uniform bool UI_MIRROR_REAR <
ui_label = "Mirror Rear Lighting";
ui_tooltip = "Enable mirrored sky/ground sampling for back-facing surfaces";

> = true;

uniform float UI_NORMAL_DETAIL <
ui_label = "Normal Detail";
ui_tooltip = "0 = flatten normals, 1 = neutral, >1 = amplify small normal variation for detail (pebbles, cracks)";
ui_min = 0.0;
ui_max = 3.0;

> = 0.300;

texture DepthInputTex : DEPTH;
sampler DepthInput { Texture = DepthInputTex; };

#include ".\MartysMods\mmx_global.fxh"
#include ".\MartysMods\mmx_math.fxh"
#include ".\MartysMods\mmx_depth.fxh"
#include ".\MartysMods\mmx_deferred.fxh"

texture ColorInputTex : COLOR;

sampler ColorInput
{
Texture = ColorInputTex;
};

texture XorbSkyCaptureTex
{
Width = XORB_CAPTURE_SIZE;
Height = XORB_CAPTURE_SIZE;
Format = RGBA16F;
MipLevels = XORB_CAPTURE_MIPS;
};

sampler XorbSkyCapture { Texture = XorbSkyCaptureTex; };

texture XorbGroundCaptureTex
{
Width = XORB_CAPTURE_SIZE;
Height = XORB_CAPTURE_SIZE;
Format = RGBA16F;
MipLevels = XORB_CAPTURE_MIPS;
};

sampler XorbGroundCapture { Texture = XorbGroundCaptureTex; };

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

float xorberax_luma(float3 c)
{
    return dot(c, float3(0.299, 0.587, 0.114));
}

// Squishes the top UI_SKY_REGION fraction of the real frame across the
// whole small capture target. Later mip levels of this target then give
// a cheap running average of "what color is the sky/background".
void SkyCapturePS(
VSOUT IN,
out float4 OUT : SV_Target0)
{
float2 srcUV =
    float2(
        IN.uv.x,
        saturate(IN.uv.y * UI_SKY_REGION)
    );

OUT = float4(tex2D(ColorInput, srcUV).rgb, 1.0);
}

// Same idea, but for the bottom UI_GROUND_REGION fraction of the frame.
void GroundCapturePS(
VSOUT IN,
out float4 OUT : SV_Target0)
{
float2 srcUV =
    float2(
        IN.uv.x,
        saturate(1.0 - UI_GROUND_REGION + IN.uv.y * UI_GROUND_REGION)
    );

OUT = float4(tex2D(ColorInput, srcUV).rgb, 1.0);
}

void XorbAmbientRimPS(
VSOUT IN,
out float4 OUT : SV_Target0)
{
float2 uv = IN.uv;


float3 centerColor =
    tex2D(
        ColorInput,
        uv
    ).rgb;


float3 normal =
    Deferred::get_normals(uv);

if (UI_FLIP_UP_AXIS)
    normal.y = -normal.y;


float depth =
    Depth::get_linear_depth(uv);


// Launchpad's reconstructed view space is Y-down (see header comment),
// so "faces upward" is normal.y < 0 - flip the sign here, not the bias.
// 1.0 = fully sky-facing, 0.0 = fully ground-facing.
float skyFactorRaw =
    saturate(-normal.y * 0.5 + 0.5);
// Apply the Normal Detail contrast to the sky blend so small normal
// deviations can affect whether a pixel reads more sky or ground.
float skyFactor =
    saturate((skyFactorRaw - 0.5) * UI_NORMAL_DETAIL + 0.5);


// How strongly this normal points up/down, independent of the sky/ground
// blend weight above - used to pick WHERE within the captured band to
// sample, so a steep upward tilt reads nearer the zenith end of the sky
// capture and a shallow one reads nearer the horizon end (mirrored for
// ground/nadir). Apply a user-controlled contrast so small micro-normal
// deviations (pebbles, cracks) can influence the sampling when desired.
float upAmountRaw =
    saturate(-normal.y);

float downAmountRaw =
    saturate(normal.y);

// Contrast: 0 => flattened (0.5), 1 => identity, >1 => amplified detail
float detailContrast = UI_NORMAL_DETAIL;
float upAmount =
    saturate((upAmountRaw - 0.5) * detailContrast + 0.5);

float downAmount =
    saturate((downAmountRaw - 0.5) * detailContrast + 0.5);

// U reuses this pixel's own screen column as a cheap proxy for "what's
// the sky/ground doing over this part of the view" - not a real azimuth
// lookup, but enough to catch e.g. sun-side vs shadow-side sky variation
// without reprojecting a direction back into the capture's screen space.
float2 skyLookupUV =
    float2(uv.x, 1.0 - upAmount);

float2 groundLookupUV =
    float2(uv.x, downAmount);

// If requested, mirror the sampled sky/ground horizontally for back-facing
// surfaces to approximate lighting coming from behind the camera.
if (UI_MIRROR_REAR && normal.z > 0.0)
{
    skyLookupUV.x = 1.0 - skyLookupUV.x;
    groundLookupUV.x = 1.0 - groundLookupUV.x;
}

float3 skyColor =
    tex2Dlod(
        XorbSkyCapture,
        float4(skyLookupUV, 0, UI_CAPTURE_DETAIL_MIP)
    ).rgb;

float3 groundColor =
    tex2Dlod(
        XorbGroundCapture,
        float4(groundLookupUV, 0, UI_CAPTURE_DETAIL_MIP)
    ).rgb;


if (UI_DEBUG == 1)
{
    OUT = float4(skyColor, 1.0);
    return;
}

if (UI_DEBUG == 2)
{
    OUT = float4(groundColor, 1.0);
    return;
}

if (UI_DEBUG == 5)
{
    OUT = float4(normal * 0.5 + 0.5, 1.0);
    return;
}


float3 ambientRaw =
    lerp(
        groundColor,
        skyColor,
        skyFactor
    );

float ambientLuma =
    max(
        xorberax_luma(ambientRaw),
        0.0001
    );

// Normalize by max channel, not luma, to get the tint. Luma weights
// green heavily and blue barely at all (0.114), so a saturated blue
// sky (low luma, high blue channel) would blow up past 1.0 per-channel
// if normalized by luma - max-channel normalization keeps every tint
// channel in [0,1], so it can't run away regardless of hue.
float ambientMaxChannel =
    max(
        max(ambientRaw.r, ambientRaw.g),
        max(ambientRaw.b, 0.0001)
    );

float3 ambientTint =
    ambientRaw /
    ambientMaxChannel;

// A dark captured sky (night, indoors) should barely contribute any
// fill/rim at all, even at high Ambient Fill Strength - this scalar
// is what makes that automatic.
float skyBrightnessScalar =
    saturate(
        ambientLuma *
        UI_SKY_BRIGHTNESS_RESPONSE
    );


float centerLuma =
    xorberax_luma(centerColor);

float shadowMask =
    pow(
        saturate(1.0 - centerLuma),
        max(UI_SHADOW_BIAS, 0.0001)
    );

if (UI_DEBUG == 3)
{
    OUT = float4(shadowMask.xxx, 1.0);
    return;
}


// Hard cutoff on top of the soft shadowMask curve above - this is what
// actually stops already-sunlit, evenly-bright ground (which otherwise
// still passes a fair amount through a pure pow() curve) from getting
// a global wash. shadowMask alone couldn't distinguish "genuinely dark"
// from "just not maximally bright" on flat, uniformly-lit terrain.
float highlightProtect =
    1.0 -
    smoothstep(
        UI_HIGHLIGHT_PROTECT_START,
        max(UI_HIGHLIGHT_PROTECT_END, UI_HIGHLIGHT_PROTECT_START + 0.0001),
        centerLuma
    );

if (UI_DEBUG == 6)
{
    OUT = float4(highlightProtect.xxx, 1.0);
    return;
}


// Sharpen the rim by applying normal-detail contrast to the normal.z
// magnitude before computing the rim falloff.
float normalZRaw = saturate(abs(normal.z));
float normalZ = saturate((normalZRaw - 0.5) * UI_NORMAL_DETAIL + 0.5);
float rimFactor =
    pow(
        1.0 - normalZ,
        max(UI_RIM_POWER, 0.0001)
    );

if (UI_DEBUG == 4)
{
    OUT = float4(rimFactor.xxx, 1.0);
    return;
}


// Fade the whole effect out on skybox pixels - their depth reads near
// the far plane, and their normals (if any) are usually meaningless.
float skyboxFade =
    1.0 -
    smoothstep(
        UI_SKY_DEPTH_CUTOFF,
        1.0,
        depth
    );


float fillAmount =
    UI_AMBIENT_STRENGTH *
    skyBrightnessScalar *
    shadowMask *
    highlightProtect *
    skyboxFade;

float rimAmount =
    UI_RIM_STRENGTH *
    rimFactor *
    skyBrightnessScalar *
    skyboxFade;

// Reduce rim on large smooth surfaces by measuring high-frequency normal
// variation via screen derivatives. This makes clothing/characters keep
// their fine rim while big smooth walls/boulders get less overdrawn rim.
float3 ddxN = ddx(normal);
float3 ddyN = ddy(normal);
float normalFreq = length(ddxN) + length(ddyN);
// Scale normalFreq by the user detail control so its influence respects UI_NORMAL_DETAIL.
float detailMask = saturate(normalFreq * 20.0 * max(UI_NORMAL_DETAIL, 0.001));
rimAmount *= lerp(1.0, detailMask, saturate(UI_RIM_DETAIL_BLEND));
// Preserve base rim amount so we can apply inward spreading separately.
float rimAmountBase = rimAmount;

// Depth-edge mask: sample neighboring linear depth values and average
// their absolute differences to create a softer, spreadable edge mask.
float2 px = ddx(IN.uv);
float2 py = ddy(IN.uv);
// Fallback if ddx/ddy of UV is zero for some drivers.
float2 approxPix = (length(px) > 0.0 || length(py) > 0.0) ? (px + py) * 0.5 : float2(1.0/1024.0, 1.0/1024.0);
float2 uvStep = approxPix * UI_RIM_EDGE_SPREAD;


// Multi-sample neighbor depth average. Samples are placed in a circle
// so larger `UI_RIM_EDGE_SAMPLES` + `UI_RIM_EDGE_SPREAD` produce
// progressively softer edges instead of a hard outline.
int samples = clamp(UI_RIM_EDGE_SAMPLES, 1, 16);
float sumDiff = 0.0;
for (int i = 0; i < samples; ++i)
{
    float fi = (float)i;
    float ang = 6.28318530718 * (fi / (float)samples);
    float2 off = float2(cos(ang), sin(ang)) * uvStep;
    float nd = Depth::get_linear_depth(uv + off);
    sumDiff += abs(depth - nd);
}
float depthDiffAvg = sumDiff / (float)samples;
float depthGrad = depthDiffAvg * UI_RIM_DEPTH_SCALE;

float edgeLow = max(UI_RIM_DEPTH_EDGE_THRESHOLD - UI_RIM_DEPTH_EDGE_SOFTNESS, 0.0);
float edgeHigh = UI_RIM_DEPTH_EDGE_THRESHOLD + UI_RIM_DEPTH_EDGE_SOFTNESS;
float edgeMask = smoothstep(edgeLow, edgeHigh, depthGrad);

// Soften the mask further by applying a mild power curve when spread is large
float spreadSoft = saturate((UI_RIM_EDGE_SPREAD - 1.0) / 7.0);
edgeMask = pow(edgeMask, lerp(1.0, 0.7, spreadSoft));

// Neighbor-based inward softening: sample surrounding depths and
// compute how many neighbors look like silhouette relative to this
// pixel. This spreads edge energy inward across same-depth pixels.
int samples2 = clamp(UI_RIM_EDGE_SAMPLES, 1, 16);
float sumW = 0.0;
float sumM = 0.0;
float maxStepLen = max(length(uvStep), 1e-6);
for (int i = 0; i < samples2; ++i)
{
    float fi = (float)i;
    float ang = 6.28318530718 * (fi / (float)samples2);
    float2 off = float2(cos(ang), sin(ang)) * uvStep;
    float nd = Depth::get_linear_depth(uv + off);
    // Use an exponential depth similarity so the UI_RIM_DEPTH_BLUR_SCALE
    // directly controls how tolerant we are to depth differences. Larger
    // UI_RIM_DEPTH_BLUR_SCALE -> more tolerant -> more inward spread.
    float depthBlurInv = 1.0 / max(UI_RIM_DEPTH_BLUR_SCALE, 1e-6);
    float depthDiff = abs(nd - depth);
    float depthSimExp = exp(-depthDiff * depthBlurInv);
    float r = length(off) / maxStepLen;
    float gw = exp(-r * r * 2.0);
    sumM += depthSimExp * gw;
    sumW += gw;
}
float neighborAvg = sumM / max(sumW, 1e-6);
// Combine center edge and neighbor similarity into a blurred mask. The
// `blurStrength` controls how much of this blurred result replaces the
// original edgeMask (0 = no blur, 1 = full blur).
float blurStrength = saturate(UI_RIM_DEPTH_BLUR_SCALE / 100.0);
float blurredMask = (edgeMask + neighborAvg) * 0.5;
edgeMask = lerp(edgeMask, blurredMask, blurStrength);

// Inward boost: increase rim on same-depth interior pixels near edges.
// The inward contribution is computed from a base rim scale (not the
// detail-masked rimAmountBase) so inward blurring remains visible even
// when the normal-detail masking reduced rimAmountBase. It still uses
// rimFactor to bias toward rim-facing surfaces.
float inwardBoost = saturate(pow(neighborAvg, max(0.0001, UI_RIM_INWARD_POWER)) * UI_RIM_INWARD_STRENGTH);
inwardBoost = min(inwardBoost, max(0.0, UI_RIM_INWARD_MAX - 1.0));
float baseRimScale = UI_RIM_STRENGTH * skyBrightnessScalar * skyboxFade;
float inwardContribution = baseRimScale * rimFactor * inwardBoost * neighborAvg;
// Combine masked base rim (respecting normal-detail masking) with
// the inward contribution, both modulated by edgeMask to keep the
// energy focused near silhouettes and similar-depth interiors.
rimAmount = (rimAmountBase * edgeMask) + (inwardContribution * edgeMask);


float3 baseWithFill = centerColor + ambientTint * fillAmount;
float3 rimContribution = ambientTint * rimAmount;

float3 finalColor;
if (UI_RIM_BLEND_MODE == 0)
{
    // Add
    finalColor = baseWithFill + rimContribution;
}
else if (UI_RIM_BLEND_MODE == 1)
{
    // SoftLight approximation per-channel
    float3 a = baseWithFill;
    float3 b = rimContribution;
    float3 res1 = a - (1.0 - 2.0 * b) * a * (1.0 - a);
    float3 res2 = a + (2.0 * b - 1.0) * (sqrt(a) - a);
    float3 mask = saturate(sign(0.5 - b)); // 1 when b < 0.5
    finalColor = lerp(res2, res1, mask);
}
else if (UI_RIM_BLEND_MODE == 2)
{
    // Screen
    finalColor = 1.0 - (1.0 - baseWithFill) * (1.0 - rimContribution);
}
else
{
    // Overlay
    float3 a = baseWithFill;
    float3 b = rimContribution;
    float3 higher = 1.0 - 2.0 * (1.0 - a) * (1.0 - b);
    float3 lower = 2.0 * a * b;
    float3 mask = saturate(sign(a - 0.5)); // 1 when a >= 0.5
    finalColor = lerp(higher, lower, 1.0 - mask);
}

OUT = float4(saturate(finalColor), 1.0);


}

technique XorberaxSkyAmbientRimLight
<
ui_label = "Xorberax: Sky Ambient & Rim Light";

>
{
    IPC_REQUEST_FEATURE(MARTYSMODS_IPC_FEATURE_NORMALS)

    pass SkyCapture
    {
        VertexShader = FullscreenVS;
        PixelShader = SkyCapturePS;
        RenderTarget = XorbSkyCaptureTex;
        GenerateMipMaps = true;
    }

    pass GroundCapture
    {
        VertexShader = FullscreenVS;
        PixelShader = GroundCapturePS;
        RenderTarget = XorbGroundCaptureTex;
        GenerateMipMaps = true;
    }

    pass Composite
    {
        VertexShader = FullscreenVS;
        PixelShader = XorbAmbientRimPS;
    }
}
