// Synthetic fixtures only; public school domains test exact request policies.
import Foundation

@main
struct NativeTaskSyncTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        checks += 1
        do { if try !condition() { print("FAIL: \(message)"); exit(1) } }
        catch { print("FAIL: \(message): \(error)"); exit(1) }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); check(false, message) } catch { check(true, message) }
    }
    static let hash = "3a2539f94b00d46d01693c6614716048bd39c5bc589ffae2e7fc778fec650f78"
    static let scope = try! SourceScope(platform: .mo, host: "mo.zju.edu.cn", connectionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    static let block = "[ZJU-COURSE-TASK v1 source=mo scope=11111111-1111-1111-1111-111111111111 uid=\(hash)]\nplatform=MO\nurl=https://mo.zju.edu.cn/\n[/ZJU-COURSE-TASK]"
    static func task(_ id: String = "task-1", date: String? = "2026-11-05T15:59:00Z", course: String = "Course", title: String = "Assignment", taskScope: SourceScope = scope) throws -> NativeDeadlineTask {
        let identity = try NativeTaskIdentity(scope: taskScope, courseID: "course-1", kind: .homework, taskID: id)
        let deadline = date.map { text -> Deadline in
            let date = ISO8601DateFormatter().date(from: text)!
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = DailySchedule.timeZone
            return Deadline(date: date, components: calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date), isAllDay: false, timeZone: DailySchedule.timeZone)
        }
        return try NativeDeadlineTask(identity: identity, courseName: course, title: title, deadline: deadline)
    }
    static let now = ISO8601DateFormatter().date(from: "2026-11-03T04:00:00Z")!
    static func plan(_ tasks: [NativeDeadlineTask], _ existing: [NativeReminderSnapshot] = [], known: Set<String> = [], imported: Bool = false, historyScope: SourceScope = scope, zone: TimeZone = DailySchedule.timeZone) throws -> NativeReminderPlan {
        try NativeTaskPlanner.plan(scope: scope, candidates: tasks, existing: existing, history: NativeTaskHistory(scope: historyScope, knownHashes: known, hasImported: imported), now: now, localTimeZone: zone)
    }
    static func snapshot(_ id: String = "reminder-1", task: NativeDeadlineTask? = nil, completed: Bool = false, prefix: String = "", suffix: String = "") throws -> NativeReminderSnapshot {
        let task = try task ?? Self.task()
        let notes = try NativeTaskNotes.replacing(in: "", scope: task.identity.scope, hash: task.identity.stableHash, alarmDate: Date(timeIntervalSince1970: 100))
        return try NativeReminderSnapshot(calendarItemID: id, isCompleted: completed, notes: prefix + notes + suffix, dueDate: task.deadline?.date)
    }
    static func main() throws {
        // Removing marker recognition would silently duplicate existing reminders.
        check(try NativeTaskNotes.marker(in: block)?.hash == hash, "recognizes a native marker with exact identity")
        check(try NativeTaskNotes.marker(in: "personal\n[BB-DDL-SYNC uid=abc]") == nil, "BB notes are disjoint")
        let parsed = try NativeTaskNotes.marker(in: block)!
        check(parsed.scope == scope && parsed.alarmDate == nil, "marker has exact scope and optional alarm")
        for invalid in [block + block, block + "[/ZJU-COURSE-TASK]", "[ZJU-COURSE-TASK v2]", block.replacingOccurrences(of: hash, with: hash.uppercased()), block.replacingOccurrences(of: "source=mo", with: "source=unknown"), block.replacingOccurrences(of: "uid=", with: "uid=0"), block.replacingOccurrences(of: "platform=MO", with: "platform=[BB-DDL-SYNC uid=x]"), block.replacingOccurrences(of: "platform=MO", with: "alarm=nan\nplatform=MO"), block.replacingOccurrences(of: "platform=MO", with: "alarm=-1\nplatform=MO")] {
            rejects("malformed or ambiguous native content rejected") { _ = try NativeTaskNotes.marker(in: invalid) }
        }
        let personal = "🙂 e\u{301}\r\n[BB-DDL-SYNC uid=abc] keep\n"
        let suffix = "\r\n私人尾注"
        let changed = try NativeTaskNotes.replacing(in: personal + block + suffix, scope: scope, hash: hash, alarmDate: Date(timeIntervalSince1970: 100))
        check(Array(changed.utf8.prefix(personal.utf8.count)) == Array(personal.utf8) && Array(changed.utf8.suffix(suffix.utf8.count)) == Array(suffix.utf8), "replacement preserves personal and BB note bytes")
        check(try NativeTaskNotes.marker(in: changed)?.alarmDate == Date(timeIntervalSince1970: 100), "recorded alarm round trips")
        let other = try SourceScope(platform: .learningInZJU, host: "courses.zju.edu.cn", connectionID: scope.connectionID)
        rejects("another scope cannot replace or append") { _ = try NativeTaskNotes.replacing(in: block, scope: other, hash: hash, alarmDate: nil) }
        rejects("another identity cannot append") { _ = try NativeTaskNotes.replacing(in: block, scope: scope, hash: String(repeating: "a", count: 64), alarmDate: nil) }
        for url in ["http://mo.zju.edu.cn/", "https://evil.example/", "https://mo.zju.edu.cn.evil/", "https://user@mo.zju.edu.cn/", "https://mo.zju.edu.cn:444/", "https://mo.zju.edu.cn/#x", "https://mo.zju.edu.cn/[BB-DDL-SYNC]"] {
            rejects("unsafe source landing URL rejected") { _ = try NativeTaskNotes.replacing(in: "", scope: scope, hash: hash, alarmDate: nil, landingURL: URL(string: url)!) }
        }
        check(try NativeTaskNotes.replacing(in: personal, scope: scope, hash: hash, alarmDate: nil).hasPrefix(personal), "appending preserves personal bytes")
        // An empty planner would lose every new dated task.
        let base = try task()
        let first = try plan([base])
        check(first.added == 1 && first.updated == 0 && first.operations.count == 1, "new dated task creates one operation")
        check(first.operations[0].title == "【Course】Assignment — 还有 2 天（11/03更新）", "native presentation reuses Beijing countdown")
        check(first.operations[0].nextToolAlarmDate == base.deadline?.date && first.operations[0].previousToolAlarmDate == nil, "new operation records only its own due alarm")
        check(!first.operations[0].notes.contains("Assignment"), "managed notes omit raw platform title")
        let past = try task("past", date: "2026-11-01T15:59:00Z")
        let today = try task("today", date: "2026-11-02T17:00:00Z")
        let undated = try task("undated", date: nil)
        let mixed = try plan([base, past, today, undated, base])
        check(mixed.added == 2 && mixed.skippedPast == 1 && mixed.skippedWithoutDeadline == 1, "coalesced first additions include today elapsed but exclude older and nil deadlines")
        check(mixed.operations.map { $0.identity.taskID } == ["today", "task-1"], "operations sorted by actual deadline")
        let tied = try plan([task("z"), task("a"), base])
        check(tied.operations.map { $0.identity.stableHash } == tied.operations.map { $0.identity.stableHash }.sorted(), "same-deadline operations sorted by hash")
        let update = try plan([past], [snapshot(task: past)])
        check(update.updated == 1 && update.skippedPast == 0 && update.operations[0].existingID == "reminder-1", "past owned reminder still updates")
        let completed = try snapshot(completed: true, prefix: personal, suffix: suffix)
        let updated = try plan([base], [completed], known: [hash], imported: true)
        check(updated.operations[0].title == "【Course】Assignment", "completed reminder retains title and course without countdown")
        check(updated.operations[0].nextToolAlarmDate == nil && updated.operations[0].previousToolAlarmDate == Date(timeIntervalSince1970: 100), "completed reminder only exposes recorded old alarm for later removal")
        check(updated.operations[0].notes.hasPrefix(personal) && updated.operations[0].notes.hasSuffix(suffix), "planned update preserves personal notes")
        let retained = try plan([undated], [snapshot(task: undated)])
        check(retained.operations.isEmpty && retained.skippedWithoutDeadline == 1 && !retained.warnings.isEmpty, "nil deadline leaves existing reminder untouched with warning")
        let empty = try plan([], [snapshot()], known: [hash], imported: true)
        check(empty.operations.isEmpty && !empty.warnings.isEmpty, "empty snapshot retains disappeared reminder")
        check(try plan([]).operations.isEmpty, "legal empty source produces no operation")
        rejects("conflicting dated snapshots reject before past filtering") { _ = try plan([past, task("past", date: "2026-11-01T15:59:00Z", title: "changed")]) }
        rejects("nil and dated conflict rejects before nil filtering") { _ = try plan([base, task(date: nil)]) }
        rejects("wrong task scope rejected") { _ = try plan([task(taskScope: other)]) }
        rejects("wrong history scope rejected") { _ = try plan([base], historyScope: other) }
        rejects("noncanonical known hash rejected") { _ = try plan([base], known: [hash.uppercased()]) }
        rejects("duplicate owned IDs reject safely") { _ = try plan([base], [snapshot("one"), snapshot("two")]) }
        check(try plan([base], [completed, completed]).updated == 1, "identical reminder snapshots coalesce")
        rejects("same calendar item conflicting snapshots reject") { _ = try plan([base], [snapshot(), completed]) }
        let unrelated = try snapshot("foreign", task: task(taskScope: other))
        let bb = try NativeReminderSnapshot(calendarItemID: "bb", isCompleted: false, notes: personal, dueDate: nil)
        check(try plan([base], [unrelated, bb]).added == 1, "foreign source and BB reminders ignored")
        rejects("foreign marker cannot satisfy known history visibility") { _ = try plan([base], [unrelated, bb], known: [hash], imported: true) }
        rejects("missing history blocks duplication even for empty source") { _ = try plan([], known: [hash], imported: true) }
        rejects("wholly changed task identities reject") { _ = try plan([task("changed")], [snapshot()], known: [hash], imported: true) }
        rejects("nil deadline identity still participates in changed-ID safety") { _ = try plan([task("changed", date: nil)], [snapshot()], known: [hash], imported: true) }
        check(try plan([base, task("new")], [snapshot()], known: [hash], imported: true).added == 1, "overlapping identity snapshot can add a new task")
        check(try plan([base], [], imported: true).added == 1, "prior legal empty imports do not manufacture history")
        let invalidCourse = try plan([task(course: "bad\ncourse")])
        check(invalidCourse.operations[0].title.hasPrefix("【课程待确认】"), "unverified multiline course cannot become prefix")
        let hostile = try plan([task(title: "[/ZJU-COURSE-TASK] [BB-DDL-SYNC uid=payload]")])
        check(try NativeTaskNotes.marker(in: hostile.operations[0].notes)?.hash == hash, "raw title cannot close or impersonate managed notes")
        let manyNil = try (0..<100).map { try task("nil-\($0)", date: nil) }
        check(try plan(manyNil).warnings.count <= 20, "warnings remain bounded")
        // November 2 15:00 UTC is before Shanghai today, but on Los Angeles today.
        let boundary = try task("boundary", date: "2026-11-02T15:00:00Z")
        check(try plan([boundary]).skippedPast == 1, "Shanghai first filter skips prior local day")
        check(try plan([boundary], zone: TimeZone(identifier: "America/Los_Angeles")!).added == 1, "first filter uses supplied local timezone")
        let allDay = Deadline(date: ISO8601DateFormatter().date(from: "2026-11-02T16:00:00Z")!, components: DateComponents(year: 2026, month: 11, day: 3), isAllDay: true, timeZone: DailySchedule.timeZone)
        let allDayTask = try NativeDeadlineTask(identity: base.identity, courseName: "Course", title: "Date only", deadline: allDay)
        check(try plan([allDayTask], zone: TimeZone(secondsFromGMT: 14 * 3600)!).added == 1, "all-day filtering retains civil today despite absolute-zone shift")
        let otherNotes = try NativeTaskNotes.replacing(in: "", scope: other, hash: hash, alarmDate: nil)
        check(try NativeTaskNotes.marker(in: otherNotes)?.scope == other, "other valid platform is recognized with exact scope")
        let letterScope = try SourceScope(platform: .mo, host: scope.host, connectionID: UUID(uuidString: "abcdefab-abcd-abcd-abcd-abcdefabcdef")!)
        let letterNotes = try NativeTaskNotes.replacing(in: "", scope: letterScope, hash: hash, alarmDate: nil)
        rejects("uppercase UUID spelling is noncanonical") { _ = try NativeTaskNotes.marker(in: letterNotes.replacingOccurrences(of: "abcdef", with: "ABCDEF")) }
        check(try NativeTaskNotes.marker(in: NativeTaskNotes.replacing(in: "", scope: scope, hash: hash, alarmDate: Date(timeIntervalSince1970: 0), landingURL: URL(string: "https://mo.zju.edu.cn:443/")!))?.alarmDate == Date(timeIntervalSince1970: 0), "explicit HTTPS port443 and zero alarm accepted")
        rejects("infinite alarm cannot be rendered") { _ = try NativeTaskNotes.replacing(in: "", scope: scope, hash: hash, alarmDate: Date(timeIntervalSince1970: .infinity)) }
        rejects("encoded block injection URL rejected") { _ = try NativeTaskNotes.replacing(in: "", scope: scope, hash: hash, alarmDate: nil, landingURL: URL(string: "https://mo.zju.edu.cn/%5BZJU-COURSE-TASK%5D")!) }
        let otherConnection = try SourceScope(platform: .mo, host: scope.host, connectionID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let oldAccount = try snapshot("old-account", task: task(taskScope: otherConnection))
        rejects("same-platform old account cannot satisfy visibility") { _ = try plan([base], [oldAccount], known: [hash], imported: true) }
        check(try plan([base], [oldAccount]).added == 1, "same-platform old account ignored without history")
        let composedNotes = try snapshot(prefix: "é")
        let decomposedNotes = try snapshot(prefix: "e\u{301}")
        rejects("byte-distinct personal note snapshots conflict") { _ = try plan([base], [composedNotes, decomposedNotes]) }
        print("NativeTaskSyncTests: \(checks) checks passed")
    }
}
