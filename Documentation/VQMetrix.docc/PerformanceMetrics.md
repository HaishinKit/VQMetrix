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
