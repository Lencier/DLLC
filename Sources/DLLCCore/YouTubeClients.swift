import Foundation

/// When YouTube refuses the default web client (SABR-only formats, "page needs to be reloaded", 403s, a broken
/// signature), yt-dlp can ask as another YouTube client instead. Order measured with the bundled yt-dlp
/// (2026.10): tv_downgraded gives full quality without HLS; android is a last resort (360p at most).
public enum YouTubeClients {
    public static let cascade = ["tv_downgraded", "web_safari", "ios", "android"]

    public static func isYouTube(_ url: String) -> Bool {
        guard let host = URL(string: url.trimmingCharacters(in: .whitespaces))?.host?.lowercased() else { return false }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return h == "youtu.be" || h == "youtube.com" || h.hasSuffix(".youtube.com")
    }

    /// True when the error looks like the client was refused, so another client may work.
    public static func shouldSwitch(stderr: String) -> Bool {
        let s = stderr.lowercased()
        return ["sabr", "the page needs to be reloaded", "http error 403", "nsig", "only images are available",
                "requested format is not available", "requested format not available", "conversion failed"]
            .contains { s.contains($0) }
    }

    /// The client to try after `current` (nil = yt-dlp's default), or nil when every client has been tried.
    public static func next(after current: String?) -> String? {
        guard let current else { return cascade.first }
        guard let i = cascade.firstIndex(of: current), i + 1 < cascade.count else { return nil }
        return cascade[i + 1]
    }

    /// yt-dlp arguments selecting `client` (ignored unless it's one of ours).
    public static func arguments(_ client: String?) -> [String] {
        guard let client, cascade.contains(client) else { return [] }
        return ["--extractor-args", "youtube:player_client=\(client)"]
    }

    /// YouTube sometimes answers the default client with 360p only; worth asking another client once.
    public static func looksDegraded(_ info: MediaInfo) -> Bool {
        guard info.hasVideo, !info.isMultiItem else { return false }
        let top = maxHeight(info)
        return top > 0 && top <= 360
    }

    public static func maxHeight(_ info: MediaInfo) -> Int {
        info.qualityOptions.compactMap(\.height).max() ?? 0
    }
}
