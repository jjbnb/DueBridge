import Foundation
import EventKit

struct NativeWriteResult {
    let result: SyncResult
    let knownHashes: Set<String>
}

/// Value-only policies also exercised without constructing an EventKit store.
enum NativeReminderWritePolicy {
    static func dueComponents(for deadline: Deadline) -> DateComponents {
        var result = deadline.components
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = deadline.timeZone
        result.calendar = calendar
        result.timeZone = deadline.timeZone
        if deadline.isAllDay {
            result.hour = nil; result.minute = nil
            result.second = nil; result.nanosecond = nil
        }
        return result
    }
    static func shouldRemoveAlarm(absoluteDate: Date?, hasLocation: Bool, previousToolAlarmDate: Date?) -> Bool {
        guard let previousToolAlarmDate else { return false }
        return !hasLocation && absoluteDate == previousToolAlarmDate
    }
    static func validateCurrent(original: NativeReminderSnapshot, current: NativeReminderSnapshot?) throws {
        guard let current, current.calendarItemID == original.calendarItemID,
              current.marker == original.marker else { throw NativeReminderWriteFailure.changed }
        // Completion, personal notes and due dates may change while verification
        // awaits. The planner must consume the current snapshot below.
    }
    static func knownHashes(scope: SourceScope, history: NativeTaskHistory, recognized: [NativeReminderSnapshot], saved: [NativeReminderOperation]) throws -> Set<String> {
        guard history.scope == scope, history.knownHashes.allSatisfy(NativeTaskNotes.isCanonicalHash),
              saved.allSatisfy({ $0.identity.scope == scope }) else { throw NativeSyncError.invalidHistory }
        let visible = recognized.compactMap { item -> String? in
            guard let marker = item.marker, marker.scope == scope else { return nil }
            return marker.hash
        }
        return history.knownHashes.union(visible).union(saved.map { $0.identity.stableHash })
    }
}

private enum NativeReminderWriteFailure: Error {
    case permission, destination, fetch, binding, changed, paused
    var message: String {
        switch self {
        case .permission: return "提醒事项权限未开启；请在系统设置中允许完整访问后重试。"
        case .destination: return "原同步列表不可用或不可写；请在“同步列表”中选择现有列表或创建新列表。"
        case .fetch: return "无法完整读取原同步列表；此次未写入提醒事项，请稍后重试。"
        case .binding: return "无法确认当前账号绑定；此次未写入提醒事项，请重新登录并读取后重试。"
        case .changed: return "原提醒事项或同步列表已改变；此次未写入，请检查原列表后重试。"
        case .paused: return "同步已暂停或来源已改变；此次未写入提醒事项。"
        }
    }
}

/// The fetch callback and its timeout/cancellation converge on one actor-owned
/// continuation. Cancellation never relies on EventKit calling its completion.
@MainActor private final class NativeReminderFetch {
    private let store: EKEventStore
    private let predicate: NSPredicate
    private var continuation: CheckedContinuation<[EKReminder], Error>?
    private var token: Any?
    private var timeout: Task<Void, Never>?
    private var settled = false
    init(store: EKEventStore, predicate: NSPredicate) { self.store = store; self.predicate = predicate }
    func run() async throws -> [EKReminder] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                token = store.fetchReminders(matching: predicate) { values in
                    Task { @MainActor in
                        if let values { self.finish(.success(values), cancelFetch: false) }
                        else { self.finish(.failure(NativeReminderWriteFailure.fetch), cancelFetch: false) }
                    }
                }
                timeout = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                    catch { return }
                    self.finish(.failure(NativeReminderWriteFailure.fetch), cancelFetch: true)
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError()), cancelFetch: true) }
        }
    }
    private func finish(_ result: Result<[EKReminder], Error>, cancelFetch: Bool) {
        guard !settled else { return }
        settled = true
        if cancelFetch, let token { store.cancelFetchRequest(token) }
        timeout?.cancel(); timeout = nil; token = nil
        let callback = continuation; continuation = nil
        callback?.resume(with: result)
    }
}

@MainActor final class NativeReminderWriter {
    private let store = EKEventStore()
    private let gate: ReminderWriteGate
    private let defaults: UserDefaults
    private lazy var destinations = ReminderDestinationService.live(defaults: defaults, store: store)
    init(gate: ReminderWriteGate, defaults: UserDefaults = .standard) { self.gate = gate; self.defaults = defaults }
    static var authorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    func requestAccess() async throws {
        if Self.authorized { return }
        do {
            let allowed = try await store.requestFullAccessToReminders()
            try Task.checkCancellation()
            guard allowed, Self.authorized else { throw NativeReminderWriteFailure.permission }
        } catch is CancellationError { throw CancellationError() }
        catch { throw SafeError(NativeReminderWriteFailure.permission.message) }
    }
    func reconcile(scope: SourceScope, candidates: [NativeDeadlineTask], history: NativeTaskHistory,
                   verifyBinding: @escaping () async throws -> Void,
                   shouldContinue: @escaping () -> Bool) async throws -> NativeWriteResult {
        try await gate.withPermit(shouldContinue: shouldContinue) {
            // Only the permit owner may reset, resolve a destination, or fetch.
            self.store.reset()
            defer { self.store.reset() }
            do {
                try self.validate(shouldContinue)
                self.store.refreshSourcesIfNecessary()
                let destinationSelection = self.destinations.selection()
                let (calendarID, _) = try self.destination(expected: destinationSelection)
                try await self.verify(verifyBinding)
                try self.validate(shouldContinue)
                let (_, calendar) = try self.destination(expected: destinationSelection, expectedID: calendarID)
                let fetch = NativeReminderFetch(store: self.store, predicate: self.store.predicateForReminders(in: [calendar]))
                let values = try await fetch.run()
                try self.validate(shouldContinue)
                let fetched = try values.map { try self.snapshot($0, calendarID: calendarID) }
                // Validate the complete fetched snapshot before another suspension.
                _ = try NativeTaskPlanner.plan(scope: scope, candidates: candidates, existing: fetched, history: history, now: Date(), localTimeZone: .current)
                try await self.verify(verifyBinding)
                try self.validate(shouldContinue)

                // Forget fetched objects, then obtain current local-database values
                // after the final async account check. No await follows this point.
                self.store.reset()
                let (_, currentCalendar) = try self.destination(expected: destinationSelection, expectedID: calendarID)
                var current = [NativeReminderSnapshot]()
                var byID = [String: EKReminder]()
                for original in fetched {
                    guard let reminder = self.store.calendarItem(withIdentifier: original.calendarItemID) as? EKReminder else {
                        throw NativeReminderWriteFailure.changed
                    }
                    let latest = try self.snapshot(reminder, calendarID: calendarID)
                    try NativeReminderWritePolicy.validateCurrent(original: original, current: latest)
                    current.append(latest)
                    byID[latest.calendarItemID] = reminder
                }
                let plan = try NativeTaskPlanner.plan(scope: scope, candidates: candidates, existing: current, history: history, now: Date(), localTimeZone: .current)
                let known = try NativeReminderWritePolicy.knownHashes(scope: scope, history: history, recognized: current, saved: plan.operations)
                try self.validate(shouldContinue)
                for operation in plan.operations {
                    try self.validate(shouldContinue)
                    let reminder: EKReminder
                    if let id = operation.existingID {
                        guard let existing = byID[id], existing.calendarItemIdentifier == id,
                              existing.calendar?.calendarIdentifier == calendarID else { throw NativeReminderWriteFailure.changed }
                        reminder = existing
                    } else {
                        reminder = EKReminder(eventStore: self.store)
                        reminder.calendar = currentCalendar
                    }
                    reminder.title = operation.title
                    reminder.notes = operation.notes
                    reminder.dueDateComponents = NativeReminderWritePolicy.dueComponents(for: operation.deadline)
                    for alarm in reminder.alarms ?? [] where NativeReminderWritePolicy.shouldRemoveAlarm(absoluteDate: alarm.absoluteDate, hasLocation: alarm.structuredLocation != nil, previousToolAlarmDate: operation.previousToolAlarmDate) {
                        reminder.removeAlarm(alarm)
                    }
                    if !reminder.isCompleted, let next = operation.nextToolAlarmDate {
                        reminder.addAlarm(EKAlarm(absoluteDate: next))
                    }
                    // Never assign isCompleted/completionDate or delete a reminder.
                    try self.store.save(reminder, commit: false)
                }
                try self.validate(shouldContinue)
                _ = try self.destination(expected: destinationSelection, expectedID: calendarID)
                if !plan.operations.isEmpty { try self.store.commit() }
                return NativeWriteResult(result: SyncResult(added: plan.added, updated: plan.updated, skipped: plan.skippedPast, warnings: plan.warnings), knownHashes: known)
            } catch is CancellationError { throw CancellationError() }
            catch let failure as NativeReminderWriteFailure { throw SafeError(failure.message) }
            catch let failure as ReminderDestinationError { throw SafeError(failure.message) }
            catch is NativeSyncError { throw SafeError("无法安全识别原同步事项；此次未写入，请检查原列表和管理备注后重试。") }
            catch is NativeTaskError { throw SafeError("来源事项的身份或截止时间不一致；此次未写入，请重新读取后重试。") }
            catch { throw SafeError("保存提醒事项失败；请检查原列表和账户后重试。") }
        }
    }
    private func validate(_ shouldContinue: () -> Bool) throws {
        try Task.checkCancellation()
        guard shouldContinue() else { throw NativeReminderWriteFailure.paused }
        guard Self.authorized else { throw NativeReminderWriteFailure.permission }
    }
    private func verify(_ binding: () async throws -> Void) async throws {
        do { try await binding() }
        catch is CancellationError { throw CancellationError() }
        catch { throw NativeReminderWriteFailure.binding }
    }
    private func destination(expected: ReminderDestinationSelection, expectedID: String? = nil) throws -> (String, EKCalendar) {
        let target = try destinations.resolve(expected: expected)
        guard expectedID == nil || expectedID == target.id else { throw ReminderDestinationError.changed }
        guard let calendar = store.calendar(withIdentifier: target.id), calendar.calendarIdentifier == target.id,
              calendar.allowedEntityTypes.contains(.reminder), calendar.allowsContentModifications else {
            throw ReminderDestinationError.missing
        }
        return (target.id, calendar)
    }
    private func snapshot(_ reminder: EKReminder, calendarID: String) throws -> NativeReminderSnapshot {
        guard !reminder.calendarItemIdentifier.isEmpty, reminder.calendar?.calendarIdentifier == calendarID else {
            throw NativeReminderWriteFailure.changed
        }
        let parts = reminder.dueDateComponents
        var calendar = parts?.calendar ?? Calendar(identifier: .gregorian)
        calendar.timeZone = parts?.timeZone ?? .current
        return try NativeReminderSnapshot(calendarItemID: reminder.calendarItemIdentifier, isCompleted: reminder.isCompleted, notes: reminder.notes ?? "", dueDate: parts.flatMap { calendar.date(from: $0) })
    }
}
