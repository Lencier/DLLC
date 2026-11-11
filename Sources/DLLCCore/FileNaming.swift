import Foundation

public enum FileNaming {
    public static func sanitize(_ name: String, maxBytes: Int = 180) -> String {
        // "/" and ":" are path separators on macOS → "-". Only Cc control characters are dropped:
        // format characters (ZWJ, Thai/Indic marks) must survive or emoji and scripts break.
        let mapped = name.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if scalar == "/" || scalar == ":" { return "-" }
            if scalar.properties.isWhitespace { return " " }
            return scalar.properties.generalCategory == .control ? nil : scalar
        }
        let cleaned = String(String.UnicodeScalarView(mapped)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". -"))
        let source = cleaned.isEmpty ? "Untitled" : cleaned
        var result = "", count = 0
        for character in source {
            let bytes = String(character).utf8.count
            guard count + bytes <= max(0, maxBytes) else { break }
            result.append(character); count += bytes
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return trimmed.isEmpty ? String("Untitled".prefix(max(0, min(8, maxBytes)))) : trimmed
    }
    public static func uniqueURL(in directory: URL, baseName: String, ext: String, fileManager: FileManager = .default) -> URL {
        let name = sanitize(baseName)
        let suffix = sanitize(ext, maxBytes: 30)
        var index = 1
        while true {
            let component = name + (index == 1 ? "" : " (\(index))") + (ext.isEmpty || suffix.isEmpty ? "" : ".\(suffix)")
            let url = directory.appendingPathComponent(component)
            if !fileManager.fileExists(atPath: url.path) && (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil { return url }
            index += 1
        }
    }
    public static func timeTag(_ seconds: Double) -> String { Timecode.format(seconds).replacingOccurrences(of: ":", with: "-") }
    public static func rangeTag(_ range: TimeRange) -> String { "\(timeTag(range.start))–\(timeTag(range.end))" }
}

public enum Timecode {
    /// Frame-accurate timecode "MM:SS:FF" (or "H:MM:SS:FF"): whole seconds of real time plus the frame within
    /// that second, so it never drifts at fractional rates like 29.97.
    public static func frames(_ seconds: Double, fps: Double) -> (clock: String, frame: String) {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        let whole = Int64(min(safe, Double(Int64.max / 2)).rounded(.down))
        let perSecond = max(1, Int(fps.rounded(.up)))
        let f = min(perSecond - 1, Int(((safe - Double(whole)) * fps + 1e-6).rounded(.down)))
        let h = whole / 3600, m = whole / 60 % 60, s = whole % 60
        let clock = h > 0 ? String(format: "%lld:%02lld:%02lld", h, m, s) : String(format: "%02lld:%02lld", m, s)
        return (clock, String(format: perSecond > 100 ? "%03d" : "%02d", f))
    }

    public static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var result: Double = 0
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                  part.filter({ $0 == "." }).count <= 1,
                  (index == parts.count - 1 || !part.contains(".")),
                  let value = Double(part), value.isFinite, value >= 0,
                  (index == 0 || value < 60) else { return nil }
            result = result * 60 + value
        }
        return result.isFinite ? result : nil
    }
    public static func format(_ seconds: Double, alwaysHours: Bool = false) -> String {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        // Stay below Int64's boundary even after millisecond rounding.
        let milliseconds = Int64(min(safe * 1000, Double(Int64.max / 2)).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60_000 % 60
        let secs = milliseconds / 1000 % 60
        let millis = milliseconds % 1000
        if alwaysHours || hours > 0 { return String(format: "%lld:%02lld:%02lld.%03lld", hours, minutes, secs, millis) }
        return String(format: "%02lld:%02lld.%03lld", minutes, secs, millis)
    }
}

public enum RangeIssue: Equatable, Sendable {
    case empty, malformedStart, malformedEnd, negative, startNotBeforeEnd, beyondDuration, tooShort
}
public enum RangeValidator {
    public static func validate(start: Double?, end: Double?, duration: Double?, minDuration: Double = 0.05) -> RangeIssue? {
        if start == nil && end == nil { return .empty }
        guard let start, start.isFinite else { return .malformedStart }
        guard let end, end.isFinite else { return .malformedEnd }
        if start < 0 || end < 0 { return .negative }
        if start >= end { return .startNotBeforeEnd }
        if let duration, duration.isFinite, end > duration { return .beyondDuration }
        if end - start + 1e-9 < max(0, minDuration.isFinite ? minDuration : 0.05) { return .tooShort }
        return nil
    }
}
