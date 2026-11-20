# Automatic macOS updates

The next release after 1.0.0 includes Sparkle 2.10.1. Existing 1.0.0 installations
must download that release manually once; the published 1.0.0 binary has no updater.

The VQMetrix menu provides **Check for Updates…** and **Automatically check for updates**
(English and Japanese). Sparkle asks for automatic-check permission, and users can change
it in the menu. Update installation uses Sparkle's confirmation UI; silent installation
is disabled by default. Raw SwiftPM executables have no installable bundle and disable
these controls.

## Distribution

`Support/updates.json` contains the public Ed25519 key, HTTPS feed URL, and local
Keychain account name. It never contains the private key. The feed is the `appcast.xml`
asset of the latest stable GitHub Release, separate from the LP and API documentation.
The first updater-enabled release creates that asset; until then the feed is unavailable.

A stable numeric tag runs `Scripts/build_appcast.rb` after packaging. Sparkle generates
the archive signature and signed feed, including OS/architecture requirements. The helper
verifies the archive against the public key embedded in the app and verifies the feed
before publishing. Missing or mismatched keys fail the release. Prereleases do not enter
the stable feed. `CFBundleVersion` follows the release version instead of remaining `1`.

The complete Sparkle framework and nested helpers are bundled with their vendor signature.
The outer app remains ad hoc signed. Ed25519 update signing does not replace Apple
Developer ID signing/notarization and does not remove the first-launch Gatekeeper warning.

## Maintainer setup

The dedicated local signing key is stored in the login Keychain under account
`com.haishinkit.VQMetrix`. Back it up securely; losing this key can prevent existing
installations from accepting future updates. Do not commit or print the private key.

GitHub Actions requires the private key in repository secret `SPARKLE_PRIVATE_KEY`.
Transferring the local key to GitHub requires the owner's explicit authorization. The
secret is exposed only to the stable-tag signing step and is passed to Sparkle through
standard input, rather than command arguments. Pull-request builds do not access it.
The signing helper deletes the key from its child-process environment.

For local verification using the Keychain (after building the app):

```sh
RELEASE_TAG=1.0.1 ruby Scripts/build_appcast.rb
```

The tag must match the packaged app's version; the helper rejects a mismatch. Never
replace an existing release's app ZIP after its signature/feed has been published.

See [Sparkle setup](https://sparkle-project.org/documentation/) and
[publishing updates](https://sparkle-project.org/documentation/publishing/).
