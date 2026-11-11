# DLLCCore API contracts (shared between Claude and Codex)

All code lives in `Sources/DLLCCore`, Swift 6 language mode (strict concurrency), Foundation only
(no AppKit/SwiftUI/AVFoundation in core). Types from `Models.swift` are already defined — do not
redefine or change them without saying so. Everything public must be `Sendable`. Tests go in
`Tests/DLLCCoreTests` using **Swift Testing** (`import Testing`, `@Test`, `#expect`). Fixtures in
`Tests/DLLCCoreTests/Fixtures/` (access via `Bundle.module.url(forResource:withExtension:subdirectory: "Fixtures")`).

Build/test with a private scratch path so parallel builds don't collide, e.g.
`swift build --scratch-path .build-codex-a` / `swift test --scratch-path .build-codex-a`.
Bundled tools for manual experiments: `Vendor/tools/{yt-dlp/yt-dlp_macos,ffmpeg,ffprobe,deno}`.

---------------------------------------------------------------------------------------------------
## Group A — ProcessSupervisor.swift, FFmpeg.swift (owner: Codex A)

```swift
public enum OutputStream: Sendable { case stdout, stderr }

public struct ProcessSpec: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL?
    public init(executable: URL, arguments: [String],
                environment: [String: String] = ProcessSpec.defaultEnvironment(),
                workingDirectory: URL? = nil)
    /// Minimal, controlled env: HOME, TMPDIR, USER, LANG/LC_ALL=en_US.UTF-8,
    /// PATH=/usr/bin:/bin:/usr/sbin:/sbin (never the user's PATH), PYTHONUTF8=1.
    public static func defaultEnvironment() -> [String: String]
}

public struct ProcessResult: Sendable {
    public var exitCode: Int32              // -1 when killed by signal
    public var terminationSignal: Int32?    // nil when exited normally
    public var wasCancelled: Bool
    public var stdout: Data                 // only filled when captureStdout == true
    public var stderrTail: String           // last ~16 KB of stderr, UTF-8 (lossy)
    public var succeeded: Bool { get }      // exitCode == 0 && !wasCancelled && terminationSignal == nil
}

public final class ProcessSupervisor: @unchecked Sendable {
    public static let shared: ProcessSupervisor
    /// posix_spawn in a NEW process group (POSIX_SPAWN_SETPGROUP, pgid = child pid), stdin = /dev/null,
    /// stdout/stderr pipes read concurrently on background queues (no deadlock on large output).
    /// Lines are split on "\n" and "\r" (yt-dlp/ffmpeg use \r), delivered without terminators, in order
    /// per stream, decoded as UTF-8 (lossy; partial multibyte sequences buffered across reads).
    /// When captureStdout is true, stdout is accumulated into ProcessResult.stdout and NOT delivered as lines.
    /// Task cancellation of the caller → terminate the whole group: SIGINT, wait 1.5 s, SIGTERM, wait 1.5 s,
    /// SIGKILL; reap with waitpid; the call then RETURNS (not throws) with wasCancelled = true.
    /// Throws only when spawn itself fails (ProcessSupervisorError.spawnFailed(errno, path)).
    public func run(_ spec: ProcessSpec, captureStdout: Bool = false,
                    onLine: (@Sendable (OutputStream, String) -> Void)? = nil) async throws -> ProcessResult
    public var runningCount: Int { get }
    /// Synchronous: terminate every running group (SIGTERM then SIGKILL after timeout). For app quit.
    public func terminateAll(timeout: TimeInterval = 3)
    /// Crash recovery: each spawned group is recorded (pid, pgid, process start time, executable path)
    /// in `registryURL`; on next launch reapOrphans() kills only groups whose pid still has the SAME start
    /// time and executable (protects against PID reuse), then clears the registry.
    public func configureRegistry(_ registryURL: URL)
    public func reapOrphans() -> Int
}
```

FFmpeg.swift:

```swift
public struct MediaInput: Sendable, Hashable {
    public var url: String                     // local path or http(s) URL
    public var headers: [String: String]       // HTTP headers for remote inputs (User-Agent, Cookie…)
    public var isRemote: Bool { get }
    public init(url: String, headers: [String: String] = [:])
}

public enum ImageFormat: String, Codable, Sendable, CaseIterable { case png, jpg }

public enum FFmpegCommand {
    /// Every command: "-hide_banner", "-nostdin", "-y" is NOT used (callers write to fresh temp paths),
    /// use "-n"; "-progress", "pipe:1", "-nostats" when progress is wanted; remote inputs get
    /// "-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5" and "-headers" (CRLF-joined) BEFORE "-i".
    /// Range semantics: [start, end) in source seconds.
    public static func preciseClip(video: MediaInput, audio: MediaInput?, range: TimeRange,
                                   includeAudio: Bool, output: URL, preserveHDR: Bool) -> [String]
        // re-encode: libx264 crf 17 preset medium, yuv420p (or libx265 10-bit + copy color metadata when
        // preserveHDR), aac 192k; accurate seek (-ss before -i on each input + -t duration), -fps_mode passthrough
        // (no frame duplication), +faststart for mp4. Map only first video and (optionally) first audio.
    public static func fastClip(video: MediaInput, audio: MediaInput?, range: TimeRange,
                                includeAudio: Bool, output: URL) -> [String]
        // stream copy, keyframe-approximate. -ss before -i, -t duration, -avoid_negative_ts make_zero.
    public static func snapshot(input: MediaInput, at time: Double, frameDuration: Double?,
                                format: ImageFormat, output: URL) -> [String]
        // Must return the frame whose presentation interval contains `time`
        // (pts <= time < next pts). Seek coarse to max(0, time - 3) before -i, keep timestamps (-copyts),
        // then select the last frame with t <= time + 1e-4 … or an equivalent proven technique. Document it.
        // Full resolution, correct orientation (autorotate default), color: PNG rgb24 / JPG q:v 2 with
        // full-range conversion handled by ffmpeg's scale (out_range=pc when needed for jpg).
    public static func gif(input: MediaInput, range: TimeRange, options: GIFOptions,
                           sourceWidth: Int?, output: URL) -> [String]
        // fps=…,scale=min(width, sourceWidth):-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];
        // [b][p]paletteuse=dither=sierra2_4a ; -loop 0 (or -1 when !loop). Never upscale.
    public static func compatibleMP4(input: URL, output: URL, reencodeVideo: Bool, reencodeAudio: Bool,
                                     hardware: Bool, sourceBitrate: Double?) -> [String]
        // copy what is already H.264/AAC; video re-encode with h264_videotoolbox (-b:v ~ sourceBitrate*1.5,
        // capped) when hardware, else libx264 crf 18; aac 192k; -fps_mode passthrough; +faststart; tag avc1.
    public static func audio(input: URL, output: URL, mp3: Bool) -> [String]
        // mp3: -vn -map 0:a:0 -c:a libmp3lame -q:a 0 ; original: -vn -map 0:a:0 -c:a copy
    public static func proxy(input: URL, output: URL, maxHeight: Int) -> [String]
        // H.264 proxy for preview: h264_videotoolbox, scale to <= maxHeight, -fps_mode passthrough,
        // -copyts not needed but timestamps must map 1:1 to the source (start at the same pts), aac audio.
}

public struct ProbeStream: Sendable, Codable, Hashable {
    public var index: Int
    public var codecType: String        // "video" | "audio" | …
    public var codecName: String
    public var width: Int?
    public var height: Int?
    public var avgFrameRate: Double?
    public var rFrameRate: Double?
    public var pixFmt: String?
    public var colorTransfer: String?   // "smpte2084" / "arib-std-b67" → HDR
    public var rotation: Int?           // from side data displaymatrix
    public var bitRate: Double?
    public var startTime: Double?
}

public struct ProbeResult: Sendable, Codable, Hashable {
    public var duration: Double?
    public var formatName: String
    public var bitRate: Double?
    public var streams: [ProbeStream]
    public var video: ProbeStream? { get }    // first video stream (excluding attached pics)
    public var audio: ProbeStream? { get }
    public var isHDR: Bool { get }
}

public enum FFprobe {
    public static func probeArguments(file: URL) -> [String]          // -v error -print_format json -show_format -show_streams
    public static func parseProbe(_ data: Data) throws -> ProbeResult
    /// Packet PTS of first video stream in presentation order (sorted, seconds) — fast (no decode).
    public static func frameIndexArguments(file: URL) -> [String]     // -select_streams v:0 -show_entries packet=pts_time -of csv=p=0
    public static func parseFrameIndex(_ data: Data) -> [Double]       // sorted ascending, NaN/"N/A" skipped
}

/// Parses `-progress pipe:1` key=value lines; returns out_time seconds when line is out_time_us/ms/out_time.
public enum FFmpegProgressParser {
    public static func outTimeSeconds(_ line: String) -> Double?
    public static func isEnd(_ line: String) -> Bool                    // "progress=end"
}
```

---------------------------------------------------------------------------------------------------
## Group B — YTDLP.swift, ErrorClassifier.swift, FileNaming.swift, Timecode.swift, Redactor.swift (owner: Codex B)

```swift
public struct ToolPaths: Sendable, Hashable {
    public var ytdlp: URL; public var ffmpeg: URL; public var ffprobe: URL; public var deno: URL
    public var ffmpegDirectory: URL { get }      // ffmpeg.deletingLastPathComponent()
    public init(ytdlp: URL, ffmpeg: URL, ffprobe: URL, deno: URL)
}

public enum YTDLPParser {
    /// Parses `yt-dlp -J` output (single video, or playlist/multi-item with `entries`).
    /// - Skips storyboards (format_note "storyboard", vcodec/acodec "none" both, ext mhtml), images.
    /// - VideoVariant for formats with vcodec != "none"; hasAudio = acodec present and != "none".
    /// - AudioVariant for audio-only formats.
    /// - filesize: `filesize` (exact) else `filesize_approx` (estimate); nil if neither.
    /// - Single-format sites (no `formats`, top-level url/ext/vcodec) must still produce a variant.
    /// - For playlist results (`_type` == "playlist" or entries present) fill `entries` (1-based index,
    ///   id, title, url/webpage_url, thumbnail, duration, isVideo) and leave variants empty when flat.
    ///   A playlist with exactly one entry that has formats → treat as that single video.
    /// - hasAudio = any audio variant or any muxed variant; hasVideo = any video variant.
    /// - platform via Platform.from(extractorKey:url:); creator = uploader ?? channel ?? creator ?? uploader_id.
    /// - thumbnail: top-level `thumbnail` else best of `thumbnails`.
    public static func parseInfo(_ json: Data, requestedURL: String) throws -> MediaInfo
    /// Distinct (height, fps rounded to 0.01, HDR) combinations from REAL variants only, sorted best first
    /// (height desc, fps desc, SDR before HDR at same res? → no: HDR listed as its own option after SDR).
    /// formatIDs ordered by preference within a combination: H.264 > HEVC > VP9 > AV1 when `preferCompatible`,
    /// else by tbr desc. Estimated bytes = video filesize (+ best audio filesize when video lacks audio);
    /// estimateIsRough when any part was approximate or derived from tbr*duration.
    public static func buildQualityOptions(video: [VideoVariant], audio: [AudioVariant],
                                           duration: Double?) -> [QualityOption]
}

public struct DownloadProgressEvent: Sendable, Equatable {
    public var status: String               // "downloading" | "finished" | "error"
    public var downloadedBytes: Int64?
    public var totalBytes: Int64?
    public var totalIsEstimate: Bool
    public var speed: Double?               // bytes/s
    public var eta: Double?                 // seconds
    public var fragmentIndex: Int?
    public var fragmentCount: Int?
    public var fraction: Double? { get }    // bytes based, else fragments based, else nil; clamped 0…1
}

public enum YTDLPOutput {
    public static let progressPrefix = "DLLC_PROGRESS "
    public static let filePrefix = "DLLC_FILE "
    public static func parseProgress(_ line: String) -> DownloadProgressEvent?   // prefix + JSON from %(progress)j
    public static func parseFinalPath(_ line: String) -> String?                 // prefix + JSON string
    /// Maps yt-dlp status lines to a friendly stage: "[Merger]"→"Merging", "[ExtractAudio]"→"Extracting audio",
    /// "[VideoConvertor]"/"[VideoRemuxer]"→"Converting", "[Fixup…]"→"Finalizing", "[download] Destination"→nil.
    public static func stage(for line: String) -> String?
}

public enum YTDLPCommand {
    /// --ignore-config --no-plugin-dirs --no-update --no-remote-components --no-color --encoding utf-8
    /// --ffmpeg-location <dir> --no-js-runtimes --js-runtimes deno:<path> --socket-timeout 20
    /// --retries 5 --fragment-retries 10 + cookie args (--cookies-from-browser NAME[:PROFILE] or --cookies FILE).
    public static func baseArguments(tools: ToolPaths, cookies: CookieSource, cookiesDirectory: URL?) -> [String]
    /// -J --no-warnings? (keep warnings on stderr) ; flatPlaylist → --flat-playlist ; playlistItems → --playlist-items "1,3"
    /// ALWAYS ends with "--", url (so a URL starting with "-" can't be an option).
    public static func analyzeArguments(url: String, flatPlaylist: Bool, playlistItems: [Int]?,
                                        tools: ToolPaths, cookies: CookieSource, cookiesDirectory: URL?) -> [String]
    /// Download into workDir with output template "<workDir>/%(playlist_index&{} - |)s%(title).150B [%(id)s].%(ext)s",
    /// --newline --progress --progress-delta 0.25 --progress-template "download:DLLC_PROGRESS %(progress)j"
    /// --print "after_move:DLLC_FILE %(filepath)j" --no-mtime --no-playlist (unless selectedEntries given →
    /// --yes-playlist --playlist-items), --continue, -f formatSelector,
    /// video bestQuality: --merge-output-format "mp4/mkv" (mp4 when streams allow, else mkv);
    /// video compatibleMP4: --merge-output-format "mp4/mkv" too (conversion is done afterwards by MediaProcessor);
    /// audio mp3: -x --audio-format mp3 --audio-quality 0 ; audio original: -x --audio-format best.
    /// clip/gif: NOT handled here (callers use FFmpegCommand on stream URLs or a local source).
    public static func downloadArguments(url: String, options: OutputOptions, workDir: URL,
                                         tools: ToolPaths, cookies: CookieSource, cookiesDirectory: URL?) -> [String]
    /// best → "bv*+ba/b" ; option(formatIDs) → "<id1>+ba/<id1>/<id2>+ba/<id2>…" for video-only ids
    /// (muxed ids just "<id>") ; audio → "ba/b".
    public static func formatSelector(options: OutputOptions) -> String
}

public enum ErrorClassifier {
    /// Maps yt-dlp/ffmpeg stderr + exit code to a friendly JobError with a next-action suggestion.
    /// Must recognise at least: Unsupported URL, "is not a valid URL", HTTP 404 / "Video unavailable" /
    /// "This video has been removed", login/"Sign in to confirm"/"login required"/"rate-limit"/private,
    /// "not available in your country", DRM, live stream not finished, network/timeouts/"Unable to download
    /// webpage" + URLError-like text, "No space left on device", "Permission denied"/"Operation not permitted",
    /// "Requested format is not available", extractor errors ("Unable to extract", "please report this issue")
    /// → extractorBroken suggesting the yt-dlp update in Settings. technical = Redactor.redact(last ~40 lines).
    public static func classify(stderr: String, exitCode: Int32) -> JobError
}

public enum Redactor {
    /// Removes cookies, Authorization/Cookie headers, query strings of googlevideo/cdn URLs (keep host+path),
    /// tokens like "sig=", "token=", "key=", home-directory user name → "~".
    public static func redact(_ text: String) -> String
}

public enum FileNaming {
    /// Safe filename component: keeps Unicode/Thai, removes "/" ":" control chars, trims dots/spaces,
    /// collapses whitespace, limits to maxBytes UTF-8 (default 180) without splitting grapheme clusters,
    /// falls back to "Untitled".
    public static func sanitize(_ name: String, maxBytes: Int = 180) -> String
    /// Returns a URL in `directory` that does not exist yet: "Name.ext", "Name (2).ext", "Name (3).ext"…
    public static func uniqueURL(in directory: URL, baseName: String, ext: String,
                                 fileManager: FileManager = .default) -> URL
    /// "Title — 00-01-23.456" style suffix for snapshots/clips (filesystem-safe, no ":").
    public static func timeTag(_ seconds: Double) -> String           // "00h01m23s456" → choose "01-23.456" / "1-02-03.500"
    public static func rangeTag(_ range: TimeRange) -> String         // "0-12.000–0-18.500"
}

public enum Timecode {
    /// Accepts "83.5", "1:23.5", "01:23", "1:02:03.25", "1:02:03:12" is NOT accepted (no frames) → nil.
    /// Rejects negatives, empty, garbage, >59 minutes/seconds components when a higher unit is present.
    public static func parse(_ text: String) -> Double?
    /// "1:02:03.250" when >= 1h, else "02:03.250" (always millis).
    public static func format(_ seconds: Double, alwaysHours: Bool = false) -> String
}

public enum RangeIssue: Equatable, Sendable { case empty, malformedStart, malformedEnd, negative,
    startNotBeforeEnd, beyondDuration, tooShort }

public enum RangeValidator {
    /// minDuration default = one frame (1/fps) or 0.05 s. Clamps nothing; reports the first issue.
    public static func validate(start: Double?, end: Double?, duration: Double?,
                                minDuration: Double) -> RangeIssue?
}
```
