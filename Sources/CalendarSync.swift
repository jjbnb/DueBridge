import Combine
import Foundation

struct CalendarScope: Equatable {
    let key: String
    static func bb(fingerprint: String) -> Self { Self(key: "bb-" + fingerprint) }

    static func bbFingerprint(address: String) throws -> String {
        let verified = try FeedAddress.validate(address)
        guard let parts = URLComponents(url: verified, resolvingAgainstBaseURL: false) else { throw RestoreFailure.invalid }
        let canonical = "https://learn.intl.zju.edu.cn" + parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
        return RestartRestore.fingerprint(canonical)
    }
}

enum CalendarDeadline: Equatable {
    case timed(Date, TimeZone)
    case allDay(year: Int, month: Int, day: Int)

    init(_ deadline: Deadline) throws {
        if deadline.isAllDay {
            guard let year = deadline.components.year, let month = deadline.components.month,
                  let day = deadline.components.day else { throw CalendarSyncFailure.invalidSnapshot }
            self = .allDay(year: year, month: month, day: day)
        } else {
            self = .timed(deadline.date, deadline.timeZone)
        }
    }

    var isAllDay: Bool {
        if case .allDay = self { return true }
        return false
    }

    var timeZone: TimeZone? {
        if case let .timed(_, zone) = self { return zone }
        return nil
    }

    func span(in zone: TimeZone) -> DateInterval? {
        switch self {
        case let .timed(date, _):
            guard date.timeIntervalSince1970.isFinite else { return nil }
            return DateInterval(start: date, duration: 60)
        case let .allDay(year, month, day):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let parts = DateComponents(year: year, month: month, day: day)
            guard let start = calendar.date(from: parts),
                  calendar.dateComponents([.year, .month, .day], from: start) == parts else { return nil }
            return calendar.dateInterval(of: .day, for: start)
        }
    }
}

struct CalendarTask {
    let key: String
    let title: String
    let deadline: CalendarDeadline
    let sourceName: String
    let link: URL?

    init(key: String, course: String?, title: String, deadline: Deadline, sourceName: String, verifiedHost: String) throws {
        func safeText(_ value: String?, fallback: String) -> String {
            guard let value, let normalized = CourseAssignments.normalizedName(value) else { return fallback }
            let decoded = normalized.removingPercentEncoding ?? normalized
            guard !decoded.localizedCaseInsensitiveContains("/webapps/calendar/calendarFeed/") else { return fallback }
            return normalized
        }
        self.key = key
        self.title = "【" + safeText(course, fallback: "课程待确认") + "】" +
            safeText(title, fallback: "未命名截止事项") + " · 截止"
        self.deadline = try CalendarDeadline(deadline)
        self.sourceName = sourceName
        // Never copy the BB subscription address, ICS descriptions, or session URLs.
        link = URL(string: "https://\(verifiedHost)/")
    }
}

struct CalendarProjection {
    let tasks: [CalendarTask]
    let skipped: Int

    static func bb(_ feed: Feed, courses: [String: String]) throws -> Self {
        let tasks = try feed.events.compactMap { event -> CalendarTask? in
            guard !event.cancelled, let deadline = event.deadline,
                  let key = CourseAssignments.key(for: event) else { return nil }
            return try CalendarTask(key: key, course: CourseAssignments.name(for: event, in: courses),
                                    title: event.title, deadline: deadline, sourceName: "BB",
                                    verifiedHost: "learn.intl.zju.edu.cn")
        }
        return Self(tasks: tasks, skipped: feed.events.count - tasks.count)
    }
}

enum CalendarSyncFailure: LocalizedError {
    case invalidSnapshot, invalidHistory, ambiguous, missingKnown, lookupLimit
    var errorDescription: String? {
        switch self {
        case .invalidSnapshot: return "截止事项的标识或日期无法校验，已停止日历同步。"
        case .invalidHistory: return "本机日历同步记录无法校验，已停止写入。"
        case .ambiguous: return "专用日历中有重复或无法确认归属的事件，已停止写入。"
        case .missingKnown: return "找不到本机记录中的已有日历事件，已停止写入以避免重复。"
        case .lookupLimit: return "日历查找超出安全范围，已停止写入。"
        }
    }
}

struct CalendarOwnership {
    let scope: String
    let task: String
    private static let begin = "[DueBridge-Calendar"
    private static let end = "[/DueBridge-Calendar]"

    static func hash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func parse(_ notes: String) throws -> (CalendarOwnership, Range<String.Index>)? {
        let begins = notes.components(separatedBy: begin).count - 1
        let ends = notes.components(separatedBy: "[/DueBridge-Calendar").count - 1
        if begins == 0 && ends == 0 { return nil }
        guard begins == 1, ends == 1, let start = notes.range(of: begin), let finish = notes.range(of: end),
              start.lowerBound < finish.lowerBound else { throw CalendarSyncFailure.ambiguous }
        let range = start.lowerBound..<finish.upperBound
        let lines = notes[range].replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.count == 3, lines[1].hasPrefix("来源："), lines[2] == end,
              let header = lines.first, header.hasPrefix(begin + " v1 scope="), header.hasSuffix("]") else {
            throw CalendarSyncFailure.ambiguous
        }
        let fields = header.dropFirst(begin.count + " v1 scope=".count).dropLast().components(separatedBy: " task=")
        guard fields.count == 2, !fields[0].isEmpty, fields[0].utf8.count <= 140,
              fields[0].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 || $0 == 95 }), hash(fields[1]) else {
            throw CalendarSyncFailure.ambiguous
        }
        return (Self(scope: fields[0], task: fields[1]), range)
    }

    static func marker(in notes: String) throws -> Self? { try parse(notes)?.0 }

    static func notes(personal: String, scope: CalendarScope, task: CalendarTask) -> String {
        let block = "\(begin) v1 scope=\(scope.key) task=\(task.key)]\n来源：\(task.sourceName)\n\(end)"
        return personal.isEmpty ? block : personal + "\n\n" + block
    }

    static func replacing(in original: String, scope: CalendarScope, task: CalendarTask) throws -> String {
        guard let (marker, span) = try parse(original) else { return notes(personal: original, scope: scope, task: task) }
        guard marker.scope == scope.key, marker.task == task.key else { throw CalendarSyncFailure.ambiguous }
        return original.replacingCharacters(in: span, with: notes(personal: "", scope: scope, task: task))
    }
}

struct CalendarEventReference: Codable, Equatable {
    let id: String
    let date: Date
}
struct CalendarExistingEvent {
    let id: String
    let key: String
}

struct CalendarReconciliation {
    struct Upsert {
        let task: CalendarTask
        let existingID: String?
    }
    let upserts: [Upsert]
    let skipped: Int

    static func plan(tasks: [CalendarTask], existing: [CalendarExistingEvent],
                     known: [String: CalendarEventReference], now: Date) throws -> Self {
        guard tasks.count <= 10_000, Set(tasks.map(\.key)).count == tasks.count,
              tasks.allSatisfy({ CalendarOwnership.hash($0.key) }) else { throw CalendarSyncFailure.invalidSnapshot }
        let matches = Dictionary(grouping: existing, by: \.key)
        guard matches.values.allSatisfy({ $0.count == 1 }) else { throw CalendarSyncFailure.ambiguous }
        let midnight = DailySchedule.midnight(for: now)
        var skipped = 0
        var upserts = [Upsert]()
        for task in tasks {
            guard let start = task.deadline.span(in: DailySchedule.timeZone)?.start else {
                throw CalendarSyncFailure.invalidSnapshot
            }
            if let match = matches[task.key]?.first {
                upserts.append(Upsert(task: task, existingID: match.id))
            } else if known[task.key] != nil {
                throw CalendarSyncFailure.missingKnown
            } else if start < midnight {
                skipped += 1
            } else {
                upserts.append(Upsert(task: task, existingID: nil))
            }
        }
        return Self(upserts: upserts, skipped: skipped)
    }
}

struct CalendarCheckpoint: Codable {
    let target: String
    var enabled = false
    var lastSuccess: Date?
    var retry: RetryCheckpoint?
    var blocked = false
    var known = [String: CalendarEventReference]()
    // Before writing, retain attempted dates so a retry can recover a committed
    // event even if the app exited before its identifier was recorded.
    var pending = [String: Set<Date>]()

    func validate() throws -> Self {
        func validDate(_ date: Date) -> Bool {
            date.timeIntervalSince1970.isFinite && abs(date.timeIntervalSince1970) < 300_000_000_000
        }
        guard !target.isEmpty, target.utf8.count <= 1024, known.count <= 100_000, pending.count <= 10_000,
              lastSuccess.map(validDate) ?? true,
              known.allSatisfy({ CalendarOwnership.hash($0.key) && !$0.value.id.isEmpty &&
                  $0.value.id.utf8.count <= 1024 && validDate($0.value.date) }),
              pending.allSatisfy({ CalendarOwnership.hash($0.key) && $0.value.count <= 16 && $0.value.allSatisfy(validDate) }) else {
            throw CalendarSyncFailure.invalidHistory
        }
        return self
    }

    private func currentRetry(now: Date) -> RetryCheckpoint? {
        guard let retry, retry.cycle == DailySchedule.midnight(for: now), (1...3).contains(retry.count),
              retry.deadline.map({ $0 >= retry.cycle && $0 <= now.addingTimeInterval(900) }) ?? (retry.count == 3) else { return nil }
        return retry
    }
    func isDue(now: Date) -> Bool {
        guard enabled, !blocked, DailySchedule.needsCatchUp(lastSuccess: RestartRestore.validSuccessDate(lastSuccess, now: now), now: now) else {
            return false
        }
        guard let retry = currentRetry(now: now) else { return true }
        return retry.deadline.map { now >= $0 } ?? false
    }
    func nextCheck(now: Date) -> Date? {
        guard enabled, !blocked else { return nil }
        let midnight = DailySchedule.nextMidnight(after: now)
        guard let deadline = currentRetry(now: now)?.deadline, deadline > now else { return midnight }
        return min(midnight, deadline)
    }
    mutating func recordSuccess(now: Date) { lastSuccess = now; retry = nil; blocked = false }
    mutating func recordFailure(network: Bool, now: Date) {
        guard network else { blocked = true; retry = nil; return }
        blocked = false
        let count = currentRetry(now: now)?.count ?? 0
        let delays: [TimeInterval] = [60, 300, 900]
        retry = RetryCheckpoint(cycle: DailySchedule.midnight(for: now), count: min(count + 1, 3),
                                deadline: count < 3 ? now.addingTimeInterval(delays[count]) : nil)
    }
}

@MainActor protocol CalendarEventDestination: AnyObject {
    var identifier: String? { get }
    func requireWritable() throws -> String
    func reconcile(scope: CalendarScope, projection: CalendarProjection, checkpoint: CalendarCheckpoint,
                   now: Date, persistPending: (CalendarCheckpoint) throws -> Void) throws -> (SyncResult, CalendarCheckpoint)
}

@MainActor final class CalendarSourceSync: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var status = "尚未启用苹果日历同步。"
    @Published private(set) var lastSync = "尚无成功同步记录"
    private let destination: CalendarEventDestination
    private let defaults: UserDefaults
    private var scope: CalendarScope?
    private var checkpoint: CalendarCheckpoint?

    init(destination: CalendarEventDestination, defaults: UserDefaults) {
        self.destination = destination
        self.defaults = defaults
    }

    private func key(_ scope: CalendarScope, target: String) -> String {
        "calendarEvents.v1." + scope.key + "." + RestartRestore.fingerprint(target)
    }
    private func load(_ scope: CalendarScope, target: String) throws -> CalendarCheckpoint? {
        guard let stored = defaults.object(forKey: key(scope, target: target)) else { return nil }
        guard let data = stored as? Data, data.count <= 32 * 1024 * 1024,
              let saved = try? JSONDecoder().decode(CalendarCheckpoint.self, from: data).validate(),
              saved.target == target else { throw CalendarSyncFailure.invalidHistory }
        return saved
    }
    private func save(_ value: CalendarCheckpoint, scope: CalendarScope) throws {
        let data = try JSONEncoder().encode(value.validate())
        guard data.count <= 32 * 1024 * 1024 else { throw CalendarSyncFailure.invalidHistory }
        defaults.set(data, forKey: key(scope, target: value.target))
        checkpoint = value
    }
    func savedIntent(scope: CalendarScope) -> Bool {
        guard let target = destination.identifier else { return false }
        return (try? load(scope, target: target)?.enabled) == true
    }
    func restore(scope: CalendarScope) {
        stop()
        guard let target = destination.identifier else { return }
        do {
            self.scope = scope
            checkpoint = try load(scope, target: target)
            enabled = checkpoint?.enabled == true
            if let date = checkpoint?.lastSuccess { lastSync = "上次成功：" + Self.time(date) }
            if enabled { status = "已恢复苹果日历同步。" }
        } catch { status = Self.message(error) }
    }
    func enable(scope: CalendarScope) -> Bool {
        do {
            let target = try destination.requireWritable()
            var saved = try load(scope, target: target) ?? CalendarCheckpoint(target: target)
            saved.enabled = true; saved.retry = nil; saved.blocked = false
            try save(saved, scope: scope)
            self.scope = scope; enabled = true
            lastSync = saved.lastSuccess.map { "上次成功：" + Self.time($0) } ?? "尚无成功同步记录"
            return true
        } catch {
            status = Self.message(error)
            return false
        }
    }
    func pause(savedScope: CalendarScope? = nil) {
        enabled = false
        do {
            if let binding = scope ?? savedScope, let target = destination.identifier {
                let prior = scope == binding ? checkpoint : try load(binding, target: target)
                if var saved = prior, saved.enabled {
                    saved.enabled = false; saved.retry = nil
                    try save(saved, scope: binding)
                    if scope == nil { checkpoint = nil }
                }
            }
            status = "苹果日历同步已暂停；已有事件保留。"
        } catch { status = Self.message(error) }
    }
    func stop() {
        enabled = false; scope = nil; checkpoint = nil
        status = "尚未启用苹果日历同步。"
        lastSync = "尚无成功同步记录"
    }
    func isDue(now: Date) -> Bool { enabled && checkpoint?.isDue(now: now) == true }
    func nextCheck(now: Date) -> Date? { enabled ? checkpoint?.nextCheck(now: now) : nil }
    func sync(scope: CalendarScope, now: Date, project: () throws -> CalendarProjection) {
        guard enabled, self.scope == scope, let checkpoint else { return }
        do {
            let (result, next) = try destination.reconcile(scope: scope, projection: project(), checkpoint: checkpoint,
                                                          now: now, persistPending: { try save($0, scope: scope) })
            var success = next
            success.recordSuccess(now: now)
            try save(success, scope: scope)
            lastSync = "\(Self.time(now))：新增 \(result.added)，更新 \(result.updated)，跳过 \(result.skipped)"
            status = "苹果日历同步完成。每天北京时间 00:00 检查。"
        } catch { fail(error, scope: scope, network: false, now: now) }
    }
    func fail(_ error: Error, scope: CalendarScope, network: Bool, now: Date) {
        guard enabled, self.scope == scope, var saved = checkpoint else { return }
        saved.recordFailure(network: network, now: now)
        do { try save(saved, scope: scope) }
        catch { enabled = false; status = Self.message(error); return }
        status = Self.message(error) + (network ? " 将有限重试。" : " 请处理后手动同步。")
    }
    private static func time(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }
    private static func message(_ error: Error) -> String {
        if error is NetworkFailure { return "读取课程失败或超时；苹果日历未更新。" }
        return (error as? LocalizedError)?.errorDescription ?? "苹果日历同步未完成。"
    }
}
