# Module VQMetrix Producer

Android evaluation-material capture for the VQMetrix macOS evaluator. Create an exact
I420/Y4M reference and replay its frames through Android MediaCodec at multiple
bitrates. All candidates use the same dimensions, frame order, and presentation
 timestamps; incompatible encoders fail rather than silently dropping frames.

## Workflow

Open the VQMetrix screen in HaishinKit.kt Example, choose a deterministic test pattern, select H.264
or HEVC, enter target bitrates in Mbps, and create a package. Camera access is requested
only when capturing; no audio is captured. Keep the activity open until processing ends.

Packages remain in app-private storage and can be shared as ZIP files or uploaded to
a LAN HTTP or trusted HTTPS receiver using protocol `vqmetrix.capture.v1`. Upload tokens are not saved.
The receiver/evaluation API is specified in the VQMetrix repository under `docs/transfer.md`.
VMAF does not run on Android.

## Pixel and timing conditions

The reference stores planar 8-bit YUV420. Test patterns use limited-range BT.709.
Camera samples preserve raw bytes and sensor timestamps; unreported color range and
matrix remain `unspecified` and must be resolved explicitly by an evaluator. Sensor
orientation is recorded, without rotating only one side of the comparison. Camera
frames are replayed with a common CFR timeline; actual capture timing is retained in
`frame-map.json`. Files may require substantial storage.

## HaishinKit Example

Check out VQMetrix next to HaishinKit.kt. The Example Preference screen exposes the
example-owned activity when `Android/producer` is present. Override its location with the Gradle
property `vqmetrixDir`. The optional integration is omitted when the checkout is absent.

## Receiver discovery

`ReceiverDiscovery` browses `_vqmetrix._tcp` with Android NSD. See the transfer guide for TXT fields, local HTTP limits and HTTPS trust. Discovery does not authorize uploads. The UI lives in HaishinKit.kt, not this library.

## Existing camera and projection

`ScreenReference` uses the public `Screen.readPixels` API to sample the current MediaMixer composition, including overlays. The Example camera and MediaProjection screens offer Save sample. Frames are converted to limited-range BT.709 YUV420 and replayed through Android MediaCodec; no HaishinKit library changes are required. This measures re-encoding of sampled composition, not packet loss or the exact live stream bitstream.
