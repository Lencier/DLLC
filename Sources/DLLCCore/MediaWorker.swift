import Foundation

/// Real JobWorker: drives the bundled yt-dlp / ffmpeg / ffprobe. Stateless apart from immutable config,
/// so it is safe to share across tasks.
public final class MediaWorker: JobWorker, @unchecked Sendable {
    public let tools: ToolPaths
    public let paths: AppPaths
    public let supervisor: ProcessSupervisor
    public let processingGate: AsyncGate
    public let sources: SourceCache
    /// Use VideoToolbox for compatibility conversions (measured faster on Apple Silicon for long/4K inputs).
    public let hardwareEncoding: Bool

    static let analysisTimeout: TimeInterval = 120
    static let remoteProtocols: Set<String> = ["https", "http", "m3u8", "m3u8_native"]

    public init(tools: ToolPaths, paths: AppPaths, supervisor: ProcessSupervisor = .shared,
                processingLimit: Int = 1, hardwareEncoding: Bool = true) {
        self.tools = tools
        self.paths = paths
        self.supervisor = supervisor
        self.processingGate = AsyncGate(limit: processingLimit)
        self.sources = SourceCache(directory: paths.sourceCache)
        self.hardwareEncoding = hardwareEncoding
    }

    // MARK: Analysis

    public func analyze(url: String, playlistItems: [Int]?, cookies: CookieSource) async throws -> MediaInfo {
        if PinterestPins.isPinterest(url) { return try await analyzePin(url: url, playlistItems: playlistItems, cookies: cookies) }
        guard YouTubeClients.isYouTube(url) else {
            return try await analyzeOnce(url: url, playlistItems: playlistItems, cookies: cookies, client: nil)
        }
        var client: String?
        while true {
            do {
                var info = try await analyzeOnce(url: url, playlistItems: playlistItems, cookies: cookies, client: client)
                info.youtubeClient = client
                // 360p only from the default client is often YouTube holding back: ask another client once.
                if client == nil, YouTubeClients.looksDegraded(info), let alt = YouTubeClients.next(after: nil),
                   var better = try? await analyzeOnce(url: url, playlistItems: playlistItems, cookies: cookies, client: alt),
                   YouTubeClients.maxHeight(better) > YouTubeClients.maxHeight(info) {
                    better.youtubeClient = alt
                    return better
                }
                return info
            } catch let error as JobError where YouTubeClients.shouldSwitch(stderr: error.technical ?? "") {
                guard let next = YouTubeClients.next(after: client) else { throw error }
                client = next
            }
        }
    }

    /// yt-dlp handles video pins; images, carousels and story pages are read directly. A pin without a video
    /// of its own that links elsewhere (Instagram, YouTube, TikTok…) is followed, a few hops at most, until
    /// a video turns up; if none does, the pin's own images are saved.
    func analyzePin(url: String, playlistItems: [Int]?, cookies: CookieSource) async throws -> MediaInfo {
        var current = url, seen: Set<String> = [url]
        var images: MediaInfo?, lastError: Error?
        for _ in 0..<4 {
            do {
                var info = PinterestPins.isPinterest(current)
                    ? try await analyzeOnce(url: current, playlistItems: playlistItems, cookies: cookies, client: nil)
                    : try await analyze(url: current, playlistItems: playlistItems, cookies: cookies)
                if current != url { info.resolvedURL = info.resolvedURL ?? current }
                return info
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
            guard PinterestPins.isPinterest(current), let pin = try? await PinterestPins.fetch(url: current) else { break }
            if pin.directItems?.contains(where: \.isVideo) == true { return pin }
            if images == nil, pin.hasDirectItems { images = pin }
            guard let next = pin.linkedURL, seen.insert(next).inserted else { break }
            current = next
        }
        if let images { return images }
        throw lastError ?? JobError(category: .unsupportedURL, message: "No video was found at this link.", suggestion: nil, isRecoverable: false)
    }

    func analyzeOnce(url: String, playlistItems: [Int]?, cookies: CookieSource, client: String?) async throws -> MediaInfo {
        let args = YTDLPCommand.analyzeArguments(url: url, flatPlaylist: playlistItems == nil,
                                                 playlistItems: playlistItems, tools: tools,
                                                 cookies: cookies, cookiesDirectory: paths.cookiesDirectory,
                                                 youtubeClient: client)
        let result = try await withTimeout(Self.analysisTimeout) {
            try await self.supervisor.run(ProcessSpec(executable: self.tools.ytdlp, arguments: args),
                                          captureStdout: true)
        }
        try Task.checkCancellation()
        guard result.succeeded, !result.stdout.isEmpty else {
            if result.wasCancelled { throw CancellationError() }
            throw ErrorClassifier.classify(stderr: result.stderrTail, exitCode: result.exitCode)
        }
        let info: MediaInfo
        do {
            info = try YTDLPParser.parseInfo(result.stdout, requestedURL: url)
        } catch {
            throw JobError(category: .extractorBroken, message: "DLLC couldn’t understand the site’s response.",
                           suggestion: "Try again, or update yt-dlp in Settings.",
                           technical: Redactor.redact(String(describing: error)))
        }
        if info.isLive {
            throw JobError(category: .liveStream, message: "Live streams can’t be saved while they’re live.",
                           suggestion: "Try again after the stream has ended.", isRecoverable: true)
        }
        if !info.isMultiItem && info.videoVariants.isEmpty && info.audioVariants.isEmpty {
            throw JobError(category: .unsupportedURL, message: "No video or audio was found at this link.",
                           suggestion: "Image-only posts aren’t supported. Try the link of a video post.",
                           isRecoverable: false)
        }
        return info
    }

    // MARK: Execution

    public func execute(job: Job, destination: URL, events: @escaping @Sendable (JobEvent) -> Void) async throws -> JobOutcome {
        try checkDestination(destination)
        // One folder per option set: an interrupted download resumes, but changing quality or format
        // before a retry never picks up files left by the earlier attempt.
        let workspace = paths.jobsWorkspace.appendingPathComponent(job.id.uuidString, isDirectory: true)
            .appendingPathComponent(Self.optionsFingerprint(job.options), isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try checkFreeSpace(job: job, workspace: workspace, destination: destination)

        let produced: [URL]
        var notes: [String] = []
        if let items = job.info?.directItems, !items.isEmpty {
            produced = try await downloadDirect(items, workDir: workspace, events: events)
        } else {
        switch job.options.kind {
        case .video, .audio:
            var files = try await download(job: job, workDir: workspace, events: events)
            if job.options.kind == .video {
                for (i, file) in files.enumerated() {
                    let (converted, note) = try await makeCompatibleIfNeeded(job: job, file: file, events: events)
                    let (finished, more) = try await finishVideo(job: job, file: converted, events: events)
                    files[i] = finished
                    notes += [note].compactMap { $0 } + more
                }
            }
            for file in files { try await validate(job: job, file: file, expectVideo: job.options.kind == .video) }
            produced = files
        case .clip, .gif:
            var (file, extraNotes) = try await renderRange(job: job, workDir: workspace, events: events)
            if job.options.kind == .clip {
                let (finished, more) = try await finishVideo(job: job, file: file, events: events)
                file = finished; extraNotes += more
            }
            notes += extraNotes
            produced = [file]
        }
        }
        try Task.checkCancellation()
        events(.progress(JobProgress(stage: "Saving")))
        var finals: [URL] = []
        let numbered = job.info?.hasDirectItems == true && produced.count > 1
        for (i, file) in produced.enumerated() {
            finals.append(try commit(file: file, job: job, destination: destination, suffix: numbered ? " (\(i + 1))" : nil))
        }
        // Only an untouched best-quality download is a faithful stand-in for the online source.
        if job.options.kind == .video, job.options.quality == .best, job.options.container == .bestQuality,
           job.options.compression == .off, let first = finals.first {
            sources.register(url: job.url, variant: Self.sourceVariant(entries: job.options.selectedEntries, cookies: job.cookies),
                             file: first)
        }
        return JobOutcome(files: finals, notes: notes)
    }

    // MARK: yt-dlp download

    func download(job: Job, workDir: URL, events: @escaping @Sendable (JobEvent) -> Void) async throws -> [URL] {
        if job.options.kind == .audio, let info = job.info, !info.hasAudio {
            throw JobError(category: .missingAudio, message: "This video has no sound, so there’s no audio to save.",
                           suggestion: "Choose Video instead.", isRecoverable: false)
        }
        guard YouTubeClients.isYouTube(job.info?.resolvedURL ?? job.url) else { return try await downloadOnce(job: job, workDir: workDir, client: nil, events: events) }
        var client = job.info?.youtubeClient
        while true {
            do {
                return try await downloadOnce(job: job, workDir: workDir, client: client, events: events)
            } catch let error as JobError where YouTubeClients.shouldSwitch(stderr: error.technical ?? "") {
                guard let next = YouTubeClients.next(after: client) else { throw error }
                client = next
                events(.progress(JobProgress(stage: "YouTube refused — retrying another way")))
            }
        }
    }

    func downloadOnce(job: Job, workDir: URL, client: String?, events: @escaping @Sendable (JobEvent) -> Void) async throws -> [URL] {
        events(.phase(.downloading))
        events(.progress(JobProgress(stage: "Connecting")))
        let args = YTDLPCommand.downloadArguments(url: job.info?.resolvedURL ?? job.url, options: job.options, workDir: workDir, tools: tools,
                                                  cookies: job.cookies, cookiesDirectory: paths.cookiesDirectory,
                                                  youtubeClient: client)
        let tracker = DownloadTracker(info: job.info, kind: job.options.kind)
        let result = try await supervisor.run(ProcessSpec(executable: tools.ytdlp, arguments: args,
                                                          workingDirectory: workDir)) { stream, line in
            if let update = tracker.consume(line) {
                if let phase = update.phase { events(.phase(phase)) }
                events(.progress(update.progress))
            }
        }
        if result.wasCancelled { throw CancellationError() }
        try Task.checkCancellation()
        guard result.succeeded else {
            throw ErrorClassifier.classify(stderr: result.stderrTail, exitCode: result.exitCode)
        }
        let root = workDir.resolvingSymlinksInPath().path + "/"
        var files = tracker.finalPaths.map { URL(fileURLWithPath: $0) }
            .filter { $0.resolvingSymlinksInPath().path.hasPrefix(root) && FileManager.default.fileExists(atPath: $0.path) }
        if files.isEmpty {
            files = Self.mediaFiles(in: workDir)
        }
        guard !files.isEmpty else {
            throw JobError(category: .toolFailure, message: "The download finished but no file was produced.",
                           suggestion: "Try again.", technical: Redactor.redact(result.stderrTail))
        }
        return files
    }

    /// Saves a post's own files (see PinterestPins) one by one; an original that isn't served falls back
    /// to the smaller copy. Files already fetched by an interrupted attempt are kept.
    func downloadDirect(_ items: [DirectItem], workDir: URL, events: @escaping @Sendable (JobEvent) -> Void) async throws -> [URL] {
        events(.phase(.downloading))
        var files: [URL] = []
        for (i, item) in items.enumerated() {
            try Task.checkCancellation()
            events(.progress(JobProgress(stage: "Downloading \(i + 1) of \(items.count)", fraction: Double(i) / Double(items.count))))
            let dest = workDir.appendingPathComponent(String(format: "%02d", i + 1)).appendingPathExtension(item.fileExtension)
            if FileManager.default.fileExists(atPath: dest.path) { files.append(dest); continue }
            var failure: Error?
            for candidate in [item.url, item.fallbackURL].compactMap({ $0 }) {
                guard PinterestPins.isMediaURL(candidate), let url = URL(string: candidate) else { continue }
                do { try await Self.fetchFile(url, to: dest, video: item.isVideo); failure = nil; break }
                catch is CancellationError { throw CancellationError() }
                catch { failure = error }
            }
            if let failure {
                throw JobError(category: .network, message: "A file of this post couldn’t be downloaded.",
                               suggestion: "Check your connection and retry.", technical: Redactor.redact(String(describing: failure)))
            }
            guard FileManager.default.fileExists(atPath: dest.path) else {
                throw JobError(category: .network, message: "A file of this post couldn’t be downloaded.", suggestion: "Retry.")
            }
            files.append(dest)
        }
        events(.progress(JobProgress(stage: "Downloaded", fraction: 1)))
        return files
    }

    static func fetchFile(_ url: URL, to dest: URL, video: Bool) async throws {
        let (tmp, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        // Only the kind of file the post promised is kept.
        let type = (http.mimeType ?? "").lowercased()
        guard type.hasPrefix(video ? "video/" : "image/") else { throw URLError(.cannotDecodeContentData) }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    static func mediaFiles(in dir: URL) -> [URL] {
        let skip: Set<String> = ["part", "ytdl", "json", "tmp", "temp"]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return items.filter { !skip.contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Compatible MP4

    func makeCompatibleIfNeeded(job: Job, file: URL, events: @escaping @Sendable (JobEvent) -> Void) async throws -> (URL, String?) {
        guard job.options.container == .compatibleMP4 else { return (file, nil) }
        let probe = try await probe(file)
        let vcodec = probe.video?.codecName ?? ""
        let acodec = probe.audio?.codecName
        let videoOK = vcodec == "h264"
        let audioOK = acodec == nil || acodec == "aac"
        if videoOK && audioOK && file.pathExtension.lowercased() == "mp4" { return (file, nil) }
        events(.phase(.processing))
        events(.progress(JobProgress(stage: "Waiting for converter")))
        let output = file.deletingPathExtension().appendingPathExtension("compatible.mp4")
        try? FileManager.default.removeItem(at: output)
        let args = FFmpegCommand.compatibleMP4(input: file, output: output, reencodeVideo: !videoOK,
                                               reencodeAudio: !audioOK, hardware: hardwareEncoding,
                                               sourceBitrate: probe.video?.bitRate ?? probe.bitRate,
                                               hdrTransfer: probe.hdrTransfer)
        let stage = videoOK ? "Converting audio" : "Converting to H.264"
        try await processingGate.withPermit {
            try await self.runFFmpeg(args, duration: probe.duration, stage: stage, events: events)
        }
        try? FileManager.default.removeItem(at: file)
        var note: String?
        if !videoOK {
            note = "Converted \(CodecNames.video(vcodec)) to H.264 for compatibility (re-encoded; slight quality loss)."
            if probe.isHDR { note! += " HDR was tone-mapped to SDR." }
        } else if !audioOK {
            note = "Converted audio to AAC for compatibility."
        }
        return (output, note)
    }

    // MARK: File type and compression

    /// Brings a finished video or clip to the chosen file type, compressing it when asked.
    func finishVideo(job: Job, file: URL, events: @escaping @Sendable (JobEvent) -> Void) async throws -> (URL, [String]) {
        let want = job.options.fileType.rawValue
        let level = job.options.compression
        if level == .off && file.pathExtension.lowercased() == want { return (file, []) }
        let probe = try await probe(file)
        let vcodec = probe.video?.codecName ?? ""
        let acodec = probe.audio?.codecName
        let output = file.deletingPathExtension().appendingPathExtension("final").appendingPathExtension(want)
        try? FileManager.default.removeItem(at: output)
        let args: [String], stage: String
        var notes: [String] = []
        if level != .off {
            args = FFmpegCommand.compress(input: file, output: output, level: level,
                                          h264: job.options.container == .compatibleMP4, hdrTransfer: probe.hdrTransfer)
            stage = "Compressing"
        } else if job.options.fileType == .mov && !Self.fitsMOV(video: vcodec, audio: acodec) {
            // MOV can't hold VP9/AV1/Opus: convert what doesn't fit (as Compatible MP4 does).
            let videoOK = vcodec == "h264" || vcodec == "hevc"
            args = FFmpegCommand.compatibleMP4(input: file, output: output, reencodeVideo: !videoOK,
                                               reencodeAudio: !(acodec == nil || acodec == "aac" || acodec == "mp3"),
                                               hardware: hardwareEncoding, sourceBitrate: probe.video?.bitRate ?? probe.bitRate,
                                               hdrTransfer: probe.hdrTransfer)
            stage = "Converting to MOV"
            if !videoOK { notes.append("Converted \(CodecNames.video(vcodec)) to H.264 to save as MOV (re-encoded).") }
        } else {
            args = FFmpegCommand.remux(input: file, output: output)
            stage = "Saving as \(job.options.fileType.label)"
        }
        events(.phase(.processing))
        events(.progress(JobProgress(stage: "Waiting for converter")))
        let before = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        try await processingGate.withPermit {
            try await self.runFFmpeg(args, duration: probe.duration, stage: stage, events: events)
        }
        if level != .off, let before, let after = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value {
            if after >= before {
                // Already small: keep the original rather than a bigger or equal "compressed" copy.
                try? FileManager.default.removeItem(at: output)
                notes.append("Already compact — kept the original encoding.")
                if file.pathExtension.lowercased() == want { return (file, notes) }
                var plain = job; plain.options.compression = .off
                let (remuxed, more) = try await finishVideo(job: plain, file: file, events: events)
                return (remuxed, notes + more)
            }
            notes.append("Compressed \(ByteFormat.string(before)) → \(ByteFormat.string(after)).")
        }
        try? FileManager.default.removeItem(at: file)
        return (output, notes)
    }

    static func fitsMOV(video: String, audio: String?) -> Bool {
        ["h264", "hevc", "prores", "mjpeg"].contains(video) && (audio == nil || ["aac", "mp3", "alac", "pcm_s16le", "pcm_s24le"].contains(audio!))
    }

    // MARK: Clip / GIF

    func renderRange(job: Job, workDir: URL, events: @escaping @Sendable (JobEvent) -> Void) async throws -> (URL, [String]) {
        guard let range = job.options.range,
              // Sites report whole-second durations; the real stream can run up to a second longer.
              RangeValidator.validate(start: range.start, end: range.end, duration: job.info?.duration.map { $0 + 1 },
                                      minDuration: 0.04) == nil else {
            throw JobError(category: .processingFailed, message: "The selected range isn’t valid.",
                           suggestion: "Open the preview and set In and Out again.", isRecoverable: true)
        }
        var notes: [String] = []
        let (video, audio, sourceWidth, isLocal, hdrTransfer) = try await resolveInputs(job: job, events: events)
        if !isLocal { notes.append("Rendered from the online source stream (only the selected range was downloaded).") }
        let isGIF = job.options.kind == .gif
        let fast = !isGIF && job.options.cutMode == .fast
        let ext: String
        if isGIF { ext = "gif" } else if fast { ext = Self.fastClipExtension(video: video, job: job) } else { ext = "mp4" }
        let output = workDir.appendingPathComponent("render-\(UUID().uuidString.prefix(8)).\(ext)")
        let includeAudio = (job.info?.hasAudio ?? true)
        let args: [String]
        if isGIF {
            args = FFmpegCommand.gif(input: video, range: range, options: job.options.gif,
                                     sourceWidth: sourceWidth, hdrTransfer: hdrTransfer,
                                     compression: job.options.compression, output: output)
        } else if fast {
            args = FFmpegCommand.fastClip(video: video, audio: audio, range: range, includeAudio: includeAudio, output: output)
            notes.append("Fast cut: start and end may shift to the nearest keyframes.")
        } else {
            args = FFmpegCommand.preciseClip(video: video, audio: audio, range: range, includeAudio: includeAudio,
                                             output: output, preserveHDR: false, hdrTransfer: hdrTransfer)
            if hdrTransfer != nil { notes.append("HDR source was tone-mapped to SDR.") }
        }
        let stage = isGIF ? "Making GIF" : (fast ? "Cutting clip" : "Encoding clip")
        events(.phase(.processing))
        events(.progress(JobProgress(stage: fast ? "Waiting" : "Waiting for encoder")))
        let work: @Sendable () async throws -> Void = {
            try await self.runFFmpeg(args, duration: range.duration, stage: stage, events: events)
        }
        try await retryingFreshLinkDenial(remote: !isLocal, partial: output) {
            if fast { try await work() } else { try await self.processingGate.withPermit(work) }
        }
        let probe = try await probe(output)
        guard probe.video != nil else {
            throw JobError(category: .processingFailed, message: "The exported file has no picture.",
                           suggestion: "Try Precise mode or another range.", isRecoverable: true)
        }
        if !isGIF, includeAudio, probe.audio == nil {
            throw JobError(category: .missingAudio, message: "The clip came out without sound although the source has audio.",
                           suggestion: "Try again, or use Precise mode.", isRecoverable: true)
        }
        return (output, notes)
    }

    static func fastClipExtension(video: MediaInput, job: Job) -> String {
        // Stream copy keeps codecs; MKV accepts every codec combination, MP4 only H.264/HEVC + AAC.
        let codec = job.info?.videoVariants.first?.codecFamily ?? ""
        return (codec == "H.264" || codec == "HEVC") ? "mp4" : "mkv"
    }

    /// Local cached source when available (exact frames), otherwise the remote streams of the chosen quality.
    /// (video, audio, source width, is local, HDR transfer when the source is HDR)
    func resolveInputs(job: Job, events: @escaping @Sendable (JobEvent) -> Void) async throws
        -> (MediaInput, MediaInput?, Int?, Bool, String?) {
        if let local = sources.lookup(url: job.url, variant: Self.sourceVariant(entries: job.options.selectedEntries,
                                                                                  cookies: job.cookies, quality: job.options.quality)) {
            let probe = try? await probe(local)
            return (MediaInput(url: local.path), nil, probe?.video?.width, true, probe?.hdrTransfer)
        }
        events(.progress(JobProgress(stage: "Refreshing stream links")))
        var info = job.info
        if info == nil || Date().timeIntervalSince(info!.analyzedAt) > 15 * 60 {
            info = try await analyze(url: job.url, playlistItems: job.options.selectedEntries, cookies: job.cookies)
        }
        guard let info else { throw CancellationError() }
        let quality = Self.rebind(job.options.quality, to: info)
        let variant = Self.pickVideoVariant(info: info, quality: quality)
        if let variant, let url = variant.url, Self.remoteProtocols.contains(variant.proto ?? "https") {
            let videoInput = MediaInput(url: url, headers: variant.httpHeaders ?? [:])
            var audioInput: MediaInput?
            if !variant.hasAudio, let audio = info.bestAudio, let aurl = audio.url,
               Self.remoteProtocols.contains(audio.proto ?? "https") {
                audioInput = MediaInput(url: aurl, headers: audio.httpHeaders ?? [:])
            }
            let range = (variant.dynamicRange ?? "SDR").uppercased()
            let transfer: String? = range == "SDR" ? nil : (range.contains("HLG") ? "arib-std-b67" : "smpte2084")
            return (videoInput, audioInput, variant.width, false, transfer)
        }
        // Fragmented streams can't be range-read directly: fetch the full source once (cached for reuse).
        let local = try await fetchSource(url: job.url, info: info, quality: quality,
                                          cookies: job.cookies, entries: job.options.selectedEntries, events: events)
        let probe = try? await probe(local)
        return (MediaInput(url: local.path), nil, probe?.video?.width, true, probe?.hdrTransfer)
    }

    /// A quality chosen from an older analysis, re-bound to this analysis's format IDs (they can change).
    static func rebind(_ quality: QualityChoice, to info: MediaInfo) -> QualityChoice {
        guard case .option(let id, _, _, _) = quality else { return quality }
        guard let fresh = info.qualityOptions.first(where: { $0.id == id }) else { return .best }
        return .option(id: fresh.id, height: fresh.height, fps: fresh.fps, formatIDs: fresh.formatIDs)
    }

    static func pickVideoVariant(info: MediaInfo, quality: QualityChoice) -> VideoVariant? {
        let byID = Dictionary(info.videoVariants.map { ($0.formatID, $0) }, uniquingKeysWith: { a, _ in a })
        let ids: [String]
        switch quality {
        case .best: ids = info.bestQuality?.formatIDs ?? []
        case .option(_, _, _, let formatIDs): ids = formatIDs
        }
        // Prefer a directly readable rendition within the chosen combination.
        let candidates = ids.compactMap { byID[$0] }
        return candidates.first { $0.url != nil && remoteProtocols.contains($0.proto ?? "https") } ?? candidates.first
    }

    /// Downloads the full source at the chosen quality into the source cache (reused by preview, frames, exports).
    public func fetchSource(url: String, info: MediaInfo?, quality: QualityChoice, cookies: CookieSource,
                            entries: [Int]?, events: @escaping @Sendable (JobEvent) -> Void) async throws -> URL {
        let variant = Self.sourceVariant(entries: entries, cookies: cookies, quality: quality)
        if let cached = sources.lookup(url: url, variant: variant) { return cached }
        // A full source can be large: refuse up front rather than filling the disk.
        if let free = Self.freeBytes(at: paths.caches) {
            let estimate = info.flatMap { i -> Int64? in
                switch quality {
                case .best: return i.bestQuality?.estimatedBytes
                case .option(let id, _, _, _): return i.qualityOptions.first { $0.id == id }?.estimatedBytes
                }
            } ?? 0
            if free < min(estimate, Int64(1e15) / 2) * 13 / 10 + 500 * 1_048_576 {
                throw JobError(category: .diskFull,
                               message: "Not enough free space to load the source (\(ByteFormat.string(free)) available).",
                               suggestion: "Free up some space, or export without loading the source.")
            }
        }
        let dir = paths.sourceCache.appendingPathComponent("tmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var opts = OutputOptions()
        opts.kind = .video
        opts.quality = quality
        opts.container = .bestQuality
        opts.selectedEntries = entries
        var job = Job(url: url, options: opts, cookies: cookies)
        job.info = info
        let files = try await download(job: job, workDir: dir, events: events)
        guard let file = files.first else { throw CancellationError() }
        return try sources.store(url: url, variant: variant, file: file)
    }

    // MARK: Snapshot

    /// Saves the frame whose presentation interval contains `time`, from the best available source.
    public func snapshot(job: Job, time: Double, frameDuration: Double?, format: ImageFormat,
                         destination: URL) async throws -> URL {
        try checkDestination(destination)
        let input: MediaInput
        var origin = 0.0
        var hdrTransfer: String?
        if let local = sources.lookup(url: job.url, variant: Self.sourceVariant(entries: job.options.selectedEntries, cookies: job.cookies)) {
            input = MediaInput(url: local.path)
            let p = try? await probe(local)
            origin = p?.startTime ?? 0
            hdrTransfer = p?.hdrTransfer
        } else {
            var info = job.info
            if info == nil || Date().timeIntervalSince(info!.analyzedAt) > 15 * 60 {
                info = try await analyze(url: job.url, playlistItems: job.options.selectedEntries, cookies: job.cookies)
            }
            guard let info, let v = Self.pickVideoVariant(info: info, quality: .best), let url = v.url,
                  Self.remoteProtocols.contains(v.proto ?? "https") else {
                throw JobError(category: .formatUnavailable, message: "This source can’t be read frame-by-frame online.",
                               suggestion: "Click “Load Source” in the preview first.")
            }
            input = MediaInput(url: url, headers: v.httpHeaders ?? [:])
            let range = (v.dynamicRange ?? "SDR").uppercased()
            if range != "SDR" { hdrTransfer = range.contains("HLG") ? "arib-std-b67" : "smpte2084" }
            // HLS/TS streams can start at a non-zero PTS; the player timeline starts at zero.
            let spec = ProcessSpec(executable: tools.ffprobe, arguments: FFmpegCommand.startTimeProbe(input: input))
            if let r = try? await supervisor.run(spec, captureStdout: true), r.succeeded,
               let t = Double(String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
               t.isFinite, t >= 0 { origin = t }
        }
        let tmp = paths.caches.appendingPathComponent("snap-\(UUID().uuidString).\(format.rawValue)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let args = FFmpegCommand.snapshot(input: input, at: time, frameDuration: frameDuration, format: format,
                                          origin: origin, hdrTransfer: hdrTransfer, output: tmp)
        try await retryingFreshLinkDenial(remote: input.isRemote, partial: tmp) {
            let result = try await self.supervisor.run(ProcessSpec(executable: self.tools.ffmpeg, arguments: args))
            if result.wasCancelled { throw CancellationError() }
            guard result.succeeded, FileManager.default.fileExists(atPath: tmp.path) else {
                throw ErrorClassifier.classify(stderr: result.stderrTail, exitCode: result.exitCode)
            }
        }
        let base = FileNaming.sanitize("\(job.displayTitle) — \(FileNaming.timeTag(time))")
        let final = FileNaming.uniqueURL(in: destination, baseName: base, ext: format.rawValue)
        try moveFile(tmp, to: final)
        return final
    }

    // MARK: Helpers

    /// Freshly extracted YouTube stream links answer 403 for the first few seconds, then work.
    /// Wait briefly and retry instead of failing the job; a persistent 403 still surfaces.
    func retryingFreshLinkDenial(remote: Bool, partial: URL, _ body: () async throws -> Void) async throws {
        var attempt = 0
        while true {
            do { return try await body() } catch let error as JobError
                where remote && attempt < 3 && (error.technical ?? "").contains("403") {
                attempt += 1
                try? FileManager.default.removeItem(at: partial)
                try await Task.sleep(for: .seconds(2 * attempt))
            }
        }
    }

    func runFFmpeg(_ args: [String], duration: Double?, stage: String,
                   events: @escaping @Sendable (JobEvent) -> Void) async throws {
        events(.progress(JobProgress(stage: stage)))
        let result = try await supervisor.run(ProcessSpec(executable: tools.ffmpeg, arguments: args)) { stream, line in
            guard stream == .stdout, let t = FFmpegProgressParser.outTimeSeconds(line) else { return }
            if let duration, duration > 0 {
                let fraction = min(0.99, max(0, t / duration))
                events(.progress(JobProgress(stage: stage, fraction: fraction,
                                             detail: "\(Timecode.format(t)) of \(Timecode.format(duration))")))
            }
        }
        if result.wasCancelled { throw CancellationError() }
        try Task.checkCancellation()
        guard result.succeeded else {
            var err = ErrorClassifier.classify(stderr: result.stderrTail, exitCode: result.exitCode)
            if err.category == .unknown {
                err = JobError(category: .processingFailed, message: "Processing failed.",
                               suggestion: "Try again, or choose a different output.", technical: err.technical)
            }
            throw err
        }
    }

    public func probe(_ file: URL) async throws -> ProbeResult {
        let result = try await supervisor.run(ProcessSpec(executable: tools.ffprobe,
                                                          arguments: FFprobe.probeArguments(file: file)),
                                              captureStdout: true)
        if result.wasCancelled { throw CancellationError() }
        guard result.succeeded, let probe = try? FFprobe.parseProbe(result.stdout) else {
            throw JobError(category: .processingFailed, message: "The file couldn’t be read after downloading.",
                           suggestion: "Try again.", technical: Redactor.redact(result.stderrTail))
        }
        return probe
    }

    func validate(job: Job, file: URL, expectVideo: Bool) async throws {
        let p = try await probe(file)
        if expectVideo && p.video == nil {
            throw JobError(category: .processingFailed, message: "The downloaded file has no video track.",
                           suggestion: "Try another quality.", isRecoverable: true)
        }
        if job.options.kind == .audio && p.audio == nil {
            throw JobError(category: .missingAudio, message: "The downloaded file has no audio.",
                           suggestion: "Try Original audio, or another source.", isRecoverable: true)
        }
        if expectVideo, let info = job.info, info.hasAudio, p.audio == nil {
            // Source exposes audio but the result has none: don't claim success.
            let chosenMuted = Self.chosenOptionIsSilent(info: info, quality: job.options.quality)
            if !chosenMuted {
                throw JobError(category: .missingAudio, message: "The video was saved without sound, although the source has audio.",
                               suggestion: "Retry, or pick another quality.", isRecoverable: true)
            }
        }
    }

    static func chosenOptionIsSilent(info: MediaInfo, quality: QualityChoice) -> Bool {
        info.audioVariants.isEmpty && !info.videoVariants.contains { $0.hasAudio }
    }

    func commit(file: URL, job: Job, destination: URL, suffix: String? = nil) throws -> URL {
        var base = job.displayTitle + (suffix ?? "")
        if let entries = job.options.selectedEntries, entries.count == 1 { base += " (\(entries[0]))" }
        if let range = job.options.range, job.options.kind == .clip || job.options.kind == .gif {
            base += " — " + FileNaming.rangeTag(range)
        }
        let ext = file.pathExtension.replacingOccurrences(of: "compatible.", with: "")
        // Only media is ever saved: anything else a site serves (an app, a script, an archive) is dropped.
        guard FileSafety.mediaExtensions.contains(ext.lowercased()) else {
            try? FileManager.default.removeItem(at: file)
            throw JobError(category: .unsupportedURL, message: "This link gave a file that isn’t video or audio, so DLLC didn’t save it.",
                           suggestion: "Check the link. DLLC only saves video, audio, images and subtitles.", isRecoverable: false)
        }
        // Another job may claim the same free name between the check and the move: pick the next one.
        for _ in 0..<50 {
            let final = FileNaming.uniqueURL(in: destination, baseName: FileNaming.sanitize(base),
                                             ext: ext.isEmpty ? "bin" : ext)
            do {
                try moveFile(file, to: final)
                FileSafety.quarantine(final)
                return final
            } catch where FileManager.default.fileExists(atPath: final.path) && FileManager.default.fileExists(atPath: file.path) {
                continue
            }
        }
        throw JobError(category: .destinationUnavailable, message: "The file couldn’t be named in the save folder.",
                       suggestion: "Retry, or choose another folder.")
    }

    /// Cache variant for a link's local source (see SourceCache.key).
    public static func sourceVariant(entries: [Int]?, cookies: CookieSource, quality: QualityChoice = .best) -> String? {
        var parts: [String] = []
        if case .option(let id, _, _, _) = quality { parts.append("q=" + id) }
        if let entries, !entries.isEmpty { parts.append("items=" + entries.map(String.init).joined(separator: ",")) }
        // Each browser/profile or cookie file gets its own copy: content seen through one login is never
        // handed to another.
        switch cookies {
        case .none: break
        case .browser(let name, let profile): parts.append("login=" + name + (profile.map { ":" + $0 } ?? ""))
        case .file(let name): parts.append("login=file:" + name)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "&")
    }

    static func optionsFingerprint(_ options: OutputOptions) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(options)) ?? Data()
        let hash = data.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return "o" + String(hash, radix: 16)
    }

    func moveFile(_ from: URL, to: URL) throws {
        do {
            try FileManager.default.moveItem(at: from, to: to)
        } catch let error as NSError {
            let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? error.code
            if posix == Int(ENOSPC) || error.code == NSFileWriteOutOfSpaceError {
                throw JobError(category: .diskFull, message: "There isn’t enough space to save this file.",
                               suggestion: "Free up space or choose another folder, then retry.")
            }
            if error.code == NSFileWriteNoPermissionError || posix == Int(EACCES) || posix == Int(EPERM) {
                throw JobError(category: .permissionDenied, message: "DLLC can’t write to the save folder.",
                               suggestion: "Choose another folder in Settings, or check its permissions.")
            }
            throw JobError(category: .destinationUnavailable, message: "The file couldn’t be moved to the save folder.",
                           suggestion: "Check that the folder is available, then retry.",
                           technical: Redactor.redact(error.localizedDescription))
        }
    }

    func checkDestination(_ destination: URL) throws {
        var isDir: ObjCBool = false
        // A project subfolder is created on first use — but only one level deep, inside a folder that
        // exists, so an unplugged drive's path never gets silently recreated on the startup disk.
        var parentIsDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: destination.path),
           FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path, isDirectory: &parentIsDir),
           parentIsDir.boolValue {
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        }
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue else {
            throw JobError(category: .destinationUnavailable,
                           message: "The save folder is unavailable.",
                           suggestion: "Reconnect the drive or choose another folder, then retry.")
        }
        guard FileManager.default.isWritableFile(atPath: destination.path) else {
            throw JobError(category: .permissionDenied, message: "DLLC can’t write to the save folder.",
                           suggestion: "Choose another folder, then retry.")
        }
    }

    func checkFreeSpace(job: Job, workspace: URL, destination: URL) throws {
        let estimate = Self.estimatedBytes(job: job)
        let margin: Int64 = 200 * 1_024 * 1_024
        for dir in [workspace, destination] {
            guard let free = Self.freeBytes(at: dir) else { continue }
            // Clamped: absurd metadata must not overflow the conversion.
            let needed = (estimate.map { Int64(min(Double($0) * (job.options.container == .compatibleMP4 ? 2.2 : 1.3), 1e15)) } ?? 0) + margin
            if free < needed {
                throw JobError(category: .diskFull,
                               message: "There isn’t enough free space (\(ByteFormat.string(free)) available).",
                               suggestion: "Free up space or choose another folder, then retry.")
            }
        }
    }

    static func estimatedBytes(job: Job) -> Int64? {
        guard let info = job.info, job.options.kind == .video || job.options.kind == .audio else { return nil }
        if job.options.kind == .audio { return info.bestAudio?.filesize }
        switch job.options.quality {
        case .best: return info.bestQuality?.estimatedBytes
        case .option(let id, _, _, _): return info.qualityOptions.first { $0.id == id }?.estimatedBytes
        }
    }

    public static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                       .volumeAvailableCapacityKey])
        if let v = values?.volumeAvailableCapacityForImportantUsage, v > 0 { return v }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            while let next = try await group.next() {
                if let value = next { return value }
                throw JobError(category: .network, message: "The site took too long to respond.",
                               suggestion: "Check your connection and retry.")
            }
            throw CancellationError()
        }
    }
}

// MARK: - Download progress tracking

/// Turns raw yt-dlp output lines into stage-aware progress. Thread-safe (called from pipe readers).
final class DownloadTracker: @unchecked Sendable {
    struct Update { var phase: JobState?; var progress: JobProgress }

    private let lock = NSLock()
    private let audioIDs: Set<String>
    private let kind: JobKind
    private var currentLabel = "Downloading"
    private var paths: [String] = []
    private var partIndex = 0

    init(info: MediaInfo?, kind: JobKind) {
        self.audioIDs = Set(info?.audioVariants.map(\.formatID) ?? [])
        self.kind = kind
    }

    var finalPaths: [String] { lock.withLock { paths } }

    func consume(_ line: String) -> Update? {
        lock.withLock {
            if let path = YTDLPOutput.parseFinalPath(line) {
                paths.append(path)
                return nil
            }
            if line.hasPrefix("[download] Destination:") {
                partIndex += 1
                let name = String(line.dropFirst("[download] Destination:".count))
                if let id = Self.formatID(inFilename: name), audioIDs.contains(id) {
                    currentLabel = kind == .audio ? "Downloading audio" : "Downloading audio track"
                } else {
                    currentLabel = kind == .audio ? "Downloading audio" : (partIndex > 1 ? "Downloading next part" : "Downloading video")
                }
                return Update(phase: nil, progress: JobProgress(stage: currentLabel))
            }
            if let p = YTDLPOutput.parseProgress(line) {
                if p.status == "finished" { return nil }
                return Update(phase: nil, progress: JobProgress(stage: currentLabel, fraction: p.fraction,
                                                                detail: Self.detail(p)))
            }
            if let stage = YTDLPOutput.stage(for: line) {
                return Update(phase: .processing, progress: JobProgress(stage: stage))
            }
            return nil
        }
    }

    static func formatID(inFilename name: String) -> String? {
        // yt-dlp names intermediate streams "<title> [id].f<format_id>.<ext>"
        guard let r = name.range(of: #"\.f([A-Za-z0-9_-]+)\.[A-Za-z0-9]+$"#, options: .regularExpression) else { return nil }
        let token = name[r].dropFirst(2)
        return token.split(separator: ".").first.map(String.init)
    }

    static func detail(_ p: DownloadProgressEvent) -> String? {
        var parts: [String] = []
        if let done = p.downloadedBytes {
            if let total = p.totalBytes, total > 0 {
                parts.append("\(ByteFormat.string(done)) of \(p.totalIsEstimate ? "~" : "")\(ByteFormat.string(total))")
            } else {
                parts.append(ByteFormat.string(done))
            }
        } else if let i = p.fragmentIndex, let n = p.fragmentCount {
            parts.append("Part \(i) of \(n)")
        }
        if let s = p.speed, s > 0 { parts.append("\(ByteFormat.string(Int64(s)))/s") }
        if let eta = p.eta, eta > 0, eta < 86_400 { parts.append("\(Timecode.format(eta).split(separator: ".").first ?? "") left") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
