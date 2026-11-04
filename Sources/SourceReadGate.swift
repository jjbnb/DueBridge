import Foundation

/// Bounds all source reads, including wake/restore and write-time identity probes.
@MainActor final class SourceReadGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private let limit: Int
    private var running = 0
    private var waiters = [Waiter]()
    init(limit: Int = 2) { precondition(limit > 0); self.limit = limit }

    func withPermit<T>(_ operation: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
    private func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if running < limit { running += 1; continuation.resume() }
                else { waiters.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                self.waiters.remove(at: index).continuation.resume(throwing: CancellationError())
            }
        }
    }
    private func release() {
        if !waiters.isEmpty { waiters.removeFirst().continuation.resume() }
        else { running -= 1 }
    }
}
