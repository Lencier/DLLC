import Foundation
import Testing
@testable import DLLCCore

/// Uses a real yt-dlp release (2026.10.26) SHA2-256SUMS and its detached signature.
@Suite struct YTDLPSignatureTests {
    private func load(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/ytdlp-sig"))
        return try Data(contentsOf: url)
    }

    @Test func pinnedKeyParses() throws {
        let key = try #require(PGPPublicKey(armored: YTDLPSignature.publicKeyArmored))
        #expect(key.fingerprintHex == YTDLPSignature.pinnedFingerprint)
        #expect(key.modulus.count == 512)   // RSA-4096
        #expect(key.secKey() != nil)
    }

    @Test func genuineReleaseVerifies() throws {
        #expect(YTDLPSignature.verify(message: try load("SHA2-256SUMS"), signature: try load("SHA2-256SUMS.sig")))
        #expect(YTDLPSignature.verifier != nil)
    }

    @Test func tamperingIsRejected() throws {
        let sums = try load("SHA2-256SUMS"), sig = try load("SHA2-256SUMS.sig")
        var altered = sums
        altered[10] ^= 0x01
        #expect(!YTDLPSignature.verify(message: altered, signature: sig))
        var badSig = sig
        badSig[badSig.count - 5] ^= 0x01
        #expect(!YTDLPSignature.verify(message: sums, signature: badSig))
        #expect(!YTDLPSignature.verify(message: sums, signature: Data()))
        #expect(!YTDLPSignature.verify(message: sums, signature: sig, fingerprint: String(repeating: "0", count: 40)))
    }
}
