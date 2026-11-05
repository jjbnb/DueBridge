// Synthetic fixtures only; public school domains test exact request policies.
import Foundation

@main
struct PreviewClockTests {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(condition(), message)
        }
        func run(for seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func wait(until condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
                run(for: 0.01)
            }
            return condition()
        }
        var instant = Date(timeIntervalSince1970: 1_000)
        let clock = PreviewClock(interval: 0.04, currentDate: { instant })
        check(!clock.isRunning && clock.refreshCount == 0, "creation does not schedule")
        clock.stop(); clock.stop()
        clock.start()
        check(clock.isRunning && clock.refreshCount == 1, "start immediately refreshes")
        clock.start(); clock.setRunning(true)
        check(clock.refreshCount == 1, "duplicate visibility/activation does not refresh or add timers")
        instant = instant.addingTimeInterval(60)
        // Timer delivery may be delayed/coalesced on a busy run loop; its exact tick count is not a contract.
        let firstTick = wait { clock.refreshCount > 1 && clock.now == instant }
        check(firstTick, "real timer fires and reads current date (refreshes: \(clock.refreshCount))")
        let previousCount = clock.refreshCount
        instant = instant.addingTimeInterval(60)
        let nextTick = wait { clock.refreshCount > previousCount && clock.now == instant }
        check(nextTick, "timer keeps repeating and reads the new date (refreshes: \(clock.refreshCount))")
        for reason in ["close", "minimize", "hide", "resign active"] {
            clock.setRunning(false)
            let count = clock.refreshCount
            run(for: 0.09)
            check(!clock.isRunning && clock.refreshCount == count, "stopped timer remains silent: \(reason)")
            instant = instant.addingTimeInterval(86400)
            clock.setRunning(true)
            check(clock.refreshCount == count + 1 && clock.now == instant, "resume refreshes once immediately: \(reason)")
            clock.start()
            check(clock.refreshCount == count + 1, "repeat resume is idempotent: \(reason)")
        }
        clock.stop()
        weak var released: PreviewClock?
        do {
            let temporary = PreviewClock(interval: 0.01)
            temporary.start()
            released = temporary
        }
        check(released == nil, "timer does not retain its owner")
        run(for: 0.03)
        print("PASS: \(checks) preview clock checks (real main-runloop timer, accelerated interval)")
    }
}
