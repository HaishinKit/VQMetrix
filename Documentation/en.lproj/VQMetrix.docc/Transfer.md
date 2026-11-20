# Transfer protocol v1

Implemented by the Android producer and the macOS app. Enable Receive on the Mac to
accept authenticated LAN HTTP uploads, validate packages and queue VMAF evaluation.

## Upload

`POST /api/v1/runs` over LAN HTTP or HTTPS. The app accepts a base URL and appends this path.

Headers:

- `Content-Type: application/zip`
- `Content-Length`: complete package size; upload is streamed
- `Authorization: Bearer <4-digit connection code>`
- `Idempotency-Key`: run UUID, reused on retry
- `X-VQMetrix-Protocol: 1`

Use a system-trusted certificate. The client does not follow redirects or disable TLS
validation. A LAN receiver may need Android local-network permission.

A successful response uses HTTP 200, 201, or 202 and a JSON body:

```json
{"jobId":"12345678-1234-1234-1234-123456789abc","status":"queued"}
```

The job ID must be a UUID. The client records acceptance, not evaluation completion.
Errors and missing/invalid IDs do not create a success receipt. Responses are limited
to 64 KiB. A receiver should return the same job ID for a retry with the same run ID and
archive digest, or HTTP 409 if the same ID is used for different data.

## ZIP layout

Only root-level files are written:

```text
manifest.json
reference.y4m
frame-map.json
h264-500000.mp4
h264-1000000.mp4
h264-2000000.mp4
```

HEVC uses `hevc-<bitrate>.mp4`. Each package contains one codec and up to six bitrates.
A new capture gets a new UUID; all variants in a package share the exact raw input.

`manifest.json` uses schema `vqmetrix.capture.v1` and `schemaVersion: 1`:

- `runId`, ISO-8601 `createdAt`, and device manufacturer/model/API/app version
- `reference`: filename, source, width/height, FPS numerator/denominator, frame count,
  `pixelFormat: yuv420p`, bit depth 8, color range/matrix, sensor orientation, and frame-map filename
- `variants`: filename, codec, target/actual payload bitrate, codec implementation name,
  hardware-acceleration flag, dimensions, and output frame count
- `files`: filename (`path`), exact byte size, SHA-256 for every payload except the manifest itself

`frame-map.json` contains `referencePtsUs`, `captureTimestampsNs`, and `variants` (MP4
filename to presentation-time array). Synthetic inputs have no sensor timestamps.
Reference and encoded time use `floor(frameIndex * 1_000_000 / fps)` microseconds,
starting at zero. Camera samples preserve captured bytes while using a common CFR
replay timeline; the original sensor timing is retained for analysis.

Test-pattern v1 is limited-range BT.709. Unknown camera color range and matrix are
explicitly `unspecified`; the evaluator must resolve these rather than silently assume
a conversion. Compare unrotated pixel coordinates, or apply identical transformations
to both sides. Sensor orientation is presentation metadata, not a one-sided VMAF transform.

## Receiver requirements

Stream uploads to temporary storage with size limits (suggested maximum: 1 GiB compressed
and extracted). Authenticate before accepting a body. Reject duplicate ZIP entries,
absolute/nested/traversal paths, symlinks, and any filename outside the declared layout.
Validate actual extracted sizes, CRC, and SHA-256; never trust only ZIP metadata.

Validate Y4M dimensions, format and frame count, decode every candidate, and verify its
frame count and timestamp correspondence before evaluating. Preserve the original
package and settings, record validation failures, and queue VMAF outside the upload
request. Export results through the same history/report model as local runs. Future
status polling can use `GET /api/v1/jobs/<jobId>`; it is not required by the current client.

## Bonjour discovery

A receiver advertises `_vqmetrix._tcp` on the local network, using its listening port.
TXT records are `protocol=1`, `scheme=http` or `scheme=https`, and `host=MacName.local`.
Do not publish tokens or credentials in TXT records. The Android NSD browser filters
incompatible advertisements and fills the selected URL. HTTP uses the address resolved by NSD so it does not depend on system .local DNS lookup; HTTPS keeps the hostname for certificate verification. The browser never starts an upload
merely because a receiver appeared. Discovery does not establish receiver identity.

HTTP accepts .local names and local IP literals only; resolved addresses must also be
local (private, link-local or loopback, including IPv6 ULA). Redirects are disabled.
HTTP transmits video and bearer tokens without encryption and is for trusted LAN
use only. HTTPS uses the platform trust store and hostname verification.
The macOS app advertises Bonjour while Receive is enabled. Its built-in endpoint uses LAN HTTP; direct HTTPS termination is not provided.

## Desktop operation

The macOS Receive page starts and stops the listener (default port 8787). Authentication
uses a fresh 4-digit connection code for each receiving session. Enter it on the sending
device; it is not advertised by Bonjour or persisted. Five failed authentication attempts
pause all new upload authentication for 60 seconds, across connections. The listener rejects remote addresses outside private/link-local/loopback ranges.
Up to four HTTP connections and eight queued/evaluating packages are allowed. Idle upload
connections time out after 60 seconds. HTTP headers are limited to 16 KiB.

Acceptance is returned after ZIP, CRC, manifest, sizes, SHA-256 and declared frame-map
validation. The original ZIP and extracted payload remain in Application Support/VQMetrix/Uploads.
Evaluation runs serially outside the HTTP handler. Decoded count, codec, dimensions and PTS
are checked before scores are committed. Each variant appears as a settings segment in the
existing History/HTML report. Failed evaluations retain their error and any completed segments.
Invalid archives are retained separately with validation-error.txt; interrupted uploads are not
shown as accepted. Queue state survives app restart; starting reception resumes pending work.

The current evaluator accepts limited-range BT.709 SDR references, including mixer snapshots
and synthetic patterns. Unspecified camera colors fail explicitly instead of assuming a matrix.
Receiving can be stopped while accepted evaluations finish. Keep the Mac app running until
jobs finish; interrupted evaluations are retried after reception starts on the next launch.

## Optional sender performance

Each variant may include `performance` with schemaVersion 1, platform, mode, wallTimeMs,
frameCount, throughputFps, videoDurationMs and realtimeSpeed. Optional fields include
firstOutputMs, meanLatencyMs, p95LatencyMs, appCpuTimeMs, appCpuCores, memoryKind,
sampledPeakMemoryBytes, sampleIntervalMs, resource samples and frame timings.
The detailed schema and caveats are in the DocC PerformanceMetrics guide.

Android Example collects offlineReplay metrics; this does not measure the exact live
stream. iOS can submit the same fields, but no iOS producer is shipped in this repository.
Memory must identify its measurement kind (for example PSS versus resident memory).
Thermal states are nominal/fair/serious/critical/unknown, with the native OS value retained.
Do not interpret them as temperatures or identical conditions across platforms.

The receiver validates available timing/count data, preserves the original manifest,
and stores measurements in history and HTML reports. Missing measurements remain absent.
Older packages without performance data still work. The transfer AAR only transports
these packages; it does not collect performance or depend on a particular codec library.
