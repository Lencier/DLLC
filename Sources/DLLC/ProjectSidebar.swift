import UniformTypeIdentifiers
import AppKit
import DLLCCore
import SwiftUI

/// Left column: the DLLC wordmark, "All Downloads" and the user's projects (groups with their own folder).
struct ProjectSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: UUID?
    @State private var draftName = ""
    @State private var confirmDelete: Project?
    @FocusState private var nameFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Wordmark()
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, Theme.Space.s)
                .padding(.bottom, Theme.Space.m)
            List(selection: selectionBinding) {
                Label {
                    HStack {
                        Text(model.mode == .songs ? "All Songs" : "All Downloads")
                        Spacer()
                        count(model.mode == .songs ? model.songs.count : model.jobCount(in: nil))
                    }
                } icon: {
                    Image(systemName: model.mode == .songs ? "music.note.list" : "tray.full").foregroundStyle(Theme.accent)
                }
                .tag(SidebarItem.all)
                .dropDestination(for: String.self) { items, _ in drop(items, into: nil) }
                .dropDestination(for: URL.self) { urls, _ in dropSongs(urls, into: nil) }
                if model.mode == .songs && model.selectedProjectID == nil { songRows(nil) }

                Section("Projects") {
                    ForEach(model.projects) { project in
                        row(project).tag(SidebarItem.project(project.id))
                        if model.mode == .songs && model.selectedProjectID == project.id { songRows(project.id) }
                    }
                    if model.projects.isEmpty {
                        Text(model.mode == .songs ? "Make a project to keep a shoot’s songs and reference clips together."
                                                  : "Group links by project. Each project saves into its own folder.")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .selectionDisabled()
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: Theme.Space.s) {
                Button {
                    let p = model.createProject(named: "New Project")
                    startRename(p)
                } label: {
                    Label("New Project", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .help("Create a project (⇧⌘N)")
                .keyboardShortcut("n", modifiers: [.command, .shift])
                SettingsLink {
                    Image(systemName: "gearshape").font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
            }
            .controlSize(.large)
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            Credits()
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, 2)
                .padding(.bottom, Theme.Space.s)
        }
        .alert("Delete “\(confirmDelete?.name ?? "")”?", isPresented: Binding(get: { confirmDelete != nil },
                                                                             set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete Project", role: .destructive) {
                if let p = confirmDelete { model.deleteProject(p.id) }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("Its downloads move to All Downloads and its songs are removed from Song Cues. Files on disk are never deleted.")
        }
    }

    @ViewBuilder private func row(_ project: Project) -> some View {
        Label {
            if renaming == project.id {
                TextField("Project name", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit { commitRename(project) }
                    .onExitCommand { renaming = nil }
                    .onChange(of: nameFocused) { _, focused in if !focused { commitRename(project) } }
            } else {
                HStack {
                    Text(project.name).lineLimit(1); Spacer()
                    count(model.mode == .songs ? model.songs.filter { $0.projectID == project.id }.count : model.jobCount(in: project.id))
                }
            }
        } icon: { Image(systemName: "folder.fill").foregroundStyle(Theme.projectColor(project.id)) }
        .help(model.folder(for: project).path)
        .dropDestination(for: String.self) { items, _ in drop(items, into: project.id) }
        .dropDestination(for: URL.self) { urls, _ in dropSongs(urls, into: project.id) }
        .contextMenu {
            Button("Rename…") { startRename(project) }
            Button("Change Save Folder…") { model.changeSaveFolder(forProject: project.id) }
            Button("Show Folder in Finder") { model.revealProjectFolder(project) }
            Divider()
            Button("Delete Project…", role: .destructive) { confirmDelete = project }
        }
    }

    private func count(_ n: Int) -> some View {
        Text("\(n)").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
            .opacity(n == 0 ? 0 : 1)
    }

    private func startRename(_ project: Project) {
        draftName = project.name
        renaming = project.id
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename(_ project: Project) {
        guard renaming == project.id else { return }
        model.renameProject(project.id, to: draftName)
        renaming = nil
    }

    private var selectionBinding: Binding<SidebarItem?> {
        Binding(get: {
            if model.mode == .songs, let id = model.selectedSongID { return .song(id) }
            return model.selectedProjectID.map(SidebarItem.project) ?? .all
        }, set: { item in
            if case .song(let id) = item { model.selectedSongID = id; return }
            model.selectedProjectID = item?.projectID
            if model.mode == .songs {
                model.selectedSongID = model.songs.first { $0.projectID == item?.projectID }?.id
            }
        })
    }

    /// The songs of one project (nil = All Songs), indented under its row.
    @ViewBuilder private func songRows(_ projectID: UUID?) -> some View {
        let list = projectID == nil ? model.songs : model.songs.filter { $0.projectID == projectID }
        ForEach(list) { song in
            Label {
                Text(song.title).lineLimit(1)
            } icon: {
                Image(systemName: "waveform").foregroundStyle(Theme.trim)
            }
            .padding(.leading, 14)
            .tag(SidebarItem.song(song.id))
            .help(song.path)
            .contextMenu {
                Menu("Move to Project") {
                    Button("No Project") { model.moveSong(song.id, toProject: nil) }
                    ForEach(model.projects) { p in Button(p.name) { model.moveSong(song.id, toProject: p.id) } }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: song.path)]) }
                Divider()
                Button("Remove from Song Cues") { model.removeSong(song.id) }
            }
        }
        Button { model.chooseSongFile() } label: {
            Label("Add Song…", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.leading, 14)
        .help("Add an audio or video file to this project (⌘O). You can also drop files here.")
        .selectionDisabled()
    }

    private func dropSongs(_ urls: [URL], into projectID: UUID?) -> Bool {
        let files = urls.filter(AppModel.isSongFile)
        guard !files.isEmpty else { return false }
        model.mode = .songs
        model.selectedProjectID = projectID
        for url in files { Task { await model.openSong(url, projectID: projectID) } }
        return true
    }

    /// Rows are dragged as their job id strings.
    private func drop(_ items: [String], into projectID: UUID?) -> Bool {
        let ids = items.compactMap(UUID.init(uuidString:)).filter { model.engine.job($0) != nil }
        guard !ids.isEmpty else { return false }
        model.move(ids, toProject: projectID)
        return true
    }
}

enum SidebarItem: Hashable {
    case all
    case project(UUID)
    case song(UUID)
    var projectID: UUID? { if case .project(let id) = self { id } else { nil } }
}

/// The version and author line at the foot of the sidebar; opens the About window.
struct Credits: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
    var body: some View {
        Button { AboutPanel.show() } label: {
            Text("v\(version) · Developed by \(AppIdentity.author)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help("About \(AppIdentity.name)")
    }
}

/// The DLLC logo (bundled artwork; a typeset fallback in debug builds) and the Quick Tips button.
struct Wordmark: View {
    @Environment(\.colorScheme) private var scheme
    /// The brand monogram, white "LC" in dark mode and dark "LC" in light mode (bundled by build-app.sh).
    private var logo: NSImage? {
        guard let url = Bundle.main.url(forResource: scheme == .dark ? "Logo" : "LogoLight", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        // Logo centred in the sidebar; the Quick Tips ? sits in the top-right corner, outside the
        // centring so it doesn't pull the logo off-centre.
        VStack(alignment: .center, spacing: 0) {
            if let logo {
                Image(nsImage: logo)
                    .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(height: 58)
                    .padding(.horizontal, 26)      // room for the ? so the logo stays in the centre
                    .accessibilityLabel("DLLC")
            } else {
                (Text("DL").foregroundStyle(Theme.brand) + Text("LC").foregroundStyle(.primary))
                    .font(.system(size: 34, weight: .black).width(.expanded).italic())
                    .kerning(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityLabel("DLLC")
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) { TipsButton().offset(x: 4, y: -4) }
    }
}
