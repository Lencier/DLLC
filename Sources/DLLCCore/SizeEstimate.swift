import Foundation

/// A rough guess of the file a job will save, from what the site reported during analysis.
public struct SizeEstimate: Equatable, Sendable {
    public var bytes: Int64
    /// True when any part is a guess (site gave no exact size, re-encode, resize, cut).
    public var rough: Bool
    public init(bytes: Int64, rough: Bool) { self.bytes = bytes; self.rough = rough }

    /// "≈ 245 MB", or "245 MB" when the site gave the exact size.
    public var label: String { (rough ? "≈ " : "") + ByteFormat.string(bytes) }
}

/// How big each kind of output comes out, measured on real encodes with DLLC's own FFmpeg settings
/// (bits per pixel per frame for video, bytes per pixel per frame for GIF), rounded up a little for busy footage.
public enum SizeModel {
    /// Hardware HEVC / H.264 at the "Smaller" and "Smallest" quality levels.
    static func compressedBPPF(_ c: Compression, h264: Bool) -> Double {
        switch c {
        case .off: 0
        case .smaller: h264 ? 0.09 : 0.05
        case .smallest: h264 ? 0.075 : 0.045
        }
    }
    /// libx264 CRF 17 (precise clips).
    static let preciseBPPF = 0.13
    /// GIF bytes per pixel per frame for each palette setting.
    static func gifBPPF(_ c: Compression) -> Double {
        switch c { case .off: 0.45; case .smaller: 0.37; case .smallest: 0.33 }
    }

    /// Frames above 30 fps cost less each (neighbouring frames are more alike), so 60 fps ≈ 1.4× of 30 fps.
    static func effectiveFPS(_ fps: Double?) -> Double {
        let f = fps.flatMap { $0 > 0 && $0 < 1000 ? $0 : nil } ?? 30
        return f <= 30 ? f : 30 + (f - 30) * 0.4
    }

    /// The quality the job will download.
    static func option(_ info: MediaInfo, _ o: OutputOptions) -> QualityOption? {
        if case .option(let id, _, _, _) = o.quality { return info.qualityOptions.first { $0.id == id } ?? info.bestQuality }
        return info.bestQuality
    }

    /// Output frame size after an optional height cap (never upscaled).
    static func frame(_ q: QualityOption?, cap: Int?) -> (w: Double, h: Double)? {
        guard let h = q?.height, h > 0 else { return nil }
        let w = Double(q?.width ?? Int((Double(h) * 16 / 9).rounded()))
        let outH = Double(min(h, cap ?? h))
        return (w * outH / Double(h), outH)
    }

    static func isH264(_ q: QualityOption) -> Bool {
        !q.codecs.isEmpty && q.codecs.allSatisfy { $0.lowercased().hasPrefix("avc") || $0.lowercased().hasPrefix("h264") || $0 == "H.264" }
    }

    /// Video or clip (`range`), following every choice that changes the size: quality, codecs, cut mode, Size.
    public static func video(info: MediaInfo, options o: OutputOptions, range: TimeRange? = nil) -> SizeEstimate? {
        guard let q = option(info, o) else { return nil }
        let whole = info.duration.flatMap { $0 > 0 ? $0 : nil }
        guard let seconds = range?.duration ?? whole, seconds > 0 else { return nil }
        let fps = effectiveFPS(q.fps)
        var rough = q.estimateIsRough || range != nil

        // What comes out before the Size step.
        var bytes: Double?
        if range != nil && o.cutMode == .precise, let f = frame(q, cap: nil) {
            bytes = preciseBPPF * f.w * f.h * fps * seconds / 8 + 192_000 * seconds / 8
            rough = true
        } else if let source = q.estimatedBytes, source > 0 {
            bytes = Double(source) * (whole.map { min(1, seconds / $0) } ?? 1)
            if o.container == .compatibleMP4 && !isH264(q) { bytes! *= 1.5; rough = true }   // re-encoded to H.264
        }

        // Size: re-encoded at a set quality; DLLC keeps the original when that wouldn't be smaller.
        if o.compression != .off, let f = frame(q, cap: o.compression.maxHeight) {
            let audio = (o.compression == .smallest ? 96_000.0 : 128_000) * seconds / 8
            let compressed = compressedBPPF(o.compression, h264: o.container == .compatibleMP4) * f.w * f.h * fps * seconds / 8 + audio
            bytes = min(bytes ?? compressed, compressed)
            rough = true
        }
        guard let bytes, bytes > 0 else { return nil }
        return SizeEstimate(bytes: Int64(bytes), rough: rough)
    }

    /// Audio: MP3 at LAME V0 (≈ 245 kbps) or the original stream.
    public static func audio(info: MediaInfo, mp3: Bool, range: TimeRange? = nil) -> SizeEstimate? {
        let whole = info.duration.flatMap { $0 > 0 ? $0 : nil }
        if mp3 {
            guard let d = range?.duration ?? whole else { return nil }
            return SizeEstimate(bytes: Int64(d * 245_000 / 8), rough: true)
        }
        guard let a = info.bestAudio else { return nil }
        if range == nil, let size = a.filesize, size > 0 { return SizeEstimate(bytes: size, rough: a.filesizeIsEstimate) }
        guard let abr = a.abr, abr > 0, let d = range?.duration ?? whole, d > 0 else { return nil }
        return SizeEstimate(bytes: Int64(abr * 1000 * d / 8), rough: true)
    }

    /// GIF of `range`, with the same width/fps limits the encoder applies.
    public static func gif(info: MediaInfo, range: TimeRange, options g: GIFOptions, compression: Compression) -> SizeEstimate? {
        guard range.duration > 0 else { return nil }
        let q = info.bestQuality
        var width = Double(max(2, min(g.width, q?.width ?? g.width, 1920)))
        var fps = min(30, max(1, g.fps.isFinite ? g.fps : 12))
        if compression == .smallest { width = min(width, 480); fps = min(fps, 10) }
        let aspect: Double = {
            guard let w = q?.width, let h = q?.height, w > 0, h > 0 else { return 9.0 / 16 }
            return Double(h) / Double(w)
        }()
        let frames = (range.duration * fps).rounded(.up)
        let bytes = gifBPPF(compression) * width * (width * aspect) * frames
        return SizeEstimate(bytes: Int64(bytes), rough: true)
    }

    /// One full-resolution still frame.
    public static func frame(info: MediaInfo, format: ImageFormat) -> SizeEstimate? {
        guard let f = frame(info.bestQuality, cap: nil) else { return nil }
        let perPixel = format == .png ? 0.5 : 0.12
        return SizeEstimate(bytes: Int64(f.w * f.h * perPixel), rough: true)
    }
}

extension Job {
    /// Estimated output size for the chosen output, or nil when there's nothing to go on
    /// (not analysed yet, multi-item posts, or the site gave no sizes).
    public var sizeEstimate: SizeEstimate? {
        guard let info, !info.isMultiItem else { return nil }
        let o = options
        switch o.kind {
        case .video: return SizeModel.video(info: info, options: o)
        case .audio: return SizeModel.audio(info: info, mp3: o.audioFormat == .mp3)
        case .clip:
            guard let r = o.range, r.duration > 0 else { return nil }
            return SizeModel.video(info: info, options: o, range: r)
        case .gif:
            guard let r = o.range else { return nil }
            return SizeModel.gif(info: info, range: r, options: o.gif, compression: o.compression)
        }
    }
}
