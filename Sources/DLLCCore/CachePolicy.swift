import Foundation

/// How much disk the regenerable caches (full-quality sources, preview proxies) may use.
/// Everything here can be rebuilt; the user's saved files are never part of it.
public struct CachePolicy: Sendable, Equatable {
    /// Total budget chosen in Settings.
    public var limitBytes: Int64
    /// Copies not used for this long are deleted.
    public var maxAge: TimeInterval

    public init(limitBytes: Int64 = 2 * Self.gigabyte, maxAge: TimeInterval = 7 * 86_400) {
        self.limitBytes = limitBytes; self.maxAge = maxAge
    }

    public static let gigabyte: Int64 = 1_073_741_824
    /// Below this much free space the app goes easy on the disk.
    public static let lowSpaceThreshold: Int64 = 15 * gigabyte
    static let lowSpaceLimit: Int64 = 512 * 1_048_576

    public static func isLowOnSpace(free: Int64?) -> Bool { free.map { $0 < lowSpaceThreshold } ?? false }

    /// The budget actually applied: much smaller when the disk is nearly full.
    public func effectiveLimit(free: Int64?) -> Int64 {
        Self.isLowOnSpace(free: free) ? min(limitBytes, Self.lowSpaceLimit) : limitBytes
    }

    /// Full-quality sources get three quarters of the budget, preview proxies the rest.
    public func sourceLimit(free: Int64?) -> Int64 { effectiveLimit(free: free) * 3 / 4 }
    public func proxyLimit(free: Int64?) -> Int64 { effectiveLimit(free: free) / 4 }
}
