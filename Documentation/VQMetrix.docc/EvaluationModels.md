# Choose a VMAF model

VQMetrix 1.4.0 offers two explicitly identified SDR models, using libvmaf 3.2.0.

| Selection | Model identifier | Evaluation |
| --- | --- | --- |
| VMAF v1 (default) | `vmaf_v1.0.16_3d0h` | 1080p / 3H; short side 1080, aspect ratio preserved; 10-bit samples |
| VMAF v0.6.1 | `vmaf_v0.6.1` | Original source dimensions; 8-bit samples, matching earlier VQMetrix releases |

Set **VMAF model** before a local measurement or bitrate search. A run keeps that model;
encoding settings can still change between segments. Search candidates and confirmation
always use the same model. The Receive screen uses the same selection: each upload
snapshots the model when accepted, so later changes do not affect queued work.
An idempotent retry refers to the original job, including its original model.

## Precision and scaling

The capture, decode, and transfer pipeline remains 8-bit SDR. For v1, both images are
matched at source size, converted and resized with VideoToolbox Normal scaling into
10-bit bi-planar YUV at a short side of 1080, then unpacked as 10-bit planar YUV420.
This follows the v1 recommendation to evaluate SDR at 10-bit precision; it does not
recover lost precision, add HDR, or preserve native 10-bit input detail.
CAMBI receives actual encoding width, height, and profile bit depth where known.
Its encode-size options require at least 180×150; choose a larger output or v0.6.1
for smaller encodes. v1 evaluation supports aspect ratios up to 4:1.

Upscaling a low-resolution sample does not create source detail. v1's display sizing
and extra features increase evaluation cost; real-time evaluation may skip frames
on a busy Mac. Bitrate search uses offline backpressure and rejects incomplete trials.

## Compare like with like

Scores and bitrate estimates from different models or preprocessing are not directly
interchangeable. A target of 90 can imply a different bitrate after changing the model.
Re-run representative samples rather than treating old results as v1 results.
History and HTML reports retain model identifiers. Per-segment summaries also record
evaluation resolution and bit depth. Histories and queued jobs from older versions
remain associated with v0.6.1 and are not recalculated automatically.

See [Netflix's v1 model documentation](https://github.com/Netflix/vmaf/blob/v3.2.0/resource/doc/models_v1.md).
The app does not select phone, HFR, 4K, or HDR models automatically.

## Language / 言語

[English](https://haishinkit.github.io/VQMetrix/swift/documentation/vqmetrix/evaluationmodels/) · [日本語](https://haishinkit.github.io/VQMetrix/ja/swift/documentation/vqmetrix/evaluationmodels/)
