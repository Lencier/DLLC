import AppKit
import DLLCCore
import SwiftUI

/// Editor-style timeline: ruler, section blocks, the song's waveform and markers.
/// Select tool (V): drag blocks to move them, drag their edges to resize, drag over empty space in the Sections
/// lane to box-select several blocks (like Premiere), drag or click on the song to move the playhead. Range tool (R): drag across the song to make a
/// new section. Pinch or ⌥-scroll zooms; scrolling pans.
struct CueTimeline: View {
    @Bindable var editor: CueEditor

    static let gutter: CGFloat = 92
    static let rulerH: CGFloat = 26
    static let sectionsH: CGFloat = 54
    static let markersH: CGFloat = 30

    private enum Lane { case ruler, sections, wave, markers }
    private enum Drag {
        case scrub
        case move(id: UUID, grabOffset: Double)
        case resize(id: UUID, leftEdge: Bool)
        case newRange(anchor: Double)
        case marker(index: Int)
        /// Box selection: blocks the box touches join `base` (what was selected before, kept with ⇧ or ⌘).
        case marquee(anchor: CGPoint, base: Set<UUID>)
    }

    @State private var drag: Drag?
    @State private var dragMoved = false
    @State private var draft: TimeRange?
    @State private var marqueeRect: CGRect?
    @State private var snapLine: Double?
    @State private var hover: CGPoint?
    @State private var lastClick: (time: Date, point: CGPoint)?

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - Self.gutter)
            HStack(spacing: 0) {
                labels(height: geo.size.height)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in draw(ctx, size: size) }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { changed($0, height: geo.size.height) }
                            .onEnded { ended($0, height: geo.size.height) })
                        .onContinuousHover { phase in
                            if case .active(let p) = phase { hover = p; setCursor(p, height: geo.size.height) }
                            else { hover = nil; NSCursor.arrow.set() }
                        }
                        .contextMenu { contextMenu(height: geo.size.height) }
                    CuePlayhead(editor: editor, height: geo.size.height)
                    ScrollZoomCatcher { event in
                        switch event {
                        case .zoom(let f, let x): editor.zoom(by: f, anchorX: x)
                        case .pan(let dx): editor.scroll(byPixels: dx)
                        }
                    }
                }
                .clipped()
                .onAppear { editor.viewWidth = width }
                .onChange(of: width) { _, w in editor.viewWidth = w }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .popover(isPresented: Binding(get: { editor.renaming != nil }, set: { if !$0 { editor.renaming = nil } }),
                 attachmentAnchor: .point(renameAnchor), arrowEdge: .bottom) {
            if let id = editor.renaming { RenamePopover(editor: editor, sectionID: id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline")
    }

    // MARK: Layout

    private func lane(_ y: CGFloat, height: CGFloat) -> Lane {
        if y < Self.rulerH { return .ruler }
        if y < Self.rulerH + Self.sectionsH { return .sections }
        if y > height - Self.markersH { return .markers }
        return .wave
    }

    private func waveRect(_ size: CGSize) -> CGRect {
        CGRect(x: 0, y: Self.rulerH + Self.sectionsH, width: size.width,
               height: max(10, size.height - Self.rulerH - Self.sectionsH - Self.markersH))
    }

    private var renameAnchor: UnitPoint {
        guard let id = editor.renaming, let s = editor.song?.sections.first(where: { $0.id == id }) else { return .center }
        let mid = (editor.x(s.start) + editor.x(s.end)) / 2
        return UnitPoint(x: (Self.gutter + mid) / (Self.gutter + editor.viewWidth), y: 0.2)
    }

    private func labels(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Self.rulerH)
            laneLabel("Sections", "rectangle.split.3x1").frame(height: Self.sectionsH)
            laneLabel("Song", "waveform").frame(maxHeight: .infinity)
            laneLabel("Markers", "diamond").frame(height: Self.markersH)
        }
        .frame(width: Self.gutter)
        .background(.bar)
        .overlay(alignment: .trailing) { Divider() }
    }

    private func laneLabel(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 8)
            .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Hit testing

    private func hitSection(_ p: CGPoint) -> (SongSection, edge: Bool?)? {
        guard let song = editor.song else { return nil }
        for s in song.sections {
            let x0 = editor.x(s.start), x1 = editor.x(s.end)
            let grab = min(7, (x1 - x0) / 3)
            if p.x >= x0 - 3 && p.x <= x1 + 3 {
                if abs(p.x - x0) <= grab { return (s, true) }
                if abs(p.x - x1) <= grab { return (s, false) }
                if p.x > x0 && p.x < x1 { return (s, nil) }
            }
        }
        return nil
    }

    private func hitMarker(_ p: CGPoint) -> Int? {
        editor.song?.markers.indices.min { abs(editor.x(editor.song!.markers[$0]) - p.x) < abs(editor.x(editor.song!.markers[$1]) - p.x) }
            .flatMap { abs(editor.x(editor.song!.markers[$0]) - p.x) <= 6 ? $0 : nil }
    }

    private func setCursor(_ p: CGPoint, height: CGFloat) {
        switch lane(p.y, height: height) {
        case .sections where editor.tool == .select:
            if let hit = hitSection(p) { (hit.edge != nil ? NSCursor.resizeLeftRight : NSCursor.openHand).set() }
            else { NSCursor.arrow.set() }
        case .markers where hitMarker(p) != nil: NSCursor.resizeLeftRight.set()
        case .sections, .wave: (editor.tool == .range ? NSCursor.crosshair : NSCursor.arrow).set()
        default: NSCursor.arrow.set()
        }
    }

    // MARK: Gestures

    private func changed(_ v: DragGesture.Value, height: CGFloat) {
        let t = editor.time(v.location.x)
        if drag == nil {
            // Clicking the timeline takes focus away from the lyrics, so the shortcut keys work again.
            if let w = NSApp.keyWindow, w.firstResponder is NSText { w.makeFirstResponder(nil) }
            dragMoved = false
            begin(at: v.startLocation, height: height)
        }
        if abs(v.translation.width) > 3 || abs(v.translation.height) > 3 { dragMoved = true }
        guard let drag else { return }
        switch drag {
        case .scrub:
            editor.player.seek(t)
        case .move(let id, let grab):
            guard dragMoved, let s = editor.song?.sections.first(where: { $0.id == id }) else { return }
            var start = t - grab
            let len = s.end - s.start
            let a = editor.snapped(start, ignoring: id), b = editor.snapped(start + len, ignoring: id)
            if let sa = a.snappedTo, abs(sa - start) <= abs((b.snappedTo ?? .infinity) - (start + len)) { start = sa; snapLine = sa }
            else if let sb = b.snappedTo { start = sb - len; snapLine = sb }
            else { snapLine = nil }
            editor.edit(nil) { $0.move(id, toStart: start) }
        case .resize(let id, let left):
            guard dragMoved, var s = editor.song?.sections.first(where: { $0.id == id }) else { return }
            let snapped = editor.snapped(t, ignoring: id)
            snapLine = snapped.snappedTo
            if left { s.start = min(snapped.time, s.end - 0.05) } else { s.end = max(snapped.time, s.start + 0.05) }
            editor.edit(nil) { $0.update(s) }
        case .newRange(let anchor):
            guard dragMoved else { return }
            let snapped = editor.snapped(t)
            snapLine = snapped.snappedTo
            draft = TimeRange(start: min(anchor, snapped.time), end: max(anchor, snapped.time))
        case .marquee(let anchor, let base):
            guard dragMoved else { return }
            let r = CGRect(x: min(anchor.x, v.location.x), y: min(anchor.y, v.location.y),
                           width: abs(v.location.x - anchor.x), height: abs(v.location.y - anchor.y))
            marqueeRect = r
            let t0 = editor.time(r.minX), t1 = editor.time(r.maxX)
            let hit = (editor.song?.sections ?? []).filter { $0.end > t0 && $0.start < t1 }.map(\.id)
            editor.selected = base.union(hit)
            editor.selectedMarker = nil
        case .marker(let i):
            guard dragMoved else { return }
            let snapped = editor.snapped(t, ignoringMarker: i)
            snapLine = snapped.snappedTo
            editor.edit(nil, timesToLyrics: false) { $0.moveMarker(at: i, to: snapped.time) }
            // Markers stay sorted, so after passing another one this marker's index changes: follow it.
            let now = editor.song?.markers.firstIndex { abs($0 - snapped.time) < 0.0001 }
            editor.selectedMarker = now
            if let now, now != i { self.drag = .marker(index: now) }
        }
    }


    private func begin(at p: CGPoint, height: CGFloat) {
        dragStartSong = editor.song
        let t = editor.time(p.x)
        switch lane(p.y, height: height) {
        case .ruler:
            drag = .scrub
            editor.player.seek(t)
        case .sections:
            if editor.tool == .select, let hit = hitSection(p) {
                if let edge = hit.edge { drag = .resize(id: hit.0.id, leftEdge: edge) }
                else { drag = .move(id: hit.0.id, grabOffset: t - hit.0.start) }
            } else if editor.tool == .range {
                drag = .newRange(anchor: editor.snapped(t).time)
            } else {
                drag = .marquee(anchor: p, base: Self.keepsSelection ? editor.selected : [])
            }
        case .wave:
            // Select tool: dragging over the song moves the playhead along with the mouse (box-select is in
            // the Sections lane, where the blocks are).
            if editor.tool == .range { drag = .newRange(anchor: editor.snapped(t).time) }
            else { drag = .scrub; editor.player.seek(t) }
        case .markers:
            if let i = hitMarker(p) { drag = .marker(index: i); editor.selectedMarker = i; editor.selected = [] }
            else { drag = .scrub; editor.player.seek(t) }
        }
    }

    @State private var dragStartSong: Song?

    /// ⇧ or ⌘ while box-selecting adds to the current selection instead of replacing it.
    private static var keepsSelection: Bool { !NSEvent.modifierFlags.intersection([.shift, .command]).isEmpty }

    private func ended(_ v: DragGesture.Value, height: CGFloat) {
        defer { drag = nil; draft = nil; snapLine = nil; dragStartSong = nil; marqueeRect = nil }
        let p = v.location
        let doubleClick = !dragMoved && lastClick.map { Date().timeIntervalSince($0.time) < NSEvent.doubleClickInterval
            && hypot($0.point.x - p.x, $0.point.y - p.y) < 5 } == true
        lastClick = dragMoved ? nil : (Date(), p)
        guard let drag else { return }
        switch drag {
        case .move(let id, _), .resize(let id, _):
            if dragMoved { commitUndo("Move Section") }
            else if doubleClick { editor.selected = [id]; editor.renaming = id }
            else { editor.click(section: id, modifiers: NSEvent.modifierFlags) }
        case .newRange:
            if dragMoved, let r = draft, r.duration * editor.pps >= 4 { editor.addSection(r) }
            else if !dragMoved {
                if !NSEvent.modifierFlags.contains(.command) { editor.selected = [] }
                editor.selectedMarker = nil
                editor.player.seek(editor.time(p.x))
            }
        case .marquee:
            // A plain click (no box) moves the playhead and clears the selection, as before.
            if !dragMoved {
                if !Self.keepsSelection { editor.selected = [] }
                editor.selectedMarker = nil
                editor.player.seek(editor.time(p.x))
            }
        case .marker:
            if dragMoved { commitUndo("Move Marker") }
        case .scrub:
            if !dragMoved, lane(p.y, height: height) == .markers, doubleClick {
                editor.edit("Add Marker", timesToLyrics: false) { $0.addMarker(editor.time(p.x)) }
            } else if !dragMoved, lane(p.y, height: height) != .ruler {
                if !Self.keepsSelection { editor.selected = [] }
                editor.selectedMarker = nil
            }
        }
    }

    /// Live drags edit the song without undo steps; one step is recorded when the drag ends.
    private func commitUndo(_ name: String) {
        guard let before = dragStartSong, let after = editor.song, before != after else { return }
        editor.model?.updateSong(before)
        editor.edit(name, timesToLyrics: true) { $0 = after }
    }

    // MARK: Context menu

    @ViewBuilder private func contextMenu(height: CGFloat) -> some View {
        if let p = hover, lane(p.y, height: height) == .sections, let hit = hitSection(p) {
            let s = hit.0
            Menu("Rename") {
                ForEach(CueEditor.presetNames, id: \.self) { n in Button(n) { editor.rename(s.id, to: n) } }
                Divider()
                Button("Other…") { editor.selected = [s.id]; editor.renaming = s.id }
            }
            Button("Play Section") { editor.player.play(from: s.start, until: s.end) }
            Button("Copy Times") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(LyricSheet.heading(s), forType: .string)
            }
            Divider()
            Button("Set Start to Playhead") { var c = s; c.start = editor.player.currentTime; editor.edit("Edit Section") { $0.update(c) } }
            Button("Set End to Playhead") { var c = s; c.end = editor.player.currentTime; editor.edit("Edit Section") { $0.update(c) } }
            Button("Split at Playhead") { editor.splitAtPlayhead() }
            Divider()
            Button("Delete Section", role: .destructive) { editor.edit("Delete Section") { $0.removeSection(s.id) }; editor.selected.remove(s.id) }
        } else if let p = hover, lane(p.y, height: height) == .markers, let i = hitMarker(p) {
            Button("Delete Marker", role: .destructive) { editor.edit("Delete Marker", timesToLyrics: false) { $0.removeMarker(at: i) } }
        } else {
            Button("Add Marker at Playhead") { editor.addMarkerAtPlayhead() }
            Button("Zoom to Fit") { editor.fit() }
        }
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, size: CGSize) {
        guard let song = editor.song else { return }
        let w = size.width
        drawRuler(ctx, width: w)
        let wave = waveRect(size)
        // Lane separators.
        for y in [Self.rulerH, Self.rulerH + Self.sectionsH, wave.maxY] {
            ctx.fill(Path(CGRect(x: 0, y: y - 0.5, width: w, height: 1)), with: .color(.primary.opacity(0.08)))
        }
        // Section bands over the waveform (faint) and blocks.
        for s in song.sections where editor.x(s.end) > 0 && editor.x(s.start) < w {
            let x0 = editor.x(s.start), x1 = editor.x(s.end)
            let color = SectionColor.of(s.name)
            let on = editor.selected.contains(s.id)
            ctx.fill(Path(CGRect(x: x0, y: wave.minY, width: x1 - x0, height: wave.height)), with: .color(color.opacity(on ? 0.16 : 0.07)))
            let block = CGRect(x: x0 + 1, y: Self.rulerH + 7, width: max(2, x1 - x0 - 2), height: Self.sectionsH - 14)
            let shape = Path(roundedRect: block, cornerRadius: 7)
            ctx.fill(shape, with: .linearGradient(Gradient(colors: [color.opacity(on ? 1 : 0.85), color.opacity(on ? 0.82 : 0.62)]),
                                                 startPoint: CGPoint(x: 0, y: block.minY), endPoint: CGPoint(x: 0, y: block.maxY)))
            ctx.stroke(shape, with: .color(on ? .white : .white.opacity(0.18)), lineWidth: on ? 2 : 1)
            if block.width > 26 {
                // Edge grips.
                for gx in [block.minX + 4, block.maxX - 6] {
                    ctx.fill(Path(roundedRect: CGRect(x: gx, y: block.midY - 7, width: 2, height: 14), cornerRadius: 1), with: .color(.white.opacity(0.45)))
                }
                var c = ctx
                c.clip(to: Path(block.insetBy(dx: 10, dy: 0)))
                c.draw(Text(s.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white),
                       at: CGPoint(x: block.minX + 12, y: block.midY - (block.width > 110 ? 6 : 0)), anchor: .leading)
                if block.width > 110 {
                    c.draw(Text("\(Format.clock(s.start)) – \(Format.clock(s.end))").font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.8)),
                           at: CGPoint(x: block.minX + 12, y: block.midY + 8), anchor: .leading)
                }
            }
        }
        if let d = draft {
            let r = CGRect(x: editor.x(d.start), y: Self.rulerH + 7, width: editor.x(d.end) - editor.x(d.start), height: Self.sectionsH - 14)
            ctx.fill(Path(roundedRect: r, cornerRadius: 7), with: .color(Theme.trim.opacity(0.35)))
            ctx.stroke(Path(roundedRect: r, cornerRadius: 7), with: .color(Theme.trim), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            ctx.fill(Path(CGRect(x: r.minX, y: wave.minY, width: r.width, height: wave.height)), with: .color(Theme.trim.opacity(0.14)))
        }
        drawWave(ctx, rect: wave)
        // Markers.
        let my = size.height - Self.markersH / 2
        for (i, m) in song.markers.enumerated() {
            let mx = editor.x(m)
            guard mx > -8 && mx < w + 8 else { continue }
            let on = editor.selectedMarker == i
            ctx.fill(Path(CGRect(x: mx - 0.5, y: Self.rulerH, width: 1, height: size.height - Self.rulerH - Self.markersH)),
                     with: .color(Theme.attention.opacity(0.35)))
            var d = Path()
            d.move(to: CGPoint(x: mx, y: my - 7)); d.addLine(to: CGPoint(x: mx + 6, y: my))
            d.addLine(to: CGPoint(x: mx, y: my + 7)); d.addLine(to: CGPoint(x: mx - 6, y: my)); d.closeSubpath()
            ctx.fill(d, with: .color(Theme.attention))
            if on { ctx.stroke(d, with: .color(.white), lineWidth: 1.5) }
        }
        if let r = marqueeRect {
            let box = Path(roundedRect: r, cornerRadius: 3)
            ctx.fill(box, with: .color(Theme.info.opacity(0.12)))
            ctx.stroke(box, with: .color(Theme.info.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        if let s = snapLine {
            let sx = editor.x(s)
            ctx.fill(Path(CGRect(x: sx - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(Theme.attention))
        }
    }

    private func drawRuler(_ ctx: GraphicsContext, width: CGFloat) {
        ctx.fill(Path(CGRect(x: 0, y: 0, width: width, height: Self.rulerH)), with: .color(.primary.opacity(0.04)))
        // Pick a label step that leaves ~90 px between labels.
        let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = steps.first { $0 * editor.pps >= 90 } ?? 600
        let minor = step / 5
        var t = (editor.scrollStart / minor).rounded(.down) * minor
        let end = editor.scrollStart + editor.visibleSpan
        while t <= end + minor {
            let x = editor.x(t)
            let major = abs((t / step).rounded() * step - t) < minor / 10
            ctx.fill(Path(CGRect(x: x, y: major ? 12 : 18, width: 1, height: major ? 14 : 8)), with: .color(.primary.opacity(major ? 0.4 : 0.18)))
            if major {
                ctx.draw(Text(rulerLabel(t, step: step)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary),
                         at: CGPoint(x: x + 4, y: 7), anchor: .leading)
            }
            t += minor
        }
    }

    private func rulerLabel(_ t: Double, step: Double) -> String {
        let m = Int(t) / 60, s = t - Double(m * 60)
        return step < 1 ? String(format: "%d:%04.1f", m, s) : String(format: "%d:%02d", m, Int(s.rounded()))
    }

    private func drawWave(_ ctx: GraphicsContext, rect: CGRect) {
        guard let peaks = editor.peaks, !peaks.values.isEmpty else {
            ctx.fill(Path(CGRect(x: 0, y: rect.midY, width: rect.width, height: 1)), with: .color(.secondary.opacity(0.4)))
            return
        }
        let bar: CGFloat = 2, gap: CGFloat = 1
        let n = Int(rect.width / (bar + gap))
        let from = editor.scrollStart, to = min(editor.scrollStart + editor.visibleSpan, peaks.duration)
        guard n > 0, to > from else { return }
        let usable = CGFloat((to - from) * editor.pps)
        let count = max(1, Int(usable / (bar + gap)))
        let values = peaks.slice(from: from, to: to, buckets: count)
        // Plain bars, added as one batch of rectangles. (Hundreds of rounded rectangles in one path were
        // sometimes filled wrongly: part of the song turned into a solid grey block with a slanted edge.)
        let half = rect.height / 2 - 6
        let bars = values.enumerated().map { i, v -> CGRect in
            let h = max(1, CGFloat(v) * half)
            return CGRect(x: CGFloat(i) * (bar + gap), y: rect.midY - h, width: bar, height: h * 2)
        }
        var path = Path()
        path.addRects(bars)
        ctx.fill(path, with: .color(.primary.opacity(0.55)))
    }
}

/// The blue playhead line with its handle. Only this redraws while the song plays.
private struct CuePlayhead: View {
    let editor: CueEditor
    let height: CGFloat
    var body: some View {
        let t = editor.player.currentTime
        let x = editor.x(t)
        ZStack(alignment: .top) {
            Rectangle().fill(Theme.info).frame(width: 1.5, height: height)
            Path { p in
                p.move(to: .zero); p.addLine(to: CGPoint(x: 12, y: 0)); p.addLine(to: CGPoint(x: 12, y: 8))
                p.addLine(to: CGPoint(x: 6, y: 14)); p.addLine(to: CGPoint(x: 0, y: 8)); p.closeSubpath()
            }
            .fill(Theme.info)
            .frame(width: 12, height: 14)
        }
        .frame(width: 12)
        .offset(x: x - 6)
        .opacity(x >= -6 && x <= editor.viewWidth + 6 ? 1 : 0)
        .allowsHitTesting(false)
        .onChange(of: t) { _, new in editor.follow(new) }
    }
}

/// Name a section: presets as one-click chips, or type any name.
private struct RenamePopover: View {
    let editor: CueEditor
    let sectionID: UUID
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Section name").font(.headline)
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { done() }
                .frame(width: 260)
            FlowChips(names: CueEditor.presetNames) { name in text = name; done() }
                .frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel") { editor.renaming = nil }.keyboardShortcut(.cancelAction)
                Button("Done") { done() }.keyboardShortcut(.defaultAction).tint(Theme.accent)
            }
        }
        .padding(14)
        .onAppear {
            text = editor.song?.sections.first { $0.id == sectionID }?.name ?? ""
            focused = true
        }
    }

    private func done() {
        editor.rename(sectionID, to: text)
        editor.renaming = nil
    }
}

private struct FlowChips: View {
    let names: [String]
    let pick: (String) -> Void
    var body: some View {
        let rows = stride(from: 0, to: names.count, by: 4).map { Array(names[$0..<min($0 + 4, names.count)]) }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { n in
                        Button { pick(n) } label: {
                            Text(n).font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(SectionColor.of(n).opacity(0.22)))
                                .foregroundStyle(SectionColor.of(n))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Pinch / ⌥-scroll / ⌘-scroll zooms; any other scroll pans the timeline sideways. Clicks pass through.
struct ScrollZoomCatcher: NSViewRepresentable {
    enum Event { case zoom(Double, x: Double), pan(Double) }
    var handle: (Event) -> Void

    func makeNSView(context: Context) -> CatcherView { let v = CatcherView(); v.handle = handle; return v }
    func updateNSView(_ view: CatcherView, context: Context) { view.handle = handle }

    final class CatcherView: NSView {
        var handle: ((Event) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .scrollWheel?, .magnify?: return super.hitTest(point)
            default: return nil
            }
        }

        override func scrollWheel(with event: NSEvent) {
            let x = convert(event.locationInWindow, from: nil).x
            let precise = event.hasPreciseScrollingDeltas
            let dx = event.scrollingDeltaX * (precise ? 1 : 10), dy = event.scrollingDeltaY * (precise ? 1 : 10)
            if !event.modifierFlags.intersection([.command, .option]).isEmpty {
                handle?(.zoom(exp(Double(dy) * 0.01), x: x))
            } else {
                // Sideways swipe pans; a plain mouse wheel (vertical) pans too.
                handle?(.pan(-Double(abs(dx) > abs(dy) ? dx : dy)))
            }
        }

        override func magnify(with event: NSEvent) {
            handle?(.zoom(1 + Double(event.magnification), x: convert(event.locationInWindow, from: nil).x))
        }
    }
}
