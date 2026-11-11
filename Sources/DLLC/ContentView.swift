import AppKit
import DLLCCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            ProjectSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            // A real container (not a Group: a Group hands its modifiers to each child, which gave each mode
            // its own toolbar and inspector, swapped on every mode change — the jumping bar).
            ZStack {
                if model.mode == .songs {
                    SongsPane()
                } else {
                    MainPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { MainToolbar() }
            .inspector(isPresented: Binding(get: { model.showTips }, set: { model.showTips = $0 })) {
                QuickTipsView()
                    .inspectorColumnWidth(min: 300, ideal: 350, max: 460)
            }
        }
        .sheet(item: selectionSheetBinding) { item in
            SelectionSheet(jobID: item.id)
        }
    }

    private var selectionSheetBinding: Binding<IdentifiedID?> {
        Binding(get: { model.selectionSheetJobID.map(IdentifiedID.init) },
                set: { model.selectionSheetJobID = $0?.id })
    }
}

/// Link bar + queue, with the preview workspace beside it (or over it in a narrow window).
struct MainPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let narrow = geo.size.width < 900
            VStack(spacing: 0) {
                if let err = model.toolError {
                    BannerView(banner: Banner(kind: .error, text: err), dismissible: false)
                }
                URLInputBar()
                Divider()
                if narrow {
                    if model.narrowShowsWorkspace, let id = model.workspaceJobID, model.engine.job(id) != nil {
                        WorkspaceView(jobID: id, onBack: {
                            model.workspaceController?.player.pause()
                            model.narrowShowsWorkspace = false
                        })
                            .transition(.opacity)
                    } else {
                        QueueView()
                    }
                } else {
                    HSplitView {
                        QueueView()
                            .frame(minWidth: 420, idealWidth: 520)
                        if let id = model.workspaceJobID, model.engine.job(id) != nil {
                            WorkspaceView(jobID: id, onBack: nil)
                                .frame(minWidth: 480, idealWidth: 620)
                        } else {
                            PreviewPlaceholder()
                                .frame(minWidth: 280, idealWidth: 420)
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let banner = model.banner {
                    BannerView(banner: banner)
                        .padding(Theme.Space.m)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Theme.animation(Theme.Motion.reveal, reduceMotion: reduceMotion), value: model.banner)
            // Wide window: the preview follows the selected row (also once a just-pasted link finishes
            // analysing), so clicking a link shows it right away.
            .onChange(of: previewCandidate) { _, id in
                guard !narrow, let id, id != model.workspaceJobID else { return }
                model.workspaceJobID = id
            }
        }
        .tint(Theme.accent)
        .navigationTitle(model.selectedProject?.name ?? "All Downloads")
        .navigationSubtitle(model.folder(for: model.selectedProject).lastPathComponent)
    }
}

extension MainPane {
    /// The single selected job, once it has been analysed and has video to show.
    var previewCandidate: UUID? {
        guard model.selection.count == 1, let id = model.selection.first,
              let info = model.engine.job(id)?.info, info.hasVideo, !info.isMultiItem else { return nil }
        return id
    }
}

/// Shown beside the queue before anything is selected.
struct PreviewPlaceholder: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("Click a video to preview it").font(.title3.weight(.semibold))
            Text("Watch it, scrub the timeline and drag the orange handles to choose a clip — before anything is downloaded.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct IdentifiedID: Identifiable { let id: UUID }

/// The window toolbar, shared by both modes: the save folder, the mode switch (centred on the work area) and
/// the actions for the current mode on the right.
struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.chooseDestination() } label: {
                Label(model.destination.lastPathComponent, systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .help("Save folder: \(model.folder(for: model.selectedProject).path)")
            .accessibilityLabel("Save folder, \(model.destination.lastPathComponent)")
        }
        ToolbarItem(placement: .principal) { ModeSwitch() }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.mode == .songs { songActions } else { downloadActions }
        }
    }

    @ViewBuilder private var songActions: some View {
        Button { model.chooseSongFile() } label: {
            Label("Add Song…", systemImage: "plus").labelStyle(.titleAndIcon)
        }
        .help("Add a song to \(model.selectedProject?.name ?? "Song Cues") (⌘O)")
    }

    @ViewBuilder private var downloadActions: some View {
        let selected = model.selection.compactMap { model.engine.job($0) }
        if !selected.isEmpty {
            Button(role: .destructive) { removeSelected(selected) } label: {
                Image(systemName: "trash")
            }
            .help("Remove the selected items from the list (⌫). Saved files stay on disk.")
            .accessibilityLabel("Remove")
        }
        Button {
            if model.workspaceJobID != nil { model.workspaceJobID = nil }
            else if let id = model.selection.first { model.openWorkspace(id) }
        } label: {
            Label("Preview", systemImage: "play.rectangle")
                .labelStyle(.titleAndIcon)
        }
        .disabled(model.workspaceJobID == nil && model.selection.first.flatMap { model.engine.job($0)?.info } == nil)
        .help("Show or hide the preview")
        let startable = model.visibleJobs.contains { [.ready, .interrupted, .analyzing, .needsSelection].contains($0.state) && !$0.enqueueWhenReady }
        Button { model.downloadAllVisible() } label: {
            Label("Download All", systemImage: "arrow.down.circle.fill")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .disabled(!startable)
        .help("Download every ready item\(model.selectedProject == nil ? "" : " in this project"), including links still being analyzed (⌘↩)")
    }

    private func removeSelected(_ jobs: [Job]) {
        let active = jobs.filter { $0.state.isActive }
        if !active.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Cancel and remove \(active.count) active job\(active.count == 1 ? "" : "s")?"
            alert.informativeText = "Files already saved are kept."
            alert.addButton(withTitle: "Cancel and Remove")
            alert.addButton(withTitle: "Keep")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let ids = jobs.map(\.id)
        if let ws = model.workspaceJobID, ids.contains(ws) { model.workspaceJobID = nil }
        model.engine.remove(ids)
        model.selection = []
    }
}

struct BannerView: View {
    let banner: Banner
    /// Blocking problems (e.g. missing tools) stay visible: they can't be dismissed.
    var dismissible = true
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(banner.text).font(.callout).lineLimit(2)
            Spacer(minLength: 0)
            if let title = banner.actionTitle, let action = banner.action {
                Button(title) { action(); model.banner = nil }.buttonStyle(.link)
            }
            if dismissible {
                Button { model.banner = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(.separator))
        .frame(maxWidth: 560)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch banner.kind {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
    private var tint: Color {
        switch banner.kind {
        case .info: Theme.info
        case .warning: Theme.attention
        case .error: Theme.error
        }
    }
}

struct URLInputBar: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "link").foregroundStyle(.secondary)
            TextField("Paste one or more links", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .focused($focused)
                .onSubmit(submit)
                .accessibilityLabel("Links to add")
            if text.isEmpty {
                Button("Paste") { model.pasteLinks() }
                    .help("Add links from the clipboard (⇧⌘V)")
            } else {
                Button("Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(LinkExtractor.extract(from: text).isEmpty)
            }
            Menu {
                OutputDefaultsMenu()
            } label: {
                // Borderless menus drop images from their label, so the icon is part of the text.
                Text("\(Image(systemName: model.defaultOptions.kind == .audio ? "music.note" : "film")) \(defaultsSummary)")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Output for newly added links")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .frame(minHeight: 36)
        .background(.background)
    }

    private var defaultsSummary: String {
        let o = model.defaultOptions
        switch o.kind {
        case .audio: return o.audioFormat == .mp3 ? "Audio · MP3" : "Audio · Original"
        default: return o.container == .compatibleMP4 ? "Video · Compatible MP4" : "Video · Best quality"
        }
    }

    private func submit() {
        let links = LinkExtractor.extract(from: text)
        guard !links.isEmpty else {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.show(.warning, "That doesn’t look like a web link. Links start with https://")
            }
            return
        }
        model.add(links)
        text = ""
    }
}

struct OutputDefaultsMenu: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Picker("New links", selection: Binding(
            get: { DefaultChoice(model.defaultOptions) },
            set: { $0.apply(to: &model.defaultOptions) })) {
            ForEach(DefaultChoice.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
    }
}

enum DefaultChoice: String, CaseIterable, Identifiable, Hashable {
    case videoBest, videoMP4, audioMP3, audioOriginal
    var id: String { rawValue }
    init(_ o: OutputOptions) {
        switch (o.kind, o.container, o.audioFormat) {
        case (.audio, _, .mp3): self = .audioMP3
        case (.audio, _, .original): self = .audioOriginal
        case (_, .compatibleMP4, _): self = .videoMP4
        default: self = .videoBest
        }
    }
    var title: String {
        switch self {
        case .videoBest: "Video · Best quality"
        case .videoMP4: "Video · Compatible MP4"
        case .audioMP3: "Audio · MP3"
        case .audioOriginal: "Audio · Original"
        }
    }
    func apply(to o: inout OutputOptions) {
        switch self {
        case .videoBest: o.kind = .video; o.container = .bestQuality
        case .videoMP4: o.kind = .video; o.container = .compatibleMP4
        case .audioMP3: o.kind = .audio; o.audioFormat = .mp3
        case .audioOriginal: o.kind = .audio; o.audioFormat = .original
        }
    }
}


/// Download ↔ Song Cues, centred in the toolbar.
struct ModeSwitch: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Picker("Mode", selection: $model.mode) {
            Label("Download", systemImage: "arrow.down.circle").tag(AppMode.download)
            Label("Song Cues", systemImage: "music.note").tag(AppMode.songs)
        }
        .pickerStyle(.segmented)
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .help("Switch between downloading clips (⌘1) and cutting song cues (⌘2)")
    }
}

/// Opens and closes Quick Tips: a small ? beside the logo, out of the way of the work area.
/// ⌘? and Help › Quick Tips do the same, so it still works with the sidebar hidden.
struct TipsButton: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Button { model.toggleTips() } label: {
            Image(systemName: model.showTips ? "questionmark.circle.fill" : "questionmark.circle")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(model.showTips ? Theme.accent : .secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quick Tips")
        .help(model.showTips ? "Close Quick Tips (⌘?)" : "Quick Tips — how to use DLLC (⌘?)")
    }
}

extension AppModel {
    /// Opens or closes Quick Tips. Opening widens a narrow window (within the screen) so the panel never
    /// squeezes or pushes the work area out of view — like an inspector in Xcode or Finder.
    @MainActor func toggleTips() {
        if !showTips, let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }),
           let screen = window.screen {
            let needed: CGFloat = 1180
            if window.frame.width < needed {
                var frame = window.frame
                let grow = min(needed, screen.visibleFrame.width) - frame.width
                frame.size.width += grow
                if frame.maxX > screen.visibleFrame.maxX { frame.origin.x = max(screen.visibleFrame.minX, screen.visibleFrame.maxX - frame.width) }
                window.setFrame(frame, display: true, animate: true)
            }
        }
        withAnimation(.snappy(duration: 0.25)) { showTips.toggle() }
    }
}
