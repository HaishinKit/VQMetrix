# 📱 VQMetrix Android library

[![Android](https://img.shields.io/badge/Android-API%2029%2B-3ddc84)](producer/build.gradle.kts)

Reusable capture, encoding, packaging, upload and Bonjour discovery for evaluation
on macOS. VMAF runs on the Mac. The Android screen lives in HaishinKit.kt Example;
VQMetrix does not have a standalone Android application.

## 🚀 Build

Check out HaishinKit.kt beside VQMetrix at the revision in `../Support/dependencies.json`.
From the VQMetrix root, run `ruby Scripts/prepare_dependencies.rb android` to apply the
Example integration, pending upstream inclusion.
With JDK 17+ and Android SDK 37 installed, build from HaishinKit.kt:

```sh
./gradlew :app:assembleDebug
```

Use Save sample on its camera or MediaProjection screen. The VQMetrix screen in Preferences also creates test patterns and lets you choose H.264/HEVC,
and target bitrates. Select a Bonjour receiver or enter its address, then upload a
saved package. HTTP is limited to the trusted LAN; HTTPS requires a trusted certificate.
Enable Receive in the macOS app to accept packages.

For another checkout layout, use `-PvqmetrixDir=/absolute/path/VQMetrix/Android/producer`.
The Example feature is omitted when the VQMetrix checkout is absent.

## 📚 Documentation

[User guide](../docs/user-guide.md) · [Transfer and Bonjour protocol](../docs/transfer.md)

Generate Kotlin API documentation here with `./gradlew :producer:dokkaGenerate`.
Tags attach the HaishinKit Example development APK and generated API references.

## 🧪 Tests

```sh
./gradlew :producer:testDebugUnitTest
./gradlew :producer:connectedDebugAndroidTest
```

Device tests require H.264, HEVC and camera support; verified on Pixel 5a / Android 14.
