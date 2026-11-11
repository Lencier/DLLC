import Foundation

/// Cancellable counting semaphore with an adjustable limit (e.g. heavy media-processing slots).
public actor AsyncGate {
    private var limit: Int
    private var inUse = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    public init(limit: Int) { self.limit = max(1, limit) }

    public func setLimit(_ newLimit: Int) {
        limit = max(1, newLimit)
        drain()
    }

    public var waitingCount: Int { waiters.count }

    public func acquire() async throws {
        if inUse < limit && waiters.isEmpty {
            inUse += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    c.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, c))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    public func release() {
        inUse = max(0, inUse - 1)
        drain()
    }

    /// Runs `body` while holding a permit; the permit is always released.
    public nonisolated func withPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let value = try await body()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    private func drain() {
        while inUse < limit, !waiters.isEmpty {
            let w = waiters.removeFirst()
            inUse += 1
            w.continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        let w = waiters.remove(at: i)
        w.continuation.resume(throwing: CancellationError())
    }
}
