// Synthetic fixtures only; public school domains test exact request policies.
import Foundation

@main
struct SourceTaskTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        checks += 1
        do { if try !condition() { print("FAIL: \(message)"); exit(1) } }
        catch { print("FAIL: \(message): \(error)"); exit(1) }
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); check(false, message) } catch { check(true, message) }
    }
    static let connection = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static func identity(course: String = "course-1", task: String = "task-1", kind: NativeTaskKind = .homework,
                         platform: NativePlatform = .mo, connectionID: UUID = connection) throws -> NativeTaskIdentity {
        let scope = try SourceScope(platform: platform, host: platform == .mo ? "mo.zju.edu.cn" : "courses.zju.edu.cn", connectionID: connectionID)
        return try NativeTaskIdentity(scope: scope, courseID: course, kind: kind, taskID: task)
    }
    // Explicit civil/absolute pair: November 5 23:59 Shanghai = 15:59 UTC.
    static func timed() -> Deadline {
        Deadline(date: ISO8601DateFormatter().date(from: "2026-11-05T15:59:00Z")!,
                 components: DateComponents(year: 2026, month: 11, day: 5, hour: 23, minute: 59, second: 0),
                 isAllDay: false, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    }
    static func task(_ id: NativeTaskIdentity, title: String = "Assignment", course: String = "Course", deadline: Deadline? = timed()) throws -> NativeDeadlineTask {
        try NativeDeadlineTask(identity: id, courseName: course, title: title, deadline: deadline)
    }
    static func main() throws {
        // Catches identity encoding changes, platform collisions and snapshot-derived IDs.
        let base = try identity()
        check(base.stableHash == "3a2539f94b00d46d01693c6614716048bd39c5bc589ffae2e7fc778fec650f78", "versioned length-prefixed identity hash matches independent fixture")
        let original = try task(base)
        var later = timed(); later.date.addTimeInterval(86400); later.components.day = 6
        let changed = try task(base, title: "Renamed", course: "Renamed course", deadline: later)
        check(original.identity.stableHash == changed.identity.stableHash, "title, course name and deadline updates preserve task identity")
        let variants = try [identity(platform: .learningInZJU), identity(connectionID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!), identity(course: "course-2"), identity(task: "task-2"), identity(kind: .quiz), identity(kind: .exam), identity(kind: .practice), identity(course: "Course-1"), identity(course: " course-1 ")]
        check(Set(([base] + variants).map(\.stableHash)).count == 10, "platform/verified host, connection, course, task, kind, case and whitespace separate identities")
        check(try identity(course: "a|homework", task: "b").stableHash != identity(course: "a", task: "homework|b").stableHash, "delimiters cannot shift field boundaries")
        let composed = try identity(course: "é"), decomposed = try identity(course: "e\u{301}")
        check(composed.stableHash != decomposed.stableHash && composed != decomposed, "Unicode bytes are preserved consistently in hashing and equality")
        check(try identity(course: "课程😀").stableHash != identity(course: "课程", task: "😀task-1").stableHash, "UTF-8 boundaries prevent Unicode field ambiguity")
        for host in ["courses.zju.edu.cn", "evil.example", "https://mo.zju.edu.cn", "mo.zju.edu.cn:443", "mo.zju.edu.cn."] {
            rejects("wrong or URL-shaped MO host rejected: \(host)") { _ = try SourceScope(platform: .mo, host: host, connectionID: connection) }
        }
        rejects("MO host cannot bind learningInZJU") { _ = try SourceScope(platform: .learningInZJU, host: "mo.zju.edu.cn", connectionID: connection) }
        for invalid in ["", "\n", "a\u{0}b", "a\u{7f}b", String(repeating: "x", count: 1025), String(repeating: "😀", count: 257)] {
            rejects("invalid course identifier rejected") { _ = try identity(course: invalid) }
            rejects("invalid task identifier rejected") { _ = try identity(task: invalid) }
        }
        check(try identity(course: String(repeating: "x", count: 1024)).courseID.utf8.count == 1024, "identifier byte bound accepts its boundary")

        // Catches missing civil/absolute validation and accidental past-date policy here.
        var allDay = timed(); allDay.isAllDay = true
        allDay.date = ISO8601DateFormatter().date(from: "2026-11-04T16:00:00Z")!
        allDay.components = DateComponents(year: 2026, month: 11, day: 5)
        check(try task(base, deadline: allDay).deadline == allDay, "all-day civil date stays in its effective zone")
        var aware = timed(); var cal = Calendar(identifier: .gregorian); cal.timeZone = aware.timeZone
        aware.components.calendar = cal; aware.components.timeZone = aware.timeZone
        check(try task(base, deadline: aware).deadline == aware, "timezone-aware calendar components accepted")
        check(original.deadline == timed(), "floating components retain explicit effective timezone")
        var past = timed(); past.date = Date(timeIntervalSince1970: 0); past.timeZone = TimeZone(secondsFromGMT: 0)!
        past.components = DateComponents(year: 1970, month: 1, day: 1, hour: 0, minute: 0, second: 0)
        check(try NativeTaskSelection.select([task(base, deadline: past)]).tasks.count == 1, "past deadlines and epoch boundary remain eligible in pure selection")
        for value in [Double.nan, Double.infinity, -Double.infinity, -1] {
            var invalid = timed(); invalid.date = Date(timeIntervalSince1970: value)
            rejects("nonfinite/pre-epoch absolute date rejected") { _ = try task(base, deadline: invalid) }
        }
        var badDay = timed(); badDay.components.day = 31
        var missingDay = timed(); missingDay.components.day = nil
        var badHour = timed(); badHour.components.hour = 22
        var missingHour = timed(); missingHour.components.hour = nil
        var badZone = timed(); badZone.components.timeZone = TimeZone(secondsFromGMT: 0)
        // Foundation overlays an explicit component timezone onto its calendar getter.
        var badCalendar = aware; badCalendar.components.timeZone = nil
        badCalendar.components.calendar?.timeZone = TimeZone(secondsFromGMT: 0)!
        var badAllDay = allDay; badAllDay.date.addTimeInterval(60)
        var badAllDayTime = allDay; badAllDayTime.components.hour = 5
        var badWeekday = timed(); badWeekday.components.weekday = 1 // November 5, 2026 is Thursday.
        for (label, invalid) in [("day", badDay), ("missing day", missingDay), ("hour", badHour), ("missing hour", missingHour), ("zone", badZone), ("calendar zone", badCalendar), ("all-day instant", badAllDay), ("all-day time", badAllDayTime), ("weekday", badWeekday)] {
            rejects("incoherent deadline rejected: \(label)") { _ = try task(base, deadline: invalid) }
        }
        // Autumn overlap: both 01:30 instants are valid, without selecting an arbitrary occurrence.
        for instant in ["2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z"] {
            let overlap = Deadline(date: ISO8601DateFormatter().date(from: instant)!, components: DateComponents(year: 2026, month: 11, day: 1, hour: 1, minute: 30, second: 0), isAllDay: false, timeZone: TimeZone(identifier: "America/New_York")!)
            check(try task(base, deadline: overlap).deadline?.date == overlap.date, "DST overlap instant is preserved")
        }

        // Catches dropping missing deadlines before conflict detection, arbitrary duplicate winners,
        // non-total sorting and counting duplicate snapshots as separate missing tasks.
        let absent = try task(identity(task: "without-deadline"), deadline: nil)
        let empty = try NativeTaskSelection.select([])
        check(empty.tasks.isEmpty && empty.skippedWithoutDeadline == 0, "empty pure input valid")
        let skipped = try NativeTaskSelection.select([absent, absent])
        check(skipped.tasks.isEmpty && skipped.skippedWithoutDeadline == 1, "identical missing-deadline snapshots coalesce and skip once")
        let tie = try task(identity(task: "tie"))
        let future = try task(identity(task: "future"), deadline: later)
        let selected = try NativeTaskSelection.select([future, tie, absent, original, original])
        let expectedTies = [original, tie].sorted { $0.identity.stableHash < $1.identity.stableHash }
        check(selected.tasks.map(\.identity) == (expectedTies + [future]).map(\.identity) && selected.skippedWithoutDeadline == 1, "date ordering, stable hash tie break and exact duplicate coalescing")
        check(try NativeTaskSelection.select([original, absent, tie, future]).tasks == selected.tasks, "input reordering preserves total order")
        let conflicts = try [task(base, title: "Different"), task(base, course: "Different course"), task(base, deadline: later), task(base, deadline: allDay), task(base, deadline: nil)]
        for conflict in conflicts {
            rejects("same-identity conflicting snapshots reject in forward order") { _ = try NativeTaskSelection.select([original, conflict]) }
            rejects("same-identity conflicting snapshots reject in reverse order") { _ = try NativeTaskSelection.select([conflict, original]) }
        }
        check(try NativeTaskSelection.select([task(composed), task(decomposed)]).tasks.count == 2, "canonically equivalent Unicode identifiers stay distinct during selection")
        print("PASS: \(checks) source task checks")
    }
}
