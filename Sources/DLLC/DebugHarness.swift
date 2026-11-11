#if DEBUG
import AppKit
import DLLCCore

/// Development-only automation, active solely when DLLC_* environment variables are set (never in normal use).
/// DLLC_SNAPSHOT_DIR: periodically renders the main window to PNG (no Screen Recording permission needed).
/// DLLC_ADD_LINKS: comma-separated links added at launch. DLLC_START_ALL=1: Download All right after.
/// DLLC_OPEN_WORKSPACE=1: open the preview for the first analysed job. DLLC_THEME=light|dark.
/// DLLC_WINDOW_SIZE=WxH: resize the main window after launch. DLLC_DATA_DIR: use a separate data folder.
/// DLLC_MODE=download|songs, DLLC_SONG=first (open the first song), DLLC_TIPS=1 (open Quick Tips).
/// DLLC_FLIP_TEST=1 (with DLLC_SNAPSHOT_DIR): switch modes twice, saving a frame every 30 ms, then quit.
@MainActor
enum DebugHarness {
    static func start(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if let d = env["DLLC_DESTINATION"] { model.destination = URL(fileURLWithPath: d, isDirectory: true) }
        if let t = env["DLLC_THEME"], let theme = ThemeChoice(rawValue: t) { model.theme = theme }
        if let m = env["DLLC_MODE"], let mode = AppMode(rawValue: m) { model.mode = mode }
        if env["DLLC_SONG"] == "first", let song = model.songs.first {
            model.selectedProjectID = song.projectID
            model.selectedSongID = song.id
        }
        if env["DLLC_TIPS"] == "1" { model.showTips = true }
        if let links = env["DLLC_ADD_LINKS"] {
            model.add(links.split(separator: ",").map(String.init))
            if env["DLLC_START_ALL"] == "1" { model.engine.startAll() }
        }
        if env["DLLC_OPEN_WORKSPACE"] == "1" {
            Task {
                for _ in 0..<120 {
                    try? await Task.sleep(for: .seconds(1))
                    if let job = model.engine.jobs.first(where: { $0.info != nil }) {
                        model.openWorkspace(job.id, mode: env["DLLC_WORKSPACE_MODE"].flatMap(WorkspaceMode.init(rawValue:)))
                        return
                    }
                }
            }
        }
        if let size = env["DLLC_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            Task {
                try? await Task.sleep(for: .seconds(1))
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                    window.setContentSize(NSSize(width: size[0], height: size[1]))
                }
            }
        }
        guard let dir = env["DLLC_SNAPSHOT_DIR"] else { return }
        // DLLC_FLIP_TEST=1: switch modes twice and save a frame every 30 ms, to catch layout jumps.
        if env["DLLC_FLIP_TEST"] == "1" {
            Task {
                try? await Task.sleep(for: .seconds(4))
                var n = 0
                for _ in 0..<2 {
                    model.mode = model.mode == .songs ? .download : .songs
                    for _ in 0..<25 {
                        snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "flip-%03d.png", n)))
                        n += 1
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                }
                NSApp.terminate(nil)
            }
            return
        }
        let interval = Double(env["DLLC_SNAPSHOT_INTERVAL"] ?? "") ?? 4
        let count = Int(env["DLLC_SNAPSHOT_COUNT"] ?? "") ?? 10
        Task {
            for i in 0..<count {
                try? await Task.sleep(for: .seconds(interval))
                snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "snap-%02d.png", i)))
            }
        }
    }

    static func snapshot(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
