import Foundation
import Testing
@testable import DLLCCore

@Suite struct FFmpegTests {
    @Test func commandOptions() {
        let remote = MediaInput(url: "https://example.com/video", headers: ["Cookie": "a=b", "User-Agent": "DLLC", "Bad": "x\r\nInjected: yes"])
        let out = URL(fileURLWithPath: "/tmp/output.mp4")
        let args = FFmpegCommand.preciseClip(video: remote, audio: remote, range: .init(start: 1, end: 2), includeAudio: true, output: out, preserveHDR: true)
        #expect(args.contains("-n")); #expect(!args.contains("-y"))
        #expect(args.contains("yuv420p10le")); #expect(args.contains("libx265"))
        #expect(args.filter { $0 == "-ss" }.count == 2)
        #expect(args.contains("Cookie: a=b\r\nUser-Agent: DLLC\r\n"))
        #expect(!args.joined().contains("Injected"))
        #expect(args.firstIndex(of: "-headers")! < args.firstIndex(of: "-i")!)
        #expect(!MediaInput(url: "/tmp/a b.mov").isRemote)
        #expect(FFmpegCommand.audio(input: out, output: out, mp3: true).contains("libmp3lame"))
        #expect(FFmpegCommand.compatibleMP4(input: out, output: out, reencodeVideo: false, reencodeAudio: false, hardware: false, sourceBitrate: nil).filter { $0 == "copy" }.count == 2)
        #expect(FFmpegCommand.proxy(input: out, output: out, maxHeight: 720).contains("-copyts"))
        #expect(args.filter { $0 == "-protocol_whitelist" }.count == 2)
        #expect(FFmpegCommand.proxy(input: out, output: out, maxHeight: 720).contains("file"))
        let gif = FFmpegCommand.gif(input: MediaInput(url: "/tmp/a.mp4"), range: .init(start: 0, end: 1),
                                    options: .init(width: 4000, fps: 120), sourceWidth: nil, output: out).joined(separator: " ")
        #expect(gif.contains("fps=30.000000000") && gif.contains("min(1920,iw)"))
    }

    @Test func progress() {
        #expect(FFmpegProgressParser.outTimeSeconds("out_time_us=1250000") == 1.25)
        #expect(FFmpegProgressParser.outTimeSeconds("out_time_ms=1250000") == 1.25)
        #expect(FFmpegProgressParser.outTimeSeconds("out_time=01:02:03.250") == 3723.25)
        #expect(FFmpegProgressParser.outTimeSeconds("out_time_us=N/A") == nil)
        #expect(FFmpegProgressParser.outTimeSeconds("out_time_us=nan") == nil)
        #expect(FFmpegProgressParser.isEnd("progress=end\r"))
    }

    // MPEG-TS starts at a non-zero time (1.4 s). A snapshot at t and a precise clip starting at t
    // must show the same source frame: both count t from the file's start.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("ffmpeg").path)))
    func snapshotAndClipShareOriginWhenStartTimeIsNonZero() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DLLC-Origin-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("src.ts")
        _ = try run("ffmpeg", ["-v", "error", "-nostdin", "-f", "lavfi", "-i", "color=black:s=64x48:r=30",
                               "-vf", "geq=lum='20+mod(N*7,200)':cb=128:cr=128", "-frames:v", "90",
                               "-c:v", "libx264", "-preset", "ultrafast", "-crf", "0", "-g", "15", source.path], directory: directory)
        let probe = try FFprobe.parseProbe(run("ffprobe", FFprobe.probeArguments(file: source), directory: directory))
        #expect(probe.startTime > 1)
        let media = MediaInput(url: source.path)
        let t = 1.0
        let snap = directory.appendingPathComponent("snap.png")
        _ = try run("ffmpeg", FFmpegCommand.snapshot(input: media, at: t, frameDuration: nil, format: .png,
                                                     origin: probe.startTime, output: snap), directory: directory)
        let clip = directory.appendingPathComponent("clip.mp4")
        _ = try run("ffmpeg", FFmpegCommand.preciseClip(video: media, audio: nil, range: .init(start: t, end: t + 0.5),
                                                        includeAudio: false, output: clip, preserveHDR: false), directory: directory)
        let raw = { (file: URL) in try run("ffmpeg", ["-v", "error", "-i", file.path, "-frames:v", "1", "-pix_fmt", "gray", "-f", "rawvideo", "pipe:1"], directory: directory) }
        let snapLuma = Int(try #require(raw(snap).first)), clipLuma = Int(try #require(raw(clip).first))
        #expect(abs(snapLuma - clipLuma) <= 3, "snapshot frame luma \(snapLuma) vs clip first frame \(clipLuma)")
        let frame30 = try run("ffmpeg", ["-v", "error", "-i", source.path, "-vf", "select=eq(n\\,30)", "-frames:v", "1",
                                         "-pix_fmt", "gray", "-f", "rawvideo", "pipe:1"], directory: directory)
        #expect(abs(snapLuma - Int(try #require(frame30.first))) <= 3, "frame 30 (1.0 s after the start) expected")
    }

    // Small frames encode their ordinal in the luma plane. Compare decoded snapshot bytes to
    // the exact decoded source frame selected using real packet PTS, not nominal frame rate.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("ffmpeg").path)))
    func realRecipesCFRAndVFR() throws {
        let started = Date()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DLLC-FFmpeg-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let frameSize = 64 * 48 * 3
        for (label, rate, vfr) in [("23976", "24000/1001", false), ("2997", "30000/1001", false), ("5994", "60000/1001", false), ("vfr", "30", true), ("sparse", "1", true)] {
            let source = directory.appendingPathComponent("\(label).mp4")
            var filter = "geq=lum='20+mod(N*7,200)':cb=128:cr=128"
            if label == "sparse" { filter += ",setpts=5*N/TB" }
            else if vfr { filter += ",setpts='(N+floor(N/3)*2)/(30*TB)'" }
            _ = try run("ffmpeg", ["-v", "error", "-nostdin", "-n", "-f", "lavfi", "-i", "color=black:s=64x48:r=\(rate)", "-vf", filter,
                "-frames:v", label == "sparse" ? "3" : (vfr ? "90" : "250"), "-c:v", "libx264", "-preset", "ultrafast", "-crf", "0", "-g", "24", "-fps_mode", "passthrough", "-enc_time_base", "1:60000", source.path], directory: directory)
            let pts = FFprobe.parseFrameIndex(try run("ffprobe", FFprobe.frameIndexArguments(file: source), directory: directory))
            let decoded = try run("ffmpeg", ["-v", "error", "-i", source.path, "-map", "0:v:0", "-pix_fmt", "rgb24", "-fps_mode", "passthrough", "-f", "rawvideo", "pipe:1"], directory: directory)
            #expect(decoded.count == pts.count * frameSize)
            let media = MediaInput(url: source.path)
            let times = [0.0, 0.013, 0.551, 3.713, pts[min(17, pts.count - 1)]]
            for (iteration, time) in times.enumerated() {
                let snap = directory.appendingPathComponent("\(label)-\(iteration).png")
                _ = try run("ffmpeg", FFmpegCommand.snapshot(input: media, at: time, frameDuration: nil, format: .png, output: snap), directory: directory)
                let actual = try run("ffmpeg", ["-v", "error", "-i", snap.path, "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"], directory: directory)
                let index = try #require(pts.lastIndex { $0 <= time + 0.000001 })
                let expected = decoded.subdata(in: (index * frameSize)..<((index + 1) * frameSize))
                #expect(actual == expected, "\(label), t=\(time), expected source frame \(index), PTS=\(pts[index])")
            }
            if label == "sparse" { continue }
            let range = TimeRange(start: 0.513, end: 1.219)
            let clip = directory.appendingPathComponent("\(label)-precise.mp4")
            _ = try run("ffmpeg", FFmpegCommand.preciseClip(video: media, audio: nil, range: range, includeAudio: false, output: clip, preserveHDR: false), directory: directory)
            let clipPTS = FFprobe.parseFrameIndex(try run("ffprobe", FFprobe.frameIndexArguments(file: clip), directory: directory))
            let first = try #require(clipPTS.first)
            let maxFrame = zip(pts, pts.dropFirst()).map { $1 - $0 }.max()!
            #expect(abs(first) <= maxFrame)
            let probe = try FFprobe.parseProbe(run("ffprobe", FFprobe.probeArguments(file: clip), directory: directory))
            #expect(abs(try #require(probe.duration) - range.duration) <= maxFrame + 0.002)
            let firstPixels = try run("ffmpeg", ["-v", "error", "-i", clip.path, "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"], directory: directory)
            let sourceIndex = try #require(pts.firstIndex { $0 >= range.start - 0.000001 })
            #expect(abs(Int(try #require(firstPixels.first)) - Int(decoded[sourceIndex * frameSize])) <= 3,
                    "Precise clip begins with source frame \(sourceIndex) for \(label)")
            if vfr {
                let gif = directory.appendingPathComponent("out.gif")
                _ = try run("ffmpeg", FFmpegCommand.gif(input: media, range: range, options: .init(width: 640, fps: 12, loop: true), sourceWidth: nil, output: gif), directory: directory)
                let gifProbe = try FFprobe.parseProbe(run("ffprobe", FFprobe.probeArguments(file: gif), directory: directory))
                #expect(gifProbe.video?.width == 64)
                #expect(gifProbe.video?.codecName == "gif")
                let fast = directory.appendingPathComponent("fast.mp4")
                _ = try run("ffmpeg", FFmpegCommand.fastClip(video: media, audio: nil, range: range, includeAudio: false, output: fast), directory: directory)
                _ = try run("ffmpeg", ["-v", "error", "-xerror", "-i", fast.path, "-f", "null", "-"], directory: directory)
                let fastProbe = try FFprobe.parseProbe(run("ffprobe", FFprobe.probeArguments(file: fast), directory: directory))
                #expect(fastProbe.video?.codecName == "h264")
                #expect((fastProbe.duration ?? 0) > 0)
            }
        }
        let hdrSource = directory.appendingPathComponent("hdr-source.mp4")
        _ = try run("ffmpeg", ["-v", "error", "-n", "-f", "lavfi", "-i", "testsrc2=s=64x48:r=24:d=0.5",
            "-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p10le",
            "-x265-params", "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc", hdrSource.path], directory: directory)
        #expect(try FFprobe.parseProbe(run("ffprobe", FFprobe.probeArguments(file: hdrSource), directory: directory)).isHDR)
        let hdrClip = directory.appendingPathComponent("hdr-clip.mp4")
        _ = try run("ffmpeg", FFmpegCommand.preciseClip(video: .init(url: hdrSource.path), audio: nil,
            range: .init(start: 0, end: 0.25), includeAudio: false, output: hdrClip, preserveHDR: true), directory: directory)
        let hdrData = try run("ffprobe", FFprobe.probeArguments(file: hdrClip), directory: directory)
        let hdrProbe = try FFprobe.parseProbe(hdrData)
        #expect(hdrProbe.video?.pixFmt == "yuv420p10le")
        #expect(hdrProbe.isHDR)
        let hdrJSON = try #require(JSONSerialization.jsonObject(with: hdrData) as? [String: Any])
        let hdrStream = try #require((hdrJSON["streams"] as? [[String: Any]])?.first)
        #expect(hdrStream["color_primaries"] as? String == "bt2020")
        #expect(hdrStream["color_space"] as? String == "bt2020nc")
        #expect(Date().timeIntervalSince(started) < 20, "Bundled-tool integrations must stay fast")
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("ffmpeg").path)))
    func toneMapChainRunsOnRealHDR() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DLLC-HDR-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hdr = directory.appendingPathComponent("hdr.mp4")
        _ = try run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "testsrc=s=128x72:r=30", "-frames:v", "15",
                               "-vf", "format=yuv420p10le", "-c:v", "libx265", "-x265-params",
                               "log-level=0:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc", hdr.path], directory: directory)
        let probe = try FFprobe.parseProbe(run("ffprobe", FFprobe.probeArguments(file: hdr), directory: directory))
        #expect(probe.isHDR)
        let out = directory.appendingPathComponent("sdr.mp4")
        _ = try run("ffmpeg", FFmpegCommand.compatibleMP4(input: hdr, output: out, reencodeVideo: true, reencodeAudio: false,
                                                          hardware: false, sourceBitrate: nil, hdrTransfer: probe.hdrTransfer),
                    directory: directory)
        let result = try FFprobe.parseProbe(run("ffprobe", FFprobe.probeArguments(file: out), directory: directory))
        #expect(result.video?.codecName == "h264" && result.video?.pixFmt == "yuv420p")
        #expect(result.video?.colorTransfer == "bt709" && !result.isHDR)
    }

    private static var tools: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor/tools")
    }
    private func run(_ tool: String, _ arguments: [String], directory: URL) throws -> Data {
        let process = Process()
        process.executableURL = Self.tools.appendingPathComponent(tool)
        process.arguments = arguments
        let stdout = Pipe()
        let errorFile = directory.appendingPathComponent("stderr-\(UUID()).txt")
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        let stderr = try FileHandle(forWritingTo: errorFile)
        defer { try? stderr.close(); try? FileManager.default.removeItem(at: errorFile) }
        process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let error = String(decoding: (try? Data(contentsOf: errorFile)) ?? Data(), as: UTF8.self)
        try #require(process.terminationStatus == 0, "\(tool) failed: \(error)")
        return data
    }
}

@Suite struct FFprobeTests {
    @Test func parsing() throws {
        let data = Data(#"{"format":{"duration":"12.25","format_name":"mov,mp4","bit_rate":"12345"},"streams":[{"index":0,"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}},{"index":1,"codec_type":"video","codec_name":"hevc","width":1920,"height":1080,"avg_frame_rate":"24000/1001","r_frame_rate":"0/0","pix_fmt":"yuv420p10le","color_transfer":"smpte2084","start_time":"0.125","side_data_list":[{"rotation":-90}]},{"index":2,"codec_type":"audio","codec_name":"aac","bit_rate":"N/A"}]}"#.utf8)
        let result = try FFprobe.parseProbe(data)
        #expect(result.duration == 12.25)
        #expect(result.video?.index == 1)
        #expect(result.video?.rotation == -90)
        #expect(result.video?.avgFrameRate == 24000.0 / 1001)
        #expect(result.video?.rFrameRate == nil)
        #expect(result.audio?.bitRate == nil)
        #expect(result.isHDR)
        #expect(try JSONDecoder().decode(ProbeResult.self, from: JSONEncoder().encode(result)) == result)
        #expect(FFprobe.parseFrameIndex(Data("0.3\nN/A\nnan\n0.1,side_data\n-0.2\ninf\n".utf8)) == [-0.2, 0.1, 0.3])
        #expect(throws: (any Error).self) { try FFprobe.parseProbe(Data("garbage".utf8)) }
    }
}
