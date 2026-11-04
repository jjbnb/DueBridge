// Synthetic fixtures only; public school domains test exact request policies.
import Foundation

@main struct SourceReadGateTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { print("FAIL: " + message); exit(1) }
        }
        let gate = SourceReadGate(limit: 2)
        var starts = [Int]()
        var releases = [Int: CheckedContinuation<Void, Never>]()
        func work(_ id: Int) -> Task<Void, Error> {
            Task { @MainActor in
                try await gate.withPermit {
                    starts.append(id)
                    await withCheckedContinuation { releases[id] = $0 }
                }
            }
        }
        let first = work(1), second = work(2)
        while releases.count < 2 { await Task.yield() }
        let third = work(3)
        for _ in 0..<20 { await Task.yield() }
        check(starts.count == 2, "third source must wait while two reads are running")
        third.cancel()
        do { try await third.value; check(false, "cancelled queued source must fail") }
        catch { check(error is CancellationError, "queued cancellation is propagated") }
        check(!starts.contains(3), "cancelled queued source never accesses its session")
        releases.removeValue(forKey: 1)?.resume(); try await first.value
        let fourth = work(4)
        while releases[4] == nil { await Task.yield() }
        check(Set(starts) == Set([1, 2, 4]) && starts.last == 4, "cancelled waiter does not consume a future permit")
        releases.removeValue(forKey: 2)?.resume(); releases.removeValue(forKey: 4)?.resume()
        try await second.value; try await fourth.value
        enum Failure: Error { case expected }
        do { try await gate.withPermit { throw Failure.expected } }
        catch { check(error is Failure, "read failure is preserved") }
        let result = try await gate.withPermit { 42 }
        check(result == 42, "failed reads release their permit for the next source")
        print("SourceReadGateTests: \(checks) checks passed")
    }
}
