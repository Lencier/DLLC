import AppKit
import DLLCCore
import SwiftUI

/// The song's whole lyrics sheet. "[Verse 1] 01:31 - 01:40" lines are section headings: they are coloured,
/// kept up to date when blocks move, and can create sections ("Sections from Times").
struct CueLyricsPanel: View {
    @Bindable var editor: CueEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Lyrics & Times").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { editor.sectionsFromLyrics() } label: {
                    Label("Sections from Times", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.info)
                .font(.system(size: 12, weight: .medium))
                .help("Make or move sections from the [Name] 01:31 - 01:40 headings below")
            }
            LyricsTextView(text: Binding(get: { editor.song?.lyrics ?? "" },
                                         set: { new in editor.edit(nil, timesToLyrics: false) { $0.lyrics = new } }),
                           sections: editor.song?.sections ?? [],
                           highlighted: editor.selected)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.1)))
                .overlay(alignment: .topLeading) {
                    if (editor.song?.lyrics ?? "").isEmpty {
                        Text("Paste the lyrics here.\n\nHeadings like\n[Verse 1] 01:31 - 01:40\nmark the sections — they fill in by themselves as you add sections on the timeline.")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                            .padding(12).allowsHitTesting(false)
                    }
                }
            Button { editor.copyLyricsAndTimes() } label: {
                Label("Copy Lyrics & Times", systemImage: "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(GlassTileButtonStyle(tint: Theme.info))
            .help("Copy the whole sheet — every section with its times and lyrics")
        }
        .padding(14)
    }
}

/// Plain-text editor that colours section headings and tints the selected sections' lines.
private struct LyricsTextView: NSViewRepresentable {
    @Binding var text: String
    let sections: [SongSection]
    let highlighted: Set<UUID>

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: 13)
        tv.textContainerInset = NSSize(width: 8, height: 10)
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5)
        scroll.hasVerticalScroller = true
        tv.string = text
        context.coordinator.restyle(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text, !context.coordinator.editing {
            let sel = tv.selectedRanges
            tv.string = text
            tv.selectedRanges = sel.filter { $0.rangeValue.upperBound <= (text as NSString).length }
        }
        let key = highlighted.sorted { $0.uuidString < $1.uuidString }.map(\.uuidString).joined()
        if context.coordinator.styledText != tv.string || context.coordinator.styledKey != key {
            context.coordinator.restyle(tv)
            if context.coordinator.styledKey != key { context.coordinator.scrollToHighlight(tv) }
            context.coordinator.styledKey = key
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LyricsTextView
        var editing = false
        var styledText = ""
        var styledKey = ""
        private var firstHighlight: NSRange?

        init(_ p: LyricsTextView) { parent = p }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            editing = true
            parent.text = tv.string
            editing = false
            restyle(tv)
        }

        /// esc leaves the lyrics so Space, ⌫ and the other shortcuts go back to the timeline.
        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            tv.window?.makeFirstResponder(nil)
            return true
        }

        func restyle(_ tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns = tv.string as NSString
            let all = NSRange(location: 0, length: ns.length)
            storage.beginEditing()
            storage.setAttributes([.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor], range: all)
            let heads = LyricSheet.headings(tv.string)
            var lineStarts: [Int] = [0]
            ns.enumerateSubstrings(in: all, options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
                lineStarts.append(enclosing.upperBound)
            }
            firstHighlight = nil
            let chosen = parent.sections.filter { parent.highlighted.contains($0.id) }
            for (k, h) in heads.enumerated() where h.line < lineStarts.count {
                let lineStart = lineStarts[h.line]
                let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
                let color = NSColor(SectionColor.of(h.name))
                if let close = ns.range(of: "]", range: lineRange).toOptional {
                    storage.addAttributes([.foregroundColor: color, .font: NSFont.systemFont(ofSize: 13, weight: .bold)],
                                          range: NSRange(location: lineRange.location, length: close.upperBound - lineRange.location))
                    let rest = NSRange(location: close.upperBound, length: lineRange.upperBound - close.upperBound)
                    storage.addAttributes([.foregroundColor: NSColor.systemBlue,
                                           .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)], range: rest)
                }
                // Tint the whole block (heading to next heading) of a selected section.
                if chosen.contains(where: { $0.name.caseInsensitiveCompare(h.name) == .orderedSame }) {
                    let end = k + 1 < heads.count && heads[k + 1].line < lineStarts.count ? lineStarts[heads[k + 1].line] : ns.length
                    let block = NSRange(location: lineRange.location, length: max(0, end - lineRange.location))
                    storage.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.16), range: block)
                    if firstHighlight == nil { firstHighlight = block }
                }
            }
            storage.endEditing()
            styledText = tv.string
        }

        func scrollToHighlight(_ tv: NSTextView) {
            if let r = firstHighlight { tv.scrollRangeToVisible(r) }
        }
    }
}

private extension NSRange {
    var toOptional: NSRange? { location == NSNotFound ? nil : self }
}
