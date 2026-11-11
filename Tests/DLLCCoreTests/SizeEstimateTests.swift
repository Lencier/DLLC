import Foundation
import Testing
@testable import DLLCCore

struct SizeEstimateTests {
    private func job(_ configure: (inout OutputOptions) -> Void = { _ in }) -> Job {
        let q1080 = QualityOption(width: 1920, height: 1080, fps: 30, isHDR: false, formatIDs: ["137"],
                                  codecs: ["avc1.640028"], estimatedBytes: 100_000_000, estimateIsRough: false)
        let q2160 = QualityOption(width: 3840, height: 2160, fps: 30, isHDR: false, formatIDs: ["313"],
                                  codecs: ["vp9"], estimatedBytes: 400_000_000, estimateIsRough: false)
        let audio = AudioVariant(formatID: "140", acodec: "mp4a", ext: "m4a", abr: 128, filesize: 2_000_000,
                                 filesizeIsEstimate: false, language: nil, url: nil, proto: nil)
        var j = Job(url: "https://example.com/v")
        j.info = MediaInfo(id: "v", title: "V", creator: nil, platform: .other, extractor: nil, webpageURL: nil,
                           thumbnailURL: nil, duration: 100, isLive: false, videoVariants: [], audioVariants: [audio],
                           qualityOptions: [q2160, q1080], hasAudio: true, hasVideo: true, entries: [], analyzedAt: Date())
        configure(&j.options)
        return j
    }

    @Test func videoUsesTheChosenQuality() {
        #expect(job().sizeEstimate == SizeEstimate(bytes: 400_000_000, rough: false))
        let picked = job { $0.quality = .option(id: "1080p30", height: 1080, fps: 30, formatIDs: ["137"]) }
        #expect(picked.sizeEstimate == SizeEstimate(bytes: 100_000_000, rough: false))
    }

    @Test func everySizeChoiceChangesTheEstimate() {
        // The reported bug: a 1080p video showed the same size for Original, Smaller and Smallest.
        let q = QualityChoice.option(id: "1080p30", height: 1080, fps: 30, formatIDs: ["137"])
        let off = job { $0.quality = q }.sizeEstimate!.bytes
        let smaller = job { $0.quality = q; $0.compression = .smaller }.sizeEstimate!
        let smallest = job { $0.quality = q; $0.compression = .smallest }.sizeEstimate!.bytes
        #expect(smaller.rough)
        #expect(off > smaller.bytes && smaller.bytes > smallest)
        // HEVC ≈ 0.05 bit per pixel per frame + 128 kbps audio, 100 s: ≈ 40 MB.
        #expect((35_000_000...46_000_000).contains(smaller.bytes))
        // Never more than the original: DLLC keeps the original when compressing wouldn't help.
        let tiny = job { $0.compression = .smaller; $0.quality = q }
        #expect(tiny.sizeEstimate!.bytes <= 100_000_000)
    }

    @Test func compatibleMP4ConvertsAndCountsIt() {
        let mp4 = job { $0.container = .compatibleMP4 }         // VP9 gets converted
        #expect(mp4.sizeEstimate?.rough == true)
        #expect(mp4.sizeEstimate!.bytes > 400_000_000)
    }

    @Test func audioAndClipsAndGIFs() {
        #expect(job { $0.kind = .audio; $0.audioFormat = .original }.sizeEstimate == SizeEstimate(bytes: 2_000_000, rough: false))
        #expect(job { $0.kind = .audio; $0.audioFormat = .mp3 }.sizeEstimate?.bytes == 3_062_500)
        let fast = job { $0.kind = .clip; $0.range = TimeRange(start: 10, end: 20); $0.cutMode = .fast }
        #expect(fast.sizeEstimate == SizeEstimate(bytes: 40_000_000, rough: true))
        // Precise clips are re-encoded, so the length (not the source file) decides; shorter = smaller.
        let p10 = job { $0.kind = .clip; $0.range = TimeRange(start: 10, end: 20); $0.cutMode = .precise }.sizeEstimate!.bytes
        let p5 = job { $0.kind = .clip; $0.range = TimeRange(start: 10, end: 15); $0.cutMode = .precise }.sizeEstimate!.bytes
        #expect(p5 < p10 && abs(Double(p10) / Double(p5) - 2) < 0.01)
        // GIFs: bigger with width and length, smaller with a smaller palette.
        let r = TimeRange(start: 0, end: 4)
        let info = job().info!
        let g640 = SizeModel.gif(info: info, range: r, options: GIFOptions(width: 640, fps: 12), compression: .off)!.bytes
        let g320 = SizeModel.gif(info: info, range: r, options: GIFOptions(width: 320, fps: 12), compression: .off)!.bytes
        let gS = SizeModel.gif(info: info, range: r, options: GIFOptions(width: 640, fps: 12), compression: .smallest)!.bytes
        #expect(g320 < g640 && gS < g640)
        #expect((3_500_000...7_000_000).contains(g640))           // measured: 640×720, 48 frames ≈ 10.8 MB, so 640×360 ≈ 5 MB
        #expect(job { $0.kind = .gif; $0.range = r }.sizeEstimate != nil)
        #expect(SizeModel.frame(info: info, format: .jpg)!.bytes < SizeModel.frame(info: info, format: .png)!.bytes)
        var unanalysed = job(); unanalysed.info = nil
        #expect(unanalysed.sizeEstimate == nil)
    }
}
