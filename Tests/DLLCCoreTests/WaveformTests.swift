import Foundation
import Testing
@testable import DLLCCore

struct WaveformTests {
    @Test func sliceMaxPools() {
        let p = WaveformPeaks(peaksPerSecond: 4, values: [0, 0.1, 0.9, 0.2, 0.3, 0.3, 0, 0])
        #expect(p.slice(from: 0, to: 2, buckets: 2) == [0.9, 0.3])
        #expect(p.slice(from: 0, to: 2, buckets: 0).isEmpty)
    }

    @Test func contrastSpreadsALoudSong() {
        // A loud master: verse at 0.5, chorus at 0.7 — nearly the same height before, clearly apart after.
        let loud = WaveformPeaks(peaksPerSecond: 10, values: Array(repeating: 0.5, count: 50) + Array(repeating: 0.7, count: 50) + [0, 0])
        let c = loud.contrasted()
        #expect(c.values.count == loud.values.count)
        #expect(c.values[0] < 0.1)
        #expect(c.values[60] > 0.95)
        #expect(c.values.last == 0)              // silence stays flat
        let flat = WaveformPeaks(peaksPerSecond: 10, values: Array(repeating: 0.6, count: 40))
        #expect(flat.contrasted() == flat)       // nothing to spread, left alone
    }

    @Test(.enabled(if: CueAudioTests.hasTools)) func peaksFollowLoudnessAndCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dllc-wave-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("half.m4a")
        let p = Process()
        p.executableURL = CueAudioTests.tools.appendingPathComponent("ffmpeg")
        p.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo:d=1",
                       "-f", "lavfi", "-i", "sine=frequency=440:duration=1:sample_rate=48000",
                       "-filter_complex", "[1:a]volume=6,aformat=channel_layouts=stereo[s];[0:a][s]concat=n=2:v=0:a=1",
                       "-c:a", "aac", url.path]
        try p.run(); p.waitUntilExit()
        let peaks = try await WaveformBuilder.cached(url: url, cacheDir: dir.appendingPathComponent("w"))
        #expect(abs(peaks.duration - 2) < 0.1)
        let halves = peaks.slice(from: 0, to: 2, buckets: 2)
        #expect(halves[0] < 0.05)
        #expect(halves[1] > 0.3)
        let again = try await WaveformBuilder.cached(url: url, cacheDir: dir.appendingPathComponent("w"))
        #expect(again == peaks)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("w").path).count == 1)
    }
}
