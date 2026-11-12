import Foundation

/// Single place for the product name so it is easy to rename.
public enum AppIdentity {
    public static let name = "DLLC"
    public static let bundleID = "com.lencier.dllc"
    public static let tagline = "Save clips from YouTube, Instagram, Pinterest and X, then trim, snapshot or turn them into GIFs."
    public static let author = "Lencier"
    public static let ideaBy = "Kannnap"
}

// MARK: - Analysis

public enum Platform: String, Codable, Sendable, CaseIterable {
    case youtube, instagram, pinterest, x, other

    public var displayName: String {
        switch self {
        case .youtube: "YouTube"
        case .instagram: "Instagram"
        case .pinterest: "Pinterest"
        case .x: "X"
        case .other: "Web"
        }
    }

    /// Best-effort mapping from yt-dlp `extractor_key` / host.
    public static func from(extractorKey: String?, url: URL?) -> Platform {
        let key = (extractorKey ?? "").lowercased()
        let host = (url?.host ?? "").lowercased()
        if key.hasPrefix("youtube") || host.hasSuffix("youtube.com") || host == "youtu.be" { return .youtube }
        if key.hasPrefix("instagram") || host.hasSuffix("instagram.com") { return .instagram }
        if key.hasPrefix("pinterest") || host.hasSuffix("pinterest.com") || host == "pin.it" { return .pinterest }
        if key == "twitter" || key.hasPrefix("twitter") || host == "x.com" || host.hasSuffix(".x.com")
            || host.hasSuffix("twitter.com") || host == "t.co" { return .x }
        return .other
    }
}

/// One real, downloadable video rendition (never a synthetic max-res × max-fps combination).
public struct VideoVariant: Codable, Sendable, Hashable, Identifiable {
    public var id: String { formatID }
    public var formatID: String
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    public var vcodec: String
    public var ext: String
    public var dynamicRange: String?     // "SDR", "HDR10", "HLG"…
    public var hasAudio: Bool            // muxed format that already carries audio
    public var filesize: Int64?
    public var filesizeIsEstimate: Bool
    public var tbr: Double?
    public var url: String?              // direct stream URL when exposed (expires)
    public var proto: String?
    /// `http_headers` yt-dlp says are required to fetch `url` (User-Agent, Referer…). Never logged.
    public var httpHeaders: [String: String]? = nil

    public init(formatID: String, width: Int?, height: Int?, fps: Double?, vcodec: String, ext: String,
                dynamicRange: String?, hasAudio: Bool, filesize: Int64?, filesizeIsEstimate: Bool,
                tbr: Double?, url: String?, proto: String?) {
        self.formatID = formatID; self.width = width; self.height = height; self.fps = fps
        self.vcodec = vcodec; self.ext = ext; self.dynamicRange = dynamicRange; self.hasAudio = hasAudio
        self.filesize = filesize; self.filesizeIsEstimate = filesizeIsEstimate; self.tbr = tbr
        self.url = url; self.proto = proto
    }

    public var isHDR: Bool { (dynamicRange ?? "SDR").uppercased() != "SDR" }
    /// Short codec family, e.g. "H.264", "HEVC", "VP9", "AV1".
    public var codecFamily: String { CodecNames.video(vcodec) }
}

public struct AudioVariant: Codable, Sendable, Hashable, Identifiable {
    public var id: String { formatID }
    public var formatID: String
    public var acodec: String
    public var ext: String
    public var abr: Double?
    public var filesize: Int64?
    public var filesizeIsEstimate: Bool
    public var language: String?
    public var url: String?
    public var proto: String?
    public var httpHeaders: [String: String]? = nil

    public init(formatID: String, acodec: String, ext: String, abr: Double?, filesize: Int64?,
                filesizeIsEstimate: Bool, language: String?, url: String?, proto: String?) {
        self.formatID = formatID; self.acodec = acodec; self.ext = ext; self.abr = abr
        self.filesize = filesize; self.filesizeIsEstimate = filesizeIsEstimate; self.language = language
        self.url = url; self.proto = proto
    }

    public var codecFamily: String { CodecNames.audio(acodec) }
}

/// A distinct resolution + FPS combination a user can choose, backed by real formats.
public struct QualityOption: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(height ?? 0)p\(fpsLabel)\(isHDR ? "-hdr" : "")" }
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    public var isHDR: Bool
    /// Format IDs of the variants offering exactly this combination, best first.
    public var formatIDs: [String]
    public var codecs: [String]
    public var estimatedBytes: Int64?
    public var estimateIsRough: Bool

    public init(width: Int?, height: Int?, fps: Double?, isHDR: Bool, formatIDs: [String],
                codecs: [String], estimatedBytes: Int64?, estimateIsRough: Bool) {
        self.width = width; self.height = height; self.fps = fps; self.isHDR = isHDR
        self.formatIDs = formatIDs; self.codecs = codecs
        self.estimatedBytes = estimatedBytes; self.estimateIsRough = estimateIsRough
    }

    public var fpsLabel: String {
        guard let fps, fps > 0, fps < 10_000 else { return "" }
        let r = fps.rounded()
        return abs(fps - r) < 0.05 ? String(Int(r)) : String(format: "%.2f", fps)
    }

    /// "2160p60", "1080p", "720p30 HDR"
    public var label: String {
        var s = height.map { "\($0)p" } ?? "Unknown"
        s += fpsLabel
        if isHDR { s += " HDR" }
        return s
    }
}

/// Entry of a multi-item post / playlist.
public struct MediaEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var index: Int            // 1-based playlist index
    public var title: String?
    public var url: String?
    public var thumbnail: String?
    public var duration: Double?
    public var isVideo: Bool

    public init(id: String, index: Int, title: String?, url: String?, thumbnail: String?,
                duration: Double?, isVideo: Bool) {
        self.id = id; self.index = index; self.title = title; self.url = url
        self.thumbnail = thumbnail; self.duration = duration; self.isVideo = isVideo
    }
}

public struct MediaInfo: Codable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var creator: String?
    public var platform: Platform
    public var extractor: String?
    public var webpageURL: String?
    public var thumbnailURL: String?
    public var duration: Double?
    public var isLive: Bool
    public var videoVariants: [VideoVariant]
    public var audioVariants: [AudioVariant]
    public var qualityOptions: [QualityOption]    // best first
    /// true when no audio stream exists anywhere (silent media)
    public var hasAudio: Bool
    public var hasVideo: Bool
    /// Non-empty for multi-item posts/playlists (analysis of the parent).
    public var entries: [MediaEntry]
    public var analyzedAt: Date
    /// The YouTube client the analysis came from when the default one was refused (see YouTubeClients);
    /// downloads ask as the same client so the format IDs match.
    public var youtubeClient: String?
    /// Files the post offers directly (Pinterest images, carousels, story pages), saved without yt-dlp.
    public var directItems: [DirectItem]?
    /// Where the media really lives when the link was a pin pointing elsewhere; downloads use it.
    public var resolvedURL: String?
    /// A pin's outbound link (the page it was saved from), followed when the pin has no video of its own.
    public var linkedURL: String?
    public var hasDirectItems: Bool { !(directItems ?? []).isEmpty }

    public init(id: String, title: String, creator: String?, platform: Platform, extractor: String?,
                webpageURL: String?, thumbnailURL: String?, duration: Double?, isLive: Bool,
                videoVariants: [VideoVariant], audioVariants: [AudioVariant],
                qualityOptions: [QualityOption], hasAudio: Bool, hasVideo: Bool,
                entries: [MediaEntry], analyzedAt: Date) {
        self.id = id; self.title = title; self.creator = creator; self.platform = platform
        self.extractor = extractor; self.webpageURL = webpageURL; self.thumbnailURL = thumbnailURL
        self.duration = duration; self.isLive = isLive; self.videoVariants = videoVariants
        self.audioVariants = audioVariants; self.qualityOptions = qualityOptions
        self.hasAudio = hasAudio; self.hasVideo = hasVideo; self.entries = entries
        self.analyzedAt = analyzedAt
    }

    public var isMultiItem: Bool { !entries.isEmpty }
    public var bestQuality: QualityOption? { qualityOptions.first }
    public var bestAudio: AudioVariant? {
        audioVariants.max { ($0.abr ?? 0) < ($1.abr ?? 0) }
    }
}

public enum CodecNames {
    public static func video(_ c: String) -> String {
        let s = c.lowercased()
        if s.hasPrefix("avc") || s.hasPrefix("h264") { return "H.264" }
        if s.hasPrefix("hev") || s.hasPrefix("hvc") || s.hasPrefix("h265") { return "HEVC" }
        if s.hasPrefix("vp09") || s.hasPrefix("vp9") { return "VP9" }
        if s.hasPrefix("av01") || s.hasPrefix("av1") { return "AV1" }
        if s.hasPrefix("vp8") { return "VP8" }
        return c.isEmpty ? "Unknown" : c
    }
    public static func audio(_ c: String) -> String {
        let s = c.lowercased()
        if s.hasPrefix("mp4a") || s == "aac" { return "AAC" }
        if s.hasPrefix("opus") { return "Opus" }
        if s.hasPrefix("mp3") { return "MP3" }
        if s.hasPrefix("vorbis") { return "Vorbis" }
        if s.hasPrefix("ac-3") || s == "ac3" { return "AC-3" }
        if s.hasPrefix("ec-3") || s == "eac3" { return "E-AC-3" }
        if s.hasPrefix("flac") { return "FLAC" }
        return c.isEmpty ? "Unknown" : c
    }
}

// MARK: - Output choices

public enum JobKind: String, Codable, Sendable, CaseIterable {
    case video, audio, clip, gif
    public var displayName: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .clip: "Clip"
        case .gif: "GIF"
        }
    }
}

/// How the final container is chosen for video/clip output.
public enum ContainerMode: String, Codable, Sendable, CaseIterable {
    /// Keep the best streams as-is; container chosen for compatibility with them (MP4 when possible, else MKV/WebM).
    case bestQuality
    /// H.264/AAC MP4 that plays everywhere; may re-encode (explained in UI).
    case compatibleMP4
}

/// File type of a saved video or clip.
public enum VideoFileType: String, Codable, Sendable, CaseIterable {
    case mp4, mov, mkv
    public var label: String { rawValue.uppercased() }
}

/// Optional re-encode for smaller files (video, clip and GIF).
public enum Compression: String, Codable, Sendable, CaseIterable {
    case off, smaller, smallest
    public var label: String {
        switch self { case .off: "Original size"; case .smaller: "Smaller"; case .smallest: "Smallest" }
    }
    /// Height cap for video (never upscaled).
    public var maxHeight: Int? { switch self { case .off: nil; case .smaller: 1080; case .smallest: 720 } }
}

public enum QualityChoice: Codable, Sendable, Hashable {
    case best
    /// Specific real combination (QualityOption.id) and its format IDs.
    case option(id: String, height: Int?, fps: Double?, formatIDs: [String])
}

public enum AudioFormatChoice: String, Codable, Sendable, CaseIterable {
    case mp3
    /// Original best audio stream, no re-encode (m4a / opus / webm…).
    case original
}

public enum CutMode: String, Codable, Sendable, CaseIterable {
    /// Re-encode: accurate boundaries.
    case precise
    /// Stream copy: boundaries snap to keyframes, approximate.
    case fast
}

public struct GIFOptions: Codable, Sendable, Hashable {
    public var width: Int = 640
    public var fps: Double = 12
    public var loop: Bool = true
    public init(width: Int = 640, fps: Double = 12, loop: Bool = true) {
        self.width = width; self.fps = fps; self.loop = loop
    }
    public static let maxRecommendedSeconds: Double = 15
    public static let maxRecommendedWidth = 960
}

/// Half-open source time range [start, end) in seconds.
public struct TimeRange: Codable, Sendable, Hashable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public var duration: Double { end - start }
}

public struct OutputOptions: Codable, Sendable, Hashable {
    public var kind: JobKind = .video
    public var quality: QualityChoice = .best
    public var container: ContainerMode = .bestQuality
    public var audioFormat: AudioFormatChoice = .mp3
    public var cutMode: CutMode = .precise
    public var range: TimeRange?
    public var gif: GIFOptions = GIFOptions()
    /// Multi-item selection: playlist indices (1-based). nil = not a multi-item job.
    public var selectedEntries: [Int]?
    /// Stored optionally so queues saved by older versions still load (nil = MP4 / no compression).
    public var fileTypeSetting: VideoFileType?
    public var compressionSetting: Compression?
    public var fileType: VideoFileType {
        get { fileTypeSetting ?? .mp4 }
        set { fileTypeSetting = newValue }
    }
    public var compression: Compression {
        get { compressionSetting ?? .off }
        set { compressionSetting = newValue == .off ? nil : newValue }
    }
    public init() {}
}

// MARK: - Job

public enum JobState: String, Codable, Sendable, CaseIterable {
    case analyzing
    case needsSelection     // multi-item post: user must choose items
    case ready
    case queued
    case downloading
    case processing
    case completed
    case failed
    case cancelled
    case interrupted

    public var isActive: Bool { self == .analyzing || self == .downloading || self == .processing }
    public var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
    /// States from which the user may (re)start the job.
    public var canStart: Bool { self == .ready || self == .failed || self == .cancelled || self == .interrupted }
}

public enum ErrorCategory: String, Codable, Sendable {
    case unsupportedURL, invalidURL, notFound, authRequired, geoBlocked, drmProtected, liveStream
    case network, diskFull, destinationUnavailable, permissionDenied, formatUnavailable
    case toolFailure, extractorBroken, processingFailed, missingAudio, cancelled, unknown
}

public struct JobError: Codable, Sendable, Hashable {
    public var category: ErrorCategory
    public var message: String          // friendly, user-facing
    public var suggestion: String?      // next action
    public var technical: String?       // redacted log tail
    public var isRecoverable: Bool
    public init(category: ErrorCategory, message: String, suggestion: String? = nil,
                technical: String? = nil, isRecoverable: Bool = true) {
        self.category = category; self.message = message; self.suggestion = suggestion
        self.technical = technical; self.isRecoverable = isRecoverable
    }
}

/// Stage-level progress. `fraction` is nil when progress is not knowable (indeterminate).
public struct JobProgress: Codable, Sendable, Hashable {
    public var stage: String
    public var fraction: Double?
    public var detail: String?
    public init(stage: String, fraction: Double? = nil, detail: String? = nil) {
        self.stage = stage; self.fraction = fraction; self.detail = detail
    }
}

public enum CookieSource: Codable, Sendable, Hashable {
    case none
    /// e.g. browser "safari" / "chrome" with optional profile.
    case browser(name: String, profile: String?)
    /// Imported cookies.txt kept in app support (path relative to the cookies directory).
    case file(name: String)
}

public struct Job: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var url: String
    public var createdAt: Date
    public var state: JobState
    public var generation: Int
    public var options: OutputOptions
    public var info: MediaInfo?
    public var progress: JobProgress?
    public var error: JobError?
    public var outputFiles: [String]
    public var enqueueWhenReady: Bool
    public var cookies: CookieSource
    /// Destination folder captured when the job is queued (path + security bookmark).
    public var destinationPath: String?
    public var completedAt: Date?
    /// Notes shown with a completed job (e.g. "Converted VP9 → H.264 for compatibility").
    public var notes: [String]
    /// Project (group) the job belongs to; nil = not in a project. Optional so older queues still decode.
    public var projectID: UUID?

    public init(id: UUID = UUID(), url: String, options: OutputOptions = OutputOptions(),
                cookies: CookieSource = .none, createdAt: Date = Date()) {
        self.id = id; self.url = url; self.createdAt = createdAt; self.state = .analyzing
        self.generation = 0; self.options = options; self.info = nil; self.progress = nil
        self.error = nil; self.outputFiles = []; self.enqueueWhenReady = false
        self.cookies = cookies; self.destinationPath = nil; self.completedAt = nil; self.notes = []
    }

    public var displayTitle: String { info?.title ?? url }
}

/// A named group of jobs. Its files are saved in a subfolder named after the project.
public struct Project: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// Where this project's downloads go, chosen by the user on the project's first download (nil = not asked yet).
    public var saveFolderPath: String?
    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), saveFolderPath: String? = nil) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.saveFolderPath = saveFolderPath
    }

    /// Folder name safe for the file system (no path separators, no leading dots, bounded length).
    public var folderName: String {
        let cleaned = name.unicodeScalars.map { CharacterSet(charactersIn: "/:\\\0").contains($0) || $0.properties.generalCategory == .control ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var out = cleaned
        while out.hasPrefix(".") { out.removeFirst() }
        // Bounded in characters for readability and in UTF-8 bytes for the file system (APFS: 255 bytes).
        if out.count > 80 { out = String(out.prefix(80)) }
        while out.utf8.count > 200 { out.removeLast() }
        out = out.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? "Project" : out
    }

    /// A name short enough that " 12345" can be appended without the folder name cutting it off again
    /// (otherwise de-duplicating a very long name would never find a free one).
    public static func suffixableStem(_ name: String) -> String {
        var stem = String(name.prefix(72))
        while stem.utf8.count > 190 { stem.removeLast() }
        return stem.trimmingCharacters(in: .whitespaces)
    }
}
