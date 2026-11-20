# Understanding VMAF scores

Compare encoded video with a reference, then use the result alongside visual inspection.

VMAF (Video Multimethod Assessment Fusion) is Netflix's learned, full-reference video
quality metric. It compares reference frames with decoded candidate frames. A higher
score generally means the candidate is closer to the reference under the model's viewing
assumptions. It is not the percentage of pixels preserved or the percentage of viewers
who will approve the picture.

VQMetrix 1.0 uses **vmaf_v0.6.1**, normally on a **0–100** scale. Other models and options
can have different assumptions or ranges. Record the model and libvmaf version with results.
Even a video compared with itself need not score exactly 100.

## A practical starting guide

These bands are **VQMetrix working heuristics, not Netflix standards or perceptual guarantees**.
Their usefulness depends on content, resolution, viewing distance, model and preprocessing.

| Score | Suggested interpretation |
| --- | --- |
| 95–100 | Very high similarity. Inspect whether additional bitrate buys a useful improvement. This does not certify visually lossless video. |
| 90–<95 | High similarity; a possible quality target after checking representative content. It is not a universal streaming-service target. |
| 80–<90 | A possible practical compromise. Compression loss may become visible on close inspection or difficult scenes. |
| 70–<80 | Inspect carefully: degradation can be distracting, depending on the material and viewing conditions. |
| Below 70 | A prompt to investigate substantial differences, including compression loss or incorrect alignment/color handling. |

Do not assume 95 is indistinguishable, 90 is always sufficient, or every result below 70 is
unusable. VMAF should help choose candidates, not replace watching the video.

## A starting target for live streaming

As a VQMetrix development heuristic, start with a mean of **90 or better**, then explore
**90–95** where bandwidth and device performance allow it. This is not an industry pass/fail
standard. Prefer a stable configuration around 90 to one scoring 95 that drops frames,
overheats or accumulates delay. Inspect low-scoring scenes and performance measurements
separately; an offline replay speed result is not proof that live streaming will stay stable.

## Read the whole result

1. Compare candidates generated from the **same reference frames**, dimensions, timeline,
   color interpretation and model. Different sources or models are not a fair bitrate comparison.
2. Inspect the **timeline and low-scoring scenes**, not just the mean. A high mean can hide
   short, distracting defects. Check the minimum and the report's evaluation completeness.
3. Consider bitrate, file size, encode cost and the intended display. Screen text, fast motion,
   animation, camera noise and static scenes can behave differently at the same bitrate.
4. Inspect reference and decoded previews. If timing, frame count or color conversion is wrong,
   a low score may indicate a faulty comparison. Partial runs describe only evaluated frames.

A damaged reference can still produce a high score: VMAF measures fidelity to that reference,
not the absolute beauty or original capture quality of the scene.

## What VQMetrix does not score

The macOS live measurement encodes and decodes locally. Uploaded samples are evaluated from
stored reference/candidate pairs. These paths do not measure audio quality, network delivery,
end-to-end latency, rebuffering, or the complete viewer experience. Missing evaluation frames
are recorded separately; do not interpret a high VMAF mean as proof that no frames were lost.

The default v0.6.1 model was trained for HDTV/living-room viewing assumptions. Evaluating a
mobile-originated clip with it does not automatically select a phone-specific model.

## Sources

- [Netflix VMAF project](https://github.com/Netflix/vmaf)
- [Netflix v0 model assumptions](https://github.com/Netflix/vmaf/blob/master/resource/doc/models_v0.md)
- [Netflix VMAF FAQ](https://github.com/Netflix/vmaf/blob/master/resource/doc/faq.md)
- [Netflix: VMAF, The Journey Continues](https://netflixtechblog.com/vmaf-the-journey-continues-44b51ee9ed12)

For Japanese, see <doc:UnderstandingVMAF-Japanese>.
