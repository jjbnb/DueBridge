import Combine
import EventKit
import Foundation

struct CalendarAccountChoice: Identifiable {
    let id: String
    let title: String
    let recommended: Bool
}
private struct DedicatedCalendar: Codable {
    let accountID: String
    let calendarID: String
}

@MainActor final class CalendarDestinationModel: ObservableObject, CalendarEventDestination {
    static let calendarTitle = "归期 · 课程截止事项"
    private static let settingsKey = "calendarEventDestination.v1"
    private lazy var store = EKEventStore()
    private let defaults: UserDefaults
    private var destination: DedicatedCalendar?
    private var damaged = false
    @Published private(set) var accounts = [CalendarAccountChoice]()
    @Published private(set) var accountName: String?
    @Published private(set) var status = "先在课程来源页预览，再授权并选择账户。"
    @Published private(set) var busy = false
    var identifier: String? { destination?.calendarID }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let savedValue = defaults.object(forKey: Self.settingsKey) {
            if let data = savedValue as? Data, data.count <= 4096,
               let saved = try? JSONDecoder().decode(DedicatedCalendar.self, from: data),
               !saved.calendarID.isEmpty, !saved.accountID.isEmpty {
                destination = saved
                status = "已创建专用日历。可在各课程来源页启用苹果日历同步。"
            } else {
                damaged = true
                status = CalendarSyncFailure.invalidHistory.localizedDescription
            }
        }
    }

    private static var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    private static let permissionMessage = "请在“系统设置 → 隐私与安全性 → 日历”中允许归期完全访问日历。"

    func loadAccounts() async {
        guard !busy, !damaged else { return }
        busy = true; defer { busy = false }
        do {
            if !Self.authorized {
                guard try await store.requestFullAccessToEvents(), Self.authorized else { throw SafeError(Self.permissionMessage) }
            }
            store.refreshSourcesIfNecessary()
            let writableSources = Set(store.calendars(for: .event).filter(\.allowsContentModifications).compactMap { $0.source?.sourceIdentifier })
            accounts = store.sources.compactMap { source in
                guard source.sourceType == .local || writableSources.contains(source.sourceIdentifier) else { return nil }
                return CalendarAccountChoice(id: source.sourceIdentifier, title: source.title,
                    recommended: source.title.localizedCaseInsensitiveContains("iCloud"))
            }.sorted {
                if $0.recommended != $1.recommended { return $0.recommended }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            if destination != nil {
                let calendar = try resolve()
                accountName = calendar.source?.title
                status = "已创建专用日历。可在各课程来源页启用苹果日历同步。"
            } else {
                status = accounts.isEmpty ? "没有可写的日历账户。请先在系统中添加账户。" : "请选择用于创建专用日历的账户。"
            }
        } catch {
            status = (error as? SafeError)?.message ?? Self.permissionMessage
        }
    }

    func create(in accountID: String) {
        guard !busy, !damaged, destination == nil, accounts.contains(where: { $0.id == accountID }) else { return }
        do {
            guard Self.authorized else { throw SafeError(Self.permissionMessage) }
            store.refreshSourcesIfNecessary()
            guard let account = store.source(withIdentifier: accountID) else { throw SafeError("选定的日历账户已不可用，请刷新账户。") }
            guard !store.calendars(for: .event).contains(where: {
                $0.source?.sourceIdentifier == accountID && $0.title == Self.calendarTitle
            }) else {
                throw SafeError("账户中已有同名日历。请先确认其归属并改名，再创建专用日历。")
            }
            let calendar = EKCalendar(for: .event, eventStore: store)
            calendar.title = Self.calendarTitle
            calendar.source = account
            try store.saveCalendar(calendar, commit: false)
            guard calendar.allowsContentModifications, calendar.allowedEntityTypes.contains(.event),
                  !calendar.calendarIdentifier.isEmpty else {
                throw SafeError("新建日历不可写。请选择支持添加日历事件的账户。")
            }
            try store.commit()
            let binding = DedicatedCalendar(accountID: accountID, calendarID: calendar.calendarIdentifier)
            defaults.set(try JSONEncoder().encode(binding), forKey: Self.settingsKey)
            destination = binding
            accountName = account.title
            status = "专用日历已创建。回到课程来源页启用苹果日历同步。"
        } catch {
            store.reset()
            status = (error as? SafeError)?.message ?? "未能创建专用日历，请检查账户是否允许创建日历。"
        }
    }

    private func resolve() throws -> EKCalendar {
        guard !damaged else { throw CalendarSyncFailure.invalidHistory }
        guard Self.authorized else { throw SafeError(Self.permissionMessage) }
        guard let destination else { throw SafeError("请先在“苹果日历”页选择账户并创建专用日历。") }
        guard let calendar = store.calendar(withIdentifier: destination.calendarID),
              calendar.source?.sourceIdentifier == destination.accountID,
              calendar.allowedEntityTypes.contains(.event), calendar.allowsContentModifications else {
            throw SafeError("已保存的专用日历不可用。请恢复原日历和账户后重试。")
        }
        return calendar
    }

    func requireWritable() throws -> String {
        guard Self.authorized else { throw SafeError(Self.permissionMessage) }
        store.refreshSourcesIfNecessary()
        return try resolve().calendarIdentifier
    }

    private func searchWindows(dates: [Date]) throws -> [DateInterval] {
        // Each range is far shorter than EventKit's four-year truncation limit.
        let day: TimeInterval = 86_400
        var windows = [DateInterval]()
        for date in Set(dates).sorted() {
            let start = date.addingTimeInterval(-2 * day)
            let end = date.addingTimeInterval(2 * day)
            if let last = windows.last, start <= last.end, end.timeIntervalSince(last.start) <= 365 * day {
                windows[windows.count - 1] = DateInterval(start: last.start, end: max(end, last.end))
            } else {
                guard windows.count < 512 else { throw CalendarSyncFailure.lookupLimit }
                windows.append(DateInterval(start: start, end: end))
            }
        }
        return windows
    }

    private func lookup(in calendar: EKCalendar, scope: CalendarScope, tasks: [CalendarTask],
                        checkpoint: CalendarCheckpoint, spans: [String: DateInterval]) throws -> [String: EKEvent] {
        var dates = [Date]()
        var byID = [String: EKEvent]()
        var observed = 0
        let keys = Set(tasks.map(\.key))
        func inspect(_ event: EKEvent) throws {
            observed += 1
            guard observed <= 50_000 else { throw CalendarSyncFailure.lookupLimit }
            guard let marker = try CalendarOwnership.marker(in: event.notes ?? ""),
                  marker.scope == scope.key, keys.contains(marker.task) else { return }
            guard event.calendar?.calendarIdentifier == calendar.calendarIdentifier, !event.hasRecurrenceRules,
                  !event.isDetached, let id = event.eventIdentifier, !id.isEmpty else {
                throw CalendarSyncFailure.ambiguous
            }
            if let previous = byID[id], previous.startDate != event.startDate || previous.notes != event.notes {
                throw CalendarSyncFailure.ambiguous
            }
            byID[id] = event
        }
        for task in tasks {
            if let start = spans[task.key]?.start { dates.append(start) }
            if let reference = checkpoint.known[task.key] {
                dates.append(reference.date)
                if let event = store.event(withIdentifier: reference.id) {
                    let marker = try CalendarOwnership.marker(in: event.notes ?? "")
                    guard marker?.scope == scope.key, marker?.task == task.key else { throw CalendarSyncFailure.ambiguous }
                    try inspect(event)
                }
            }
            dates.append(contentsOf: checkpoint.pending[task.key] ?? [])
        }
        for window in try searchWindows(dates: dates) {
            let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: [calendar])
            var failure: Error?
            store.enumerateEvents(matching: predicate) { event, stop in
                do { try inspect(event) }
                catch { failure = error; stop.pointee = true }
            }
            if let failure { throw failure }
        }
        return byID
    }

    func reconcile(scope: CalendarScope, projection: CalendarProjection, checkpoint: CalendarCheckpoint,
                   now: Date, persistPending: (CalendarCheckpoint) throws -> Void) throws -> (SyncResult, CalendarCheckpoint) {
        try Task.checkCancellation()
        guard try requireWritable() == checkpoint.target else { throw SafeError("专用日历已变化，请重新启用日历同步。") }
        let calendar = try resolve()
        let zone = NSTimeZone.default
        guard projection.tasks.count <= 10_000 else { throw CalendarSyncFailure.lookupLimit }
        var spans = [String: DateInterval]()
        for task in projection.tasks {
            guard let span = task.deadline.span(in: zone), spans.updateValue(span, forKey: task.key) == nil else {
                throw CalendarSyncFailure.invalidSnapshot
            }
        }
        let events = try lookup(in: calendar, scope: scope, tasks: projection.tasks, checkpoint: checkpoint, spans: spans)
        let existing = try events.map { id, event -> CalendarExistingEvent in
            guard let marker = try CalendarOwnership.marker(in: event.notes ?? "") else { throw CalendarSyncFailure.ambiguous }
            return CalendarExistingEvent(id: id, key: marker.task)
        }
        let plan = try CalendarReconciliation.plan(tasks: projection.tasks, existing: existing, known: checkpoint.known, now: now)
        let retainedKeys = Set(checkpoint.known.keys).union(plan.upserts.map { $0.task.key })
        guard retainedKeys.count <= 100_000 else { throw CalendarSyncFailure.lookupLimit }
        var next = checkpoint
        for operation in plan.upserts {
            guard let span = spans[operation.task.key] else { throw CalendarSyncFailure.invalidSnapshot }
            next.pending[operation.task.key, default: []].insert(span.start)
        }
        if !plan.upserts.isEmpty { try persistPending(next) }
        var result = SyncResult(added: 0, updated: 0, skipped: plan.skipped + projection.skipped, warnings: [])
        var written = [(task: CalendarTask, event: EKEvent, date: Date)]()
        var staged = false
        do {
            for operation in plan.upserts {
                let task = operation.task
                guard let span = spans[task.key] else { throw CalendarSyncFailure.invalidSnapshot }
                let event: EKEvent
                if let id = operation.existingID {
                    guard let found = events[id] else { throw CalendarSyncFailure.ambiguous }
                    event = found
                } else {
                    event = EKEvent(eventStore: store)
                    event.calendar = calendar
                    event.alarms = []
                }
                let notes = try CalendarOwnership.replacing(in: event.notes ?? "", scope: scope, task: task)
                let free = calendar.supportedEventAvailabilities.contains(.free)
                if event.title != task.title || event.isAllDay != task.deadline.isAllDay ||
                    event.startDate != span.start || event.endDate != span.end ||
                    event.notes != notes || event.url != task.link || (free && event.availability != .free) {
                    event.title = task.title
                    event.isAllDay = task.deadline.isAllDay
                    event.timeZone = task.deadline.timeZone
                    event.startDate = span.start
                    event.endDate = span.end
                    event.notes = notes
                    event.url = task.link
                    if free { event.availability = .free }
                    // Keep user-created alarms on existing events. This writer adds none.
                    try store.save(event, span: .thisEvent, commit: false)
                    staged = true
                    if operation.existingID == nil { result.added += 1 } else { result.updated += 1 }
                } else { result.skipped += 1 }
                written.append((task, event, span.start))
            }
            if staged {
                try Task.checkCancellation()
                guard try resolve().calendarIdentifier == checkpoint.target else { throw CalendarSyncFailure.ambiguous }
                try store.commit()
            }
            for item in written {
                guard let id = item.event.eventIdentifier, !id.isEmpty else { throw CalendarSyncFailure.invalidHistory }
                next.known[item.task.key] = CalendarEventReference(id: id, date: item.date)
                next.pending.removeValue(forKey: item.task.key)
            }
        } catch {
            store.reset()
            if let safe = error as? CalendarSyncFailure { throw safe }
            if let safe = error as? SafeError { throw safe }
            throw SafeError("未能完成专用日历写入。请检查账户、权限和网络后重试。")
        }
        return (result, next)
    }
}
