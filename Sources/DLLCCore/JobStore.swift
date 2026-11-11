import Foundation

/// Durable queue persistence: one schema-versioned JSON file, written atomically off the main thread.
public final class JobStore: @unchecked Sendable {
    public static let schemaVersion = 1

    struct Envelope: Codable {
        var schemaVersion: Int
        var savedAt: Date
        var jobs: [Job]
    }

    private let url: URL
    private let queue = DispatchQueue(label: "dllc.jobstore", qos: .utility)
    private let lock = NSLock()
    private var pending: [Job]?
    private var scheduled = false
    private let debounce: TimeInterval

    public init(url: URL, debounce: TimeInterval = 0.4) {
        self.url = url
        self.debounce = debounce
    }

    /// Loads the queue. A corrupt file is moved aside (never deleted) and an empty queue returned.
    public func load() -> [Job] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            let env = try Self.decoder.decode(Envelope.self, from: data)
            return env.jobs
        } catch {
            let backup = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            return []
        }
    }

    /// Debounced save; the latest snapshot wins.
    public func save(_ jobs: [Job]) {
        lock.lock()
        pending = jobs
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        guard needsSchedule else { return }
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in self?.flush() }
    }

    /// Writes any pending snapshot synchronously (used on quit).
    public func flushNow() {
        queue.sync { self.flush() }
    }

    private func flush() {
        lock.lock()
        let jobs = pending
        pending = nil
        scheduled = false
        lock.unlock()
        guard let jobs else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try Self.encoder.encode(Envelope(schemaVersion: Self.schemaVersion, savedAt: Date(), jobs: jobs))
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("DLLC: failed to save queue: \(error.localizedDescription)")
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
