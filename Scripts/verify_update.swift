import CryptoKit
import Foundation

// Public inputs only: archive path, public key, signature. Never accepts a private key.
let arguments = CommandLine.arguments
 guard arguments.count == 4,
       let publicData = Data(base64Encoded: arguments[2]),
       let signature = Data(base64Encoded: arguments[3]) else {
    fatalError("Expected archive, public key, and Ed25519 signature")
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[1]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: archive) else {
    fputs("Update signature does not match the app's public key\n", stderr)
    exit(1)
}
print("Verified update archive against the app's public key")
