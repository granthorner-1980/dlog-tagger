// Checks that an update zip's signature matches the public key built into the app
// (SUPublicEDKey). If they didn't match, nobody could install the update, so the
// Release workflow stops instead of publishing it.
//     swift verify_update.swift "D-Log Tagger.app" update.zip SIGNATURE
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4 else { print("usage: verify_update.swift APP ZIP SIGNATURE"); exit(2) }
let plist = NSDictionary(contentsOf: URL(fileURLWithPath: args[1] + "/Contents/Info.plist"))
guard let keyB64 = plist?["SUPublicEDKey"] as? String, let keyData = Data(base64Encoded: keyB64),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    print("No valid SUPublicEDKey in the app's Info.plist"); exit(1)
}
guard let sig = Data(base64Encoded: args[3]),
      let file = try? Data(contentsOf: URL(fileURLWithPath: args[2])) else {
    print("Can't read the signature or the zip"); exit(1)
}
if key.isValidSignature(sig, for: file) {
    print("Update signature matches the app's public key")
} else {
    print("Update signature does NOT match the app's public key (SUPublicEDKey in mac/build.sh)"); exit(1)
}
