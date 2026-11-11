import Foundation

/// Size accounting and least-recently-used trimming for a folder of regenerable cache files
/// (preview proxies). Only call this on folders the app owns.
public enum CacheFolder {
    struct Item { let url: URL; let size: Int64; let used: Date }

    static func items(in directory: URL) -> [Item] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return Item(url: url, size: Int64(v.fileSize ?? 0), used: v.contentModificationDate ?? .distantPast)
        }
    }

    public static func size(of directory: URL) -> Int64 {
        items(in: directory).reduce(0) { $0 + $1.size }
    }

    /// Marks a cached file as just used, so trimming keeps it longest.
    public static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Removes the least recently used files until the folder fits `maxBytes`.
    /// Files touched in the last `grace` seconds are kept (they may be in use right now).
    public static func trim(_ directory: URL, maxBytes: Int64, maxAge: TimeInterval? = nil,
                            grace: TimeInterval = 600, now: Date = Date()) {
        var all = items(in: directory)
        if let maxAge {
            for item in all where now.timeIntervalSince(item.used) > max(maxAge, grace) {
                try? FileManager.default.removeItem(at: item.url)
            }
            all = all.filter { now.timeIntervalSince($0.used) <= max(maxAge, grace) }
        }
        var total = all.reduce(Int64(0)) { $0 + $1.size }
        for item in all.sorted(by: { $0.used < $1.used }) where total > maxBytes {
            guard now.timeIntervalSince(item.used) > grace else { continue }
            try? FileManager.default.removeItem(at: item.url)
            total -= item.size
        }
    }

    public static func clear(_ directory: URL) {
        for item in items(in: directory) { try? FileManager.default.removeItem(at: item.url) }
    }
}
