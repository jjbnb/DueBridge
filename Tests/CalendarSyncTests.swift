// Synthetic fixtures only; public school domains test exact request policies.
import Foundation

private struct DesktopFixture: Decodable {
    let now: String
    let originalIcs: String
    let rescheduledIcs: String
    let courseName: String
    let timedKey: String
    let allDayKey: String
    let timedDueUtc: String
    let rescheduledDueUtc: String
    let allDay: String
    let expectedTimedTitle: String
}

@main struct CalendarSyncTests {
    static func main() throws {
        let fixture = try JSONDecoder().decode(DesktopFixture.self, from: Data(contentsOf:
            URL(fileURLWithPath: ProcessInfo.processInfo.environment["DUEBRIDGE_DESKTOP_FIXTURE"] ?? "Tests/Fixtures/desktop-parity.json")))
        let iso = ISO8601DateFormatter()
        let now = iso.date(from: fixture.now)!
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let original = try ICSParser.parse(fixture.originalIcs, localTimeZone: zone)
        let rescheduled = try ICSParser.parse(fixture.rescheduledIcs, localTimeZone: zone)
        let courses = [fixture.timedKey: fixture.courseName, fixture.allDayKey: fixture.courseName]
        let before = try CalendarProjection.bb(original, courses: courses).tasks
        let after = try CalendarProjection.bb(rescheduled, courses: courses).tasks
        let oldTimed = before.first { $0.key == fixture.timedKey }!
        let newTimed = after.first { $0.key == fixture.timedKey }!
        precondition(before.count == 2 && after.count == 2)
        precondition(oldTimed.title == fixture.expectedTimedTitle && newTimed.title == oldTimed.title)
        precondition(oldTimed.deadline.span(in: zone)?.start == iso.date(from: fixture.timedDueUtc))
        precondition(newTimed.deadline.span(in: zone)?.start == iso.date(from: fixture.rescheduledDueUtc))
        let allDay = before.first { $0.key == fixture.allDayKey }!.deadline
        let civil = DateFormatter()
        civil.dateFormat = "yyyy-MM-dd"
        civil.timeZone = zone
        precondition(civil.string(from: allDay.span(in: zone)!.start) == fixture.allDay)
        civil.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        precondition(civil.string(from: allDay.span(in: civil.timeZone)!.start) == fixture.allDay)

        let daylightSaving = CalendarDeadline.allDay(year: 2018, month: 11, day: 4)
        let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!
        let shortDay = daylightSaving.span(in: saoPaulo)
        precondition(shortDay?.start == iso.date(from: "2018-11-04T03:00:00Z") &&
                     shortDay?.end == iso.date(from: "2018-11-05T02:00:00Z"),
                     "A midnight DST transition ends at the next civil midnight")

        let scope = CalendarScope.bb(fingerprint: String(repeating: "a", count: 64))
        let oldDate = oldTimed.deadline.span(in: zone)!.start
        let oldRef = CalendarEventReference(id: "first", date: oldDate)
        let oldEvent = CalendarExistingEvent(id: "first", key: oldTimed.key)
        let first = try CalendarReconciliation.plan(tasks: before, existing: [], known: [:], now: now)
        precondition(first.upserts.count == 2)
        let repeatPlan = try CalendarReconciliation.plan(tasks: [newTimed], existing: [oldEvent],
                                                       known: [oldTimed.key: oldRef], now: now)
        precondition(repeatPlan.upserts.count == 1 && repeatPlan.upserts[0].existingID == "first")
        let absent = try CalendarReconciliation.plan(tasks: [], existing: [oldEvent],
                                                     known: [oldTimed.key: oldRef], now: now)
        precondition(absent.upserts.isEmpty)
        expectFailure {
            _ = try CalendarReconciliation.plan(tasks: [newTimed], existing: [],
                                               known: [oldTimed.key: oldRef], now: now)
        }
        expectFailure {
            _ = try CalendarReconciliation.plan(tasks: [newTimed],
                                               existing: [oldEvent, .init(id: "second", key: oldTimed.key)],
                                               known: [oldTimed.key: oldRef], now: now)
        }
        let notes = CalendarOwnership.notes(personal: "保留个人备注", scope: scope, task: oldTimed)
        let marker = try CalendarOwnership.marker(in: notes)
        precondition(marker?.scope == scope.key && marker?.task == oldTimed.key)
        precondition(notes.contains("保留个人备注"))
        precondition(!notes.contains("calendarFeed"))

        var checkpoint = CalendarCheckpoint(target: "calendar")
        checkpoint.enabled = true
        precondition(checkpoint.isDue(now: now))
        checkpoint.recordSuccess(now: now)
        precondition(!checkpoint.isDue(now: now))
        checkpoint.recordFailure(network: true, now: now)
        precondition(checkpoint.lastSuccess == now)
        precondition(!checkpoint.isDue(now: now))
        let data = try JSONEncoder().encode(checkpoint)
        let restored = try JSONDecoder().decode(CalendarCheckpoint.self, from: data)
        precondition(restored.lastSuccess == now && restored.enabled && restored.target == "calendar")
        print("Calendar projection, ownership, reconciliation and checkpoint tests passed.")
    }

    private static func expectFailure(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Unsafe reconciliation should stop") }
        catch {}
    }
}
