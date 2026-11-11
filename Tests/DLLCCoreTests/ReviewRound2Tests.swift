import Foundation
import Testing
@testable import DLLCCore

/// Regressions for the second (Codex/Astra) review round.
@MainActor
@Suite struct ReviewRound2Tests {
    let dest = URL(fileURLWithPath: NSTemporaryDirectory())

    private func info(formatID: String) -> MediaInfo {
        var i = FakeWorker.info("https://a.com/v")
        i.qualityOptions = [QualityOption(width: 1280, height: 720, fps: 30, isHDR: false, formatIDs: [formatID],
                                          codecs: ["H.264"], estimatedBytes: nil, estimateIsRough: true)]
        return i
    }

    @Test func staleFormatIDsAreReboundToTheSameQuality() {
        let fresh = info(formatID: "new-22")
        let old = QualityChoice.option(id: "720p30", height: 720, fps: 30, formatIDs: ["old-22"])
        #expect(MediaWorker.rebind(old, to: fresh) == .option(id: "720p30", height: 720, fps: 30, formatIDs: ["new-22"]))
        #expect(MediaWorker.rebind(.option(id: "2160p60", height: 2160, fps: 60, formatIDs: ["x"]), to: fresh) == .best)
        #expect(MediaWorker.sourceVariant(entries: nil, cookies: .none, quality: old) == "q=720p30")
        #expect(MediaWorker.sourceVariant(entries: nil, cookies: .none) == nil)
    }

    @Test func downloadAllRemembersItemsAwaitingSelection() async {
        let w = FakeWorker()
        w.analysisResult = { url in
            .success(FakeWorker.info(url, entries: [MediaEntry(id: "1", index: 1, title: "a", url: nil, thumbnail: nil, duration: 5, isVideo: true),
                                                    MediaEntry(id: "2", index: 2, title: "b", url: nil, thumbnail: nil, duration: 5, isVideo: true)]))
        }
        let e = QueueEngine(worker: w, store: nil, defaultDestination: dest)
        e.add(urls: ["https://a.com/post"], options: OutputOptions())
        await settle()
        #expect(e.jobs[0].state == .needsSelection)
        e.startAll()
        #expect(e.jobs[0].enqueueWhenReady)
        #expect(!e.hasPendingWork)   // waiting on the user doesn't keep the app alive
    }

    @Test func folderErrorRetryUsesTheCurrentSaveFolder() async {
        let w = FakeWorker()
        let e = QueueEngine(worker: w, store: nil, defaultDestination: URL(fileURLWithPath: "/Volumes/Gone"))
        e.add(urls: ["https://a.com/1"], options: OutputOptions())
        await settle()
        e.start(e.jobs[0].id)
        await settle()
        w.finishExecution(e.jobs[0].id, error: JobError(category: .destinationUnavailable, message: "gone", suggestion: nil))
        await settle()
        #expect(e.jobs[0].state == .failed)
        e.defaultDestination = dest
        e.start(e.jobs[0].id)
        #expect(e.jobs[0].destinationPath == dest.path)
    }

    @Test func folderErrorRetryKeepsAProjectSubfolder() async {
        let w = FakeWorker()
        let e = QueueEngine(worker: w, store: nil, defaultDestination: dest)
        let project = dest.appendingPathComponent("Project \(UUID().uuidString)", isDirectory: true)
        e.add(urls: ["https://a.com/1"], options: OutputOptions())
        await settle()
        e.assign([e.jobs[0].id], toProject: UUID(), destination: project)
        e.start(e.jobs[0].id)
        await settle()
        w.finishExecution(e.jobs[0].id, error: JobError(category: .destinationUnavailable, message: "gone", suggestion: nil))
        await settle()
        e.start(e.jobs[0].id)
        #expect(e.jobs[0].destinationPath == project.path)
    }

    @Test func redactorDropsURLCredentials() {
        let s = Redactor.redact("GET https://alice:hunter2@media.example/v?x=1 failed")
        #expect(!s.contains("alice") && !s.contains("hunter2"))
        #expect(s.contains("https://media.example/…"))
    }

    @Test func concurrentCacheStoreKeepsTheFirstCopy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dllc-c2-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = SourceCache(directory: dir)
        let a = dir.appendingPathComponent("a.mp4"), b = dir.appendingPathComponent("b.mp4")
        try Data([1]).write(to: a); try Data([2]).write(to: b)
        let first = try cache.store(url: "https://a.com/v", file: a)
        let second = try cache.store(url: "https://a.com/v", file: b)
        #expect(first == second)
        #expect(try Data(contentsOf: first) == Data([1]))
        #expect(!FileManager.default.fileExists(atPath: b.path))
    }

    @Test func hdrIsToneMappedNotJustTruncated() {
        let out = URL(fileURLWithPath: "/tmp/o.mp4")
        let compat = FFmpegCommand.compatibleMP4(input: out, output: out, reencodeVideo: true, reencodeAudio: false,
                                                 hardware: false, sourceBitrate: nil, hdrTransfer: "arib-std-b67").joined(separator: " ")
        #expect(compat.contains("tonemap=tonemap=hable") && compat.contains("tin=arib-std-b67") && compat.contains("-color_trc bt709"))
        let clip = FFmpegCommand.preciseClip(video: MediaInput(url: "/tmp/a.mp4"), audio: nil, range: .init(start: 0, end: 1),
                                             includeAudio: false, output: out, preserveHDR: false, hdrTransfer: "smpte2084")
        #expect(clip.joined(separator: " ").contains("tin=smpte2084"))
        let sdr = FFmpegCommand.preciseClip(video: MediaInput(url: "/tmp/a.mp4"), audio: nil, range: .init(start: 0, end: 1),
                                            includeAudio: false, output: out, preserveHDR: false)
        #expect(!sdr.joined(separator: " ").contains("tonemap"))
    }
}
