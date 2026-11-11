import Foundation

// MARK: - Count-in

/// Generates the count-in ticks as a WAV file in code (no bundled sounds). The first tick is accented.
public enum CountInSynth {
    public static func wav(_ c: CountIn, sampleRate: Int = 48_000) -> Data {
        let slot = Int((c.interval * Double(sampleRate)).rounded())
        let total = slot * max(0, c.count)
        var samples = [Int16](repeating: 0, count: total * 2)
        var noise: UInt32 = 0x1234_5678
        for k in 0..<max(0, c.count) {
            let accent = k == 0
            let tickLength = min(slot, Int(0.06 * Double(sampleRate)))
            for i in 0..<tickLength {
                let t = Double(i) / Double(sampleRate)
                let v: Double
                switch c.sound {
                case .beep:
                    let f = accent ? 1760.0 : 880.0
                    v = sin(2 * .pi * f * t) * exp(-t * 40)
                case .click:
                    noise = noise &* 1_664_525 &+ 1_013_904_223
                    let n = Double(Int32(bitPattern: noise)) / Double(Int32.max)
                    v = n * exp(-t * (accent ? 120 : 180))
                case .woodblock:
                    let f = accent ? 1200.0 : 900.0
                    v = sin(2 * .pi * f * t) * exp(-t * 90)
                }
                let s = Int16(max(-1, min(1, v * (accent ? 0.9 : 0.6))) * Double(Int16.max))
                let index = (k * slot + i) * 2
                samples[index] = s; samples[index + 1] = s
            }
        }
        return wavData(samples, channels: 2, sampleRate: sampleRate)
    }

    static func wavData(_ samples: [Int16], channels: Int, sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVE".utf8)); d.append(contentsOf: Array("fmt ".utf8))
        u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBufferPointer { buf in
            for s in buf { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        }
        return d
    }
}

// MARK: - Lyric timeline

/// One piece of on-screen text, in output-file seconds.
public struct LyricCue: Sendable, Hashable {
    public let text: String
    public let start: Double
    public let end: Double
}

public enum LyricTimeline {
    /// Maps song time to output time: padding start → 0, sped up, after the count-in.
    static func outputTime(_ t: Double, padded: TimeRange, options: CueOptions) -> Double {
        let lead = options.countIn?.length ?? 0
        let clamped = min(max(t, padded.start), padded.end)
        return lead + (clamped - padded.start) / options.speed.rawValue
    }

    /// Start time (song time) of each lyric line: tapped times where set, the rest spread evenly
    /// between their timed neighbours (or the section's edges).
    static func lineStarts(_ section: SongSection) -> [Double] {
        let n = section.lyricLines.count
        var known: [Double?] = (0..<n).map { i in
            i < section.lyricTimes.count ? section.lyricTimes[i].map { min(max($0, section.start), section.end) } : nil
        }
        if n > 0, known[0] == nil { known[0] = section.start }
        var i = 0
        while i < n {
            guard known[i] == nil else { i += 1; continue }
            let prev = i - 1
            var next = i
            while next < n, known[next] == nil { next += 1 }
            let a = known[prev]!, b = next < n ? known[next]! : section.end
            let steps = Double(next - prev)
            for j in i..<next { known[j] = a + (b - a) * Double(j - prev) / steps }
            i = next
        }
        return known.map { $0! }
    }

    public static func cues(sections: [SongSection], range: TimeRange, options: CueOptions, duration: Double)
        -> (lines: [LyricCue], titles: [LyricCue], countdown: [LyricCue]) {
        let padded = CueMath.padded(range, options: options, duration: duration)
        let map = { (t: Double) in outputTime(t, padded: padded, options: options) }
        var lines: [LyricCue] = [], titles: [LyricCue] = []
        for section in sections.sorted(by: { $0.start < $1.start }) where section.end > padded.start && section.start < padded.end {
            titles.append(LyricCue(text: section.name, start: map(section.start), end: map(section.end)))
            let starts = lineStarts(section)
            for (i, text) in section.lyricLines.enumerated() {
                let s = map(starts[i]), e = map(i + 1 < starts.count ? starts[i + 1] : section.end)
                if e > s { lines.append(LyricCue(text: text, start: s, end: e)) }
            }
        }
        var countdown: [LyricCue] = []
        if let c = options.countIn {
            for k in 0..<c.count {
                countdown.append(LyricCue(text: String(c.count - k), start: Double(k) * c.interval, end: Double(k + 1) * c.interval))
            }
        }
        return (lines, titles, countdown)
    }
}

// MARK: - ffmpeg arguments

public enum CueCommand {
    static let base = ["-hide_banner", "-nostdin", "-n"]
    public static let lyricFont = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"

    /// atempo accepts 0.5…2 per stage; larger changes are chained.
    public static func atempoChain(_ speed: Double) -> [String] {
        guard abs(speed - 1) > 1e-6, speed > 0 else { return [] }
        var factors: [Double] = []
        var rest = speed
        while rest > 2 { factors.append(2); rest /= 2 }
        while rest < 0.5 { factors.append(0.5); rest /= 0.5 }
        if abs(rest - 1) > 1e-6 { factors.append(rest) }
        return factors.map { "atempo=\(String(format: "%.6f", $0))" }
    }

    /// The audio part of the graph: the song's pieces trimmed and joined in order → tempo → optional fade,
    /// then the count-in in front. Leaves its result on the label `[aout]`.
    static func audioGraph(padded: TimeRange, options: CueOptions, hasCountIn: Bool) -> String {
        audioGraph(pieces: [padded], options: options, hasCountIn: hasCountIn)
    }

    static func audioGraph(pieces: [TimeRange], options: CueOptions, hasCountIn: Bool) -> String {
        let fmt = ["aresample=48000", "aformat=sample_fmts=fltp:channel_layouts=stereo"]
        func trim(_ r: TimeRange) -> String {
            String(format: "atrim=start=%.6f:end=%.6f", r.start, r.end) + ",asetpts=PTS-STARTPTS"
        }
        var graph: String
        var chain: [String] = []
        if pieces.count == 1 {
            graph = "[0:a]" + ([trim(pieces[0])] + fmt).joined(separator: ",")
        } else {
            let n = pieces.count
            graph = "[0:a]asplit=\(n)" + (0..<n).map { "[s\($0)]" }.joined() + ";"
            graph += pieces.enumerated().map { i, r in "[s\(i)]" + trim(r) + "[p\(i)]" }.joined(separator: ";") + ";"
            graph += (0..<n).map { "[p\($0)]" }.joined() + "concat=n=\(n):v=0:a=1"
            chain += fmt
        }
        chain += atempoChain(options.speed.rawValue)
        let musicLength = pieces.reduce(0) { $0 + $1.duration } / options.speed.rawValue
        if options.fadeOut, musicLength > 0.2 {
            let d = min(CueOptions.fadeLength, musicLength / 2)
            chain.append(String(format: "afade=t=out:st=%.6f:d=%.6f", musicLength - d, d))
        }
        if !chain.isEmpty { graph += "," + chain.joined(separator: ",") }
        if hasCountIn {
            return graph + "[m];[1:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[c];[c][m]concat=n=2:v=0:a=1[aout]"
        }
        return graph + "[aout]"
    }

    static func audioCodec(_ format: CueFormat) -> [String] {
        switch format {
        case .mp3: ["-c:a", "libmp3lame", "-b:a", "256k"]
        case .wav: ["-c:a", "pcm_s16le"]
        case .lyricVideo: ["-c:a", "aac", "-b:a", "192k"]
        }
    }

    public static func audio(song: URL, padded: TimeRange, options: CueOptions, countIn: URL?, output: URL) -> [String] {
        audio(song: song, pieces: [padded], options: options, countIn: countIn, output: output)
    }

    public static func audio(song: URL, pieces: [TimeRange], options: CueOptions, countIn: URL?, output: URL) -> [String] {
        var args = base + ["-protocol_whitelist", "file", "-i", song.path]
        if let countIn { args += ["-protocol_whitelist", "file", "-i", countIn.path] }
        args += ["-filter_complex", audioGraph(pieces: pieces, options: options, hasCountIn: countIn != nil),
                 "-map", "[aout]", "-map_metadata", "-1", "-ar", "48000", "-ac", "2"]
        args += audioCodec(options.format == .lyricVideo ? .mp3 : options.format)
        return args + [output.path]
    }

    /// A 1280×720 dark video with the cues drawn from text files (never inlined: any lyric is safe).
    /// `texts` pairs each cue with the text file holding its words.
    public static func lyricVideo(song: URL, padded: TimeRange, options: CueOptions, countIn: URL?, total: Double,
                                  lines: [(LyricCue, URL)], titles: [(LyricCue, URL)], countdown: [(LyricCue, URL)],
                                  output: URL) -> [String] {
        var args = base + ["-protocol_whitelist", "file", "-i", song.path]
        if let countIn { args += ["-protocol_whitelist", "file", "-i", countIn.path] }
        let videoIndex = countIn == nil ? 1 : 2
        args += ["-f", "lavfi", "-i", String(format: "color=c=0x111111:s=1280x720:r=30:d=%.3f", total)]
        func draw(_ cue: LyricCue, _ file: URL, size: Int, color: String, x: String, y: String) -> String {
            "drawtext=fontfile='\(lyricFont)':textfile='\(file.path)':fontsize=\(size):fontcolor=\(color)"
                + ":x=\(x):y=\(y)" + String(format: ":enable='between(t,%.3f,%.3f)'", cue.start, cue.end)
        }
        var draws: [String] = []
        draws += titles.map { draw($0.0, $0.1, size: 28, color: "0x9A9A9A", x: "48", y: "40") }
        draws += lines.map { draw($0.0, $0.1, size: 56, color: "white", x: "(w-text_w)/2", y: "(h-text_h)/2") }
        draws += countdown.map { draw($0.0, $0.1, size: 180, color: "0xE8402A", x: "(w-text_w)/2", y: "(h-text_h)/2") }
        let timecode = "drawtext=fontfile='\(lyricFont)':text='%{pts\\:hms}':fontsize=24:fontcolor=0x9A9A9A:x=w-tw-48:y=44"
        let video = "[\(videoIndex):v]" + (draws + [timecode]).joined(separator: ",") + "[vout]"
        args += ["-filter_complex", audioGraph(padded: padded, options: options, hasCountIn: countIn != nil) + ";" + video,
                 "-map", "[vout]", "-map", "[aout]", "-map_metadata", "-1",
                 "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p", "-r", "30"]
        args += audioCodec(.lyricVideo) + ["-ar", "48000", "-ac", "2", "-movflags", "+faststart", "-shortest", output.path]
        return args
    }
}

// MARK: - Export

public enum CueExportError: Error, LocalizedError {
    case emptyRange, failed(String)
    public var errorDescription: String? {
        switch self {
        case .emptyRange: "Choose a section or a range first."
        case .failed(let tail): "Export failed. \(tail.split(separator: "\n").last.map(String.init) ?? "")"
        }
    }
}

/// Renders one cue file with the bundled ffmpeg. The song is only read; the output never replaces a file.
public final class CueExporter: Sendable {
    let ffmpeg: URL
    let supervisor: ProcessSupervisor

    public init(ffmpeg: URL, supervisor: ProcessSupervisor = .shared) {
        self.ffmpeg = ffmpeg; self.supervisor = supervisor
    }

    /// Several stretches of the song joined into one audio file, in time order.
    public func export(songFile: URL, song: Song, sections: [SongSection], pieces: [TimeRange],
                       options: CueOptions, to folder: URL) async throws -> URL {
        let sorted = pieces.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        guard sorted.count > 1, options.format != .lyricVideo else {
            guard let r = sorted.first else { throw CueExportError.emptyRange }
            return try await export(songFile: songFile, song: song, sections: sections,
                                    range: TimeRange(start: r.start, end: sorted.last!.end), options: options, to: folder)
        }
        let padded = CueMath.padded(pieces: sorted, options: options, duration: song.duration)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("dllc-cue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var countInURL: URL?
        if let c = options.countIn, c.count > 0 {
            let url = work.appendingPathComponent("countin.wav")
            try CountInSynth.wav(c).write(to: url)
            countInURL = url
        }
        let range = TimeRange(start: sorted[0].start, end: sorted.last!.end)
        let base = CueNaming.baseName(sections: sections, range: range, songTitle: song.title,
                                      prefix: song.prefix, speed: options.speed)
        let partial = work.appendingPathComponent("render.\(options.format.fileExtension)")
        let args = CueCommand.audio(song: songFile, pieces: padded, options: options, countIn: countInURL, output: partial)
        let result = try await supervisor.run(ProcessSpec(executable: ffmpeg, arguments: args))
        if result.wasCancelled { throw CancellationError() }
        guard result.succeeded else { throw CueExportError.failed(result.stderrTail) }
        return try Self.place(partial, in: folder, base: base, ext: options.format.fileExtension)
    }

    static func place(_ partial: URL, in folder: URL, base: String, ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var attempt = 0
        while true {
            let dest = CueNaming.uniqueURL(in: folder, base: base, ext: ext)
            do { try FileManager.default.moveItem(at: partial, to: dest); return dest }
            catch { attempt += 1; if attempt > 5 { throw error } }
        }
    }

    public func export(songFile: URL, song: Song, sections: [SongSection], range: TimeRange,
                       options: CueOptions, to folder: URL) async throws -> URL {
        let padded = CueMath.padded(range, options: options, duration: song.duration)
        guard padded.duration > 0.05 else { throw CueExportError.emptyRange }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("dllc-cue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var countInURL: URL?
        if let c = options.countIn, c.count > 0 {
            let url = work.appendingPathComponent("countin.wav")
            try CountInSynth.wav(c).write(to: url)
            countInURL = url
        }
        let base = CueNaming.baseName(sections: sections, range: range, songTitle: song.title,
                                      prefix: song.prefix, speed: options.speed)
        let ext = options.format.fileExtension
        let partial = work.appendingPathComponent("render.\(ext)")
        let args: [String]
        if options.format == .lyricVideo {
            let cues = LyricTimeline.cues(sections: sections, range: range, options: options, duration: song.duration)
            var n = 0
            func files(_ list: [LyricCue]) throws -> [(LyricCue, URL)] {
                try list.map { cue in
                    n += 1
                    let url = work.appendingPathComponent("t\(n).txt")
                    try cue.text.write(to: url, atomically: true, encoding: .utf8)
                    return (cue, url)
                }
            }
            args = CueCommand.lyricVideo(song: songFile, padded: padded, options: options, countIn: countInURL,
                                         total: CueMath.outputDuration(range: padded, options: options),
                                         lines: try files(cues.lines), titles: try files(cues.titles),
                                         countdown: try files(cues.countdown), output: partial)
        } else {
            args = CueCommand.audio(song: songFile, padded: padded, options: options, countIn: countInURL, output: partial)
        }
        let result = try await supervisor.run(ProcessSpec(executable: ffmpeg, arguments: args))
        if result.wasCancelled { throw CancellationError() }
        guard result.succeeded else { throw CueExportError.failed(result.stderrTail) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Pick the name at the last moment and never replace: moveItem fails rather than overwrite.
        var attempt = 0
        while true {
            let dest = CueNaming.uniqueURL(in: folder, base: base, ext: ext)
            do { try FileManager.default.moveItem(at: partial, to: dest); return dest }
            catch { attempt += 1; if attempt > 5 { throw error } }
        }
    }
}
