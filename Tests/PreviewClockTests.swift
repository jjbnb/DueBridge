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
        var instant = Date(timeIntervalSince1970: 1_000)
        let clock = PreviewClock(interval: 0.04, currentDate: { instant })
        check(!clock.isRunning && clock.refreshCount == 0, "creation does not schedule")
        clock.stop(); clock.stop()
        clock.start()
        check(clock.isRunning && clock.refreshCount == 1, "start immediately refreshes")
        clock.start(); clock.setRunning(true)
        check(clock.refreshCount == 1, "duplicate visibility/activation does not refresh or add timers")
        instant = instant.addingTimeInterval(60)
        run(for: 0.13)
        check((3...4).contains(clock.refreshCount) && clock.now == instant, "one real timer fires and reads current date")
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
