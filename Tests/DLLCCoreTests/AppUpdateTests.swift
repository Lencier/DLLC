import CryptoKit
import Foundation
import Testing
@testable import DLLCCore

struct AppUpdateTests {
    @Test func versionsCompareNumerically() {
        #expect(AppUpdate.isNewer("1.3.10", than: "1.3.9"))
        #expect(AppUpdate.isNewer("v1.4", than: "1.3.25"))
        #expect(!AppUpdate.isNewer("1.3.25", than: "1.3.25"))
        #expect(!AppUpdate.isNewer("1.3.2", than: "1.3.10"))
    }

    @Test func parsesTheLatestRelease() throws {
        let json = #"""
        {"tag_name":"v1.3.30","body":"Notes","html_url":"https://github.com/Lencier/DLLC/releases/tag/v1.3.30",
         "assets":[{"name":"DLLC-1.3.30.zip","browser_download_url":"https://github.com/Lencier/DLLC/releases/download/v1.3.30/DLLC-1.3.30.zip"},
                   {"name":"DLLC-1.3.30.zip.sig","browser_download_url":"https://github.com/Lencier/DLLC/releases/download/v1.3.30/DLLC-1.3.30.zip.sig"}]}
        """#
        let r = try #require(try AppUpdate.parseLatest(Data(json.utf8)))
        #expect(r.version == "1.3.30")
        #expect(r.zipURL.lastPathComponent == "DLLC-1.3.30.zip")
    }

    @Test func refusesReleasesWithoutSignatureOrOffGitHub() throws {
        let unsigned = #"{"tag_name":"v2.0","assets":[{"name":"DLLC-2.0.zip","browser_download_url":"https://github.com/x/y/DLLC-2.0.zip"}]}"#
        #expect(try AppUpdate.parseLatest(Data(unsigned.utf8)) == nil)
        let elsewhere = #"{"tag_name":"v2.0","assets":[{"name":"DLLC-2.0.zip","browser_download_url":"https://evil.example/DLLC-2.0.zip"},{"name":"DLLC-2.0.zip.sig","browser_download_url":"https://github.com/x/y/s"}]}"#
        #expect(try AppUpdate.parseLatest(Data(elsewhere.utf8)) == nil)
        let pre = #"{"tag_name":"v2.0","prerelease":true,"assets":[]}"#
        #expect(try AppUpdate.parseLatest(Data(pre.utf8)) == nil)
    }

    @Test func signatureMustMatchTheKey() {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let digest = Data(SHA256.hash(data: Data("zip bytes".utf8)))
        let sig = try! key.signature(for: digest).base64EncodedString()
        #expect(AppUpdate.verify(digest: digest, signatureBase64: sig, publicKeyBase64: pub))
        let other = Data(SHA256.hash(data: Data("tampered".utf8)))
        #expect(!AppUpdate.verify(digest: other, signatureBase64: sig, publicKeyBase64: pub))
        #expect(!AppUpdate.verify(digest: digest, signatureBase64: sig))      // not signed by the release key
    }
}
