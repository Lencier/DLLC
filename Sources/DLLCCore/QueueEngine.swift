import Foundation
import Observation

// MARK: - Worker abstraction (real implementation: MediaWorker; tests use fakes)

public enum JobEvent: Sendable {
    case progress(JobProgress)
    /// Worker moved to a new active phase (.downloading / .processing).
    case phase(JobState)
}

public struct JobOutcome: Sendable {
    public var files: [URL]
    public var notes: [String]
    public init(files: [URL], notes: [String] = []) { self.files = files; self.notes = notes }
}

extension JobError: Error {}

public protocol JobWorker: Sendable {
    func analyze(url: String, playlistItems: [Int]?, cookies: CookieSource) async throws -> MediaInfo
    /// Runs the job to completion. Must honour Task cancellation (child processes are killed).
    func execute(job: Job, destination: URL, events: @escaping @Sendable (JobEvent) -> Void) async throws -> JobOutcome
}

public struct ConcurrencyLimits: Codable, Sendable, Equatable {
    public var analysis: Int = 3
    public var downloads: Int = 2
    public var processing: Int = 1
    public init(analysis: Int = 3, downloads: Int = 2, processing: Int = 1) {
        self.analysis = analysis; self.downloads = downloads; self.processing = processing
    }
}

public struct AddResult: Sendable {
    public var added: [UUID]
    /// URLs that were already in the queue (still added — duplicates are allowed for multiple ranges).
    public var duplicates: [String]
    public var rejected: [String]
}

// MARK: - Engine

/// Owns the queue state. All mutations happen on the main actor; work runs in child tasks whose results
/// are applied only if the job's `generation` still matches (stale callbacks are dropped).
@MainActor
@Observable
public final class QueueEngine {
    public private(set) var jobs: [Job] = []
    public var limits: ConcurrencyLimits { didSet { pump() } }
    /// Default destination used when a job doesn't capture one.
    public var defaultDestination: URL

    @ObservationIgnored private let store: JobStore?
    @ObservationIgnored private let worker: JobWorker
    @ObservationIgnored private var tasks: [UUID: (generation: Int, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var lastProgressApply: [UUID: Date] = [:]
    @ObservationIgnored private var autoRetryCount: [UUID: Int] = [:]
    @ObservationIgnored public var onJobFinished: ((Job) -> Void)?
    @ObservationIgnored public var cleanupWorkspace: ((UUID) -> Void)?
    /// Called with the removed jobs after they leave the queue.
    @ObservationIgnored public var onJobsRemoved: (([Job]) -> Void)?

    public init(worker: JobWorker, store: JobStore?, defaultDestination: URL,
                limits: ConcurrencyLimits = ConcurrencyLimits()) {
        self.worker = worker
        self.store = store
        self.defaultDestination = defaultDestination
        self.limits = limits
    }

    // MARK: Lifecycle

    /// Restores persisted jobs. Interrupted work becomes recoverable; analysis restarts automatically.
    public func restore() {
        guard let store else { return }
        var restored = store.load()
        for i in restored.indices {
            switch restored[i].state {
            case .analyzing:
                restored[i].generation += 1
                restored[i].progress = nil
            case .downloading, .processing:
                restored[i].state = .interrupted
                restored[i].progress = nil
                restored[i].enqueueWhenReady = false
                restored[i].generation += 1
            case .queued:
                break // keeps its place; pump() resumes the queue
            default:
                break
            }
        }
        jobs = restored
        persist()
        pump()
    }

    public var activeCount: Int { jobs.filter { $0.state == .downloading || $0.state == .processing }.count }
    public var hasPendingWork: Bool {
        jobs.contains { $0.state.isActive || $0.state == .queued || ($0.enqueueWhenReady && $0.state == .analyzing) }
    }

    // MARK: Commands

    @discardableResult
    public func add(urls: [String], options: OutputOptions, cookies: CookieSource = .none,
                    destination: URL? = nil, info: MediaInfo? = nil, projectID: UUID? = nil) -> AddResult {
        var result = AddResult(added: [], duplicates: [], rejected: [])
        var existing = Set(jobs.map { LinkExtractor.canonicalKey($0.url) })
        for raw in urls {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), LinkExtractor.isAcceptable(url) else {
                result.rejected.append(raw); continue
            }
            if !existing.insert(LinkExtractor.canonicalKey(trimmed)).inserted { result.duplicates.append(trimmed) }
            var job = Job(url: trimmed, options: options, cookies: cookies)
            job.destinationPath = destination?.path
            job.projectID = projectID
            if let info {
                job.info = info
                job.state = .ready
            }
            jobs.append(job)
            result.added.append(job.id)
        }
        persist()
        pump()
        return result
    }

    /// Adds a derived job (e.g. a clip/GIF of an analysed video) that is queued immediately.
    @discardableResult
    public func addDerived(from source: Job, options: OutputOptions, startNow: Bool, destination: URL? = nil) -> UUID {
        var job = Job(url: source.url, options: options, cookies: source.cookies)
        job.info = source.info
        job.destinationPath = destination?.path ?? source.destinationPath
        job.projectID = source.projectID
        job.state = source.info == nil ? .analyzing : (startNow ? .queued : .ready)
        job.enqueueWhenReady = source.info == nil && startNow
        if job.state == .queued { job.destinationPath = job.destinationPath ?? defaultDestination.path }
        if let idx = jobs.firstIndex(where: { $0.id == source.id }) {
            jobs.insert(job, at: idx + 1)
        } else {
            jobs.append(job)
        }
        persist()
        pump()
        return job.id
    }

    public func start(_ id: UUID) {
        guard let i = index(id) else { return }
        // A clip or GIF without a range can only be started from the preview workspace.
        if jobs[i].options.kind == .clip || jobs[i].options.kind == .gif, jobs[i].options.range == nil { return }
        switch jobs[i].state {
        case .ready, .interrupted, .failed, .cancelled:
            if jobs[i].info == nil {
                // Never analysed successfully: analyse first, then queue automatically.
                restartAnalysis(i, enqueue: true)
            } else {
                // A save-folder problem is fixed by choosing another folder: retry into the current one.
                if let category = jobs[i].error?.category,
                   [.destinationUnavailable, .permissionDenied, .diskFull].contains(category) {
                    // A missing project subfolder directly inside the current save folder is created on retry,
                    // so keep it; any other unavailable folder falls back to the current save folder.
                    let current = jobs[i].destinationPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    let creatable = category == .destinationUnavailable && current.map {
                        $0.deletingLastPathComponent().standardizedFileURL.path == defaultDestination.standardizedFileURL.path
                            && FileManager.default.fileExists(atPath: defaultDestination.path)
                    } == true
                    if !creatable { jobs[i].destinationPath = defaultDestination.path }
                }
                jobs[i].state = .queued
                jobs[i].error = nil
                jobs[i].progress = JobProgress(stage: "Waiting")
                jobs[i].destinationPath = jobs[i].destinationPath ?? defaultDestination.path
            }
        case .analyzing, .needsSelection:
            // Remembered: the chosen items start as soon as they're picked / analysed.
            jobs[i].enqueueWhenReady = true
        default:
            return
        }
        persist()
        pump()
    }

    /// Download All: every ready/interrupted job plus jobs still analysing (queued when analysis finishes).
    public func startAll() {
        for job in jobs {
            switch job.state {
            case .ready, .interrupted, .analyzing, .needsSelection: start(job.id)
            default: break
            }
        }
    }

    public func cancel(_ id: UUID) {
        guard let i = index(id) else { return }
        let state = jobs[i].state
        guard state.isActive || state == .queued || jobs[i].enqueueWhenReady else { return }
        jobs[i].generation += 1           // invalidate in-flight callbacks first
        jobs[i].enqueueWhenReady = false
        jobs[i].progress = nil
        if state == .analyzing && jobs[i].info != nil {
            jobs[i].state = .ready
        } else if state == .queued {
            jobs[i].state = .ready
        } else {
            jobs[i].state = .cancelled
            jobs[i].error = nil
        }
        tasks[id]?.task.cancel()
        persist()
        pump()
    }

    /// Restart a failed/cancelled/interrupted job. Waits for any previous process to be reaped first.
    public func retry(_ id: UUID) {
        guard let i = index(id), jobs[i].state.canStart else { return }
        autoRetryCount[id] = 0
        if jobs[i].info == nil || jobs[i].error?.category == .formatUnavailable {
            restartAnalysis(i, enqueue: true)
            persist(); pump()
        } else {
            start(id)
        }
    }

    public func remove(_ ids: [UUID]) {
        for id in ids {
            tasks[id]?.task.cancel()
            tasks[id] = nil
            cleanupWorkspace?(id)
        }
        let removed = jobs.filter { ids.contains($0.id) }
        jobs.removeAll { ids.contains($0.id) }
        persist()
        pump()
        if !removed.isEmpty { onJobsRemoved?(removed) }
    }

    /// Removes completed records; files on disk are untouched.
    public func clearCompleted() {
        let ids = jobs.filter { $0.state == .completed }.map(\.id)
        remove(ids)
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var copy = jobs
        let moving = source.map { copy[$0] }
        for idx in source.sorted(by: >) { copy.remove(at: idx) }
        let insertAt = destination - source.filter { $0 < destination }.count
        copy.insert(contentsOf: moving, at: max(0, min(insertAt, copy.count)))
        jobs = copy
        persist()
    }

    public func move(_ id: UUID, by delta: Int) {
        guard let i = index(id) else { return }
        let j = max(0, min(jobs.count - 1, i + delta))
        guard i != j else { return }
        let job = jobs.remove(at: i)
        jobs.insert(job, at: j)
        persist()
    }

    public func updateOptions(_ id: UUID, _ change: (inout OutputOptions) -> Void) {
        guard let i = index(id), !jobs[i].state.isActive || jobs[i].state == .analyzing else { return }
        change(&jobs[i].options)
        persist()
    }

    /// Moves jobs into a project (nil = none). Jobs that haven't started saving yet also switch to
    /// `destination`; running and finished jobs keep the folder they're saving / saved to.
    public func assign(_ ids: [UUID], toProject projectID: UUID?, destination: URL?) {
        for id in ids {
            guard let i = index(id) else { continue }
            jobs[i].projectID = projectID
            let s = jobs[i].state
            if !(s == .downloading || s == .processing || s == .completed) {
                jobs[i].destinationPath = destination?.path
            }
        }
        persist()
    }

    public func setCookies(_ id: UUID, _ cookies: CookieSource) {
        guard let i = index(id), !jobs[i].state.isActive else { return }
        jobs[i].cookies = cookies
        persist()
    }

    /// Multi-item post: create one job per selected entry, then drop the parent.
    public func resolveSelection(_ id: UUID, entries indices: [Int]) {
        guard let i = index(id), let info = jobs[i].info, info.isMultiItem else { return }
        let parent = jobs[i]
        var children: [Job] = []
        for idx in indices.sorted() {
            guard let entry = info.entries.first(where: { $0.index == idx }) else { continue }
            var opts = parent.options
            let entryURL = entry.url.flatMap { u -> String? in
                guard let url = URL(string: u), LinkExtractor.isAcceptable(url),
                      LinkExtractor.canonicalKey(u) != LinkExtractor.canonicalKey(parent.url) else { return nil }
                return u
            }
            opts.selectedEntries = entryURL == nil ? [idx] : nil
            var child = Job(url: entryURL ?? parent.url, options: opts, cookies: parent.cookies)
            child.destinationPath = parent.destinationPath
            child.projectID = parent.projectID
            child.enqueueWhenReady = parent.enqueueWhenReady
            children.append(child)
        }
        jobs.remove(at: i)
        jobs.insert(contentsOf: children, at: i)
        persist()
        pump()
    }

    /// Called when connectivity returns: retry jobs that failed for network reasons (bounded).
    public func retryNetworkFailures() {
        for job in jobs where job.state == .failed && job.error?.category == .network {
            let n = autoRetryCount[job.id, default: 0]
            guard n < 2 else { continue }
            autoRetryCount[job.id] = n + 1
            start(job.id)
        }
    }

    public func job(_ id: UUID) -> Job? { index(id).map { jobs[$0] } }

    /// For app quit: cancel everything, mark interrupted, flush to disk.
    public func prepareForTermination() {
        for i in jobs.indices where jobs[i].state == .downloading || jobs[i].state == .processing {
            jobs[i].generation += 1
            jobs[i].state = .interrupted
            jobs[i].progress = nil
        }
        for (_, entry) in tasks { entry.task.cancel() }
        tasks.removeAll()
        store?.save(jobs)
        store?.flushNow()
    }

    // MARK: Scheduling

    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }

    private func restartAnalysis(_ i: Int, enqueue: Bool) {
        jobs[i].generation += 1
        jobs[i].state = .analyzing
        jobs[i].error = nil
        jobs[i].progress = nil
        jobs[i].enqueueWhenReady = enqueue
        tasks[jobs[i].id]?.task.cancel()
    }

    private func pump() {
        // Analysis
        var analysing = jobs.filter { $0.state == .analyzing && hasLiveTask($0) }.count
        for job in jobs where job.state == .analyzing && !hasLiveTask(job) {
            guard analysing < max(1, limits.analysis) else { break }
            guard tasks[job.id] == nil else { continue } // previous generation still unwinding
            launchAnalysis(job)
            analysing += 1
        }
        // Downloads (processing-phase jobs don't hold a download slot)
        var downloading = jobs.filter { $0.state == .downloading }.count
        for job in jobs where job.state == .queued {
            guard downloading < max(1, limits.downloads) else { break }
            guard tasks[job.id] == nil else { continue }
            launchExecution(job)
            downloading += 1
        }
    }

    private func hasLiveTask(_ job: Job) -> Bool {
        tasks[job.id]?.generation == job.generation
    }

    private func launchAnalysis(_ job: Job) {
        let id = job.id, gen = job.generation
        let worker = self.worker
        let url = job.url, items = job.options.selectedEntries, cookies = job.cookies
        let task = Task { [weak self] in
            let result: Result<MediaInfo, Error>
            do { result = .success(try await worker.analyze(url: url, playlistItems: items, cookies: cookies)) }
            catch { result = .failure(error) }
            await self?.finishAnalysis(id: id, generation: gen, result: result)
        }
        tasks[id] = (gen, task)
    }

    private func finishAnalysis(id: UUID, generation: Int, result: Result<MediaInfo, Error>) {
        if tasks[id]?.generation == generation { tasks[id] = nil }
        defer { pump() }
        guard let i = index(id), jobs[i].generation == generation, jobs[i].state == .analyzing else { return }
        switch result {
        case .success(let info):
            jobs[i].info = info
            jobs[i].error = nil
            if info.isMultiItem {
                jobs[i].state = .needsSelection
            } else {
                normaliseOptions(&jobs[i])
                jobs[i].state = .ready
                if jobs[i].enqueueWhenReady {
                    jobs[i].enqueueWhenReady = false
                    jobs[i].state = .queued
                    jobs[i].progress = JobProgress(stage: "Waiting")
                    jobs[i].destinationPath = jobs[i].destinationPath ?? defaultDestination.path
                }
            }
        case .failure(let error):
            if error is CancellationError { return }
            jobs[i].state = .failed
            jobs[i].enqueueWhenReady = false
            jobs[i].error = (error as? JobError) ?? JobError(category: .unknown, message: "Couldn’t read this link.",
                                                             suggestion: "Check the link and try again.",
                                                             technical: Redactor.redact(String(describing: error)))
        }
        persist()
    }

    /// Adjust choices that the analysed media can't satisfy (e.g. audio for a silent video).
    private func normaliseOptions(_ job: inout Job) {
        guard let info = job.info else { return }
        if case .option(let id, _, _, _) = job.options.quality {
            // Format IDs can change between analyses; re-bind the same quality to the fresh ones.
            if let fresh = info.qualityOptions.first(where: { $0.id == id }) {
                job.options.quality = .option(id: fresh.id, height: fresh.height, fps: fresh.fps, formatIDs: fresh.formatIDs)
            } else {
                job.options.quality = .best
            }
        }
        if !info.hasVideo && job.options.kind != .audio { job.options.kind = .audio }
    }

    private func launchExecution(_ job: Job) {
        guard let i = index(job.id) else { return }
        let destination = URL(fileURLWithPath: jobs[i].destinationPath ?? defaultDestination.path, isDirectory: true)
        jobs[i].destinationPath = destination.path
        jobs[i].state = .downloading
        jobs[i].progress = JobProgress(stage: "Starting")
        let snapshot = jobs[i]
        let id = job.id, gen = snapshot.generation
        let worker = self.worker
        let task = Task { [weak self] in
            let sink: @Sendable (JobEvent) -> Void = { [weak self] event in
                Task { @MainActor in self?.applyEvent(id: id, generation: gen, event: event) }
            }
            let result: Result<JobOutcome, Error>
            do { result = .success(try await worker.execute(job: snapshot, destination: destination, events: sink)) }
            catch { result = .failure(error) }
            await self?.finishExecution(id: id, generation: gen, result: result)
        }
        tasks[id] = (gen, task)
        persist()
    }

    private func applyEvent(id: UUID, generation: Int, event: JobEvent) {
        guard let i = index(id), jobs[i].generation == generation, jobs[i].state.isActive else { return }
        switch event {
        case .phase(let state):
            guard state == .downloading || state == .processing, jobs[i].state != state else { return }
            jobs[i].state = state
            persist()
            pump() // a download slot may have been freed
        case .progress(let p):
            // Throttle UI updates (~5/s) except stage changes.
            let now = Date()
            if jobs[i].progress?.stage == p.stage, let last = lastProgressApply[id], now.timeIntervalSince(last) < 0.2 { return }
            lastProgressApply[id] = now
            jobs[i].progress = p
        }
    }

    private func finishExecution(id: UUID, generation: Int, result: Result<JobOutcome, Error>) {
        if tasks[id]?.generation == generation { tasks[id] = nil }
        lastProgressApply[id] = nil
        defer { pump() }
        guard let i = index(id), jobs[i].generation == generation, jobs[i].state.isActive else { return }
        switch result {
        case .success(let outcome):
            jobs[i].state = .completed
            jobs[i].completedAt = Date()
            jobs[i].outputFiles = outcome.files.map(\.path)
            jobs[i].notes = outcome.notes
            jobs[i].progress = nil
            jobs[i].error = nil
            cleanupWorkspace?(id)
        case .failure(let error):
            if error is CancellationError || (error as? JobError)?.category == .cancelled {
                jobs[i].state = .cancelled
                jobs[i].progress = nil
            } else {
                jobs[i].state = .failed
                jobs[i].progress = nil
                jobs[i].error = (error as? JobError) ?? JobError(category: .unknown, message: "Something went wrong.",
                                                                 suggestion: "Try again.",
                                                                 technical: Redactor.redact(String(describing: error)))
            }
        }
        persist()
        onJobFinished?(jobs[i])
    }

    private func persist() { store?.save(jobs) }
}
