# 📱 VQMetrix Android Transfer

[![JitPack](https://jitpack.io/v/HaishinKit/VQMetrix.svg)](https://jitpack.io/#HaishinKit/VQMetrix)
[![Android](https://img.shields.io/badge/Android-API%2026%2B-3ddc84)](transfer/build.gradle.kts)

Upload evaluation packages and discover VQMetrix receivers through Bonjour.
The transfer AAR has no HaishinKit dependency and runs on Android API 26+.
Camera, MediaProjection, encoding and their UI live in HaishinKit.kt Example (API 29+).

## 🚀 Install

In `settings.gradle.kts`:

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven("https://jitpack.io")
    }
}
```

In the consuming module:

```kotlin
dependencies {
    implementation("com.github.HaishinKit.VQMetrix:transfer:1.0.0")
}
```

`1.0.0` is the release tag and dependency version; do not add a `v` prefix.
The library does not enable cleartext traffic globally. The host app must explicitly
allow LAN HTTP when using the built-in Mac receiver and request local-network permission
on Android versions that require it. HTTPS uses the platform trust store.

## 📚 Documentation

[API reference](https://haishinkit.github.io/VQMetrix/android/) ·
[Transfer protocol](../docs/transfer.md) · [User guide](../docs/user-guide.md)

Detailed API usage, cancellation and lifecycle rules are in Dokka. Use
`BatchArchive`, `BatchUploader`, `ReceiverDiscovery`, and `ReceiverEndpoint` from
`com.haishinkit.vqmetrix`.

## 🧰 Example and development

HaishinKit.kt Example consumes the Maven artifact by default, without a neighboring
VQMetrix checkout. For source development, use
`-PvqmetrixTransferDir=/absolute/path/VQMetrix/Android/transfer` from HaishinKit.kt.
The old `producer` directory is retained as a migration reference and is not published.

From this directory, with JDK 17+ and Android SDK 37:

```sh
./gradlew :transfer:testDebugUnitTest :transfer:lintDebug
./gradlew :transfer:publishReleasePublicationToVerificationRepository
./gradlew :transfer:dokkaGenerate
```

The local Maven repository is written to `build/maven-repository`. JitPack uses the
same standard Maven publication through the repository's `jitpack.yml`.
