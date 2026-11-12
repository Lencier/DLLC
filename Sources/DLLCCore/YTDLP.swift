import Foundation

public struct ToolPaths: Sendable, Hashable {
    public var ytdlp: URL
    public var ffmpeg: URL
    public var ffprobe: URL
    public var deno: URL
    public var ffmpegDirectory: URL { ffmpeg.deletingLastPathComponent() }
    public init(ytdlp: URL, ffmpeg: URL, ffprobe: URL, deno: URL) {
        self.ytdlp = ytdlp; self.ffmpeg = ffmpeg; self.ffprobe = ffprobe; self.deno = deno
    }
}

public enum YTDLPParser {
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, String(cString: n.objCType) != "c", n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func thumbnail(_ item: [String: Any]) -> String? {
        if let value = item["thumbnail"] as? String { return value }
        return (item["thumbnails"] as? [[String: Any]])?.sorted {
            (number($0["preference"]) ?? 0, number($0["height"]) ?? 0) < (number($1["preference"]) ?? 0, number($1["height"]) ?? 0)
        }.last?["url"] as? String
    }
    public static func parseInfo(_ json: Data, requestedURL: String) throws -> MediaInfo {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return parse(root, requestedURL: requestedURL)
    }
    private static func parse(_ root: [String: Any], requestedURL: String) -> MediaInfo {
        let children = root["entries"] as? [Any]
        if let children, children.count == 1, let child = children.first as? [String: Any],
           let formats = child["formats"] as? [[String: Any]], !formats.isEmpty {
            return parse(child, requestedURL: requestedURL)
        }
        var video: [VideoVariant] = [], audio: [AudioVariant] = []
        let formats = root["formats"] as? [[String: Any]] ?? (root["url"] is String && children == nil ? [root] : [])
        let imageExtensions = ["mhtml", "jpg", "jpeg", "png", "webp", "gif", "avif"]
        for f in formats {
            let ext = f["ext"] as? String ?? ""
            let vc = f["vcodec"] as? String ?? "none", ac = f["acodec"] as? String ?? "none"
            guard !imageExtensions.contains(ext.lowercased()),
                  !(f["format_note"] as? String ?? "").lowercased().contains("storyboard") else { continue }
            let id = f["format_id"] as? String ?? "default"
            let exact = number(f["filesize"]), approximate = number(f["filesize_approx"])
            let size = (exact ?? approximate).flatMap { $0 >= 0 && $0 < Double(Int64.max) ? Int64($0) : nil }
            let estimated = exact == nil && approximate != nil
            // Per-format headers matter: CDNs (e.g. googlevideo) reject a URL fetched with another client's User-Agent.
            let headers = (f["http_headers"] as? [String: Any])?.compactMapValues { $0 as? String }
            if vc != "none" && !vc.isEmpty {
                var v = VideoVariant(formatID: id, width: number(f["width"]).flatMap(safeInt),
                    height: number(f["height"]).flatMap(safeInt), fps: number(f["fps"]), vcodec: vc, ext: ext,
                    dynamicRange: f["dynamic_range"] as? String, hasAudio: ac != "none" && !ac.isEmpty,
                    filesize: size, filesizeIsEstimate: estimated, tbr: number(f["tbr"]),
                    url: f["url"] as? String, proto: f["protocol"] as? String)
                v.httpHeaders = headers
                video.append(v)
            } else if ac != "none" && !ac.isEmpty {
                var a = AudioVariant(formatID: id, acodec: ac, ext: ext, abr: number(f["abr"]),
                    filesize: size, filesizeIsEstimate: estimated, language: f["language"] as? String,
                    url: f["url"] as? String, proto: f["protocol"] as? String)
                a.httpHeaders = headers
                audio.append(a)
            }
        }
        let entries = (children ?? []).enumerated().compactMap { index, value -> MediaEntry? in
            guard let c = value as? [String: Any] else { return nil }
            let ext = c["ext"] as? String ?? ""
            return MediaEntry(id: c["id"] as? String ?? "\(index + 1)",
                index: number(c["playlist_index"]).flatMap(safeInt) ?? index + 1,
                title: c["title"] as? String, url: c["webpage_url"] as? String ?? c["url"] as? String,
                thumbnail: thumbnail(c), duration: number(c["duration"]),
                isVideo: !imageExtensions.contains(ext.lowercased()) && (c["vcodec"] as? String != "none"))
        }
        let duration = number(root["duration"])
        let extractor = root["extractor_key"] as? String ?? root["extractor"] as? String
        return MediaInfo(id: root["id"] as? String ?? "", title: root["title"] as? String ?? "Untitled",
            creator: ["uploader", "channel", "creator", "uploader_id"].compactMap { root[$0] as? String }.first,
            platform: Platform.from(extractorKey: extractor, url: URL(string: requestedURL)), extractor: extractor,
            webpageURL: root["webpage_url"] as? String ?? requestedURL, thumbnailURL: thumbnail(root), duration: duration,
            isLive: root["is_live"] as? Bool == true || root["live_status"] as? String == "is_live",
            videoVariants: video, audioVariants: audio,
            qualityOptions: buildQualityOptions(video: video, audio: audio, duration: duration),
            hasAudio: !audio.isEmpty || video.contains(where: \.hasAudio), hasVideo: !video.isEmpty,
            entries: entries, analyzedAt: Date())
    }
    private static func safeInt(_ n: Double) -> Int? { n >= 0 && n < Double(Int.max) ? Int(n) : nil }
    private struct Combination: Hashable { var height: Int?; var fps: Double?; var hdr: Bool }
    public static func buildQualityOptions(video: [VideoVariant], audio: [AudioVariant], duration: Double?) -> [QualityOption] {
        let groups = Dictionary(grouping: video) { Combination(height: $0.height, fps: $0.fps.map { ($0 * 100).rounded() / 100 }, hdr: $0.isHDR) }
        func bytes(_ exact: Int64?, _ bitrate: Double?) -> Int64? {
            if let exact { return exact }
            guard let bitrate, let duration, bitrate.isFinite, duration.isFinite else { return nil }
            let n = bitrate * 1000 / 8 * duration
            return n >= 0 && n < Double(Int64.max) ? Int64(n) : nil
        }
        let bestAudio = audio.max { ($0.abr ?? 0) < ($1.abr ?? 0) }
        return groups.map { key, variants in
            // The contract has no preferCompatible parameter; prefer compatible codecs, then bitrate.
            let rank = ["H.264": 4, "HEVC": 3, "VP9": 2, "AV1": 1]
            let sorted = variants.sorted {
                let l = rank[$0.codecFamily] ?? 0, r = rank[$1.codecFamily] ?? 0
                if l != r { return l > r }
                if $0.tbr != $1.tbr { return ($0.tbr ?? 0) > ($1.tbr ?? 0) }
                return $0.formatID < $1.formatID
            }
            let v = sorted[0]
            var size = bytes(v.filesize, v.tbr)
            var rough = v.filesizeIsEstimate || v.filesize == nil
            if !v.hasAudio {
                if let a = bestAudio, let vb = size, let ab = bytes(a.filesize, a.abr), vb <= Int64.max - ab {
                    size = vb + ab; rough = rough || a.filesizeIsEstimate || a.filesize == nil
                } else { size = nil }
            }
            var codecs: [String] = []
            for v in sorted where !codecs.contains(v.codecFamily) { codecs.append(v.codecFamily) }
            return QualityOption(width: v.width, height: key.height, fps: key.fps, isHDR: key.hdr,
                formatIDs: sorted.map(\.formatID), codecs: codecs, estimatedBytes: size, estimateIsRough: rough)
        }.sorted {
            if $0.height != $1.height { return ($0.height ?? 0) > ($1.height ?? 0) }
            if $0.fps != $1.fps { return ($0.fps ?? 0) > ($1.fps ?? 0) }
            return !$0.isHDR && $1.isHDR
        }
    }
}

public struct DownloadProgressEvent: Sendable, Equatable {
    public var status: String
    public var downloadedBytes: Int64?
    public var totalBytes: Int64?
    public var totalIsEstimate: Bool
    public var speed: Double?
    public var eta: Double?
    public var fragmentIndex: Int?
    public var fragmentCount: Int?
    public var fraction: Double? {
        if let d = downloadedBytes, let t = totalBytes, t > 0 { return min(1, max(0, Double(d) / Double(t))) }
        if let i = fragmentIndex, let c = fragmentCount, c > 0 { return min(1, max(0, Double(i) / Double(c))) }
        return nil
    }
}

public enum YTDLPOutput {
    public static let progressPrefix = "DLLC_PROGRESS "
    public static let filePrefix = "DLLC_FILE "
    public static func parseProgress(_ line: String) -> DownloadProgressEvent? {
        guard line.hasPrefix(progressPrefix), let data = String(line.dropFirst(progressPrefix.count)).data(using: .utf8),
              let p = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let status = p["status"] as? String else { return nil }
        func n(_ key: String) -> Double? {
            guard let v = p[key] as? NSNumber, String(cString: v.objCType) != "c", v.doubleValue.isFinite else { return nil }
            return v.doubleValue >= 0 ? v.doubleValue : nil
        }
        func integer(_ key: String) -> Int64? { n(key).flatMap { $0 < Double(Int64.max) ? Int64($0) : nil } }
        return DownloadProgressEvent(status: status, downloadedBytes: integer("downloaded_bytes"),
            totalBytes: integer("total_bytes") ?? integer("total_bytes_estimate"), totalIsEstimate: integer("total_bytes") == nil && integer("total_bytes_estimate") != nil,
            speed: n("speed"), eta: n("eta"), fragmentIndex: integer("fragment_index").map(Int.init), fragmentCount: integer("fragment_count").map(Int.init))
    }
    public static func parseFinalPath(_ line: String) -> String? {
        guard line.hasPrefix(filePrefix), let data = String(line.dropFirst(filePrefix.count)).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }
    public static func stage(for line: String) -> String? {
        if line.hasPrefix("[Merger]") { return "Merging" }
        if line.hasPrefix("[ExtractAudio]") { return "Extracting audio" }
        if line.hasPrefix("[VideoConvertor]") || line.hasPrefix("[VideoRemuxer]") { return "Converting" }
        if line.hasPrefix("[Fixup") { return "Finalizing" }
        return nil
    }
}

public enum YTDLPCommand {
    public static func baseArguments(tools: ToolPaths, cookies: CookieSource, cookiesDirectory: URL?) -> [String] {
        var args = ["--ignore-config", "--no-plugin-dirs", "--no-update", "--no-remote-components", "--no-color", "--encoding", "utf-8",
            "--ffmpeg-location", tools.ffmpegDirectory.path, "--no-js-runtimes", "--js-runtimes", "deno:\(tools.deno.path)",
            "--socket-timeout", "20", "--retries", "5", "--fragment-retries", "10"]
        switch cookies {
        case .none: break
        case let .browser(name, profile):
            let browsers: Set = ["safari", "chrome", "chromium", "firefox", "brave", "edge", "vivaldi", "opera", "whale"]
            if browsers.contains(name), profile.map({ !$0.contains(":") && !$0.contains("+") && !$0.hasPrefix("-") }) ?? true {
                args += ["--cookies-from-browser", name + (profile.map { ":\($0)" } ?? "")]
            }
        case let .file(name):
            // Only a plain file name inside the app's private cookies folder (queue.json is user-writable).
            if let directory = cookiesDirectory, !name.isEmpty, name != ".", name != "..",
               !name.contains("/"), !name.hasPrefix("-") {
                args += ["--cookies", directory.appendingPathComponent(name).path]
            }
        }
        return args
    }
    public static func analyzeArguments(url: String, flatPlaylist: Bool, playlistItems: [Int]?, tools: ToolPaths, cookies: CookieSource, cookiesDirectory: URL?, youtubeClient: String? = nil) -> [String] {
        var args = baseArguments(tools: tools, cookies: cookies, cookiesDirectory: cookiesDirectory) + YouTubeClients.arguments(youtubeClient) + ["-J"]
        if flatPlaylist { args += ["--flat-playlist"] }
        if let playlistItems { args += ["--playlist-items", playlistItems.map(String.init).joined(separator: ",")] }
        // A YouTube watch link that also names a playlist (Mix "&list=RD…", "&list=PL…&index=3") means the
        // video being watched. Whole playlists use /playlist?list=… links, which stay playlists.
        else if LinkExtractor.isYouTubeWatchInPlaylist(url) { args += ["--no-playlist"] }
        return args + ["--", url]
    }
    public static func downloadArguments(url: String, options: OutputOptions, workDir: URL, tools: ToolPaths, cookies: CookieSource, cookiesDirectory: URL?, youtubeClient: String? = nil) -> [String] {
        var args = baseArguments(tools: tools, cookies: cookies, cookiesDirectory: cookiesDirectory) + YouTubeClients.arguments(youtubeClient) + [
            "-o", workDir.path.replacingOccurrences(of: "%", with: "%%") + "/%(playlist_index&{} - |)s%(title).150B [%(id)s].%(ext)s",
            "--newline", "--no-quiet", "--progress", "--progress-delta", "0.25", "--progress-template", "download:DLLC_PROGRESS %(progress)j",
            "--print", "after_move:DLLC_FILE %(filepath)j", "--no-mtime", "--continue", "-f", formatSelector(options: options)]
        if let entries = options.selectedEntries { args += ["--yes-playlist", "--playlist-items", entries.map(String.init).joined(separator: ",")] }
        else { args += ["--no-playlist"] }
        if options.kind == .audio {
            args += ["-x", "--audio-format", options.audioFormat == .mp3 ? "mp3" : "best"]
            if options.audioFormat == .mp3 { args += ["--audio-quality", "0"] }
        } else {
            // Merge straight into the wanted type when every codec fits it; MOV is finished by ffmpeg afterwards.
            switch options.fileType {
            case .mp4: args += ["--merge-output-format", "mp4/mkv"]
            case .mkv: args += ["--merge-output-format", "mkv"]
            case .mov: args += ["--merge-output-format", "mp4/mkv"]
            }
        }
        return args + ["--", url]
    }
    public static func formatSelector(options: OutputOptions) -> String {
        if options.kind == .audio { return "ba/b" }
        switch options.quality {
        case .best: return "bv*+ba/b"
        case let .option(_, height, _, ids):
            // QualityChoice does not carry hasAudio; the /id fallback also handles muxed formats.
            let safe = ids.filter { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) } }
            guard !safe.isEmpty else { return "bv*+ba/b" }
            // HLS copies can hold packets without timestamps, which makes the merge fail ("Conversion failed"),
            // so a direct copy of the listed formats is tried first; HLS stays as the fallback for HLS-only sites.
            let direct = safe.map { "\($0)[protocol!*=m3u8]" }
            // YouTube doesn't always offer the same formats twice: when none of the analysed IDs is there any
            // more, take the closest at or below the chosen height rather than failing.
            var tail = ["bv*+ba/b"]
            if let height, height > 0 {
                tail.insert("bv*[height<=\(height)][protocol!*=m3u8]+ba/bv*[height<=\(height)]+ba/b[height<=\(height)]", at: 0)
            }
            return ((direct + safe).flatMap { ["\($0)+ba", $0] } + tail).joined(separator: "/")
        }
    }
}
