import Foundation

public struct MediaInput: Sendable, Hashable {
    public var url: String
    public var headers: [String: String]
    public var isRemote: Bool {
        let scheme = URL(string: url)?.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }
    public init(url: String, headers: [String: String] = [:]) {
        self.url = url; self.headers = headers
    }
}

public enum ImageFormat: String, Codable, Sendable, CaseIterable { case png, jpg }

public enum FFmpegCommand {
    private static let base = ["-hide_banner", "-nostdin", "-n"]
    private static let progress = ["-progress", "pipe:1", "-nostats"]
    private static func number(_ value: Double) -> String { String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), value) }
    private static func input(_ media: MediaInput, seek: Double? = nil) -> [String] {
        var args: [String] = []
        if let seek { args += ["-ss", number(seek)] }
        // Inputs come from site-controlled metadata: a remote playlist may only pull more network
        // streams, and a local file may never reach out to the network or other local files' protocols.
        args += ["-protocol_whitelist", media.isRemote ? "https,http,tls,tcp,crypto" : "file"]
        if media.isRemote {
            args += ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5"]
            let headers = media.headers.sorted { $0.key < $1.key }.filter {
                !$0.key.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == ":" }) &&
                !$0.value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" })
            }.map { "\($0.key): \($0.value)\r\n" }.joined()
            if !headers.isEmpty { args += ["-headers", headers] }
        }
        return args + ["-i", media.url]
    }
    private static func clipInputs(video: MediaInput, audio: MediaInput?, range: TimeRange, includeAudio: Bool) -> [String] {
        var args = input(video, seek: range.start)
        if includeAudio, let audio { args += input(audio, seek: range.start) }
        args += ["-map", "0:v:0"]
        if includeAudio { args += ["-map", audio == nil ? "0:a:0?" : "1:a:0"] }
        else { args += ["-an"] }
        return args + ["-t", number(range.duration)]
    }
    private static func faststart(_ output: URL) -> [String] {
        ["mp4", "mov", "m4v"].contains(output.pathExtension.lowercased()) ? ["-movflags", "+faststart"] : []
    }
    /// PQ/HLG → SDR BT.709 with tone mapping (a plain 8-bit conversion leaves HDR washed out).
    /// `transfer` is the source's ffprobe color_transfer ("smpte2084" or "arib-std-b67").
    static func sdrToneMap(transfer: String) -> String {
        let tin = transfer == "arib-std-b67" ? "arib-std-b67" : "smpte2084"
        return "zscale=tin=\(tin):min=bt2020nc:pin=bt2020:rin=tv:t=linear:npl=100:m=bt2020nc:p=bt2020," +
            "format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"
    }
    private static let sdrTags = ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]

    public static func preciseClip(video: MediaInput, audio: MediaInput?, range: TimeRange,
                                   includeAudio: Bool, output: URL, preserveHDR: Bool,
                                   hdrTransfer: String? = nil) -> [String] {
        let toneMap = !preserveHDR && hdrTransfer != nil
        return base + progress + clipInputs(video: video, audio: audio, range: range, includeAudio: includeAudio) +
        (toneMap ? ["-vf", sdrToneMap(transfer: hdrTransfer!)] + sdrTags : []) +
        ["-c:v", preserveHDR ? "libx265" : "libx264", "-crf", "17", "-preset", "medium",
         "-pix_fmt", preserveHDR ? "yuv420p10le" : "yuv420p", "-map_metadata", "0",
         "-c:a", "aac", "-b:a", "192k", "-fps_mode", "passthrough"] + faststart(output) + [output.path]
    }
    public static func fastClip(video: MediaInput, audio: MediaInput?, range: TimeRange,
                                includeAudio: Bool, output: URL) -> [String] {
        base + progress + clipInputs(video: video, audio: audio, range: range, includeAudio: includeAudio) +
        ["-c", "copy", "-avoid_negative_ts", "make_zero"] + faststart(output) + [output.path]
    }
    /// ffprobe arguments reading an input's start time (honours headers/whitelist for remote inputs).
    public static func startTimeProbe(input media: MediaInput) -> [String] {
        ["-v", "error", "-show_entries", "format=start_time", "-of", "default=nw=1:nk=1"] + input(media)
    }

    /// `origin` is the file's start time: `time` counts from it (like `-ss`), while the filters see raw PTS.
    public static func snapshot(input media: MediaInput, at time: Double, frameDuration: Double?,
                                format: ImageFormat, origin: Double = 0, hdrTransfer: String? = nil,
                                output: URL) -> [String] {
        // Keep the keyframe preceding the coarse seek (including sparse VFR frames). Trim on
        // original PTS, then reverse this short decoded window to emit its final frame first.
        // trim signals EOF one second later; select enforces the exact cutoff without trim's
        // rounding of end-time to the input timebase discarding a frame exactly at the playhead.
        // Nominal frameDuration cannot identify a VFR presentation interval and is not used.
        let end = max(0, time) + origin + 0.000001
        let filter = "trim=end=\(number(end + 1)),select='lte(t,\(number(end)))',reverse," +
            (hdrTransfer.map { sdrToneMap(transfer: $0) + "," } ?? "") +
            (format == .png ? "format=rgb24" : "scale=out_range=pc,format=yuvj420p")
        return base + ["-copyts", "-noaccurate_seek"] + input(media, seek: max(0, time - 3)) +
            ["-map", "0:v:0", "-an", "-vf", filter, "-frames:v", "1", "-fps_mode", "passthrough"] +
            (format == .jpg ? ["-q:v", "2"] : []) + ["-update", "1", output.path]
    }
    public static func gif(input media: MediaInput, range: TimeRange, options: GIFOptions,
                           sourceWidth: Int?, hdrTransfer: String? = nil, compression: Compression = .off,
                           output: URL) -> [String] {
        // Hard limits regardless of the UI: never upscale, at most 1920 px wide and 1–30 fps.
        // Smaller GIFs use fewer colours and ordered dithering (compresses far better); Smallest also caps size and rate.
        var width = max(2, min(options.width, sourceWidth ?? options.width, 1920))
        var fps = min(30, max(1, options.fps.isFinite ? options.fps : 12))
        if compression == .smallest { width = min(width, 480); fps = min(fps, 10) }
        let palette: String
        switch compression {
        case .off: palette = "palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a"
        case .smaller: palette = "palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle"
        case .smallest: palette = "palettegen=max_colors=64:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=2:diff_mode=rectangle"
        }
        let filter = (hdrTransfer.map { sdrToneMap(transfer: $0) + "," } ?? "") + "fps=\(number(fps)),scale=w='min(\(width),iw)':h=-2:flags=lanczos,split[a][b];[a]" + palette
        return base + progress + input(media, seek: range.start) + ["-t", number(range.duration), "-an",
            "-filter_complex", filter, "-loop", options.loop ? "0" : "-1", output.path]
    }
    public static func compatibleMP4(input file: URL, output: URL, reencodeVideo: Bool,
                                     reencodeAudio: Bool, hardware: Bool, sourceBitrate: Double?,
                                     hdrTransfer: String? = nil) -> [String] {
        var args = base + progress + input(MediaInput(url: file.path)) + ["-map", "0:v:0", "-map", "0:a:0?"]
        if reencodeVideo, let hdrTransfer { args += ["-vf", sdrToneMap(transfer: hdrTransfer)] + sdrTags }
        if reencodeVideo {
            if hardware {
                let bitrate = sourceBitrate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 8_000_000
                args += ["-c:v", "h264_videotoolbox", "-b:v", String(Int(min(100_000_000, max(1_000_000, bitrate * 1.5))))]
            } else { args += ["-c:v", "libx264", "-crf", "18", "-preset", "medium"] }
            args += ["-pix_fmt", "yuv420p"]
        } else { args += ["-c:v", "copy"] }
        args += reencodeAudio ? ["-c:a", "aac", "-b:a", "192k"] : ["-c:a", "copy"]
        return args + ["-fps_mode", "passthrough", "-tag:v", "avc1", "-movflags", "+faststart", output.path]
    }
    /// Changes the file type without re-encoding (every stream copied as-is).
    public static func remux(input file: URL, output: URL) -> [String] {
        base + progress + input(MediaInput(url: file.path)) + ["-map", "0:v:0", "-map", "0:a:0?", "-c", "copy",
            "-fps_mode", "passthrough"] + faststart(output) + [output.path]
    }

    /// Smaller file: hardware HEVC (or H.264 when `h264`) at a constant quality, height capped, lighter audio.
    public static func compress(input file: URL, output: URL, level: Compression, h264: Bool,
                                hdrTransfer: String? = nil) -> [String] {
        let maxHeight = level.maxHeight ?? 2160
        let quality = level == .smallest ? 40 : 50
        var filters: [String] = []
        if let hdrTransfer { filters.append(sdrToneMap(transfer: hdrTransfer)) }
        filters.append("scale=w=-2:h='min(\(maxHeight),ih)':force_divisible_by=2")
        var args = base + progress + input(MediaInput(url: file.path)) + ["-map", "0:v:0", "-map", "0:a:0?",
            "-vf", filters.joined(separator: ",")]
        if hdrTransfer != nil { args += sdrTags }
        args += h264 ? ["-c:v", "h264_videotoolbox", "-q:v", String(quality + 5), "-tag:v", "avc1"]
                     : ["-c:v", "hevc_videotoolbox", "-q:v", String(quality), "-tag:v", "hvc1"]
        args += ["-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", level == .smallest ? "96k" : "128k",
                 "-fps_mode", "passthrough"]
        return args + faststart(output) + [output.path]
    }

    public static func audio(input file: URL, output: URL, mp3: Bool) -> [String] {
        base + progress + input(MediaInput(url: file.path)) + ["-vn", "-map", "0:a:0"] +
        (mp3 ? ["-c:a", "libmp3lame", "-q:a", "0"] : ["-c:a", "copy"]) + [output.path]
    }
    public static func proxy(input file: URL, output: URL, maxHeight: Int) -> [String] {
        base + progress + ["-copyts"] + input(MediaInput(url: file.path)) +
        ["-map", "0:v:0", "-map", "0:a:0?", "-vf", "scale=w=-2:h='min(\(max(2, maxHeight)),ih)':force_divisible_by=2",
         "-c:v", "h264_videotoolbox", "-b:v", "5000000", "-pix_fmt", "yuv420p", "-fps_mode", "passthrough",
         "-c:a", "aac", "-b:a", "192k", "-avoid_negative_ts", "disabled", "-movflags", "+faststart", output.path]
    }
}

public struct ProbeStream: Sendable, Codable, Hashable {
    public var index: Int
    public var codecType: String
    public var codecName: String
    public var width: Int?
    public var height: Int?
    public var avgFrameRate: Double?
    public var rFrameRate: Double?
    public var pixFmt: String?
    public var colorTransfer: String?
    public var rotation: Int?
    public var bitRate: Double?
    public var startTime: Double?
    // Kept in Codable so a persisted probe still excludes cover art.
    var attachedPicture: Bool = false
}

public struct ProbeResult: Sendable, Codable, Hashable {
    public var duration: Double?
    public var formatName: String
    public var bitRate: Double?
    public var streams: [ProbeStream]
    public var video: ProbeStream? { streams.first { $0.codecType == "video" && !$0.attachedPicture } }
    /// The file's start time (earliest stream start). App timelines and input `-ss` both count from here.
    public var startTime: Double { streams.compactMap(\.startTime).min() ?? 0 }
    public var audio: ProbeStream? { streams.first { $0.codecType == "audio" } }
    public var isHDR: Bool { ["smpte2084", "arib-std-b67"].contains(video?.colorTransfer ?? "") }
    public var hdrTransfer: String? { isHDR ? video?.colorTransfer : nil }
}

public enum FFprobe {
    public static func probeArguments(file: URL) -> [String] {
        ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", file.path]
    }
    public static func frameIndexArguments(file: URL) -> [String] {
        ["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time", "-of", "csv=p=0", file.path]
    }
    public static func parseFrameIndex(_ data: Data) -> [Double] {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap {
            $0.split(separator: ",", omittingEmptySubsequences: false).first.flatMap { finite(String($0)) }
        }.sorted()
    }
    private static func finite(_ value: Any?) -> Double? {
        let number: Double?
        if let text = value as? String { number = Double(text) }
        else { number = (value as? NSNumber)?.doubleValue }
        return number.flatMap { $0.isFinite ? $0 : nil }
    }
    private static func rate(_ value: Any?) -> Double? {
        guard let text = value as? String else { return finite(value) }
        let parts = text.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 {
            let result = n / d
            return result.isFinite && result > 0 ? result : nil
        }
        return finite(text).flatMap { $0 > 0 ? $0 : nil }
    }
    public static func parseProbe(_ data: Data) throws -> ProbeResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let format = root["format"] as? [String: Any] ?? [:]
        let streams = (root["streams"] as? [[String: Any]] ?? []).map { raw in
            let side = raw["side_data_list"] as? [[String: Any]] ?? []
            let rotation = side.compactMap { finite($0["rotation"]) }.first ??
                finite((raw["tags"] as? [String: Any])?["rotate"])
            return ProbeStream(index: (raw["index"] as? Int) ?? 0, codecType: raw["codec_type"] as? String ?? "",
                codecName: raw["codec_name"] as? String ?? "", width: raw["width"] as? Int, height: raw["height"] as? Int,
                avgFrameRate: rate(raw["avg_frame_rate"]), rFrameRate: rate(raw["r_frame_rate"]),
                pixFmt: raw["pix_fmt"] as? String, colorTransfer: raw["color_transfer"] as? String,
                rotation: rotation.flatMap { abs($0) < Double(Int.max) ? Int($0.rounded()) : nil },
                bitRate: finite(raw["bit_rate"]), startTime: finite(raw["start_time"]),
                attachedPicture: (raw["disposition"] as? [String: Any])?["attached_pic"] as? Int == 1)
        }
        return ProbeResult(duration: finite(format["duration"]), formatName: format["format_name"] as? String ?? "",
                           bitRate: finite(format["bit_rate"]), streams: streams)
    }
}

public enum FFmpegProgressParser {
    public static func outTimeSeconds(_ line: String) -> Double? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let result: Double?
        switch parts[0] {
        // Despite its name FFmpeg's out_time_ms is also in microseconds.
        case "out_time_us", "out_time_ms": result = Double(parts[1]).map { $0 / 1_000_000 }
        case "out_time":
            let components = parts[1].split(separator: ":").compactMap { Double($0) }
            result = components.count == 3 ? components[0] * 3600 + components[1] * 60 + components[2] : nil
        default: result = nil
        }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }
    public static func isEnd(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == "progress=end"
    }
}
