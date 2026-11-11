import AVFoundation
import Foundation

/// Loudness outline of a song: the average (RMS) level of each short bucket (0…1), computed once and cached.
public struct WaveformPeaks: Codable, Sendable, Equatable {
    public let peaksPerSecond: Int
    public let values: [Float]

    public init(peaksPerSecond: Int, values: [Float]) {
        self.peaksPerSecond = peaksPerSecond; self.values = values
    }

    public var duration: Double { Double(values.count) / Double(peaksPerSecond) }

    /// The same outline stretched to the song's own loudness range (in dB), so a loud, heavily mastered song
    /// still shows quiet and loud parts clearly instead of one solid block. Silence stays flat.
    public func contrasted() -> WaveformPeaks {
        let db = values.map { 20 * log10(max($0, 0.000_01)) }
        let audible = db.filter { $0 > -70 }.sorted()
        guard audible.count > 10 else { return self }
        let lo = audible[Int(Double(audible.count - 1) * 0.05)]
        let hi = audible[Int(Double(audible.count - 1) * 0.995)]
        guard hi - lo > 0.5 else { return self }
        let mapped = db.map { d -> Float in
            d <= -70 ? 0 : min(1, max(0.03, (d - lo) / (hi - lo)))
        }
        return WaveformPeaks(peaksPerSecond: peaksPerSecond, values: mapped)
    }

    /// `buckets` values covering `from`…`to` seconds, each the loudest peak in its share (for drawing).
    public func slice(from: Double, to: Double, buckets: Int) -> [Float] {
        guard buckets > 0, to > from, !values.isEmpty else { return [] }
        let perSecond = Double(peaksPerSecond)
        return (0..<buckets).map { b in
            let t0 = from + (to - from) * Double(b) / Double(buckets)
            let t1 = from + (to - from) * Double(b + 1) / Double(buckets)
            let i0 = max(0, min(values.count - 1, Int(t0 * perSecond)))
            let i1 = max(i0 + 1, min(values.count, Int((t1 * perSecond).rounded(.up))))
            return values[i0..<i1].max() ?? 0
        }
    }
}

public enum WaveformBuilder {
    /// Reads the audio in chunks (never the whole file in memory) and keeps one RMS level per bucket.
    public static func build(url: URL, peaksPerSecond: Int = 200) async throws -> WaveformPeaks {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return WaveformPeaks(peaksPerSecond: peaksPerSecond, values: [])
        }
        let sampleRate = 8_000
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: sampleRate,
        ]
        let work = Task.detached(priority: .utility) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
            let bucket = max(1, sampleRate / peaksPerSecond)
            var values: [Float] = []
            var sumSquares: Float = 0, filled = 0
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                                  dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { continue }
                let count = length / MemoryLayout<Float>.size
                pointer.withMemoryRebound(to: Float.self, capacity: count) { samples in
                    for i in 0..<count {
                        sumSquares += samples[i] * samples[i]
                        filled += 1
                        if filled == bucket { values.append(min(1, (sumSquares / Float(filled)).squareRoot())); sumSquares = 0; filled = 0 }
                    }
                }
            }
            if filled > 0 { values.append(min(1, (sumSquares / Float(filled)).squareRoot())) }
            if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
            return WaveformPeaks(peaksPerSecond: peaksPerSecond, values: values)
        }
        // Leaving the song stops the reading instead of letting it run on in the background.
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// Cached by the file's identity (path, size, modification time) in `cacheDir`; rebuilt when missing.
    /// The cached outline, contrast-stretched off the main thread for drawing.
    public static func cachedForDisplay(url: URL, cacheDir: URL) async throws -> WaveformPeaks {
        let peaks = try await cached(url: url, cacheDir: cacheDir)
        try Task.checkCancellation()
        return await Task.detached(priority: .utility) { peaks.contrasted() }.value
    }

    public static func cached(url: URL, cacheDir: URL) async throws -> WaveformPeaks {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let identity = "\(url.standardizedFileURL.path)|\((attrs?[.size] as? NSNumber)?.int64Value ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let key = String(identity.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }, radix: 16)
        let file = cacheDir.appendingPathComponent("\(key).rms")
        if let data = try? Data(contentsOf: file), let peaks = try? PropertyListDecoder().decode(WaveformPeaks.self, from: data) {
            CacheFolder.touch(file)
            return peaks
        }
        let peaks = try await build(url: url)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(peaks) { try? data.write(to: file, options: .atomic) }
        return peaks
    }
}
