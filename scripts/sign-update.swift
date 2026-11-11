// Signs a release zip for DLLC's in-app updater: prints the Ed25519 signature (base64) of the file's SHA-256.
// Usage: swift scripts/sign-update.swift <private-key-file> <zip>
// The private key (base64, raw 32 bytes) lives outside the repository, by default ~/.config/dllc/update-signing-key.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else { FileHandle.standardError.write(Data("usage: sign-update.swift <key> <zip>\n".utf8)); exit(2) }
guard let keyText = try? String(contentsOfFile: args[1], encoding: .utf8),
      let raw = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    FileHandle.standardError.write(Data("✗ can't read the signing key\n".utf8)); exit(1)
}
let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: args[2]))
var hasher = SHA256()
while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
let digest = Data(hasher.finalize())
let signature = try key.signature(for: digest)
guard key.publicKey.isValidSignature(signature, for: digest) else { exit(1) }
print(signature.base64EncodedString())
