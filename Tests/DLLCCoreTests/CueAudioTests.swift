import Foundation
import Testing
@testable import DLLCCore

struct CueAudioTests {
    static let tools = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Vendor/tools")
    static var hasTools: Bool { FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("ffmpeg").path) }

    @Test func atempoChainStaysInRange() {
        for speed in CueSpeed.allCases {
            let factors = CueCommand.atempoChain(speed.rawValue).map { Double($0.dropFirst("atempo=".count))! }
            #expect(factors.allSatisfy { $0 >= 0.5 && $0 <= 2 })
            #expect(abs(factors.reduce(1, *) - speed.rawValue) < 0.001)
        }
        #expect(CueCommand.atempoChain(1).isEmpty)
    }

    @Test func countInLengthAndAccent() {
        let data = CountInSynth.wav(CountIn(count: 4, interval: 0.5, sound: .beep), sampleRate: 48_000)
        #expect(data.count == 44 + 4 * 24_000 * 2 * 2)
        func peak(_ slot: Int) -> Int16 {
            data.withUnsafeBytes { raw in
                let s = raw.bindMemory(to: Int16.self)
                let start = 22 + slot * 24_000 * 2
                return (start..<(start + 4800)).map { abs(s[$0]) }.max() ?? 0
            }
        }
        #expect(peak(0) > peak(1))
        #expect(peak(1) > 0)
    }

    @Test func lyricTimingEvenSplitAndTapped() {
        var s = SongSection(name: "Hook", start: 10, end: 20, note: "a\nb\nc\nd")
        #expect(LyricTimeline.lineStarts(s) == [10, 12.5, 15, 17.5])
        s.lyricTimes = [nil, nil, 18, nil]
        #expect(LyricTimeline.lineStarts(s) == [10, 14, 18, 19])
    }

    @Test func lyricTimesFollowSpeedAndCountIn() {
        var o = CueOptions(); o.speed = .x2; o.countIn = CountIn(count: 3, interval: 1); o.padBefore = 2
        let s = SongSection(name: "Hook", start: 10, end: 20, note: "a\nb")
        let cues = LyricTimeline.cues(sections: [s], range: s.range, options: o, duration: 100)
        // padded start 8; 10 → 3 + (2/2) = 4; 15 → 3 + 7/2 = 6.5; end 20 → 3 + 6 = 9
        #expect(cues.lines.map(\.start) == [4, 6.5])
        #expect(cues.lines.last?.end == 9)
        #expect(cues.countdown.map(\.text) == ["3", "2", "1"])
        #expect(cues.titles.first?.text == "Hook")
    }

    @Test func lyricTextGoesThroughFiles() {
        let line = LyricCue(text: "ฮุค 'one': 하나", start: 0, end: 1)
        let file = URL(fileURLWithPath: "/tmp/t1.txt")
        let args = CueCommand.lyricVideo(song: URL(fileURLWithPath: "/tmp/s.mp3"), padded: TimeRange(start: 0, end: 1),
                                         options: CueOptions(), countIn: nil, total: 1, lines: [(line, file)],
                                         titles: [], countdown: [], output: URL(fileURLWithPath: "/tmp/o.mp4"))
        #expect(!args.joined().contains("하나"))
        #expect(args.joined().contains("textfile='/tmp/t1.txt'"))
    }

    // MARK: Real ffmpeg

    private func makeSong(_ dir: URL, seconds: Int = 20) throws -> URL {
        let url = dir.appendingPathComponent("song.wav")
        let p = Process()
        p.executableURL = Self.tools.appendingPathComponent("ffmpeg")
        p.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
                       "-ac", "2", "-ar", "48000", url.path]
        try p.run(); p.waitUntilExit()
        return url
    }

    private func duration(_ url: URL) throws -> Double {
        let p = Process(), out = Pipe()
        p.executableURL = Self.tools.appendingPathComponent("ffprobe")
        p.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path]
        p.standardOutput = out
        try p.run(); p.waitUntilExit()
        return Double(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dllc-cue-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test(.enabled(if: CueAudioTests.hasTools)) func exportDurationsMatch() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let songURL = try makeSong(dir)
        let song = Song(title: "Test", path: songURL.path, duration: 20)
        let exporter = CueExporter(ffmpeg: Self.tools.appendingPathComponent("ffmpeg"))
        let section = SongSection(name: "Hook 1", start: 5, end: 9)
        var o = CueOptions(); o.countIn = CountIn(count: 3, interval: 1)
        let a = try await exporter.export(songFile: songURL, song: song, sections: [section], range: section.range, options: o, to: dir)
        #expect(a.lastPathComponent == "Test - Hook 1.mp3")
        #expect(abs(try duration(a) - 7) < 0.06)
        o.speed = .x2
        let b = try await exporter.export(songFile: songURL, song: song, sections: [section], range: section.range, options: o, to: dir)
        #expect(b.lastPathComponent == "Test - Hook 1 (fast x2).mp3")
        #expect(abs(try duration(b) - 5) < 0.06)
        o.speed = .x1; o.countIn = nil; o.format = .wav; o.fadeOut = true
        let c = try await exporter.export(songFile: songURL, song: song, sections: [section], range: section.range, options: o, to: dir)
        #expect(abs(try duration(c) - 4) < 0.01) // fade adds no length
        o.format = .mp3; o.fadeOut = false
        _ = try await exporter.export(songFile: songURL, song: song, sections: [section], range: section.range, options: o, to: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Test - Hook 1 (2).mp3").path)) // never overwrites
    }

    @Test(.enabled(if: CueAudioTests.hasTools)) func joinedPiecesExport() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let songURL = try makeSong(dir)
        let song = Song(title: "Test", path: songURL.path, duration: 20)
        let a = SongSection(name: "Hook 1", start: 2, end: 5), b = SongSection(name: "Hook 2", start: 10, end: 14)
        var o = CueOptions(); o.padBefore = 1; o.countIn = CountIn(count: 2, interval: 0.5)
        let out = try await CueExporter(ffmpeg: Self.tools.appendingPathComponent("ffmpeg"))
            .export(songFile: songURL, song: song, sections: [a, b], pieces: [b.range, a.range], options: o, to: dir)
        #expect(out.lastPathComponent == "Test - Hook 1+Hook 2.mp3")
        #expect(abs(try duration(out) - 9) < 0.08) // 1 lead-in + 3 + 4 + 1 count-in
    }

    @Test(.enabled(if: CueAudioTests.hasTools)) func lyricVideoRenders() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let songURL = try makeSong(dir, seconds: 8)
        let song = Song(title: "Test", path: songURL.path, duration: 8)
        let section = SongSection(name: "ฮุค 1", start: 1, end: 4, note: "ฮุค 'one': 하나\nline two")
        var o = CueOptions(); o.format = .lyricVideo; o.countIn = CountIn(count: 2, interval: 0.5)
        let out = try await CueExporter(ffmpeg: Self.tools.appendingPathComponent("ffmpeg"))
            .export(songFile: songURL, song: song, sections: [section], range: section.range, options: o, to: dir)
        #expect(out.pathExtension == "mp4")
        #expect(abs(try duration(out) - 4) < 0.15)
    }
}
