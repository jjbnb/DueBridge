// Synthetic fixtures only; public school domains test exact request policies.
import Foundation

// All external effects are replaced at their boundary; the actual controller,
// metadata/checkpoint policy, generation guards, and scheduler decisions run here.
@MainActor final class MemoryRestartSettings: RestartSettings {
    var record: RestartMetadata?
    func load() -> RestartMetadata? { record }
    func save(_ value: RestartMetadata?) { record = value }
}
@MainActor final class MemoryVault: RestartVault {
    var value: String?
    var failure: Error?
    var reads = [Bool]()
    var writes = 0
    var suspended: CheckedContinuation<String, Error>?
    var suspendRead = false
    func read(interactive: Bool) async throws -> String {
        reads.append(interactive)
        if suspendRead { return try await withCheckedThrowingContinuation { suspended = $0 } }
        if let failure { throw failure }
        guard let value else { throw RestoreFailure.missing }
        return value
    }
    func save(_ value: String) async throws {
        if let failure { throw failure }; self.value = value; writes += 1
    }
}
@MainActor final class MemoryLogin: RestartLogin {
    var state: LoginAvailability = .enabled
    var inspections = 0, registrations = 0, removals = 0
    var failure = false
    func status() -> LoginAvailability { inspections += 1; return state }
    func register() throws -> LoginAvailability {
        registrations += 1
        if failure { throw RestoreFailure.unavailable }
        return state
    }
    func unregister() async throws { removals += 1 }
    func openSettings() {}
}
@MainActor final class MemoryScheduler: SyncScheduling {
    var date: Date?
    var callback: (() -> Void)?
    func schedule(at date: Date, action: @escaping () -> Void) { self.date = date; callback = action }
    func cancel() { date = nil; callback = nil }
}
@MainActor final class Fixture {
    // Intentionally fake hex credential, never a user's private subscription.
    let address = "https://learn.intl.zju.edu.cn/webapps/calendar/calendarFeed/synthetic-feed-example-a/learn.ics"
    let alternate = "https://learn.intl.zju.edu.cn/webapps/calendar/calendarFeed/synthetic-feed-example-b/learn.ics"
    let settings = MemoryRestartSettings(), vault = MemoryVault(), login = MemoryLogin(), scheduler = MemoryScheduler()
    var now = ISO8601DateFormatter().date(from: "2026-10-27T09:00:00Z")!
    var fetched = [String](), commits = 0, requests = 0
    var failure: Error?
    var response: HTTPURLResponse?
    var authorized = true
    var grantAccessOnRequest = false
    var accessFailure: Error?
    var suspendAccess = false
    var suspendedAccess: CheckedContinuation<Void, Never>?
    var writeFailure: Error?
    var suspendWrite = false
    var suspendedWrite: CheckedContinuation<Void, Never>?
    var suspendedFetch: CheckedContinuation<Feed, Error>?
    var suspendFetch = false
    let feed = Feed(events: [], warnings: [])
    func controller() -> SyncController {
        let services = SyncServices(fetch: { address in
            self.fetched.append(address)
            if self.suspendFetch { return try await withCheckedThrowingContinuation { self.suspendedFetch = $0 } }
            if let response = self.response { try FeedFetcher.validateResponse(response) }
            if let failure = self.failure { throw failure }; return self.feed
        }, requestAccess: {
            self.requests += 1
            if self.suspendAccess { await withCheckedContinuation { self.suspendedAccess = $0 } }
            if let failure = self.accessFailure { throw failure }
            if self.grantAccessOnRequest { self.authorized = true }
        }, authorized: { self.authorized }, reconcile: { _, _, valid in
            if self.suspendWrite { await withCheckedContinuation { self.suspendedWrite = $0 } }
            if let failure = self.writeFailure { throw failure }
            guard valid() else { throw SafeError("cancelled") }
            self.commits += 1
            return SyncResult(added: 0, updated: 0, skipped: 0, warnings: [])
        }, now: { self.now }, loadCourses: { [:] }, saveCourses: { _ in }, scheduler: scheduler)
        return SyncController(services: services, restore: RestartRestore(settings: settings, vault: vault, login: login))
    }
    func configured(lastSuccess: Date? = nil) {
        vault.value = address
        settings.record = RestartMetadata(fingerprint: RestartRestore.fingerprint(address), desiredEnabled: true,
                                           lastSuccess: lastSuccess)
    }
    func enableAndSave(_ controller: SyncController) async {
        controller.source = address
        await controller.readPreview(); await controller.enable(); await controller.saveForRestart()
    }
}
@main struct RestartRestoreTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { print("FAIL: \(message)"); exit(1) }
    }
    @MainActor static func main() async throws {
        // Removing the restore branch must fail this real-controller regression.
        let restore = Fixture(); restore.configured(lastSuccess: restore.now)
        let restored = restore.controller(); await restored.start()
        check(restored.enabled && restored.source == restore.address, "opted-in controller restores saved URL and intent")
        check(restore.commits == 0 && restore.requests == 0, "same Shanghai day restart neither writes nor requests access")
        check(restore.vault.reads == [false], "automatic restore reads noninteractively once")
        restored.stop()

        let off = Fixture(); let session = off.controller(); await session.start()
        check(off.vault.reads.isEmpty && off.login.inspections == 0 && off.login.registrations == 0, "default startup has zero vault/login operations")
        check(!session.enabled && session.source.isEmpty, "default startup stays session-only")
        await off.enableAndSave(session)
        check(off.vault.writes == 1 && off.vault.value == off.address, "explicit configured action saves exact current validated source")
        check(off.settings.record?.desiredEnabled == true, "successful setup persists enabled intent")
        let persistedData = try JSONEncoder().encode(off.settings.record!)
        check(!String(decoding: persistedData, as: UTF8.self).contains(off.address), "nonsecret metadata contains no URL")
        session.pause(); session.stop()
        let paused = off.controller(); await paused.start()
        check(!paused.enabled && off.vault.reads.isEmpty, "paused restart does not read saved credential")
        paused.stop()

        let next = Fixture(); next.configured(lastSuccess: next.now.addingTimeInterval(-86400))
        let catchup = next.controller(); await catchup.start()
        check(next.commits == 1 && next.settings.record?.lastSuccess == next.now, "next day startup commits catchup and checkpoints")
        await catchup.handleWake(); await catchup.syncAutomatically()
        check(next.commits == 1, "wake and duplicate auto checks deduplicate after commit")
        await catchup.manualSync(); check(next.commits == 2, "manual sync bypasses same-day dedup")
        catchup.stop(); check(next.scheduler.date == nil, "stop cancels owned scheduler")

        let retry = Fixture(); retry.configured(); retry.failure = NetworkFailure()
        var retryController = retry.controller(); await retryController.start()
        check(retry.settings.record?.retry?.count == 1 && retry.scheduler.date == retry.now.addingTimeInterval(60), "network failure schedules first retry after 60 seconds")
        check(retry.settings.record?.lastSuccess == nil, "failed write does not checkpoint success")
        for (advance, count, delay) in [(60.0, 2, 300.0), (300.0, 3, 900.0)] {
            retryController.stop(); retry.now.addTimeInterval(advance)
            retryController = retry.controller(); await retryController.start()
            check(retry.settings.record?.retry?.count == count && retry.scheduler.date == retry.now.addingTimeInterval(delay), "restart preserves network retry count and next deadline")
        }
        retryController.stop(); retry.now.addTimeInterval(900)
        retryController = retry.controller(); await retryController.start()
        check(retry.settings.record?.retry?.count == 3 && retry.scheduler.date == DailySchedule.nextMidnight(after: retry.now), "exhausted retries wait for next day")
        let attempts = retry.fetched.count
        await retryController.handleWake(); check(retry.fetched.count == attempts, "wake cannot bypass exhausted retry cap")
        await retryController.manualSync(); check(retry.fetched.count == attempts + 1, "explicit manual retry bypasses backoff")
        retryController.stop()

        let permanent = Fixture(); permanent.configured(); permanent.failure = SafeError("invalid feed")
        let blocked = permanent.controller(); await blocked.start(); await blocked.handleWake()
        check(permanent.fetched.count == 1 && permanent.settings.record?.retry == nil, "permanent feed failure stops automatic retries")
        check(permanent.vault.reads == [false] && permanent.requests == 0, "permanent failure never prompts or rereads credential")
        blocked.stop()

        let stale = Fixture(); stale.configured(); stale.vault.suspendRead = true
        let staleController = stale.controller()
        let startup = Task { await staleController.start() }
        while stale.vault.suspended == nil { await Task.yield() }
        staleController.source = stale.alternate
        stale.vault.suspended?.resume(returning: stale.address); await startup.value
        check(!staleController.enabled && staleController.source == stale.alternate && stale.commits == 0, "source edit invalidates asynchronous credential restore")
        check(stale.settings.record?.desiredEnabled == false, "source edit persists paused intent")
        staleController.stop()

        let pause = Fixture(); pause.configured(); pause.suspendFetch = true
        let pauseController = pause.controller(); let inFlight = Task { await pauseController.start() }
        while pause.suspendedFetch == nil { await Task.yield() }
        pauseController.pause(); pause.suspendedFetch?.resume(returning: pause.feed); await inFlight.value
        check(pause.commits == 0 && pause.settings.record?.lastSuccess == nil, "pause during fetch prevents write and success checkpoint")
        pauseController.stop()

        let denied = Fixture(); denied.configured(); denied.vault.failure = RestoreFailure.denied
        let deniedController = denied.controller(); await deniedController.start()
        check(!deniedController.enabled && denied.settings.record?.desiredEnabled == true && deniedController.canRecover, "denied credential preserves desired intent and offers explicit recovery")
        denied.vault.failure = nil; await deniedController.recoverSavedSource()
        check(deniedController.enabled && denied.vault.reads == [false, true], "explicit recovery alone permits interactive credential read")
        check(denied.requests == 0, "already authorized recovery does not request permission again")
        deniedController.stop()

        let approval = Fixture(); approval.login.state = .requiresApproval
        let approvalController = approval.controller(); await approvalController.start(); await approval.enableAndSave(approvalController)
        check(approval.settings.record != nil && approvalController.loginAvailability == .requiresApproval, "saved source remains configured when login needs OS approval")
        check(approvalController.restoreStatus.contains("批准") && !approvalController.restoreStatus.contains("已就绪"), "partial setup reports approval requirement honestly")
        approvalController.stop()
        let failed = Fixture(); failed.vault.failure = RestoreFailure.denied
        let failedController = failed.controller(); await failedController.start(); await failed.enableAndSave(failedController)
        check(failed.settings.record == nil && failed.login.registrations == 0, "save failure never configures consent or registers login")
        failedController.stop()

        for bad in [Date.distantFuture, Date(timeIntervalSince1970: -1)] {
            let corrupt = Fixture(); corrupt.configured(lastSuccess: bad)
            let c = corrupt.controller(); await c.start()
            check(corrupt.commits == 1, "future or pre-epoch checkpoint cannot suppress catchup")
            c.stop()
        }
        let mismatch = Fixture(); mismatch.configured(); mismatch.vault.value = mismatch.alternate
        let mismatchController = mismatch.controller(); await mismatchController.start()
        check(!mismatchController.enabled && mismatch.commits == 0, "fingerprint mismatch blocks saved credential")
        mismatchController.stop()
        let invalid = Fixture(); invalid.configured(); invalid.vault.value = "https://example.invalid/aaaaaaaa"
        let invalidController = invalid.controller(); await invalidController.start()
        check(!invalidController.enabled && invalid.fetched.isEmpty, "invalid saved URL never fetches")
        invalidController.stop()
        let legacy = Fixture(); legacy.configured(); legacy.settings.record?.version = 0
        let legacyController = legacy.controller(); await legacyController.start()
        check(legacy.vault.reads.isEmpty && legacy.login.inspections == 0 && !legacyController.enabled, "legacy metadata cannot imply new consent")
        legacyController.stop()

        let changed = Fixture(); let changedController = changed.controller(); await changedController.start()
        await changed.enableAndSave(changedController)
        changedController.source = changed.alternate
        changed.failure = NetworkFailure()
        changed.failure = nil; await changedController.readPreview()
        changed.failure = NetworkFailure(); await changedController.enable(); await changedController.saveForRestart()
        check(changed.settings.record?.lastSuccess == nil, "new source cannot inherit previous source success checkpoint after failed sync")
        check(changed.settings.record?.fingerprint == RestartRestore.fingerprint(changed.alternate), "explicit setup updates fingerprint only to validated enabled source")
        changedController.stop()

        let writer = Fixture(); writer.configured(); writer.suspendWrite = true
        let writerController = writer.controller(); let writeTask = Task { await writerController.start() }
        while writer.suspendedWrite == nil { await Task.yield() }
        writerController.pause(); writer.suspendedWrite?.resume(); await writeTask.value
        check(writer.commits == 0 && writer.settings.record?.lastSuccess == nil, "writer receives live generation gate after asynchronous preparation")
        writerController.stop()

        let writeFailure = Fixture(); writeFailure.configured(); writeFailure.writeFailure = SafeError("commit failed")
        let failureController = writeFailure.controller(); await failureController.start()
        check(writeFailure.settings.record?.lastSuccess == nil && writeFailure.commits == 0, "failed commit cannot advance persisted success")
        failureController.stop()

        let busy = Fixture(); busy.configured(); busy.suspendFetch = true
        let busyController = busy.controller(); let busyTask = Task { await busyController.start() }
        while busy.suspendedFetch == nil { await Task.yield() }
        await busyController.handleWake(); await busyController.handleWake()
        busy.suspendedFetch?.resume(returning: busy.feed); await busyTask.value
        for _ in 0..<10 { await Task.yield() }
        check(busy.commits == 1 && busy.fetched.count == 1, "repeated wake during fetch coalesces and never duplicates writes")
        busyController.stop()

        let permission = Fixture(); permission.configured(); permission.authorized = false
        let permissionController = permission.controller(); await permissionController.start()
        check(permission.requests == 0 && permission.fetched.isEmpty && permission.settings.record?.desiredEnabled == true, "revoked reminder permission preserves intent without permission prompt or fetch")
        permission.grantAccessOnRequest = true
        await permissionController.recoverSavedSource()
        check(permissionController.enabled && permissionController.source == permission.address && permission.commits == 1,
              "explicit recovery obtains permission and restores the saved source without repasting")
        check(permission.requests == 1 && permission.settings.record?.lastSuccess == permission.now,
              "successful permission recovery requests once and checkpoints only the actual sync")
        permissionController.stop()

        for deniedAccess in [true, false] {
            let access = Fixture(); access.configured(); access.authorized = false
            if deniedAccess { access.accessFailure = SafeError("permission denied") }
            let c = access.controller(); await c.start(); await c.recoverSavedSource()
            check(!c.enabled && c.canRecover && access.fetched.isEmpty && access.commits == 0 && access.settings.record?.desiredEnabled == true,
                  "denied or still unauthorized recovery preserves intent and performs no feed read or write")
            c.stop()
        }

        // Removing the post-permission generation guard must allow a stale
        // recovery to undo pause/edit/quit; exercise the real controller boundary.
        for action in ["pause", "edit", "stop"] {
            let access = Fixture(); access.configured(); access.authorized = false
            access.grantAccessOnRequest = true; access.suspendAccess = true
            let c = access.controller(); await c.start()
            let recovery = Task { await c.recoverSavedSource() }
            while access.suspendedAccess == nil { await Task.yield() }
            switch action {
            case "pause": c.pause()
            case "edit": c.source = access.alternate
            default: c.stop()
            }
            access.suspendedAccess?.resume(); await recovery.value
            check(!c.enabled && access.fetched.isEmpty && access.commits == 0 && access.scheduler.date == nil,
                  "permission result cannot resume stale restoration after " + action)
            if action == "edit" { check(c.source == access.alternate, "permission recovery cannot overwrite an edited source") }
            c.stop()
        }

        let loginFailure = Fixture(); loginFailure.login.failure = true; loginFailure.login.state = .notRegistered
        let loginFailureController = loginFailure.controller(); await loginFailureController.start(); await loginFailure.enableAndSave(loginFailureController)
        check(loginFailure.settings.record != nil && loginFailureController.restoreStatus.contains("链接保存成功") && loginFailureController.restoreStatus.contains("失败"), "save-success login-failure explains partial completion")
        loginFailureController.stop()

        let revoke = Fixture(); revoke.configured(lastSuccess: revoke.now); revoke.login.state = .notRegistered
        let revokeController = revoke.controller(); await revokeController.start(); revokeController.refreshLoginStatus()
        check(revoke.login.registrations == 0 && revokeController.loginAvailability == .notRegistered, "OS login revocation is reported without automatic registration")
        await revokeController.disableRestartRestore()
        check(revoke.settings.record == nil && !revokeController.enabled && revoke.login.removals == 1, "explicit disable revokes metadata and login intent")
        revokeController.stop()

        let futureRetry = Fixture(); futureRetry.configured()
        futureRetry.settings.record?.retry = RetryCheckpoint(cycle: DailySchedule.midnight(for: futureRetry.now), count: 1, deadline: Date.distantFuture)
        let futureRetryController = futureRetry.controller(); await futureRetryController.start()
        check(futureRetry.commits == 1, "corrupt retry deadline cannot suppress catchup indefinitely")
        futureRetryController.stop()

        let waiting = Fixture(); waiting.configured(); waiting.failure = NetworkFailure()
        var waitingController = waiting.controller(); await waitingController.start(); waitingController.stop()
        waiting.now.addTimeInterval(10); waitingController = waiting.controller(); await waitingController.start()
        check(waiting.fetched.count == 1 && waiting.scheduler.date == waiting.now.addingTimeInterval(50), "restart before backoff deadline cannot make another request")
        waitingController.stop()
        waiting.now.addTimeInterval(86400); waiting.failure = nil
        waitingController = waiting.controller(); await waitingController.start()
        check(waiting.commits == 1 && waiting.settings.record?.retry == nil, "new Shanghai day clears exhausted prior retry cycle")
        waitingController.stop()

        let stop = Fixture(); stop.configured(); stop.vault.suspendRead = true
        let stopController = stop.controller(); let stopping = Task { await stopController.start() }
        while stop.vault.suspended == nil { await Task.yield() }
        stopController.stop(); stop.vault.suspended?.resume(returning: stop.address); await stopping.value
        check(!stopController.enabled && stop.commits == 0 && stop.scheduler.date == nil && stop.settings.record?.desiredEnabled == true, "quit cancels stale restore without losing persisted intent")

        let initialFailure = Fixture(); let initialFailureController = initialFailure.controller(); await initialFailureController.start()
        initialFailureController.source = initialFailure.address; await initialFailureController.readPreview()
        initialFailure.failure = NetworkFailure(); await initialFailureController.enable(); await initialFailureController.saveForRestart()
        check(initialFailure.settings.record?.retry?.count == 1, "first explicit setup preserves already pending network backoff")
        initialFailureController.stop()

        let persistedBlock = Fixture(); persistedBlock.configured(); persistedBlock.failure = SafeError("invalid feed")
        let firstBlock = persistedBlock.controller(); await firstBlock.start(); firstBlock.stop()
        let resumedBlock = persistedBlock.controller(); await resumedBlock.start()
        check(persistedBlock.fetched.count == 1 && resumedBlock.status.contains("自动重试已停止"), "restart reports persisted permanent failure without claiming active automatic recovery")
        resumedBlock.stop()

        // Uses the exact real fetch response boundary, with no URLSession/network.
        let responses = Fixture()
        for status in [408, 429, 500, 502, 503, 504, 507, 599] {
            let response = HTTPURLResponse(url: URL(string: responses.address)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/calendar"])!
            do { try FeedFetcher.validateResponse(response); check(false, "temporary HTTP status must fail before consuming feed") }
            catch { check(error is NetworkFailure, "temporary HTTP \(status) enters finite network retry policy") }
        }
        for (address, status, mime) in [(responses.address, 401, "text/calendar"),
                                         (responses.address, 403, "text/html"),
                                         (responses.address, 404, "text/calendar"),
                                         (responses.address, 200, "text/html"),
                                         ("https://example.invalid/aaaaaaaa", 503, "text/calendar"),
                                         ("https://learn.intl.zju.edu.cn/webapps/calendar/view", 503, "text/calendar")] {
            let response = HTTPURLResponse(url: URL(string: address)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
            do { try FeedFetcher.validateResponse(response); check(false, "unsafe/authentication/malformed response must be rejected") }
            catch { check(error is SafeError && !(error is NetworkFailure), "unsafe/authentication/malformed response never enters retry policy") }
        }
        do { _ = try ICSParser.parse("<html>login</html>"); check(false, "malformed feed must fail") }
        catch { check(error is SafeError && !(error is NetworkFailure), "malformed feed remains permanent") }
        responses.configured()
        responses.response = HTTPURLResponse(url: URL(string: responses.address)!, statusCode: 503, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        let responseController = responses.controller(); await responseController.start()
        check(responses.settings.record?.retry?.count == 1 && responses.scheduler.date == responses.now.addingTimeInterval(60), "real 503 classification schedules controller backoff")
        responses.response = HTTPURLResponse(url: URL(string: responses.address)!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/calendar"])!
        responses.now.addTimeInterval(60); await responseController.syncAutomatically()
        check(responses.commits == 1 && responses.settings.record?.retry == nil, "real-response transient retry succeeds when server recovers")
        responseController.stop()

        for configured in [true, false] {
            let transition = Fixture()
            var transitionController: SyncController
            if configured {
                transition.configured(); transition.failure = SafeError("invalid feed")
                transitionController = transition.controller(); await transitionController.start()
            } else {
                transitionController = transition.controller(); await transitionController.start()
                transitionController.source = transition.address; await transitionController.readPreview()
                transition.failure = SafeError("invalid feed"); await transitionController.enable()
            }
            transition.now.addTimeInterval(86400)
            await transitionController.syncAutomatically()
            check(transition.fetched.count == (configured ? 1 : 2), "genuine permanent block survives midnight without an explicit retry")
            transition.failure = NetworkFailure(); await transitionController.manualSync()
            check(transition.scheduler.date == transition.now.addingTimeInterval(60), "explicit transient attempt replaces old permanent state with backoff")
            if configured {
                check(transition.settings.record?.blockedDay == nil && transition.settings.record?.retry?.count == 1, "persisted failure states are mutually consistent after transient attempt")
                transitionController.stop(); transitionController = transition.controller(); await transitionController.start()
                check(transition.settings.record?.retry?.count == 1, "permanent-to-transient retry budget survives recreation")
            }
            transition.failure = nil; transition.now.addTimeInterval(60)
            await transitionController.syncAutomatically()
            check(transition.commits == 1, "permanent then explicit transient failure permits due automatic success")
            await transitionController.syncAutomatically()
            check(transition.commits == 1, "recovered transient attempt returns to same-day dedup")
            transitionController.stop()
        }

        for configured in [true, false] {
            let clock = Fixture()
            let clockController: SyncController
            if configured {
                clock.configured(); clockController = clock.controller(); await clockController.start()
            } else {
                clockController = clock.controller(); await clockController.start()
                clockController.source = clock.address; await clockController.readPreview(); await clockController.enable()
            }
            check(clock.commits == 1, "clock rollback fixture begins with one successful reconciliation")
            clock.now.addTimeInterval(-90 * 86400)
            await clockController.handleClockChange()
            check(clock.commits == 2, "live backward clock correction allows exactly one catchup in configured and session modes")
            if configured { check(clock.settings.record?.lastSuccess == clock.now, "rollback replaces future saved success with current actual commit time") }
            check(clock.scheduler.date == DailySchedule.nextMidnight(after: clock.now), "clock correction rearms the one daily scheduler at corrected midnight")
            await clockController.syncAutomatically(); await clockController.handleClockChange(); await clockController.handleWake()
            check(clock.commits == 2, "post-rollback automatic/wake/clock events return to same-day dedup")
            clockController.stop()
        }

        let summary = Fixture(); summary.configured(lastSuccess: summary.now)
        let summaryController = summary.controller(); await summaryController.start()
        summaryController.source = summary.alternate
        check(summary.settings.record?.desiredEnabled == false && summaryController.restoreStatus.contains("自动同步已暂停"), "source edit refreshes saved pause summary immediately")
        summaryController.stop()

        print("Restart restore: \(checks) checks passed")
    }
}
