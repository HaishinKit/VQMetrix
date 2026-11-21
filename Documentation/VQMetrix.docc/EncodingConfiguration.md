# Profiles and output resolution

Choose a codec, profile, target bitrate, and output resolution before measuring.
During a run, choose new values and use **Apply changes**. The current encoder is
drained, its result is saved as a segment, and the next segment uses a new encoder.
The input timeline continues across segments.

## Profiles

H.264 supports Baseline, Main, and High. HEVC (H.265) supports Main and Main 10.
Level selection is automatic. Availability depends on VideoToolbox and the Mac;
an unsupported setting fails the measurement rather than being reported as a
successful fallback. The app checks the encoded configuration record and output
dimensions, and saves actual profile and dimensions in each segment report.

This is an **8-bit SDR capture/decode pipeline**. Choosing HEVC Main 10 changes
the requested encoded profile; it does not add HDR or recover precision absent from
the input. VMAF v1 then evaluates an upscaled, 10-bit representation; v0.6.1 keeps 8-bit source-size evaluation. See <doc:EvaluationModels>.

## Resolution and aspect ratio

**Source** retains the input dimensions. Other choices fit the source aspect ratio
within 1920×1080, 1280×720, 960×540, 854×480, 640×360, or 320×180. Dimensions are
rounded down to even numbers. For example, a 4:3 source at 720p produces 960×720,
not a stretched 1280×720 frame. A preset may upscale a smaller source; it cannot
create additional source detail. The actual result is shown in History.

Before VMAF evaluation, the decoded output is resized back to the **source dimensions**
using VideoToolbox normal scaling. For v1, both matched images are then scaled to a short side of 1080. For v0.6.1, the reference stays at its original size. In both cases,
loss introduced by downscaling remains part of the comparison. The resampling method
can affect scores and may differ from FFmpeg or a viewer's scaler. Compare runs with
the same reference dimensions, model, and evaluation method; scores from different
native resolutions are not interchangeable.

History JSON records requested settings, actual encoded size/profile, reference size,
and the evaluation scaling method. HTML reports include output dimensions. Histories
from 1.0.0/1.0.1 remain readable and default to Main and Source; missing actual dimensions
are shown as unknown.

See [Netflix's VMAF FAQ](https://github.com/Netflix/vmaf/blob/master/resource/doc/faq.md)
and [Apple's profile-level documentation](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_profilelevel).

## Language / 言語

[English](https://haishinkit.github.io/VQMetrix/swift/documentation/vqmetrix/encodingconfiguration/) · [日本語](https://haishinkit.github.io/VQMetrix/ja/swift/documentation/vqmetrix/encodingconfiguration/)
