import Foundation

enum NativeDeadlineParser {
    static func parse(_ raw: String?, naiveTimeZone: TimeZone) throws -> Deadline? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let pattern = #"\A([0-9]{4})-([0-9]{2})-([0-9]{2})[ T]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?(?:(Z|z)|([+-])([0-9]{2}):?([0-9]{2}))?\z"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { throw NativeTaskError.invalidDeadline }
        func field(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        let year = Int(field(1)!)!, month = Int(field(2)!)!, day = Int(field(3)!)!
        let hour = Int(field(4)!)!, minute = Int(field(5)!)!, second = Int(field(6)!)!
        guard year > 0, (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { throw NativeTaskError.invalidDeadline }
        var zone = naiveTimeZone
        if field(8) != nil { zone = TimeZone(secondsFromGMT: 0)! }
        if let sign = field(9) {
            let hours = Int(field(10)!)!, minutes = Int(field(11)!)!
            guard hours <= 23, minutes <= 59,
                  let explicitZone = TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)) else { throw NativeTaskError.invalidDeadline }
            zone = explicitZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let base = calendar.date(from: parts) else { throw NativeTaskError.invalidDeadline }
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let actual = calendar.dateComponents(fields, from: base)
        for component in fields where parts.value(for: component) != actual.value(for: component) { throw NativeTaskError.invalidDeadline }
        // A fractional field is less than one second even if Double rounds it to 1.
        guard base.timeIntervalSince1970 >= 0 else { throw NativeTaskError.invalidDeadline }
        let fraction = field(7).flatMap { Double("0." + $0) } ?? 0
        let date = base.addingTimeInterval(fraction)
        guard date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= 0 else { throw NativeTaskError.invalidDeadline }
        let displayZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.timeZone = displayZone
        // Extract from the resulting instant, including representable nanoseconds, so validation stays coherent.
        let displayParts = calendar.dateComponents(fields.union([.nanosecond]), from: date)
        return Deadline(date: date, components: displayParts, isAllDay: false, timeZone: displayZone)
    }
}
