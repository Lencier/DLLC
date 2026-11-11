import CryptoKit
import Foundation
import Security

/// OpenPGP verification of yt-dlp's detached `SHA2-256SUMS.sig` against the release signing key pinned
/// below (from github.com/yt-dlp/yt-dlp/blob/master/public.key). Supports exactly what that key uses:
/// a v4 RSA primary key and v4 RSA signatures over binary documents with SHA-256/384/512.
public enum YTDLPSignature {
    public static let verifier: YTDLPUpdater.SignatureVerifier? = { message, signature in
        verify(message: message, signature: signature)
    }

    /// Fingerprint of the pinned key; parsing fails closed if the embedded key doesn't match it.
    public static let pinnedFingerprint = "AC0CBBE6848D6A873464AF4E57CF65933B5A7581"

    public static let publicKeyArmored = """
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBGP78C4BEAD0rF9zjGPAt0thlt5C1ebzccAVX7Nb1v+eqQjk+WEZdTETVCg3
WAM5ngArlHdm/fZqzUgO+pAYrB60GKeg7ffUDf+S0XFKEZdeRLYeAaqqKhSibVal
DjvOBOztu3W607HLETQAqA7wTPuIt2WqmpL60NIcyr27LxqmgdN3mNvZ2iLO+bP0
nKR/C+PgE9H4ytywDa12zMx6PmZCnVOOOu6XZEFmdUxxdQ9fFDqd9LcBKY2LDOcS
Yo1saY0YWiZWHtzVoZu1kOzjnS5Fjq/yBHJLImDH7pNxHm7s/PnaurpmQFtDFruk
t+2lhDnpKUmGr/I/3IHqH/X+9nPoS4uiqQ5HpblB8BK+4WfpaiEg75LnvuOPfZIP
KYyXa/0A7QojMwgOrD88ozT+VCkKkkJ+ijXZ7gHNjmcBaUdKK7fDIEOYI63Lyc6Q
WkGQTigFffSUXWHDCO9aXNhP3ejqFWgGMtCUsrbkcJkWuWY7q5ARy/05HbSM3K4D
U9eqtnxmiV1WQ8nXuI9JgJQRvh5PTkny5LtxqzcmqvWO9TjHBbrs14BPEO9fcXxK
L/CFBbzXDSvvAgArdqqlMoncQ/yicTlfL6qzJ8EKFiqW14QMTdAn6SuuZTodXCTi
InwoT7WjjuFPKKdvfH1GP4bnqdzTnzLxCSDIEtfyfPsIX+9GI7Jkk/zZjQARAQAB
tDdTaW1vbiBTYXdpY2tpICh5dC1kbHAgc2lnbmluZyBrZXkpIDxjb250YWN0QGdy
dWI0ay54eXo+iQJOBBMBCgA4FiEErAy75oSNaoc0ZK9OV89lkztadYEFAmP78C4C
GwMFCwkIBwIGFQoJCAsCBBYCAwECHgECF4AACgkQV89lkztadYEVqQ//cW7TxhXg
7Xbh2EZQzXml0egn6j8QaV9KzGragMiShrlvTO2zXfLXqyizrFP4AspgjSn/4NrI
8mluom+Yi+qr7DXT4BjQqIM9y3AjwZPdywe912Lxcw52NNoPZCm24I9T7ySc8lmR
FQvZC0w4H/VTNj/2lgJ1dwMflpwvNRiWa5YzcFGlCUeDIPskLx9++AJE+xwU3LYm
jQQsPBqpHHiTBEJzMLl+rfd9Fg4N+QNzpFkTDW3EPerLuvJniSBBwZthqxeAtw4M
UiAXh6JvCc2hJkKCoygRfM281MeolvmsGNyQm+axlB0vyldiPP6BnaRgZlx+l6MU
cPqgHblb7RW5j9lfr6OYL7SceBIHNv0CFrt1OnkGo/tVMwcs8LH3Ae4a7UJlIceL
V54aRxSsZU7w4iX+PB79BWkEsQzwKrUuJVOeL4UDwWajp75OFaUqbS/slDDVXvK5
OIeuth3mA/adjdvgjPxhRQjA3l69rRWIJDrqBSHldmRsnX6cvXTDy8wSXZgy51lP
m4IVLHnCy9m4SaGGoAsfTZS0cC9FgjUIyTyrq9M67wOMpUxnuB0aRZgJE1DsI23E
qdvcSNVlO+39xM/KPWUEh6b83wMn88QeW+DCVGWACQq5N3YdPnAJa50617fGbY6I
gXIoRHXkDqe23PZ/jURYCv0sjVtjPoVC+bg=
=bJkn
-----END PGP PUBLIC KEY BLOCK-----
"""

    public static func verify(message: Data, signature: Data, armoredKey: String = publicKeyArmored,
                              fingerprint: String = pinnedFingerprint) -> Bool {
        guard let key = PGPPublicKey(armored: armoredKey), key.fingerprintHex == fingerprint,
              let sig = PGPSignature(signature.starts(with: Array("-----".utf8)) ? (dearmor(String(decoding: signature, as: UTF8.self)) ?? Data()) : signature)
        else { return false }
        // The issuer must be the pinned key (by fingerprint when present, else by key ID).
        if let issuerFP = sig.issuerFingerprint, issuerFP != key.fingerprint { return false }
        if let issuerID = sig.issuerKeyID, issuerID != key.keyID { return false }
        guard sig.type == 0x00, sig.publicKeyAlgorithm == 1 else { return false }

        var hashed = message
        hashed.append(sig.hashedPortion)
        hashed.append(contentsOf: [0x04, 0xFF])
        hashed.append(contentsOf: UInt32(sig.hashedPortion.count).bigEndianBytes)
        let digest: Data, algorithm: SecKeyAlgorithm
        switch sig.hashAlgorithm {
        case 8: digest = Data(SHA256.hash(data: hashed)); algorithm = .rsaSignatureDigestPKCS1v15SHA256
        case 9: digest = Data(SHA384.hash(data: hashed)); algorithm = .rsaSignatureDigestPKCS1v15SHA384
        case 10: digest = Data(SHA512.hash(data: hashed)); algorithm = .rsaSignatureDigestPKCS1v15SHA512
        default: return false
        }
        guard digest.prefix(2) == sig.hashLeft16, let secKey = key.secKey() else { return false }
        // MPIs drop leading zero bytes; RSA signatures must be exactly the modulus length.
        let modulusLength = key.modulus.count
        guard sig.value.count <= modulusLength else { return false }
        let padded = Data(repeating: 0, count: modulusLength - sig.value.count) + sig.value
        return SecKeyVerifySignature(secKey, algorithm, digest as CFData, padded as CFData, nil)
    }

    static func dearmor(_ text: String) -> Data? {
        var body: [Substring] = []
        var inBody = false, pastHeaders = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map({ $0.trimmingCharacters(in: .whitespaces)[...] }) {
            if line.hasPrefix("-----BEGIN") { inBody = true; continue }
            if line.hasPrefix("-----END") { break }
            guard inBody else { continue }
            if !pastHeaders { if line.isEmpty { pastHeaders = true }; continue }
            if line.hasPrefix("=") { continue }   // CRC-24 line (the signature check is what matters)
            body.append(line)
        }
        return Data(base64Encoded: body.joined())
    }
}

/// Minimal OpenPGP packet reader (RFC 4880 §4.2).
struct PGPPacketReader {
    let data: Data
    var offset: Int

    init(_ data: Data) { self.data = Data(data); offset = 0 }

    mutating func next() -> (tag: Int, body: Data)? {
        guard offset < data.count else { return nil }
        let header = data[offset]; offset += 1
        guard header & 0x80 != 0 else { return nil }
        let tag: Int, length: Int
        if header & 0x40 != 0 {
            tag = Int(header & 0x3F)
            guard offset < data.count else { return nil }
            let first = Int(data[offset]); offset += 1
            if first < 192 { length = first }
            else if first < 224 {
                guard offset < data.count else { return nil }
                length = ((first - 192) << 8) + Int(data[offset]) + 192; offset += 1
            } else if first == 255 {
                guard let l = read(4) else { return nil }; length = l
            } else { return nil }   // partial lengths aren't used by keys or signatures
        } else {
            tag = Int((header >> 2) & 0x0F)
            switch header & 0x03 {
            case 0: guard let l = read(1) else { return nil }; length = l
            case 1: guard let l = read(2) else { return nil }; length = l
            case 2: guard let l = read(4) else { return nil }; length = l
            default: return nil
            }
        }
        guard length >= 0, offset + length <= data.count else { return nil }
        let body = data.subdata(in: offset..<(offset + length))
        offset += length
        return (tag, body)
    }

    private mutating func read(_ n: Int) -> Int? {
        guard offset + n <= data.count else { return nil }
        let v = data[offset..<(offset + n)].reduce(0) { ($0 << 8) | Int($1) }
        offset += n
        return v
    }
}

/// Reads an MPI (2-byte bit count + big-endian bytes) at `offset`.
private func readMPI(_ d: Data, _ offset: inout Int) -> Data? {
    guard offset + 2 <= d.count else { return nil }
    let bits = (Int(d[offset]) << 8) | Int(d[offset + 1])
    let bytes = (bits + 7) / 8
    offset += 2
    guard offset + bytes <= d.count else { return nil }
    defer { offset += bytes }
    return d.subdata(in: offset..<(offset + bytes))
}

struct PGPPublicKey {
    let modulus: Data
    let exponent: Data
    let fingerprint: Data

    var keyID: Data { fingerprint.suffix(8) }
    var fingerprintHex: String { fingerprint.map { String(format: "%02X", $0) }.joined() }

    init?(armored: String) {
        guard let raw = YTDLPSignature.dearmor(armored) else { return nil }
        var reader = PGPPacketReader(raw)
        guard let (tag, body) = reader.next(), tag == 6, body.count > 6, body[0] == 4, body[5] == 1 else { return nil }
        var o = 6
        guard let n = readMPI(body, &o), let e = readMPI(body, &o) else { return nil }
        modulus = n; exponent = e
        var material = Data([0x99]) + UInt16(body.count).bigEndianBytes
        material.append(body)
        fingerprint = Data(Insecure.SHA1.hash(data: material))   // v4 fingerprints are defined as SHA-1
    }

    func secKey() -> SecKey? {
        let der = DER.sequence(DER.integer(modulus) + DER.integer(exponent))
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil)
    }
}

struct PGPSignature {
    let type: UInt8
    let publicKeyAlgorithm: UInt8
    let hashAlgorithm: UInt8
    /// Version byte through the end of the hashed subpackets: the part covered by the hash.
    let hashedPortion: Data
    let hashLeft16: Data
    let value: Data
    var issuerKeyID: Data?
    var issuerFingerprint: Data?

    init?(_ raw: Data) {
        var reader = PGPPacketReader(raw)
        guard let (tag, b) = reader.next(), tag == 2, b.count > 10, b[0] == 4 else { return nil }
        type = b[1]; publicKeyAlgorithm = b[2]; hashAlgorithm = b[3]
        let hashedLen = (Int(b[4]) << 8) | Int(b[5])
        guard 6 + hashedLen + 2 <= b.count else { return nil }
        hashedPortion = b.subdata(in: 0..<(6 + hashedLen))
        var o = 6 + hashedLen
        let unhashedLen = (Int(b[o]) << 8) | Int(b[o + 1])
        o += 2
        guard o + unhashedLen + 2 <= b.count else { return nil }
        let unhashed = b.subdata(in: o..<(o + unhashedLen))
        o += unhashedLen
        hashLeft16 = b.subdata(in: o..<(o + 2)); o += 2
        guard let v = readMPI(b, &o) else { return nil }
        value = v
        // Only hashed subpackets are trusted for the issuer fingerprint; the key ID is advisory.
        for (type, data) in Self.subpackets(b.subdata(in: 6..<(6 + hashedLen))) + Self.subpackets(unhashed) {
            if type == 16, data.count == 8 { issuerKeyID = data }
            if type == 33, data.count == 21, data[0] == 4, issuerFingerprint == nil { issuerFingerprint = data.dropFirst() }
        }
    }

    static func subpackets(_ d: Data) -> [(Int, Data)] {
        var out: [(Int, Data)] = []
        var o = 0
        let d = Data(d)
        while o < d.count {
            let first = Int(d[o]); o += 1
            var len: Int
            if first < 192 { len = first }
            else if first < 255 { guard o < d.count else { break }; len = ((first - 192) << 8) + Int(d[o]) + 192; o += 1 }
            else { guard o + 4 <= d.count else { break }; len = d[o..<(o + 4)].reduce(0) { ($0 << 8) | Int($1) }; o += 4 }
            guard len >= 1, o + len <= d.count else { break }
            out.append((Int(d[o]) & 0x7F, d.subdata(in: (o + 1)..<(o + len))))
            o += len
        }
        return out
    }
}

private enum DER {
    static func length(_ n: Int) -> Data {
        if n < 128 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    static func integer(_ magnitude: Data) -> Data {
        var m = Data(magnitude.drop { $0 == 0 })
        if m.isEmpty { m = Data([0]) }
        if m[m.startIndex] & 0x80 != 0 { m.insert(0, at: 0) }
        return Data([0x02]) + length(m.count) + m
    }
    static func sequence(_ content: Data) -> Data { Data([0x30]) + length(content.count) + content }
}

private extension FixedWidthInteger {
    var bigEndianBytes: Data { withUnsafeBytes(of: self.bigEndian) { Data($0) } }
}
