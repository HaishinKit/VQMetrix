# Module VQMetrix Android Transfer

Standalone Android transfer client for VQMetrix protocol v1. It has no HaishinKit dependency.

## Use

Create a `BatchArchive(runId, directory, archive)` for a completed package. Use
`BatchUploader.upload` from a coroutine with the receiver URL, connection code and progress
callback. The result is the receiver's job UUID: acceptance, not evaluation completion.
`cancel()` disconnects the active request. Connection codes are not saved; successful
receipts are written beside the archive without credentials.

`ReceiverDiscovery.start` and `stop` run on the main thread. Start discovery while the
screen is visible, stop it when the screen closes, and let the user select a discovered
`ReceiverEndpoint`. Discovery does not initiate uploads or establish trust.

## Network

Bonjour uses `_vqmetrix._tcp`, protocol 1, with `scheme` and `host` TXT fields. HTTP is
limited to local addresses; HTTPS uses Android's trust store and hostname verification.
HTTP transmits video and connection codes without encryption. The host application must
explicitly allow cleartext traffic if it uses LAN HTTP. No TLS checks are bypassed.
Request local-network permission on Android versions that require it.

## Distribution

JitPack coordinate: `com.github.HaishinKit.VQMetrix:transfer:1.0.0`.
Requires Android API 26+. Capture/encoding UI and examples live in HaishinKit.kt, not this AAR.
See the repository's transfer guide for package layout, checksums, frame maps and receiver limits.
