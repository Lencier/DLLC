import CryptoKit
import Foundation

/// A DLLC release on GitHub that can be installed from inside the app.
public struct AppRelease: Sendable, Equatable {
    public var version: String
    public var notes: String
    public var pageURL: URL
    public var zipURL: URL
    public var signatureURL: URL
}

/// In-app updates from the GitHub releases of `repository`.
///
/// Each release carries `DLLC-<version>.zip` and `DLLC-<version>.zip.sig`: an Ed25519 signature over the
/// zip's SHA-256, made with the maintainer's private key (kept off the repository, see scripts/release.sh).
/// Nothing is installed unless the signature matches the public key below, the app inside is DLLC with the
/// announced version, and its code signature is intact.
public enum AppUpdate {
    public static let repository = "Lencier/DLLC"
    public static let bundleIdentifier = "com.lencier.dllc"
    /// Public half of the release signing key (Curve25519 / Ed25519, raw 32 bytes, base64).
    public static let publicKey = "hEs4yKJZaD2R43vmrDnd08fnzZ9dNknGMQj9QlD4FA0="

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case badResponse, badSignature, badPackage(String), notWritable, translocated
        public var description: String {
            switch self {
            case .badResponse: "GitHub didn’t answer as expected."
            case .badSignature: "The update’s signature doesn’t match, so it wasn’t installed."
            case .badPackage(let why): "The update package isn’t valid (\(why))."
            case .notWritable: "DLLC can’t replace itself in this folder. Download the new version from GitHub instead."
            case .translocated: "Move DLLC into the Applications folder first, then update."
            }
        }
    }

    /// Compares dotted versions numerically ("1.3.10" > "1.3.9"); a leading "v" is ignored.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Only files served by GitHub are accepted.
    static func isGitHubURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let h = url.host?.lowercased() else { return false }
        return h == "github.com" || h == "api.github.com"
    }

    /// Reads GitHub's "latest release" JSON. Nil when the release lacks the zip or its signature.
    public static func parseLatest(_ data: Data) throws -> AppRelease? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String else { throw Failure.badResponse }
        if root["draft"] as? Bool == true || root["prerelease"] as? Bool == true { return nil }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard !version.isEmpty, version.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        let assets = (root["assets"] as? [[String: Any]] ?? []).reduce(into: [String: URL]()) { map, a in
            if let name = a["name"] as? String, let s = a["browser_download_url"] as? String, let u = URL(string: s), isGitHubURL(u) { map[name] = u }
        }
        let zip = "DLLC-\(version).zip"
        guard let zipURL = assets[zip], let sigURL = assets[zip + ".sig"] else { return nil }
        let page = (root["html_url"] as? String).flatMap(URL.init(string:)).flatMap { isGitHubURL($0) ? $0 : nil }
            ?? URL(string: "https://github.com/\(repository)/releases")!
        return AppRelease(version: version, notes: root["body"] as? String ?? "", pageURL: page, zipURL: zipURL, signatureURL: sigURL)
    }

    public static func fetchLatest(session: URLSession = .shared) async throws -> AppRelease? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("DLLC-updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }                                  // no release published yet
        guard code == 200 else { throw Failure.badResponse }
        return try parseLatest(data)
    }

    public static func sha256(of file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize())
    }

    public static func verify(digest: Data, signatureBase64: String, publicKeyBase64: String = publicKey) -> Bool {
        guard let sig = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let raw = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(sig, for: digest)
    }

    /// Downloads, verifies and unpacks `release`; returns the new DLLC.app inside `workDir`.
    public static func prepare(_ release: AppRelease, workDir: URL, session: URLSession = .shared) async throws -> URL {
        try? FileManager.default.removeItem(at: workDir)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let (sigData, sigResponse) = try await session.data(from: release.signatureURL)
        guard (sigResponse as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.badResponse }
        let (tmp, zipResponse) = try await session.download(from: release.zipURL)
        guard (zipResponse as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.badResponse }
        let zip = workDir.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: tmp, to: zip)
        guard verify(digest: try sha256(of: zip), signatureBase64: String(decoding: sigData, as: UTF8.self)) else {
            throw Failure.badSignature
        }
        let out = workDir.appendingPathComponent("unpacked", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        let app = out.appendingPathComponent("DLLC.app", isDirectory: true)
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw Failure.badPackage("no app inside")
        }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else { throw Failure.badPackage("not DLLC") }
        guard info["CFBundleShortVersionString"] as? String == release.version else { throw Failure.badPackage("wrong version") }
        do { try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) }
        catch { throw Failure.badPackage("damaged app signature") }
        return app
    }

    /// Checks DLLC may replace itself where it lives.
    public static func checkReplaceable(_ current: URL) throws {
        if current.path.contains("/AppTranslocation/") || current.path.hasPrefix("/Volumes/") { throw Failure.translocated }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: current.deletingLastPathComponent().path), fm.isWritableFile(atPath: current.path) else {
            throw Failure.notWritable
        }
    }

    /// Starts a small helper that waits for DLLC (`pid`) to quit, swaps `newApp` in at `current` (restoring the
    /// old copy if that fails) and opens it. The caller quits right after. Paths are passed as arguments, never
    /// spliced into the script.
    public static func launchSwap(newApp: URL, current: URL, pid: Int32) throws {
        let script = """
        pid="$1"; new="$2"; dest="$3"
        for _ in $(seq 1 600); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        keep="$(mktemp -d)"
        if mv "$dest" "$keep/old.app"; then
          if ditto "$new" "$dest"; then rm -rf "$keep"; else rm -rf "$dest"; mv "$keep/old.app" "$dest"; fi
        fi
        open "$dest"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "dllc-update", String(pid), newApp.path, current.path]
        try p.run()
    }

    static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure.badPackage("\(URL(fileURLWithPath: tool).lastPathComponent) failed") }
    }
}
