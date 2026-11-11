import AppKit
import DLLCCore
import SwiftUI

/// Design tokens: a deep orange-tinged red for actions and the trim range (matching the logo's red), distinct state
/// colors (always paired with an icon + label). Light values keep ≥4.5:1 contrast on white; dark values on the
/// dark window background.
enum Theme {
    static let accent = Color(light: 0xC0261A, dark: 0xF0452F)
    /// In/Out handles, the kept range and the frame number: bright, on dark thumbnails.
    static let trim = Color(light: 0xD8321F, dark: 0xE8402A)
    /// Neutral "in progress / ready" information, kept apart from the action color.
    static let info = Color(light: 0x0A6CD6, dark: 0x4FA3FF)
    static let processing = Color(light: 0x8E3FD9, dark: 0xBF8CFF)
    static let success = Color(light: 0x1F8A4C, dark: 0x4CD38A)
    static let attention = Color(light: 0xB25E00, dark: 0xFFB547)
    static let error = Color(light: 0xC62828, dark: 0xFF6B6B)
    static let brand = Color(light: 0xD7111B, dark: 0xFF3B3B)

    /// Folder colors for projects, picked by the project's id so a project keeps its color.
    static let projectPalette: [Color] = [
        Color(light: 0x0A6CD6, dark: 0x4FA3FF), Color(light: 0x8E3FD9, dark: 0xBF8CFF),
        Color(light: 0xD1366B, dark: 0xFF7AA8), Color(light: 0xB25E00, dark: 0xFFB547),
        Color(light: 0x1F8A4C, dark: 0x4CD38A), Color(light: 0x00838F, dark: 0x4DD9E6),
    ]
    static func projectColor(_ id: UUID) -> Color {
        let sum = withUnsafeBytes(of: id.uuid) { $0.reduce(0) { $0 &+ Int($1) } }
        return projectPalette[sum % projectPalette.count]
    }

    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24
    }
    enum Radius {
        static let control: CGFloat = 8, thumb: CGFloat = 6, preview: CGFloat = 12
    }
    enum Motion {
        static let hover = 0.10, state = 0.15, reveal = 0.18
    }

    static func animation(_ duration: Double, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: duration)
    }
}

extension Color {
    /// Dynamic color resolving per appearance (light/dark, increased contrast handled by the system palette).
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Visual treatment for each job state (icon + label + tint; color never stands alone).
struct StateStyle {
    let symbol: String
    let label: String
    let tint: Color

    static func of(_ job: Job) -> StateStyle {
        switch job.state {
        case .analyzing: return StateStyle(symbol: "magnifyingglass", label: "Analyzing link…", tint: .secondary)
        case .needsSelection: return StateStyle(symbol: "square.stack", label: "Choose items", tint: Theme.accent)
        case .ready: return StateStyle(symbol: "arrow.down.circle", label: "Ready", tint: Theme.info)
        case .queued: return StateStyle(symbol: "clock", label: "Queued", tint: Theme.attention)
        case .downloading: return StateStyle(symbol: "arrow.down.circle.fill", label: job.progress?.stage ?? "Downloading", tint: Theme.info)
        case .processing: return StateStyle(symbol: "gearshape.2", label: job.progress?.stage ?? "Processing", tint: Theme.processing)
        case .completed: return StateStyle(symbol: "checkmark.circle.fill", label: "Saved", tint: Theme.success)
        case .cancelled: return StateStyle(symbol: "xmark.circle", label: "Cancelled", tint: .secondary)
        case .interrupted: return StateStyle(symbol: "arrow.clockwise.circle", label: "Interrupted — restart when ready", tint: Theme.attention)
        case .failed:
            switch job.error?.category {
            case .authRequired: return StateStyle(symbol: "lock", label: "Login required", tint: Theme.attention)
            case .unsupportedURL, .invalidURL: return StateStyle(symbol: "nosign", label: "Unsupported link", tint: .secondary)
            case .drmProtected: return StateStyle(symbol: "lock.shield", label: "Protected content", tint: .secondary)
            default: return StateStyle(symbol: "exclamationmark.circle.fill", label: job.error?.message ?? "Failed", tint: Theme.error)
            }
        }
    }
}

extension Platform {
    var symbol: String {
        switch self {
        case .youtube: "play.rectangle"
        case .instagram: "camera"
        case .pinterest: "pin"
        case .x: "text.bubble"
        case .other: "link"
        }
    }

    /// Each site's own color, so rows are easy to tell apart at a glance.
    var tint: Color {
        switch self {
        case .youtube: Color(light: 0xE00020, dark: 0xFF4A5A)
        case .instagram: Color(light: 0xC1307C, dark: 0xFF6FB5)
        case .pinterest: Color(light: 0xC8001F, dark: 0xFF5A6E)
        case .x: .primary
        case .other: Theme.info
        }
    }
}

enum Format {
    static func duration(_ s: Double?) -> String? {
        guard let s, s.isFinite, s > 0 else { return nil }
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Short human summary of the chosen output, e.g. "Best · 2160p60" or "Clip · 0:12–0:18".
func outputSummary(_ job: Job) -> String {
    if let items = job.info?.directItems, !items.isEmpty { return PinterestPins.summary(items) }
    let o = job.options
    var parts: [String] = []
    switch o.kind {
    case .video:
        parts.append(qualityLabel(o.quality, info: job.info))
        parts.append(o.fileType.label + (o.container == .compatibleMP4 ? " · H.264" : ""))
        if o.compression != .off { parts.append(o.compression.label) }
    case .audio:
        parts.append(o.audioFormat == .mp3 ? "Audio · MP3" : "Audio · Original")
    case .clip:
        parts.append("Clip")
        if let r = o.range { parts.append("\(Timecode.format(r.start))–\(Timecode.format(r.end))") }
        parts.append(o.cutMode == .precise ? "Precise" : "Fast")
    case .gif:
        parts.append("GIF")
        if let r = o.range { parts.append(String(format: "%.1fs", r.duration)) }
        parts.append("\(o.gif.width)px · \(Int(o.gif.fps))fps")
    }
    if let e = o.selectedEntries, e.count == 1, job.info?.isMultiItem != true { parts.append("Item \(e[0])") }
    return parts.joined(separator: " · ")
}

func qualityLabel(_ q: QualityChoice, info: MediaInfo?) -> String {
    switch q {
    case .best:
        if let b = info?.bestQuality { return "Best · \(b.label)" }
        return "Best"
    case .option(let id, _, _, _):
        return info?.qualityOptions.first { $0.id == id }?.label ?? id
    }
}
