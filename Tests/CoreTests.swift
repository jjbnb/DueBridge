// Synthetic fixtures only; public school domains test exact request policies.
import Foundation

@main
struct CoreTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError("FAIL: \(message)") }
    }
    static func calendar(_ body: String) -> String { "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n\(body)\r\nEND:VCALENDAR\r\n" }
    static func event(_ fields: String) -> String { "BEGIN:VEVENT\r\n\(fields)\r\nEND:VEVENT" }
    static func parse(_ fields: String) throws -> Feed { try ICSParser.parse(calendar(event(fields)), localTimeZone: TimeZone(identifier: "Asia/Shanghai")!) }
    static func rejects(_ value: String, _ label: String) {
        do { _ = try ICSParser.parse(value); check(false, label) } catch { check(true, label) }
    }
    static func countdownChecks() throws {
        func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        func timed(_ value: String, title: String = "示例任务甲") throws -> FeedEvent {
            try parse("UID:countdown\r\nDTSTART:\(value)\r\nSUMMARY:\(title)").events[0]
        }
        func title(_ event: FeedEvent, _ now: String, completed: Bool = false) -> String {
            CountdownPresentation.reminderTitle(for: event, isCompleted: completed, now: instant(now))
        }
        let deadline = try timed("20261024T160000Z") // October 25 00:00 in Shanghai.
        check(title(deadline, "2026-10-24T15:59:59Z") == "示例任务甲 — 明天到期（10/24更新）", "Shanghai tomorrow and update stamp before midnight")
        check(title(deadline, "2026-10-24T16:00:00Z") == "示例任务甲 — 今天到期（10/25更新）", "exact deadline is today, not yet overdue")
        check(title(deadline, "2026-10-24T16:00:01Z") == "示例任务甲 — 已逾期（10/25更新）", "timed deadline becomes overdue immediately after its instant")
        check(title(deadline, "2026-10-23T16:00:00Z") == "示例任务甲 — 明天到期（10/24更新）", "tomorrow counts calendar days despite 24-hour boundary")
        check(title(deadline, "2026-10-22T16:00:00Z") == "示例任务甲 — 还有 2 天（10/23更新）", "later deadline shows calendar day distance")
        check(title(deadline, "2026-10-25T16:00:00Z") == "示例任务甲 — 已逾期 1 天（10/26更新）", "overdue advances at next Shanghai midnight")
        check(title(deadline, "2026-10-27T10:00:00Z") == "示例任务甲 — 已逾期 2 天（10/27更新）", "earlier deadline counts overdue calendar days")
        let futureToday = try timed("20261024T155959Z")
        check(title(futureToday, "2026-10-24T09:00:00Z") == "示例任务甲 — 今天到期（10/24更新）", "future timed deadline today")
        let elapsedToday = try timed("20261024T010000Z")
        check(title(elapsedToday, "2026-10-24T09:00:00Z") == "示例任务甲 — 已逾期（10/24更新）", "past timed deadline today")
        let newYear = try timed("20270101T000000Z")
        check(title(newYear, "2026-12-31T15:59:59Z") == "示例任务甲 — 明天到期（12/31更新）", "calendar day distance across year boundary")
        let leapDay = try timed("20280228T160000Z")
        check(title(leapDay, "2028-02-29T16:00:00Z") == "示例任务甲 — 已逾期 1 天（03/01更新）", "leap-day overdue uses calendar days")
        let originalZone = NSTimeZone.default
        defer { NSTimeZone.default = originalZone }
        for zoneName in ["Pacific/Kiritimati", "Pacific/Pago_Pago", "America/Los_Angeles"] {
            let zone = TimeZone(identifier: zoneName)!
            NSTimeZone.default = zone
            let allDay = try ICSParser.parse(calendar(event("UID:countdown-all-day\r\nDTSTART;VALUE=DATE:20261025\r\nSUMMARY:全天")), localTimeZone: zone).events[0]
            check(title(deadline, "2026-10-24T15:59:59Z") == "示例任务甲 — 明天到期（10/24更新）", "timed title independent of host zone \(zoneName)")
            check(title(allDay, "2026-10-24T15:59:59Z") == "全天 — 明天到期（10/24更新）", "all-day source YMD retained across zone \(zoneName)")
            check(title(allDay, "2026-10-25T15:59:59Z") == "全天 — 今天到期（10/25更新）", "all-day lasts through end of its Shanghai date \(zoneName)")
            check(title(allDay, "2026-10-25T16:00:00Z") == "全天 — 已逾期 1 天（10/26更新）", "all-day becomes overdue only on following date \(zoneName)")
        }
        NSTimeZone.default = originalZone
        check(title(deadline, "2026-10-24T09:00:00Z", completed: true) == "示例任务甲", "completed event returns raw source title")
        var cancelled = deadline; cancelled.cancelled = true
        check(title(cancelled, "2026-10-24T09:00:00Z") == "示例任务甲", "cancelled event returns raw source title")
        var missing = deadline; missing.deadline = nil
        check(title(missing, "2026-10-24T09:00:00Z") == "示例任务甲", "missing deadline returns raw source title")
        let suffixSource = try timed("20261024T160000Z", title: "课程 — 今天到期（10/01更新）")
        let sourceExpected = "课程 — 今天到期（10/01更新） — 明天到期（10/24更新）"
        check(title(suffixSource, "2026-10-24T09:00:00Z") == sourceExpected, "source title containing countdown-like suffix is never stripped")
        check(title(suffixSource, "2026-10-24T09:00:00Z") == sourceExpected && suffixSource.title == "课程 — 今天到期（10/01更新）", "repeated construction does not accumulate or mutate source")
        var stable = deadline
        stable.uid = "20261024T091430Z-_blackboard.platform.gradebook2.GradableItem-_100001_1@synthetic-bb9.example"
        let marker = ManagedNotes.marker(uid: stable.uid)
        let notes = ManagedNotes.replacing(in: "个人备注", event: stable, alarmDate: stable.deadline!.date)
        let stored = ManagedReminder(id: "countdown-existing", marker: marker, isCompleted: false, notes: notes, identityVersion: 2, title: title(stable, "2026-10-24T09:00:00Z"), dueDate: stable.deadline!.date)
        let prepared = try LegacyAdoption.prepare(events: [stable], existing: [stored])
        let planned = SyncPlanner.plan(events: [stable], existing: prepared, now: instant("2026-10-24T09:00:00Z"))
        check(planned.operations.count == 1 && planned.operations[0].existingID == stored.id, "v2 displayed countdown title replans same reminder without insert")
        check(planned.operations[0].event.title == "示例任务甲" && prepared[0].marker == marker && prepared[0].notes == notes, "presentation preserves raw event, v2 marker and notes")
        var legacy = stored; legacy.identityVersion = 1
        do { _ = try LegacyAdoption.prepare(events: [stable], existing: [legacy]); check(false, "legacy countdown-like title must not receive relaxed adoption") }
        catch { check(true, "legacy countdown-like title must not receive relaxed adoption") }
    }
    static func countdownDetailChecks() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-24T09:00:00Z")!
        let source = try parse("UID:detail\r\nDTSTART:20261024T090000Z\r\nSUMMARY:示例任务甲").events[0]
        func detail(after seconds: TimeInterval) -> String? {
            var event = source
            event.deadline!.date = now.addingTimeInterval(seconds)
            return CountdownPresentation.detail(for: event, now: now)
        }
        for (seconds, units) in [(183600.0, "2 天 3 小时"), (86340.0, "23 小时 59 分钟"), (2700.0, "45 分钟")] {
            check(detail(after: seconds) == "还剩 \(units)", "future detail \(units) uses absolute elapsed seconds")
            check(detail(after: -seconds) == "已逾期 \(units)", "past detail \(units) uses absolute elapsed seconds")
        }
        check(detail(after: 59.999) == "还剩 不足 1 分钟", "future sub-minute detail is explicit")
        check(detail(after: -0.001) == "已逾期 不足 1 分钟", "past sub-minute detail is explicit")
        check(detail(after: 0) == "已到期", "exact deadline is explicit")
        check(detail(after: 60) == "还剩 1 分钟", "exact minute boundary")
        check(detail(after: 7200) == "还剩 2 小时", "zero lower minutes omitted")
        check(detail(after: 86400) == "还剩 1 天", "exact day boundary omits zero hours")
        check(detail(after: 89100) == "还剩 1 天", "day detail uses days and hours without a third minute unit")
        let dstNow = ISO8601DateFormatter().date(from: "2026-11-01T07:30:00Z")!
        let dstEvent = try parse("UID:detail-dst\r\nDTSTART;TZID=America/Los_Angeles:20261101T023000\r\nSUMMARY:DST").events[0]
        check(CountdownPresentation.detail(for: dstEvent, now: dstNow) == "还剩 3 小时", "timed detail across DST uses elapsed seconds, not calendar hours")
        let originalZone = NSTimeZone.default
        defer { NSTimeZone.default = originalZone }
        for zoneName in ["Pacific/Kiritimati", "Pacific/Pago_Pago", "America/Los_Angeles"] {
            let zone = TimeZone(identifier: zoneName)!
            NSTimeZone.default = zone
            let allDay = try ICSParser.parse(calendar(event("UID:detail-all-day\r\nDTSTART;VALUE=DATE:20261025\r\nSUMMARY:全天")), localTimeZone: zone).events[0]
            func allDayDetail(_ instant: String) -> String? {
                CountdownPresentation.detail(for: allDay, now: ISO8601DateFormatter().date(from: instant)!)
            }
            check(allDayDetail("2026-10-24T15:59:59Z") == "明天到期（全天）", "all-day source date tomorrow independent of host zone \(zoneName)")
            check(allDayDetail("2026-10-25T15:59:59Z") == "今天到期（全天）", "all-day remains current through Shanghai date end \(zoneName)")
            check(allDayDetail("2026-10-25T16:00:00Z") == "已逾期 1 天（全天）", "all-day expiry at following Shanghai midnight \(zoneName)")
            check(allDayDetail("2026-10-22T16:00:00Z") == "还有 2 天（全天）", "all-day future distance counts calendar days \(zoneName)")
        }
        var cancelled = source; cancelled.cancelled = true
        check(CountdownPresentation.detail(for: cancelled, now: now) == nil, "cancelled source has no countdown even with deadline")
        var missing = source; missing.deadline = nil
        check(CountdownPresentation.detail(for: missing, now: now) == nil, "missing deadline has no countdown")
    }
    static func courseChecks() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-24T09:00:00Z")!
        let firstUID = "20261023T181430Z-_blackboard.platform.gradebook2.GradableItem-_100001_1@synthetic-bb3.example"
        let nextUID = "20261024T091430Z-_blackboard.platform.gradebook2.GradableItem-_100001_1@synthetic-bb9.example"
        let otherUID = firstUID.replacingOccurrences(of: "_100001_1", with: "_100002_1")
        let source = try parse("UID:\(firstUID)\r\nDTSTART:20261024T160000Z\r\nSUMMARY:同名作业").events[0]
        var later = source; later.uid = nextUID
        var other = source; other.uid = otherUID
        let key = CourseAssignments.key(for: source)!
        let otherKey = CourseAssignments.key(for: other)!
        check(key == ManagedNotes.marker(uid: firstUID) && key.count == 64 && !key.contains(firstUID), "course key is existing anonymous stable hash")
        check(CourseAssignments.key(for: later) == key, "volatile export changes preserve course key")
        check(key != otherKey, "same title with different stable IDs has independent course keys")
        check(CourseAssignments.normalizedName("  示例 Course  ") == "示例 Course", "course names trim outer whitespace and preserve embedded spaces")
        check(CourseAssignments.normalizedName(" \n\t ") == nil, "blank course name has no assignment")
        for invalid in ["示例\n课程", "示例\r课程", "示例\t课程", "示例\u{0000}课程", "示例\u{007F}课程", "示例\u{2028}课程"] {
            check(CourseAssignments.normalizedName(invalid) == nil, "embedded course controls and newlines rejected")
        }
        let assignments = [key: " 示例课程一 ", otherKey: "示例课程二"]
        check(CourseAssignments.name(for: source, in: assignments) == "示例课程一", "course lookup normalizes mapped value")
        check(CourseAssignments.name(for: later, in: assignments) == "示例课程一", "same stable item retains mapped course after export")
        check(CourseAssignments.name(for: other, in: assignments) == "示例课程二", "same-title different item keeps separate course")
        var unknown = source; unknown.uid = "unverified-uid"
        check(CourseAssignments.key(for: unknown) == nil, "unverified UID has no course key")
        check(CourseAssignments.name(for: unknown, in: [ManagedNotes.marker(uid: unknown.uid): "不应使用"]) == nil, "unverified UID cannot acquire a course by raw UID hash")
        check(CourseAssignments.name(for: source, in: [:]) == nil, "new unmapped event remains unknown")
        let saved: [String: Any] = [key: " 示例课程一 ", otherKey: "示例\n课程", "bad-key": "不能存入", String(repeating: "A", count: 64): "非法大写键", String(repeating: "c", count: 64): 123]
        check(CourseAssignments.validated(saved) == [key: "示例课程一"], "saved course dictionary retains only lowercase 64hex keys and valid string names")
        check(CourseAssignments.settingsKey == "courseNamesByStableUIDV1", "course settings use dedicated versioned key")
        func title(_ event: FeedEvent, completed: Bool = false, name: String? = "示例课程一") -> String {
            CoursePresentation.reminderTitle(for: event, isCompleted: completed, now: now, courseName: name)
        }
        check(title(source) == "【示例课程一】同名作业 — 明天到期（10/24更新）", "active title prefixes course around existing countdown presentation")
        check(title(source, name: nil) == "【课程待确认】同名作业 — 明天到期（10/24更新）", "unknown course has explicit title label")
        check(title(source, name: "课程\n无效").hasPrefix("【课程待确认】"), "invalid display course falls back to explicit unknown")
        check(title(source, completed: true) == "【示例课程一】同名作业", "completed title keeps course without countdown")
        var cancelled = source; cancelled.cancelled = true
        check(title(cancelled) == "【示例课程一】同名作业", "cancelled title keeps course without countdown")
        var missing = source; missing.deadline = nil
        check(title(missing) == "【示例课程一】同名作业", "missing deadline title keeps course without countdown")
        let original = source.title
        check(title(source) == title(source) && source.title == original && source.uid == firstUID && source.deadline?.date == later.deadline?.date, "repeated presentation neither accumulates prefix nor mutates feed identity or deadline")
        check(title(source, name: "示例课程二") == "【示例课程二】同名作业 — 明天到期（10/24更新）", "course edit reconstructs one prefix from raw title")
        let notes = ManagedNotes.replacing(in: "保留个人备注", event: source, alarmDate: source.deadline!.date)
        let stored = ManagedReminder(id: "course-existing", marker: key, isCompleted: true, notes: notes, identityVersion: 2, title: title(source, completed: true), dueDate: source.deadline!.date)
        let prepared = try LegacyAdoption.prepare(events: [later], existing: [stored])
        let plan = SyncPlanner.plan(events: [later], existing: prepared, now: now)
        check(plan.operations.count == 1 && plan.operations[0].existingID == stored.id && plan.operations[0].preserveCompleted, "course-prefixed v2 title replans existing completed item with no insert")
        check(plan.operations[0].event.title == original && prepared[0].notes == notes && prepared[0].marker == key, "course presentation preserves raw title, notes and v2 identity")
        var legacy = stored; legacy.identityVersion = 1
        do { _ = try LegacyAdoption.prepare(events: [later], existing: [legacy]); check(false, "course prefix never relaxes strict legacy title matching") }
        catch { check(true, "course prefix never relaxes strict legacy title matching") }
    }
    static func main() throws {
        if CommandLine.arguments.contains("--course-only") {
            try courseChecks()
            print("PASS: \(checks) course checks")
            return
        }
        if CommandLine.arguments.contains("--countdown-detail-only") {
            try countdownDetailChecks()
            print("PASS: \(checks) countdown detail checks")
            return
        }
        if CommandLine.arguments.contains("--countdown-only") {
            try countdownChecks()
            print("PASS: \(checks) countdown checks")
            return
        }
        let utc = try parse("UID:utc\r\nDTSTART:20261024T155900Z\r\nSUMMARY:作业")
        check(utc.events[0].deadline!.date.timeIntervalSince1970 == 1792857540, "UTC timestamp")
        let zoned = try parse("UID:tz\r\nDTSTART;TZID=Asia/Shanghai:20261024T235900\r\nSUMMARY:作业")
        check(zoned.events[0].deadline!.date == utc.events[0].deadline!.date, "TZID honors Shanghai")
        let floating = try parse("UID:floating\r\nDTSTART:20261024T235900")
        check(floating.events[0].deadline!.date == utc.events[0].deadline!.date, "floating uses local zone")
        let allDay = try parse("UID:all-day\r\nDTSTART;VALUE=DATE:20261024")
        check(allDay.events[0].deadline!.isAllDay, "all day retained")
        check(allDay.events[0].deadline!.components.hour == nil, "all-day has no time")
        let escaped = try parse("UID:folded\r\nDTSTART:20261024T235900Z\r\nSUMMARY:课程\\,一\\;作业\r\n 中文\r\nDESCRIPTION:第一行\\n第二行\\\\结束")
        check(escaped.events[0].title == "课程,一;作业中文", "folded Chinese + escaped punctuation")
        check(escaped.events[0].details == "第一行\n第二行\\结束", "escaped newline + backslash")
        let revisions = try ICSParser.parse(calendar(event("UID:same\r\nSEQUENCE:1\r\nDTSTART:20261024T120000Z\r\nSUMMARY:旧") + "\r\n" + event("UID:same\r\nSEQUENCE:2\r\nLAST-MODIFIED:20261022T120000Z\r\nDTSTART:20261025T120000Z\r\nSUMMARY:新") + "\r\n" + event("UID:same\r\nSEQUENCE:2\r\nLAST-MODIFIED:20261023T120000Z\r\nDTSTART:20261026T120000Z\r\nSUMMARY:最新")))
        check(revisions.events.count == 1 && revisions.events[0].title == "最新", "UID revision selection")
        let recurring = try parse("UID:recur\r\nDTSTART:20261024T120000Z\r\nRRULE:FREQ=WEEKLY")
        check(recurring.events.isEmpty && !recurring.warnings.isEmpty, "recurrence visibly skipped")
        let override = try parse("UID:recur\r\nDTSTART:20261024T120000Z\r\nRECURRENCE-ID:20261024T120000Z")
        check(override.events.isEmpty && !override.warnings.isEmpty, "recurrence override skipped")
        rejects("<html>login</html>", "HTML rejected")
        rejects(calendar(event("UID:bad\r\nDTSTART:20260230T120000Z")), "invalid date rejected")
        rejects(calendar(event("UID:bad\r\nDTSTART;TZID=NoSuch/Zone:20261024T120000")), "unknown TZID rejected")
        rejects(calendar(event("DTSTART:20261024T120000Z")), "missing UID rejected")
        rejects(calendar(event("UID:bad")), "missing deadline rejected")
        rejects("BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:bad\nDTSTART:20261024T120000Z\nEND:VCALENDAR", "unbalanced event rejected")
        rejects(calendar(event("UID:bad\r\nDTSTART:20261024T120000Z\r\nSEQUENCE:abc")), "bad sequence rejected")
        let now = ISO8601DateFormatter().date(from: "2026-10-24T09:00:00Z")!
        let old = try parse("UID:old\r\nDTSTART:20261023T120000Z").events[0]
        let today = try parse("UID:today\r\nDTSTART:20261024T010000Z").events[0]
        let marker = ManagedNotes.marker(uid: old.uid)
        let untouched = "我的笔记\n\n尾注"
        let notes = ManagedNotes.replacing(in: untouched, event: old, alarmDate: old.deadline!.date)
        check(ManagedNotes.identity(in: notes) == marker, "stable hashed UID marker")
        check(!marker.contains(old.uid), "UID is hashed")
        let existing = ManagedReminder(id: "existing", marker: marker, isCompleted: true, notes: notes)
        let plan = SyncPlanner.plan(events: [old, today], existing: [existing], now: now, localTimeZone: TimeZone(identifier: "Asia/Shanghai")!)
        check(plan.operations.count == 2, "old managed retained, today new imported")
        check(plan.operations.first { $0.event.uid == old.uid }?.existingID == "existing", "UID reuses existing")
        check(plan.operations.first { $0.event.uid == old.uid }?.preserveCompleted == true, "completion preserved")
        let first = SyncPlanner.plan(events: [old, today], existing: [], now: now, localTimeZone: TimeZone(identifier: "Asia/Shanghai")!)
        check(first.operations.count == 1 && first.skippedPast == 1, "first-import today horizon includes elapsed time today")
        var changed = old
        changed.title = "改名"
        changed.deadline = utc.events[0].deadline
        let replaced = ManagedNotes.replacing(in: notes + "\n用户尾注", event: changed, alarmDate: changed.deadline!.date)
        check(ManagedNotes.identity(in: replaced) == marker, "renaming/reschedule preserve identity")
        check(replaced.contains(untouched) && replaced.hasSuffix("\n用户尾注"), "user notes outside managed block preserved")
        check(replaced.components(separatedBy: ManagedNotes.beginPrefix).count == 2, "only one managed block")
        let cancelled = try parse("UID:old\r\nSTATUS:CANCELLED").events[0]
        check(SyncPlanner.plan(events: [cancelled], existing: [], now: now).operations.isEmpty, "cancel does not add")
        let cancellation = SyncPlanner.plan(events: [cancelled], existing: [existing], now: now)
        check(cancellation.operations.count == 1 && cancellation.operations[0].preserveCompleted, "cancel preserves existing completion")
        let cancelledNotes = ManagedNotes.replacing(in: notes, event: cancelled, alarmDate: nil)
        check(cancelledNotes.contains("已取消") && ManagedNotes.alarmDate(in: cancelledNotes) == nil, "cancel annotation removes managed alarm metadata")
        check(ManagedNotes.alarmDate(in: notes) == old.deadline!.date, "managed alarm tracks previous deadline")
        check(ManagedNotes.identity(in: "normal notes") == nil, "unrelated reminder ignored")
        check(ManagedNotes.identity(in: "[BB DDL: not valid]") == nil, "invalid marker ignored")
        let duplicate = SyncPlanner.plan(events: [old], existing: [existing, existing], now: now)
        check(duplicate.operations.count == 1 && !duplicate.warnings.isEmpty, "existing duplicate never creates another")
        for value in ["http://learn.intl.zju.edu.cn/webapps/calendar/calendarFeed/synthetic-example", "https://example.org/webapps/calendar/calendarFeed/synthetic-example", "https://learn.intl.zju.edu.cn/other", "https://learn.intl.zju.edu.cn:444/webapps/calendar/calendarFeed/synthetic-example", "https://user@learn.intl.zju.edu.cn/webapps/calendar/calendarFeed/synthetic-example", "https://learn.intl.zju.edu.cn/webapps/calendar/calendarFeed/../other"] {
            do { _ = try FeedAddress.validate(value); check(false, "source scope rejection") } catch { check(true, "source scope rejection") }
        }
        _ = try FeedAddress.validate("https://learn.intl.zju.edu.cn/webapps/calendar/calendarFeed/synthetic-example")
        check(true, "allowed source shape")
        for (status, mime, size) in [(302, "text/calendar", Int64(100)), (403, "text/plain", Int64(100)), (200, "text/html", Int64(100)), (200, "text/calendar", Int64(FeedHTTPPolicy.maxBytes + 1))] {
            do {
                try FeedHTTPPolicy.validate(status: status, address: "https://learn.intl.zju.edu.cn/webapps/calendar/calendarFeed/synthetic-example", mimeType: mime, expectedBytes: size)
                check(false, "invalid HTTP response rejected")
            } catch { check(true, "invalid HTTP response rejected") }
        }
        let newPlan = SyncPlanner.plan(events: [changed], existing: [existing], now: now)
        check(newPlan.operations[0].existingID == "existing" && newPlan.operations[0].preserveCompleted, "changed title/date preserves completed reminder")
        let allDayFirst = SyncPlanner.plan(events: allDay.events, existing: [], now: now, localTimeZone: TimeZone(identifier: "Asia/Shanghai")!)
        check(allDayFirst.operations.count == 1, "all-day horizon preserves local calendar date")
        let recurrenceFamily = try ICSParser.parse(calendar(event("UID:family\r\nDTSTART:20261024T120000Z") + "\r\n" + event("UID:family\r\nDTSTART:20261025T120000Z\r\nRECURRENCE-ID:20261024T120000Z")))
        check(recurrenceFamily.events.isEmpty, "unsupported recurrence family is not partially scheduled")
        let calendarCancel = try ICSParser.parse(calendar("METHOD:CANCEL\r\n" + event("UID:method-cancel")))
        check(calendarCancel.events[0].cancelled && calendarCancel.events[0].deadline == nil, "calendar cancellation with UID only")
        var injected = cancelled
        injected.details = "alarm=123\n" + ManagedNotes.end + "\n" + ManagedNotes.beginPrefix + String(repeating: "a", count: 64) + "]"
        let protected = ManagedNotes.replacing(in: "我的额外笔记", event: injected, alarmDate: nil)
        check(ManagedNotes.alarmDate(in: protected) == nil && ManagedNotes.identity(in: protected) == marker, "feed description cannot forge marker/alarm metadata")
        rejects(calendar(event("UID:dst\r\nDTSTART;TZID=America/New_York:20260308T023000")), "nonexistent DST time rejected")
        rejects(calendar("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR"), "nested calendars rejected")
        do {
            try ReconciliationSafety.validate(events: [today], recognizedMarkers: [], knownMarkers: [ManagedNotes.marker(uid: today.uid)], previouslySynced: true)
            check(false, "stale empty EventKit result cannot reinsert previously managed UID")
        } catch { check(true, "stale empty EventKit result cannot reinsert previously managed UID") }
        do {
            try ReconciliationSafety.validate(events: [today], recognizedMarkers: [], knownMarkers: [], previouslySynced: true)
            check(false, "legacy prior sync with no recognizable markers stops before writes")
        } catch { check(true, "legacy prior sync with no recognizable markers stops before writes") }
        try ReconciliationSafety.validate(events: [today], recognizedMarkers: [ManagedNotes.marker(uid: today.uid)], knownMarkers: [ManagedNotes.marker(uid: today.uid)], previouslySynced: true)
        check(true, "visible prior UID may update")
        try ReconciliationSafety.validate(events: [today], recognizedMarkers: [], knownMarkers: [], previouslySynced: false)
        check(true, "genuine first import remains allowed")
        do {
            try ReconciliationSafety.validate(events: [old, today], recognizedMarkers: [ManagedNotes.marker(uid: old.uid)], knownMarkers: [ManagedNotes.marker(uid: old.uid), ManagedNotes.marker(uid: today.uid)], previouslySynced: true)
            check(false, "partial database visibility stops before any inserts")
        } catch { check(true, "partial database visibility stops before any inserts") }
        do {
            try ReconciliationSafety.validate(events: [today], recognizedMarkers: [], knownMarkers: [ManagedNotes.marker(uid: old.uid)], previouslySynced: true)
            check(false, "prior sync with known old UID, zero recognized records, and different requested UID must stop")
        } catch { check(true, "prior sync with known old UID, zero recognized records, and different requested UID must stop") }
        try ReconciliationSafety.validate(events: [], recognizedMarkers: [], knownMarkers: [ManagedNotes.marker(uid: old.uid)], previouslySynced: true)
        check(true, "empty feed remains a no-write exemption despite missing recognized records")
        let exportUID1 = "20261023T181430Z-_blackboard.platform.gradebook2.GradableItem-_100001_1@synthetic-bb3.example"
        let exportUID2 = "20261024T091430Z-_blackboard.platform.gradebook2.GradableItem-_100001_1@synthetic-bb9.example"
        check(FeedIdentity.stableKey(uid: exportUID1) == "learn.intl.zju.edu.cn|blackboard.platform.gradebook2.GradableItem|_100001_1", "verified Blackboard grammar produces scoped stable key")
        check(ManagedNotes.marker(uid: exportUID1) == ManagedNotes.marker(uid: exportUID2), "timestamp and server changes preserve BB identity")
        check(FeedIdentity.stableKey(uid: "20261023T181430Z-_blackboard.other.Kind-_100001_1@synthetic-bb3.example") == nil, "unknown Blackboard classes are not heuristically normalized")
        check(ManagedNotes.marker(uid: exportUID1) != ManagedNotes.marker(uid: exportUID1.replacingOccurrences(of: "_100001_1", with: "_100001_2")), "complete primary key is retained")
        var exported = today; exported.uid = exportUID1; exported.title = "Test deadline"
        var laterExport = exported; laterExport.uid = exportUID2
        let v1Hash = String(repeating: "a", count: 64)
        let v1Notes = "保留前注\n[BB-DDL-SYNC v1 uid=\(v1Hash)]\nalarm=\(exported.deadline!.date.timeIntervalSince1970)\n旧版管理区\n[/BB-DDL-SYNC]\n保留尾注"
        let legacyReminder = ManagedReminder(id: "legacy-one", marker: v1Hash, isCompleted: true, notes: v1Notes, identityVersion: 1, title: exported.title, dueDate: exported.deadline!.date)
        let migrated = try LegacyAdoption.prepare(events: [laterExport], existing: [legacyReminder])
        check(migrated[0].marker == ManagedNotes.marker(uid: exportUID2) && migrated[0].isCompleted, "unique v1 adoption preserves completion")
        let migratedPlan = SyncPlanner.plan(events: [laterExport], existing: migrated, now: now)
        check(migratedPlan.operations.count == 1 && migratedPlan.operations[0].existingID == "legacy-one", "migration updates existing instead of inserting")
        try ReconciliationSafety.validate(events: [laterExport], recognizedMarkers: Set(migrated.map(\.marker)), knownMarkers: [], previouslySynced: true)
        check(true, "turnover guard runs after adoption mapping")
        let migratedNotes = ManagedNotes.replacing(in: v1Notes, event: laterExport, alarmDate: nil)
        check(ManagedNotes.identityVersion(in: migratedNotes) == 2 && migratedNotes.contains("identity-version=2stable") && !migratedNotes.contains(ManagedNotes.legacyPrefix), "one-time migration writes explicit stable v2 metadata")
        check(migratedNotes.hasPrefix("保留前注\n") && migratedNotes.hasSuffix("\n保留尾注"), "v1 migration retains outside-block notes")
        var rescheduled = laterExport; rescheduled.title = "Renamed deadline"; rescheduled.deadline = utc.events[0].deadline
        let stableExisting = ManagedReminder(id: "legacy-one", marker: migrated[0].marker, isCompleted: true, notes: migratedNotes, identityVersion: 2, title: exported.title, dueDate: exported.deadline!.date)
        let repeated = try LegacyAdoption.prepare(events: [rescheduled], existing: [stableExisting])
        check(SyncPlanner.plan(events: [rescheduled], existing: repeated, now: now).operations[0].existingID == "legacy-one", "second export with renamed/rescheduled item updates same v2 reminder")
        do { _ = try LegacyAdoption.prepare(events: [laterExport], existing: [legacyReminder, legacyReminder]); check(false, "ambiguous legacy duplicates blocked") }
        catch { check(true, "ambiguous legacy duplicates blocked") }
        var another = laterExport; another.uid = exportUID2.replacingOccurrences(of: "_100001_1", with: "_100002_1")
        do { _ = try LegacyAdoption.prepare(events: [laterExport, another], existing: [legacyReminder]); check(false, "ambiguous current title/date blocked") }
        catch { check(true, "ambiguous current title/date blocked") }
        do { _ = try LegacyAdoption.prepare(events: [rescheduled], existing: [legacyReminder]); check(false, "changed legacy title/date cannot be guessed") }
        catch { check(true, "changed legacy title/date cannot be guessed") }
        do { _ = try LegacyAdoption.prepare(events: [laterExport, rescheduled], existing: []); check(false, "conflicting current events with one stable BB ID blocked") }
        catch { check(true, "conflicting current events with one stable BB ID blocked") }
        do { try ReconciliationSafety.validate(events: [another], recognizedMarkers: [stableExisting.marker], knownMarkers: [], previouslySynced: true); check(false, "complete stable identity turnover blocks inserts") }
        catch { check(true, "complete stable identity turnover blocks inserts") }
        try ReconciliationSafety.validate(events: [laterExport, another], recognizedMarkers: [stableExisting.marker], knownMarkers: [], previouslySynced: true)
        check(SyncPlanner.plan(events: [laterExport, another], existing: [stableExisting], now: now, localTimeZone: TimeZone(identifier: "Asia/Shanghai")!).operations.filter { $0.existingID == nil }.count == 1, "new task adds normally with existing stable overlap on its Shanghai fixture day")
        let v2Unmatched = ManagedReminder(id: "v2-other", marker: String(repeating: "b", count: 64), isCompleted: false, notes: "", identityVersion: 2, title: laterExport.title, dueDate: laterExport.deadline!.date)
        let neverReAdopt = try LegacyAdoption.prepare(events: [laterExport], existing: [v2Unmatched])
        check(neverReAdopt[0].marker == v2Unmatched.marker, "v2 never falls back to title/date adoption")
        var allDayExport = allDay.events[0]; allDayExport.uid = exportUID1
        var hostCalendar = Calendar(identifier: .gregorian); hostCalendar.timeZone = .current
        // ReminderWriter reconstructs legacy all-day dates in the host calendar.
        // A Shanghai instant is not the same as the host-local civil date.
        let hostDue = hostCalendar.date(from: DateComponents(year: 2026, month: 10, day: 24))!
        if let requestedZone = ProcessInfo.processInfo.environment["TZ"], let expectedZone = TimeZone(identifier: requestedZone) {
            check(TimeZone.current.secondsFromGMT(for: hostDue) == expectedZone.secondsFromGMT(for: hostDue),
                  "the process actually uses its requested host timezone")
        }
        let allDayLegacy = ManagedReminder(id: "all-day-legacy", marker: v1Hash, isCompleted: true, notes: v1Notes, identityVersion: 1, title: allDayExport.title, dueDate: hostDue, isAllDay: true)
        let allDayAdopted = try LegacyAdoption.prepare(events: [allDayExport], existing: [allDayLegacy])
        check(allDayAdopted[0].marker == ManagedNotes.marker(uid: exportUID1), "legacy all-day adoption compares host-local civil date semantics")
        var wrongDate = allDayLegacy
        wrongDate.dueDate = hostCalendar.date(byAdding: .day, value: -1, to: hostDue)!
        do {
            _ = try LegacyAdoption.prepare(events: [allDayExport], existing: [wrongDate])
            check(false, "different legacy civil date must not be adopted")
        } catch { check(true, "different legacy civil date is rejected") }
        let shanghaiMidnight = ISO8601DateFormatter().date(from: "2026-10-24T16:00:00Z")!
        let previousSecond = shanghaiMidnight.addingTimeInterval(-1)
        let nextSecond = shanghaiMidnight.addingTimeInterval(1)
        let followingMidnight = ISO8601DateFormatter().date(from: "2026-10-25T16:00:00Z")!
        check(DailySchedule.nextMidnight(after: previousSecond) == shanghaiMidnight, "just before Shanghai midnight schedules that midnight")
        check(DailySchedule.nextMidnight(after: shanghaiMidnight) == followingMidnight, "exact midnight schedules next day with no immediate double-fire")
        check(DailySchedule.nextMidnight(after: nextSecond) == followingMidnight, "just after midnight schedules following midnight")
        check(DailySchedule.midnight(for: nextSecond) == shanghaiMidnight && DailySchedule.timeZone.identifier == "Asia/Shanghai", "daily boundary fixed to Shanghai independently of host timezone")
        check(DailySchedule.needsCatchUp(lastSuccess: previousSecond, now: nextSecond), "missed midnight requires wake catch-up")
        check(!DailySchedule.needsCatchUp(lastSuccess: shanghaiMidnight, now: nextSecond), "successful midnight sync prevents same-day wake sync")
        check(!DailySchedule.needsCatchUp(lastSuccess: nextSecond, now: shanghaiMidnight.addingTimeInterval(3600)), "manual or enable success counts for current Shanghai day")
        check(DailySchedule.needsCatchUp(lastSuccess: previousSecond.addingTimeInterval(-172800), now: nextSecond), "multi-day sleep needs one catch-up")
        try countdownChecks()
        try countdownDetailChecks()
        try courseChecks()
        print("PASS: \(checks) focused checks")
    }
}
