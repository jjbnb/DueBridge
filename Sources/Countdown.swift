import Foundation

enum CountdownPresentation {
    static func reminderTitle(for event: FeedEvent, isCompleted: Bool, now: Date) -> String {
        guard !isCompleted, !event.cancelled, let deadline = event.deadline else { return event.title }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = DailySchedule.timeZone
        let today = calendar.startOfDay(for: now)
        let dueDay: Date
        if deadline.isAllDay {
            // Date-only deadlines retain their source Y/M/D, regardless of the host zone.
            var parts = DateComponents()
            parts.year = deadline.components.year
            parts.month = deadline.components.month
            parts.day = deadline.components.day
            guard let date = calendar.date(from: parts) else { return event.title }
            dueDay = date
        } else {
            dueDay = calendar.startOfDay(for: deadline.date)
        }
        let days = calendar.dateComponents([.day], from: today, to: dueDay).day ?? 0
        let overdue = deadline.isAllDay ? days < 0 : deadline.date < now
        let label: String
        if overdue {
            label = days < 0 ? "已逾期 \(-days) 天" : "已逾期"
        } else if days == 0 {
            label = "今天到期"
        } else if days == 1 {
            label = "明天到期"
        } else {
            label = "还有 \(days) 天"
        }
        let stamp = calendar.dateComponents([.month, .day], from: now)
        let month = String(format: "%02d", stamp.month!)
        let day = String(format: "%02d", stamp.day!)
        return "\(event.title) — \(label)（\(month)/\(day)更新）"
    }

    static func detail(for event: FeedEvent, now: Date) -> String? {
        guard !event.cancelled, let deadline = event.deadline else { return nil }
        if deadline.isAllDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = DailySchedule.timeZone
            var parts = DateComponents()
            parts.year = deadline.components.year
            parts.month = deadline.components.month
            parts.day = deadline.components.day
            guard let dueDay = calendar.date(from: parts) else { return nil }
            let today = calendar.startOfDay(for: now)
            let days = calendar.dateComponents([.day], from: today, to: dueDay).day ?? 0
            let label: String
            if days < 0 { label = "已逾期 \(-days) 天" }
            else if days == 0 { label = "今天到期" }
            else if days == 1 { label = "明天到期" }
            else { label = "还有 \(days) 天" }
            return label + "（全天）"
        }
        let interval = deadline.date.timeIntervalSince(now)
        guard interval != 0 else { return "已到期" }
        let prefix = interval > 0 ? "还剩 " : "已逾期 "
        let seconds = Int(abs(interval))
        guard seconds >= 60 else { return prefix + "不足 1 分钟" }
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 {
            let lower = hours % 24
            return prefix + "\(days) 天" + (lower > 0 ? " \(lower) 小时" : "")
        }
        if hours > 0 {
            let lower = minutes % 60
            return prefix + "\(hours) 小时" + (lower > 0 ? " \(lower) 分钟" : "")
        }
        return prefix + "\(minutes) 分钟"
    }
}
