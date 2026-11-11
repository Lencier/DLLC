import Foundation
import Testing
@testable import DLLCCore

struct YTDLPTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    private var tools: ToolPaths {
        let directory = URL(fileURLWithPath: "/tools")
        return ToolPaths(ytdlp: directory.appendingPathComponent("yt-dlp"), ffmpeg: directory.appendingPathComponent("ffmpeg"), ffprobe: directory.appendingPathComponent("ffprobe"), deno: directory.appendingPathComponent("deno"))
    }
    @Test func youtubeRealFixtures() throws {
        let zoo = try YTDLPParser.parseInfo(fixture("youtube-zoo"), requestedURL: "https://youtube.com/watch?v=jNQXAC9IVRw")
        #expect(zoo.title == "Me at the zoo")
        #expect(zoo.platform == .youtube)
        #expect(zoo.hasAudio && zoo.hasVideo)
        #expect(!zoo.videoVariants.contains { $0.ext == "mhtml" })
        let fourK = try YTDLPParser.parseInfo(fixture("youtube-4k"), requestedURL: "https://youtube.com/watch?v=LXb3EKWsInQ")
        #expect(fourK.qualityOptions.contains { $0.height == 2160 && $0.fps == 60 })
        #expect(fourK.qualityOptions.contains { $0.isHDR })
        for option in fourK.qualityOptions {
            for id in option.formatIDs {
                let variant = try #require(fourK.videoVariants.first { $0.formatID == id })
                #expect(variant.height == option.height)
                #expect(variant.fps.map { ($0 * 100).rounded() / 100 } == option.fps)
                #expect(variant.isHDR == option.isHDR)
            }
        }
    }
    @Test func otherRealFixtures() throws {
        let pin = try YTDLPParser.parseInfo(fixture("pinterest-real"), requestedURL: "https://pinterest.com/pin/664281013778109217/")
        #expect(pin.platform == .pinterest)
        #expect(pin.hasVideo)
        let instagram = try YTDLPParser.parseInfo(fixture("instagram"), requestedURL: "https://instagram.com/p/BQ0eAlwhDrw/")
        #expect(instagram.platform == .instagram)
        #expect(instagram.hasVideo || !instagram.entries.isEmpty)
    }
    @Test func singleAndPlaylist() throws {
        let single = Data(#"{"id":"silent","url":"https://cdn.example/video.mp4","ext":"mp4","vcodec":"h264","acodec":"none","height":1080,"fps":30,"filesize_approx":1234,"thumbnails":[{"height":100,"url":"small"},{"height":800,"url":"large"}]}"#.utf8)
        let info = try YTDLPParser.parseInfo(single, requestedURL: "https://example.com")
        #expect(info.hasVideo && !info.hasAudio)
        #expect(info.videoVariants.first?.filesize == 1234)
        #expect(info.videoVariants.first?.filesizeIsEstimate == true)
        #expect(info.thumbnailURL == "large")
        let playlist = Data(#"{"_type":"playlist","id":"p","entries":[null,{"id":"v","_type":"url","url":"https://example.com/v","title":"Video"},{"id":"i","ext":"jpg","url":"https://example.com/i"}]}"#.utf8)
        let result = try YTDLPParser.parseInfo(playlist, requestedURL: "https://example.com")
        #expect(result.videoVariants.isEmpty)
        #expect(result.entries.map(\.index) == [2, 3])
        #expect(result.entries.map(\.isVideo) == [true, false])
        let child = #"{"_type":"playlist","entries":[{"id":"v","formats":[{"format_id":"a","vcodec":"h264","acodec":"aac","ext":"mp4"}]}]}"#
        #expect(try YTDLPParser.parseInfo(Data(child.utf8), requestedURL: "https://example.com").id == "v")
        #expect(throws: (any Error).self) { try YTDLPParser.parseInfo(Data("[]".utf8), requestedURL: "") }
    }
    private func variant(_ id: String, height: Int, fps: Double, codec: String, hdr: Bool = false, muxed: Bool = false, size: Int64? = 1000) -> VideoVariant {
        VideoVariant(formatID: id, width: height * 16 / 9, height: height, fps: fps, vcodec: codec, ext: "mp4", dynamicRange: hdr ? "HDR10" : "SDR", hasAudio: muxed, filesize: size, filesizeIsEstimate: false, tbr: 8, url: nil, proto: nil)
    }
    @Test func realCombinationsAndSizes() throws {
        let video = [variant("4k30", height: 2160, fps: 30, codec: "vp9"), variant("1080-60", height: 1080, fps: 60, codec: "h264"), variant("av1", height: 1080, fps: 60, codec: "av01"), variant("hdr", height: 1080, fps: 60, codec: "h265", hdr: true)]
        let audio = AudioVariant(formatID: "a", acodec: "aac", ext: "m4a", abr: 128, filesize: 300, filesizeIsEstimate: true, language: nil, url: nil, proto: nil)
        let options = YTDLPParser.buildQualityOptions(video: video, audio: [audio], duration: 10)
        #expect(options.count == 3)
        #expect(!options.contains { $0.height == 2160 && $0.fps == 60 })
        #expect(options[1].formatIDs == ["1080-60", "av1"])
        #expect(options[1].estimatedBytes == 1300)
        #expect(options[1].estimateIsRough)
        #expect(!options[1].isHDR && options[2].isHDR)
        let muxed = YTDLPParser.buildQualityOptions(video: [variant("m", height: 720, fps: 29.974, codec: "h264", muxed: true, size: nil)], audio: [audio], duration: 10)
        #expect(muxed.first?.estimatedBytes == 10000)
        #expect(muxed.first?.fps == 29.97)
        #expect(muxed.first?.estimateIsRough == true)
        #expect(YTDLPParser.buildQualityOptions(video: [video[0]], audio: [], duration: nil).first?.estimatedBytes == nil)
    }
    @Test func commandArguments() {
        var options = OutputOptions()
        let args = YTDLPCommand.downloadArguments(url: "-untrusted", options: options, workDir: URL(fileURLWithPath: "/tmp/100%"), tools: tools, cookies: .none, cookiesDirectory: nil)
        #expect(Array(args.suffix(2)) == ["--", "-untrusted"])
        #expect(args.contains("download:DLLC_PROGRESS %(progress)j"))
        #expect(args.contains("after_move:DLLC_FILE %(filepath)j"))
        #expect(args.contains("--no-quiet"))
        #expect(args.contains("mp4/mkv"))
        #expect(args.contains { $0.hasPrefix("/tmp/100%%/") })
        #expect(YTDLPCommand.formatSelector(options: options) == "bv*+ba/b")
        options.quality = .option(id: "chosen", height: 720, fps: 30, formatIDs: ["136", "247"])
        #expect(YTDLPCommand.formatSelector(options: options) == "136[protocol!*=m3u8]+ba/136[protocol!*=m3u8]/247[protocol!*=m3u8]+ba/247[protocol!*=m3u8]/136+ba/136/247+ba/247")
        options.selectedEntries = [1, 3]
        options.kind = .audio
        let audio = YTDLPCommand.downloadArguments(url: "u", options: options, workDir: URL(fileURLWithPath: "/tmp"), tools: tools, cookies: .browser(name: "chrome", profile: "Default"), cookiesDirectory: nil)
        #expect(audio.contains("chrome:Default") && audio.contains("1,3"))
        #expect(audio.contains("--yes-playlist") && !audio.contains("--no-playlist"))
        #expect(audio.contains("mp3") && audio.contains("--audio-quality"))
        options.audioFormat = .original
        #expect(YTDLPCommand.downloadArguments(url: "u", options: options, workDir: URL(fileURLWithPath: "/tmp"), tools: tools, cookies: .none, cookiesDirectory: nil).contains("best"))
        let analyze = YTDLPCommand.analyzeArguments(url: "u", flatPlaylist: true, playlistItems: [2, 5], tools: tools, cookies: .file(name: "cookies.txt"), cookiesDirectory: URL(fileURLWithPath: "/cookies"))
        #expect(analyze.contains("--flat-playlist") && analyze.contains("2,5"))
        #expect(analyze.contains("/cookies/cookies.txt"))
        #expect(analyze.contains("deno:/tools/deno"))
        #expect(!analyze.contains("--no-warnings"))
    }
    @Test func progressEdgeCases() throws {
        #expect(YTDLPOutput.parseProgress("noise") == nil)
        #expect(YTDLPOutput.parseProgress("DLLC_PROGRESS invalid") == nil)
        let estimated = try #require(YTDLPOutput.parseProgress(#"DLLC_PROGRESS {"status":"downloading","downloaded_bytes":200,"total_bytes_estimate":100,"speed":null,"eta":null}"#))
        #expect(estimated.fraction == 1 && estimated.totalIsEstimate)
        #expect(estimated.speed == nil)
        let fragment = try #require(YTDLPOutput.parseProgress(#"DLLC_PROGRESS {"status":"downloading","fragment_index":2,"fragment_count":4}"#))
        #expect(fragment.fraction == 0.5)
        #expect(YTDLPOutput.parseProgress(#"DLLC_PROGRESS {"status":"finished"}"#)?.fraction == nil)
        #expect(YTDLPOutput.parseFinalPath(#"DLLC_FILE "/tmp/ไทย \"quoted\".mp4""#) == "/tmp/ไทย \"quoted\".mp4")
        #expect(YTDLPOutput.parseFinalPath("DLLC_FILE not-json") == nil)
        #expect(YTDLPOutput.stage(for: "[ExtractAudio] Destination") == "Extracting audio")
        #expect(YTDLPOutput.stage(for: "[VideoRemuxer] Remuxing") == "Converting")
        #expect(YTDLPOutput.stage(for: "[FixupM4a] Correcting") == "Finalizing")
        #expect(YTDLPOutput.stage(for: "[download] Destination: file") == nil)
    }
    @Test func realDownloadLines() throws {
        let lines = try JSONDecoder().decode([String].self, from: fixture("download-lines"))
        let progress = lines.compactMap(YTDLPOutput.parseProgress)
        #expect(progress.count >= 4)
        #expect(progress.filter { $0.status == "finished" }.count == 2)
        #expect(progress.filter { $0.status == "finished" }.allSatisfy { $0.fraction == 1 })
        #expect(lines.compactMap(YTDLPOutput.parseFinalPath).first?.hasSuffix(".mkv") == true)
        #expect(lines.compactMap { YTDLPOutput.stage(for: $0) }.contains("Merging"))
    }
}
