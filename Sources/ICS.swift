import Foundation
import CryptoKit

struct SafeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct FeedAddress {
    static func validate(_ raw: String) throws -> URL {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == "learn.intl.zju.edu.cn", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443, parts.fragment == nil,
              let decoded = parts.percentEncodedPath.removingPercentEncoding,
              decoded.hasPrefix("/webapps/calendar/calendarFeed/"),
              !decoded.contains("\\"), !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !decoded.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }),
              let url = parts.url else {
            throw SafeError("请填写学校 HTTPS 私人日历订阅链接（calendarFeed 路径）。")
        }
        return url
    }
}

struct FeedHTTPPolicy {
    static let maxBytes = 8 * 1024 * 1024
    static func validate(status: Int, address: String, mimeType: String?, expectedBytes: Int64) throws {
        _ = try FeedAddress.validate(address)
        guard status == 200 else { throw SafeError("无法读取日历（服务器状态异常），未修改提醒事项。") }
        let type = mimeType?.lowercased() ?? ""
        guard ["text/calendar", "text/plain", "application/ics", "application/octet-stream", "application/calendar", ""].contains(type), expectedBytes <= Int64(maxBytes) else {
            throw SafeError("服务器返回了登录页、错误页或过大的文件，未同步。")
        }
    }
}

struct Deadline: Equatable {
    var date: Date
    var components: DateComponents
    var isAllDay: Bool
    var timeZone: TimeZone
}
struct FeedEvent {
    var uid: String
    var title: String
    var details: String
    var deadline: Deadline?
    var sequence: Int
    var modified: Date?
    var cancelled: Bool
}
struct FeedIdentity {
    static func stableKey(uid: String) -> String? {
        // Only this school's observed GradableItem export grammar has been verified.
        let pattern = #"\A[0-9]{8}T[0-9]{6}Z-_(blackboard\.platform\.gradebook2\.GradableItem)-(_[0-9]+_[0-9]+)@[A-Za-z0-9.-]+\z"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: uid, range: NSRange(uid.startIndex..., in: uid)),
              let kind = Range(match.range(at: 1), in: uid), let pk = Range(match.range(at: 2), in: uid) else { return nil }
        return "learn.intl.zju.edu.cn|\(uid[kind])|\(uid[pk])"
    }
}
struct Feed {
    var events: [FeedEvent]
    var warnings: [String]
}

struct ICSParser {
    private struct Property {
        var name: String
        var parameters: [String: String]
        var value: String
    }
    static func parse(_ source: String, localTimeZone: TimeZone = .current) throws -> Feed {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        guard normalized.hasPrefix("BEGIN:VCALENDAR\n"), normalized.hasSuffix("\nEND:VCALENDAR"),
              !normalized.lowercased().contains("<html") else { throw SafeError("返回内容不是有效日历，可能需要重新取得 BB 订阅链接。") }
        var lines = [String]()
        for line in normalized.components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard !lines.isEmpty else { throw SafeError("日历折行格式无效。") }
                lines[lines.count - 1] += String(line.dropFirst())
            } else { lines.append(line) }
        }
        var stack = [String]()
        var eventProperties = [Property]()
        var candidates = [FeedEvent]()
        var unsupportedUIDs = Set<String>()
        var warnings = [String]()
        var sawVersion = false
        var calendarCancelled = false
        var roots = 0
        for line in lines where !line.isEmpty {
            let property = try property(line)
            if property.name == "BEGIN" {
                let component = property.value.uppercased()
                if stack.isEmpty && component != "VCALENDAR" { throw SafeError("日历结构无效。") }
                if component == "VCALENDAR" {
                    roots += 1
                    guard stack.isEmpty && roots == 1 else { throw SafeError("日历只能包含一个根组件。") }
                }
                if component == "VEVENT" {
                    guard stack == ["VCALENDAR"] else { throw SafeError("日历事件结构无效。") }
                    eventProperties = []
                }
                stack.append(component)
            } else if property.name == "END" {
                guard stack.last == property.value.uppercased() else { throw SafeError("日历组件未正确结束。") }
                if stack.last == "VEVENT" {
                    let properties = eventProperties
                    let uid = properties.first { $0.name == "UID" }?.value ?? ""
                    if properties.contains(where: { ["RRULE", "RDATE", "EXDATE", "RECURRENCE-ID"].contains($0.name) }) {
                        guard !uid.isEmpty else { throw SafeError("日历事件缺少 UID。") }
                        unsupportedUIDs.insert(uid)
                        warnings.append("已跳过一个含重复规则或重复例外的事件；本工具暂不支持重复日程。")
                    } else { candidates.append(try makeEvent(properties, localTimeZone: localTimeZone)) }
                }
                _ = stack.popLast()
            } else {
                guard !stack.isEmpty else { throw SafeError("日历包含组件外的数据。") }
                if stack == ["VCALENDAR"] && property.name == "VERSION" {
                    guard property.value == "2.0" else { throw SafeError("仅支持 iCalendar 2.0。") }
                    sawVersion = true
                }
                if stack == ["VCALENDAR"] && property.name == "METHOD" && property.value.uppercased() == "CANCEL" { calendarCancelled = true }
                if stack == ["VCALENDAR", "VEVENT"] { eventProperties.append(property) }
                if property.name == "TRIGGER" && stack.contains("VALARM") {
                    warnings.append("已忽略日历内的提前提醒；同步后默认只在截止时间提醒。")
                }
            }
        }
        guard stack.isEmpty, sawVersion else { throw SafeError("日历不完整或缺少版本。") }
        var selected = [String: FeedEvent]()
        for var event in candidates where !unsupportedUIDs.contains(event.uid) {
            if calendarCancelled { event.cancelled = true }
            guard event.deadline != nil || event.cancelled else { throw SafeError("日历事件缺少 DTSTART 截止时间。") }
            if let previous = selected[event.uid] {
                if event.sequence < previous.sequence { continue }
                if event.sequence == previous.sequence && (event.modified ?? .distantPast) < (previous.modified ?? .distantPast) { continue }
            }
            selected[event.uid] = event
        }
        return Feed(events: selected.values.sorted { ($0.deadline?.date ?? .distantFuture, $0.uid) < ($1.deadline?.date ?? .distantFuture, $1.uid) }, warnings: Array(Set(warnings)).sorted())
    }
    private static func property(_ line: String) throws -> Property {
        // A colon or semicolon inside a quoted parameter is not a separator.
        var quoted = false
        var colon: String.Index?
        for index in line.indices {
            if line[index] == "\"" { quoted.toggle() }
            if line[index] == ":" && !quoted { colon = index; break }
        }
        guard let split = colon else { throw SafeError("日历属性格式无效。") }
        let header = String(line[..<split])
        var tokens = [String](), current = ""
        quoted = false
        for character in header {
            if character == "\"" { quoted.toggle() }
            if character == ";" && !quoted { tokens.append(current); current = "" } else { current.append(character) }
        }
        tokens.append(current)
        guard !quoted, let name = tokens.first, !name.isEmpty else { throw SafeError("日历属性名称无效。") }
        var parameters = [String: String]()
        for token in tokens.dropFirst() {
            let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw SafeError("日历参数格式无效。") }
            parameters[pair[0].uppercased()] = String(pair[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return Property(name: name.uppercased(), parameters: parameters, value: String(line[line.index(after: split)...]))
    }
    private static func makeEvent(_ properties: [Property], localTimeZone: TimeZone) throws -> FeedEvent {
        func field(_ name: String) -> Property? { properties.first { $0.name == name } }
        for name in ["UID", "DTSTART", "SUMMARY", "STATUS", "SEQUENCE", "LAST-MODIFIED"] {
            guard properties.filter({ $0.name == name }).count <= 1 else { throw SafeError("日历事件包含重复的关键属性。") }
        }
        guard let uid = field("UID")?.value, !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SafeError("日历事件缺少 UID。") }
        let cancelled = field("STATUS")?.value.uppercased() == "CANCELLED"
        let deadline = try field("DTSTART").map { try date($0, localTimeZone: localTimeZone) }
        var sequence = 0
        if let value = field("SEQUENCE")?.value {
            guard let number = Int(value), number >= 0 else { throw SafeError("日历事件版本号无效。") }
            sequence = number
        }
        let modified = try field("LAST-MODIFIED").map { try date($0, localTimeZone: localTimeZone).date }
        let title = unescape(field("SUMMARY")?.value ?? "未命名截止事项")
        return FeedEvent(uid: uid, title: title.isEmpty ? "未命名截止事项" : title, details: unescape(field("DESCRIPTION")?.value ?? ""), deadline: deadline, sequence: sequence, modified: modified, cancelled: cancelled)
    }
    private static func date(_ property: Property, localTimeZone: TimeZone) throws -> Deadline {
        let raw = property.value
        let type = property.parameters["VALUE"]?.uppercased()
        guard type == nil || type == "DATE" || type == "DATE-TIME" else { throw SafeError("不支持此日历日期类型。") }
        let allDay = type == "DATE"
        let utc = raw.hasSuffix("Z")
        let body = utc ? String(raw.dropLast()) : raw
        guard (allDay && body.count == 8 && !utc && property.parameters["TZID"] == nil) || (!allDay && body.count == 15 && body[body.index(body.startIndex, offsetBy: 8)] == "T") else { throw SafeError("日历日期格式无效。") }
        guard !(utc && property.parameters["TZID"] != nil) else { throw SafeError("日历同时指定 UTC 与时区，无法安全同步。") }
        let zone: TimeZone
        if utc { zone = TimeZone(secondsFromGMT: 0)! }
        else if let name = property.parameters["TZID"] {
            guard let found = TimeZone(identifier: name) else { throw SafeError("日历含无法识别的时区；未作任何同步。") }
            zone = found
        } else { zone = localTimeZone }
        func number(_ start: Int, _ length: Int) throws -> Int {
            let a = body.index(body.startIndex, offsetBy: start), b = body.index(a, offsetBy: length)
            let value = body[a..<b]
            guard value.allSatisfy({ $0.isASCII && $0.isNumber }), let result = Int(value) else { throw SafeError("日历日期含无效数字。") }
            return result
        }
        var parts = DateComponents()
        parts.year = try number(0, 4); parts.month = try number(4, 2); parts.day = try number(6, 2)
        if !allDay { parts.hour = try number(9, 2); parts.minute = try number(11, 2); parts.second = try number(13, 2) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var input = parts; input.timeZone = zone
        guard let instant = calendar.date(from: input) else { throw SafeError("日历日期无法解析。") }
        let result = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
        guard parts.year == result.year, parts.month == result.month, parts.day == result.day,
              allDay || (parts.hour == result.hour && parts.minute == result.minute && parts.second == result.second) else { throw SafeError("日历日期不存在或处于时区跳时区间。") }
        if !allDay { parts.timeZone = zone }
        parts.calendar = calendar
        return Deadline(date: instant, components: parts, isAllDay: allDay, timeZone: zone)
    }
    static func unescape(_ text: String) -> String {
        var result = "", escaped = false
        for character in text {
            if escaped {
                if character == "n" || character == "N" { result.append("\n") }
                else if character == "\\" || character == "," || character == ";" { result.append(character) }
                else { result.append("\\"); result.append(character) }
                escaped = false
            } else if character == "\\" { escaped = true } else { result.append(character) }
        }
        if escaped { result.append("\\") }
        return result
    }
}

struct ManagedReminder {
    var id: String
    var marker: String
    var isCompleted: Bool
    var notes: String
    var identityVersion: Int = 2
    var title: String = ""
    var dueDate: Date? = nil
    var isAllDay: Bool = false
}
struct SyncOperation {
    var event: FeedEvent
    var existingID: String?
    var preserveCompleted: Bool
}
struct SyncPlan {
    var operations: [SyncOperation]
    var skippedPast: Int
    var warnings: [String]
}
struct ReconciliationSafety {
    /// Losing database visibility must never turn a previously imported UID into an insert.
    static func validate(events: [FeedEvent], recognizedMarkers: Set<String>, knownMarkers: Set<String>, previouslySynced: Bool) throws {
        let requested = Set(events.map { ManagedNotes.marker(uid: $0.uid) })
        let missing = requested.intersection(knownMarkers).subtracting(recognizedMarkers)
        guard missing.isEmpty else { throw SafeError("暂时无法完整读取已同步事项；为防止重复新增，本次未写入。请稍后重试并检查 BB DDL 列表。") }
        if !requested.isEmpty && !recognizedMarkers.isEmpty && requested.isDisjoint(with: recognizedMarkers) {
            throw SafeError("日历的事件标识全部发生变化；为防止重复新增，本次未写入。请核对订阅来源。")
        }
        // Any prior sync with no recognizable records is unsafe, even if all feed IDs changed.
        if previouslySynced && recognizedMarkers.isEmpty && !events.isEmpty {
            throw SafeError("无法识别原先同步的事项；为防止重复新增，本次未写入。请检查 BB DDL 列表中的管理备注。")
        }
    }
}
struct LegacyAdoption {
    static func prepare(events: [FeedEvent], existing: [ManagedReminder]) throws -> [ManagedReminder] {
        guard events.allSatisfy({ FeedIdentity.stableKey(uid: $0.uid) != nil }) else { throw SafeError("日历事件不含已验证的 BB 稳定记录 ID；为防止重复新增，本次未写入。") }
        let groups = Dictionary(grouping: events, by: { ManagedNotes.marker(uid: $0.uid) })
        guard groups.values.allSatisfy({ $0.count == 1 }) else { throw SafeError("多个日历事件指向同一个 BB 记录 ID；本次未写入，请核对日历。") }
        let stableMarkers = Set(existing.filter { $0.identityVersion == 2 }.map(\.marker))
        let unmatched = events.filter { !stableMarkers.contains(ManagedNotes.marker(uid: $0.uid)) }
        let legacy = existing.filter { $0.identityVersion == 1 }
        var adopted = [String: String]()
        func matches(_ event: FeedEvent, _ reminder: ManagedReminder) -> Bool {
            guard event.title == reminder.title, let deadline = event.deadline, let due = reminder.dueDate,
                  deadline.isAllDay == reminder.isAllDay else { return false }
            if !deadline.isAllDay { return deadline.date == due }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
            let old = calendar.dateComponents([.year, .month, .day], from: due)
            return old.year == deadline.components.year && old.month == deadline.components.month && old.day == deadline.components.day
        }
        for event in unmatched {
            let candidates = legacy.filter { matches(event, $0) }
            guard candidates.count <= 1 else { throw SafeError("旧版事项有重复或无法唯一识别；本次未写入，请先核对 BB DDL 列表。") }
            if let candidate = candidates.first {
                guard unmatched.filter({ matches($0, candidate) }).count == 1, adopted[candidate.id] == nil else { throw SafeError("旧版事项与日历不是唯一对应；本次未写入，请先核对。") }
                adopted[candidate.id] = ManagedNotes.marker(uid: event.uid)
            }
        }
        guard legacy.allSatisfy({ adopted[$0.id] != nil }) else { throw SafeError("部分旧版事项的标题或截止时间已改变，无法安全迁移；本次未写入，请先核对。") }
        return existing.map { reminder in
            var copy = reminder
            if let key = adopted[copy.id] { copy.marker = key; copy.identityVersion = 2 }
            return copy
        }
    }
}
struct SyncPlanner {
    static func plan(events: [FeedEvent], existing: [ManagedReminder], now: Date = Date(), localTimeZone: TimeZone = .current) -> SyncPlan {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = localTimeZone
        let today = calendar.startOfDay(for: now)
        var map = [String: ManagedReminder](), warnings = [String]()
        for reminder in existing {
            if map[reminder.marker] != nil { warnings.append("列表中发现重复的已管理事项，本次只更新其中一条，不新增重复项。") }
            else { map[reminder.marker] = reminder }
        }
        var operations = [SyncOperation](), skipped = 0
        for event in events {
            let match = map[ManagedNotes.marker(uid: event.uid)]
            if match == nil {
                if event.cancelled { continue }
                guard let deadline = event.deadline else { continue }
                // Date-only values compare by their calendar date, with no UTC boundary shift.
                let isPast: Bool
                if deadline.isAllDay {
                    var parts = deadline.components; parts.timeZone = localTimeZone; parts.calendar = calendar
                    isPast = (calendar.date(from: parts) ?? .distantPast) < today
                } else { isPast = deadline.date < today }
                if isPast { skipped += 1; continue }
            }
            operations.append(SyncOperation(event: event, existingID: match?.id, preserveCompleted: match?.isCompleted ?? false))
        }
        return SyncPlan(operations: operations, skippedPast: skipped, warnings: Array(Set(warnings)).sorted())
    }
}

struct ManagedNotes {
    static let beginPrefix = "[BB-DDL-SYNC v2stable uid="
    static let legacyPrefix = "[BB-DDL-SYNC v1 uid="
    static let end = "[/BB-DDL-SYNC]"
    static func marker(uid: String) -> String { SHA256.hash(data: Data((FeedIdentity.stableKey(uid: uid) ?? uid).utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func block(in notes: String) -> (Range<String.Index>, String, Int)? {
        let starts = [(beginPrefix, 2), (legacyPrefix, 1)].compactMap { prefix, version -> (Range<String.Index>, Int)? in notes.range(of: prefix).map { ($0, version) } }.sorted { $0.0.lowerBound < $1.0.lowerBound }
        guard let (start, version) = starts.first, let finish = notes.range(of: end, range: start.upperBound..<notes.endIndex),
              let closing = notes[start.upperBound..<finish.lowerBound].firstIndex(of: "]") else { return nil }
        let hash = String(notes[start.upperBound..<closing])
        guard hash.count == 64, hash.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }) else { return nil }
        return (start.lowerBound..<finish.upperBound, hash, version)
    }
    static func identity(in notes: String) -> String? { block(in: notes)?.1 }
    static func identityVersion(in notes: String) -> Int? { block(in: notes)?.2 }
    static func alarmDate(in notes: String) -> Date? {
        guard let (range, _, _) = block(in: notes) else { return nil }
        let lines = notes[range].components(separatedBy: "\n")
        guard lines.count > 1, lines[1].hasPrefix("alarm=") else { return nil }
        if let value = Double(lines[1].dropFirst(6)), value.isFinite { return Date(timeIntervalSince1970: value) }
        return nil
    }
    static func replacing(in notes: String, event: FeedEvent, alarmDate: Date?) -> String {
        var lines = ["\(beginPrefix)\(marker(uid: event.uid))]", "alarm=\(alarmDate.map { String($0.timeIntervalSince1970) } ?? "none")", "identity-version=2stable", "BB 日历同步 · \(event.cancelled ? "已取消（请自行决定是否完成）" : "截止事项；完成状态由你手动管理")"]
        if !event.details.isEmpty {
            // Feed text must never be able to terminate or impersonate the managed block.
            lines.append(event.details.replacingOccurrences(of: "[BB-DDL-SYNC ", with: "［BB-DDL-SYNC ").replacingOccurrences(of: end, with: "［/BB-DDL-SYNC］"))
        }
        lines.append(end)
        let managed = lines.joined(separator: "\n")
        if let (range, _, _) = block(in: notes) { var copy = notes; copy.replaceSubrange(range, with: managed); return copy }
        return notes.isEmpty ? managed : notes + "\n\n" + managed
    }
}
