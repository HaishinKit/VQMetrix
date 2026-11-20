# 📊 VQMetrix

[![Build](https://github.com/HaishinKit/VQMetrix/actions/workflows/build.yml/badge.svg)](https://github.com/HaishinKit/VQMetrix/actions/workflows/build.yml)
[![Android](https://img.shields.io/badge/Android-10%2B-3ddc84)](Android/README.md)
[![License](https://img.shields.io/badge/license-BSD--3--Clause-blue)](LICENSE.md)

Video quality development tools built on HaishinKit.

- **macOS:** compare reference and decoded video, change H.264/HEVC and bitrate, inspect VMAF, and review saved runs and HTML reports.
- **Android (HaishinKit Example):** create exact YUV references from a camera or test pattern, encode bitrate variants, and prepare checksummed upload packages.
- **Transfer:** LAN HTTP / HTTPS upload client and Bonjour discovery and a versioned package format. The macOS receiver/evaluation service is the next integration; it is not implemented yet.

## 🚀 Build

Keep HaishinKit.swift and HaishinKit.kt beside this checkout at the revisions in
[Support/dependencies.json](Support/dependencies.json), then prepare their development adapters:

```sh
ruby Scripts/prepare_dependencies.rb
```

macOS (Swift 6, macOS 13+; the installed libvmaf can require a newer OS):

```sh
brew install libvmaf pkgconf
ruby Scripts/build_app.rb
open .build/VQMetrix.app
```

Android (JDK 17+, SDK 37):

```sh
cd ../HaishinKit.kt
./gradlew :app:assembleDebug
```

These use local development checkouts, not published release tags. The adapters and
pinned revisions make CI reproduce the same build. See the [Android guide](Android/README.md)
for the HaishinKit Example integration.

## 📚 Documentation

[User guide](docs/user-guide.md) · [Transfer protocol](docs/transfer.md) · [Release workflow](docs/releases.md)

Tags generate Swift DocC, Android Dokka, and a combined API-reference archive. Extract
it and run `ruby serve.rb` to read it locally. GitHub Pages publication is optional.

## 🧪 Verification

```sh
swift test
cd Android
./gradlew :producer:testDebugUnitTest :producer:connectedDebugAndroidTest
```

VideoToolbox integration tests and Android device tests require suitable hardware.
App languages are English and Japanese. Android captures no audio. macOS camera input
is experimental; capture availability depends on the device and environment.

## 📦 Development builds

Tags such as `v0.1.0` attach a macOS ZIP, HaishinKit Example debug APK, API documentation, and
checksums to [GitHub Release](https://github.com/HaishinKit/VQMetrix/releases). macOS builds
are ad hoc signed and not notarized. The Android APK uses development signing.

## ⚖️ Licenses

VQMetrix and HaishinKit use BSD-3-Clause. libvmaf uses
[BSD-2-Clause-Patent](https://github.com/Netflix/vmaf/blob/master/LICENSE).
The macOS package includes dependency license notices. Preserve them when distributing it.
