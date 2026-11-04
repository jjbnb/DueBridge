import Foundation
import EventKit
import Combine

struct ReminderDestinationList: Identifiable, Equatable {
    let id: String
    let title: String
    let account: String
    let isWritable: Bool
    var isReminder: Bool = true
}

enum ReminderDestinationError: Error, Equatable, LocalizedError {
    case permission, notConfigured, invalidIdentifier, missing, readOnly, changed
    case invalidName, noAccount, creationFailed, ambiguous
    var message: String {
        switch self {
        case .permission: return "提醒事项权限未开启；请允许完整访问后重试。"
        case .notConfigured: return "尚未选择同步列表；请在“同步列表”中选择现有列表或创建新列表。"
        case .invalidIdentifier: return "保存的同步列表记录无效；请在“同步列表”中重新选择。"
        case .missing: return "原同步列表已消失或不再可用；请在“同步列表”中明确重新选择，未改选其他列表。"
        case .readOnly: return "原同步列表不可写；请检查列表权限，或在“同步列表”中明确重新选择。"
        case .changed: return "同步列表已改变；此次未写入提醒事项，请重新同步。"
        case .invalidName: return "请输入新列表的名称。"
        case .noAccount: return "没有可用的提醒事项账户；请先在苹果提醒事项中添加账户或创建列表。"
        case .creationFailed: return "无法创建提醒事项列表；原同步列表设置已保留，请检查账户后重试。"
        case .ambiguous: return "发现重复的列表标识，无法安全选择同步列表。"
        }
    }
    var errorDescription: String? { message }
}

/// A revision distinguishes an A → B → A change from an unchanged destination.
/// Existing installations need only the legacy calendarID; no migration is needed.
struct ReminderDestinationSelection: Equatable {
    enum Identifier: Equatable { case unset, saved(String), invalid }
    let identifier: Identifier
    let revision: String?
}

enum ReminderDestinationBBImportPolicy {
    static func previouslySynced(selection: ReminderDestinationSelection, hasHashCheckpoint: Bool, legacyHint: Bool) -> Bool {
        if hasHashCheckpoint || legacyHint { return true }
        return shouldPreserveLegacyImport(selection)
    }
    static func shouldPreserveLegacyImport(_ selection: ReminderDestinationSelection) -> Bool {
        if case .saved = selection.identifier { return selection.revision == nil }
        return false
    }
}

@MainActor struct ReminderDestinationStorage {
    let readID: () -> Any?
    let readRevision: () -> String?
    let save: (String, String) -> Void
    var preserveLegacyImport: () -> Void = {}
    func selection() -> ReminderDestinationSelection {
        let identifier: ReminderDestinationSelection.Identifier
        if let raw = readID() {
            if let id = raw as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                identifier = .saved(id)
            } else { identifier = .invalid }
        } else { identifier = .unset }
        return ReminderDestinationSelection(identifier: identifier, revision: readRevision())
    }
    func persist(_ id: String, revision: String, previous: ReminderDestinationSelection) {
        if ReminderDestinationBBImportPolicy.shouldPreserveLegacyImport(previous) { preserveLegacyImport() }
        save(id, revision)
    }
    static func userDefaults(_ defaults: UserDefaults?) -> Self {
        Self(readID: { (defaults ?? .standard).object(forKey: "calendarID") },
             readRevision: { (defaults ?? .standard).string(forKey: "reminderDestinationRevision") },
             save: { id, revision in
                 let defaults = defaults ?? .standard
                 defaults.set(id, forKey: "calendarID")
                 defaults.set(revision, forKey: "reminderDestinationRevision")
             }, preserveLegacyImport: { (defaults ?? .standard).set(true, forKey: "bbLegacyImportEvidence") })
    }
}

/// All OS access is behind closures so the selection contract is testable with
/// value-only lists and storage. Construction does not enumerate or authorize.
@MainActor struct ReminderDestinationBackend {
    let authorized: () -> Bool
    let requestAccess: () async throws -> Void
    let lists: () throws -> [ReminderDestinationList]
    let create: (String) throws -> ReminderDestinationList
}

@MainActor final class ReminderDestinationService {
    private let storage: ReminderDestinationStorage
    private let backend: ReminderDestinationBackend
    init(storage: ReminderDestinationStorage, backend: ReminderDestinationBackend) {
        self.storage = storage; self.backend = backend
    }
    func selection() -> ReminderDestinationSelection { storage.selection() }
    func requestAccess() async throws {
        if !backend.authorized() { try await backend.requestAccess() }
        try Task.checkCancellation()
        guard backend.authorized() else { throw ReminderDestinationError.permission }
    }
    func writableLists() throws -> [ReminderDestinationList] {
        try allLists().filter { $0.isReminder && $0.isWritable }
    }
    func resolve(expected: ReminderDestinationSelection? = nil) throws -> ReminderDestinationList {
        let original = selection()
        if let expected, original != expected { throw ReminderDestinationError.changed }
        let id: String
        switch original.identifier {
        case .unset: throw ReminderDestinationError.notConfigured
        case .invalid: throw ReminderDestinationError.invalidIdentifier
        case .saved(let saved): id = saved
        }
        let list = try writableList(id)
        guard selection() == original else { throw ReminderDestinationError.changed }
        return list
    }
    @discardableResult func select(id: String) throws -> ReminderDestinationList {
        let original = selection()
        let list = try writableList(id)
        guard selection() == original else { throw ReminderDestinationError.changed }
        storage.persist(list.id, revision: UUID().uuidString, previous: original)
        return list
    }
    @discardableResult func create(named rawName: String) throws -> ReminderDestinationList {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ReminderDestinationError.invalidName }
        guard backend.authorized() else { throw ReminderDestinationError.permission }
        let original = selection()
        let list = try backend.create(name)
        guard !list.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, list.isReminder else {
            throw ReminderDestinationError.invalidIdentifier
        }
        guard list.isWritable else { throw ReminderDestinationError.readOnly }
        guard selection() == original else { throw ReminderDestinationError.changed }
        storage.persist(list.id, revision: UUID().uuidString, previous: original)
        return list
    }
    /// Called after every suspension and immediately before a writer commits.
    /// An unset selection is accepted only for BB's existing first-run fallback.
    func validate(_ original: ReminderDestinationSelection, calendarID: String) throws {
        guard selection() == original else { throw ReminderDestinationError.changed }
        switch original.identifier {
        case .invalid: throw ReminderDestinationError.invalidIdentifier
        case .saved(let id): guard id == calendarID else { throw ReminderDestinationError.changed }
        case .unset: break
        }
        _ = try writableList(calendarID)
        guard selection() == original else { throw ReminderDestinationError.changed }
    }
    /// BB may stage a new legacy list that is not yet visible to enumeration.
    func validateUnchanged(_ original: ReminderDestinationSelection) throws {
        guard backend.authorized() else { throw ReminderDestinationError.permission }
        guard selection() == original else { throw ReminderDestinationError.changed }
        guard original.identifier != .invalid else { throw ReminderDestinationError.invalidIdentifier }
    }
    private func allLists() throws -> [ReminderDestinationList] {
        guard backend.authorized() else { throw ReminderDestinationError.permission }
        let values = try backend.lists()
        guard Set(values.map(\.id)).count == values.count else { throw ReminderDestinationError.ambiguous }
        return values
    }
    private func writableList(_ id: String) throws -> ReminderDestinationList {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReminderDestinationError.invalidIdentifier }
        guard let list = try allLists().first(where: { $0.id == id && $0.isReminder }) else { throw ReminderDestinationError.missing }
        guard list.isWritable else { throw ReminderDestinationError.readOnly }
        return list
    }
    static func live(defaults: UserDefaults? = nil, store: EKEventStore? = nil) -> ReminderDestinationService {
        let access = EventKitReminderDestinationAccess(store: store)
        let backend = ReminderDestinationBackend(
            authorized: { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess },
            requestAccess: {
                do {
                    guard try await access.store().requestFullAccessToReminders() else { throw ReminderDestinationError.permission }
                } catch { throw ReminderDestinationError.permission }
            }, lists: {
                // Writers refresh their own store before staging. Do not refresh
                // it again while validating an uncommitted transaction.
                if store == nil { access.store().refreshSourcesIfNecessary() }
                return access.store().calendars(for: .reminder).map(EventKitReminderDestinationAccess.describe)
            }, create: { name in
                let store = access.store()
                store.refreshSourcesIfNecessary()
                let calendar = EKCalendar(for: .reminder, eventStore: store)
                calendar.title = name
                if let source = store.defaultCalendarForNewReminders()?.source { calendar.source = source }
                else if let source = store.calendars(for: .reminder).first(where: { $0.allowsContentModifications })?.source { calendar.source = source }
                else if let source = store.sources.first(where: { $0.sourceType == .local }) { calendar.source = source }
                else { throw ReminderDestinationError.noAccount }
                do { try store.saveCalendar(calendar, commit: true) }
                catch { store.reset(); throw ReminderDestinationError.creationFailed }
                return EventKitReminderDestinationAccess.describe(calendar)
            })
        return ReminderDestinationService(storage: .userDefaults(defaults), backend: backend)
    }
}

@MainActor private final class EventKitReminderDestinationAccess {
    private var value: EKEventStore?
    init(store: EKEventStore?) { value = store }
    func store() -> EKEventStore {
        if let value { return value }
        let created = EKEventStore(); value = created; return created
    }
    static func describe(_ calendar: EKCalendar) -> ReminderDestinationList {
        ReminderDestinationList(id: calendar.calendarIdentifier, title: calendar.title,
                                account: calendar.source?.title ?? "提醒事项", isWritable: calendar.allowsContentModifications,
                                isReminder: calendar.allowedEntityTypes.contains(.reminder))
    }
}

@MainActor final class ReminderDestinationModel: ObservableObject {
    @Published private(set) var lists = [ReminderDestinationList]()
    @Published private(set) var currentID: String?
    @Published private(set) var currentTitle: String?
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var status = "所有来源共用一个提醒事项列表。请选择现有可写列表，或明确创建新列表；无需先连接 BB。"
    private let service: ReminderDestinationService
    init(service: ReminderDestinationService? = nil) {
        self.service = service ?? .live()
    }
    func refresh(busy: Bool) async {
        guard !busy, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            try await service.requestAccess()
            lists = try service.writableLists()
            loaded = true
            currentID = nil; currentTitle = nil
            do {
                let current = try service.resolve()
                currentID = current.id; currentTitle = current.title
                status = "当前同步列表：\(current.title)。已有同步记录会继续接受防重复校验。"
            } catch { status = message(error) }
            if lists.isEmpty {
                status += " 当前没有可写列表；可以创建新列表，或先在苹果提醒事项中配置账户。"
            }
        } catch { status = message(error) }
    }
    func select(id: String, busy: Bool) {
        guard !busy, !loading, loaded else { return }
        do { show(try service.select(id: id)) }
        catch { status = message(error) }
    }
    func create(named name: String, busy: Bool) {
        guard !busy, !loading, loaded else { return }
        do {
            let list = try service.create(named: name)
            lists.removeAll { $0.id == list.id }
            lists.append(list)
            show(list)
        } catch { status = message(error) }
    }
    private func show(_ list: ReminderDestinationList) {
        currentID = list.id; currentTitle = list.title
        status = "已选择同步列表：\(list.title)。已有同步记录会继续接受防重复校验。"
    }
    private func message(_ error: Error) -> String {
        if let failure = error as? ReminderDestinationError { return failure.message }
        if error is CancellationError { return "此次列表读取已取消；原同步列表设置已保留。" }
        return "无法读取提醒事项列表；原同步列表设置已保留，请检查权限和账户后重试。"
    }
}
