// Synthetic fixtures only; public school domains test exact request policies.
// Appended to a build-only source copy for private access. The runner replaces only
// navigation sleep with a controlled clock and observes its stopLoading branch. No view,
// store, window, account or real navigation is created by these tests.
@MainActor private enum ControlledNavigationClock {
    static var sleepers = [CheckedContinuation<Void, Error>]()
    static var armed = 0
    static var stopAttempts = 0
    static func sleep() async throws {
        try await withCheckedThrowingContinuation { continuation in
            armed += 1
            sleepers.append(continuation)
        }
    }
    static func completeFirst() {
        precondition(!sleepers.isEmpty)
        // Successful sleep completes before cancellation/replacement. Its suspended
        // MainActor caller cannot resume until the current synchronous block exits.
        sleepers.removeFirst().resume(returning: ())
    }
}

@MainActor private final class NavigationReceipt {
    var installed = false
    var completions = 0
    var timeout = false
    var failure: NativeSessionError?
}

@MainActor private enum NavigationDeadlineChecks {
    static var count = 0
    static func check(_ valid: @autoclosure () -> Bool, _ message: String) throws {
        count += 1
        guard valid() else { throw Failure.failed(message) }
    }
    enum Failure: Error { case failed(String) }
    static func waitFor(_ ready: () -> Bool) async throws {
        // All waits are actor turns under a controlled clock, not real time/sleeps.
        for _ in 0..<1000 {
            if ready() { return }
            await Task.yield()
        }
        throw Failure.failed("fixture did not reach its controlled suspension")
    }
}

extension NativeWebSession {
    @MainActor fileprivate func checkFramePolicyIsolation() async throws {
        let previousArmed = ControlledNavigationClock.armed
        startNavigationDeadline()
        let deadline = navigationDeadline!
        try await NavigationDeadlineChecks.waitFor { ControlledNavigationClock.armed == previousArmed + 1 }
        let ticket = navigationDeadlineID
        let receipt = NavigationReceipt()
        let operation = Task { @MainActor in
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    navigationContinuation = continuation
                    receipt.installed = true
                }
            } catch let failure as NativeSessionError { receipt.failure = failure }
            catch {}
            receipt.completions += 1
        }
        try await NavigationDeadlineChecks.waitFor { receipt.installed }
        rejectNavigation(.unsafeRequest, isMainFrame: false, isCurrentView: true)
        try NavigationDeadlineChecks.check(navigationDeadlineID == ticket && navigationContinuation != nil && lastError == nil, "rejected child frame preserves the main navigation deadline and continuation")
        rejectNavigation(.invalidResponse, isMainFrame: true, isCurrentView: false)
        try NavigationDeadlineChecks.check(navigationDeadlineID == ticket && navigationContinuation != nil && lastError == nil, "stale view rejection cannot settle the current navigation")
        rejectNavigation(.unsafeRequest, isMainFrame: true, isCurrentView: true)
        await operation.value
        try NavigationDeadlineChecks.check(receipt.completions == 1 && receipt.failure == .unsafeRequest, "current main-frame rejection settles once with its safe failure")
        try NavigationDeadlineChecks.check(navigationDeadline == nil && navigationContinuation == nil, "main-frame rejection invalidates its deadline")
        rejectNavigation(.unsafeRequest, isMainFrame: true, isCurrentView: true)
        try NavigationDeadlineChecks.check(receipt.completions == 1, "repeated policy rejection cannot resume a settled continuation twice")
        ControlledNavigationClock.completeFirst()
        await deadline.value
        lastError = .network
        acceptNavigation(isMainFrame: false, isCurrentView: true)
        try NavigationDeadlineChecks.check(lastError == .network, "accepted child frame cannot hide a main-frame failure")
        acceptNavigation(isMainFrame: true, isCurrentView: false)
        try NavigationDeadlineChecks.check(lastError == .network, "accepted stale view cannot clear the current failure")
        acceptNavigation(isMainFrame: true, isCurrentView: true)
        try NavigationDeadlineChecks.check(lastError == nil, "valid current top-level navigation clears the previous failure")
        try NavigationDeadlineChecks.check(webView == nil && loginWindow == nil, "frame policy checks create no WebKit resources")
        cancel()
    }
    @MainActor fileprivate func checkFailedLoginPreservesCause(_ failure: NativeSessionError) async throws {
        interactive = true
        lastError = failure
        var observed: NativeSessionError?
        do { _ = try await finishLogin() }
        catch let error as NativeSessionError { observed = error }
        try NavigationDeadlineChecks.check(observed == failure, "finishing a failed interactive login preserves its safe failure")
        try NavigationDeadlineChecks.check(webView == nil && loginWindow == nil, "failed login check creates no WebKit resources")
        cancel()
    }
    @MainActor fileprivate func checkQueuedNavigationDeadline(cancelFirst: Bool) async throws {
        try NavigationDeadlineChecks.check(webView == nil && loginWindow == nil, "session starts inert")
        let previousArmed = ControlledNavigationClock.armed
        let previousStops = ControlledNavigationClock.stopAttempts
        startNavigationDeadline()
        let oldDeadline = navigationDeadline!
        try await NavigationDeadlineChecks.waitFor { ControlledNavigationClock.armed == previousArmed + 1 }
        let receipt = NavigationReceipt()
        let operation = Task { @MainActor in
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    ControlledNavigationClock.completeFirst()
                    if cancelFirst { cancel() }
                    startNavigationDeadline()
                    navigationContinuation = continuation
                    receipt.installed = true
                }
            } catch NativeSessionError.timeout { receipt.timeout = true }
            catch {}
            receipt.completions += 1
        }
        try await NavigationDeadlineChecks.waitFor { receipt.installed }
        await oldDeadline.value
        try NavigationDeadlineChecks.check(ControlledNavigationClock.stopAttempts == previousStops, "expired old timer must not stop the current view")
        try NavigationDeadlineChecks.check(lastError == nil, "expired old timer must not report timeout after \(cancelFirst ? "cancel/reconnect" : "replacement")")
        try NavigationDeadlineChecks.check(navigationDeadline != nil, "expired old timer must preserve replacement deadline")
        try NavigationDeadlineChecks.check(navigationContinuation != nil && receipt.completions == 0, "expired old timer must preserve replacement continuation")
        try NavigationDeadlineChecks.check(webView == nil && loginWindow == nil, "deadline race creates no WebKit resources")
        let currentDeadline = navigationDeadline!
        try await NavigationDeadlineChecks.waitFor { ControlledNavigationClock.armed == previousArmed + 2 }
        ControlledNavigationClock.completeFirst()
        await currentDeadline.value
        await operation.value
        try NavigationDeadlineChecks.check(ControlledNavigationClock.stopAttempts == previousStops + 1, "current timer stops only its own view once")
        try NavigationDeadlineChecks.check(lastError == .timeout, "current timer still reports its own timeout")
        try NavigationDeadlineChecks.check(navigationDeadline == nil && navigationContinuation == nil, "current timer clears its settled operation")
        try NavigationDeadlineChecks.check(receipt.completions == 1 && receipt.timeout, "current continuation resumes exactly once with timeout")
        cancel()
    }
    @MainActor fileprivate func checkCompletedNavigationDeadline() async throws {
        let previousArmed = ControlledNavigationClock.armed
        let previousStops = ControlledNavigationClock.stopAttempts
        startNavigationDeadline()
        let oldDeadline = navigationDeadline!
        try await NavigationDeadlineChecks.waitFor { ControlledNavigationClock.armed == previousArmed + 1 }
        ControlledNavigationClock.completeFirst()
        finishNavigation(.success(()))
        await oldDeadline.value
        try NavigationDeadlineChecks.check(ControlledNavigationClock.stopAttempts == previousStops, "settled timer must not request a view stop")
        try NavigationDeadlineChecks.check(lastError == nil, "successful navigation invalidates expired queued deadline")
        try NavigationDeadlineChecks.check(navigationDeadline == nil && navigationContinuation == nil, "completed navigation stays settled")
        try NavigationDeadlineChecks.check(webView == nil && loginWindow == nil, "completion race creates no WebKit resources")
        cancel()
    }
}

@main private struct NativeNavigationDeadlineTests {
    @MainActor static func main() async {
        do {
            let frameSession = NativeWebSession(platform: .mo, storeID: UUID())
            try await frameSession.checkFramePolicyIsolation()
            for failure: NativeSessionError in [.timeout, .unsafeRequest, .network] {
                let session = NativeWebSession(platform: .mo, storeID: UUID())
                try await session.checkFailedLoginPreservesCause(failure)
            }
            for cancelFirst in [false, true] {
                let session = NativeWebSession(platform: .mo, storeID: UUID())
                try await session.checkQueuedNavigationDeadline(cancelFirst: cancelFirst)
            }
            let session = NativeWebSession(platform: .learningInZJU, storeID: UUID())
            try await session.checkCompletedNavigationDeadline()
            try NavigationDeadlineChecks.check(ControlledNavigationClock.sleepers.isEmpty, "all test sleeps settle")
            print("PASS: \(NavigationDeadlineChecks.count) inert navigation deadline checks")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }
}
