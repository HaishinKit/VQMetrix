# Building and releasing VQMetrix

The release version is stored in `VERSION`. Use the same value for the Git tag,
application version and Android dependency: **1.3.0**, without a `v` prefix. A prefix is
only a tag convention; on JitPack it also becomes part of the requested version.

## Release contents

The tag workflow tests and packages:

- The macOS app, with bundled libvmaf, model, localization and license notices. The CLI is no longer built or bundled.
- Android Example builds and APK distribution belong to HaishinKit.kt. This workflow verifies and publishes the independent transfer library.
- The standalone Android transfer AAR, sources and Maven POM.
- Swift DocC and Kotlin Dokka, combined into `api-documentation.tar.gz`.
- A signed Sparkle appcast for stable releases after updater integration.
- SHA256SUMS.txt for the release assets.

The Android artifact is `com.github.HaishinKit:VQMetrix:1.3.0` on JitPack.
It does not depend on HaishinKit. Capture/encoding implementations belong to the SDK
Example. Standard `maven-publish` metadata allows other Maven repositories to be added
later; Maven Central still requires its own account, namespace and signing setup.

## Verification and tags

Main, pull requests and manual dispatch run verification without creating releases.
The macOS job checks out the pinned Swift SDK revision from `Support/dependencies.json`
and applies its development adapter. The transfer library builds independently. The
optional Android adapter changes Example code only; Example verification runs in
HaishinKit.kt. Update a pinned revision and its adapter together. Native camera/codec
tests need real hardware.

After verification, create and push the exact version tag. The workflow attaches
applications, library and reference assets to GitHub Releases. JitPack builds its Maven
artifacts from the same tag when requested. Never move a published tag.

App binaries use development signing. The Mac minimum OS is the highest requirement
of its executable and bundled libvmaf. Developer ID notarization and a persistent
Android signing key are separate production-distribution steps.

## Documentation

GitHub Pages uses GitHub Actions and repository variable `PUBLISH_PAGES=true`.
Tag builds publish the combined site under `/VQMetrix/`, with Swift documentation under
`/swift/` and Android API documentation under `/android/`. The Mac Help menu and sidebar
open the language-appropriate DocC VMAF score guide.

For offline reading, extract the documentation archive and run `ruby serve.rb`.
It binds to localhost and serves `/VQMetrix/`; it does not receive video uploads.
Failure-reporting helpers use runner Ruby without Bundler or gems.

## Automatic updates

See [automatic macOS updates](automatic-updates.md) for the signing secret, stable feed,
verification, and the one-time manual migration from 1.0.0. Private-key setup must be
completed before publishing the next stable tag.

## Language catalogs

DocC app guides are compiled independently from `Documentation/en.lproj/VQMetrix.docc`
and `Documentation/ja.lproj/VQMetrix.docc`. App resources and executable code share one
SwiftPM module, `VQMetrix`. The guide site retains redirects for released 1.0.x help URLs.

DocC sources use `Documentation/VQMetrix.docc`, with Japanese articles in
`Localization/ja.lproj`. The current compiler does not select natural languages
from that layout: the build stages each language separately to prevent duplicate
articles. English and Japanese keep their existing URLs, with explicit language
links in the articles. No browser-language redirect is added.
