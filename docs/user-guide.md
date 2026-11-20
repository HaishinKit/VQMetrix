# VQMetrix user guide

## macOS measurement

1. Open the app and choose a video file or a camera. Camera capture requests permission
   only on Start; no audio is captured. The camera mode requests up to 640×480 at 30 fps.
2. Choose H.264 or HEVC, bitrate, and a maximum duration of 300 seconds.
3. Start measurement. Compare MediaMixer output and decoded output, and inspect the
   latest VMAF, the current segment mean, and the score timeline.
4. Use Apply Changes during measurement to start a new codec/bitrate segment. Sessions
   drain at each change; playback may pause briefly. Stop finalizes outstanding scores.
5. Open History to search saved runs, inspect segment results, give a run a title, add
   notes, and export a self-contained HTML report. Browser printing can save the report
   as a PDF. Previous local runs are included automatically.

The Language control supports System, English, and Japanese. App controls and reports
follow that selection; system permission dialogs follow macOS settings.

History lives in `~/Library/Application Support/VQMetrix/Results/`. Do not move or edit
run files while the app is measuring. Titles and notes are separate from raw results.
An unreadable cache falls back to the original summary; unreadable runs are counted.

## Android material creation

The VQMetrix screen in HaishinKit.kt Example does not run VMAF. It records an exact uncompressed I420 reference in
Y4M format and replays the same frames to Android MediaCodec at each requested bitrate.
The VQMetrix screen creates a deterministic test pattern with SD/HD resolution, 15/30 fps, H.264/HEVC,
and up to six comma-separated bitrates (0.05–20 Mbps). Capture length is 1–10 nominal
seconds. Camera frame sizes are selected from the device's supported YUV sizes.

Keep the screen open during capture, encoding, and upload. Leaving it cancels the
current operation; completed packages remain available. The library camera-capture API requests camera
permission and captures no audio. The preview is luma-only; the stored reference retains
all three YUV planes. Camera range/matrix that the capture API does not report are marked
`unspecified`, not guessed. Sensor timestamps and orientation are recorded separately.

A package contains the raw reference, every encoded MP4, frame maps, settings, and
SHA-256 checksums. Every candidate must contain the exact input frame count and CFR
presentation timestamps. A mismatched or unsupported encoder fails the run. Target
bitrate and actual encoded payload bitrate are separate measurements. References may
use hundreds of megabytes; free space is checked before starting.

Saved packages can be shared as ZIP files or sent to a compatible LAN HTTP or HTTPS receiver with
a bearer token. The app validates the receiver response and stores its job ID without
the token. On systems requiring local-network permission, allow it for a LAN receiver.
Tokens are not saved. HTTP is restricted to local network addresses and .local names; video and tokens are unencrypted. HTTPS needs a system-trusted certificate; certificate
validation is not bypassed. The upload contract is described in the transfer guide.

The receiver picker browses Bonjour services automatically while this screen is visible. Choose a discovered Mac to fill its address. Manual entry remains available. The Mac receiver advertises Bonjour while receiving is enabled.

## HaishinKit Example integration

The Example consumes `com.github.HaishinKit:VQMetrix:1.0.0` from JitPack.
No VQMetrix checkout is required for a normal Example build. Capture, replay encoding
and UI live in HaishinKit.kt/app/vqmetrix; upload and discovery live in the published AAR.
For source development, set `vqmetrixTransferDir` to VQMetrix/Android/transfer.

## Interpreting results

The pinned model is `vmaf_v0.6.1`. Both sides use the same resolution; no automatic
resizing is performed. Local macOS measurement evaluates mixer track 0, not offscreen
screen composition, network loss, transport, or receiver/player behavior. This model
does not comprehensively measure chroma fidelity.

Queues are bounded. A partial run's score covers only evaluated frames, and temporal
gaps alter motion features. Compare complete runs and matching source/model conditions.
Evaluator service fps differs from end-to-end streaming throughput. Score availability
includes buffering of approximately one nominal second plus processing time. Measure
streaming performance with evaluation disabled separately to quantify overhead.

## Build and releases

Check out the sibling dependencies at the immutable revisions in `Support/dependencies.json`,
then run `ruby Scripts/prepare_dependencies.rb`. This applies the included development
adapters only when needed: the external Swift codec probe and Android Example integration.
These APIs are not yet assumed to exist in a published HaishinKit release.

macOS: `brew install libvmaf pkgconf`, then `ruby Scripts/build_app.rb`.
Android: `cd ../HaishinKit.kt && ./gradlew :app:assembleDebug` with JDK 17+ and SDK 37.

The `1.0.0` tag trigger app builds and documentation generation. macOS ZIP, Android
development APK, and offline API documentation are attached to GitHub Release. The
macOS app is ad hoc signed and not notarized. Android uses debug signing; a stable
release signing key is required before offering an upgradeable production channel.
GitHub Pages deployment is optional via repository variable `PUBLISH_PAGES=true` after
Pages is configured for GitHub Actions. No release tag is created by these instructions.

## Save from an existing Android source

In HaishinKit Example, use **VQMetrix · Save sample** on the camera or MediaProjection screen. It samples that existing mixer composition, including overlays, without opening a second camera or projection. Defaults are 3 seconds, 15 fps, within 640×480 while preserving aspect ratio; duration, codec and bitrates come from the VQMetrix screen after leaving it. Sampling is bounded and source shutdown cancels an unfinished capture; encoding and packaging can finish after capture completes. Open VQMetrix from Preferences to share or upload saved packages.

These are sampled post-composition frames replayed with a CFR timeline, not the original live bitstream. Observed readback times are preserved. The comparison measures re-encoding of the stored reference; it does not include network effects. Android MediaCodec handles raw replay without changes to HaishinKit library code.

## Receive on your Mac

1. Choose **Receive** in the sidebar and click **Start receiving**. Allow local network access
   if macOS asks, and allow the app through the firewall if needed.
2. Keep the Mac and Android on the same trusted LAN. Android's VQMetrix receiver picker finds
   this Mac through Bonjour; select it. A manual LAN address is also supported.
3. Enter the Mac’s **4-digit connection code** in the sending device’s authentication field, then upload a saved package. A new code is issued whenever reception starts. Five wrong attempts trigger a one-minute cooldown.
4. The Mac shows transfer progress, validation and queued/evaluating/completed/failed jobs.
   Open **History** for per-bitrate VMAF scores, notes and an HTML report.

The port is editable while reception is stopped. Stop receiving closes incoming connections,
but accepted jobs keep evaluating. HTTP video/token traffic is unencrypted; the built-in
receiver is intended for trusted LAN development. It does not provide WAN HTTPS hosting.

## Learn about scores

See the [English score guide](https://haishinkit.github.io/VQMetrix/swift/documentation/vqmetrixcore/understandingvmaf/) or [日本語ガイド](https://haishinkit.github.io/VQMetrix/swift/documentation/vqmetrixcore/understandingvmaf-japanese/). The Mac sidebar and Help menu open these guides on GitHub Pages. Score bands are practical starting points rather than universal perceptual thresholds.

## Sender performance

Android Example also records replay processing time, per-frame input/output latency, app CPU time, sampled memory and OS thermal state. Open Sender performance in History and expand Performance timeline. These are sender-reported measurements of offline replay, not a live-stream stability guarantee. CPU/memory cover the whole app. See the [performance guide](https://haishinkit.github.io/VQMetrix/swift/documentation/vqmetrixcore/performancemetrics/) for units, sampling and iOS schema compatibility.
