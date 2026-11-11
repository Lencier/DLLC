import Foundation
import Testing
@testable import DLLCCore

@MainActor
@Suite struct ProjectTests {
    let dest = URL(fileURLWithPath: NSTemporaryDirectory())

    @Test func addedJobsCarryProjectAndDestination() async {
        let e = QueueEngine(worker: FakeWorker(), store: nil, defaultDestination: dest)
        let project = Project(name: "Trip")
        let folder = dest.appendingPathComponent(project.folderName)
        let r = e.add(urls: ["https://a.com/1"], options: OutputOptions(), destination: folder, projectID: project.id)
        await settle()
        let job = try! #require(e.job(r.added[0]))
        #expect(job.projectID == project.id)
        #expect(job.destinationPath == folder.path)
    }

    @Test func derivedClipsAndSplitItemsStayInTheProject() async {
        let w = FakeWorker()
        w.analysisResult = { url in
            .success(FakeWorker.info(url, entries: [
                MediaEntry(id: "a", index: 1, title: "A", url: nil, thumbnail: nil, duration: 3, isVideo: true),
                MediaEntry(id: "b", index: 2, title: "B", url: nil, thumbnail: nil, duration: 3, isVideo: true),
            ]))
        }
        let e = QueueEngine(worker: w, store: nil, defaultDestination: dest)
        let pid = UUID()
        let r = e.add(urls: ["https://a.com/post"], options: OutputOptions(), projectID: pid)
        await settle()
        e.resolveSelection(r.added[0], entries: [1, 2])
        #expect(e.jobs.count == 2)
        #expect(e.jobs.allSatisfy { $0.projectID == pid })

        var clip = OutputOptions(); clip.kind = .clip; clip.range = TimeRange(start: 0, end: 1)
        let derived = e.addDerived(from: e.jobs[0], options: clip, startNow: false)
        #expect(e.job(derived)?.projectID == pid)
    }

    @Test func assignMovesUnstartedJobsButNotFinishedOnes() async {
        let w = FakeWorker(); w.autoExecute = true
        let e = QueueEngine(worker: w, store: nil, defaultDestination: dest)
        let r = e.add(urls: ["https://a.com/1", "https://a.com/2"], options: OutputOptions())
        await settle()
        e.start(r.added[0])
        await settle()
        #expect(e.job(r.added[0])?.state == .completed)
        let savedTo = e.job(r.added[0])?.destinationPath
        let pid = UUID()
        let folder = dest.appendingPathComponent("P")
        e.assign(r.added, toProject: pid, destination: folder)
        #expect(e.jobs.allSatisfy { $0.projectID == pid })
        #expect(e.job(r.added[0])?.destinationPath == savedTo)        // already saved: unchanged
        #expect(e.job(r.added[1])?.destinationPath == folder.path)    // not started: follows the project
    }

    @Test func projectSurvivesRestoreAndOldQueuesStillLoad() async throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let e = QueueEngine(worker: FakeWorker(), store: JobStore(url: file, debounce: 0), defaultDestination: dest)
        let pid = UUID()
        e.add(urls: ["https://a.com/1"], options: OutputOptions(), projectID: pid)
        await settle()
        let e2 = QueueEngine(worker: FakeWorker(), store: JobStore(url: file, debounce: 0), defaultDestination: dest)
        e2.restore()
        #expect(e2.jobs.first?.projectID == pid)

        // A queue saved before projects existed has no "projectID" key at all.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var jobs = json["jobs"] as! [[String: Any]]
        jobs[0].removeValue(forKey: "projectID")
        json["jobs"] = jobs
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let e3 = QueueEngine(worker: FakeWorker(), store: JobStore(url: file, debounce: 0), defaultDestination: dest)
        e3.restore()
        #expect(e3.jobs.count == 1)
        #expect(e3.jobs.first?.projectID == nil)
    }

    @Test func folderNamesAreSafe() {
        #expect(Project(name: "Trip / 2026").folderName == "Trip - 2026")
        #expect(Project(name: "../etc").folderName == "-etc")
        #expect(Project(name: "   ").folderName == "Project")
        #expect(Project(name: "งานลูกค้า: A").folderName == "งานลูกค้า- A")
        #expect(Project(name: String(repeating: "x", count: 200)).folderName.count == 80)
        #expect(Project(name: String(repeating: "🎬", count: 80)).folderName.utf8.count <= 200)
    }
}

@Suite struct ProjectFolderTests {
    @Test func projectFolderIsCreatedOnlyInsideAnExistingFolder() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dllc-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let tools = ToolPaths(ytdlp: URL(fileURLWithPath: "/t/y"), ffmpeg: URL(fileURLWithPath: "/t/f"),
                              ffprobe: URL(fileURLWithPath: "/t/p"), deno: URL(fileURLWithPath: "/t/d"))
        let worker = MediaWorker(tools: tools, paths: AppPaths(applicationSupport: base, caches: base),
                                 processingLimit: 1, hardwareEncoding: false)
        let project = base.appendingPathComponent("Music Videos")
        try worker.checkDestination(project)
        #expect(FileManager.default.fileExists(atPath: project.path))
        // Missing parent (e.g. an unplugged drive): not recreated, reported as unavailable.
        let gone = base.appendingPathComponent("Unplugged/Project")
        #expect(throws: JobError.self) { try worker.checkDestination(gone) }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Unplugged").path))
    }
}

@Suite struct PlaylistLinkTests {
    @Test func watchLinksInsideAPlaylistMeanTheVideo() {
        #expect(LinkExtractor.isYouTubeWatchInPlaylist("https://www.youtube.com/watch?v=abc&list=RDabc&start_radio=1"))
        #expect(LinkExtractor.isYouTubeWatchInPlaylist("https://m.youtube.com/watch?v=abc&list=PL123&index=3"))
        #expect(LinkExtractor.isYouTubeWatchInPlaylist("https://youtu.be/abc?list=PL123"))
        #expect(!LinkExtractor.isYouTubeWatchInPlaylist("https://www.youtube.com/watch?v=abc"))
        #expect(!LinkExtractor.isYouTubeWatchInPlaylist("https://www.youtube.com/playlist?list=PL123"))
        #expect(!LinkExtractor.isYouTubeWatchInPlaylist("https://www.instagram.com/p/xyz/?list=1"))
    }

    @Test func analysisOfAMixLinkAsksForOneVideo() {
        let tools = ToolPaths(ytdlp: URL(fileURLWithPath: "/t/yt-dlp"), ffmpeg: URL(fileURLWithPath: "/t/ffmpeg"),
                              ffprobe: URL(fileURLWithPath: "/t/ffprobe"), deno: URL(fileURLWithPath: "/t/deno"))
        let mix = YTDLPCommand.analyzeArguments(url: "https://www.youtube.com/watch?v=abc&list=RDabc", flatPlaylist: true,
                                                playlistItems: nil, tools: tools, cookies: .none, cookiesDirectory: nil)
        #expect(mix.contains("--no-playlist"))
        #expect(mix.last == "https://www.youtube.com/watch?v=abc&list=RDabc")
        let playlist = YTDLPCommand.analyzeArguments(url: "https://www.youtube.com/playlist?list=PL1", flatPlaylist: true,
                                                     playlistItems: nil, tools: tools, cookies: .none, cookiesDirectory: nil)
        #expect(!playlist.contains("--no-playlist"))
    }
}

@Suite struct FrameTimecodeTests {
    @Test func countsFramesWithinTheSecond() {
        #expect(Timecode.frames(308.79, fps: 24) == ("05:08", "18"))
        #expect(Timecode.frames(0, fps: 30) == ("00:00", "00"))
        #expect(Timecode.frames(3725.5, fps: 60) == ("1:02:05", "30"))
    }
    @Test func neverShowsAFrameNumberPastTheRate() {
        #expect(Timecode.frames(1.9999, fps: 29.97).frame == "29")
        #expect(Timecode.frames(2.0 - 1e-9, fps: 24).frame == "23")
    }
}

@Suite struct FileTypeAndCompressionTests {
    @Test func oldSavedOptionsDefaultToMP4WithoutCompression() throws {
        let data = try JSONEncoder().encode(OutputOptions())
        var dict = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "fileTypeSetting"); dict.removeValue(forKey: "compressionSetting")
        let old = try JSONDecoder().decode(OutputOptions.self, from: JSONSerialization.data(withJSONObject: dict))
        #expect(old.fileType == .mp4 && old.compression == .off)
    }
    @Test func mergesIntoTheChosenType() {
        var o = OutputOptions(); o.fileType = .mkv
        let args = YTDLPCommand.downloadArguments(url: "https://a.com/v", options: o, workDir: URL(fileURLWithPath: "/tmp"),
                                                  tools: ToolPaths(ytdlp: URL(fileURLWithPath: "/y"), ffmpeg: URL(fileURLWithPath: "/f"),
                                                                   ffprobe: URL(fileURLWithPath: "/p"), deno: URL(fileURLWithPath: "/d")),
                                                  cookies: .none, cookiesDirectory: nil)
        let i = try! #require(args.firstIndex(of: "--merge-output-format"))
        #expect(args[i + 1] == "mkv")
    }
    @Test func compressionCapsHeightAndUsesHardwareHEVC() {
        let a = FFmpegCommand.compress(input: URL(fileURLWithPath: "/in.mp4"), output: URL(fileURLWithPath: "/o.mov"),
                                       level: .smallest, h264: false)
        #expect(a.contains("hevc_videotoolbox") && a.contains("hvc1"))
        #expect(a.contains { $0.contains("min(720,ih)") })
        #expect(a.last == "/o.mov")
    }
    @Test func smallerGIFsUseFewerColours() {
        let a = FFmpegCommand.gif(input: MediaInput(url: "/in.mp4"), range: TimeRange(start: 0, end: 2), options: GIFOptions(),
                                  sourceWidth: 1920, compression: .smallest, output: URL(fileURLWithPath: "/o.gif"))
        let f = a[a.firstIndex(of: "-filter_complex")! + 1]
        #expect(f.contains("max_colors=64") && f.contains("min(480,iw)") && f.contains("fps=10"))
    }
    @Test func movOnlyAcceptsItsCodecs() {
        #expect(MediaWorker.fitsMOV(video: "h264", audio: "aac"))
        #expect(!MediaWorker.fitsMOV(video: "vp9", audio: "opus"))
        #expect(!MediaWorker.fitsMOV(video: "h264", audio: "opus"))
    }
}
