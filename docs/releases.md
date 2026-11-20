# Building and releasing VQMetrix

`Build and release` runs on main, pull requests, manual dispatch, and semantic-version
tags such as `v0.1.0` or `0.1.0`. A tag is validated before it is used as a version.
This setup does not create tags, change repository visibility, or publish SDK releases.

Each build checks out the exact HaishinKit revisions in `Support/dependencies.json` and
applies only the included development adapters. Update the revisions and patches together
when the upstream APIs change. Until merged upstream, the Example screen and integration are supplied with the Android
adapter; no RTC or unrelated local changes are included.

The workflow builds:

- A native macOS app with bundled libvmaf, model, localization resources, and licenses.
- The HaishinKit.kt Example APK, with its VQMetrix screen and the reusable producer module.
- Swift DocC and Kotlin Dokka, combined with guides into `api-documentation.tar.gz`.

On tags, the apps, reference archive, and SHA256SUMS.txt are attached to GitHub Release.
App binaries use development signing. The macOS minimum deployment version is the highest
requirement of its executable and bundled libvmaf. A production channel needs Developer ID
signing/notarization and a persistent Android signing key; neither is silently configured.

For an offline reference, extract the documentation archive and run `ruby serve.rb`.
The server binds only to localhost and serves the reference at `/VQMetrix/`. It does not
receive video uploads.

To also publish the API site, configure GitHub Pages to use GitHub Actions and set the
repository variable `PUBLISH_PAGES=true`. This is opt-in; build artifacts and release assets
do not depend on Pages being configured. Private repositories need a plan that supports
Pages if enabling that option.

Linux CI runs Android unit tests and lint. Hardware codec/camera tests were run on a Pixel
5a; run `:producer:connectedDebugAndroidTest` on a connected device before a release.
macOS CI runs non-capture tests; VideoToolbox integration tests can be run locally with
`swift test`. Failure reporting uses runner Ruby without Bundler or gems.
