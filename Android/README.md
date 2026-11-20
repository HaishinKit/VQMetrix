# 📱 VQMetrix Android

[![Android](https://img.shields.io/badge/Android-API%2029%2B-3ddc84)](app/build.gradle.kts)

Creates reference/encoded material for evaluation on macOS. It does not run VMAF.
The standalone app and HaishinKit Example use the same `producer` module.

## 🚀 Build

Check out HaishinKit.kt beside VQMetrix at the revision in `../Support/dependencies.json`.
From the VQMetrix root, run `ruby Scripts/prepare_dependencies.rb android`. This supplies
the development YUV input API, which is not assumed to exist in a published SDK tag.

With JDK 17+ and Android SDK 37 installed:

```sh
./gradlew :app:assembleDebug
```

Install `app/build/outputs/apk/debug/app-debug.apk`. Choose a camera or test pattern,
H.264/HEVC, and comma-separated Mbps targets. Completed packages remain in private
storage and can be shared or uploaded to a compatible trusted HTTPS receiver.

## 🧰 HaishinKit Example

Build the HaishinKit.kt Example with VQMetrix beside it. Its Preference screen adds a
VQMetrix button. Another checkout layout can use:

```sh
./gradlew :app:assembleDebug -PvqmetrixDir=/absolute/path/VQMetrix/Android/producer
```

The integration is optional when the VQMetrix checkout is absent. Both entry points use
the same capture, encoding, packaging, and upload implementation.

## 📚 Documentation

[User guide](../docs/user-guide.md) · [Package and HTTPS contract](../docs/transfer.md)

Generate the Kotlin reference with `./gradlew :producer:dokkaGenerate`. Release tags
build and attach the standalone development APK and generated references automatically.

## 🧪 Tests

```sh
./gradlew :producer:testDebugUnitTest
./gradlew :producer:connectedDebugAndroidTest
```

The latter requires a connected device supporting H.264, HEVC, and camera capture.
The initial integration was verified on Pixel 5a / Android 14.
