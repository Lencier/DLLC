import Foundation
import Testing
@testable import DLLCCore

/// Real-network end-to-end tests of the bundled tools through MediaWorker.
/// Run with: DLLC_E2E=1 swift test --filter E2E   (needs Vendor/tools from scripts/fetch-tools.sh)
enum E2E {
    static let enabled = ProcessInfo.processInfo.environment["DLLC_E2E"] == "1"
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let toolsDir = root.appendingPathComponent("Vendor/tools")
    static let zoo = "https://www.youtube.com/watch?v=jNQXAC9IVRw"
    static let fourK = "https://www.youtube.com/watch?v=LXb3EKWsInQ"
    static let x = "https://twitter.com/captainamerica/status/719944021058060289"
    static let instagram = "https://www.instagram.com/p/BQ0eAlwhDrw/"
    static let pinterest = "https://www.pinterest.com/pin/664281013778109217/"

    /// Each run leaves its downloads for inspection; the next run removes ones older than an hour.
    static func removeOldRuns() {
        let tmp = FileManager.default.temporaryDirectory
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        for url in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: Array(keys))) ?? []
        where url.lastPathComponent.hasPrefix("dllc-e2e-") {
            let date = (try? url.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(date) > 3600 { try? FileManager.default.removeItem(at: url) }
        }
    }

    static func makeWorker() throws -> (MediaWorker, URL) {
        removeOldRuns()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("dllc-e2e-\(UUID().uuidString.prefix(6))")
        let paths = AppPaths(applicationSupport: base.appendingPathComponent("support"), caches: base.appendingPathComponent("caches"))
        try paths.createDirectories()
        let tools = try ToolLocator.resolve(paths: nil, preferUpdatedYTDLP: false, environment: ["DLLC_TOOLS_DIR": toolsDir.path])
        let out = base.appendingPathComponent("out ไทย", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return (MediaWorker(tools: tools, paths: paths), out)
    }

    static func job(_ url: String, info: MediaInfo, _ change: (inout OutputOptions) -> Void = { _ in }) -> Job {
        var j = Job(url: url)
        j.info = info
        change(&j.options)
        return j
    }
}

@Suite(.enabled(if: E2E.enabled), .serialized)
struct E2ETests {
    @Test func platformsAnalyze() async throws {
        let (w, _) = try E2E.makeWorker()
        let x = try await w.analyze(url: E2E.x, playlistItems: nil, cookies: .none)
        #expect(x.platform == .x && x.hasVideo)
        let ig = try await w.analyze(url: E2E.instagram, playlistItems: nil, cookies: .none)
        #expect(ig.platform == .instagram && ig.entries.count == 3)
        let pin = try await w.analyze(url: E2E.pinterest, playlistItems: nil, cookies: .none)
        #expect(pin.platform == .pinterest && pin.hasVideo)
        let yt = try await w.analyze(url: E2E.fourK, playlistItems: nil, cookies: .none)
        #expect(yt.qualityOptions.contains { $0.height == 2160 && ($0.fps ?? 0) >= 59 })
        // Every option is backed by a real variant with exactly that height and fps.
        for q in yt.qualityOptions {
            #expect(q.formatIDs.allSatisfy { id in yt.videoVariants.contains { $0.formatID == id && $0.height == q.height } })
        }
        await #expect(throws: JobError.self) {
            _ = try await w.analyze(url: "https://www.youtube.com/watch?v=aaaaaaaaaaa", playlistItems: nil, cookies: .none)
        }
    }

    @Test func audioAndCompatibleMP4() async throws {
        let (w, out) = try E2E.makeWorker()
        let info = try await w.analyze(url: E2E.zoo, playlistItems: nil, cookies: .none)
        let mp3 = try await w.execute(job: E2E.job(E2E.zoo, info: info) { $0.kind = .audio; $0.audioFormat = .mp3 }, destination: out) { _ in }
        let p1 = try await w.probe(mp3.files[0])
        #expect(p1.audio?.codecName == "mp3" && p1.video == nil || p1.video?.codecName == "mjpeg")
        let orig = try await w.execute(job: E2E.job(E2E.zoo, info: info) { $0.kind = .audio; $0.audioFormat = .original }, destination: out) { _ in }
        let p2 = try await w.probe(orig.files[0])
        #expect(["opus", "aac"].contains(p2.audio?.codecName ?? ""))
        let mp4 = try await w.execute(job: E2E.job(E2E.zoo, info: info) { $0.container = .compatibleMP4 }, destination: out) { _ in }
        let p3 = try await w.probe(mp4.files[0])
        #expect(mp4.files[0].pathExtension == "mp4")
        #expect(p3.video?.codecName == "h264" && p3.audio?.codecName == "aac")
        #expect(abs((p3.duration ?? 0) - 19.0) < 0.6)
        #expect(mp4.files[0].path.contains("out ไทย"))
    }

    @Test func remoteRangesFrom4K60() async throws {
        let (w, out) = try E2E.makeWorker()
        let info = try await w.analyze(url: E2E.fourK, playlistItems: nil, cookies: .none)
        let sdr4k = try #require(info.qualityOptions.first { $0.height == 2160 && ($0.fps ?? 0) >= 59 && !$0.isHDR })
        let q = QualityChoice.option(id: sdr4k.id, height: sdr4k.height, fps: sdr4k.fps, formatIDs: sdr4k.formatIDs)
        let started = Date()
        let clip = try await w.execute(job: E2E.job(E2E.fourK, info: info) {
            $0.kind = .clip; $0.quality = q; $0.cutMode = .precise; $0.range = TimeRange(start: 10, end: 12)
        }, destination: out) { _ in }
        let p = try await w.probe(clip.files[0])
        print("E2E precise 2 s 4K60 remote clip: \(Date().timeIntervalSince(started)) s")
        #expect(p.video?.width == 3840 && p.video?.height == 2160)
        #expect((p.video?.avgFrameRate ?? 0) > 59)
        #expect(abs((p.duration ?? 0) - 2.0) < 0.1)
        #expect(p.audio != nil)

        let fast = try await w.execute(job: E2E.job(E2E.fourK, info: info) {
            $0.kind = .clip; $0.quality = q; $0.cutMode = .fast; $0.range = TimeRange(start: 20, end: 23)
        }, destination: out) { _ in }
        let pf = try await w.probe(fast.files[0])
        #expect(pf.video?.height == 2160 && pf.audio != nil)

        let gif = try await w.execute(job: E2E.job(E2E.fourK, info: info) {
            $0.kind = .gif; $0.range = TimeRange(start: 30, end: 32); $0.gif = GIFOptions(width: 480, fps: 12)
        }, destination: out) { _ in }
        let pg = try await w.probe(gif.files[0])
        #expect(pg.video?.codecName == "gif" && pg.video?.width == 480)

        let snap = try await w.snapshot(job: E2E.job(E2E.fourK, info: info), time: 15.0, frameDuration: 1 / 60,
                                        format: .png, destination: out)
        let ps = try await w.probe(snap)
        #expect(ps.video?.width == 3840)
        #expect(snap.lastPathComponent.contains("00-15.000"))
    }

    @Test func localSourceAndCancellation() async throws {
        let (w, out) = try E2E.makeWorker()
        let info = try await w.analyze(url: E2E.zoo, playlistItems: nil, cookies: .none)
        let src = try await w.fetchSource(url: E2E.zoo, info: info, quality: .best, cookies: .none, entries: nil) { _ in }
        #expect(w.sources.lookup(url: "https://youtu.be/jNQXAC9IVRw") == src)
        let clip = try await w.execute(job: E2E.job(E2E.zoo, info: info) {
            $0.kind = .clip; $0.range = TimeRange(start: 3, end: 5)
        }, destination: out) { _ in }
        #expect(clip.notes.allSatisfy { !$0.contains("online") })
        let p = try await w.probe(clip.files[0])
        #expect(abs((p.duration ?? 0) - 2.0) < 0.1)

        // Cancel a large download mid-flight: the call must end promptly and leave no child processes.
        let big = try await w.analyze(url: E2E.fourK, playlistItems: nil, cookies: .none)
        let task = Task { try await w.execute(job: E2E.job(E2E.fourK, info: big), destination: out) { _ in } }
        try await Task.sleep(for: .seconds(6))
        let cancelAt = Date()
        task.cancel()
        let result = await task.result
        #expect(Date().timeIntervalSince(cancelAt) < 6)
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(w.supervisor.runningCount == 0)
    }

    @Test func otherPlatformsDownload() async throws {
        let (w, out) = try E2E.makeWorker()
        for url in [E2E.x, E2E.pinterest] {
            let info = try await w.analyze(url: url, playlistItems: nil, cookies: .none)
            let r = try await w.execute(job: E2E.job(url, info: info), destination: out) { _ in }
            let p = try await w.probe(r.files[0])
            #expect(p.video != nil, "\(url)")
        }
        // Instagram carousel: only the selected item is downloaded.
        let child = try await w.analyze(url: E2E.instagram, playlistItems: [1], cookies: .none)
        let r = try await w.execute(job: E2E.job(E2E.instagram, info: child) { $0.selectedEntries = [1] }, destination: out) { _ in }
        #expect(r.files.count == 1)
    }
}
