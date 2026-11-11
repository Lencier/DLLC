import AVFoundation
import DLLCCore
import Observation

/// Plays a song for Song Cues at any of the cue speeds with the pitch kept. Only observes time while playing.
@MainActor @Observable
final class SongPlayer {
    @ObservationIgnored let player = AVPlayer()
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    var speed: CueSpeed = .x1 { didSet { if isPlaying { player.rate = Float(speed.rawValue) } } }
    var volume: Float = UserDefaults.standard.object(forKey: "previewVolume") as? Float ?? 1 {
        didSet { player.volume = volume; UserDefaults.standard.set(volume, forKey: "previewVolume") }
    }
    var isMuted: Bool = UserDefaults.standard.bool(forKey: "previewMuted") {
        didSet { player.isMuted = isMuted; UserDefaults.standard.set(isMuted, forKey: "previewMuted") }
    }
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var stopAt: Double?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init() {
        player.volume = volume
        player.isMuted = isMuted
        player.actionAtItemEnd = .pause
    }

    func load(_ url: URL?) {
        pause()
        guard let url else { player.replaceCurrentItem(with: nil); return }
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral // keeps pitch at ×0.25…×4
        player.replaceCurrentItem(with: item)
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
        currentTime = 0
    }

    func togglePlay() { isPlaying ? pause() : play() }

    /// Plays from the current time; with `until`, stops there.
    func play(from start: Double? = nil, until end: Double? = nil) {
        if let start { seek(start) }
        else if let d = player.currentItem?.duration.seconds, d.isFinite, currentTime >= d - 0.05 { seek(0) }
        stopAt = end
        player.playImmediately(atRate: Float(speed.rawValue))
        isPlaying = true
        startObserving()
    }

    func pause() {
        player.pause()
        isPlaying = false
        stopAt = nil
        stopObserving()
        currentTime = player.currentTime().seconds.isFinite ? player.currentTime().seconds : currentTime
    }

    func seek(_ t: Double) {
        let time = max(0, t)
        currentTime = time
        player.seek(to: CMTime(seconds: time, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func tearDown() {
        pause()
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    private func startObserving() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, t.seconds.isFinite else { return }
                self.currentTime = t.seconds
                if let end = self.stopAt, t.seconds >= end { self.pause(); self.seek(end) }
            }
        }
    }

    private func stopObserving() {
        if let t = timeObserver { player.removeTimeObserver(t) }
        timeObserver = nil
    }
}
