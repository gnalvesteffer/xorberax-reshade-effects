// Xorberax_Capture.fx
// Saves the current backbuffer into a persistent texture for later blending.
// Place the corresponding blend effect after other effects to composite with the captured image.

#include "ReShade.fxh"

// textures and samplers
texture texCapture { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler CaptureSampler { Texture = texCapture; };

// pixel shader: store current backbuffer into texCapture
float4 PS_Capture(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    return tex2D(ReShade::BackBuffer, texcoord);
}

technique Xorberax_Capture_Before < ui_tooltip = "Xorberax_Capture_Before: stores an unmodified copy of the current backbuffer into a texture. Place this technique before other effects to capture the original image."; >
{
    pass {
        VertexShader = PostProcessVS;
        PixelShader = PS_Capture;
        RenderTarget = texCapture;
        ClearRenderTargets = true;
    }
}
