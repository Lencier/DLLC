import Foundation
import Testing
@testable import DLLCCore

/// Scriptable fake worker: each call waits until the test releases it.
final class FakeWorker: JobWorker, @unchecked Sendable {
    private let lock = NSLock()
    private var analysisGates: [String: CheckedContinuation<MediaInfo, Error>] = [:]
    private var executeGates: [UUID: CheckedContinuation<JobOutcome, Error>] = [:]
    private(set) var analyzeCalls: [String] = []
    private(set) var executeCalls: [UUID] = []
    var analysisResult: (String) -> Result<MediaInfo, Error> = { url in .success(FakeWorker.info(url)) }
    var autoAnalyze = true
    var autoExecute = false

    static func info(_ url: String, entries: [MediaEntry] = []) -> MediaInfo {
        MediaInfo(id: url, title: "T \(url.suffix(4))", creator: nil, platform: .other, extractor: nil,
                  webpageURL: url, thumbnailURL: nil, duration: 10, isLive: false,
                  videoVariants: [], audioVariants: [], qualityOptions: [], hasAudio: true, hasVideo: true,
                  entries: entries, analyzedAt: Date())
    }

    func analyze(url: String, playlistItems: [Int]?, cookies: CookieSource) async throws -> MediaInfo {
        lock.withLock { analyzeCalls.append(url) }
        if autoAnalyze { return try analysisResult(url).get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in lock.withLock { analysisGates[url] = c } }
        } onCancel: {
            self.lock.withLock { self.analysisGates.removeValue(forKey: url) }?.resume(throwing: CancellationError())
        }
    }

    func execute(job: Job, destination: URL, events: @escaping @Sendable (JobEvent) -> Void) async throws -> JobOutcome {
        lock.withLock { executeCalls.append(job.id) }
        events(.progress(JobProgress(stage: "Downloading", fraction: 0.5)))
        if autoExecute { return JobOutcome(files: [destination.appendingPathComponent("x.mp4")]) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in lock.withLock { executeGates[job.id] = c } }
        } onCancel: {
            self.lock.withLock { self.executeGates.removeValue(forKey: job.id) }?.resume(throwing: CancellationError())
        }
    }

    func finishAnalysis(_ url: String) {
        lock.withLock { analysisGates.removeValue(forKey: url) }?.resume(returning: FakeWorker.info(url))
    }
    func finishExecution(_ id: UUID, error: Error? = nil) {
        let c = lock.withLock { executeGates.removeValue(forKey: id) }
        if let error { c?.resume(throwing: error) } else { c?.resume(returning: JobOutcome(files: [URL(fileURLWithPath: "/tmp/out.mp4")])) }
    }
    var pendingExecutions: Int { lock.withLock { executeGates.count } }
}

@MainActor
func settle(_ times: Int = 20) async {
    for _ in 0..<times { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor
@Suite struct QueueEngineTests {
    let dest = URL(fileURLWithPath: NSTemporaryDirectory())

    @Test func downloadAllIncludesItemsStillAnalyzing() async {
        let w = FakeWorker(); w.autoAnalyze = false
        let e = QueueEngine(worker: w, store: nil, defaultDestination: dest)
        e.add(urls: ["https://a.com/1", "https://a.com/2"], options: OutputOptions())
        await settle()
        #expect(e.jobs.allSatisfy { $0.state == .analyzing })
        e.startAll()
        w.finishAnalysis("https://a.com/1")
        w.finishAnalysis("https://a.com/2")
        await settle()
        #expect(e.jobs.allSatisfy { $0.state == .downloading })
    }

    @Test func respectsDownloadLimitAndFailureDoesNotBlock() async {
        let w = FakeWorker()
        let e = QueueEngine(worker: w, store: nil, defaultDestination: dest, limits: ConcurrencyLimits(downloads: 2))
        e.add(urls: ["https://a.com/1", "https://a.com/2", "https://a.com/3"], options: OutputOptions())
        await settle()
        e.startAll()
        await settle()
        #expect(e.jobs.filter { $0.state == .downloading }.count == 2)
        #expect(e.jobs[2].state == .queued)
        w.finishExecution(e.jobs[0].id, error: JobError(category: .network, message: "x"))
        await settle()
        #expect(e.jobs[0].state == .failed)
        #expect(e.jobs[2].state == .downloading)
    }

    @Test func cancelThenRetryIgnoresStaleCallbacks() async {
        let w = FakeWorker()
        let e = QueueEngine(worker: w, store: nil, defaultDestination: dest)
        e.add(urls: ["https://a.com/1"], options: OutputOptions())
        await settle()
        let id = e.jobs[0].id
        e.start(id)
        await settle()
        #expect(e.jobs[0].state == .downloading)
        e.cancel(id)
        #expect(e.jobs[0].state == .cancelled)
        await settle()
        e.retry(id)
        await settle()
        #expect(e.jobs[0].state == .downloading)
        #expect(w.executeCalls.count == 2)
        w.finishExecution(id)
        await settle()
        #expect(e.jobs[0].state == .completed)
    }

    @Test func duplicatesAreWarnedButAdded() async {
        let e = QueueEngine(worker: FakeWorker(), store: nil, defaultDestination: dest)
        e.add(urls: ["https://youtu.be/abc"], options: OutputOptions())
        let r = e.add(urls: ["https://www.youtube.com/watch?v=abc&si=xyz"], options: OutputOptions())
        #expect(r.duplicates.count == 1)
        #expect(e.jobs.count == 2)
    }

    @Test func duplicatesWithinOnePasteAreWarned() async {
        let e = QueueEngine(worker: FakeWorker(), store: nil, defaultDestination: dest)
        let r = e.add(urls: ["https://youtu.be/abc", "https://www.youtube.com/watch?v=abc"], options: OutputOptions())
        #expect(r.duplicates.count == 1 && e.jobs.count == 2)
    }

    @Test func clipWithoutRangeIsNotStartedByDownloadAll() async {
        let e = QueueEngine(worker: FakeWorker(), store: nil, defaultDestination: dest)
        var clip = OutputOptions(); clip.kind = .clip
        e.add(urls: ["https://a.com/clip"], options: clip)
        e.add(urls: ["https://a.com/video"], options: OutputOptions())
        await settle()
        e.startAll()
        await settle()
        #expect(e.jobs[0].state == .ready)
        #expect(e.jobs[1].state != .ready)
    }

    @Test func sourceCacheSeparatesItemsAndLogins() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dllc-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = SourceCache(directory: dir)
        let file = dir.appendingPathComponent("in.mp4")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1]).write(to: file)
        let url = "https://www.instagram.com/p/X/"
        let item2 = MediaWorker.sourceVariant(entries: [2], cookies: .none)
        _ = try cache.store(url: url, variant: item2, file: file)
        #expect(cache.lookup(url: url, variant: item2) != nil)
        #expect(cache.lookup(url: url, variant: MediaWorker.sourceVariant(entries: [3], cookies: .none)) == nil)
        #expect(cache.lookup(url: url) == nil)
        #expect(MediaWorker.sourceVariant(entries: nil, cookies: .browser(name: "safari", profile: nil)) == "login=safari")
        #expect(MediaWorker.sourceVariant(entries: nil, cookies: .browser(name: "chrome", profile: "Work")) == "login=chrome:Work")
    }

    @Test func rejectsNonHTTPLinks() async {
        let e = QueueEngine(worker: FakeWorker(), store: nil, defaultDestination: dest)
        let r = e.add(urls: ["file:///etc/passwd", "javascript:alert(1)", "notaurl"], options: OutputOptions())
        #expect(r.rejected.count == 3)
        #expect(e.jobs.isEmpty)
    }

    @Test func restoreMarksActiveJobsInterruptedAndKeepsQueue() async throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = JobStore(url: file, debounce: 0)
        let w = FakeWorker()
        let e = QueueEngine(worker: w, store: store, defaultDestination: dest)
        e.add(urls: ["https://a.com/1", "https://a.com/2", "https://a.com/3"], options: OutputOptions())
        await settle()
        e.limits = ConcurrencyLimits(downloads: 1)
        e.startAll()
        await settle()
        #expect(e.jobs[0].state == .downloading)
        e.prepareForTermination()

        let w2 = FakeWorker()
        let e2 = QueueEngine(worker: w2, store: JobStore(url: file, debounce: 0), defaultDestination: dest,
                             limits: ConcurrencyLimits(downloads: 1))
        e2.restore()
        await settle()
        #expect(e2.jobs.count == 3)
        #expect(e2.jobs[0].state == .interrupted)
        #expect(e2.jobs[1].state == .downloading) // queued work resumes
        #expect(e2.jobs[2].state == .queued)
    }

    @Test func multiItemNeedsSelectionThenSplits() async {
        let w = FakeWorker()
        let entries = (1...3).map { MediaEntry(id: "\($0)", index: $0, title: "E\($0)", url: nil, thumbnail: nil, duration: 5, isVideo: true) }
        w.analysisResult = { url in .success(FakeWorker.info(url, entries: url.hasSuffix("post") ? entries : [])) }
        let e = QueueEngine(worker: w, store: nil, defaultDestination: dest)
        e.add(urls: ["https://instagram.com/p/post"], options: OutputOptions())
        await settle()
        #expect(e.jobs[0].state == .needsSelection)
        e.resolveSelection(e.jobs[0].id, entries: [1, 3])
        await settle()
        #expect(e.jobs.count == 2)
        #expect(e.jobs.map { $0.options.selectedEntries } == [[1], [3]])
    }

    @Test func removeKeepsOtherJobsRunning() async {
        let w = FakeWorker()
        let e = QueueEngine(worker: w, store: nil, defaultDestination: dest)
        e.add(urls: ["https://a.com/1", "https://a.com/2"], options: OutputOptions())
        await settle()
        e.startAll()
        await settle()
        e.remove([e.jobs[0].id])
        await settle()
        #expect(e.jobs.count == 1)
        #expect(e.jobs[0].state == .downloading)
    }

    @Test func gateLimitsConcurrency() async throws {
        let gate = AsyncGate(limit: 1)
        try await gate.acquire()
        let t = Task { try await gate.acquire() }
        await settle()
        #expect(await gate.waitingCount == 1)
        t.cancel()
        await settle()
        #expect(await gate.waitingCount == 0)
        await gate.release()
        try await gate.acquire()
    }
}

@Suite struct LinkExtractorTests {
    @Test func extractsMultipleLinks() {
        let text = "look https://youtu.be/abc and\nhttps://x.com/u/status/1?s=20 , also www.example.com/x ftp://no"
        let links = LinkExtractor.extract(from: text)
        #expect(links.contains("https://youtu.be/abc"))
        #expect(links.contains("https://x.com/u/status/1?s=20"))
        #expect(!links.contains { $0.hasPrefix("ftp") })
    }

    @Test func canonicalKeys() {
        #expect(LinkExtractor.canonicalKey("https://youtu.be/abc?si=1") == LinkExtractor.canonicalKey("https://www.youtube.com/watch?v=abc"))
        #expect(LinkExtractor.canonicalKey("https://twitter.com/a/status/1") == LinkExtractor.canonicalKey("https://x.com/a/status/1"))
        #expect(LinkExtractor.canonicalKey("https://youtube.com/shorts/abc") == LinkExtractor.canonicalKey("https://youtu.be/abc"))
    }
}
