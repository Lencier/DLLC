import Foundation

/// App-owned locations. User data never lives inside the app bundle.
public struct AppPaths: Sendable {
    public var applicationSupport: URL
    public var caches: URL

    public init(applicationSupport: URL, caches: URL) {
        self.applicationSupport = applicationSupport
        self.caches = caches
    }

    public static func standard(fileManager: FileManager = .default) -> AppPaths {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.name, isDirectory: true)
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.bundleID, isDirectory: true)
        return AppPaths(applicationSupport: support, caches: caches)
    }

    public var queueFile: URL { applicationSupport.appendingPathComponent("queue.json") }
    public var processRegistry: URL { applicationSupport.appendingPathComponent("processes.json") }
    public var cookiesDirectory: URL { applicationSupport.appendingPathComponent("Cookies", isDirectory: true) }
    public var updatedToolsDirectory: URL { applicationSupport.appendingPathComponent("tools", isDirectory: true) }
    public var jobsWorkspace: URL { caches.appendingPathComponent("jobs", isDirectory: true) }
    public var sourceCache: URL { caches.appendingPathComponent("sources", isDirectory: true) }
    public var thumbnailCache: URL { caches.appendingPathComponent("thumbnails", isDirectory: true) }
    public var proxyCache: URL { caches.appendingPathComponent("proxies", isDirectory: true) }
    public var waveformCache: URL { caches.appendingPathComponent("waveforms", isDirectory: true) }
    public var songsFile: URL { applicationSupport.appendingPathComponent("songs.json") }
    public var logsDirectory: URL { applicationSupport.appendingPathComponent("Logs", isDirectory: true) }

    public func workspace(for jobID: UUID, generation: Int) -> URL {
        jobsWorkspace.appendingPathComponent(jobID.uuidString, isDirectory: true)
            .appendingPathComponent("g\(generation)", isDirectory: true)
    }

    public func createDirectories(fileManager: FileManager = .default) throws {
        for dir in [applicationSupport, cookiesDirectory, updatedToolsDirectory, jobsWorkspace,
                    sourceCache, thumbnailCache, logsDirectory] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Cookie files are credentials, and the queue/songs lists are the user's own history: owner-only.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cookiesDirectory.path)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: applicationSupport.path)
    }
}

public enum ToolLocatorError: Error, Sendable, Equatable {
    case missing(String)
}

/// Resolves bundled executables from controlled locations only (never $PATH).
public enum ToolLocator {
    /// `DLLC_TOOLS_DIR` overrides (tests / development). Otherwise `<bundle>/Contents/Resources/tools`.
    /// A user-installed, verified yt-dlp update in Application Support takes precedence over the bundled one
    /// only when `preferUpdatedYTDLP` is true and it exists.
    public static func resolve(bundle: Bundle = .main, paths: AppPaths? = nil,
                               preferUpdatedYTDLP: Bool = true,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               fileManager: FileManager = .default) throws -> ToolPaths {
        let base: URL
        if let override = environment["DLLC_TOOLS_DIR"], !override.isEmpty {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else if let res = bundle.resourceURL?.appendingPathComponent("tools", isDirectory: true),
                  fileManager.fileExists(atPath: res.path) {
            base = res
        } else {
            throw ToolLocatorError.missing("tools directory")
        }
        var ytdlp = base.appendingPathComponent("yt-dlp/yt-dlp_macos")
        if preferUpdatedYTDLP, let paths, let updated = YTDLPUpdateStore(paths: paths).activeExecutable(),
           fileManager.isExecutableFile(atPath: updated.path) {
            ytdlp = updated
        }
        let tools = ToolPaths(ytdlp: ytdlp,
                              ffmpeg: base.appendingPathComponent("ffmpeg"),
                              ffprobe: base.appendingPathComponent("ffprobe"),
                              deno: base.appendingPathComponent("deno"))
        for (name, url) in [("yt-dlp", tools.ytdlp), ("ffmpeg", tools.ffmpeg),
                            ("ffprobe", tools.ffprobe), ("deno", tools.deno)] {
            guard fileManager.isExecutableFile(atPath: url.path) else { throw ToolLocatorError.missing(name) }
        }
        return tools
    }
}
