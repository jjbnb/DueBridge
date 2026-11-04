// Synthetic fixtures only; public school domains test exact request policies.
import Foundation

@main struct NativeReminderWriterTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        checks += 1
        do { if try !condition() { print("FAIL: \(message)"); exit(1) } }
        catch { print("FAIL: \(message): \(error)"); exit(1) }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); check(false, message) } catch { check(true, message) }
    }
    static let scope = try! SourceScope(platform: .mo, host: "mo.zju.edu.cn", connectionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    static let now = ISO8601DateFormatter().date(from: "2026-11-03T04:00:00Z")!
    static func task(_ id: String, deadline: Deadline?) throws -> NativeDeadlineTask {
        try NativeDeadlineTask(identity: NativeTaskIdentity(scope: scope, courseID: "c1", kind: .homework, taskID: id), courseName: "课程", title: "作业", deadline: deadline)
    }
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = ISO8601DateFormatter().date(from: "2026-11-05T15:59:00Z")!
        let deadline = Deadline(date: date, components: calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date), isAllDay: false, timeZone: calendar.timeZone)
        let due = NativeReminderWritePolicy.dueComponents(for: deadline)
        check(due.timeZone == calendar.timeZone && due.calendar?.timeZone == calendar.timeZone && due.calendar?.identifier == .gregorian, "EventKit due components explicitly carry Gregorian calendar and deadline timezone")
        check(due.year == 2026 && due.month == 11 && due.day == 5 && due.hour == 23 && due.minute == 59, "due mapping preserves source civil time")
        let day = calendar.startOfDay(for: date)
        let allDay = Deadline(date: day, components: calendar.dateComponents([.year, .month, .day], from: day), isAllDay: true, timeZone: calendar.timeZone)
        let dayDue = NativeReminderWritePolicy.dueComponents(for: allDay)
        check(dayDue.hour == nil && dayDue.minute == nil && dayDue.day == 5 && dayDue.timeZone == calendar.timeZone, "all-day mapping stays date-only in explicit source zone")
        var zeroClock = calendar.dateComponents([.year, .month, .day], from: day)
        zeroClock.hour = 0; zeroClock.minute = 0; zeroClock.second = 0; zeroClock.nanosecond = 0
        let zeroAllDay = Deadline(date: day, components: zeroClock, isAllDay: true, timeZone: calendar.timeZone)
        let validatedAllDay = try task("all-day-zero-clock", deadline: zeroAllDay)
        let zeroDue = NativeReminderWritePolicy.dueComponents(for: validatedAllDay.deadline!)
        check(zeroDue.hour == nil && zeroDue.minute == nil && zeroDue.second == nil && zeroDue.nanosecond == nil, "validated all-day zero clock components are omitted for EventKit")
        check(zeroDue.year == 2026 && zeroDue.month == 11 && zeroDue.day == 5 && zeroDue.timeZone == calendar.timeZone && zeroDue.calendar?.timeZone == calendar.timeZone && zeroDue.calendar?.identifier == .gregorian, "all-day zero clock mapping preserves civil date and explicit Gregorian timezone")
        let previous = Date(timeIntervalSince1970: 100)
        check(NativeReminderWritePolicy.shouldRemoveAlarm(absoluteDate: previous, hasLocation: false, previousToolAlarmDate: previous), "only recorded tool alarm can be removed")
        check(!NativeReminderWritePolicy.shouldRemoveAlarm(absoluteDate: previous, hasLocation: true, previousToolAlarmDate: previous), "same-time location alarm survives")
        check(!NativeReminderWritePolicy.shouldRemoveAlarm(absoluteDate: date, hasLocation: false, previousToolAlarmDate: previous), "unrelated personal absolute alarm survives")
        check(!NativeReminderWritePolicy.shouldRemoveAlarm(absoluteDate: nil, hasLocation: false, previousToolAlarmDate: nil), "relative alarm is never removed")
        let base = try task("existing", deadline: deadline)
        let notes = try NativeTaskNotes.replacing(in: "personal\r\ne\u{301}", scope: scope, hash: base.identity.stableHash, alarmDate: previous)
        let original = try NativeReminderSnapshot(calendarItemID: "r1", isCompleted: false, notes: notes, dueDate: date)
        let changed = try NativeReminderSnapshot(calendarItemID: "r1", isCompleted: true, notes: notes + "\nlatest personal", dueDate: day)
        try NativeReminderWritePolicy.validateCurrent(original: original, current: changed)
        let history = NativeTaskHistory(scope: scope, knownHashes: [base.identity.stableHash], hasImported: true)
        let replanned = try NativeTaskPlanner.plan(scope: scope, candidates: [base], existing: [changed], history: history, now: now, localTimeZone: calendar.timeZone)
        check(replanned.operations[0].notes.hasSuffix("latest personal") && replanned.operations[0].nextToolAlarmDate == nil && replanned.operations[0].title == "【课程】作业", "replanning current values preserves user completion and newest personal notes")
        rejects("removed reminder fails final validation") { try NativeReminderWritePolicy.validateCurrent(original: original, current: nil) }
        let otherID = try NativeReminderSnapshot(calendarItemID: "r2", isCompleted: false, notes: notes, dueDate: date)
        rejects("changed calendar item ID fails final validation") { try NativeReminderWritePolicy.validateCurrent(original: original, current: otherID) }
        let stripped = try NativeReminderSnapshot(calendarItemID: "r1", isCompleted: false, notes: "personal only", dueDate: date)
        rejects("stripped management marker fails final validation") { try NativeReminderWritePolicy.validateCurrent(original: original, current: stripped) }
        let other = try SourceScope(platform: .learningInZJU, host: "courses.zju.edu.cn", connectionID: scope.connectionID)
        let foreign = try NativeReminderSnapshot(calendarItemID: "foreign", isCompleted: false, notes: NativeTaskNotes.replacing(in: "", scope: other, hash: String(repeating: "b", count: 64), alarmDate: nil), dueDate: nil)
        let recognizedOnly = try task("disappeared", deadline: nil)
        let recognized = try NativeReminderSnapshot(calendarItemID: "retained", isCompleted: false, notes: NativeTaskNotes.replacing(in: "", scope: scope, hash: recognizedOnly.identity.stableHash, alarmDate: nil), dueDate: nil)
        let new = try task("new", deadline: deadline)
        let nilTask = try task("undated", deadline: nil)
        let pastDate = ISO8601DateFormatter().date(from: "2026-11-01T15:59:00Z")!
        let pastDeadline = Deadline(date: pastDate, components: calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: pastDate), isAllDay: false, timeZone: calendar.timeZone)
        let past = try task("past", deadline: pastDeadline)
        let current = [changed, recognized, foreign]
        let plan = try NativeTaskPlanner.plan(scope: scope, candidates: [base, new, nilTask, past], existing: current, history: history, now: now, localTimeZone: calendar.timeZone)
        let hashes = try NativeReminderWritePolicy.knownHashes(scope: scope, history: history, recognized: current, saved: plan.operations)
        check(hashes == [base.identity.stableHash, recognizedOnly.identity.stableHash, new.identity.stableHash], "checkpoint unions history, same-scope recognized and actual saved operations only")
        check(!hashes.contains(nilTask.identity.stableHash) && !hashes.contains(past.identity.stableHash), "skipped undated and past candidates do not become imported hashes")
        let empty = NativeTaskHistory(scope: scope, knownHashes: [], hasImported: true)
        check(try NativeReminderWritePolicy.knownHashes(scope: scope, history: empty, recognized: [], saved: []).isEmpty, "validated empty import invents no hashes")
        rejects("foreign history cannot enter checkpoint") { _ = try NativeReminderWritePolicy.knownHashes(scope: other, history: history, recognized: current, saved: []) }
        print("NativeReminderWriterTests: \(checks) checks passed (pure policies only; no EventKit store created)")
    }
}
