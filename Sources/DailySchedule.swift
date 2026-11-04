import Foundation

struct DailySchedule {
    static let timeZone = TimeZone(identifier: "Asia/Shanghai")!
    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = timeZone
        return value
    }
    static func midnight(for date: Date) -> Date { calendar.startOfDay(for: date) }
    static func nextMidnight(after date: Date) -> Date {
        // Advance the calendar day even when date is exactly midnight.
        calendar.date(byAdding: .day, value: 1, to: midnight(for: date))!
    }
    static func needsCatchUp(lastSuccess: Date?, now: Date) -> Bool {
        guard let lastSuccess else { return true }
        return lastSuccess < midnight(for: now)
    }
}
