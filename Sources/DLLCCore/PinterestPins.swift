import Foundation

/// One file a post offers directly (an image or an MP4), downloaded without yt-dlp.
public struct DirectItem: Codable, Sendable, Hashable {
    public var url: String
    /// Tried when `url` fails (e.g. the 736px copy when an original isn't served).
    public var fallbackURL: String?
    public var isVideo: Bool
    public var width: Int?
    public var height: Int?
    public init(url: String, fallbackURL: String? = nil, isVideo: Bool, width: Int? = nil, height: Int? = nil) {
        self.url = url; self.fallbackURL = fallbackURL; self.isVideo = isVideo; self.width = width; self.height = height
    }
    public var fileExtension: String {
        let ext = (URL(string: url)?.pathExtension ?? "").lowercased()
        return FileSafety.mediaExtensions.contains(ext) ? ext : (isVideo ? "mp4" : "jpg")
    }
}

/// Pins yt-dlp can't save — images, carousels (images and videos mixed), story pages — read from Pinterest's
/// public pin data, the same request the website makes. No login; files come only from Pinterest's media hosts.
public enum PinterestPins {
    public static func isPinterest(_ url: String) -> Bool {
        guard let host = URL(string: url.trimmingCharacters(in: .whitespaces))?.host?.lowercased() else { return false }
        return host == "pin.it" || host.hasPrefix("pinterest.") || host.contains(".pinterest.")
    }

    /// "/pin/123/", "/pin/some-title--123/" → "123".
    public static func pinID(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "pin"), i + 1 < parts.count else { return nil }
        let slug = parts[i + 1]
        let tail = slug.components(separatedBy: "--").last ?? slug
        return !tail.isEmpty && tail.allSatisfy(\.isNumber) ? tail : nil
    }

    /// Only https files on Pinterest's own media servers are ever fetched.
    static func isMediaURL(_ s: String) -> Bool {
        guard let u = URL(string: s), u.scheme == "https", let h = u.host?.lowercased() else { return false }
        return h == "pinimg.com" || h.hasSuffix(".pinimg.com")
    }

    struct Parsed { var title: String; var creator: String?; var thumbnail: String?; var items: [DirectItem]; var link: String? = nil }

    /// A pin's outbound link worth following: http(s), and not back to Pinterest's media servers.
    static func outboundLink(_ any: Any?) -> String? {
        guard let s = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), let u = URL(string: s),
              u.scheme == "https" || u.scheme == "http", let h = u.host?.lowercased(), !h.isEmpty,
              !(h == "pinimg.com" || h.hasSuffix(".pinimg.com")) else { return nil }
        return s
    }

    /// Reads the PinResource JSON. Pure, so it is tested with captured responses.
    static func parse(_ data: Data, id: String) throws -> Parsed {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pin = (root["resource_response"] as? [String: Any])?["data"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        var items: [DirectItem] = []
        var link = outboundLink(pin["link"])
        if let slots = (pin["carousel_data"] as? [String: Any])?["carousel_slots"] as? [[String: Any]] {
            for slot in slots {
                link = link ?? outboundLink(slot["link"])
                if let item = video(slot["videos"]) ?? image(slot["images"]) { items.append(item) } }
        } else if let pages = (pin["story_pin_data"] as? [String: Any])?["pages"] as? [[String: Any]] {
            for page in pages {
                for block in page["blocks"] as? [[String: Any]] ?? [] {
                    let img = (block["image"] as? [String: Any])?["images"]
                    if let item = video(block["video"]) ?? image(img) { items.append(item) }
                }
            }
        }
        if items.isEmpty, let item = video(pin["videos"]) ?? image(pin["images"]) { items.append(item) }

        let text = [pin["title"], pin["grid_title"], pin["seo_title"], pin["description"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        let title = text.map { $0.count > 90 ? String($0.prefix(90)) + "…" : $0 } ?? "Pinterest pin \(id)"
        let creator = ((pin["closeup_attribution"] ?? pin["pinner"]) as? [String: Any])?["full_name"] as? String
        let thumb = ((pin["images"] as? [String: Any])?["736x"] as? [String: Any])?["url"] as? String
        return Parsed(title: title, creator: creator, thumbnail: thumb.flatMap { isMediaURL($0) ? $0 : nil }, items: items, link: link)
    }

    /// The MP4 of a `videos` object (HLS copies are skipped), largest first.
    static func video(_ any: Any?) -> DirectItem? {
        guard let list = (any as? [String: Any])?["video_list"] as? [String: Any] else { return nil }
        let mp4s = list.values.compactMap { $0 as? [String: Any] }.filter {
            guard let u = $0["url"] as? String else { return false }
            return isMediaURL(u) && URL(string: u)?.pathExtension.lowercased() == "mp4"
        }
        guard let best = mp4s.max(by: { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }),
              let url = best["url"] as? String else { return nil }
        return DirectItem(url: url, isVideo: true, width: best["width"] as? Int, height: best["height"] as? Int)
    }

    /// The original-size image of an `images` object; the 736px copy is the fallback.
    static func image(_ any: Any?) -> DirectItem? {
        guard let images = any as? [String: Any] else { return nil }
        func entry(_ key: String) -> (String, Int?, Int?)? {
            guard let e = images[key] as? [String: Any], let u = e["url"] as? String, isMediaURL(u) else { return nil }
            return (u, e["width"] as? Int, e["height"] as? Int)
        }
        if let (u, w, h) = entry("orig") ?? entry("originals") {
            return DirectItem(url: u, fallbackURL: entry("736x")?.0, isVideo: false, width: w, height: h)
        }
        guard let (u, w, h) = entry("736x") ?? entry("564x") ?? entry("474x") else { return nil }
        let original = u.replacingOccurrences(of: #"/\d+x/"#, with: "/originals/", options: .regularExpression)
        return original == u ? DirectItem(url: u, isVideo: false, width: w, height: h)
                             : DirectItem(url: original, fallbackURL: u, isVideo: false)
    }

    /// Looks the pin up on Pinterest. Nil when the link isn't a pin, or the pin offers no files and links nowhere.
    public static func fetch(url: String, session: URLSession = .shared) async throws -> MediaInfo? {
        guard var link = URL(string: url.trimmingCharacters(in: .whitespaces)), link.scheme?.hasPrefix("http") == true else { return nil }
        if link.host?.lowercased() == "pin.it" {
            // Short links redirect to the pin page.
            var req = URLRequest(url: link); req.httpMethod = "HEAD"
            let (_, response) = try await session.data(for: req)
            guard let final = response.url, isPinterest(final.absoluteString) else { return nil }
            link = final
        }
        guard let id = pinID(from: link) else { return nil }
        var comps = URLComponents(string: "https://www.pinterest.com/resource/PinResource/get/")!
        comps.queryItems = [URLQueryItem(name: "data", value: #"{"options":{"field_set_key":"unauth_react_main_pin","id":"\#(id)"}}"#)]
        var req = URLRequest(url: comps.url!)
        req.setValue("www/pin/[id].js", forHTTPHeaderField: "X-Pinterest-PWS-Handler")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let p = try parse(data, id: id)
        guard !p.items.isEmpty || p.link != nil else { return nil }
        var info = MediaInfo(id: id, title: p.title, creator: p.creator, platform: .pinterest, extractor: "PinterestDirect",
                             webpageURL: "https://www.pinterest.com/pin/\(id)/", thumbnailURL: p.thumbnail ?? p.items.first { !$0.isVideo }?.url,
                             duration: nil, isLive: false, videoVariants: [], audioVariants: [], qualityOptions: [],
                             hasAudio: false, hasVideo: false, entries: [], analyzedAt: Date())
        info.directItems = p.items.isEmpty ? nil : p.items
        info.linkedURL = p.link
        return info
    }

    /// "4 images · 2 videos".
    public static func summary(_ items: [DirectItem]) -> String {
        let v = items.filter(\.isVideo).count, i = items.count - v
        return [i > 0 ? "\(i) image\(i == 1 ? "" : "s")" : nil, v > 0 ? "\(v) video\(v == 1 ? "" : "s")" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
