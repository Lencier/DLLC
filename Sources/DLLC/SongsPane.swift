import AppKit
import DLLCCore
import SwiftUI
import UniformTypeIdentifiers

/// Song Cues mode: the chosen song's editor, or a place to add one.
struct SongsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let id = model.selectedSongID, let song = model.songs.first(where: { $0.id == id }),
               model.selectedProjectID == nil || song.projectID == model.selectedProjectID {
                SongEditorView(songID: id).id(id)
            } else {
                emptyState
            }
        }
        .navigationTitle(model.selectedSong?.title ?? "Song Cues")
        .navigationSubtitle(model.selectedProject?.name ?? "All Songs")
        .overlay(alignment: .bottom) {
            if let banner = model.banner { BannerView(banner: banner).padding(Theme.Space.m).padding(.bottom, 180) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 52, weight: .light)).foregroundStyle(Theme.trim)
            Text("Add a song to \(model.selectedProject?.name ?? "Song Cues")").font(.title2.weight(.semibold))
            Text("Mark its parts on the timeline — Verse, Hook, Dance Break — then export each part as an audio cue\nwith a count-in, at any speed, straight to your iPhone.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { model.chooseSongFile() } label: {
                Label("Add Song…", systemImage: "plus").font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 18).frame(minHeight: 36)
            }
            .buttonStyle(ExportButtonStyle())
            .keyboardShortcut("o", modifiers: .command)
            Text("or drop an audio or video file here").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(AppModel.isSongFile)
            for url in files { Task { await model.openSong(url, projectID: model.selectedProjectID) } }
            return !files.isEmpty
        }
    }
}

/// One song: header, tools, timeline with the lyrics beside it, and the export panel below.
struct SongEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let songID: UUID
    @State private var editor: CueEditor?
    @State private var keyMonitor: Any?
    @State private var clickMonitor: Any?
    @State private var appearance = 0
    /// Lyrics beside the timeline: remembered for roomy windows; in a narrow one it starts hidden.
    @AppStorage("cueShowLyrics") private var showLyrics = true
    @State private var showLyricsNarrow = false
    static let lyricsBesideWidth: CGFloat = 820
    /// Export panel height the user dragged to (0 = fit its contents). Never taller than its contents.
    @AppStorage("cueExportHeight") private var exportHeight: Double = 0
    @State private var exportNatural: CGFloat = 0
    @State private var dragFrom: CGFloat?

    var body: some View {
        Group {
            if let editor, let song = editor.song {
                // The pane's own width decides the layout, so nothing is cut off in a small window.
                GeometryReader { geo in
                    let width = geo.size.width
                    let roomy = width >= Self.lyricsBesideWidth
                    let lyricsShown = roomy ? showLyrics : showLyricsNarrow
                    VStack(spacing: 0) {
                        header(song, editor, compact: width < 700)
                        CueToolbar(editor: editor, compact: width < 900, tiny: width < 800, lyricsShown: lyricsShown) {
                            if roomy { showLyrics.toggle() } else { showLyricsNarrow.toggle() }
                        }
                        HSplitView {
                            CueTimeline(editor: editor)
                                .frame(minWidth: 300, minHeight: 200)
                            if lyricsShown {
                                CueLyricsPanel(editor: editor)
                                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 440)
                                    .background(.bar)
                            }
                        }
                        exportArea(editor, width: width, room: geo.size.height)
                    }
                    .frame(width: width, height: geo.size.height)
                }
                .frame(minWidth: 600)
                // Reloads when the file changes and every time the view comes back (the player is
                // released while it's hidden), always on the editor that is on screen.
                .task(id: "\(song.path)|\(appearance)") { await editor.load() }
            } else {
                Color.clear
            }
        }
        .onAppear {
            // Keep one editor for this song: a fresh one would start with no file loaded.
            if editor == nil {
                let e = CueEditor(songID: songID, model: model)
                e.undoManager = undoManager
                editor = e
            }
            appearance += 1
            installKeys()
        }
        .onChange(of: undoManager) { _, u in editor?.undoManager = u }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m) }
            keyMonitor = nil
            if let m = clickMonitor { NSEvent.removeMonitor(m) }
            clickMonitor = nil
            editor?.player.tearDown()
        }
    }

    /// The export panel under a drag handle: drag up or down to trade space with the timeline,
    /// double-click the handle to fit it to its contents again. Scrolls when made smaller than its contents.
    private func exportArea(_ editor: CueEditor, width: CGFloat, room: CGFloat) -> some View {
        let natural = max(exportNatural, 1)
        let maxH = max(120, room - 320)                       // the timeline keeps at least ~200 pt
        let wanted = exportHeight > 0 ? CGFloat(exportHeight) : natural
        let height = min(wanted, natural, maxH)
        return VStack(spacing: 0) {
            ExportResizeHandle(onDrag: { dy in
                let start = dragFrom ?? height
                if dragFrom == nil { dragFrom = height }
                exportHeight = Double(min(max(start - dy, 110), natural))
            }, onEnd: {
                dragFrom = nil
                if exportHeight >= Double(natural) - 1 { exportHeight = 0 }   // dragged all the way: back to "fit"
            }, onReset: { exportHeight = 0 })
            ScrollView(.vertical) {
                CueExportPanel(editor: editor, width: width)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { exportNatural = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: height)
        }
        .background(.bar)
    }

    private func header(_ song: Song, _ editor: CueEditor, compact: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform").font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.trim)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.trim.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                TextField("Song title", text: Binding(get: { editor.song?.title ?? "" },
                                                       set: { t in editor.edit(nil, timesToLyrics: false) { $0.title = t } }))
                    .textFieldStyle(.plain).font(.system(size: 17, weight: .semibold))
                    .help("Song title — every exported file name starts with it")
                Text("\(Format.duration(song.duration) ?? "–") · \(song.sections.count) section\(song.sections.count == 1 ? "" : "s") · \(URL(fileURLWithPath: song.path).lastPathComponent)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .layoutPriority(1)
            SaveStatus(state: model.songSave)
            Spacer(minLength: 8)
            if editor.fileURL == nil, let drive = Self.blockedDrive(song.path) {
                // The drive is there but the file can't be read: macOS is blocking access to that drive.
                Label("No access to \(drive)", systemImage: "lock.fill").foregroundStyle(Theme.attention)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .help("macOS is blocking DLLC from reading the drive \(drive). Allow it in System Settings › Privacy & Security › Files & Folders › DLLC › Removable Volumes (or Network Volumes), then press Try Again.")
                headerButton("Allow Access…", "gearshape", compact: compact, tint: Theme.attention) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .help("Open Privacy & Security › Files & Folders")
                headerButton("Try Again", "arrow.clockwise", compact: compact, tint: Theme.info) {
                    Task { await editor.reloadFile() }
                }
                .help("Read the song again")
            } else if editor.fileURL == nil {
                Label("File not found", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.attention)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                headerButton("Locate…", "magnifyingglass", compact: false, tint: Theme.attention) {
                    model.relocateSong(song.id); Task { await editor.reloadFile() }
                }
                .help("Find the moved or renamed song file")
            } else if let url = editor.fileURL {
                headerButton("Show in Finder", "folder.fill", compact: true, tint: Theme.info) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .help("Show \(url.lastPathComponent) in Finder")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// The drive's name when the song is on a drive that is plugged in but can't be read (macOS privacy block).
    static func blockedDrive(_ path: String) -> String? {
        let parts = URL(fileURLWithPath: path).pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return nil }
        let root = "/Volumes/" + parts[2]
        guard FileManager.default.fileExists(atPath: root), !FileManager.default.isReadableFile(atPath: root) ||
              (try? FileManager.default.contentsOfDirectory(atPath: root)) == nil else { return nil }
        return parts[2]
    }

    /// A header action the same height as the song icon, so it lines up with the title block.
    private func headerButton(_ title: String, _ symbol: String, compact: Bool, tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                if !compact { Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary) }
            }
            .lineLimit(1).fixedSize()
            .frame(minWidth: 36, minHeight: 34)
        }
        .buttonStyle(GlassTileButtonStyle(tint: tint, radius: 9, padding: compact ? 0 : 14))
        .fixedSize()                      // never squeezed by a long title: the text stayed and spilled out
        .accessibilityLabel(title)
    }

    // MARK: Keys

    /// Editor shortcuts, ignored while typing in a text field or the lyrics.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        // A click anywhere outside the text you're typing in ends typing, so the shortcuts work again.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard model.mode == .songs, let window = event.window, window == NSApp.mainWindow,
                  let text = window.firstResponder as? NSTextView else { return event }
            let box = text.enclosingScrollView ?? text
            let p = box.convert(event.locationInWindow, from: nil)
            if !box.bounds.contains(p) { window.makeFirstResponder(nil) }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let editor, model.mode == .songs,
                  !(event.window?.firstResponder is NSText), event.window?.attachedSheet == nil,
                  event.window == NSApp.mainWindow else { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            let shift = event.modifierFlags.contains(.shift)
            if mods == .command, event.charactersIgnoringModifiers == "a" { editor.selectAllSections(); return nil }
            // Fine steps: ← → 0.1 s, ⇧ 1 s, ⌥ 0.01 s (J / L for 5 s).
            if mods == .option, event.keyCode == 123 || event.keyCode == 124 {
                editor.jump(event.keyCode == 123 ? -0.01 : 0.01); return nil
            }
            guard mods.isEmpty else { return event }
            switch event.keyCode {
            case 123: editor.jump(shift ? -1 : -0.1); return nil            // ←
            case 124: editor.jump(shift ? 1 : 0.1); return nil              // →
            case 51, 117: editor.deleteSelection(); return nil              // ⌫ / ⌦
            case 53: editor.selected = []; editor.selectedMarker = nil; editor.tool = .select; return nil // esc
            case 115: editor.player.seek(0); editor.reveal(0); return nil  // home
            case 119: editor.player.seek(editor.duration); editor.reveal(editor.duration); return nil // end
            default: break
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ": editor.togglePlay()
            case "j": editor.jump(-5)
            case "k": editor.player.pause()
            case "l": editor.jump(5)
            case "v": editor.tool = .select
            case "r": editor.tool = .range
            case "c": editor.splitAtPlayhead()
            case "m": editor.addMarkerAtPlayhead()
            case "s": editor.snap.toggle()
            case "=", "+": editor.zoom(by: 1.5)
            case "-", "_": editor.zoom(by: 1 / 1.5)
            case "z" where shift: editor.fit()
            default: return event
            }
            return nil
        }
    }
}

/// Transport, tools and zoom above the timeline. Hover any button for its name and shortcut.
/// "Saved" beside the song title: songs save themselves as you work, so there is no Save button.
private struct SaveStatus: View {
    let state: AppModel.SongSaveState
    var body: some View {
        Group {
            switch state {
            case .saved:  Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            case .saving: Label("Saving…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
            case .failed: Label("Not saved", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.attention)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(.primary.opacity(0.06)))
        .help(state == .failed
              ? "DLLC couldn't save your songs (is the disk full?). Your work is still open — free some space and edit anything to try again."
              : "Saved automatically — no need to press Save. Sections, lyrics and the title are kept as you work and are still here after you quit and reopen DLLC. (Save in the export panel writes the audio files.)")
        .animation(.easeOut(duration: 0.15), value: state)
    }
}

/// The grip between the timeline and the export panel.
private struct ExportResizeHandle: View {
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    @State private var hover = false
    var body: some View {
        ZStack {
            Rectangle().fill(.clear)
            Capsule().fill(.primary.opacity(hover ? 0.35 : 0.18)).frame(width: 38, height: 4)
        }
        .frame(height: 10)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Divider() }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pointerStyle(.rowResize)
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { onDrag($0.translation.height) }
            .onEnded { _ in onEnd() })
        .onTapGesture(count: 2) { onReset() }
        .help("Drag to resize the export panel · double-click to fit")
        .accessibilityLabel("Resize export panel")
    }
}

private struct CueToolbar: View {
    @Bindable var editor: CueEditor
    var compact = false
    /// Very narrow: the ±5 s and zoom ± buttons go (J/L and +/− still work), Fit stays.
    var tiny = false
    var lyricsShown = true
    var toggleLyrics: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            if !tiny { tool("gobackward.5", "Back 5 s (J) · ← 0.1 s · ⇧← 1 s · ⌥← 0.01 s") { editor.jump(-5) } }
            Button { editor.togglePlay() } label: {
                Image(systemName: editor.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold)).frame(width: 40, height: 30)
            }
            .buttonStyle(ExportButtonStyle())
            .help(editor.player.isPlaying ? "Pause (Space)" : "Play (Space)")
            .disabled(editor.fileURL == nil)
            if !tiny { tool("goforward.5", "Forward 5 s (L) · → 0.1 s · ⇧→ 1 s · ⌥→ 0.01 s") { editor.jump(5) } }
            CueClock(player: editor.player, duration: editor.duration, compact: compact)
            divider
            tool("cursorarrow", "Select (V) — move and resize blocks; drag over empty space to select several", on: editor.tool == .select) { editor.tool = .select }
            tool("arrow.left.and.right.square", "Range — drag across the song to make a section (R)", on: editor.tool == .range) { editor.tool = .range }
            tool("scissors", "Split the section at the playhead (C)") { editor.splitAtPlayhead() }
            tool("diamond", "Add a marker at the playhead (M)") { editor.addMarkerAtPlayhead() }
            tool("dot.scope", "Snap — edges stick to sections, markers and the playhead (S)", on: editor.snap) { editor.snap.toggle() }
            divider
            Menu {
                ForEach(CueSpeed.slowToFast) { s in
                    Button { editor.player.speed = s } label: {
                        if editor.player.speed == s { Label(s.longLabel, systemImage: "checkmark") } else { Text(s.longLabel) }
                    }
                }
            } label: {
                Label(editor.player.speed.label, systemImage: editor.player.speed.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(editor.player.speed.tint)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Speed — pitch stays the same. The same speed is used for the export (Speed in the panel below).")
            CueVolume(player: editor.player)
            Spacer()
            if !tiny { tool("minus.magnifyingglass", "Zoom out (−)") { editor.zoom(by: 1 / 1.5) } }
            if !compact { zoomSlider }
            if !tiny { tool("plus.magnifyingglass", "Zoom in (+)") { editor.zoom(by: 1.5) } }
            Button { editor.fit() } label: { Text("Fit").frame(height: 30).fixedSize() }
                .buttonStyle(GlassTileButtonStyle(tint: .primary))
                .font(.system(size: 12, weight: .semibold))
                .help("Show the whole song (⇧Z)")
            divider
            tool("text.quote", lyricsShown ? "Hide the lyrics" : "Show the lyrics", on: lyricsShown, action: toggleLyrics)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var zoomSlider: some View {
            Slider(value: Binding(get: { log(editor.pps / editor.minPPS) / log(editor.maxPPS / editor.minPPS) },
                                  set: { editor.zoom(by: editor.minPPS * pow(editor.maxPPS / editor.minPPS, $0) / editor.pps) }),
                   in: 0...1)
                .frame(minWidth: 60, maxWidth: 110).tint(Theme.trim)
                .help("Zoom")
    }

    private var divider: some View { Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 20).padding(.horizontal, 2) }

    private func tool(_ symbol: String, _ help: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 34, height: 30)
        }
        .buttonStyle(GlassTileButtonStyle(tint: on ? Theme.trim : .primary, selected: on, radius: 8, padding: 0))
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct CueClock: View {
    let player: SongPlayer
    let duration: Double
    var compact = false
    var body: some View {
        HStack(spacing: 4) {
            Text(Format.clock(player.currentTime)).foregroundStyle(Theme.info)
            if !compact { Text("/ \(Format.clock(duration))").foregroundStyle(.secondary) }
        }
        .font(.system(size: 14, weight: .semibold, design: .monospaced))
        .fixedSize()
        .padding(.horizontal, 6)
    }
}

private struct CueVolume: View {
    @Bindable var player: SongPlayer
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 13, weight: .medium)).frame(width: 34, height: 30)
        }
        .buttonStyle(GlassTileButtonStyle(tint: player.isMuted ? Theme.attention : .primary, radius: 8, padding: 0))
        .help("Volume")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            HStack(spacing: 10) {
                Button { player.isMuted.toggle() } label: {
                    Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.fill").frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(player.isMuted ? "Unmute" : "Mute")
                Slider(value: Binding(get: { Double(player.isMuted ? 0 : player.volume) },
                                      set: { player.volume = Float($0); if $0 > 0 { player.isMuted = false } }), in: 0...1)
                    .tint(Theme.trim).frame(width: 150)
            }
            .padding(12)
        }
    }
}
