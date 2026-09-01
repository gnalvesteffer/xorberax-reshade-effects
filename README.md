# xorberax ReShade Effects

This folder contains custom ReShade effect files for use with Bannerlord and related game setups.

## Included

- `Shaders/XorberaxPseudoPerObjectMotionBlur.fx`
  - Pseudo per-object motion blur driven by Launchpad motion vectors.
  - Uses motion vector direction and magnitude, plus depth/normal similarity weighting to reduce cross-object bleeding.
  - Best used with Launchpad / motion-vector-producing preprocessing enabled.

## Notes

- These effects are intended for ReShade shader packaging and experimentation.
- For best results, run this effect after motion-vector generation is available in the pipeline.
- The motion blur is a pseudo-object approach, not true object ID masking, so it works best when pixels have distinct motion, depth, or normal separation.

## Install

Copy the `.fx` files from this folder into your ReShade shader directory, then enable the effect in the ReShade UI.
