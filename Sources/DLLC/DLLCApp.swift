import AppKit
import DLLCCore
import SwiftUI

@main
struct DLLCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window(AppIdentity.name, id: "main") {
            ContentView()
                .environment(delegate.model)
                .frame(minWidth: 820, minHeight: 600)
        }
        .defaultSize(width: 1360, height: 820)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(AppIdentity.name)") { AboutPanel.show() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Song…") { delegate.model.chooseSongFile() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(before: .sidebar) {
                Button("Download") { delegate.model.mode = .download }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Song Cues") { delegate.model.mode = .songs }
                    .keyboardShortcut("2", modifiers: .command)
                Divider()
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Paste Links") { delegate.model.pasteLinks() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Quick Tips") { delegate.model.toggleTips() }
                    .keyboardShortcut("?", modifiers: .command)
            }
            CommandMenu("Queue") {
                Button("Download All") { delegate.model.downloadAllVisible() }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Clear Completed") { delegate.model.clearCompletedVisible() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button("Choose Save Folder…") { delegate.model.chooseDestination() }
                Button("Show Save Folder in Finder") {
                    NSWorkspace.shared.open(delegate.model.destination)
                }
            }
        }

        Settings {
            SettingsView()
                .environment(delegate.model)
        }
    }
}

/// The standard About window with a short description and credits.
enum AboutPanel {
    @MainActor static func show() {
        let credits = NSMutableAttributedString()
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 6
        func add(_ text: String, _ font: NSFont, _ color: NSColor) {
            credits.append(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: center]))
        }
        add(AppIdentity.tagline + "\n", .systemFont(ofSize: 11), .secondaryLabelColor)
        add("Developed by \(AppIdentity.author)\n", .systemFont(ofSize: 11, weight: .semibold), .labelColor)
        add("from an idea by \(AppIdentity.ideaBy)\n", .systemFont(ofSize: 11), .secondaryLabelColor)
        add("Uses yt-dlp and FFmpeg. Settings › Privacy & Updates lists licences.", .systemFont(ofSize: 10), .tertiaryLabelColor)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .init(rawValue: "Copyright"): "© 2026 \(AppIdentity.author)",
        ])
        NSApp.activate()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor lazy var model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            model.applyTheme()
            #if DEBUG
            DebugHarness.start(model: model)
            #endif
        }
    }

    /// Closing the window keeps the queue running; clicking the Dock icon brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !model.engine.hasPendingWork }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let engine = model.engine!
            let active = engine.jobs.filter { $0.state == .downloading || $0.state == .processing }.count
            let waiting = engine.jobs.filter { $0.state == .queued || $0.state == .analyzing }.count
            guard active + waiting > 0 else { return .terminateNow }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = active > 0
                ? "Quit and stop \(active) active job\(active == 1 ? "" : "s")?"
                : "Quit with \(waiting) job\(waiting == 1 ? "" : "s") waiting?"
            alert.informativeText = "Your queue is saved. Stopped jobs are marked Interrupted and can be restarted next time you open \(AppIdentity.name)."
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "Quit and Interrupt")
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model.terminate() }
    }
}
