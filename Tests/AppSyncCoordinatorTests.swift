// Synthetic fixtures only; public school domains test exact request policies.
import Foundation

@MainActor private final class Suspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    func wait() async { await withCheckedContinuation { continuation = $0; waiting = true } }
    func resume() { continuation?.resume(); continuation = nil }
}
@MainActor private final class SchedulerProbe: SyncScheduling {
    var date: Date?
    var action: (() -> Void)?
    var schedules = 0
    var cancellations = 0
    func schedule(at date: Date, action: @escaping () -> Void) { self.date = date; self.action = action; schedules += 1 }
    func cancel() { date = nil; action = nil; cancellations += 1 }
    func fire() { let callback = action; date = nil; action = nil; callback?() }
}
@MainActor private final class LoginProbe: RestartLogin {
    var availability: LoginAvailability = .enabled
    var registers = 0
    var unregisters = 0
    var failRegister = false
    var failUnregister = false
    var suspension: Suspension?
    func status() -> LoginAvailability { availability }
    func register() throws -> LoginAvailability {
        registers += 1
        if failRegister { throw RestoreFailure.unavailable }
        availability = .enabled
        return availability
    }
    func unregister() async throws {
        unregisters += 1
        if let suspension { await suspension.wait() }
        if failUnregister { throw RestoreFailure.unavailable }
        availability = .notRegistered
    }
    func openSettings() {}
}

@main struct AppSyncCoordinatorTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { print("FAIL: \(message)"); exit(1) }
    }
    @MainActor static func spin(until condition: () -> Bool) async {
        for _ in 0..<1000 { if condition() { return }; await Task.yield() }
        check(false, "asynchronous test reached its expected checkpoint")
    }
    @MainActor static func rejected<T>(_ task: Task<T, Error>, _ message: String) async {
        do { _ = try await task.value; check(false, message) } catch { check(true, message) }
    }
    @MainActor static func gateTests() async throws {
        let gate = ReminderWriteGate(), paused = Suspension()
        var events = [String]()
        let first = Task { try await gate.withPermit(shouldContinue: { true }) {
            events.append("first-start"); await paused.wait(); events.append("first-end")
        } }
        await spin { paused.waiting }
        var secondTried = false
        let second = Task { secondTried = true; try await gate.withPermit(shouldContinue: { true }) { events.append("second") } }
        await spin { secondTried }
        for _ in 0..<10 { await Task.yield() }
        check(events == ["first-start"], "permit covers an operation while suspended")
        paused.resume(); try await first.value; try await second.value
        check(events == ["first-start", "first-end", "second"], "queued operation starts after whole owner finishes")

        let hold = Suspension(); events = []
        let owner = Task { try await gate.withPermit(shouldContinue: { true }) { await hold.wait() } }
        await spin { hold.waiting }
        var attempted = 0
        let a = Task { attempted += 1; try await gate.withPermit(shouldContinue: { true }) { events.append("a") } }
        await spin { attempted == 1 }
        let cancelled = Task { attempted += 1; try await gate.withPermit(shouldContinue: { true }) { events.append("cancelled") } }
        await spin { attempted == 2 }
        var valid = true
        let stale = Task { attempted += 1; try await gate.withPermit(shouldContinue: { valid }) { events.append("stale") } }
        await spin { attempted == 3 }
        let b = Task { attempted += 1; try await gate.withPermit(shouldContinue: { true }) { events.append("b") } }
        await spin { attempted == 4 }
        cancelled.cancel(); valid = false
        await rejected(cancelled, "cancelled waiter resolves while owner is still suspended")
        hold.resume(); try await owner.value; try await a.value; await rejected(stale, "invalid queued generation is rejected"); try await b.value
        check(events == ["a", "b"], "FIFO skips cancelled and stale waiters without leaking a permit")
        let throwing = Task { try await gate.withPermit(shouldContinue: { true }) { throw RestoreFailure.invalid } }
        await rejected(throwing, "operation error propagates")
        let value = try await gate.withPermit(shouldContinue: { true }) { 42 }
        check(value == 42, "throw releases permit for next operation")
        let invalid = Task { try await gate.withPermit(shouldContinue: { false }) { events.append("invalid") } }
        await rejected(invalid, "invalid generation before wait is rejected")
        check(events == ["a", "b"], "invalid operation body never runs")
        let cancelledOwner = Suspension()
        let active = Task { try await gate.withPermit(shouldContinue: { true }) { await cancelledOwner.wait(); return 1 } }
        await spin { cancelledOwner.waiting }; active.cancel()
        var afterStarted = false
        let after = Task { try await gate.withPermit(shouldContinue: { true }) { afterStarted = true } }
        for _ in 0..<10 { await Task.yield() }
        check(!afterStarted, "cancelling owner does not release its still-running operation")
        cancelledOwner.resume(); await rejected(active, "cancelled owner rejects after its operation returns"); try await after.value
        check(afterStarted, "cancelled owner eventually releases permit")
    }
    @MainActor static func schedulerTests() {
        let physical = SchedulerProbe(), coordinator = AppSyncCoordinator(scheduler: physical)
        let bb = coordinator.slot("bb"), mo = coordinator.slot("mo"), zju = coordinator.slot("zju")
        let early = Date().addingTimeInterval(3600), late = early.addingTimeInterval(60)
        var events = [String]()
        bb.schedule(at: early) { events.append("bb") }
        mo.schedule(at: late) { events.append("mo") }
        check(physical.date == early && physical.schedules == 1, "later source uses the already armed minimum physical schedule")
        mo.cancel()
        check(physical.date == early, "cancelling another source preserves BB schedule")
        mo.schedule(at: early) { events.append("mo") }
        zju.schedule(at: early) { events.append("zju") }
        physical.fire()
        check(events == ["bb", "mo", "zju"], "simultaneous due callbacks fire once in stable schedule order")
        check(physical.date == nil, "all fired slots leave no physical schedule")
        let staleCallback: () -> Void
        bb.schedule(at: late) { events.append("stale") }; staleCallback = physical.action!
        bb.schedule(at: early) {
            events.append("first")
            mo.schedule(at: late) { events.append("replacement") }
            zju.cancel()
        }
        mo.schedule(at: early) { events.append("old") }
        zju.schedule(at: early) { events.append("cancelled") }
        physical.fire(); staleCallback()
        check(events == ["bb", "mo", "zju", "first"], "reentrant callback invalidates replaced and cancelled due callbacks")
        check(physical.date == late, "reentrant schedule survives dispatch cleanup")
        physical.fire()
        check(events.last == "replacement", "replacement callback fires once later")
        bb.schedule(at: early) { events.append("stop") }; let stopped = physical.action!
        coordinator.stop(); stopped(); mo.schedule(at: late) { events.append("restart") }
        check(physical.date == nil && !events.contains("stop") && !events.contains("restart"), "stop invalidates queued and future slot schedules")
    }
    @MainActor static func loginTests() async throws {
        let underlying = LoginProbe(), claims = SharedLoginClaims(underlying: underlying, initialClaims: ["bb", "mo"])
        let bb = claims.facade("bb"), mo = claims.facade("mo")
        try await bb.unregister()
        check(underlying.availability == .enabled && underlying.unregisters == 0, "BB release keeps native login claim enabled")
        try await bb.unregister(); try await mo.unregister()
        check(underlying.unregisters == 1 && underlying.availability == .notRegistered, "only final unique claim unregisters physical service")
        _ = try bb.register(); _ = try bb.register(); _ = try mo.register()
        check(underlying.registers == 1, "enabled service registration is idempotent across claims")
        try await mo.unregister()
        check(underlying.availability == .enabled, "native release preserves BB claim")
        underlying.failUnregister = true
        do { try await bb.unregister(); check(false, "failed unregister throws") } catch { check(true, "failed unregister throws") }
        underlying.failUnregister = false
        _ = try mo.register(); try await mo.unregister()
        check(underlying.availability == .enabled, "failed final unregister restores prior claim")
        try await bb.unregister()
        underlying.failRegister = true
        do { _ = try mo.register(); check(false, "failed register throws") } catch { check(true, "failed register throws") }
        underlying.failRegister = false
        let before = underlying.unregisters
        try await mo.unregister()
        check(underlying.unregisters == before, "failed register does not manufacture a claim")
        underlying.availability = .requiresApproval
        _ = try bb.register()
        check(underlying.registers == 2, "pending approval is reused without duplicate registration")
        let pause = Suspension(); underlying.suspension = pause
        let removal = Task { try await bb.unregister() }; await spin { pause.waiting }
        do { _ = try mo.register(); check(false, "registration during in-flight final unregister is rejected") } catch { check(true, "registration during in-flight final unregister is rejected") }
        pause.resume(); try await removal.value
        underlying.suspension = nil
        _ = try mo.register()
        check(underlying.availability == .enabled, "registration can retry after unregister completes")
    }
    @MainActor static func main() async throws {
        switch CommandLine.arguments.dropFirst().first ?? "all" {
        case "gate": try await gateTests()
        case "scheduler": schedulerTests()
        case "login": try await loginTests()
        default: try await gateTests(); schedulerTests(); try await loginTests()
        }
        print("AppSyncCoordinatorTests: \(checks) checks passed")
    }
}
