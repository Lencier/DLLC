import DLLCCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            TransferSettings().tabItem { Label("Transfers", systemImage: "arrow.down.circle") }
            PrivacySettings().tabItem { Label("Privacy & Updates", systemImage: "lock.shield") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            LabeledContent("Save to") {
                HStack {
                    Text(model.destination.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") { model.chooseDestination() }
                }
            }
            Picker("New links", selection: Binding(get: { DefaultChoice(model.defaultOptions) },
                                                  set: { $0.apply(to: &model.defaultOptions) })) {
                ForEach(DefaultChoice.allCases) { Text($0.title).tag($0) }
            }
            Picker("Appearance", selection: $model.theme) {
                ForEach(ThemeChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
    }
}

private struct TransferSettings: View {
    @Environment(AppModel.self) private var model
    @State private var cacheSize: Int64 = 0
    @State private var autoLoad = Preferences.autoLoadSourceMinutes
    @State private var hardware = Preferences.hardwareEncoding
    @State private var cacheLimit = Preferences.cacheLimitGB
    @State private var cacheAge = Preferences.cacheMaxAgeDays

    var body: some View {
        @Bindable var model = model
        Form {
            Stepper("Simultaneous downloads: \(model.limits.downloads)", value: $model.limits.downloads, in: 1...6)
            Stepper("Simultaneous conversions: \(model.limits.processing)", value: $model.limits.processing, in: 1...3)
            Picker("Load full source for preview", selection: $autoLoad) {
                Text("Never automatically (recommended)").tag(0.0)
                Text("Videos up to 5 min").tag(5.0)
                Text("Videos up to 10 min").tag(10.0)
                Text("Videos up to 30 min").tag(30.0)
            }
            .onChange(of: autoLoad) { _, v in Preferences.autoLoadSourceMinutes = v }
            .help("Never on a hotspot, in Low Data Mode or when the disk is nearly full.")
            Toggle("Use hardware encoder for MP4 conversion", isOn: $hardware)
                .onChange(of: hardware) { _, v in Preferences.hardwareEncoding = v }
                .help("Takes effect after relaunch. VideoToolbox is much faster for 4K; software x264 is slightly more efficient.")
            Picker("Cache size", selection: $cacheLimit) {
                Text("1 GB").tag(1); Text("2 GB").tag(2); Text("5 GB").tag(5); Text("10 GB").tag(10)
            }
            .onChange(of: cacheLimit) { _, v in Preferences.cacheLimitGB = v; model.applyCachePolicy(); refresh() }
            Picker("Delete unused copies after", selection: $cacheAge) {
                Text("1 day").tag(1); Text("3 days").tag(3); Text("7 days").tag(7); Text("30 days").tag(30)
            }
            .onChange(of: cacheAge) { _, v in Preferences.cacheMaxAgeDays = v; model.applyCachePolicy(); refresh() }
            LabeledContent("Cache in use") {
                HStack {
                    Text(ByteFormat.string(cacheSize)).foregroundStyle(.secondary)
                    Button("Clear Cache") {
                        model.worker?.sources.clearOwned()
                        CacheFolder.clear(model.paths.proxyCache)
                        refresh()
                    }
                    .disabled(cacheSize == 0)
                }
            }
            Text("The cache holds full-quality copies for exact frames and quick exports, plus small previews for videos macOS can’t play. A link’s copy is deleted when its item leaves the queue, and replaced by your file once you download it. When less than 15 GB is free, the cache shrinks to 512 MB and sources aren’t loaded automatically. Your saved files are never touched.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let sources = model.worker?.sources
        let proxies = model.paths.proxyCache
        Task.detached {
            let s = (sources?.ownedSize() ?? 0) + CacheFolder.size(of: proxies)
            await MainActor.run { cacheSize = s }
        }
    }
}

private struct PrivacySettings: View {
    @Environment(AppModel.self) private var model
    @State private var latest: String?
    @State private var checking = false
    @State private var message: String?
    @State private var versions: [String] = []
    @State private var active: String?
    @State private var bundledVersion = "…"
    @State private var autoCheck = Preferences.autoCheckAppUpdates

    var body: some View {
        Form {
            Section("Browser logins") {
                Text("Off by default. You can enable a browser login per item (Output › Advanced) for content you’re allowed to view. Cookies are read locally at download time, never stored, logged or sent anywhere except the site itself. DLLC never asks for passwords.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Forget Browser Logins on All Items") {
                    var busy = 0
                    for job in model.engine.jobs where job.cookies != .none {
                        if job.state.isActive { busy += 1 } else { model.engine.setCookies(job.id, .none) }
                    }
                    try? FileManager.default.removeItem(at: model.paths.cookiesDirectory)
                    try? model.paths.createDirectories()
                    message = busy == 0 ? "Browser logins removed from all items."
                        : "Browser logins removed, except \(busy) item\(busy == 1 ? "" : "s") still working. Cancel \(busy == 1 ? "it" : "them") or forget again when finished."
                }
            }
            Section("App updates") {
                LabeledContent("This version", value: AppModel.appVersion)
                Toggle("Check for updates automatically (once a day)", isOn: Binding(
                    get: { Preferences.autoCheckAppUpdates }, set: { Preferences.autoCheckAppUpdates = $0; autoCheck = $0 }))
                    .id(autoCheck)
                HStack {
                    Button(model.appUpdateBusy ? "Working…" : "Check Now") { model.checkForAppUpdate(manual: true) }
                        .disabled(model.appUpdateBusy)
                    if let r = model.appUpdate {
                        Button("Install \(r.version) and Restart") { model.installAppUpdate() }
                            .disabled(model.appUpdateBusy)
                        Link("What’s new", destination: r.pageURL)
                    }
                }
                if let s = model.appUpdateStatus { Text(s).font(.caption) }
                Text("Updates come only from the DLLC releases on GitHub (\(AppUpdate.repository)) and must carry the developer’s signature before they’re installed. The check sends nothing about you or your downloads.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("yt-dlp (site support)") {
                LabeledContent("Bundled", value: bundledVersion)
                LabeledContent("In use", value: active ?? "Bundled")
                HStack {
                    Button(checking ? "Checking…" : "Check for Update") { check() }.disabled(checking)
                    if let latest, latest != (active ?? bundledVersion) {
                        Button("Install \(latest)") { install(latest) }.disabled(checking)
                    }
                    if active != nil {
                        Button("Use Bundled Version") {
                            try? YTDLPUpdateStore(paths: model.paths).setActive(nil)
                            refresh()
                            message = "Switched back to the bundled yt-dlp. Relaunch to apply."
                        }
                    }
                }
                Text("Updates download only from the official yt-dlp GitHub release. The release’s checksum list must carry a valid signature from yt-dlp’s signing key, and the download must match it, before anything runs. Updates are kept outside the app so you can roll back. Relaunch after updating.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).font(.caption) }
            }
            Section("About") {
                Text(versionsText).font(.caption.monospaced()).textSelection(.enabled)
                Button("Show Licenses") {
                    if let url = Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: "txt") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    private var versionsText: String {
        let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let tools = (Bundle.main.url(forResource: "VERSIONS", withExtension: "txt", subdirectory: "tools"))
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return "\(AppIdentity.name) \(app)\n\(tools)"
    }

    private func refresh() {
        let store = YTDLPUpdateStore(paths: model.paths)
        versions = store.installedVersions()
        active = store.activeVersion
        if let tools = model.tools {
            let exe = tools.ytdlp.path.contains("Application Support")
                ? Bundle.main.resourceURL!.appendingPathComponent("tools/yt-dlp/yt-dlp_macos") : tools.ytdlp
            Task {
                let r = try? await ProcessSupervisor.shared.run(ProcessSpec(executable: exe, arguments: ["--version"]), captureStdout: true)
                bundledVersion = r.map { String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "?"
            }
        }
    }

    private func updater() -> YTDLPUpdater {
        YTDLPUpdater(store: YTDLPUpdateStore(paths: model.paths), verifySignature: YTDLPSignature.verifier)
    }

    private func check() {
        checking = true; message = nil
        Task {
            defer { checking = false }
            do {
                latest = try await updater().latestVersion()
                message = latest == (active ?? bundledVersion) ? "You have the latest version." : "Version \(latest!) is available."
            } catch { message = "Couldn’t check for updates. Check your connection." }
        }
    }

    private func install(_ v: String) {
        checking = true; message = "Downloading and verifying \(v)…"
        Task {
            defer { checking = false }
            do {
                let inUse = model.tools?.ytdlp.deletingLastPathComponent().lastPathComponent
                _ = try await updater().install(version: v, tmpDirectory: model.paths.caches, inUse: inUse)
                refresh()
                message = "Installed \(v). Relaunch DLLC to use it."
            } catch {
                message = "Update failed verification and was not installed (\(error)). The current version is unchanged."
            }
        }
    }
}
