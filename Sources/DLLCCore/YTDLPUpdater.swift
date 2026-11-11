import CryptoKit
import Foundation

/// Tracks user-installed yt-dlp updates in Application Support. The bundled copy is never modified and is
/// always available as the rollback target.
public struct YTDLPUpdateStore: Sendable {
    public let root: URL

    public init(paths: AppPaths) {
        root = paths.updatedToolsDirectory.appendingPathComponent("yt-dlp", isDirectory: true)
    }

    private var activeFile: URL { root.appendingPathComponent("active.json") }

    public var activeVersion: String? {
        guard let data = try? Data(contentsOf: activeFile),
              let obj = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        // active.json lives in user-writable storage: never let it point outside the store.
        return obj["version"].flatMap { YTDLPUpdater.isValidVersion($0) ? $0 : nil }
    }

    public func executable(for version: String) -> URL {
        root.appendingPathComponent(version, isDirectory: true).appendingPathComponent("yt-dlp_macos")
    }

    public func activeExecutable() -> URL? {
        activeVersion.map(executable(for:))
    }

    public func installedVersions() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return items.filter { FileManager.default.isExecutableFile(atPath: executable(for: $0).path) }.sorted(by: >)
    }

    /// nil → use the bundled yt-dlp.
    public func setActive(_ version: String?) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let version {
            let data = try JSONEncoder().encode(["version": version])
            try data.write(to: activeFile, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: activeFile)
        }
    }

    /// Keeps the active version and the most recent other one (rollback); removes older ones.
    /// `inUse` is the version this app session launched with: it keeps running until relaunch.
    public func prune(keeping inUse: String? = nil) {
        let keep = Set([activeVersion, inUse].compactMap { $0 } + installedVersions().prefix(2))
        for v in installedVersions() where !keep.contains(v) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(v, isDirectory: true))
        }
    }
}

public enum UpdateError: Error, Sendable, Equatable {
    case network(String)
    case checksumMissing
    case checksumMismatch
    case signatureInvalid
    case verificationFailed(String)
}

/// User-initiated yt-dlp updater.
/// Trust chain: HTTPS to github.com/yt-dlp/yt-dlp (official repo only) → the release's `SHA2-256SUMS`
/// → its OpenPGP signature `SHA2-256SUMS.sig` checked against yt-dlp's release key pinned in the app
/// (when a `SignatureVerifier` is provided) → SHA-256 of `yt-dlp_macos.zip` must match → the unpacked
/// binary must report the expected version before it is activated.
public final class YTDLPUpdater: Sendable {
    public typealias SignatureVerifier = @Sendable (_ message: Data, _ signature: Data) -> Bool

    let store: YTDLPUpdateStore
    let session: URLSession
    let verifySignature: SignatureVerifier?
    static let repo = "https://github.com/yt-dlp/yt-dlp"

    public init(store: YTDLPUpdateStore, session: URLSession = .shared, verifySignature: SignatureVerifier?) {
        self.store = store
        self.session = session
        self.verifySignature = verifySignature
    }

    public func latestVersion() async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, Self.isValidVersion(tag) else {
            throw UpdateError.network("Couldn’t read the latest release.")
        }
        return tag
    }

    static func isValidVersion(_ v: String) -> Bool {
        v.range(of: #"^\d{4}\.\d{2}\.\d{2}(\.\d+)?$"#, options: .regularExpression) != nil
    }

    /// Downloads, verifies and activates `version`. Returns the active executable.
    /// `inUse`: the update version this session launched with, kept until relaunch.
    public func install(version: String, tmpDirectory: URL, inUse: String? = nil) async throws -> URL {
        guard Self.isValidVersion(version) else { throw UpdateError.verificationFailed("Invalid version") }
        let base = "\(Self.repo)/releases/download/\(version)/"
        let sums = try await fetch(base + "SHA2-256SUMS")
        // Fail closed: nothing is downloaded or executed unless the checksum list is signed by the pinned key.
        guard let verifySignature else { throw UpdateError.signatureInvalid }
        let sig = try await fetch(base + "SHA2-256SUMS.sig")
        guard verifySignature(sums, sig) else { throw UpdateError.signatureInvalid }
        guard let expected = Self.checksum(for: "yt-dlp_macos.zip", in: sums) else { throw UpdateError.checksumMissing }

        let work = tmpDirectory.appendingPathComponent("ytdlp-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let zip = work.appendingPathComponent("yt-dlp_macos.zip")
        let (downloaded, response) = try await session.download(from: URL(string: base + "yt-dlp_macos.zip")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.network("Download failed") }
        try FileManager.default.moveItem(at: downloaded, to: zip)
        guard try Self.sha256(of: zip) == expected else { throw UpdateError.checksumMismatch }

        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try await runSystem("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let exe = unpacked.appendingPathComponent("yt-dlp_macos")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw UpdateError.verificationFailed("Archive has no yt-dlp_macos")
        }
        let reported = try await runSystem(exe.path, ["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard reported == version else { throw UpdateError.verificationFailed("Binary reports \(reported)") }

        let target = store.root.appendingPathComponent(version, isDirectory: true)
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: unpacked, to: target)
        try store.setActive(version)
        store.prune(keeping: inUse)
        return store.executable(for: version)
    }

    static func checksum(for name: String, in sums: Data) -> String? {
        guard let text = String(data: sums, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, parts[1] == name || parts[1] == "*\(name)" {
                return parts[0].lowercased()
            }
        }
        return nil
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func fetch(_ url: String) async throws -> Data {
        var req = URLRequest(url: URL(string: url)!)
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.network(url) }
        return data
    }

    @discardableResult
    private func runSystem(_ path: String, _ args: [String]) async throws -> String {
        let result = try await ProcessSupervisor.shared.run(
            ProcessSpec(executable: URL(fileURLWithPath: path), arguments: args), captureStdout: true)
        guard result.succeeded else { throw UpdateError.verificationFailed(Redactor.redact(result.stderrTail)) }
        return String(decoding: result.stdout, as: UTF8.self)
    }
}
