import Foundation

// MARK: - Song and sections

/// A named part of a song ("Verse 1", "Hook 2", anything typed). Times are in song seconds.
public struct SongSection: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var start: Double
    public var end: Double
    /// Notes or lyrics; each line is one lyric line in a lyric video.
    public var note: String
    /// Tap-timed start (song time) per lyric line; nil = share the section's time evenly.
    public var lyricTimes: [Double?]

    public init(id: UUID = UUID(), name: String, start: Double, end: Double, note: String = "", lyricTimes: [Double?] = []) {
        self.id = id; self.name = name; self.start = start; self.end = end; self.note = note; self.lyricTimes = lyricTimes
    }

    public var range: TimeRange { TimeRange(start: start, end: end) }
    public var lyricLines: [String] {
        note.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// A song file the user marks up. The file itself is never modified.
public struct Song: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var path: String
    public var bookmark: Data?
    public var projectID: UUID?
    public var duration: Double
    public private(set) var sections: [SongSection]
    /// Optional file-name prefix such as "S5Sh4".
    public var prefix: String
    public var addedAt: Date
    /// The whole song's lyrics sheet; "[Verse 1] 01:31 - 01:40" lines mark sections.
    public var lyrics: String
    /// Marker times (song seconds), kept sorted.
    public var markers: [Double]

    private enum CodingKeys: String, CodingKey {
        case id, title, path, bookmark, projectID, duration, sections, prefix, addedAt, lyrics, markers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        path = try c.decode(String.self, forKey: .path)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        sections = try c.decodeIfPresent([SongSection].self, forKey: .sections) ?? []
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        lyrics = try c.decodeIfPresent(String.self, forKey: .lyrics) ?? ""
        markers = try c.decodeIfPresent([Double].self, forKey: .markers) ?? []
    }

    public init(id: UUID = UUID(), title: String, path: String, bookmark: Data? = nil, projectID: UUID? = nil,
                duration: Double, sections: [SongSection] = [], prefix: String = "", addedAt: Date = Date()) {
        self.id = id; self.title = title; self.path = path; self.bookmark = bookmark; self.projectID = projectID
        self.duration = duration; self.sections = []; self.prefix = prefix; self.addedAt = addedAt
        self.lyrics = ""; self.markers = []
        for s in sections { insert(s) }
    }

    /// Adds a section, clipped to the free gap its start falls in, keeping sections sorted and apart.
    /// Returns the stored section, or nil if there was no room.
    @discardableResult
    public mutating func insert(_ section: SongSection) -> SongSection? {
        var s = section
        s.start = min(max(0, s.start), duration)
        s.end = min(max(s.end, s.start), duration)
        let others = sections.filter { $0.id != s.id }
        if others.contains(where: { s.start >= $0.start && s.start < $0.end }) { return nil }
        if let next = others.filter({ $0.start >= s.start }).min(by: { $0.start < $1.start }) { s.end = min(s.end, next.start) }
        guard s.end - s.start >= 0.05 else { return nil }
        sections = (others + [s]).sorted { $0.start < $1.start }
        return s
    }

    /// Changes a section; times are limited to its neighbours so sections never overlap.
    public mutating func update(_ section: SongSection) {
        guard let i = sections.firstIndex(where: { $0.id == section.id }) else { return }
        var s = section
        let lower = i > 0 ? sections[i - 1].end : 0
        let upper = i + 1 < sections.count ? sections[i + 1].start : duration
        // Never shorter than 0.05 s: a zero-length section can't be played or exported.
        guard upper - lower >= 0.05 else { return }
        s.start = min(max(s.start, lower), upper - 0.05)
        s.end = min(max(s.end, s.start + 0.05), upper)
        sections[i] = s
    }

    public mutating func removeSection(_ id: UUID) { sections.removeAll { $0.id == id } }

    public mutating func removeAllSections() { sections.removeAll() }

    /// Slides a section to start at `start`, keeping its length, stopped by its neighbours.
    public mutating func move(_ id: UUID, toStart start: Double) {
        guard let i = sections.firstIndex(where: { $0.id == id }) else { return }
        let len = sections[i].end - sections[i].start
        let lower = i > 0 ? sections[i - 1].end : 0
        let upper = i + 1 < sections.count ? sections[i + 1].start : duration
        let s = min(max(start, lower), max(lower, upper - len))
        sections[i].start = s
        sections[i].end = min(s + len, upper)
    }

    /// Cuts a section in two at `time`; the second part is named "<name> (2)". Returns the new part.
    @discardableResult
    public mutating func split(_ id: UUID, at time: Double) -> SongSection? {
        guard let i = sections.firstIndex(where: { $0.id == id }),
              time - sections[i].start >= 0.05, sections[i].end - time >= 0.05 else { return nil }
        let second = SongSection(name: sections[i].name + " (2)", start: time, end: sections[i].end)
        sections[i].end = time
        sections.insert(second, at: i + 1)
        return second
    }

    /// The section playing at `time`, if any.
    public func section(at time: Double) -> SongSection? {
        sections.first { time >= $0.start && time < $0.end }
    }

    public mutating func addMarker(_ t: Double) {
        let time = min(max(0, t), duration)
        guard !markers.contains(where: { abs($0 - time) < 0.01 }) else { return }
        markers.append(time); markers.sort()
    }

    public mutating func moveMarker(at index: Int, to t: Double) {
        guard markers.indices.contains(index) else { return }
        markers[index] = min(max(0, t), duration); markers.sort()
    }

    public mutating func removeMarker(at index: Int) {
        guard markers.indices.contains(index) else { return }
        markers.remove(at: index)
    }
}

// MARK: - Export options

public enum CueSpeed: Double, Codable, Sendable, CaseIterable, Identifiable {
    case x4 = 4, x3 = 3, x2 = 2, x1 = 1, half = 0.5, third = 0.3333333333, quarter = 0.25
    public var id: Double { rawValue }

    public var label: String {
        switch self {
        case .x4: "×4"
        case .x3: "×3"
        case .x2: "×2"
        case .x1: "NM"
        case .half: "÷2"
        case .third: "÷3"
        case .quarter: "÷4"
        }
    }

    /// Spoken-out name for help text and accessibility, e.g. "Slow 2× (half speed)".
    public var longLabel: String {
        switch self {
        case .x1: "Normal speed"
        case .x2, .x3, .x4: "Fast \(label)"
        case .half: "Slow 2× (half speed)"
        case .third: "Slow 3× (one third)"
        case .quarter: "Slow 4× (one quarter)"
        }
    }

    public var isSlow: Bool { rawValue < 1 }

    /// Slowest to fastest, for left-to-right pickers.
    public static let slowToFast: [CueSpeed] = [.quarter, .third, .half, .x1, .x2, .x3, .x4]

    /// Added to file names: "(slow 2x)", "(fast x2)"; nothing at normal speed.
    public var fileSuffix: String {
        switch self {
        case .x1: ""
        case .half: "(slow 2x)"
        case .third: "(slow 3x)"
        case .quarter: "(slow 4x)"
        default: "(fast x\(Int(rawValue)))"
        }
    }
}

public enum CountInSound: String, Codable, Sendable, CaseIterable {
    case beep, click, woodblock
    public var label: String { rawValue.capitalized }
}

public struct CountIn: Codable, Sendable, Hashable {
    public var count: Int
    /// Seconds between ticks (1 or 0.5).
    public var interval: Double
    public var sound: CountInSound
    public init(count: Int = 3, interval: Double = 1, sound: CountInSound = .beep) {
        self.count = count; self.interval = interval; self.sound = sound
    }
    public var length: Double { Double(count) * interval }
}

public enum CueFormat: String, Codable, Sendable, CaseIterable {
    case mp3, wav, lyricVideo
    public var fileExtension: String {
        switch self { case .mp3: "mp3"; case .wav: "wav"; case .lyricVideo: "mp4" }
    }
    public var label: String {
        switch self { case .mp3: "MP3"; case .wav: "WAV"; case .lyricVideo: "Lyric video" }
    }
}

public struct CueOptions: Codable, Sendable, Hashable {
    public var padBefore: Double = 0
    public var padAfter: Double = 0
    public var fadeOut = false
    public var countIn: CountIn?
    public var speed: CueSpeed = .x1
    public var format: CueFormat = .mp3
    public init() {}

    public static let fadeLength = 1.5
}

// MARK: - Range math

public enum CueMath {
    /// From the first section's start to the last one's end.
    public static func range(of sections: [SongSection]) -> TimeRange? {
        guard let s = sections.map(\.start).min(), let e = sections.map(\.end).max(), e > s else { return nil }
        return TimeRange(start: s, end: e)
    }

    /// The range with padding added, kept inside the song.
    public static func padded(_ r: TimeRange, options: CueOptions, duration: Double) -> TimeRange {
        let start = max(0, r.start - max(0, options.padBefore))
        let end = min(duration > 0 ? duration : .infinity, r.end + max(0, options.padAfter))
        return TimeRange(start: start, end: max(end, start))
    }

    /// Pieces joined into one file, in time order: lead-in before the first, tail after the last.
    public static func padded(pieces: [TimeRange], options: CueOptions, duration: Double) -> [TimeRange] {
        var p = pieces.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        guard !p.isEmpty else { return [] }
        if p.count == 1 { return [padded(p[0], options: options, duration: duration)] }
        p[0].start = max(0, p[0].start - max(0, options.padBefore))
        let last = p.count - 1
        p[last].end = min(duration > 0 ? duration : .infinity, p[last].end + max(0, options.padAfter))
        return p
    }

    public static func outputDuration(pieces: [TimeRange], options: CueOptions) -> Double {
        pieces.reduce(0) { $0 + $1.duration } / options.speed.rawValue + (options.countIn?.length ?? 0)
    }

    /// Length of the exported file: the (padded) range at the chosen speed, plus the count-in.
    public static func outputDuration(range: TimeRange, options: CueOptions) -> Double {
        range.duration / options.speed.rawValue + (options.countIn?.length ?? 0)
    }
}

// MARK: - File names

public enum CueNaming {
    public static func baseName(sections: [SongSection], range: TimeRange, songTitle: String,
                                prefix: String, speed: CueSpeed) -> String {
        let names = sections.sorted { $0.start < $1.start }.map { $0.name.trimmingCharacters(in: .whitespaces) }
        let part: String
        switch names.count {
        case 0: part = "\(stamp(range.start))-\(stamp(range.end))"
        case 1...3: part = names.joined(separator: "+")
        default: part = "\(names[0])→\(names[names.count - 1])"
        }
        let title = songTitle.trimmingCharacters(in: .whitespaces)
        var core = title.isEmpty ? part : "\(title) - \(part)"
        let p = prefix.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty { core = p + " " + core }
        if !speed.fileSuffix.isEmpty { core += " " + speed.fileSuffix }
        return clean(core)
    }

    /// The first free name in the folder: "Hook 2.mp3", then "Hook 2 (2).mp3"… Never an existing file.
    public static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var n = 1
        while true {
            let name = n == 1 ? "\(base).\(ext)" : "\(base) (\(n)).\(ext)"
            let url = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    static func stamp(_ t: Double) -> String {
        let s = Int(max(0, t).rounded(.down))
        return "\(s / 60)m\(String(format: "%02d", s % 60))s"
    }

    static func clean(_ s: String) -> String {
        var out = s.unicodeScalars.map { CharacterSet(charactersIn: "/:\\\0").contains($0) || $0.properties.generalCategory == .control ? "-" : String($0) }.joined()
        while out.hasPrefix(".") { out.removeFirst() }
        if out.count > 120 { out = String(out.prefix(120)) }
        out = out.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? "Cue" : out
    }
}

// MARK: - Storage

/// The user's songs and their sections, as one JSON file in Application Support.
public final class SongStore: @unchecked Sendable {
    private let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> [Song] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Song].self, from: data)) ?? []
    }

    /// Writes the song list. Returns false if it couldn't be written (full disk, no permission).
    @discardableResult public func save(_ songs: [Song]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(songs).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Called on a background queue after each `saveSoon` write, with whether it succeeded.
    public var onSaved: (@Sendable (Bool) -> Void)?

    private let queue = DispatchQueue(label: "dllc.songs.save", qos: .utility)
    private let lock = NSLock()
    private var pending: [Song]?
    private var generation = 0

    /// Saves off the main thread, at most once per `delay` while edits keep coming (a drag or typing),
    /// so the UI never waits on the disk. `flush()` writes anything still waiting.
    public func saveSoon(_ songs: [Song], delay: Double = 0.4) {
        lock.lock(); pending = songs; generation += 1; let mine = generation; lock.unlock()
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard mine == self.generation, let list = self.pending else { self.lock.unlock(); return }
            self.pending = nil
            self.lock.unlock()
            let ok = self.save(list)
            self.onSaved?(ok)
        }
    }

    public func flush() {
        lock.lock(); let list = pending; pending = nil; generation += 1; lock.unlock()
        queue.sync { if let list { let ok = save(list); onSaved?(ok) } }
    }
}
