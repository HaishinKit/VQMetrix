# Encoding performance and device resources

Use sender-reported performance alongside VMAF, not as a substitute for a live load test.

## What is collected

HaishinKit.kt Example records optional `performance` data for each variant in the capture
manifest. The standalone transfer library transports the package without measuring the
encoder itself. The Mac preserves these measurements in History and HTML reports.

| Field | Meaning |
| --- | --- |
| `wallTimeMs` | Offline replay wall time, including setup, raw-frame IO/copy, queueing, output and MP4 finalization; codec disposal is excluded. |
| `firstOutputMs` | Time to the first encoded frame, including setup. |
| `throughputFps` | Output frames divided by replay wall time. |
| `realtimeSpeed` | Nominal video duration divided by replay wall time; 2× means replaying one second of media took about half a second. |
| `meanLatencyMs`, `p95LatencyMs` | Monotonic time from input queueing to observing the corresponding output, including buffering and scheduling; p95 uses nearest-rank percentile. |
| `appCpuTimeMs`, `appCpuCores` | Whole-app CPU time and CPU-time/wall-time ratio. 1.0 means one core's worth on average; it can exceed 1.0. |
| `sampledPeakMemoryBytes`, `memoryKind` | Largest observed process-memory sample. Android reports PSS; an iOS sender may report resident memory. These are not directly equivalent metrics. |
| `samples` | Elapsed time, cumulative app CPU time, process memory and OS thermal state. |
| `frameTimings` | Per-frame media PTS plus relative input/output times and latency. |

Resource samples are taken at input/output events, no more often than once per 250 ms,
plus the start and end. A stalled pipeline may have longer gaps. The observed peak is
not a guarantee of the true peak. Sampling has overhead and is part of the app workload.
The latency timestamp is taken immediately before input is queued and before MP4 output
is written. Timings include codec buffering; they are not pure hardware execution time.

## Interpret measurements correctly

The current Android Example captures a reference and then replays it through encoders.
It labels these results `mode: offlineReplay`. This is **not** a live encoder benchmark.
Live sampling, rendering, network transmission, other encoder sessions and background
work can change real-time behavior. CPU and memory cover the whole app, not just the
encoder, and exclude work in separate system codec processes or dedicated hardware.

A 30 fps stream has a new frame every 33.3 ms, but individual input-to-output latency
may exceed that while a pipelined encoder still sustains 30 fps. Look at throughput,
queue growth, missing frames and sustained latency together. An average can hide spikes.

Thermal states are OS-reported categories, not measured encoder temperatures in °C.
Android and iOS use different thresholds; do not compare their names as equivalent
physical conditions. Sustained tests are needed to observe thermal throttling.

## Cross-platform schema

`performance.schemaVersion` is 1. `platform` is `android`, `ios` or `macos`; `mode` is
`offlineReplay` or `live`. Times are milliseconds relative to a monotonic session start.
Memory counts are bytes. Per-frame PTS is microseconds on the same timeline as frame-map.
Unavailable CPU/memory/sample fields may be omitted; absence is not a zero measurement.

The Android Example implements this collector. An iOS producer is not included yet,
but can send the same optional fields using VideoToolbox callbacks and native resource
APIs. The Mac accepts this common schema and does not infer missing measurements.
Older packages without performance metadata continue to evaluate normally.

## Read in the app

Open History after evaluation. **Sender performance** lists each variant's processing
speed, p95 latency, average app CPU, observed memory peak and thermal-state changes.
Expand **Performance timeline** for latency, process-memory and CPU time-series charts.
The HTML report exports a per-variant summary and latency graphs alongside VMAF.

## Platform references

- [Android MediaCodec metrics](https://developer.android.com/reference/android/media/MediaCodec#getMetrics())
- [Android thermal status](https://developer.android.com/reference/android/os/PowerManager#getCurrentThermalStatus())
- [Apple VideoToolbox hardware encoder selection](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_usinghardwareacceleratedvideoencoder)
- [Apple thermal state](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property)

## Language / 言語

[English](https://haishinkit.github.io/VQMetrix/swift/documentation/vqmetrix/performancemetrics/) · [日本語](https://haishinkit.github.io/VQMetrix/ja/swift/documentation/vqmetrix/performancemetrics/)

## Local encoder statistics

The live screen, each History segment, saved JSON, and HTML reports include encoder
statistics. Older histories without statistics remain readable. Each segment starts
new counters, including when changing bitrate, profile, codec, or resolution. Search
trial measurements also retain these values in their individual run histories.

- VP8/VP9/AV1: native encode-call wall time (last, mean, maximum, and cumulative seconds),
  accepted frames, returned packets, and compressed payload bytes. Conversion, copying,
  validation, failed calls, and flushing time are excluded; drained output is counted.
- H.264/HEVC: submission-to-encoded-output wall time, including asynchronous queueing
  and scheduling. This is not the same measurement as a native software encode call.

Timing uses a monotonic clock. `timedFrameCount` is the mean's denominator. Cumulative
per-frame times may overlap for asynchronous encoders and are not total run wall time.
Neither scope is CPU utilization, power consumption, or end-to-end playback latency.

## Live FPS and pipeline delay

Frame delivery shows nominal FPS, actual mixer input FPS, decoded output FPS over the last second, mean segment output FPS, and mean/maximum mixer-arrival-to-decoded latency. Latency includes queueing after mixer output, conversion, encoding, decoding, and main-actor delivery. Capture before mixer output and network delivery are excluded. Live output FPS drops to zero after a second without decoded frames; completed runs keep their end-of-segment snapshot.

History, JSON, and HTML retain frames over one nominal frame interval, pending frames (including the mixer queue), observed peak pending frames, and actual mixer drops. Peak pending is observed at frame events and periodic samples; it is not a guarantee of the instantaneous peak. Startup FPS uses the observed portion of the first second.

Latency above one interval is not by itself a dropped frame or a realtime failure: pipelined codecs can sustain the nominal FPS with greater per-frame latency. Compare FPS, pending queue growth, actual drops and evaluated frames together. Offline search is labeled offline throughput and does not establish live performance.
