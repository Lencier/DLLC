import SwiftUI
import DLLCCore

/// Apple's Liquid Glass on macOS 26 and later, a light frosted look before that. Used only on small
/// controls (never on the timeline or anything redrawn while playing), so it stays cheap.
extension View {
    @ViewBuilder
    func glassTile(selected: Bool, tint: Color, radius: CGFloat = 12) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(selected ? Glass.regular.tint(tint.opacity(0.55)).interactive() : Glass.regular.interactive(),
                             in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self.background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selected ? AnyShapeStyle(tint.opacity(0.28)) : AnyShapeStyle(.regularMaterial))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.8) : Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
    }
}

/// A plain button drawn as a glass tile.
struct GlassTileButtonStyle: ButtonStyle {
    var tint: Color
    var selected = false
    var radius: CGFloat = 10
    var padding: CGFloat = 10
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? (selected ? Color.white : tint) : Color.secondary)
            .padding(.horizontal, padding)
            .background {
                // A solid colour under the glass so a turned-on tool is obvious at a glance.
                if selected { RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tint.opacity(0.85)) }
            }
            .glassTile(selected: selected, tint: tint, radius: radius)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: radius))
    }
}

/// A row of choices where the chosen one sits on a glass pill that slides between them.
struct GlassChoice<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    var tint: Color = Theme.accent
    let label: (Value) -> AnyView
    var help: (Value) -> String = { _ in "" }
    /// Colour of the pill for a given choice; `tint` when nil.
    var tintFor: ((Value) -> Color)? = nil
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { value in
                let on = value == selection
                let tint = tintFor?(value) ?? tint
                Button { withAnimation(.snappy(duration: 0.22)) { selection = value } } label: {
                    label(value)
                        .font(.system(size: 12, weight: on ? .semibold : .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .padding(.horizontal, 9)
                        .frame(minWidth: 28, minHeight: 26)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(tint.opacity(0.32))
                                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(tint.opacity(0.7), lineWidth: 1))
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help(value))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .fixedSize()
        .glassTile(selected: false, tint: tint, radius: 10)
    }
}

extension CueSpeed {
    /// Slow is blue, normal (NM) green, fast red — same colours everywhere a speed is shown.
    var tint: Color { self == .x1 ? Theme.success : (isSlow ? Theme.info : Theme.accent) }
    var symbol: String { self == .x1 ? "gauge.with.dots.needle.50percent" : (isSlow ? "tortoise.fill" : "hare.fill") }
}

extension CountInSound {
    var shortLabel: String { self == .woodblock ? "Wood" : label }
    var symbol: String {
        switch self { case .beep: "bell.fill"; case .click: "metronome.fill"; case .woodblock: "music.note" }
    }
    var explanation: String {
        switch self {
        case .beep: "Beep — a clear electronic tone, easy to hear on set"
        case .click: "Click — a short metronome tick"
        case .woodblock: "Wood — a soft woodblock knock"
        }
    }
}
