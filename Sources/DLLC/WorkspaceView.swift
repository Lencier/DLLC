import AVKit
import DLLCCore
import SwiftUI

struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    let jobID: UUID
    let onBack: (() -> Void)?

    var body: some View {
        Group {
            if let controller = model.workspaceController, controller.jobID == jobID, let job = model.engine.job(jobID) {
                if job.info != nil {
                    WorkspaceContent(job: job, player: controller, onBack: onBack)
                } else {
                    waiting(job)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Opened while the link was still being analysed: start the preview as soon as it's ready.
        .onChange(of: model.engine.job(jobID)?.info != nil) { _, ready in
            if ready { model.workspaceController?.start() }
        }
    }

    private func waiting(_ job: Job) -> some View {
        VStack(spacing: Theme.Space.m) {
            if job.state == .analyzing {
                ProgressView()
                Text("Reading the link…").foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(Theme.attention)
                    .accessibilityHidden(true)
                Text(job.error?.message ?? "This link couldn’t be read, so there’s nothing to preview.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            Button("Close Preview") {
                if let onBack { onBack() } else { model.workspaceJobID = nil }
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// True while a text field's editor has keyboard focus.
@MainActor private var isEditingText: Bool { NSApp.keyWindow?.firstResponder is NSTextView }

private struct WorkspaceContent: View {
    @Environment(AppModel.self) private var model
    let job: Job
    @Bindable var player: PlayerController
    let onBack: (() -> Void)?
    @FocusState private var playerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    playerArea
                    SourceBar(player: player)
                    // Every mode keeps the same layout: rows that don't apply are hidden in place rather than
                    // removed, and the mode cards share one size, so switching Clip / Frame / GIF never
                    // moves anything.
                    let usesRange = player.mode != .frame
                    PanelSection("Playback & Range", symbol: "play.square", tint: Theme.trim) {
                        TransportBar(player: player)
                        TrimTimeline(player: player, showsRange: usesRange)
                            .frame(height: 90)
                        TimelineZoomBar(player: player, showsRange: usesRange)
                        Divider()
                        RangeFields(player: player)
                            .opacity(usesRange ? 1 : 0.35)
                            .disabled(!usesRange)
                            .help(usesRange ? "" : "Frame mode saves the frame under the playhead")
                    }
                    ZStack(alignment: .topLeading) {
                        modeCard(.clip) { ClipControls(job: job, player: player) }
                        modeCard(.frame) { FrameControls(job: job, player: player) }
                        modeCard(.gif) { GIFControls(job: job, player: player) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.l)
            }
        }
        .focusable()
        .focused($playerFocused)
        .focusEffectDisabled()
        // Playback keys never apply while a text field is being edited (the field gets them).
        .onKeyPress(.space) { guard !isEditingText else { return .ignored }; player.togglePlay(); return .handled }
        .onKeyPress(.leftArrow) { guard !isEditingText else { return .ignored }; player.step(-1); return .handled }
        .onKeyPress(.rightArrow) { guard !isEditingText else { return .ignored }; player.step(1); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "iIoO"), phases: .down) { press in
            guard !isEditingText else { return .ignored }
            if press.characters.lowercased() == "i" { player.markIn() } else { player.markOut() }
            return .handled
        }
        .onKeyPress(.escape) {
            // Esc first ends editing (restoring the field's value); only then does it leave the workspace.
            if isEditingText {
                player.syncRangeText()
                NSApp.keyWindow?.makeFirstResponder(nil)
                playerFocused = true
                return .handled
            }
            if let onBack { onBack() } else { model.workspaceJobID = nil }
            return .handled
        }
        .onAppear { playerFocused = true }
    }

    /// One mode's card, stacked with the others so the area always has the tallest card's height.
    /// Hidden cards are disabled too, so their keyboard shortcuts can't fire.
    private func modeCard(_ mode: WorkspaceMode, @ViewBuilder _ content: () -> some View) -> some View {
        let shown = player.mode == mode
        return content()
            .frame(maxHeight: .infinity, alignment: .top)
            .opacity(shown ? 1 : 0)
            .disabled(!shown)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            if let onBack {
                Button { onBack() } label: { Label("Queue", systemImage: "chevron.left") }
                    .help("Back to the queue (Esc)")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(job.displayTitle).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text([job.info?.creator, job.info?.platform.displayName].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Picker("Mode", selection: $player.mode) {
                ForEach(WorkspaceMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if onBack == nil {
                Button { model.workspaceJobID = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Close preview")
                    .help("Close preview (Esc)")
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
    }

    private var playerArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.preview).fill(Color.black)
            PlayerSurface(player: player.player) { ready in player.surfaceReady = ready }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.preview))
                .opacity(player.preview == .none ? 0 : 1)
            // Until the video has a frame, show the link's thumbnail instead of a black box.
            if !player.surfaceReady || !player.hasInteracted, let s = job.info?.thumbnailURL, let u = URL(string: s) {
                AsyncImage(url: u) { phase in
                    if let img = phase.image { img.resizable().aspectRatio(contentMode: .fit) } else { Color.clear }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.preview))
                .allowsHitTesting(false)
            }
            if let s = player.status {
                VStack(spacing: Theme.Space.s) {
                    if s.hasPrefix("Preparing") { ProgressView().controlSize(.small) }
                    Text(s).font(.callout).foregroundStyle(.white).multilineTextAlignment(.center)
                }
                .padding()
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            } else if let e = player.previewError {
                Text(e).font(.callout).foregroundStyle(.white).padding()
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            } else if player.preview != .none && !player.isPlaying {
                // Big play button: obvious way to watch before downloading.
                Button { playerFocused = true; player.togglePlay() } label: {
                    ZStack {
                        Circle().fill(.black.opacity(0.55)).frame(width: 72, height: 72)
                        if player.itemLoading {
                            ProgressView().controlSize(.regular).tint(.white)
                        } else {
                            Image(systemName: "play.fill").font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                                .offset(x: 3)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play")
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 460)
        .contentShape(Rectangle())
        .onTapGesture { playerFocused = true; player.togglePlay() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video preview")
        .accessibilityHint("Space plays or pauses. Left and right arrows step one frame. I and O set the range.")
        .accessibilityAddTraits(.startsMediaSession)
    }

    private var aspect: CGFloat {
        if let q = job.info?.bestQuality, let w = q.width, let h = q.height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return 16 / 9
    }
}

/// Bare AVPlayerLayer (we provide frame-accurate transport). Reports when it has a frame to display.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    var onReadyChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        v.onReadyChange = onReadyChange
        return v
    }
    func updateNSView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.onReadyChange = onReadyChange
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    var onReadyChange: (Bool) -> Void = { _ in }
    private var readyObservation: NSKeyValueObservation?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            DispatchQueue.main.async { self?.onReadyChange(ready) }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct SourceBar: View {
    @Bindable var player: PlayerController

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            switch player.preview {
            case .stream(let label):
                Label("\(label)\(player.previewHasAudio ? "" : " · no sound") · Exports use full quality",
                      systemImage: "wifi").foregroundStyle(.secondary)
            case .local:
                Label("Full-quality source · exact frames", systemImage: "checkmark.seal").foregroundStyle(Theme.success)
            case .proxy:
                Label("Preview proxy · Exports use source · exact frames", systemImage: "film").foregroundStyle(.secondary)
            case .none:
                EmptyView()
            }
            Spacer()
            switch player.source {
            case .notLoaded:
                Button("Load Source") { player.loadSource() }
                    .help("Downloads the full-quality video once (cached) for exact frame stepping and faster exports.")
            case .loading(let stage, let fraction):
                if let fraction { ProgressView(value: fraction).frame(width: 80) } else { ProgressView().controlSize(.mini) }
                Text(stage).foregroundStyle(.secondary).lineLimit(1)
                Button("Cancel") { player.cancelSourceLoad() }.buttonStyle(.borderless)
            case .loaded:
                EmptyView()
            case .failed(let msg):
                Text(msg).foregroundStyle(Theme.error).lineLimit(1)
                Button("Retry") { player.cancelSourceLoad(); player.loadSource() }.buttonStyle(.borderless)
            }
        }
        .font(.caption)
        .controlSize(.small)
    }
}

private struct TransportBar: View {
    @Bindable var player: PlayerController

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Button { player.step(-1) } label: { Image(systemName: "backward.frame.fill").frame(width: 22, height: 18) }
                .help("Previous frame (←)").accessibilityLabel("Previous frame")
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 30, height: 18)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .help("Play/Pause (Space)").accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.step(1) } label: { Image(systemName: "forward.frame.fill").frame(width: 22, height: 18) }
                .help("Next frame (→)").accessibilityLabel("Next frame")
            FrameReadout(player: player).fixedSize()
            Spacer(minLength: Theme.Space.s)
            VolumeControl(player: player)
            Text(Timecode.format(player.duration)).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityLabel("Duration \(Timecode.format(player.duration))")
        }
        .controlSize(.large)
        .buttonStyle(.bordered)
    }
}

/// Current position as "MM:SS" + a highlighted frame number, with the frame count and rate underneath.
private struct FrameReadout: View {
    @Bindable var player: PlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let f = player.displayedFrame {
                let tc = Timecode.frames(player.currentTime, fps: f.fps)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(tc.clock).foregroundStyle(.primary)
                    Text(":").foregroundStyle(.tertiary)
                    Text(tc.frame).foregroundStyle(TrimTimeline.trim)
                    Text(" f").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                HStack(spacing: 4) {
                    Text("frame \((f.index + 1).formatted())").monospacedDigit()
                    Text("·")
                    Text("\(Self.rate(f.fps)) fps")
                    if !f.exact {
                        Text("· preview").foregroundStyle(Theme.attention)
                            .help("Frames are estimated from the online preview. Load Source for exact frames.")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text(Timecode.format(player.currentTime))
                    .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current time \(Timecode.format(player.currentTime))")
    }

    static func rate(_ fps: Double) -> String {
        abs(fps - fps.rounded()) < 0.01 ? String(Int(fps.rounded())) : String(format: "%.2f", fps)
    }
}

/// Trimmer: a thumbnail strip with red-orange In/Out handles (always visible) and a draggable playhead.
/// One drag gesture decides at mouse-down what it moves — the handle under the pointer, else the playhead — so
/// handles and scrubbing never fight over the same drag. Zoom with a trackpad pinch, ⌘/⌥-scroll or the zoom bar;
/// pan a zoomed timeline with a sideways two-finger swipe.
struct TrimTimeline: View {
    @Bindable var player: PlayerController
    var showsRange = true
    @State private var dragging: Target?
    /// Time of the grabbed handle at mouse-down, so grabbing a handle never makes it jump.
    @State private var grabTime: Double = 0
    @State private var hoverX: CGFloat?
    enum Target { case inHandle, outHandle, playhead }

    private let handleW: CGFloat = 16
    private let stripTop: CGFloat = 14
    private let stripH: CGFloat = 54
    static let trim = Theme.trim

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width - 2 * handleW)
            let d = max(player.duration, 0.001)
            let vs = player.visibleStart
            let span = max(player.visibleSpan, 0.001)
            let x: (Double) -> CGFloat = { handleW + CGFloat((min(max($0, 0), d) - vs) / span) * w }
            let cx: (Double) -> CGFloat = { min(max(x($0), handleW), handleW + w) }
            let visible: (CGFloat) -> Bool = { $0 >= handleW - 0.5 && $0 <= handleW + w + 0.5 }
            let inT = player.inPoint ?? 0
            let outT = player.outPoint ?? d
            ZStack(alignment: .topLeading) {
                strip(width: w, d: d, vs: vs, span: span)
                    .offset(x: handleW, y: stripTop)
                if showsRange {
                    // Dim what's outside the range.
                    Rectangle().fill(.black.opacity(0.55))
                        .frame(width: max(0, cx(inT) - handleW), height: stripH)
                        .offset(x: handleW, y: stripTop)
                    Rectangle().fill(.black.opacity(0.55))
                        .frame(width: max(0, handleW + w - cx(outT)), height: stripH)
                        .offset(x: cx(outT), y: stripTop)
                    // Red-orange frame around the kept range (open-ended where the range runs off screen).
                    if cx(outT) > cx(inT) {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Self.trim, lineWidth: 3)
                            .frame(width: max(6, cx(outT) - cx(inT)), height: stripH + 6)
                            .offset(x: cx(inT), y: stripTop - 3)
                    }
                    if visible(x(inT)) {
                        handle(chevron: "chevron.compact.left", active: dragging == .inHandle)
                            .offset(x: x(inT) - handleW, y: stripTop - 3)
                        Text(Timecode.format(inT)).font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary).fixedSize()
                            .offset(x: max(0, x(inT) - handleW), y: stripTop + stripH + 6)
                    }
                    if visible(x(outT)) {
                        handle(chevron: "chevron.compact.right", active: dragging == .outHandle)
                            .offset(x: x(outT), y: stripTop - 3)
                        Text(Timecode.format(outT)).font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary).fixedSize()
                            .frame(width: 80, alignment: .trailing)
                            .offset(x: min(geo.size.width - 80, x(outT) + handleW - 80), y: stripTop + stripH + 6)
                    }
                }
                // Hover guide.
                if let hx = hoverX, dragging == nil {
                    Rectangle().fill(.white.opacity(0.35)).frame(width: 1, height: stripH)
                        .offset(x: hx, y: stripTop).allowsHitTesting(false)
                }
                // Playhead with a grab knob on top.
                if visible(x(player.currentTime)) {
                    VStack(spacing: 0) {
                        Circle().fill(.white).frame(width: 12, height: 12)
                            .shadow(color: .black.opacity(0.4), radius: 1.5)
                        Rectangle().fill(.white).frame(width: 2, height: stripH + 4)
                            .shadow(color: .black.opacity(0.5), radius: 1)
                    }
                    .offset(x: x(player.currentTime) - 6, y: stripTop - 12)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragging == nil {
                        dragging = target(at: g.startLocation.x, x: x, visible: visible, inT: inT, outT: outT)
                        grabTime = dragging == .inHandle ? inT : outT
                    }
                    apply(time(for: g, w: w, vs: vs, span: span), d: d, precise: false)
                }
                .onEnded { g in
                    apply(time(for: g, w: w, vs: vs, span: span), d: d, precise: true)
                    dragging = nil
                })
            .onContinuousHover { phase in
                if case .active(let p) = phase, p.x >= handleW, p.x <= handleW + w { hoverX = p.x } else { hoverX = nil }
            }
            .overlay {
                TimelineScrollCatcher { event in
                    let t = vs + Double((event.x - handleW) / w) * span
                    switch event.kind {
                    case .zoom(let factor):
                        player.setZoom(player.zoomFactor * factor, around: min(max(t, 0), d))
                        return true
                    case .pan(let dx):
                        guard player.isZoomed else { return false }
                        player.panTimeline(by: -Double(dx / w) * span)
                        return true
                    }
                }
            }
        }
        .onChange(of: player.currentTime) { _, t in
            if player.isPlaying, dragging == nil { player.revealInTimeline(t) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline")
        .accessibilityValue("\(Timecode.format(player.currentTime)), range \(Timecode.format(player.inPoint ?? 0)) to \(Timecode.format(player.outPoint ?? player.duration))")
        .accessibilityAdjustableAction { dir in player.step(dir == .increment ? 1 : -1) }
        .accessibilityAction(named: "Set In to playhead") { player.markIn() }
        .accessibilityAction(named: "Set Out to playhead") { player.markOut() }
    }

    /// Thumbnails placed by time: the whole-video strip underneath, sharper zoomed-in frames on top when ready.
    @ViewBuilder private func strip(width w: CGFloat, d: Double, vs: Double, span: Double) -> some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.14)], startPoint: .top, endPoint: .bottom)
            thumbs(player.filmstrip, start: 0, length: d, w: w, vs: vs, span: span)
            if player.isZoomed, let z = player.zoomStrip {
                thumbs(z.images, start: z.start, length: z.span, w: w, vs: vs, span: span)
            }
        }
        .frame(width: w, height: stripH, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder private func thumbs(_ frames: [CGImage], start: Double, length: Double, w: CGFloat,
                                     vs: Double, span: Double) -> some View {
        let n = frames.count
        if n > 0 {
            let cell = length / Double(n)
            let cellW = CGFloat(cell / span) * w
            ForEach(0..<n, id: \.self) { i in
                let x0 = CGFloat((start + Double(i) * cell - vs) / span) * w
                if x0 + cellW >= 0, x0 <= w {
                    Image(decorative: frames[i], scale: 1)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: cellW + 0.5, height: stripH)
                        .clipped()
                        .offset(x: x0)
                }
            }
        }
    }

    private func handle(chevron: String, active: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Self.trim)
            Image(systemName: chevron).font(.system(size: 14, weight: .black)).foregroundStyle(.white)
        }
        .frame(width: handleW, height: stripH + 6)
        .scaleEffect(y: active ? 1.08 : 1)
        .shadow(color: .black.opacity(0.35), radius: active ? 4 : 1)
    }

    /// Handles move by how far they're dragged (relative); the playhead jumps to where you click (absolute).
    private func time(for g: DragGesture.Value, w: CGFloat, vs: Double, span: Double) -> Double {
        switch dragging ?? .playhead {
        case .playhead: return vs + Double((g.location.x - handleW) / w) * span
        case .inHandle, .outHandle: return grabTime + Double(g.translation.width / w) * span
        }
    }

    /// A handle is hit only on its drawn orange tab (plus a little slack), so clicks on the strip always scrub.
    private func target(at px: CGFloat, x: (Double) -> CGFloat, visible: (CGFloat) -> Bool,
                        inT: Double, outT: Double) -> Target {
        guard showsRange else { return .playhead }
        let slack: CGFloat = 4
        let inHit = visible(x(inT)) && ((x(inT) - handleW - slack)...(x(inT) + slack)).contains(px)
        let outHit = visible(x(outT)) && ((x(outT) - slack)...(x(outT) + handleW + slack)).contains(px)
        switch (inHit, outHit) {
        case (true, true): return abs(px - (x(inT) - handleW / 2)) <= abs(px - (x(outT) + handleW / 2)) ? .inHandle : .outHandle
        case (true, false): return .inHandle
        case (false, true): return .outHandle
        default: return .playhead
        }
    }

    private func apply(_ raw: Double, d: Double, precise: Bool) {
        let t = max(0, min(d, raw))
        player.hasInteracted = true
        switch dragging ?? .playhead {
        case .playhead:
            player.seek(to: t, precise: precise)
        case .inHandle:
            let limit = (player.outPoint ?? d) - (player.frameDuration(at: t) ?? 0.04)
            player.inPoint = player.frameStart(at: max(0, min(t, limit)))
            player.syncRangeText()
            player.seek(to: player.inPoint!, precise: precise)
            player.revealInTimeline(player.inPoint!)
        case .outHandle:
            let floor = (player.inPoint ?? 0) + (player.frameDuration(at: t) ?? 0.04)
            let end = t >= d - 0.0005 ? d : player.frameEnd(at: max(t, floor) - 1e-4)
            player.outPoint = min(d, max(end, floor))
            player.syncRangeText()
            player.seek(to: max(0, player.outPoint! - 0.001), precise: precise)
            player.revealInTimeline(player.outPoint!)
        }
    }
}

/// Zoom controls under the timeline: an overview of the whole video (drag it to move around) and zoom buttons.
struct TimelineZoomBar: View {
    @Bindable var player: PlayerController
    var showsRange = true

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if player.isZoomed {
                overview
            } else {
                Label("Pinch to zoom", systemImage: "plus.magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help("Pinch on the trackpad or ⌘-scroll over the timeline to zoom; swipe sideways to move along it")
                Spacer(minLength: 0)
            }
            Button { player.setZoom(player.zoomFactor / 2) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(!player.isZoomed)
                .help("Zoom out")
                .accessibilityLabel("Zoom out")
            Slider(value: Binding(
                get: { player.maxZoom > 1 ? log(player.zoomFactor) / log(player.maxZoom) : 0 },
                set: { player.setZoom(exp($0 * log(max(player.maxZoom, 1)))) }), in: 0...1)
                .frame(width: 110)
                .disabled(player.maxZoom <= 1)
                .accessibilityLabel("Timeline zoom")
            Button { player.setZoom(player.zoomFactor * 2) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(player.zoomFactor >= player.maxZoom)
                .help("Zoom in around the playhead")
                .accessibilityLabel("Zoom in")
            Button("Zoom to Range") { player.zoomToRange() }
                .disabled(!showsRange)
                .help("Fill the timeline with the In–Out range")
            Button("Fit") { player.fitTimeline() }
                .disabled(!player.isZoomed)
                .help("Show the whole video")
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }

    /// The whole video in miniature: range in red-orange, the visible part outlined; click or drag to move there.
    private var overview: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let d = max(player.duration, 0.001)
            let px: (Double) -> CGFloat = { CGFloat(min(max($0, 0), d) / d) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if showsRange {
                    Rectangle().fill(TrimTimeline.trim.opacity(0.7))
                        .frame(width: max(2, px(player.outPoint ?? d) - px(player.inPoint ?? 0)))
                        .offset(x: px(player.inPoint ?? 0))
                }
                Rectangle().fill(.white).frame(width: 1.5).offset(x: px(player.currentTime))
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.primary, lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.12)))
                    .frame(width: max(6, px(player.visibleStart + player.visibleSpan) - px(player.visibleStart)))
                    .offset(x: px(player.visibleStart))
            }
            .frame(height: 14)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                player.centerTimeline(on: Double(g.location.x / w) * d)
            })
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline overview")
        .accessibilityValue("Showing \(Timecode.format(player.visibleStart)) to \(Timecode.format(player.visibleStart + player.visibleSpan))")
    }
}

/// Catches trackpad pinches and scroll-wheel events over the timeline (clicks pass straight through to SwiftUI).
/// Pinch or ⌘/⌥-scroll zooms; a sideways swipe pans; plain vertical scrolling goes on to the page.
struct TimelineScrollCatcher: NSViewRepresentable {
    struct Event { enum Kind { case zoom(Double), pan(CGFloat) }; let kind: Kind; let x: CGFloat }
    var handle: (Event) -> Bool

    func makeNSView(context: Context) -> CatcherView { let v = CatcherView(); v.handle = handle; return v }
    func updateNSView(_ view: CatcherView, context: Context) { view.handle = handle }

    final class CatcherView: NSView {
        var handle: ((Event) -> Bool)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .scrollWheel?, .magnify?: return super.hitTest(point)
            default: return nil
            }
        }

        override func scrollWheel(with event: NSEvent) {
            let x = convert(event.locationInWindow, from: nil).x
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            let zoomKey = !event.modifierFlags.intersection([.command, .option]).isEmpty
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            var handled = false
            if zoomKey, dy != 0 {
                handled = handle?(Event(kind: .zoom(exp(Double(dy * scale) * 0.01)), x: x)) ?? false
            } else if abs(dx) > abs(dy), dx != 0 {
                handled = handle?(Event(kind: .pan(dx * scale), x: x)) ?? false
            }
            if !handled { super.scrollWheel(with: event) }
        }

        override func magnify(with event: NSEvent) {
            let x = convert(event.locationInWindow, from: nil).x
            if handle?(Event(kind: .zoom(1 + Double(event.magnification)), x: x)) != true { super.magnify(with: event) }
        }
    }
}

/// Editable In / Out time fields with inline validation (never silently clamped).
private struct RangeFields: View {
    @Bindable var player: PlayerController
    @FocusState private var focus: Field?
    enum Field { case inF, outF }

    var body: some View {
        let issue = currentIssue
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                field("In", text: $player.inText, f: .inF, set: { player.markIn() })
                field("Out", text: $player.outText, f: .outF, set: { player.markOut() })
                Spacer(minLength: 0)
                // Fixed width so the row never shifts as the length changes.
                Text(durationText).font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.trim)
                    .frame(width: 92, height: 22)
                    .background(Capsule().fill(Theme.trim.opacity(0.14)))
                    .help("Length of the In–Out range")
                    .accessibilityLabel("Length \(durationText)")
            }
            HStack(spacing: Theme.Space.s) {
                Button { player.playRange() } label: { Label("Play Range", systemImage: "play.fill") }
                    .buttonStyle(TintedButtonStyle(tint: Theme.trim))
                    .disabled(player.inPoint == nil || player.outPoint == nil)
                Toggle("Loop", isOn: $player.loopRange).toggleStyle(.checkbox)
                    .help("Repeat the In–Out range while previewing")
                    .fixedSize()
                // Problems show in this one-line slot, so nothing below moves when one appears.
                Label(issue ?? " ", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.error)
                    .lineLimit(1).truncationMode(.tail)
                    .opacity(issue == nil ? 0 : 1)
                    .help(issue ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { player.clearRange() } label: { Label("Whole Video", systemImage: "arrow.left.and.right") }
                    .disabled(player.rangeIsWhole)
                    .help("Reset In/Out to the whole video")
            }
            .controlSize(.small)
        }
        .onAppear(perform: sync)
        .onChange(of: player.inPoint) { _, _ in if focus != .inF { sync() } }
        .onChange(of: player.outPoint) { _, _ in if focus != .outF { sync() } }
    }

    private func field(_ label: String, text: Binding<String>, f: Field, set: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
            TextField("0:00.000", text: text)
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 86)
                .focused($focus, equals: f)
                .onSubmit { commit(f) }
                .accessibilityLabel("\(label) time")
            Button("Set") { set() }
                .buttonStyle(TintedButtonStyle(tint: Theme.trim))
                .help("Set \(label) to the playhead (\(label.prefix(1)))")
        }
        .fixedSize()
    }

    private func commit(_ f: Field) {
        guard player.commitRangeText() else { return }
        player.hasInteracted = true
        if f == .inF, let i = player.inPoint { player.seek(to: i, precise: true) }
        sync()
    }

    private func sync() { player.syncRangeText() }

    private var durationText: String {
        guard let i = player.inPoint, let o = player.outPoint, o > i else { return "—" }
        return Timecode.format(o - i)
    }

    private var currentIssue: String? {
        if !player.inText.isEmpty && Timecode.parse(player.inText) == nil { return "In time isn’t valid — use 1:23.5 or 83.5" }
        if !player.outText.isEmpty && Timecode.parse(player.outText) == nil { return "Out time isn’t valid — use 1:23.5 or 83.5" }
        guard player.inPoint != nil || player.outPoint != nil else { return nil }
        let minDur = player.frameDuration(at: player.inPoint ?? 0) ?? 0.04
        switch RangeValidator.validate(start: player.inPoint, end: player.outPoint,
                                       duration: player.duration > 0 ? player.duration : nil, minDuration: minDur * 0.99) {
        case .none: return nil
        case .empty?: return nil
        case .malformedStart?: return "Set an In point."
        case .malformedEnd?: return "Set an Out point."
        case .negative?: return "Times can’t be negative."
        case .startNotBeforeEnd?: return "Out must be after In."
        case .beyondDuration?: return "The range goes past the end of the video (\(Timecode.format(player.duration)))."
        case .tooShort?: return "The range is shorter than one frame."
        }
    }
}

/// The range shown in the In/Out fields, typed drafts included; nil while any field is invalid.
@MainActor private func validRange(_ player: PlayerController) -> TimeRange? { player.draftRange }

/// Applies typed drafts first so the export always matches what the fields show.
@MainActor private func commitAndValidRange(_ player: PlayerController) -> TimeRange? {
    guard player.commitRangeText() else { return nil }
    return validRange(player)
}

/// Original size / Smaller / Smallest, with a one-line explanation of what each does.
struct SizePicker: View {
    @Binding var compression: Compression
    var gif = false
    /// The estimated file for each choice, so you can compare before exporting (nil: not known yet).
    var estimate: ((Compression) -> SizeEstimate?)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Picker("Size", selection: $compression) {
                ForEach(Compression.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            Text(Self.explanation(compression, gif: gif))
                .font(.caption).foregroundStyle(compression == .off ? .secondary : Theme.success)
                .lineLimit(1)
            if let estimate, Compression.allCases.contains(where: { estimate($0) != nil }) {
                estimates(estimate)
            }
        }
    }

    /// "Original ≈ 1.1 GB · Smaller ≈ 310 MB · Smallest ≈ 140 MB", the chosen one in bold.
    private func estimates(_ estimate: (Compression) -> SizeEstimate?) -> some View {
        let parts = Compression.allCases.compactMap { c -> Text? in
            guard let e = estimate(c) else { return nil }
            let name = c == .off ? "Original" : c.label
            let t = Text("\(name) \(e.label)")
            return c == compression ? t.bold().foregroundColor(.primary) : t
        }
        let line = parts.dropFirst().reduce(parts.first ?? Text("")) { $0 + Text("  ·  ") + $1 }
        return line
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.85)
            .help("Estimated file size for each choice — rough: the real size depends on how busy the picture is")
            .accessibilityLabel("Estimated sizes")
    }

    static func explanation(_ c: Compression, gif: Bool) -> String {
        switch (c, gif) {
        case (.off, _): return "Full quality, largest file"
        case (.smaller, false): return "HEVC ≤1080p · usually 3–5× smaller"
        case (.smallest, false): return "HEVC ≤720p · smallest, for chat apps"
        case (.smaller, true): return "128 colours · noticeably smaller"
        case (.smallest, true): return "64 colours, ≤480 px, ≤10 fps · smallest"
        }
    }
}

private struct ClipControls: View {
    @Environment(AppModel.self) private var model
    let job: Job
    @Bindable var player: PlayerController
    @AppStorage("clipCutMode") private var cutMode: CutMode = .precise
    @AppStorage("clipFileType") private var fileType: VideoFileType = .mp4
    @AppStorage("clipCompression") private var compression: Compression = .off

    var body: some View {
        PanelSection("Export Clip", symbol: "scissors", tint: Theme.accent) {
            OptionsGrid {
                OptionRow("Cut") {
                    Picker("Cut", selection: $cutMode) {
                        Text("Precise").tag(CutMode.precise)
                        Text("Fast").tag(CutMode.fast)
                    }
                    .pickerStyle(.segmented).fixedSize().labelsHidden()
                    Text(cutMode == .precise
                         ? "Exact In/Out frames · re-encodes the clip"
                         : "Original quality · cuts snap to nearby keyframes")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                OptionRow("File type") {
                    Picker("File type", selection: $fileType) {
                        ForEach(VideoFileType.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).fixedSize().labelsHidden()
                }
                OptionRow("Size") { SizePicker(compression: $compression, estimate: { estimate($0) }).labelsHidden() }
            }
            Spacer(minLength: 0)
            ExportFooter(summary: rangeSummary(player, extra: [fileType.label, estimate(compression)?.label]
                .compactMap { $0 }.joined(separator: " · "))) {
                Button {
                    guard let r = commitAndValidRange(player) else { return }
                    var o = job.options
                    o.kind = .clip; o.range = r; o.cutMode = cutMode
                    o.fileType = fileType; o.compression = compression
                    guard let folder = model.saveFolder(forProject: job.projectID) else { return }
                    model.engine.addDerived(from: job, options: o, startNow: true, destination: folder)
                    model.show(.info, "Clip added to the queue.")
                } label: { Label("Export Clip", systemImage: "scissors") }
                .disabled(validRange(player) == nil || player.rangeIsWhole)
                .help(player.rangeIsWhole ? "Drag the orange handles to choose part of the video (use Download for the whole video)" : "Export the In–Out range (⌘E)")
                .keyboardShortcut("e", modifiers: .command)
            }
        }
    }

    /// The clip's estimated size with the current In–Out range, cut mode and file type.
    private func estimate(_ c: Compression) -> SizeEstimate? {
        guard let info = job.info, let r = validRange(player) else { return nil }
        var o = job.options
        o.kind = .clip; o.range = r; o.cutMode = cutMode; o.fileType = fileType; o.compression = c
        return SizeModel.video(info: info, options: o, range: r)
    }
}

private struct FrameControls: View {
    @Environment(AppModel.self) private var model
    let job: Job
    @Bindable var player: PlayerController
    @State private var format: ImageFormat = Preferences.snapshotFormat
    @State private var copy = Preferences.copySnapshotToClipboard
    @State private var busy = false

    var body: some View {
        PanelSection("Snapshot", symbol: "camera", tint: Theme.accent) {
            OptionsGrid {
                OptionRow("Format") {
                    Picker("Format", selection: $format) {
                        Text("PNG").tag(ImageFormat.png)
                        Text("JPEG").tag(ImageFormat.jpg)
                    }
                    .pickerStyle(.segmented).fixedSize().labelsHidden()
                    .onChange(of: format) { _, v in Preferences.snapshotFormat = v }
                }
                OptionRow("Clipboard") {
                    Toggle("Also copy when saving", isOn: $copy).toggleStyle(.checkbox)
                        .onChange(of: copy) { _, v in Preferences.copySnapshotToClipboard = v }
                }
                OptionRow("Cover") { coverRow }
            }
            Spacer(minLength: 0)
            ExportFooter(summary: summary, busy: busy) {
                HStack(spacing: Theme.Space.s) {
                    Button { snap(copyOnly: true) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .buttonStyle(.bordered)
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                        .help("Copy this frame to the clipboard without saving a file (⇧⌘C) — paste it straight into a chat")
                        .disabled(busy || model.worker == nil)
                    Button { snap(copyOnly: false) } label: { Label("Snap Frame", systemImage: "camera.fill") }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                        .help("Save this frame to the project folder (⇧⌘S)")
                        .disabled(busy || model.worker == nil)
                }
            }
        }
    }

    /// "1920×1080 · PNG ≈ 1.0 MB · exact frame" (full resolution either way; Load Source for exact stepping)
    private var summary: String {
        var parts: [String] = []
        if let q = job.info?.bestQuality, let w = q.width, let h = q.height { parts.append("\(w)×\(h)") }
        let name = format == .png ? "PNG" : "JPEG"
        if let info = job.info, let e = SizeModel.frame(info: info, format: format) { parts.append("\(name) \(e.label)") }
        else { parts.append(name) }
        if player.hasExactFrames { parts.append("exact frame") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var coverRow: some View {
        if let s = job.info?.thumbnailURL, let url = URL(string: s) {
            HStack(spacing: Theme.Space.s) {
                Button { cover(url, copyOnly: false) } label: { Label("Save Cover", systemImage: "photo") }
                    .help("Save the clip’s cover image (its thumbnail on the site) to the project folder")
                Button { cover(url, copyOnly: true) } label: { Label("Copy Cover", systemImage: "doc.on.doc") }
                    .help("Copy the cover image to the clipboard")
            }
            .buttonStyle(TintedButtonStyle(tint: Theme.trim))
            .disabled(busy)
        } else {
            Text("This clip has no cover image.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func copyToClipboard(_ data: Data) -> Bool {
        guard let image = NSImage(data: data) else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([image])
    }

    private func snap(copyOnly: Bool) {
        guard let worker = model.worker else { return }
        player.player.pause()
        let t = player.frameStart(at: player.currentTime)
        let fd = player.frameDuration(at: t)
        // Copy only: the frame goes through a private temporary folder and is removed right after.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("DLLC-copy-\(UUID().uuidString)", isDirectory: true)
        let dest: URL
        if copyOnly {
            guard (try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)) != nil else { return }
            dest = scratch
        } else {
            guard let folder = model.saveFolder(forProject: job.projectID) else { return }
            dest = folder
        }
        busy = true
        Task {
            defer { busy = false; if copyOnly { try? FileManager.default.removeItem(at: scratch) } }
            do {
                let url = try await worker.snapshot(job: job, time: t, frameDuration: fd, format: format, destination: dest)
                let data = try Data(contentsOf: url)
                if copyOnly {
                    guard Self.copyToClipboard(data) else { throw CocoaError(.fileReadCorruptFile) }
                    model.show(.info, "Copied the frame at \(Timecode.format(t)) — paste it anywhere.")
                    return
                }
                if copy { _ = Self.copyToClipboard(data) }
                model.show(.info, "Saved frame at \(Timecode.format(t))\(copy ? " and copied it" : "").", action: "Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                model.show(.error, (error as? JobError)?.message ?? (copyOnly ? "Couldn’t copy the frame." : "Couldn’t save the frame."))
            }
        }
    }

    /// Downloads the site's cover image; saves it in the chosen format (never over an existing file) or copies it.
    private func cover(_ url: URL, copyOnly: Bool) {
        // The address comes from the site: only fetch it over the web, never a local or other scheme.
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            model.show(.error, "This clip’s cover image can’t be fetched.")
            return
        }
        let folder: URL?
        if copyOnly { folder = nil } else {
            guard let f = model.saveFolder(forProject: job.projectID) else { return }
            folder = f
        }
        let title = job.displayTitle
        let format = format
        busy = true
        Task {
            defer { busy = false }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
                guard let image = NSImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                if copyOnly {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                    model.show(.info, "Copied the cover image — paste it anywhere.")
                    return
                }
                guard let folder, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let out = rep.representation(using: format == .png ? .png : .jpeg,
                                                   properties: format == .png ? [:] : [.compressionFactor: 0.92]) else {
                    throw URLError(.cannotDecodeContentData)
                }
                let file = FileNaming.uniqueURL(in: folder, baseName: FileNaming.sanitize("\(title) — cover"), ext: format.rawValue)
                try out.write(to: file, options: .withoutOverwriting)
                model.show(.info, "Saved the cover image.", action: "Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
            } catch {
                model.show(.error, "Couldn’t get the cover image. Check the connection and try again.")
            }
        }
    }
}

private struct GIFControls: View {
    @Environment(AppModel.self) private var model
    let job: Job
    @Bindable var player: PlayerController
    @State private var width = 640
    @State private var fps: Double = 12
    @State private var loop = true
    @AppStorage("gifCompression") private var compression: Compression = .off

    var body: some View {
        let range = validRange(player)
        let sourceWidth = job.info?.bestQuality?.width
        PanelSection("Export GIF", symbol: "photo.stack", tint: Theme.accent) {
            OptionsGrid {
                OptionRow("Width") {
                    HStack(spacing: Theme.Space.m) {
                        Picker("Width", selection: $width) {
                            ForEach([320, 480, 640, 800, 960, 1280], id: \.self) { w in
                                Text("\(w) px").tag(w).disabled(sourceWidth.map { w > $0 } ?? false)
                            }
                        }.fixedSize().labelsHidden()
                        Text("Height follows the video. Never upscaled.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                OptionRow("Frame rate") {
                    Picker("Frame rate", selection: $fps) {
                        ForEach([8.0, 10, 12, 15, 20, 24], id: \.self) { Text("\(Int($0)) fps").tag($0) }
                    }.fixedSize().labelsHidden()
                }
                OptionRow("Loop") { Toggle("Repeat forever", isOn: $loop).toggleStyle(.checkbox) }
                OptionRow("Size") { SizePicker(compression: $compression, gif: true, estimate: { estimate($0) }).labelsHidden() }
            }
            Spacer(minLength: 0)
            ExportFooter(summary: rangeSummary(player, extra: range.map { r in
                                     ["\(Int(r.duration * fps)) frames", estimate(compression)?.label].compactMap { $0 }
                                         .joined(separator: " · ") }),
                         warning: range.flatMap(gifWarning)) {
                Button {
                    guard let r = commitAndValidRange(player) else { return }
                    var o = job.options
                    o.kind = .gif; o.range = r
                    o.gif = GIFOptions(width: width, fps: fps, loop: loop)
                    o.compression = compression
                    guard let folder = model.saveFolder(forProject: job.projectID) else { return }
                    model.engine.addDerived(from: job, options: o, startNow: true, destination: folder)
                    model.show(.info, "GIF added to the queue.")
                } label: { Label("Export GIF", systemImage: "photo.stack.fill") }
                .disabled(range == nil || (player.rangeIsWhole && player.duration > GIFOptions.maxRecommendedSeconds))
                .help(player.rangeIsWhole && player.duration > GIFOptions.maxRecommendedSeconds ? "Drag the orange handles to choose a short part of the video" : "Export the In–Out range as a GIF")
            }
        }
    }

    /// The GIF's estimated size with the current range, width, frame rate and palette.
    private func estimate(_ c: Compression) -> SizeEstimate? {
        guard let info = job.info, let r = validRange(player) else { return nil }
        return SizeModel.gif(info: info, range: r, options: GIFOptions(width: width, fps: fps, loop: loop), compression: c)
    }

    private func gifWarning(_ r: TimeRange) -> String? {
        if r.duration > GIFOptions.maxRecommendedSeconds {
            return "Long GIF (\(Int(r.duration)) s) — will be very large; try a shorter range"
        }
        if width > GIFOptions.maxRecommendedWidth { return "Wide GIFs take longer and make big files" }
        return nil
    }
}

/// A titled card grouping one part of the preview panel.
struct PanelSection<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder let content: Content

    init(_ title: String, symbol: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.tint = tint; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label {
                Text(title).font(.system(size: 11, weight: .semibold))
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s + 2)
        // Fills a taller slot when asked (the mode cards share one height); otherwise just fits.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Two columns: right-aligned labels and their controls, so every option lines up.
struct OptionsGrid<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.s) {
            content
        }
    }
}

struct OptionRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }
    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 3) { content }
        }
    }
}

/// A short summary on the left and the section's main action on the right, large and in the accent color.
struct ExportFooter<Action: View>: View {
    let summary: String?
    var warning: String?
    var busy = false
    @ViewBuilder let action: Action

    init(summary: String?, warning: String? = nil, busy: Bool = false, @ViewBuilder action: () -> Action) {
        self.summary = summary; self.warning = warning; self.busy = busy; self.action = action()
    }

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Divider()
            HStack(spacing: Theme.Space.s) {
                // One line, in place: a warning replaces the summary rather than adding a row.
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption)
                        .foregroundStyle(Theme.attention).lineLimit(1).truncationMode(.tail).help(warning)
                } else if let summary {
                    Text(summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle).help(summary)
                }
                Spacer(minLength: Theme.Space.s)
                if busy { ProgressView().controlSize(.small) }
                action
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .controlSize(.large)
            }
        }
    }
}

/// "0:12.0 → 0:18.5 · 6.5 s · MP4" for the current In–Out range.
@MainActor private func rangeSummary(_ player: PlayerController, extra: String?) -> String? {
    guard let r = validRange(player) else { return nil }
    var parts = ["\(Timecode.format(r.start)) → \(Timecode.format(r.end))", String(format: "%.1f s", r.duration)]
    if let extra { parts.append(extra) }
    return parts.joined(separator: " · ")
}

/// A small button that keeps its colour even when the window is in the background, so it always reads
/// as clickable: tinted fill, tinted label, darker while pressed, grey when disabled.
struct TintedButtonStyle: ButtonStyle {
    var tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isEnabled ? tint : Color.secondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill((isEnabled ? tint : Color.secondary).opacity(configuration.isPressed ? 0.32 : 0.16)))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder((isEnabled ? tint : Color.secondary).opacity(0.45), lineWidth: 0.5))
            .contentShape(Rectangle())
    }
}

/// Speaker button in the accent colour: click for a popover with mute and a volume slider
/// (preview only; exports are unaffected).
private struct VolumeControl: View {
    @Bindable var player: PlayerController
    var showsSlider = true
    @State private var open = false

    private var symbol: String {
        if player.isMuted || player.volume == 0 { return "speaker.slash.fill" }
        return player.volume < 0.34 ? "speaker.wave.1.fill" : player.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: symbol).frame(width: 18, height: 16)
        }
        .buttonStyle(TintedButtonStyle(tint: player.isMuted ? Theme.attention : Theme.trim))
        .help("Preview volume")
        .accessibilityLabel(player.isMuted ? "Preview muted" : "Preview volume")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            HStack(spacing: Theme.Space.s) {
                Button { player.isMuted.toggle() } label: {
                    Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(player.isMuted ? Theme.attention : .secondary)
                .help(player.isMuted ? "Unmute" : "Mute")
                Slider(value: Binding(get: { Double(player.isMuted ? 0 : player.volume) },
                                      set: { player.volume = Float($0); if $0 > 0 { player.isMuted = false } }),
                       in: 0...1)
                    .tint(Theme.trim)
                    .frame(width: 140)
                    .accessibilityLabel("Preview volume")
                Text("\(Int(((player.isMuted ? 0 : player.volume) * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .padding(Theme.Space.m)
        }
    }
}
