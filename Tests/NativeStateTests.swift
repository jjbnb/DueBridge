// Synthetic fixtures only; public school domains test exact request policies.
import Foundation

@main struct NativeStateTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { print("FAIL: " + message); exit(1) }
    }
    static func rejects(_ message: String, _ work: () throws -> Void) {
        do { try work(); print("FAIL: " + message); exit(1) }
        catch NativeStateError.invalidState { checks += 1 }
        catch { print("FAIL: unexpected error: " + message); exit(1) }
    }
    @MainActor static func main() throws {
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        var state = NativePlatformState()
        let first = try state.connect(fingerprint: a)
        check(state.activeID == first.id, "connection is selected after explicit connect")
        var saved = first
        saved.desiredEnabled = true; saved.restoreEnabled = true
        saved.recordSuccess(hashes: [a], now: Date(timeIntervalSince1970: 1_793_000_000))
        try state.update(saved)
        let same = try state.connect(fingerprint: a)
        check(same.id == first.id && same.knownHashes == [a], "same account keeps identity and import history")
        let other = try state.connect(fingerprint: b)
        check(other.id != first.id && other.knownHashes.isEmpty && !other.desiredEnabled, "new account cannot reuse history or enable intent")
        check(state.connections.first { $0.id == first.id }?.desiredEnabled == false, "old account paused when switching")
        check(state.connections.first { $0.id == first.id }?.restoreEnabled == false, "old account no longer claims restoration")
        let again = try state.connect(fingerprint: a)
        check(again.id == first.id && again.hasImported, "returning account keeps original reminder identities")
        rejects("invalid fingerprint refused") { _ = try state.connect(fingerprint: "token") }
        var corrupt = state; corrupt.connections.append(corrupt.connections[0])
        rejects("duplicate connection identity refused") { _ = try corrupt.validated() }
        corrupt = state; corrupt.activeID = UUID()
        rejects("unknown selected connection refused") { _ = try corrupt.validated() }
        corrupt = state; corrupt.connections[0].knownHashes = ["not-a-hash"]
        rejects("corrupt reminder history refused") { _ = try corrupt.validated() }
        let now = ISO8601DateFormatter().date(from: "2026-11-03T04:00:00Z")!
        var c = NativeConnectionState(accountFingerprint: a)
        c.desiredEnabled = true
        check(c.automaticDue(now: now), "new enabled connection catches up")
        c.recordSuccess(hashes: [], now: now)
        check(c.hasImported && c.knownHashes.isEmpty, "valid empty success has no manufactured hashes")
        check(!c.automaticDue(now: now.addingTimeInterval(60)), "same day success suppresses wake checks")
        check(c.automaticDue(now: now.addingTimeInterval(86400)), "next day requires check")
        check(c.automaticDue(now: now.addingTimeInterval(-3600)), "clock rollback invalidates future success")
        c.recordFailure(network: true, now: now)
        check(!c.automaticDue(now: now.addingTimeInterval(59)), "network retry waits sixty seconds")
        check(c.automaticDue(now: now.addingTimeInterval(60)), "first retry due at sixty seconds")
        c.recordFailure(network: true, now: now.addingTimeInterval(60))
        check(c.retry?.deadline == now.addingTimeInterval(360), "second delay is five minutes")
        c.recordFailure(network: true, now: now.addingTimeInterval(360))
        check(c.retry?.deadline == now.addingTimeInterval(1260), "third delay is fifteen minutes")
        c.recordFailure(network: true, now: now.addingTimeInterval(1260))
        check(c.retry?.deadline == nil && !c.automaticDue(now: now.addingTimeInterval(2000)), "retry budget exhausted until next day")
        check(c.automaticDue(now: now.addingTimeInterval(86400)), "fresh day resets network retry budget")
        c.recordFailure(network: false, now: now)
        check(!c.automaticDue(now: now.addingTimeInterval(86400)), "schema/auth block persists until manual recovery")
        check(c.nextCheck(now: now) == nil, "blocked source creates no timer")
        c.recordSuccess(hashes: [b], now: now)
        check(!c.blocked && c.retry == nil && c.knownHashes == [b], "manual success clears failures and checkpoints supplied union")
        check(c.nextCheck(now: now) == ISO8601DateFormatter().date(from: "2026-11-03T16:00:00Z"), "next check follows Beijing zero")
        c.desiredEnabled = false
        check(!c.automaticDue(now: now.addingTimeInterval(86400)) && c.nextCheck(now: now) == nil, "pause suppresses scheduling")
        var memory = [String: Data]()
        let store = NativeStateStore(read: { memory[$0] }, write: { memory[$0] = $1 })
        let fresh = try store.load(.mo)
        check(fresh == nil, "fresh install does not create session metadata")
        try store.save(state, for: .mo)
        let loaded = try store.load(.mo), isolated = try store.load(.learningInZJU)
        check(loaded?.activeID == state.activeID, "state survives persisted roundtrip")
        check(isolated == nil, "platform metadata isolated")
        let text = String(data: memory["nativeCourses.v1.mo"]!, encoding: .utf8)!
        check(!text.contains("token") && !text.contains("calendarFeed"), "nonsecret metadata has no credentials or BB keys")
        memory["nativeCourses.v1.mo"] = Data("{}".utf8)
        rejects("corrupt metadata never silently resets IDs") { _ = try store.load(.mo) }
        print("PASS: \(checks) native state checks")
    }
}
