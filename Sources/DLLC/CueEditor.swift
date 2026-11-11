import AppKit
import DLLCCore
import Observation
import SwiftUI

/// Everything the Song Cues editor needs between its views: the song being edited, the player,
/// the timeline's zoom and scroll, the tool, the selection and undo.
@MainActor @Observable
final class CueEditor {
    enum Tool { case select, range }

    let songID: UUID
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored weak var undoManager: UndoManager?
    let player = SongPlayer()

    private(set) var peaks: WaveformPeaks?
    private(set) var peaksFailed = false
    private(set) var fileURL: URL?

    var tool: Tool = .select
    var snap = UserDefaults.standard.object(forKey: "cueSnap") as? Bool ?? true {
        didSet { UserDefaults.standard.set(snap, forKey: "cueSnap") }
    }
    /// Sections chosen on the timeline; the same set is what gets exported.
    var selected: Set<UUID> = []
    var selectedMarker: Int?
    /// Section whose name is being edited in the popover.
    var renaming: UUID?

    // Timeline geometry: pixels per second and the time at the left edge.
    var pps: Double = 10
    var scrollStart: Double = 0
    var viewWidth: Double = 0 { didSet { if oldValue < 2 || !hasFitted { fit() } else { clampScroll() } } }
    @ObservationIgnored private var hasFitted = false

    init(songID: UUID, model: AppModel) {
        self.songID = songID
        self.model = model
    }

    var song: Song? { model?.songs.first { $0.id == songID } }
    var duration: Double { max(0.1, song?.duration ?? 1) }
    var visibleSpan: Double { viewWidth / pps }

    // MARK: Loading

    func load() async {
        guard let model, let song else { return }
        fileURL = model.songFileURL(song)
        guard let url = fileURL else { player.load(nil); return }
        player.load(url)
        peaksFailed = false
        let token = UUID()
        loadToken = token
        do {
            let p = try await WaveformBuilder.cachedForDisplay(url: url, cacheDir: model.paths.waveformCache)
            if loadToken == token { peaks = p }       // an older load never replaces a newer file's outline
        } catch is CancellationError {
        } catch {
            if loadToken == token { peaksFailed = true }
        }
    }
    @ObservationIgnored private var loadToken: UUID?

    func reloadFile() async { await load() }

    // MARK: Zoom and scroll

    var minPPS: Double { max(0.5, viewWidth / duration) }
    let maxPPS: Double = 600

    func fit() {
        if viewWidth > 1, song != nil { hasFitted = true }
        pps = minPPS
        scrollStart = 0
    }

    /// Zooms keeping the time under `anchorX` (view x) in place.
    func zoom(by factor: Double, anchorX: Double? = nil) {
        let ax = anchorX ?? playheadX ?? viewWidth / 2
        let anchorT = scrollStart + ax / pps
        pps = min(max(pps * factor, minPPS), maxPPS)
        scrollStart = anchorT - ax / pps
        clampScroll()
    }

    func scroll(byPixels dx: Double) {
        scrollStart += dx / pps
        clampScroll()
    }

    func clampScroll() {
        pps = min(max(pps, minPPS), maxPPS)
        scrollStart = min(max(0, scrollStart), max(0, duration - visibleSpan))
    }

    func x(_ t: Double) -> Double { (t - scrollStart) * pps }
    func time(_ x: Double) -> Double { min(max(0, scrollStart + x / pps), duration) }

    private var playheadX: Double? {
        let px = x(player.currentTime)
        return px >= 0 && px <= viewWidth ? px : nil
    }

    /// While playing, turns the page when the playhead runs off the right edge.
    func follow(_ t: Double) {
        guard player.isPlaying else { return }
        if t > scrollStart + visibleSpan * 0.95 || t < scrollStart {
            scrollStart = t - visibleSpan * 0.05
            clampScroll()
        }
    }

    func reveal(_ t: Double) {
        if t < scrollStart || t > scrollStart + visibleSpan {
            scrollStart = t - visibleSpan / 2
            clampScroll()
        }
    }

    // MARK: Snapping

    /// The nearest snap point within 8 px (section edges, markers, playhead, start and end).
    func snapped(_ t: Double, ignoring: UUID? = nil, ignoringMarker: Int? = nil) -> (time: Double, snappedTo: Double?) {
        guard snap, let song else { return (t, nil) }
        var targets = [0, duration, player.currentTime]
        for (i, m) in song.markers.enumerated() where i != ignoringMarker { targets.append(m) }
        for s in song.sections where s.id != ignoring { targets += [s.start, s.end] }
        let limit = 8 / pps
        guard let best = targets.min(by: { abs($0 - t) < abs($1 - t) }), abs(best - t) <= limit else { return (t, nil) }
        return (best, best)
    }

    // MARK: Editing

    /// Applies a change to the song. With an undo name, ⌘Z restores the previous version.
    func edit(_ undoName: String?, timesToLyrics: Bool = true, _ change: (inout Song) -> Void) {
        guard let model, var s = song else { return }
        let old = s
        change(&s)
        if timesToLyrics, s.sections != old.sections { s.writeTimesToLyrics(previous: old.sections) }
        guard s != old else { return }
        model.updateSong(s)
        if let undoName, let undoManager { Self.registerUndo(undoManager, model: model, songID: songID, old: old, new: s, undoName) }
    }

    /// Undo puts back only what that step changed (sections, markers, title…), so later edits — like lyrics
    /// typed afterwards — survive. It holds the model, not this editor, so Redo still works after switching songs.
    static func registerUndo(_ um: UndoManager, model: AppModel, songID: UUID, old: Song, new: Song, _ name: String) {
        um.registerUndo(withTarget: model) { m in
            MainActor.assumeIsolated {
                guard var cur = m.songs.first(where: { $0.id == songID }) else { return }
                let before = cur
                if old.title != new.title { cur.title = old.title }
                if old.prefix != new.prefix { cur.prefix = old.prefix }
                if old.markers != new.markers { cur.markers = old.markers }
                if old.sections != new.sections {
                    let was = cur.sections
                    cur.replaceSections(old.sections)
                    cur.writeTimesToLyrics(previous: was)
                } else if old.lyrics != new.lyrics {
                    cur.lyrics = old.lyrics
                }
                guard cur != before else { return }
                m.updateSong(cur)
                registerUndo(um, model: m, songID: songID, old: before, new: cur, name)
            }
        }
        um.setActionName(name)
    }

    func addSection(_ range: TimeRange) {
        guard let song else { return }
        let name = Self.nextName(after: song.sections.last { $0.end <= range.start + 0.01 }?.name, existing: song.sections.map(\.name))
        var added: SongSection?
        edit("Add Section") { added = $0.insert(SongSection(name: name, start: range.start, end: range.end)) }
        if let added {
            selected = [added.id]
            renaming = added.id
        } else {
            model?.show(.warning, "That spot already belongs to another section.")
        }
    }

    func rename(_ id: UUID, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var s = song?.sections.first(where: { $0.id == id }), s.name != name else { return }
        s.name = name
        edit("Rename Section") { $0.update(s) }
    }

    func splitAtPlayhead() {
        let t = player.currentTime
        guard let s = song?.section(at: t) else { model?.show(.info, "Move the playhead over a section to split it."); return }
        var second: SongSection?
        edit("Split Section") { second = $0.split(s.id, at: t) }
        if let second { selected = [second.id] }
    }

    func addMarkerAtPlayhead() {
        edit("Add Marker", timesToLyrics: false) { $0.addMarker(player.currentTime) }
    }

    func deleteSelection() {
        if let m = selectedMarker {
            edit("Delete Marker", timesToLyrics: false) { $0.removeMarker(at: m) }
            selectedMarker = nil
        } else if !selected.isEmpty {
            let ids = selected
            edit(ids.count == 1 ? "Delete Section" : "Delete Sections") { s in ids.forEach { s.removeSection($0) } }
            selected = []
        }
    }

    func selectAllSections() { selected = Set(song?.sections.map(\.id) ?? []) }

    /// Click (replace), ⌘-click (toggle) or ⇧-click (extend through neighbours).
    func click(section id: UUID, modifiers: NSEvent.ModifierFlags) {
        selectedMarker = nil
        guard let sections = song?.sections else { return }
        if modifiers.contains(.command) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        } else if modifiers.contains(.shift), let i = sections.firstIndex(where: { $0.id == id }),
                  let a = sections.firstIndex(where: { selected.contains($0.id) }) {
            let b = sections.lastIndex(where: { selected.contains($0.id) }) ?? a
            selected = Set(sections[min(a, i)...max(b, i)].map(\.id))
        } else {
            selected = [id]
        }
    }

    // MARK: Transport

    func togglePlay() {
        if !player.isPlaying, let s = song?.sections.first(where: { selected.contains($0.id) }), selected.count == 1,
           !(s.start..<s.end).contains(player.currentTime) {
            player.seek(s.start)
        }
        player.togglePlay()
    }

    func jump(_ seconds: Double) {
        player.seek(min(max(0, player.currentTime + seconds), duration))
        reveal(player.currentTime)
    }

    func copyLyricsAndTimes() {
        edit(nil) { $0.writeTimesToLyrics() }
        let text = song?.lyrics ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model?.show(.info, "Copied lyrics and section times.")
    }

    func sectionsFromLyrics() {
        guard let song else { return }
        let found = LyricSheet.sections(song.lyrics, duration: song.duration)
        guard !found.isEmpty else {
            model?.show(.info, "Write headings like “[Verse 1] 01:31 - 01:40” in the lyrics first.")
            return
        }
        edit("Sections from Lyrics", timesToLyrics: false) { $0.syncSectionsFromLyrics() }
    }

    // MARK: Names

    static let presetNames = ["Intro", "Verse 1", "Verse 2", "Verse 3", "Pre-hook", "Hook 1", "Hook 2", "Hook 3",
                              "Bridge", "Dance Break", "Outro"]

    /// A sensible next name in pop-song order (Intro → Verse → Pre-hook → Hook → … → Bridge → Hook → Outro),
    /// numbered so it is never one already used.
    static func nextName(after previous: String?, existing: [String]) -> String {
        let used = Set(existing.map { $0.lowercased() })
        func free(_ base: String, numbered: Bool) -> String {
            if !numbered { return used.contains(base.lowercased()) ? free(base, numbered: true) : base }
            var n = 1
            while used.contains("\(base) \(n)".lowercased()) { n += 1 }
            return "\(base) \(n)"
        }
        let hooks = existing.filter { $0.lowercased().hasPrefix("hook") }.count
        let p = previous?.lowercased() ?? ""
        switch true {
        case previous == nil: return used.contains("intro") ? free("Verse", numbered: true) : "Intro"
        case p.hasPrefix("intro"): return free("Verse", numbered: true)
        case p.hasPrefix("verse"): return free("Pre-hook", numbered: false)
        case p.hasPrefix("pre"): return free("Hook", numbered: true)
        case p.hasPrefix("hook") || p.hasPrefix("chorus"): return hooks < 2 ? free("Verse", numbered: true) : free("Bridge", numbered: false)
        case p.hasPrefix("bridge"), p.hasPrefix("dance"): return free("Hook", numbered: true)
        default: return free("Section", numbered: true)
        }
    }
}

/// Colour for a section from its name, so all Hooks share a colour, all Verses another…
enum SectionColor {
    static func of(_ name: String) -> Color {
        let n = name.lowercased()
        if n.hasPrefix("intro") { return Color(light: 0x5B6B82, dark: 0x8A9BB5) }
        if n.hasPrefix("verse") { return Color(light: 0x2E6FD0, dark: 0x4F8FEA) }
        if n.hasPrefix("pre") { return Color(light: 0x8E3FD9, dark: 0xA968F0) }
        if n.hasPrefix("hook") || n.hasPrefix("chorus") { return Color(light: 0xC0261A, dark: 0xE0412E) }
        if n.hasPrefix("bridge") { return Color(light: 0xB25E00, dark: 0xE08A1E) }
        if n.hasPrefix("dance") || n.hasPrefix("break") { return Color(light: 0x1F8A4C, dark: 0x2FAE68) }
        if n.hasPrefix("outro") { return Color(light: 0x00838F, dark: 0x26A9B5) }
        let palette: [Color] = [Color(light: 0xC2185B, dark: 0xE04A86), Color(light: 0x6D4C41, dark: 0xA07B6E),
                                Color(light: 0x3949AB, dark: 0x6F7FE0)]
        return palette[abs(n.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count]
    }
}

extension Format {
    /// "1:42.30" — minutes, seconds and hundredths.
    static func clock(_ t: Double) -> String {
        let safe = t.isFinite ? max(0, t) : 0
        let cs = Int((safe * 100).rounded())
        return String(format: "%d:%02d.%02d", cs / 6000, cs / 100 % 60, cs % 100)
    }
}
