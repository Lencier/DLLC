import AppKit
import DLLCCore
import Network
import Observation
import SwiftUI
import UserNotifications

enum ThemeChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { self == .system ? "Follow System" : rawValue.capitalized }
}

/// Persisted user preferences (UserDefaults). Only small, non-sensitive values live here.
struct Preferences {
    static let defaults = UserDefaults.standard

    static var destination: URL {
        get {
            if let p = defaults.string(forKey: "destination"), !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
            let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            return dl.appendingPathComponent(AppIdentity.name, isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: "destination") }
    }

    static var defaultOptions: OutputOptions {
        get {
            guard let data = defaults.data(forKey: "defaultOptions"),
                  var o = try? JSONDecoder().decode(OutputOptions.self, from: data) else { return OutputOptions() }
            o.range = nil; o.selectedEntries = nil; o.quality = .best
            if o.kind == .clip || o.kind == .gif { o.kind = .video }
            return o
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "defaultOptions") }
    }

    static var theme: ThemeChoice {
        get { ThemeChoice(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "theme") }
    }

    static var limits: ConcurrencyLimits {
        get {
            guard let d = defaults.data(forKey: "limits"), let l = try? JSONDecoder().decode(ConcurrencyLimits.self, from: d) else {
                return ConcurrencyLimits()
            }
            return l
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "limits") }
    }

    static var autoLoadSourceMinutes: Double {
        // Off by default: the online preview (≤720p, streamed, nothing kept on disk) is enough to watch
        // and mark times; the full source is fetched only when asked for.
        get { defaults.object(forKey: "autoLoadSourceMinutes") as? Double ?? 0 }
        set { defaults.set(newValue, forKey: "autoLoadSourceMinutes") }
    }

    /// Cache budget in GB (sources + previews) and how many days unused copies are kept.
    static var cacheLimitGB: Int {
        get { defaults.object(forKey: "cacheLimitGB") as? Int ?? 2 }
        set { defaults.set(newValue, forKey: "cacheLimitGB") }
    }
    static var cacheMaxAgeDays: Int {
        get { defaults.object(forKey: "cacheMaxAgeDays") as? Int ?? 7 }
        set { defaults.set(newValue, forKey: "cacheMaxAgeDays") }
    }
    static var cachePolicy: CachePolicy {
        CachePolicy(limitBytes: Int64(cacheLimitGB) * CachePolicy.gigabyte, maxAge: Double(cacheMaxAgeDays) * 86_400)
    }

    /// Look for a new DLLC on GitHub at launch, at most once a day.
    static var autoCheckAppUpdates: Bool {
        get { defaults.object(forKey: "autoCheckAppUpdates") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoCheckAppUpdates") }
    }
    static var lastAppUpdateCheck: Date {
        get { defaults.object(forKey: "lastAppUpdateCheck") as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: "lastAppUpdateCheck") }
    }

    static var hardwareEncoding: Bool {
        get { defaults.object(forKey: "hardwareEncoding") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "hardwareEncoding") }
    }

    static var snapshotFormat: ImageFormat {
        get { ImageFormat(rawValue: defaults.string(forKey: "snapshotFormat") ?? "") ?? .png }
        set { defaults.set(newValue.rawValue, forKey: "snapshotFormat") }
    }

    static var copySnapshotToClipboard: Bool {
        get { defaults.object(forKey: "copySnapshot") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "copySnapshot") }
    }

    /// Browser cookie connection chosen by the user (opt-in). Applied only to jobs where the user enables it.
    static var cookieBrowser: String? {
        get { defaults.string(forKey: "cookieBrowser") }
        set { defaults.set(newValue, forKey: "cookieBrowser") }
    }
}

struct Banner: Identifiable, Equatable {
    enum Kind { case info, warning, error }
    let id = UUID()
    var kind: Kind
    var text: String
    var actionTitle: String?
    var action: (() -> Void)?
    static func == (a: Banner, b: Banner) -> Bool { a.id == b.id }
}

@MainActor
@Observable
final class AppModel {
    let paths: AppPaths = {
        #if DEBUG
        // Development only: a separate data folder so automated UI runs never touch the real queue or songs.
        if let d = ProcessInfo.processInfo.environment["DLLC_DATA_DIR"] {
            let root = URL(fileURLWithPath: d, isDirectory: true)
            return AppPaths(applicationSupport: root.appendingPathComponent("Support"), caches: root.appendingPathComponent("Caches"))
        }
        #endif
        return AppPaths.standard()
    }()
    private(set) var engine: QueueEngine!
    private(set) var worker: MediaWorker?
    private(set) var toolError: String?
    private(set) var tools: ToolPaths?

    var selection: Set<UUID> = []
    /// The job shown in the preview workspace. Its PlayerController lives here, not in the view, so
    /// SwiftUI rebuilding the split view never restarts the preview or a source download.
    var workspaceJobID: UUID? {
        didSet { if workspaceJobID != oldValue { replaceWorkspaceController() } }
    }
    private(set) var workspaceController: PlayerController?
    /// Narrow (single-pane) layout: whether the workspace covers the queue. Every open shows it again.
    var narrowShowsWorkspace = false
    var banner: Banner?
    var selectionSheetJobID: UUID?

    // MARK: Projects
    /// Named groups of jobs. Saved to Application Support; each one saves into its own subfolder.
    var projects: [Project] = [] { didSet { saveProjects() } }
    // MARK: Songs (Song Cues)
    var songs: [Song] = [] { didSet { if songsLoaded { songSave = .saving; songStore.saveSoon(songs) } } }
    @ObservationIgnored var songsLoaded = false
    /// Songs save themselves (sections, lyrics, title): there is no Save button. This shows it happening.
    enum SongSaveState { case saved, saving, failed }
    var songSave: SongSaveState = .saved
    @ObservationIgnored lazy var songStore: SongStore = {
        let store = SongStore(url: paths.songsFile)
        store.onSaved = { [weak self] ok in
            Task { @MainActor in self?.songSave = ok ? .saved : .failed }
        }
        return store
    }()
    /// The song shown in the main area instead of the queue (nil = queue).
    var selectedSongID: UUID?
    /// Download or Song Cues; remembered between launches.
    /// The Quick Tips side panel (Tips button, ⌘?).
    var showTips = false
    var mode: AppMode = AppMode(rawValue: UserDefaults.standard.string(forKey: "appMode") ?? "") ?? .download {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "appMode") }
    }

    /// Sidebar choice: nil shows everything.
    var selectedProjectID: UUID? {
        didSet {
            guard selectedProjectID != oldValue else { return }
            selection = selection.filter { id in visibleJobs.contains { $0.id == id } }
            // The preview belongs to the list it was opened from: close it when its item isn't in this project.
            if let ws = workspaceJobID, !visibleJobs.contains(where: { $0.id == ws }) {
                workspaceController?.player.pause()
                workspaceJobID = nil
                narrowShowsWorkspace = false
            }
        }
    }
    var isOnline = true

    var destination: URL = Preferences.destination {
        didSet {
            Preferences.destination = destination
            engine?.defaultDestination = destination
        }
    }
    var defaultOptions: OutputOptions = Preferences.defaultOptions {
        didSet { Preferences.defaultOptions = defaultOptions }
    }
    var theme: ThemeChoice = Preferences.theme {
        didSet { Preferences.theme = theme; applyTheme() }
    }
    var limits: ConcurrencyLimits = Preferences.limits {
        didSet {
            Preferences.limits = limits
            engine?.limits = limits
            let gate = worker?.processingGate
            let n = limits.processing
            Task { await gate?.setLimit(n) }
        }
    }

    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    /// iPhone hotspot or Low Data Mode: never download anything that wasn't asked for.
    private(set) var isMeteredNetwork = false
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var wasOffline = false

    init() {
        try? paths.createDirectories()
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        ProcessSupervisor.shared.configureRegistry(paths.processRegistry)
        _ = ProcessSupervisor.shared.reapOrphans()

        let fallbackWorker = UnavailableWorker()
        do {
            // DLLC_TOOLS_DIR (run against Vendor/tools) is a development aid only; release builds always
            // use the tools inside the signed bundle.
            #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            #else
            let environment: [String: String] = [:]
            #endif
            let tools = try ToolLocator.resolve(bundle: .main, paths: paths, environment: environment)
            self.tools = tools
            let worker = MediaWorker(tools: tools, paths: paths, processingLimit: Preferences.limits.processing,
                                     hardwareEncoding: Preferences.hardwareEncoding)
            self.worker = worker
            engine = QueueEngine(worker: worker, store: JobStore(url: paths.queueFile),
                                 defaultDestination: destination, limits: Preferences.limits)
        } catch {
            toolError = "DLLC’s bundled tools are missing or damaged (\(error)). Reinstall the app."
            engine = QueueEngine(worker: fallbackWorker, store: JobStore(url: paths.queueFile),
                                 defaultDestination: destination, limits: Preferences.limits)
        }
        engine.cleanupWorkspace = { [paths] id in
            let dir = paths.jobsWorkspace.appendingPathComponent(id.uuidString, isDirectory: true)
            DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: dir) }
        }
        engine.onJobFinished = { [weak self] job in self?.jobFinished(job) }
        worker?.sources.policy = Preferences.cachePolicy
        // A link's cached full-quality copy goes with its last item in the queue.
        engine.onJobsRemoved = { [weak self] removed in
            guard let self, let sources = self.worker?.sources else { return }
            let still = Set(self.engine.jobs.map { LinkExtractor.canonicalKey($0.url) })
            let gone = removed.map(\.url).filter { !still.contains(LinkExtractor.canonicalKey($0)) }
            DispatchQueue.global(qos: .utility).async { sources.removeOwned(forURLs: gone) }
        }
        loadProjects()
        songs = songStore.load()
        songsLoaded = true
        engine.restore()
        // Synchronous listing: job tasks launched by restore() can't run before this main-actor turn ends.
        sweepOrphanWorkspaces()
        applyTheme()
        startNetworkMonitor()
        observeActivity()
        if Preferences.autoCheckAppUpdates, Date().timeIntervalSince(Preferences.lastAppUpdateCheck) > 20 * 3600 {
            checkForAppUpdate(manual: false)
        }
    }

    // MARK: App updates

    /// A newer DLLC found on GitHub, and what the updater is doing.
    var appUpdate: AppRelease?
    var appUpdateStatus: String?
    var appUpdateBusy = false
    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    func checkForAppUpdate(manual: Bool) {
        guard !appUpdateBusy else { return }
        appUpdateBusy = true
        if manual { appUpdateStatus = "Checking…" }
        Task {
            defer { appUpdateBusy = false }
            do {
                let latest = try await AppUpdate.fetchLatest()
                Preferences.lastAppUpdateCheck = Date()
                if let latest, AppUpdate.isNewer(latest.version, than: Self.appVersion) {
                    appUpdate = latest
                    appUpdateStatus = "DLLC \(latest.version) is available."
                    show(.info, "DLLC \(latest.version) is available.", action: "Update") { [weak self] in self?.installAppUpdate() }
                } else {
                    appUpdate = nil
                    if manual { appUpdateStatus = "You have the latest version (\(Self.appVersion))." }
                }
            } catch {
                if manual { appUpdateStatus = "Couldn’t check for updates. Check your connection." }
            }
        }
    }

    /// Downloads and verifies the new version, then quits so a helper can swap it in and reopen DLLC.
    func installAppUpdate() {
        guard let release = appUpdate, !appUpdateBusy else { return }
        if engine.jobs.contains(where: { $0.state.isActive }) {
            appUpdateStatus = "Finish or cancel the current downloads, then update."
            show(.warning, "Finish or cancel the current downloads, then update.")
            return
        }
        appUpdateBusy = true
        appUpdateStatus = "Downloading DLLC \(release.version)…"
        Task {
            defer { appUpdateBusy = false }
            do {
                let current = Bundle.main.bundleURL
                try AppUpdate.checkReplaceable(current)
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("DLLC-update", isDirectory: true)
                let app = try await AppUpdate.prepare(release, workDir: work)
                appUpdateStatus = "Restarting to finish the update…"
                try AppUpdate.launchSwap(newApp: app, current: current, pid: ProcessInfo.processInfo.processIdentifier)
                NSApp.terminate(nil)
            } catch let failure as AppUpdate.Failure {
                appUpdateStatus = failure.description
                show(.error, failure.description)
            } catch {
                appUpdateStatus = "The update couldn’t be downloaded. Check your connection and try again."
                show(.error, appUpdateStatus!)
            }
        }
    }

    // MARK: Adding links

    /// Explicit paste action only — the clipboard is never monitored.
    func pasteLinks() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let links = LinkExtractor.extract(from: text)
        if links.isEmpty {
            show(.warning, "No links found on the clipboard.")
            return
        }
        add(links)
    }

    func add(_ links: [String], options: OutputOptions? = nil) {
        let project = selectedProject
        let result = engine.add(urls: links, options: options ?? defaultOptions,
                                destination: folder(for: project), projectID: project?.id)
        if let first = result.added.first, result.added.count == 1 { selection = [first] }
        if !result.rejected.isEmpty {
            show(.warning, "\(result.rejected.count) item\(result.rejected.count == 1 ? " isn’t a" : "s aren’t") valid web link\(result.rejected.count == 1 ? "" : "s").")
        } else if !result.duplicates.isEmpty {
            let ids = result.added.filter { id in result.duplicates.contains { engine.job(id)?.url == $0 } }
            show(.info, result.duplicates.count == 1 ? "This link is already in the queue — added again."
                 : "\(result.duplicates.count) links were already in the queue — added again.",
                 action: "Undo") { [weak self] in self?.engine.remove(ids) }
        }
    }

    // MARK: Projects

    var selectedProject: Project? { selectedProjectID.flatMap { id in projects.first { $0.id == id } } }

    /// Jobs shown in the queue for the sidebar's current choice.
    var visibleJobs: [Job] {
        guard let pid = selectedProjectID else { return engine.jobs }
        return engine.jobs.filter { $0.projectID == pid }
    }

    func jobCount(in projectID: UUID?) -> Int {
        guard let projectID else { return engine.jobs.count }
        return engine.jobs.filter { $0.projectID == projectID }.count
    }

    /// Save folder for a project: the folder the user chose for it, else a subfolder of the main save folder.
    func folder(for project: Project?) -> URL {
        guard let project else { return destination }
        if let path = project.saveFolderPath { return URL(fileURLWithPath: path, isDirectory: true) }
        return destination.appendingPathComponent(project.folderName, isDirectory: true)
    }

    func project(_ id: UUID?) -> Project? { id.flatMap { id in projects.first { $0.id == id } } }

    /// Where to save for a project (remembered after the first time) or, outside a project, where to save
    /// this time (always asked). Nil when the user cancels.
    func saveFolder(forProject projectID: UUID?, itemCount: Int = 1) -> URL? {
        if let p = project(projectID) {
            if let path = p.saveFolderPath { return URL(fileURLWithPath: path, isDirectory: true) }
            guard let url = askForFolder(
                message: "Where should “\(p.name)” save its files? DLLC will remember this folder for the project.",
                suggested: destination) else { return nil }
            setSaveFolder(url, forProject: p.id)
            return url
        }
        let what = itemCount == 1 ? "this download" : "these \(itemCount) downloads"
        return askForFolder(message: "Where should DLLC save \(what)?", suggested: lastAskedFolder ?? destination)
    }

    /// Changes (or sets) a project's save folder; items not yet saving follow it.
    func setSaveFolder(_ url: URL, forProject id: UUID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].saveFolderPath = url.path
        let ids = engine.jobs.filter { $0.projectID == id }.map(\.id)
        engine.assign(ids, toProject: id, destination: url)
    }

    func changeSaveFolder(forProject id: UUID) {
        guard let p = project(id), let url = askForFolder(
            message: "Choose a new save folder for “\(p.name)”.", suggested: folder(for: p)) else { return }
        setSaveFolder(url, forProject: id)
        show(.info, "“\(p.name)” now saves to \(url.lastPathComponent).")
    }

    @ObservationIgnored private var lastAskedFolder: URL?

    private func askForFolder(message: String, suggested: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Here"
        panel.message = message
        panel.directoryURL = FileManager.default.fileExists(atPath: suggested.path) ? suggested : destination
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        lastAskedFolder = url
        return url
    }

    /// Starts downloads, asking where to save first (once per project, every time outside a project).
    func download(_ ids: [UUID]) {
        let jobs = ids.compactMap { engine.job($0) }
        var groups: [UUID?: [UUID]] = [:]
        var order: [UUID?] = []
        for job in jobs {
            if groups[job.projectID] == nil { order.append(job.projectID) }
            groups[job.projectID, default: []].append(job.id)
        }
        for key in order {
            let group = groups[key] ?? []
            guard let folder = saveFolder(forProject: key, itemCount: group.count) else { continue }
            engine.assign(group, toProject: key, destination: folder)
            for id in group { engine.start(id) }
        }
    }

    @discardableResult
    func createProject(named name: String) -> Project {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = base.isEmpty ? "New Project" : base
        let stem = Project.suffixableStem(candidate)
        var n = 2
        while projects.contains(where: { $0.folderName.caseInsensitiveCompare(Project(name: candidate).folderName) == .orderedSame }) {
            candidate = "\(stem) \(n)"; n += 1
        }
        let project = Project(name: candidate)
        projects.append(project)
        selectedProjectID = project.id
        return project
    }

    func renameProject(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = projects.firstIndex(where: { $0.id == id }) else { return }
        // Two projects must never share a folder ("A/B" and "A-B" map to the same folder name).
        var candidate = trimmed, n = 2
        let stem = Project.suffixableStem(trimmed)
        while projects.contains(where: { $0.id != id && Project(name: $0.name).folderName.caseInsensitiveCompare(Project(name: candidate).folderName) == .orderedSame }) {
            candidate = "\(stem) \(n)"; n += 1
        }
        projects[i].name = candidate
        // A folder the user picked stays as it is; otherwise items not yet saving follow the new folder name.
        guard projects[i].saveFolderPath == nil else { return }
        let ids = engine.jobs.filter { $0.projectID == id }.map(\.id)
        engine.assign(ids, toProject: id, destination: folder(for: projects[i]))
    }

    /// Deletes the group only: its items move back to "All Downloads", files on disk are untouched.
    func deleteProject(_ id: UUID) {
        let ids = engine.jobs.filter { $0.projectID == id }.map(\.id)
        engine.assign(ids, toProject: nil, destination: destination)
        // Its songs go with it (only the list entries; the audio files are never touched).
        songs.removeAll { $0.projectID == id }
        if let sid = selectedSongID, !songs.contains(where: { $0.id == sid }) { selectedSongID = nil }
        projects.removeAll { $0.id == id }
        if selectedProjectID == id { selectedProjectID = nil }
    }

    func move(_ ids: [UUID], toProject projectID: UUID?) {
        let project = projectID.flatMap { id in projects.first { $0.id == id } }
        engine.assign(ids, toProject: project?.id, destination: folder(for: project))
        if let pid = selectedProjectID, pid != projectID { selection.subtract(ids) }
        show(.info, "Moved \(ids.count) item\(ids.count == 1 ? "" : "s") to \(project?.name ?? "All Downloads").")
    }

    func revealProjectFolder(_ project: Project?) {
        let url = folder(for: project)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    /// Download All for what the sidebar shows (a project downloads only its own items).
    func downloadAllVisible() {
        download(visibleJobs.filter { [.ready, .interrupted, .analyzing, .needsSelection].contains($0.state) }.map(\.id))
    }

    /// Clear Completed for what the sidebar shows; closes the preview if it showed one of them.
    func clearCompletedVisible() {
        let ids = visibleJobs.filter { $0.state == .completed }.map(\.id)
        guard !ids.isEmpty else { return }
        if let ws = workspaceJobID, ids.contains(ws) { workspaceJobID = nil }
        selection.subtract(ids)
        engine.remove(ids)
    }

    /// Move Up / Down among the rows the user can see (inside a project, hidden rows are skipped).
    func moveVisible(_ id: UUID, by delta: Int) {
        let visible = visibleJobs
        guard let v = visible.firstIndex(where: { $0.id == id }) else { return }
        let target = v + delta
        guard visible.indices.contains(target),
              let from = engine.jobs.firstIndex(where: { $0.id == id }),
              let to = engine.jobs.firstIndex(where: { $0.id == visible[target].id }) else { return }
        engine.move(id, by: to - from)
    }

    private var projectsFile: URL { paths.applicationSupport.appendingPathComponent("projects.json") }

    private func loadProjects() {
        guard let data = try? Data(contentsOf: projectsFile),
              let list = try? JSONDecoder().decode([Project].self, from: data) else { return }
        projects = list
    }

    private func saveProjects() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: projectsFile, options: .atomic)
    }

    // MARK: Workspace

    func openWorkspace(_ id: UUID, mode: WorkspaceMode? = nil) {
        // Image posts have no timeline to preview.
        if engine.job(id)?.info?.hasDirectItems == true { return }
        workspaceJobID = id
        narrowShowsWorkspace = true
        selection = [id]
        if let mode { workspaceController?.mode = mode }
    }

    private func replaceWorkspaceController() {
        workspaceController?.tearDown()
        workspaceController = nil
        guard let id = workspaceJobID, engine.job(id) != nil else { return }
        let controller = PlayerController(jobID: id, model: self)
        workspaceController = controller
        controller.start()
    }

    // MARK: Banners

    func show(_ kind: Banner.Kind, _ text: String, action: String? = nil, perform: (() -> Void)? = nil) {
        banner = Banner(kind: kind, text: text, actionTitle: action, action: perform)
        bannerTask?.cancel()
        let id = banner?.id
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(action == nil ? 4 : 8))
            if self?.banner?.id == id { self?.banner = nil }
        }
    }

    // MARK: Files

    /// Row whose output popover should open (used after "Download Again" adds a copy).
    var outputPopoverRequest: UUID?

    /// Adds a fresh copy of a finished item right below it, selected with its output picker open,
    /// so it can be downloaded again — at the same or another quality, type or size.
    func downloadAgain(_ job: Job) {
        var o = job.options
        if o.kind == .clip || o.kind == .gif { o.range = job.options.range }
        let id = engine.addDerived(from: job, options: o, startNow: false)
        selection = [id]
        outputPopoverRequest = id
        show(.info, "Added a copy — choose the quality, then Download.")
    }

    func reveal(_ job: Job) {
        let urls = job.outputFiles.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty {
            show(.warning, "The file was moved or deleted.", action: "Download Again") { [weak self] in self?.downloadAgain(job) }
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func open(_ job: Job) {
        guard let path = job.outputFiles.first, FileManager.default.fileExists(atPath: path) else {
            show(.warning, "The file was moved or deleted."); return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }

    // MARK: Theme

    func applyTheme() {
        switch theme {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: System integration

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let metered = path.isExpensive || path.isConstrained
            Task { @MainActor in
                guard let self else { return }
                self.isOnline = online
                self.isMeteredNetwork = metered
                if online && self.wasOffline { self.engine.retryNetworkFailures() }
                self.wasOffline = !online
            }
        }
        monitor.start(queue: DispatchQueue(label: "dllc.network"))
        pathMonitor = monitor
        // Manual or lid-close sleep cuts connections mid-download; once awake and online, retry the
        // jobs that failed with a network error (stream links are refreshed when they're stale).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.isOnline else { return }
                self.engine.retryNetworkFailures()
            }
        }
    }

    /// Keeps the Mac from idle-sleeping only while work is active; observes the queue cheaply.
    private func observeActivity() {
        withObservationTracking {
            _ = engine.jobs.map(\.state)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateActivity()
                self?.observeActivity()
            }
        }
        updateActivity()
    }

    private func updateActivity() {
        let busy = engine.jobs.contains { $0.state == .downloading || $0.state == .processing }
        if busy && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Downloading media")
        } else if !busy, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
        let active = engine.jobs.filter { $0.state.isActive && $0.state != .analyzing }.count
        NSApp?.dockTile.badgeLabel = active > 0 ? "\(active)" : nil
    }

    private func jobFinished(_ job: Job) {
        // UNUserNotificationCenter raises an exception outside an .app bundle (e.g. `swift run`).
        guard !NSApp.isActive, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        switch job.state {
        case .completed: content.title = "Saved"; content.body = job.displayTitle
        case .failed: content.title = "Couldn’t save"; content.body = "\(job.displayTitle) — \(job.error?.message ?? "")"
        default: return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil))
        }
    }

    private func sweepOrphanWorkspaces() {
        let known = Set(engine.jobs.map { $0.id.uuidString })
        let dir = paths.jobsWorkspace
        let sourceCache = paths.sourceCache
        // List leftovers now, at launch, before any new job or source download can create folders;
        // only the (slow) deletion happens in the background.
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var stale = items.filter { !known.contains($0) }.map { dir.appendingPathComponent($0) }
        // Partial source downloads interrupted by a crash or force quit.
        let sources = (try? FileManager.default.contentsOfDirectory(atPath: sourceCache.path)) ?? []
        stale += sources.filter { $0.hasPrefix("tmp-") }.map { sourceCache.appendingPathComponent($0) }
        // Half-written preview proxies from a quit mid-conversion.
        let proxies = paths.proxyCache
        stale += ((try? FileManager.default.contentsOfDirectory(atPath: proxies.path)) ?? [])
            .filter { !$0.hasSuffix("-proxy.mp4") }.map { proxies.appendingPathComponent($0) }
        let cache = worker?.sources
        let waveforms = paths.waveformCache
        DispatchQueue.global(qos: .utility).async {
            for url in stale { try? FileManager.default.removeItem(at: url) }
            // Keep the caches within their limits (waveforms are tiny; unused ones expire).
            CacheFolder.trim(waveforms, maxBytes: 200 * 1_048_576, maxAge: Preferences.cachePolicy.maxAge)
            AppModel.trimProxies(proxies)
            cache?.trim()
        }
    }

    /// Preview proxies are cheap to rebuild; keep at most this much of them.
    nonisolated static func trimProxies(_ dir: URL) {
        let policy = Preferences.cachePolicy
        CacheFolder.trim(dir, maxBytes: policy.proxyLimit(free: MediaWorker.freeBytes(at: dir.deletingLastPathComponent())),
                         maxAge: policy.maxAge)
    }

    /// Applies new cache settings right away.
    func applyCachePolicy() {
        let sources = worker?.sources
        sources?.policy = Preferences.cachePolicy
        let proxies = paths.proxyCache
        DispatchQueue.global(qos: .utility).async {
            sources?.trim()
            AppModel.trimProxies(proxies)
        }
    }

    var isLowOnSpace: Bool { CachePolicy.isLowOnSpace(free: MediaWorker.freeBytes(at: paths.caches)) }

    func terminate() {
        songStore.flush()
        engine.prepareForTermination()
        ProcessSupervisor.shared.terminateAll(timeout: 3)
    }
}

/// Used when bundled tools are missing: every job fails with a clear message.
struct UnavailableWorker: JobWorker {
    func analyze(url: String, playlistItems: [Int]?, cookies: CookieSource) async throws -> MediaInfo {
        throw JobError(category: .toolFailure, message: "DLLC’s bundled tools are missing.",
                       suggestion: "Reinstall DLLC.", isRecoverable: false)
    }
    func execute(job: Job, destination: URL, events: @escaping @Sendable (JobEvent) -> Void) async throws -> JobOutcome {
        throw JobError(category: .toolFailure, message: "DLLC’s bundled tools are missing.",
                       suggestion: "Reinstall DLLC.", isRecoverable: false)
    }
}
