import Foundation

/// Remembers local full-quality copies of a link so preview, snapshots and exports can reuse them.
/// Entries either point at app-owned files in the cache directory (deletable) or at completed user
/// downloads (never deleted by the app).
public final class SourceCache: @unchecked Sendable {
    struct Entry: Codable {
        var path: String
        var owned: Bool
        var addedAt: Date
    }

    private let directory: URL
    private let indexURL: URL
    private let lock = NSLock()
    private var index: [String: Entry]

    public init(directory: URL) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("index.json")
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            index = decoded
        } else {
            index = [:]
        }
    }

    /// `variant` separates copies of one link that must not be swapped: a single item of a
    /// multi-item post, or content fetched with a browser login.
    static func key(_ url: String, _ variant: String?) -> String {
        LinkExtractor.canonicalKey(url) + (variant.map { "#" + $0 } ?? "")
    }

    public func lookup(url: String, variant: String? = nil) -> URL? {
        let key = Self.key(url, variant)
        return lock.withLock {
            guard let entry = index[key] else { return nil }
            guard FileManager.default.fileExists(atPath: entry.path) else {
                index[key] = nil
                saveLocked()
                return nil
            }
            // Least-recently-used eviction: a lookup counts as a use.
            index[key]?.addedAt = Date()
            saveLocked()
            return URL(fileURLWithPath: entry.path)
        }
    }

    /// Registers a completed user download as a source (not owned: never deleted by the app).
    public func register(url: String, variant: String? = nil, file: URL) {
        let key = Self.key(url, variant)
        lock.withLock {
            if let existing = index[key], existing.owned { try? FileManager.default.removeItem(atPath: existing.path) }
            index[key] = Entry(path: file.path, owned: false, addedAt: Date())
            saveLocked()
        }
    }

    /// Moves a freshly downloaded file into the cache and records it (owned).
    public func store(url: String, variant: String? = nil, file: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = Self.key(url, variant)
        let name = String(key.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }, radix: 16)
        let dest = directory.appendingPathComponent("\(name).\(file.pathExtension)")
        // Check and publish atomically: two jobs missing the cache at once must not delete or
        // overwrite a copy the other has already handed out.
        return try lock.withLock {
            if let existing = index[key], FileManager.default.fileExists(atPath: existing.path) {
                try? FileManager.default.removeItem(at: file)
                return URL(fileURLWithPath: existing.path)
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: file, to: dest)
            index[key] = Entry(path: dest.path, owned: true, addedAt: Date())
            trimLocked(maxBytes: maxOwnedBytes, keeping: key)
            saveLocked()
            return dest
        }
    }

    /// Size budget and age limit; the size budget shrinks automatically when the disk is nearly full.
    public var policy = CachePolicy()
    /// Fixed size cap for tests; nil = follow `policy` and the free space.
    public var maxOwnedBytesOverride: Int64?
    var maxOwnedBytes: Int64 {
        maxOwnedBytesOverride ?? policy.sourceLimit(free: MediaWorker.freeBytes(at: directory.deletingLastPathComponent()))
    }

    /// Deletes app-owned copies unused for longer than the policy allows, then the least recently used
    /// ones until the total fits, and files in the cache folder that the index no longer knows about.
    /// Registered user files are never touched (they are only forgotten when unused for long).
    public func trim(maxBytes: Int64? = nil, now: Date = Date()) {
        lock.withLock {
            for (key, entry) in index where now.timeIntervalSince(entry.addedAt) > policy.maxAge {
                if entry.owned { try? FileManager.default.removeItem(atPath: entry.path) }
                index[key] = nil
            }
            trimLocked(maxBytes: maxBytes ?? maxOwnedBytes, keeping: nil)
            let known = Set(index.values.map { URL(fileURLWithPath: $0.path).lastPathComponent })
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name != "index.json" && !name.hasPrefix("tmp-") && !known.contains(name) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
            saveLocked()
        }
    }

    private func trimLocked(maxBytes: Int64, keeping: String?) {
        let owned = index.filter { $0.value.owned }.map { key, entry in
            (key, entry, (try? FileManager.default.attributesOfItem(atPath: entry.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        var total = owned.reduce(Int64(0)) { $0 + $1.2 }
        for (key, entry, size) in owned.sorted(by: { $0.1.addedAt < $1.1.addedAt }) where total > maxBytes && key != keeping {
            try? FileManager.default.removeItem(atPath: entry.path)
            index[key] = nil
            total -= size
        }
    }

    /// Deletes app-owned copies of these links (all variants), e.g. when their items leave the queue.
    public func removeOwned(forURLs urls: [String]) {
        let keys = Set(urls.map { LinkExtractor.canonicalKey($0) })
        guard !keys.isEmpty else { return }
        lock.withLock {
            for (key, entry) in index where entry.owned {
                let base = key.split(separator: "#", maxSplits: 1).first.map(String.init) ?? key
                guard keys.contains(base) else { continue }
                try? FileManager.default.removeItem(atPath: entry.path)
                index[key] = nil
            }
            saveLocked()
        }
    }

    /// Bytes used by app-owned cached sources.
    public func ownedSize() -> Int64 {
        lock.withLock {
            index.values.filter(\.owned).reduce(Int64(0)) { sum, e in
                let size = (try? FileManager.default.attributesOfItem(atPath: e.path)[.size] as? NSNumber)?.int64Value ?? 0
                return sum + size
            }
        }
    }

    /// Deletes only app-owned cache files; registered user files are just forgotten.
    public func clearOwned() {
        lock.withLock {
            for (key, entry) in index where entry.owned {
                try? FileManager.default.removeItem(atPath: entry.path)
                index[key] = nil
            }
            saveLocked()
        }
    }

    private func saveLocked() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexURL, options: .atomic) }
    }
}
