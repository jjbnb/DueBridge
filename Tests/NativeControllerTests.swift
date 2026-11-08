// Synthetic fixtures only; public school domains test exact request policies.
import Foundation

@MainActor final class NativeTestScheduler: SyncScheduling {
    var date: Date?; var action: (() -> Void)?
    func schedule(at date: Date, action: @escaping () -> Void) { self.date = date; self.action = action }
    func cancel() { date = nil; action = nil }
}
@MainActor final class NativeTestLogin: RestartLogin {
    var claimed = false
    func status() -> LoginAvailability { claimed ? .enabled : .notRegistered }
    func register() throws -> LoginAvailability { claimed = true; return .enabled }
    func unregister() async throws { claimed = false }
    func openSettings() {}
}
@MainActor final class NativeCalendarProbe: CalendarEventDestination {
    var identifier: String? = "native-calendar-test"
    var received = [(CalendarScope, CalendarProjection)]()
    func requireWritable() throws -> String { identifier! }
    func reconcile(scope: CalendarScope, projection: CalendarProjection, checkpoint: CalendarCheckpoint,
                   now: Date, persistPending: (CalendarCheckpoint) throws -> Void) throws -> (SyncResult, CalendarCheckpoint) {
        received.append((scope, projection))
        return (SyncResult(added: 1, updated: 0, skipped: projection.skipped, warnings: []), checkpoint)
    }
}
struct NativeControllerTestNetwork: Error {}
struct NativeControllerTestIdentity: Error {}
@main struct NativeControllerTests {
    static var checks = 0
    static func check(_ ok: @autoclosure () -> Bool, _ text: String) {
        checks += 1; if !ok() { print("FAIL: " + text); exit(1) }
    }
    // Removing restore verification, moving activation ahead of it, or omitting the
    // post-await generation check must fail these memory-only lifecycle cases.
    @MainActor static func restoreRegressions() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z")!
        let fingerprint = String(repeating: "a", count: 64)
        for outcome in ["valid", "missing", "expired", "changed", "pause", "stop"] {
            var memory = [String: Data]()
            var metadataWrites = 0
            let store = NativeStateStore(read: { memory[$0] }, write: { memory[$0] = $1; metadataWrites += 1 })
            var saved = NativePlatformState()
            var connection = try saved.connect(fingerprint: fingerprint)
            connection.desiredEnabled = true; connection.restoreEnabled = true
            connection.recordSuccess(hashes: [String(repeating: "b", count: 64)], now: now)
            try saved.update(connection); try store.save(saved, for: .mo)
            let before = memory
            let scheduler = NativeTestScheduler(), login = NativeTestLogin()
            login.claimed = true
            var verifies = 0, reads = 0, writes = 0, opens = 0, access = 0
            var suspended: CheckedContinuation<Void, Never>?
            let services = NativeSourceServices(openLogin: { _ in opens += 1 }, finishLogin: { _ in fingerprint },
                verify: { storeID, expected in
                    verifies += 1
                    check(storeID == saved.storeID && expected == fingerprint, "restore verifies saved store and fingerprint: " + outcome)
                    if outcome == "pause" || outcome == "stop" {
                        await withCheckedContinuation { suspended = $0 }
                    }
                    if ["missing", "expired", "changed"].contains(outcome) { throw NativeControllerTestIdentity() }
                }, collect: { _, scope, account in
                    reads += 1
                    return NativeSourcePreview(scope: scope, accountFingerprint: account, candidates: [], courseCount: 0)
                }, requestAccess: { access += 1 }, authorized: { true },
                write: { _, _, _, _ in
                    writes += 1
                    return (SyncResult(added: 0, updated: 0, skipped: 0, warnings: []), [])
                }, cancel: {}, close: {}, now: { now }, networkFailure: { _ in false }, errorMessage: { _ in "身份无法验证" })
            let controller = NativeSourceController(platform: .mo, store: store, services: services, scheduler: scheduler, login: login)
            if outcome == "pause" || outcome == "stop" {
                let starting = Task { await controller.start() }
                for _ in 0..<100 where suspended == nil { await Task.yield() }
                check(suspended != nil && controller.busy && !controller.enabled, "restore stays disabled during verification: " + outcome)
                if outcome == "pause" { controller.pause() } else { controller.stop() }
                suspended?.resume(); suspended = nil
                await starting.value
                check(!controller.enabled && !controller.busy && scheduler.date == nil, "invalidated restore cannot activate: " + outcome)
            } else {
                await controller.start()
                if outcome == "valid" {
                    check(controller.enabled && scheduler.date == ISO8601DateFormatter().date(from: "2026-11-03T16:00:00Z"), "verified same-day restore enables and schedules")
                } else {
                    check(!controller.enabled && scheduler.date == nil && controller.status.contains("重新连接"), "invalid identity blocks restore with reconnect recovery: " + outcome)
                    check(memory == before && metadataWrites == 1, "restore verification failure preserves saved state: " + outcome)
                }
            }
            check(verifies == 1 && reads == 0 && writes == 0 && opens == 0 && access == 0, "restore uses verification only: " + outcome)
            let after = try store.load(.mo)!
            check(after.storeID == saved.storeID && after.activeID == connection.id && after.connections.count == 1 &&
                  after.active?.knownHashes == connection.knownHashes && after.active?.lastSuccess == now &&
                  after.active?.hasImported == true && after.active?.restoreEnabled == true &&
                  after.active?.desiredEnabled == (outcome != "pause"), "restore retains identity, history and persisted intent: " + outcome)
            check(login.claimed, "restore does not release saved startup claim: " + outcome)
            controller.stop()
        }
    }
    @MainActor static func calendarRegressions() async throws {
        let suite = "DueBridge.NativeControllerTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for platform in [NativePlatform.mo, .learningInZJU] {
            var memory = [String: Data]()
            let store = NativeStateStore(read: { memory[$0] }, write: { memory[$0] = $1 })
            let scheduler = NativeTestScheduler(), login = NativeTestLogin()
            let destination = NativeCalendarProbe()
            let account = String(repeating: "a", count: 64)
            let now = ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z")!
            var verified = 0, accesses = 0, reminderWrites = 0, collections = 0
            let services = NativeSourceServices(openLogin: { _ in }, finishLogin: { _ in account },
                verify: { _, fingerprint in
                    check(fingerprint == account, "calendar restore verifies the connected account")
                    verified += 1
                }, collect: { _, scope, fingerprint in
                    collections += 1
                    let identity = try NativeTaskIdentity(scope: scope, courseID: "course", kind: .homework, taskID: "task")
                    let deadline = try NativeDeadlineParser.parse("2026-12-31T23:59:00+08:00", naiveTimeZone: DailySchedule.timeZone)
                    let task = try NativeDeadlineTask(identity: identity, courseName: "课程", title: "任务", deadline: deadline)
                    return NativeSourcePreview(scope: scope, accountFingerprint: fingerprint, candidates: [task], courseCount: 1)
                }, requestAccess: { accesses += 1 }, authorized: { false },
                write: { _, _, _, _ in
                    reminderWrites += 1
                    return (SyncResult(added: 0, updated: 0, skipped: 0, warnings: []), [])
                }, cancel: {}, close: {}, now: { now }, networkFailure: { _ in false }, errorMessage: { _ in "无法读取" })
            func controller() -> NativeSourceController {
                NativeSourceController(platform: platform, store: store, services: services, scheduler: scheduler, login: login,
                    calendar: CalendarSourceSync(destination: destination, defaults: defaults))
            }
            let first = controller()
            await first.start()
            first.beginConnect()
            await first.finishConnect()
            check(destination.received.isEmpty && collections == 1, "native preview collects without writing")
            await first.enableCalendar()
            check(first.calendarEnabled && !first.enabled && accesses == 0 && reminderWrites == 0 && collections == 2,
                  "native Calendar enable runs a fresh collect without Reminders authorization")
            let preview = first.preview!
            let received = destination.received.first!
            check(received.0.key == platform.rawValue + "-" + preview.scope.connectionID.uuidString.lowercased() &&
                  received.1.tasks.first?.key == preview.candidates.first?.identity.stableHash &&
                  received.1.tasks.first?.title == "【课程】任务 · 截止" &&
                  received.1.tasks.first?.link?.host == platform.verifiedHost, "native Calendar ownership binds verified account and task")
            await first.setRestore(true)
            first.stop()
            let restored = controller()
            await restored.start()
            check(restored.calendarEnabled && !restored.enabled && verified == 1 && collections == 2 && destination.received.count == 1,
                  "native Calendar-only restore verifies binding without replaying a same-day success")
            restored.pauseCalendar()
            restored.stop()
            let paused = controller()
            await paused.start()
            check(!paused.calendarEnabled && verified == 1, "native pause persists Calendar-only consent")
            paused.stop()
        }
    }
    @MainActor static func main() async throws {
        try await restoreRegressions()
        try await calendarRegressions()
        var memory = [String: Data]()
        let store = NativeStateStore(read: { memory[$0] }, write: { memory[$0] = $1 })
        let fingerprint = String(repeating: "a", count: 64)
        var now = ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z")!
        var writes = 0, opens = 0, reads = 0
        var fail = false
        var suspended: CheckedContinuation<Void, Never>?
        var hold = false
        let scheduler = NativeTestScheduler(), login = NativeTestLogin()
        let services = NativeSourceServices(openLogin: { _ in opens += 1 }, finishLogin: { _ in fingerprint }, verify: { _, _ in }, collect: { _, scope, account in
            reads += 1
            if hold { await withCheckedContinuation { suspended = $0 } }
            if fail { throw NativeControllerTestNetwork() }
            let identity = try NativeTaskIdentity(scope: scope, courseID: "course", kind: .homework, taskID: "task")
            let deadline = try NativeDeadlineParser.parse("2026-12-31T23:59:00+08:00", naiveTimeZone: DailySchedule.timeZone)
            return NativeSourcePreview(scope: scope, accountFingerprint: account,
                candidates: [try NativeDeadlineTask(identity: identity, courseName: "课程", title: "任务", deadline: deadline)], courseCount: 1)
        }, requestAccess: {}, authorized: { true }, write: { _, preview, _, shouldContinue in
            guard shouldContinue() else { throw NativeStateError.invalidState }
            writes += 1
            return (SyncResult(added: 1, updated: 0, skipped: 0, warnings: []), Set(preview.candidates.map { $0.identity.stableHash }))
        }, cancel: {}, close: {}, now: { now }, networkFailure: { $0 is NativeControllerTestNetwork }, errorMessage: { _ in "连接失败" })
        let c = NativeSourceController(platform: .mo, store: store, services: services, scheduler: scheduler, login: login)
        await c.start()
        check(opens == 0 && reads == 0 && memory.isEmpty, "opening app does not create new account session")
        c.beginConnect()
        check(opens == 1 && c.waitingForLogin, "explicit connection opens app login")
        await c.finishConnect()
        check(c.connected && c.preview?.candidates.count == 1 && writes == 0, "login previews source without importing")
        let originalID = c.preview!.scope.connectionID
        await c.enable()
        check(c.enabled && writes == 1, "enable imports after fresh complete read")
        check(scheduler.date == ISO8601DateFormatter().date(from: "2026-11-03T16:00:00Z"), "one slot arms Beijing midnight")
        await c.handleWake()
        check(writes == 1, "same-day wake has no repeat write")
        await c.setRestore(true)
        check(c.restoreEnabled && login.claimed, "explicit restore claims login startup")
        c.stop()
        let restored = NativeSourceController(platform: .mo, store: store, services: services, scheduler: scheduler, login: login)
        await restored.start()
        check(restored.enabled && writes == 1, "restart retains intent and same-day checkpoint")
        now = now.addingTimeInterval(86400)
        fail = true
        await restored.handleWake()
        check(writes == 1 && scheduler.date == now.addingTimeInterval(60), "network failure schedules bounded first retry")
        fail = false
        await restored.manualSync()
        check(writes == 2, "manual recovery writes and clears retry")
        hold = true
        let running = Task { await restored.manualSync() }
        for _ in 0..<50 where suspended == nil { await Task.yield() }
        check(suspended != nil, "read is suspended before pause")
        restored.pause()
        suspended?.resume(); suspended = nil
        await running.value
        check(writes == 2 && !restored.enabled && scheduler.date == nil, "pause during read prevents later write")
        hold = false
        restored.beginConnect(); await restored.finishConnect()
        check(restored.preview?.scope.connectionID == originalID, "same-account reconnect retains source identity")
        await restored.enable(); await restored.setRestore(false)
        check(!restored.restoreEnabled && !login.claimed, "disable native restoration releases own claim")
        restored.stop()
        let sessionOnly = NativeSourceController(platform: .mo, store: store, services: services, scheduler: scheduler, login: login)
        let oldReads = reads
        await sessionOnly.start()
        check(!sessionOnly.enabled && reads == oldReads, "session-only source does not silently restore")
        print("PASS: \(checks) native controller checks")
    }
}
