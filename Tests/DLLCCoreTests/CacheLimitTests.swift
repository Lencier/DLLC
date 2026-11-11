import Foundation
import Testing
@testable import DLLCCore

struct CacheLimitTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dllc-limit-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func sourceCacheEvictsLeastRecentlyUsedOwnedCopies() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = SourceCache(directory: dir.appendingPathComponent("sources"))
        cache.maxOwnedBytesOverride = 2500
        func file(_ name: String) throws -> URL {
            let f = dir.appendingPathComponent(name)
            try Data(count: 1000).write(to: f)
            return f
        }
        let userFile = try file("mine.mp4")
        cache.register(url: "https://youtu.be/user", file: userFile)
        _ = try cache.store(url: "https://youtu.be/a", file: try file("a.mp4"))
        _ = try cache.store(url: "https://youtu.be/b", file: try file("b.mp4"))
        _ = cache.lookup(url: "https://youtu.be/a") // a is now more recent than b
        _ = try cache.store(url: "https://youtu.be/c", file: try file("c.mp4"))
        #expect(cache.lookup(url: "https://youtu.be/b") == nil)
        #expect(cache.lookup(url: "https://youtu.be/a") != nil)
        #expect(cache.lookup(url: "https://youtu.be/c") != nil)
        #expect(FileManager.default.fileExists(atPath: userFile.path)) // user downloads are never deleted
        try Data(count: 10).write(to: dir.appendingPathComponent("sources/stray.mp4"))
        cache.trim()
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("sources/stray.mp4").path))
        #expect(cache.lookup(url: "https://youtu.be/a") != nil)
    }

    @Test func cacheFolderTrimsOldestButKeepsRecentFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        for (name, age) in [("old", 7200.0), ("mid", 3600.0), ("new", 60.0)] {
            let f = dir.appendingPathComponent(name)
            try Data(count: 1000).write(to: f)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: f.path)
        }
        CacheFolder.trim(dir, maxBytes: 500, now: now)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left == ["new"]) // within the grace period, kept even though over the limit
        #expect(CacheFolder.size(of: dir) == 1000)
    }
}

struct AuditRegressionTests {
    @Test func longProjectNamesStillGetAFreeSuffix() {
        let long = String(repeating: "a", count: 120)
        let stem = Project.suffixableStem(long)
        let first = Project(name: long).folderName
        let second = Project(name: "\(stem) 2").folderName
        #expect(first != second)
        #expect(second.hasSuffix(" 2"))
        let thai = String(repeating: "ก", count: 120) // 3 bytes each
        #expect(Project(name: "\(Project.suffixableStem(thai)) 12345").folderName.hasSuffix(" 12345"))
    }

    @Test func absurdFrameRateDoesNotCrash() {
        let q = QualityOption(width: 1920, height: 1080, fps: 1e20, isHDR: false, formatIDs: [], codecs: [],
                              estimatedBytes: nil, estimateIsRough: false)
        #expect(q.fpsLabel == "")
    }
}

struct CachePolicyTests {
    @Test func budgetShrinksWhenDiskIsNearlyFull() {
        let p = CachePolicy(limitBytes: 4 * CachePolicy.gigabyte)
        #expect(p.effectiveLimit(free: 200 * CachePolicy.gigabyte) == 4 * CachePolicy.gigabyte)
        #expect(p.effectiveLimit(free: 5 * CachePolicy.gigabyte) == 512 * 1_048_576)
        #expect(p.sourceLimit(free: nil) + p.proxyLimit(free: nil) == 4 * CachePolicy.gigabyte)
    }

    @Test func unusedCopiesExpireAndRemovedLinksAreDeleted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dllc-age-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = SourceCache(directory: dir.appendingPathComponent("sources"))
        cache.policy = CachePolicy(limitBytes: CachePolicy.gigabyte, maxAge: 3600)
        func file(_ n: String) throws -> URL { let f = dir.appendingPathComponent(n); try Data(count: 10).write(to: f); return f }
        let a = try cache.store(url: "https://youtu.be/a", file: try file("a.mp4"))
        _ = try cache.store(url: "https://youtu.be/b", variant: "q=137", file: try file("b.mp4"))
        cache.trim(now: Date().addingTimeInterval(7200))
        #expect(!FileManager.default.fileExists(atPath: a.path))
        let b = try cache.store(url: "https://youtu.be/b", variant: "q=137", file: try file("b2.mp4"))
        cache.removeOwned(forURLs: ["https://www.youtube.com/watch?v=b"])
        #expect(!FileManager.default.fileExists(atPath: b.path))
    }

    @Test func proxiesOlderThanMaxAgeAreRemoved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dllc-pa-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("old-proxy.mp4")
        try Data(count: 10).write(to: f)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 86_400)], ofItemAtPath: f.path)
        CacheFolder.trim(dir, maxBytes: CachePolicy.gigabyte, maxAge: 7 * 86_400)
        #expect(!FileManager.default.fileExists(atPath: f.path))
    }
}
