import DLLCCore
import SwiftUI

struct QueueView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        let jobs = model.visibleJobs
        VStack(spacing: 0) {
            if jobs.isEmpty {
                EmptyQueueView()
            } else {
                List(selection: $model.selection) {
                    ForEach(jobs) { job in
                        JobRow(job: job)
                            .tag(job.id)
                            .contextMenu { JobMenu(job: job) }
                            // Drag a row onto a project in the sidebar to move it there.
                            .draggable(job.id.uuidString) {
                                Label(job.displayTitle, systemImage: "film").padding(6)
                            }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                .animation(Theme.animation(Theme.Motion.state, reduceMotion: reduceMotion), value: jobs.map(\.id))
                .onDeleteCommand { removeSelection() }
                .onPasteCommand(of: [.plainText, .url]) { _ in model.pasteLinks() }
                .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
                    if let id = ids.first, model.engine.job(id)?.info != nil { model.openWorkspace(id) }
                }
            }
            QueueFooter()
        }
    }

    private func removeSelection() {
        let ids = Array(model.selection)
        let active = ids.compactMap { model.engine.job($0) }.filter { $0.state.isActive }
        if !active.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Cancel and remove \(active.count) active job\(active.count == 1 ? "" : "s")?"
            alert.informativeText = "Files already saved are kept."
            alert.addButton(withTitle: "Cancel and Remove")
            alert.addButton(withTitle: "Keep")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if let ws = model.workspaceJobID, ids.contains(ws) { model.workspaceJobID = nil }
        model.engine.remove(ids)
        model.selection = []
    }
}

struct EmptyQueueView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(model.selectedProject.map { "Paste links to add them to “\($0.name)”." } ?? "Paste links to get started.")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Video, audio, clips, frames, and GIFs from YouTube, Instagram, Pinterest and X.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Paste Links") { model.pasteLinks() }
                .controlSize(.large)
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Text("DLLC reads the clipboard only when you press Paste.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct QueueFooter: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let jobs = model.visibleJobs
        let active = jobs.filter { $0.state == .downloading || $0.state == .processing }.count
        let pending = jobs.filter { $0.state == .queued || $0.state == .analyzing || $0.state == .ready }.count
        let attention = jobs.filter { [.failed, .interrupted, .needsSelection].contains($0.state) }.count
        let done = jobs.filter { $0.state == .completed }.count
        HStack(spacing: Theme.Space.s) {
            if !model.isOnline {
                Label("Offline — jobs will retry when you’re back online", systemImage: "wifi.slash")
                    .foregroundStyle(Theme.attention)
            } else {
                Text(summary(pending: pending, active: active, attention: attention))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let project = model.selectedProject {
                Button("Open Project Folder") { model.revealProjectFolder(project) }
                    .buttonStyle(.borderless)
            }
            if done > 0 {
                Button("Clear Completed") { model.clearCompletedVisible() }
                    .buttonStyle(.borderless)
                    .help("Removes finished items from the list. Files stay on disk.")
            }
        }
        .font(.caption)
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func summary(pending: Int, active: Int, attention: Int) -> String {
        let needs = attention > 0 ? "\(attention) need\(attention == 1 ? "s" : "") attention" : nil
        if pending == 0 && active == 0 {
            if let needs { return needs }
            let jobs = model.visibleJobs
            return jobs.isEmpty ? "" : (jobs.allSatisfy { $0.state == .completed } ? "All done" : "Nothing in progress")
        }
        return (["\(pending) pending", "\(active) active"] + [needs].compactMap { $0 }).joined(separator: " · ")
    }
}

// MARK: - Row

struct JobRow: View {
    @Environment(AppModel.self) private var model
    let job: Job
    @State private var showOutput = false
    @State private var showDetails = false
    @State private var hovering = false

    var body: some View {
        let style = StateStyle.of(job)
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Button { if canPreview { model.openWorkspace(job.id) } } label: {
                Thumbnail(url: job.info?.thumbnailURL, platform: job.info?.platform, showsPlay: canPreview)
            }
            .buttonStyle(.plain)
            .disabled(!canPreview)
            .help(canPreview ? "Preview" : "")
            .accessibilityLabel("Preview \(job.displayTitle)")
            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(job.displayTitle)
                metaLine
                statusLine(style)
                // Output chip on the left, big actions on the right — on their own line so they're never squeezed.
                HStack(spacing: Theme.Space.s) {
                    Button { showOutput = true } label: {
                        HStack(spacing: 3) {
                            Text(outputSummary(job)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .disabled(job.state.isActive && job.state != .analyzing || job.state == .queued)
                    .popover(isPresented: $showOutput, arrowEdge: .bottom) {
                        OutputPopover(jobID: job.id).environment(model)
                    }
                    .accessibilityLabel("Output: \(outputSummary(job)). Change output")
                    .layoutPriority(-1)
                    if job.state != .completed, let est = job.sizeEstimate {
                        Text("\(est.rough ? "≈ " : "")\(ByteFormat.string(est.bytes))")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize()
                            .help(est.rough ? "Estimated file size (a guess from what the site reports)"
                                            : "File size the site reports for this quality")
                            .accessibilityLabel("Estimated size \(ByteFormat.string(est.bytes))")
                    }
                    Spacer(minLength: Theme.Space.s)
                    RowActions(job: job, showDetails: $showDetails)
                        .fixedSize()
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(job.displayTitle), \(style.label)")
        .popover(isPresented: $showDetails) { ErrorDetails(job: job).environment(model) }
        .onAppear { openRequestedOutput() }
        .onChange(of: model.outputPopoverRequest) { _, _ in openRequestedOutput() }
    }

    private func openRequestedOutput() {
        guard model.outputPopoverRequest == job.id else { return }
        model.outputPopoverRequest = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showOutput = true }
    }

    private var canPreview: Bool { job.info?.hasVideo == true && job.info?.isMultiItem != true }

    @ViewBuilder private var metaLine: some View {
        let parts: [String] = [job.info?.creator, Format.duration(job.info?.duration)].compactMap { $0 }
        HStack(spacing: 4) {
            if let p = job.info?.platform {
                Label(p.displayName, systemImage: p.symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(p.tint)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(p.tint.opacity(0.14)))
            }
            Text(parts.isEmpty ? job.url : parts.joined(separator: " · "))
                .lineLimit(1).truncationMode(.middle)
            if let info = job.info, info.hasVideo, !info.hasAudio {
                Label("No audio", systemImage: "speaker.slash").labelStyle(.titleAndIcon)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func statusLine(_ style: StateStyle) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if job.state == .analyzing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: style.symbol).foregroundStyle(style.tint).accessibilityHidden(true)
                }
                Text(statusText(style)).lineLimit(1)
                    .fontWeight(job.state == .completed || job.state == .failed ? .semibold : .regular)
                    .foregroundStyle(style.tint)
                if let d = job.progress?.detail, job.state.isActive {
                    Text("· \(d)").foregroundStyle(.tertiary).lineLimit(1).monospacedDigit()
                }
            }
            .font(.system(size: 11))
            if job.state == .downloading || job.state == .processing {
                if let f = job.progress?.fraction {
                    ProgressView(value: f).progressViewStyle(.linear).tint(StateStyle.of(job).tint)
                        .accessibilityValue("\(Int(f * 100)) percent")
                } else {
                    ProgressView().progressViewStyle(.linear).tint(StateStyle.of(job).tint)
                }
            }
        }
    }

    private func statusText(_ style: StateStyle) -> String {
        switch job.state {
        case .queued:
            let pos = model.engine.jobs.filter { $0.state == .queued }.firstIndex { $0.id == job.id }.map { $0 + 1 }
            return pos.map { "Queued · \($0)" } ?? "Queued"
        case .ready where job.enqueueWhenReady, .analyzing where job.enqueueWhenReady:
            return "Analyzing — will download when ready"
        case .completed:
            if let f = job.outputFiles.first { return "Saved · \(URL(fileURLWithPath: f).lastPathComponent)" }
            return "Saved"
        case .failed:
            return job.error?.message ?? style.label
        default:
            return style.label
        }
    }
}

struct Thumbnail: View {
    let url: String?
    let platform: Platform?
    var showsPlay = false
    @State private var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.thumb).fill(.quaternary)
            if let s = url, let u = URL(string: s) {
                AsyncImage(url: u, transaction: Transaction(animation: nil)) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
            if showsPlay {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.black.opacity(hovering ? 0.75 : 0.5)))
                    .scaleEffect(hovering ? 1.1 : 1)
            }
        }
        .frame(width: 128, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumb))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityHidden(true)
    }
    private var placeholder: some View {
        Image(systemName: platform?.symbol ?? "link").font(.system(size: 20)).foregroundStyle((platform?.tint ?? .secondary).opacity(0.7))
    }
}

/// Always-visible, large actions: the main step (Download…), Preview, Remove, and an overflow menu.
struct RowActions: View {
    @Environment(AppModel.self) private var model
    let job: Job
    @Binding var showDetails: Bool

    var body: some View {
        HStack(spacing: 6) {
            primary
            Button(role: .destructive) { remove() } label: {
                Image(systemName: "trash").frame(width: 18)
            }
            .buttonStyle(.bordered)
            .tint(Theme.error)
            .help(job.state.isActive ? "Cancel and remove" : "Remove from the list (files stay on disk)")
            .accessibilityLabel(job.state.isActive ? "Cancel and remove" : "Remove")
            Menu { JobMenu(job: job) } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More actions")
        }
        .controlSize(.large)
    }

    private func remove() {
        if job.state.isActive {
            let alert = NSAlert()
            alert.messageText = "Cancel and remove this job?"
            alert.informativeText = "Files already saved are kept."
            alert.addButton(withTitle: "Cancel and Remove")
            alert.addButton(withTitle: "Keep")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if model.workspaceJobID == job.id { model.workspaceJobID = nil }
        model.selection.remove(job.id)
        model.engine.remove([job.id])
    }

    @ViewBuilder private var primary: some View {
        let e = model.engine!
        switch job.state {
        case .analyzing:
            Button("Cancel") { e.cancel(job.id) }
        case .needsSelection:
            Button { model.selectionSheetJobID = job.id } label: { Label("Choose…", systemImage: "square.stack") }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
        case .ready:
            if job.options.kind == .clip || job.options.kind == .gif, job.options.range == nil {
                Button { model.openWorkspace(job.id) } label: { Label("Set Range…", systemImage: "timeline.selection") }
            } else {
                Button { model.download([job.id]) } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .help("Download (\(outputSummary(job)))")
            }
        case .queued, .downloading, .processing:
            Button { e.cancel(job.id) } label: { Label("Stop", systemImage: "stop.circle") }
        case .completed:
            HStack(spacing: 6) {
                Button { model.reveal(job) } label: { Label("Show", systemImage: "folder") }
                    .tint(Theme.success)
                    .help("Show the file in Finder")
                Button { model.downloadAgain(job) } label: { Label("Again", systemImage: "arrow.down.circle") }
                    .help("Download again — at the same or another quality")
            }
        case .failed:
            if job.error?.category == .authRequired || job.error?.isRecoverable == false {
                Button("Details…") { showDetails = true }
            } else {
                HStack(spacing: 4) {
                    Button { e.retry(job.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    Button { showDetails = true } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("Error details")
                }
            }
        case .cancelled, .interrupted:
            Button { e.retry(job.id) } label: { Label("Restart", systemImage: "arrow.clockwise") }
        }
    }
}

struct JobMenu: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
        let e = model.engine!
        if job.state.canStart && job.info != nil { Button("Download") { model.download([job.id]) } }
        if job.state == .completed && job.info != nil { Button("Download Again…") { model.downloadAgain(job) } }
        if job.state.isActive || job.state == .queued { Button("Cancel") { e.cancel(job.id) } }
        if job.state == .failed || job.state == .cancelled || job.state == .interrupted {
            Button(job.state == .failed ? "Retry" : "Restart") { e.retry(job.id) }
        }
        if job.info != nil && job.info?.hasVideo == true {
            Button("Open Preview") { model.openWorkspace(job.id) }
        }
        if job.state == .needsSelection { Button("Choose Items…") { model.selectionSheetJobID = job.id } }
        if job.state == .completed {
            Divider()
            Button("Open File") { model.open(job) }
            if job.info?.hasVideo == true || job.options.kind == .audio || job.options.kind == .video {
                Button("Open in Song Cues") { model.openSong(from: job) }
            }
            Button("Reveal in Finder") { model.reveal(job) }
        }
        Divider()
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(job.url, forType: .string)
        }
        if let u = URL(string: job.url) { Button("Open Original Page") { NSWorkspace.shared.open(u) } }
        Divider()
        Menu("Move to Project") {
            let ids = model.selection.contains(job.id) ? Array(model.selection) : [job.id]
            Button("All Downloads (no project)") { model.move(ids, toProject: nil) }
                .disabled(job.projectID == nil && ids.count == 1)
            if !model.projects.isEmpty { Divider() }
            ForEach(model.projects) { p in
                Button(p.name) { model.move(ids, toProject: p.id) }
                    .disabled(job.projectID == p.id && ids.count == 1)
            }
            Divider()
            Button("New Project…") {
                let p = model.createProject(named: job.info?.creator ?? "New Project")
                model.move(ids, toProject: p.id)
            }
        }
        if job.state == .queued || job.state == .ready {
            Button("Move Up") { model.moveVisible(job.id, by: -1) }
            Button("Move Down") { model.moveVisible(job.id, by: 1) }
        }
        Divider()
        Button(job.state.isActive ? "Cancel and Remove" : "Remove from Queue", role: .destructive) {
            if model.workspaceJobID == job.id { model.workspaceJobID = nil }
            e.remove([job.id])
        }
    }
}

struct ErrorDetails: View {
    @Environment(AppModel.self) private var model
    let job: Job
    @State private var showTechnical = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let err = job.error {
                Label(err.message, systemImage: StateStyle.of(job).symbol)
                    .font(.headline).foregroundStyle(StateStyle.of(job).tint)
                if let s = err.suggestion { Text(s).font(.callout) }
                if err.category == .authRequired { AuthHelp(job: job) }
                if let t = err.technical, !t.isEmpty {
                    DisclosureGroup("Technical details", isExpanded: $showTechnical) {
                        ScrollView {
                            Text(t).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 160)
                    }
                    .font(.callout)
                }
                HStack {
                    Spacer()
                    if err.isRecoverable { Button("Retry") { model.engine.retry(job.id) }.keyboardShortcut(.defaultAction) }
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 380)
    }
}

/// Explains opt-in browser cookies for content the user is authorised to access.
struct AuthHelp: View {
    @Environment(AppModel.self) private var model
    let job: Job
    @State private var browser = "safari"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("If you can view this in your browser while signed in, DLLC can use that browser’s login for this item only. DLLC never asks for your password.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Browser", selection: $browser) {
                ForEach(CookieBrowsers.all, id: \.id) { Text($0.name).tag($0.id) }
            }
            Text(CookieBrowsers.note(for: browser)).font(.caption2).foregroundStyle(.tertiary)
            Button("Use \(CookieBrowsers.name(browser)) Login and Retry") {
                model.engine.setCookies(job.id, .browser(name: browser, profile: nil))
                model.engine.retry(job.id)
            }
        }
    }
}

enum CookieBrowsers {
    static let all: [(id: String, name: String)] = [("safari", "Safari"), ("chrome", "Chrome"), ("firefox", "Firefox"),
                                                     ("brave", "Brave"), ("edge", "Edge"), ("vivaldi", "Vivaldi"), ("opera", "Opera")]
    static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }
    static func note(for id: String) -> String {
        switch id {
        case "safari": "Safari cookies need Full Disk Access for DLLC (System Settings › Privacy & Security)."
        case "chrome", "brave", "edge", "vivaldi", "opera": "macOS will ask to allow Keychain access to decrypt the browser’s cookies."
        default: "Cookies are read locally each time and never stored or logged by DLLC."
        }
    }
}
