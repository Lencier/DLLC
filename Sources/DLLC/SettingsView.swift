import DLLCCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            TransferSettings().tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            PrivacySettings(part: .privacy).tabItem { Label("Privacy", systemImage: "hand.raised") }
            PrivacySettings(part: .updates).tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 560, height: 520)
    }
}

/// A System Settings–style row: a small coloured icon tile, a title and an optional hint, then the control.
private struct SettingRow<Content: View>: View {
    var icon: String, tint: Color, title: String, hint: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        LabeledContent {
            content
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppIdentity.name).font(.title2.weight(.semibold))
                        Text("Version \(AppModel.appVersion)").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            Section("Saving") {
                SettingRow(icon: "folder.fill", tint: .blue, title: "Save to", hint: model.destination.path) {
                    Button("Choose…") { model.chooseDestination() }
                }
                SettingRow(icon: "link", tint: .teal, title: "New links", hint: "What a pasted link is set to download") {
                    Picker("", selection: Binding(get: { DefaultChoice(model.defaultOptions) },
                                                  set: { $0.apply(to: &model.defaultOptions) })) {
                        ForEach(DefaultChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            Section("Look") {
                SettingRow(icon: "circle.lefthalf.filled", tint: .indigo, title: "Appearance") {
                    Picker("", selection: $model.theme) {
                        ForEach(ThemeChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
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
            Section("At the same time") {
                SettingRow(icon: "arrow.down", tint: .blue, title: "Downloads") {
                    Stepper("\(model.limits.downloads)", value: $model.limits.downloads, in: 1...6).monospacedDigit()
                }
                SettingRow(icon: "gearshape.2.fill", tint: .orange, title: "Conversions") {
                    Stepper("\(model.limits.processing)", value: $model.limits.processing, in: 1...3).monospacedDigit()
                }
            }
            Section("Preview & conversion") {
                SettingRow(icon: "play.rectangle.fill", tint: .pink, title: "Load full source for preview",
                           hint: "Never on a hotspot, in Low Data Mode or when the disk is nearly full") {
                    Picker("", selection: $autoLoad) {
                        Text("Never (recommended)").tag(0.0)
                        Text("Up to 5 min").tag(5.0)
                        Text("Up to 10 min").tag(10.0)
                        Text("Up to 30 min").tag(30.0)
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: autoLoad) { _, v in Preferences.autoLoadSourceMinutes = v }
                }
                SettingRow(icon: "cpu", tint: .green, title: "Hardware encoder for MP4",
                           hint: "Much faster for 4K. Takes effect after relaunch") {
                    Toggle("", isOn: $hardware).labelsHidden().toggleStyle(.switch)
                        .onChange(of: hardware) { _, v in Preferences.hardwareEncoding = v }
                }
            }
            Section {
                SettingRow(icon: "internaldrive.fill", tint: .gray, title: "Cache size") {
                    Picker("", selection: $cacheLimit) {
                        Text("1 GB").tag(1); Text("2 GB").tag(2); Text("5 GB").tag(5); Text("10 GB").tag(10)
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: cacheLimit) { _, v in Preferences.cacheLimitGB = v; model.applyCachePolicy(); refresh() }
                }
                SettingRow(icon: "clock.arrow.circlepath", tint: .gray, title: "Delete unused copies after") {
                    Picker("", selection: $cacheAge) {
                        Text("1 day").tag(1); Text("3 days").tag(3); Text("7 days").tag(7); Text("30 days").tag(30)
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: cacheAge) { _, v in Preferences.cacheMaxAgeDays = v; model.applyCachePolicy(); refresh() }
                }
                SettingRow(icon: "trash.fill", tint: .red, title: "Cache in use", hint: ByteFormat.string(cacheSize)) {
                    Button("Clear Cache") {
                        model.worker?.sources.clearOwned()
                        CacheFolder.clear(model.paths.proxyCache)
                        refresh()
                    }
                    .disabled(cacheSize == 0)
                }
            } header: { Text("Cache") } footer: {
                Text("Full-quality copies for exact frames and quick exports. A link’s copy goes when its item leaves the queue. Your saved files are never touched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
    enum Part { case privacy, updates }
    var part: Part
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
            if part == .privacy { privacy } else { updates }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    @ViewBuilder private var privacy: some View {
        Section {
            SettingRow(icon: "eye.slash.fill", tint: .blue, title: "No tracking", hint: "No analytics, no accounts. Links go only to the site itself") { EmptyView() }
            SettingRow(icon: "doc.on.clipboard", tint: .teal, title: "Clipboard", hint: "Read only when you paste") { EmptyView() }
        } header: { Text("What DLLC does") }
        Section {
            SettingRow(icon: "key.fill", tint: .orange, title: "Browser logins", hint: "Off unless you turn it on for an item") {
                Button("Forget All") {
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
            if let message { Text(message).font(.caption) }
        } header: { Text("Logins") } footer: {
            Text("Enable a login per item (Output › Advanced) for content you’re allowed to view. Cookies are read locally at download time, never stored, logged or sent anywhere except the site itself. DLLC never asks for passwords.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var updates: some View {
        Section {
            SettingRow(icon: "app.badge.fill", tint: .red, title: "DLLC \(AppModel.appVersion)",
                       hint: model.appUpdate.map { "Version \($0.version) is ready" } ?? model.appUpdateStatus) {
                HStack {
                    if let r = model.appUpdate {
                        Link("What’s new", destination: r.pageURL)
                        Button("Install & Restart") { model.installAppUpdate() }
                            .buttonStyle(.borderedProminent).disabled(model.appUpdateBusy)
                    } else {
                        Button(model.appUpdateBusy ? "Checking…" : "Check Now") { model.checkForAppUpdate(manual: true) }
                            .disabled(model.appUpdateBusy)
                    }
                }
            }
            SettingRow(icon: "clock.fill", tint: .gray, title: "Check automatically", hint: "Once a day") {
                Toggle("", isOn: Binding(get: { Preferences.autoCheckAppUpdates },
                                         set: { Preferences.autoCheckAppUpdates = $0; autoCheck = $0 }))
                    .labelsHidden().toggleStyle(.switch).id(autoCheck)
            }
        } header: { Text("App") } footer: {
            Text("Updates come only from DLLC’s GitHub releases (\(AppUpdate.repository)) and must carry the developer’s signature. The check sends nothing about you or your downloads.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            SettingRow(icon: "globe", tint: .blue, title: "yt-dlp \(active ?? bundledVersion)",
                       hint: active == nil ? "Bundled version" : "Updated (bundled \(bundledVersion))") {
                HStack {
                    if active != nil {
                        Button("Use Bundled") {
                            try? YTDLPUpdateStore(paths: model.paths).setActive(nil)
                            refresh()
                            message = "Switched back to the bundled yt-dlp. Relaunch to apply."
                        }
                    }
                    if let latest, latest != (active ?? bundledVersion) {
                        Button("Install \(latest)") { install(latest) }.buttonStyle(.borderedProminent).disabled(checking)
                    } else {
                        Button(checking ? "Checking…" : "Check") { check() }.disabled(checking)
                    }
                }
            }
            if let message { Text(message).font(.caption) }
        } header: { Text("Site support") } footer: {
            Text("Sites change often; updating yt-dlp fixes most “can’t download” errors. Updates come only from yt-dlp’s official GitHub release, signature-checked before anything runs. Relaunch after updating.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("About") {
            Text(versionsText).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Button("Show Licenses") {
                if let url = Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: "txt") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
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
