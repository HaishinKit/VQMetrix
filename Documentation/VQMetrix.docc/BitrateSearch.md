# Estimate bitrate for a target VMAF

Find a confirmed bitrate candidate for a fixed sample and an arbitrary mean VMAF target.

Available starting in VQMetrix 1.2.0.

## Run a search

Select a video file or camera, then choose codec, profile, and output resolution.
Expand **Estimate bitrate for target VMAF**, set the target (0–100, including decimals),
minimum/maximum bitrate, precision, sample duration, and maximum trial count.
Choose **Estimate bitrate**. **Use estimate** copies the confirmed candidate into the encoding settings.
The target is a mean across evaluated frames; individual frames can score lower.

A file sample uses the beginning of the selected video, up to 30 seconds. A camera
sample is recorded once in ProRes 422 HQ, up to 10 seconds, and then reused. This is
a compressed acquisition reference, not raw-camera ground truth. Acquisition may
omit frames when the writer is busy; every trial must evaluate every frame of the
resulting fixed file. The current camera capture preset is 640×480 at 30 fps;
actual device output may vary. Audio is excluded.

## Interpret the estimate

The search checks the lower and upper bounds, then refines the passing/failing
bracket while reserving one trial for an independent confirmation. Only complete
trials with matching frame counts and no dropped/unmatched frames are accepted.
If confirmation fails, a trial fails, or the search is cancelled, no estimate is given.
If the upper bound fails, the result is **target not reached within the range**.
If the lower bound passes and confirms, lower rates remain unexplored. A trial-limit
result still requires confirmation, but may have a wider bracket than the requested precision.

The estimate is the lowest observed passing candidate that also passed confirmation.
VMAF need not vary monotonically with bitrate; this bounded search does not prove a
global minimum. Different content, models, profiles, resolutions, and encoder behavior
can change the result. Use representative samples and review difficult scenes visually.

Trials replay offline with backpressure to avoid evaluation drops. Their execution
time and score latency do not represent real-time encoding load. Target bitrate is
an encoder request; actual encoded payload bitrate can differ, especially for short
clips. The estimate excludes container, audio, protocol overhead, bandwidth variation,
and delivery losses. Allow appropriate headroom when choosing live-stream settings.

## History and reports

History retains the search target, range, precision, trial limit, fixed settings,
all completed attempts, final confirmation, and reference SHA-256. The parent result
shows the confirmed trial's timeline, or the last completed trial if no estimate was
produced. HTML reports include the attempts and saved target line. Changing the
current target does not change a saved search target.

The results folder contains `reference.mov`, per-trial results under `trials/`,
`live-summary.json`, and `history.json`. Reference recordings remain on disk until
you remove the result folder; consider storage and privacy when recording a camera.

Starting in 1.3.0, select the VMAF model before searching. Every candidate and confirmation keeps that model. See <doc:EvaluationModels>.

## Language / 言語

[English](https://haishinkit.github.io/VQMetrix/swift/documentation/vqmetrix/bitratesearch/) · [日本語](https://haishinkit.github.io/VQMetrix/ja/swift/documentation/vqmetrix/bitratesearch/)
