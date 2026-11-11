import AVFoundation
import AppKit
import DLLCCore
import Observation

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case clip = "Clip", frame = "Frame", gif = "GIF"
    var id: String { rawValue }
}

/// Owns one AVPlayer for the preview workspace. Time is always expressed in *source* seconds; the
/// preview rendition (stream, local source or proxy) shares the source timeline.
@MainActor
@Observable
final class PlayerController {
    enum PreviewKind: Equatable {
        case none
        case stream(label: String)   // low-res online rendition
        case local                   // full-quality cached source (exact frames)
        case proxy                   // local H.264 proxy of a source AVPlayer can't decode
    }
    enum SourceState: Equatable {
        case notLoaded
        case loading(stage: String, fraction: Double?)
        case loaded
        case failed(String)
    }

    let jobID: UUID
    let player = AVPlayer()
    private(set) var preview: PreviewKind = .none
    private(set) var status: String? = "Preparing preview…"
    private(set) var previewError: String?
    private(set) var previewHasAudio = true
    private(set) var source: SourceState = .notLoaded
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    /// Exact presentation timestamps of the source's video frames (only when a local source is loaded).
    private(set) var frameTimes: [Double]?
    private(set) var nominalFPS: Double?
    /// Frame rate of what is actually on screen. A low-res online preview often runs at a different rate
    /// (e.g. 30 fps) than the quality being downloaded (e.g. 60 fps); stepping must follow the preview.
    private(set) var previewFPS: Double?
    var inPoint: Double?
    var outPoint: Double?
    var loopRange = true
    /// Preview loudness only (exports are never affected); remembered between previews.
    var volume: Float = UserDefaults.standard.object(forKey: "previewVolume") as? Float ?? 1 {
        didSet { player.volume = volume; UserDefaults.standard.set(volume, forKey: "previewVolume") }
    }
    var isMuted: Bool = UserDefaults.standard.bool(forKey: "previewMuted") {
        didSet { player.isMuted = isMuted; UserDefaults.standard.set(isMuted, forKey: "previewMuted") }
    }
    var mode: WorkspaceMode = .clip
    /// True once the video layer has a frame to show (until then the view shows the thumbnail).
    var surfaceReady = false
    /// Set once the user plays, steps or scrubs: until then the thumbnail stands in for the (often black) first frame.
    var hasInteracted = false
    /// True while the current item is still opening.
    private(set) var itemLoading = false
    /// Evenly spaced thumbnails along the timeline (empty until generated or when the source can't provide them).
    private(set) var filmstrip: [CGImage] = []

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var localTask: Task<Void, Never>?
    @ObservationIgnored private var isTornDown = false
    @ObservationIgnored private var sourceTask: Task<Void, Never>?
    @ObservationIgnored private var sourceToken: UUID?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var seekTarget: CMTime?
    @ObservationIgnored private var seekInFlight = false
    @ObservationIgnored private var seekPrecise = false
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var autoLoadTask: Task<Void, Never>?
    @ObservationIgnored private var filmstripTask: Task<Void, Never>?
    @ObservationIgnored private var streamRetried = false
    @ObservationIgnored private var filmstripAssetKey: String?
    @ObservationIgnored private var stripAsset: AVAsset?
    @ObservationIgnored private var zoomStripTask: Task<Void, Never>?

    // MARK: Timeline zoom state
    /// Requested start / length of the visible part of the timeline; a length of 0 means "whole video".
    private(set) var viewStartSetting: Double = 0
    private(set) var viewSpanSetting: Double = 0
    /// Sharper thumbnails for the zoomed-in part of the timeline.
    private(set) var zoomStrip: ZoomStrip?
    struct ZoomStrip { let start: Double; let span: Double; let images: [CGImage] }

    init(jobID: UUID, model: AppModel) {
        defer { player.volume = volume; player.isMuted = isMuted }
        self.jobID = jobID
        self.model = model
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .pause
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
        installTimeObserver()
    }

    func tearDown() {
        isTornDown = true
        localTask?.cancel()
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = nil
        autoLoadTask?.cancel()
        filmstripTask?.cancel()
        zoomStripTask?.cancel()
        sourceTask?.cancel()
        player.pause()
        if let t = timeObserver { player.removeTimeObserver(t) }
        timeObserver = nil
        rateObservation = nil
        itemStatusObservation = nil
        player.replaceCurrentItem(with: nil)
    }

    private var job: Job? { model?.engine.job(jobID) }

    // MARK: Loading

    /// Starts the preview once the job has been analysed; safe to call again (e.g. when analysis finishes).
    func start() {
        guard !started, let job, let info = job.info else { return }
        started = true
        duration = info.duration ?? 0
        nominalFPS = Self.sourceFPS(info: info, quality: job.options.quality)
        resetRangeToWhole()
        if let worker = model?.worker, let local = worker.sources.lookup(url: job.url, variant: MediaWorker.sourceVariant(entries: job.options.selectedEntries, cookies: job.cookies)) {
            source = .loaded
            localTask = Task { await useLocal(local) }
            return
        }
        if let (url, headers, label, hasAudio) = Self.streamCandidate(info) {
            openStream(url: url, headers: headers)
            preview = .stream(label: label)
            previewHasAudio = hasAudio
            status = nil
        } else {
            status = "No online preview for this format."
        }
        // Nearly full disk: never fetch the full source on its own.
        // Nor on a hotspot or in Low Data Mode, where it would eat the data plan.
        let minutes = model?.isLowOnSpace == true || model?.isMeteredNetwork == true ? 0 : Preferences.autoLoadSourceMinutes
        if let d = info.duration, d > 0, d <= minutes * 60 {
            // Short videos fetch the exact-frame source automatically — after a moment, so clicking
            // through the list doesn't start a download for every row passed over.
            autoLoadTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                self?.loadSource()
            }
        } else if preview == .none {
            status = "Load the source to preview this video."
        }
    }

    private func openStream(url: URL, headers: [String: String]) {
        let asset = AVURLAsset(url: url, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
        replaceItem(AVPlayerItem(asset: asset), at: currentTime)
    }

    /// In/Out start out covering the whole video, so the timeline always shows two handles to drag.
    func resetRangeToWhole() {
        guard duration > 0 else { return }
        inPoint = 0
        outPoint = duration
        syncRangeText()
    }

    /// Downloads the full-quality source once (cached), then previews it with exact frame positions.
    func loadSource() {
        guard let job, let worker = model?.worker, sourceTask == nil else { return }
        source = .loading(stage: "Starting", fraction: nil)
        let info = job.info
        let token = UUID()
        sourceToken = token
        sourceTask = Task { [weak self] in
            defer { if self?.sourceToken == token { self?.sourceTask = nil } }
            do {
                let file = try await worker.fetchSource(url: job.url, info: info, quality: .best, cookies: job.cookies,
                                                        entries: job.options.selectedEntries) { event in
                    if case .progress(let p) = event {
                        Task { @MainActor in if self?.sourceToken == token { self?.source = .loading(stage: p.stage, fraction: p.fraction) } }
                    }
                }
                guard let self, !Task.isCancelled, self.sourceToken == token else { return }
                self.source = .loaded
                await self.useLocal(file)
            } catch {
                // A superseded load (cancelled, then started again) must not touch the newer one's state.
                guard let self, self.sourceToken == token else { return }
                self.source = error is CancellationError ? .notLoaded
                    : .failed((error as? JobError)?.message ?? "Couldn’t load the source.")
            }
        }
    }

    func cancelSourceLoad() {
        sourceTask?.cancel()
        sourceTask = nil
        sourceToken = nil
        source = .notLoaded
    }

    private func useLocal(_ file: URL) async {
        let keepTime = currentTime
        let asset = AVURLAsset(url: file)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        var decodable = playable && !videoTracks.isEmpty
        if decodable, let track = videoTracks.first {
            decodable = (try? await track.load(.isPlayable)) ?? false
        }
        if decodable {
            replaceItem(AVPlayerItem(asset: asset), at: keepTime)
            preview = .local
            status = nil
        } else {
            status = "Preparing preview proxy… (this source’s codec isn’t supported by the macOS player)"
            if let proxy = await makeProxy(file) {
                replaceItem(AVPlayerItem(asset: AVURLAsset(url: proxy)), at: keepTime)
                preview = .proxy
                status = nil
            } else {
                status = nil
                previewError = "Couldn’t prepare a preview. Exports and snapshots still use the source."
            }
        }
        previewHasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty || preview == .proxy
        if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 {
            // Keep a whole-video range whole when the exact duration arrives.
            let wasWhole = (inPoint ?? 0) <= 0.0005 && outPoint.map { abs($0 - duration) < 0.5 } ?? true
            duration = d.seconds
            if wasWhole { inPoint = 0; outPoint = duration; syncRangeText() }
        }
        guard !isTornDown, !Task.isCancelled else { return }
        await buildFrameIndex(file)
    }

    private func makeProxy(_ file: URL) async -> URL? {
        guard let model, let worker = model.worker else { return nil }
        let dir = model.paths.proxyCache
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Key by the source's identity (path, size, modification time), not its name: two downloads can
        // share a file name in different folders.
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let identity = "\(file.standardizedFileURL.path)|\((attrs?[.size] as? NSNumber)?.int64Value ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let key = String(identity.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }, radix: 16)
        let out = dir.appendingPathComponent("\(key)-proxy.mp4")
        if FileManager.default.fileExists(atPath: out.path) { CacheFolder.touch(out); return out }
        let tmp = dir.appendingPathComponent(UUID().uuidString + ".mp4")
        let args = FFmpegCommand.proxy(input: file, output: tmp, maxHeight: 720)
        guard let result = try? await worker.supervisor.run(ProcessSpec(executable: worker.tools.ffmpeg, arguments: args)),
              result.succeeded else {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        try? FileManager.default.moveItem(at: tmp, to: out)
        AppModel.trimProxies(dir)
        return out
    }

    private func buildFrameIndex(_ file: URL) async {
        guard let worker = model?.worker else { return }
        let spec = ProcessSpec(executable: worker.tools.ffprobe, arguments: FFprobe.frameIndexArguments(file: file))
        guard let result = try? await worker.supervisor.run(spec, captureStdout: true), result.succeeded else { return }
        // Packet PTS are absolute; the player, cuts and snapshots count from the file's start time.
        let origin = (try? await worker.probe(file))?.startTime ?? 0
        let times = await Task.detached { FFprobe.parseFrameIndex(result.stdout).map { $0 - origin } }.value
        guard times.count > 1 else { return }
        frameTimes = times
        let span = (times.last! - times.first!)
        if span > 0 { nominalFPS = Double(times.count - 1) / span }
    }

    private func replaceItem(_ item: AVPlayerItem, at time: Double) {
        // Async loading can finish after the preview was closed; never revive a closed player.
        guard !isTornDown else { return }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        surfaceReady = false
        itemLoading = true
        player.replaceCurrentItem(with: item)
        if time > 0 { seek(to: time, precise: true) }
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                switch status {
                case .readyToPlay:
                    self.itemLoading = false
                    // A paused stream shows nothing until a frame is decoded: seek once so it draws one.
                    if case .stream = self.preview, !self.isPlaying, !self.seekInFlight {
                        self.seek(to: max(self.currentTime, 0.001), precise: false)
                    }
                    self.makeFilmstrip(for: item.asset)
                    let asset = item.asset
                    Task { [weak self] in
                        let track = try? await asset.loadTracks(withMediaType: .video).first
                        let rate = try? await track?.load(.nominalFrameRate)
                        guard let self, self.player.currentItem === item else { return }
                        self.previewFPS = rate.flatMap { $0 > 0 ? Double($0) : nil }
                    }
                case .failed:
                    self.itemLoading = false
                    if case .stream = self.preview {
                        // Fresh stream links are briefly refused (403) right after analysis: retry once.
                        if !self.streamRetried, let asset = item.asset as? AVURLAsset {
                            self.streamRetried = true
                            let url = asset.url
                            try? await Task.sleep(for: .seconds(3))
                            guard self.player.currentItem === item else { return }
                            let info = self.job?.info
                            let headers = info.flatMap(Self.streamCandidate)?.1 ?? [:]
                            self.openStream(url: url, headers: headers)
                            return
                        }
                        self.preview = .none
                        self.status = "The online preview couldn’t be opened. Load the source to preview this video."
                    } else {
                        self.status = "This file couldn’t be played."
                    }
                default:
                    break
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isPlaying = false }
        }
    }

    /// Builds the timeline's thumbnail strip from whatever is being previewed (local file, proxy or stream).
    private func makeFilmstrip(for asset: AVAsset) {
        let key = (asset as? AVURLAsset)?.url.absoluteString ?? UUID().uuidString
        // Keep a strip made from a better source; replace a stream strip once the local file is ready.
        if filmstripAssetKey == key || (!filmstrip.isEmpty && preview != .local && preview != .proxy) { return }
        let d = duration
        guard d > 0 else { return }
        stripAsset = asset
        zoomStrip = nil
        filmstripAssetKey = key
        filmstripTask?.cancel()
        let count = 14
        filmstripTask = Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 136)
            let slack = CMTime(seconds: d / Double(count) / 2, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = slack
            generator.requestedTimeToleranceAfter = slack
            var images: [CGImage] = []
            for i in 0..<count {
                if Task.isCancelled { return }
                let t = CMTime(seconds: d * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
                guard let (image, _) = try? await generator.image(at: t) else { break }
                images.append(image)
            }
            guard !Task.isCancelled, images.count == count else { return }
            self?.filmstrip = images
        }
    }

    // MARK: Timeline zoom

    /// Length of the visible part of the timeline (the whole video unless zoomed in).
    var visibleSpan: Double {
        guard duration > 0 else { return 0 }
        return viewSpanSetting > 0 ? min(viewSpanSetting, duration) : duration
    }
    /// Start of the visible part, kept inside the video.
    var visibleStart: Double { min(max(viewStartSetting, 0), max(0, duration - visibleSpan)) }
    var zoomFactor: Double { visibleSpan > 0 ? duration / visibleSpan : 1 }
    var isZoomed: Bool { zoomFactor > 1.001 }
    /// Never zoom in further than about one second across the whole timeline.
    var maxZoom: Double { max(1, min(400, duration)) }

    /// Zooms to `factor` × keeping `anchor` (default: the playhead, if visible) at the same place on screen.
    func setZoom(_ factor: Double, around anchor: Double? = nil) {
        guard duration > 0 else { return }
        let z = min(max(factor, 1), maxZoom)
        let oldStart = visibleStart, oldSpan = visibleSpan
        let a = anchor ?? ((oldStart...(oldStart + oldSpan)).contains(currentTime) ? currentTime : oldStart + oldSpan / 2)
        let fraction = oldSpan > 0 ? (a - oldStart) / oldSpan : 0.5
        let span = duration / z
        viewSpanSetting = z <= 1.001 ? 0 : span
        viewStartSetting = a - fraction * span
        viewStartSetting = visibleStart
        scheduleZoomStrip()
    }

    func panTimeline(by seconds: Double) {
        guard isZoomed else { return }
        viewStartSetting = visibleStart + seconds
        viewStartSetting = visibleStart
        scheduleZoomStrip()
    }

    /// Centres the visible part on `time` (used by the overview bar).
    func centerTimeline(on time: Double) {
        guard isZoomed else { return }
        viewStartSetting = time - visibleSpan / 2
        viewStartSetting = visibleStart
        scheduleZoomStrip()
    }

    func fitTimeline() {
        viewSpanSetting = 0
        viewStartSetting = 0
        zoomStripTask?.cancel()
        zoomStrip = nil
    }

    /// Fills the timeline with the In–Out range (plus a little room either side).
    func zoomToRange() {
        guard duration > 0 else { return }
        let i = inPoint ?? 0, o = outPoint ?? duration
        let span = max(o - i, 1) * 1.2
        guard span < duration * 0.95 else { fitTimeline(); return }
        viewSpanSetting = span
        viewStartSetting = i - (span - (o - i)) / 2
        viewStartSetting = visibleStart
        scheduleZoomStrip()
    }

    /// Pages the zoomed timeline so `time` is on screen (playback and handle drags past the edge).
    func revealInTimeline(_ time: Double) {
        guard isZoomed else { return }
        let start = visibleStart, span = visibleSpan
        if time > start + span { viewStartSetting = time - span * 0.9 }
        else if time < start { viewStartSetting = time - span * 0.1 }
        else { return }
        viewStartSetting = visibleStart
        scheduleZoomStrip()
    }

    /// Regenerates thumbnails for just the visible part, shortly after zooming / panning stops.
    private func scheduleZoomStrip() {
        zoomStripTask?.cancel()
        guard isZoomed, let asset = stripAsset else { return }
        let start = visibleStart, span = visibleSpan
        zoomStripTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let count = 14
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 136)
            let slack = CMTime(seconds: span / Double(count) / 2, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = slack
            generator.requestedTimeToleranceAfter = slack
            var images: [CGImage] = []
            for i in 0..<count {
                if Task.isCancelled { return }
                let t = CMTime(seconds: start + span * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
                guard let (image, _) = try? await generator.image(at: t) else { return }
                images.append(image)
            }
            guard !Task.isCancelled else { return }
            self?.zoomStrip = ZoomStrip(start: start, span: span, images: images)
        }
    }

    private func installTimeObserver() {
        // 20 Hz is enough for a smooth playhead without waking the CPU unnecessarily; paused = no callbacks.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.seekInFlight else { return }
                self.currentTime = t.seconds.isFinite ? t.seconds : 0
                if self.loopRange, self.isPlaying, let i = self.inPoint, let o = self.outPoint, o > i,
                   self.currentTime >= o {
                    self.seek(to: i, precise: true)
                }
            }
        }
    }

    // MARK: Transport

    func togglePlay() {
        hasInteracted = true
        if isPlaying {
            player.pause()
        } else {
            if loopRange, let i = inPoint, let o = outPoint, currentTime >= o || currentTime < i {
                seek(to: i, precise: true)
            } else if duration > 0, currentTime >= duration - 0.05 {
                seek(to: 0, precise: true)
            }
            player.play()
        }
    }

    func playRange() {
        guard let i = inPoint else { return }
        hasInteracted = true
        loopRange = true
        seek(to: i, precise: true)
        player.play()
    }

    /// Coalesces rapid seeks: only one seek in flight, the latest target wins.
    func seek(to seconds: Double, precise: Bool) {
        let clamped = max(0, duration > 0 ? min(seconds, duration) : seconds)
        currentTime = clamped
        seekTarget = CMTime(seconds: clamped, preferredTimescale: 600_000)
        // A precise request stays precise even when coalesced behind a scrubbing seek.
        seekPrecise = precise || (seekPrecise && seekInFlight)
        guard !seekInFlight else { return }
        chase()
    }

    private func chase() {
        guard let target = seekTarget else { seekInFlight = false; return }
        let tolerance = seekPrecise ? CMTime.zero : CMTime(value: 1, timescale: 10)
        seekTarget = nil
        seekPrecise = false
        seekInFlight = true
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.seekTarget != nil { self.chase() } else { self.seekInFlight = false }
            }
        }
    }

    // MARK: Frames

    var hasExactFrames: Bool { frameTimes != nil && (preview == .local || preview == .proxy) }

    /// Index of the frame whose presentation interval contains `t`.
    func frameIndex(at t: Double) -> Int? {
        guard let f = frameTimes, !f.isEmpty else { return nil }
        var lo = 0, hi = f.count - 1
        if t < f[0] { return 0 }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if f[mid] <= t + 1e-6 { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Start time of the frame containing `t` (exact when indexed, nominal grid otherwise).
    func frameStart(at t: Double) -> Double {
        if let f = frameTimes, let i = frameIndex(at: t) { return f[i] }
        guard let fps = nominalFPS, fps > 0 else { return t }
        return (t * fps + 1e-6).rounded(.down) / fps
    }

    /// End (exclusive) of the frame containing `t`.
    func frameEnd(at t: Double) -> Double {
        if let f = frameTimes, let i = frameIndex(at: t) {
            return i + 1 < f.count ? f[i + 1] : min(duration, f[i] + (frameDuration(at: t) ?? 0.04))
        }
        return frameStart(at: t) + (frameDuration(at: t) ?? 0.04)
    }

    func frameDuration(at t: Double) -> Double? {
        if let f = frameTimes, let i = frameIndex(at: t), i + 1 < f.count { return f[i + 1] - f[i] }
        return nominalFPS.map { 1 / $0 }
    }

    /// Frame grid used for stepping and the frame timecode: the indexed source frames when available,
    /// otherwise the rate of what is on screen (online preview), otherwise the source's nominal rate.
    var steppingFPS: Double? {
        if hasExactFrames { return nominalFPS }
        if case .stream = preview { return previewFPS ?? nominalFPS }
        return nominalFPS ?? previewFPS
    }

    /// The frame on screen: number (from 0), rate, and whether it's exact (indexed source) or estimated.
    var displayedFrame: (index: Int, fps: Double, exact: Bool)? {
        if hasExactFrames, let i = frameIndex(at: currentTime), let fps = nominalFPS { return (i, fps, true) }
        guard let fps = steppingFPS, fps > 0 else { return nil }
        return (Int((currentTime * fps + 1e-6).rounded(.down)), fps, false)
    }

    func step(_ delta: Int) {
        hasInteracted = true
        player.pause()
        // Land in the middle of the target frame: a seek right on a frame boundary can show the frame
        // before it (timestamps are rounded), which looks like a repeated frame.
        if hasExactFrames, let f = frameTimes, let i = frameIndex(at: currentTime) {
            let j = max(0, min(f.count - 1, i + delta))
            let next = j + 1 < f.count ? f[j + 1] : f[j] + (frameDuration(at: f[j]) ?? 0.04)
            seek(to: f[j] + (next - f[j]) / 2, precise: true)
        } else if let fps = steppingFPS, fps > 0 {
            let n = max(0, (currentTime * fps + 1e-6).rounded(.down) + Double(delta))
            seek(to: (n + 0.5) / fps, precise: true)
        } else {
            player.currentItem?.step(byCount: delta)
        }
    }

    func markIn() {
        let t = frameStart(at: currentTime)
        inPoint = t
        if let o = outPoint, o <= t { outPoint = nil }
    }

    func markOut() {
        let t = frameEnd(at: currentTime)
        outPoint = min(t, duration > 0 ? duration : t)
        if let i = inPoint, i >= outPoint! { inPoint = nil }
    }

    /// Moves In by whole frames (VoiceOver adjust on the handle); never crosses Out.
    func nudgeIn(_ frames: Int) {
        guard let i = inPoint else { return }
        hasInteracted = true
        let t = frames > 0 ? frameEnd(at: i) : frameStart(at: max(0, i - 1e-4))
        guard t >= 0, t < (outPoint ?? (duration > 0 ? duration : .infinity)) else { return }
        inPoint = t
        seek(to: t, precise: true)
    }

    /// Moves Out by whole frames (Out is the end of the last included frame); never crosses In.
    func nudgeOut(_ frames: Int) {
        guard let o = outPoint else { return }
        hasInteracted = true
        var t = frames > 0 ? frameEnd(at: o) : frameStart(at: max(0, o - 1e-4))
        if duration > 0 { t = min(t, duration) }
        guard t > (inPoint ?? 0) else { return }
        outPoint = t
        seek(to: max(0, t - 0.001), precise: true)
    }

    /// "Reset": back to the whole video.
    func clearRange() {
        inPoint = nil; outPoint = nil; inText = ""; outText = ""
        resetRangeToWhole()
    }

    var rangeIsWhole: Bool {
        guard duration > 0 else { return true }
        return (inPoint ?? 0) <= 0.0005 && abs((outPoint ?? duration) - duration) < 0.0005
    }

    /// Text of the In/Out fields, possibly mid-edit (not yet applied with Return).
    var inText = ""
    var outText = ""

    func syncRangeText() {
        inText = inPoint.map { Timecode.format($0) } ?? ""
        outText = outPoint.map { Timecode.format($0) } ?? ""
    }

    /// Applies typed In/Out text so exports never use a stale range. False when a field doesn't parse.
    @discardableResult
    func commitRangeText() -> Bool {
        let i = inText.isEmpty ? nil : Timecode.parse(inText)
        let o = outText.isEmpty ? nil : Timecode.parse(outText)
        guard inText.isEmpty || i != nil, outText.isEmpty || o != nil else { return false }
        let newIn = i.map { frameStart(at: $0) }
        if newIn != inPoint { inPoint = newIn }
        if o != outPoint { outPoint = o }
        return true
    }

    /// The range the fields describe right now (drafts included), if valid.
    var draftRange: TimeRange? {
        let i = inText.isEmpty ? nil : Timecode.parse(inText).map { frameStart(at: $0) }
        let o = outText.isEmpty ? nil : Timecode.parse(outText)
        guard let i, let o else { return nil }
        let minDur = (frameDuration(at: i) ?? 0.04) * 0.99
        guard RangeValidator.validate(start: i, end: o, duration: duration > 0 ? duration : nil,
                                      minDuration: minDur) == nil else { return nil }
        return TimeRange(start: i, end: o)
    }

    // MARK: Helpers

    static func sourceFPS(info: MediaInfo, quality: QualityChoice) -> Double? {
        switch quality {
        case .best: return info.bestQuality?.fps
        case .option(_, _, let fps, _): return fps
        }
    }

    /// A low-resolution rendition AVPlayer can stream directly (H.264/HEVC MP4 or HLS), preferring muxed audio.
    static func streamCandidate(_ info: MediaInfo) -> (URL, [String: String], String, Bool)? {
        let ok = info.videoVariants.filter { v in
            guard let s = v.url, URL(string: s) != nil else { return false }
            let proto = v.proto ?? "https"
            let codecOK = v.codecFamily == "H.264" || v.codecFamily == "HEVC"
            if proto.hasPrefix("m3u8") { return true }
            return (proto == "https" || proto == "http") && codecOK && (v.ext == "mp4" || v.ext == "mov")
        }
        func score(_ v: VideoVariant) -> Double {
            let h = Double(v.height ?? 360)
            let sizePenalty = h > 720 ? (h - 720) * 2 : (720 - h)
            return (v.hasAudio ? 0 : 5000) + sizePenalty
        }
        guard let best = ok.min(by: { score($0) < score($1) }), let url = URL(string: best.url!) else { return nil }
        let label = "\(best.height.map { "\($0)p" } ?? "Online") preview"
        return (url, best.httpHeaders ?? [:], label, best.hasAudio || (best.proto ?? "").hasPrefix("m3u8"))
    }
}
