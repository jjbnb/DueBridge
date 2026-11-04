import Foundation

/// One permit spans the entire async write attempt, including fetch and validation.
@MainActor final class ReminderWriteGate {
    private struct Waiter {
        let id: UUID
        let shouldContinue: () -> Bool
        let continuation: CheckedContinuation<Void, Error>
    }
    private var owned = false
    private var waiters = [Waiter]()

    func withPermit<T>(shouldContinue: @escaping () -> Bool, operation: () async throws -> T) async throws -> T {
        try await acquire(shouldContinue: shouldContinue)
        defer { release() }
        try validate(shouldContinue)
        let result = try await operation()
        try validate(shouldContinue)
        return result
    }
    private func validate(_ shouldContinue: () -> Bool) throws {
        try Task.checkCancellation()
        guard shouldContinue() else { throw SafeError("同步已暂停或来源已改变；此次未写入提醒事项。") }
    }
    private func acquire(shouldContinue: @escaping () -> Bool) async throws {
        try validate(shouldContinue)
        if !owned { owned = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    try validate(shouldContinue)
                    waiters.append(Waiter(id: id, shouldContinue: shouldContinue, continuation: continuation))
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(id) }
        }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func release() {
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            guard next.shouldContinue() else {
                next.continuation.resume(throwing: SafeError("同步已暂停或来源已改变；此次未写入提醒事项。"))
                continue
            }
            // Ownership transfers before waking the waiter. Its own task checks
            // cancellation on resumption, then releases via withPermit's defer.
            next.continuation.resume()
            return
        }
        owned = false
    }
}

/// Independent one-shot slots over the app's single physical scheduler.
@MainActor final class AppSyncCoordinator {
    private struct Entry {
        let date: Date
        let order: UInt64
        let action: () -> Void
    }
    private let scheduler: SyncScheduling
    private var entries = [String: Entry]()
    private var nextOrder: UInt64 = 0
    private var armGeneration: UInt64 = 0
    private var armedDate: Date?
    private var dispatching = false
    private var stopped = false

    init(scheduler: SyncScheduling) { self.scheduler = scheduler }
    func slot(_ id: String) -> SyncScheduling { Slot(owner: self, id: id) }
    func stop() {
        stopped = true; entries.removeAll(); armedDate = nil
        armGeneration &+= 1; scheduler.cancel()
    }
    private func schedule(_ id: String, date: Date, action: @escaping () -> Void) {
        guard !stopped, date.timeIntervalSince1970.isFinite else { return }
        nextOrder &+= 1
        entries[id] = Entry(date: date, order: nextOrder, action: action)
        arm()
    }
    private func cancel(_ id: String) { entries.removeValue(forKey: id); arm() }
    private func arm() {
        guard !stopped, !dispatching else { return }
        let minimum = entries.values.map(\.date).min()
        guard minimum != armedDate else { return }
        armGeneration &+= 1
        armedDate = minimum
        guard let minimum else { scheduler.cancel(); return }
        let generation = armGeneration
        scheduler.schedule(at: minimum) { [weak self] in self?.fire(generation: generation, deadline: minimum) }
    }
    private func fire(generation: UInt64, deadline: Date) {
        guard !stopped, armGeneration == generation, armedDate == deadline else { return }
        armedDate = nil; armGeneration &+= 1
        dispatching = true
        let cutoff = max(deadline, Date())
        let due = entries.filter { $0.value.date <= cutoff }.sorted {
            if $0.value.date != $1.value.date { return $0.value.date < $1.value.date }
            return $0.value.order < $1.value.order
        }
        for (id, entry) in due {
            // A previous callback may cancel or replace this slot. A replacement
            // stays queued even if its deadline is already due.
            guard !stopped, entries[id]?.order == entry.order else { continue }
            entries.removeValue(forKey: id)
            entry.action()
        }
        dispatching = false
        arm()
    }
    @MainActor private final class Slot: SyncScheduling {
        private let owner: AppSyncCoordinator
        private let id: String
        init(owner: AppSyncCoordinator, id: String) { self.owner = owner; self.id = id }
        func schedule(at date: Date, action: @escaping () -> Void) { owner.schedule(id, date: date, action: action) }
        func cancel() { owner.cancel(id) }
    }
}

/// Persisted restore intents seed claims; construction never changes the OS service.
@MainActor final class SharedLoginClaims {
    private let underlying: RestartLogin
    private var claims: Set<String>
    private var unregistering = false
    init(underlying: RestartLogin, initialClaims: Set<String>) {
        self.underlying = underlying; claims = initialClaims
    }
    func facade(_ id: String) -> RestartLogin { Facade(owner: self, id: id) }
    private func register(_ id: String) throws -> LoginAvailability {
        guard !unregistering else { throw SafeError("登录启动设置正在更新，请稍后重试。") }
        let status = underlying.status()
        if status == .enabled || status == .requiresApproval { claims.insert(id); return status }
        do {
            let result = try underlying.register()
            guard result == .enabled || result == .requiresApproval else { throw RestoreFailure.unavailable }
            claims.insert(id)
            return result
        } catch { throw SafeError("无法开启登录启动，请检查系统设置后重试。") }
    }
    private func unregister(_ id: String) async throws {
        guard claims.contains(id) else { return }
        claims.remove(id)
        guard claims.isEmpty else { return }
        unregistering = true
        defer { unregistering = false }
        do { try await underlying.unregister() }
        catch {
            claims.insert(id)
            throw SafeError("无法关闭登录启动，请检查系统设置后重试。")
        }
    }
    @MainActor private final class Facade: RestartLogin {
        private let owner: SharedLoginClaims
        private let id: String
        init(owner: SharedLoginClaims, id: String) { self.owner = owner; self.id = id }
        func status() -> LoginAvailability { owner.underlying.status() }
        func register() throws -> LoginAvailability { try owner.register(id) }
        func unregister() async throws { try await owner.unregister(id) }
        func openSettings() { owner.underlying.openSettings() }
    }
}
