# Module VQMetrix Producer

Android evaluation-material capture for the VQMetrix macOS evaluator. Create an exact
I420/Y4M reference and replay its frames through HaishinKit VideoCodec at multiple
bitrates. All candidates use the same dimensions, frame order, and presentation
 timestamps; incompatible encoders fail rather than silently dropping frames.

## Workflow

Open `VQMetrixActivity`, choose a deterministic test pattern or camera, select H.264
or HEVC, enter target bitrates in Mbps, and create a package. Camera access is requested
only when capturing; no audio is captured. Keep the activity open until processing ends.

Packages remain in app-private storage and can be shared as ZIP files or uploaded to
a trusted HTTPS receiver using protocol `vqmetrix.capture.v1`. Upload tokens are not saved.
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
same activity when `Android/producer` is present. Override its location with the Gradle
property `vqmetrixDir`. The optional integration is omitted when the checkout is absent.
