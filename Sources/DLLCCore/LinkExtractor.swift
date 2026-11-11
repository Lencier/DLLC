import Foundation

/// Pulls http(s) links out of pasted text and normalises them for duplicate detection.
public enum LinkExtractor {
    public static func extract(from text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var out: [String] = []
        for match in detector.matches(in: text, options: [], range: range) {
            guard let url = match.url, isAcceptable(url) else { continue }
            let s = url.absoluteString
            if seen.insert(s).inserted { out.append(s) }
        }
        return out
    }

    public static func isAcceptable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty, host.contains(".") else { return false }
        return url.absoluteString.count <= 4096
    }

    private static let trackingParams: Set<String> = [
        "si", "feature", "igsh", "igshid", "utm_source", "utm_medium", "utm_campaign", "utm_term",
        "utm_content", "s", "t_ref", "ref_src", "ref_url", "fbclid", "gclid", "pp",
    ]

    /// Canonical key used only to *warn* about duplicates (never to block or rewrite what is downloaded).
    public static func canonicalKey(_ string: String) -> String {
        guard var comps = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return string
        }
        var host = (comps.host ?? "").lowercased()
        for prefix in ["www.", "m.", "mobile."] where host.hasPrefix(prefix) { host = String(host.dropFirst(prefix.count)) }
        if host == "twitter.com" { host = "x.com" }
        var path = comps.path
        var items = (comps.queryItems ?? []).filter { !trackingParams.contains($0.name.lowercased()) }
        if host == "youtu.be" {
            let id = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            host = "youtube.com"; path = "/watch"
            items = [URLQueryItem(name: "v", value: id)]
        } else if host == "youtube.com", path.hasPrefix("/shorts/") {
            let id = String(path.dropFirst("/shorts/".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            path = "/watch"; items = [URLQueryItem(name: "v", value: id)]
        } else if host == "youtube.com", path == "/watch" {
            items = items.filter { $0.name == "v" || $0.name == "list" }
        }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        comps.scheme = "https"
        comps.host = host
        comps.path = path
        comps.queryItems = items.isEmpty ? nil : items.sorted { $0.name < $1.name }
        comps.fragment = nil
        return comps.string ?? string
    }

    /// True for a YouTube watch link that carries both a video id and a playlist (e.g. a Mix).
    public static func isYouTubeWatchInPlaylist(_ string: String) -> Bool {
        guard let comps = URLComponents(string: string) else { return false }
        var host = (comps.host ?? "").lowercased()
        for prefix in ["www.", "m.", "music."] where host.hasPrefix(prefix) { host = String(host.dropFirst(prefix.count)) }
        let names = Set((comps.queryItems ?? []).filter { !($0.value ?? "").isEmpty }.map(\.name))
        if host == "youtu.be" { return names.contains("list") }
        return host == "youtube.com" && comps.path == "/watch" && names.contains("v") && names.contains("list")
    }
}
