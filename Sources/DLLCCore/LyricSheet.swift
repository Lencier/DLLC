import Foundation

/// The lyrics sheet for a whole song. Lines such as "[Verse 1] 01:31 - 01:40" mark sections;
/// everything else is lyrics. Labels often send lyrics in this form, so it can be pasted straight in.
public enum LyricSheet {
    public struct Heading: Equatable, Sendable {
        public var name: String
        public var start: Double?
        public var end: Double?
        public var line: Int
    }

    private static let time = #"(\d{1,2}:\d{2}:\d{2}(?:\.\d{1,3})?|\d{1,3}:\d{2}(?:\.\d{1,3})?)"#
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\s*\[([^\]]+)\]\s*(?:"# + time + #"\s*(?:[-–—~]\s*"# + time + #")?)?\s*$"#)

    /// "01:31", "1:31.25", "1:02:03" → seconds.
    public static func seconds(_ s: String) -> Double? {
        let parts = s.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts { guard let v = Double(p) else { return nil }; total = total * 60 + v }
        return total
    }

    /// "01:31", or "01:31.25" when not on a whole second.
    public static func stamp(_ t: Double) -> String {
        let safe = max(0, t.isFinite ? t : 0)
        let cs = Int((safe * 100).rounded())
        let whole = cs / 100, frac = cs % 100
        let h = whole / 3600, m = whole / 60 % 60, sec = whole % 60
        let clock = h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
        return frac == 0 ? clock : clock + String(format: ".%02d", frac)
    }

    public static func headings(_ text: String) -> [Heading] {
        var out: [Heading] = []
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let ns = raw as NSString
            guard let m = pattern.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { continue }
            let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            // "[01:50.20] words" is a timed lyric line (LRC), not a section.
            guard !name.isEmpty, seconds(name) == nil else { continue }
            func t(_ k: Int) -> Double? { m.range(at: k).location == NSNotFound ? nil : seconds(ns.substring(with: m.range(at: k))) }
            out.append(Heading(name: name, start: t(2), end: t(3), line: i))
        }
        return out
    }

    /// Sections described by the sheet's timed headings. A heading without an end runs to the next
    /// heading's start (or the end of the song).
    public static func sections(_ text: String, duration: Double) -> [(name: String, start: Double, end: Double)] {
        let timed = headings(text).filter { $0.start != nil }
        return timed.enumerated().compactMap { i, h in
            let start = h.start!
            let end = h.end ?? (i + 1 < timed.count ? timed[i + 1].start! : duration)
            return end > start ? (h.name, start, min(end, duration > 0 ? duration : end)) : nil
        }
    }

    /// The sheet with each section's heading showing its current times. Headings are matched by name in
    /// order; sections the sheet doesn't mention yet are added at the end.
    public static func withTimes(_ text: String, sections: [SongSection]) -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        var unused = sections.sorted { $0.start < $1.start }
        for h in headings(text) {
            guard let k = unused.firstIndex(where: { $0.name.caseInsensitiveCompare(h.name) == .orderedSame }) else { continue }
            let s = unused.remove(at: k)
            let indent = String(lines[h.line].prefix { $0 == " " || $0 == "\t" })
            lines[h.line] = indent + heading(s)
        }
        if !unused.isEmpty {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            for s in unused { lines.append(heading(s)); lines.append("") }
            if lines.last == "" { lines.removeLast() }
        }
        return lines.joined(separator: "\n")
    }

    public static func heading(_ s: SongSection) -> String { "[\(s.name)] \(stamp(s.start)) - \(stamp(s.end))" }

    /// Renames the first heading called `old` to `new`, keeping its line (and the lyrics under it).
    public static func renaming(_ text: String, from old: String, to new: String) -> String {
        guard let h = headings(text).first(where: { $0.name.caseInsensitiveCompare(old) == .orderedSame }) else { return text }
        var lines = text.components(separatedBy: "\n")
        lines[h.line] = lines[h.line].replacingOccurrences(of: "[" + h.name + "]", with: "[" + new + "]")
        return lines.joined(separator: "\n")
    }

    /// Takes the times off the first timed heading called `name` ("[Hook 1] 01:00 - 01:10" → "[Hook 1]"),
    /// so a deleted section isn't made again by "Sections from Times". Its lyrics stay.
    public static func clearingTimes(_ text: String, name: String) -> String {
        guard let h = headings(text).first(where: { $0.start != nil && $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { return text }
        var lines = text.components(separatedBy: "\n")
        let indent = String(lines[h.line].prefix { $0 == " " || $0 == "\t" })
        lines[h.line] = indent + "[" + h.name + "]"
        return lines.joined(separator: "\n")
    }
}

extension Song {
    /// Makes or moves sections from the lyrics sheet's timed headings. Sections the sheet doesn't
    /// mention are kept; anything that would overlap is trimmed to fit.
    public mutating func syncSectionsFromLyrics() {
        var existing = sections
        var result: [SongSection] = []
        for item in LyricSheet.sections(lyrics, duration: duration) {
            if let k = existing.firstIndex(where: { $0.name.caseInsensitiveCompare(item.name) == .orderedSame }) {
                var s = existing.remove(at: k)
                s.start = item.start; s.end = item.end
                result.append(s)
            } else {
                result.append(SongSection(name: item.name, start: item.start, end: item.end))
            }
        }
        replaceSections(result + existing)
    }

    /// Puts each section's current times into the lyrics sheet. With the sections from before the change,
    /// a renamed section renames its heading and a deleted section's heading loses its times (lyrics kept).
    public mutating func writeTimesToLyrics(previous: [SongSection]? = nil) {
        if let previous {
            for old in previous {
                if let now = sections.first(where: { $0.id == old.id }) {
                    if now.name != old.name { lyrics = LyricSheet.renaming(lyrics, from: old.name, to: now.name) }
                } else if !sections.contains(where: { $0.name.caseInsensitiveCompare(old.name) == .orderedSame }) {
                    lyrics = LyricSheet.clearingTimes(lyrics, name: old.name)
                }
            }
        }
        lyrics = LyricSheet.withTimes(lyrics, sections: sections)
    }

    /// Replaces all sections; earlier-listed sections win where two overlap.
    public mutating func replaceSections(_ list: [SongSection]) {
        removeAllSections()
        for s in list { insert(s) }
    }
}
