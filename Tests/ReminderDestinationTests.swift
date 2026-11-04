// Synthetic fixtures only; public school domains test exact request policies.
import Foundation

@MainActor private final class DestinationFixture {
    var storedID: Any?
    var revision: String?
    var legacyImportHint = false
    var reads = 0
    var writes = 0
    var authorized = true
    var lists = [
        ReminderDestinationList(id: "list-a", title: "Original", account: "Synthetic", isWritable: true),
        ReminderDestinationList(id: "list-b", title: "Other", account: "Synthetic", isWritable: true),
        ReminderDestinationList(id: "locked", title: "Read only", account: "Synthetic", isWritable: false)
    ]
    var createError: Error?
    var afterCreate: (() -> Void)?
    var onLists: (() -> Void)?
    var createdNames = [String]()
    lazy var service = ReminderDestinationService(storage: ReminderDestinationStorage(
        readID: { self.reads += 1; return self.storedID }, readRevision: { self.revision },
        save: { self.storedID = $0; self.revision = $1; self.writes += 1 },
        preserveLegacyImport: { self.legacyImportHint = true }),
        backend: ReminderDestinationBackend(authorized: { self.authorized }, requestAccess: {},
            lists: { self.onLists?(); return self.lists }, create: { name in
                if let error = self.createError { throw error }
                self.createdNames.append(name)
                let created = ReminderDestinationList(id: "new-list", title: name, account: "Synthetic", isWritable: true)
                self.lists.append(created)
                self.afterCreate?()
                return created
            }))
}

@main struct ReminderDestinationTests {
    static var checks = 0
    @MainActor static func check(_ value: @autoclosure () throws -> Bool, _ message: String) {
        checks += 1
        do { if try !value() { print("FAIL: \(message)"); exit(1) } }
        catch { print("FAIL: \(message): \(error)"); exit(1) }
    }
    @MainActor static func rejects(_ expected: ReminderDestinationError, _ message: String, _ body: () throws -> Void) {
        do { try body(); check(false, message) }
        catch { check((error as? ReminderDestinationError) == expected, message) }
    }
    @MainActor static func main() async throws {
        let fresh = DestinationFixture()
        _ = fresh.service
        check(fresh.reads == 0, "service construction never reads persisted settings or EventKit")
        rejects(.notConfigured, "native-only first run explicitly requires a target") { _ = try fresh.service.resolve() }
        check(try fresh.service.writableLists().map(\.id) == ["list-a", "list-b"], "only writable reminder lists can be selected")
        _ = try fresh.service.select(id: "list-b")
        check(fresh.storedID as? String == "list-b" && fresh.writes == 1, "explicit selection persists the shared calendar ID without BB")
        check(try fresh.service.resolve().title == "Other", "native writer resolves explicitly selected target")
        fresh.lists[1] = ReminderDestinationList(id: "list-b", title: "Renamed", account: "Synthetic", isWritable: true)
        check(try fresh.service.resolve().title == "Renamed", "renaming selected list retains its persistent identity")
        rejects(.readOnly, "read-only selection is rejected") { _ = try fresh.service.select(id: "locked") }
        rejects(.missing, "missing selection is rejected") { _ = try fresh.service.select(id: "deleted") }
        check(fresh.storedID as? String == "list-b" && fresh.writes == 1, "invalid selection retains prior saved ID")
        fresh.lists.removeAll { $0.id == "list-b" }
        rejects(.missing, "deleted saved target cannot fall back to a different writable list") { _ = try fresh.service.resolve() }
        check(fresh.storedID as? String == "list-b", "deleted target failure preserves its ID for recovery")
        fresh.storedID = "locked"
        rejects(.readOnly, "saved read-only target cannot fall back") { _ = try fresh.service.resolve() }
        for invalid in ["", "  ", 42] as [Any] {
            fresh.storedID = invalid
            rejects(.invalidIdentifier, "malformed saved target fails closed") { _ = try fresh.service.resolve() }
        }
        fresh.authorized = false
        rejects(.permission, "enumeration requires reminder authorization") { _ = try fresh.service.writableLists() }

        let unusual = DestinationFixture()
        unusual.storedID = "list-a"
        unusual.lists[0].isReminder = false
        rejects(.missing, "a saved non-reminder calendar is unavailable") { _ = try unusual.service.resolve() }
        check(try unusual.service.writableLists().map(\.id) == ["list-b"], "non-reminder calendars cannot appear in setup choices")
        unusual.lists.append(unusual.lists[1])
        rejects(.ambiguous, "duplicate calendar identifiers fail closed") { _ = try unusual.service.writableLists() }

        let create = DestinationFixture()
        rejects(.invalidName, "blank list creation does not write") { _ = try create.service.create(named: " \n ") }
        check(create.writes == 0 && create.createdNames.isEmpty, "invalid name creates no list or persisted state")
        let new = try create.service.create(named: "  DueBridge tasks  ")
        check(new.id == "new-list" && new.title == "DueBridge tasks", "explicit create uses chosen trimmed name")
        check(create.storedID as? String == "new-list" && create.writes == 1, "newly created list becomes shared saved destination")
        create.createError = ReminderDestinationError.noAccount
        rejects(.noAccount, "unavailable account is explained") { _ = try create.service.create(named: "Another") }
        check(create.storedID as? String == "new-list" && create.writes == 1, "creation failure retains saved ID")

        let transaction = DestinationFixture()
        _ = try transaction.service.select(id: "list-a")
        let token = transaction.service.selection()
        var commits = 0
        _ = try transaction.service.select(id: "list-b")
        rejects(.changed, "native destination resolution rejects a changed stored selection") { _ = try transaction.service.resolve(expected: token) }
        rejects(.changed, "target changed while fetching cannot commit to old list") {
            try transaction.service.validate(token, calendarID: "list-a")
            commits += 1
        }
        _ = try transaction.service.select(id: "list-a")
        rejects(.changed, "A to B to A target change still invalidates in-flight transaction") {
            try transaction.service.validate(token, calendarID: "list-a")
            commits += 1
        }
        check(commits == 0, "changed target never reaches commit boundary")
        rejects(.changed, "saved destination cannot validate a different calendar ID") { try transaction.service.validate(transaction.service.selection(), calendarID: "list-b") }
        let current = transaction.service.selection()
        transaction.lists.removeAll { $0.id == "list-a" }
        rejects(.missing, "list deleted during fetch fails final validation") { try transaction.service.validate(current, calendarID: "list-a") }
        let racingRead = DestinationFixture()
        racingRead.storedID = "list-a"
        racingRead.onLists = { racingRead.storedID = "list-b"; racingRead.revision = "changed-during-query" }
        rejects(.changed, "destination changed during lookup is not returned as a writable target") { _ = try racingRead.service.resolve() }
        check(racingRead.storedID as? String == "list-b" && racingRead.writes == 0, "lookup never overwrites the newer selection")
        let racingCreate = DestinationFixture()
        racingCreate.afterCreate = { racingCreate.storedID = "list-b"; racingCreate.revision = "concurrent-choice" }
        rejects(.changed, "create cannot overwrite a concurrent target change") { _ = try racingCreate.service.create(named: "Explicit") }
        check(racingCreate.storedID as? String == "list-b" && racingCreate.writes == 0, "concurrent selection is retained")

        let ui = DestinationFixture()
        let model = ReminderDestinationModel(service: ui.service)
        check(ui.reads == 0 && model.lists.isEmpty, "settings model construction performs no reads or permission requests")
        await model.refresh(busy: true)
        check(ui.reads == 0, "settings enumeration stays idle during sync")
        await model.refresh(busy: false)
        check(model.lists.map(\.id) == ["list-a", "list-b"] && model.currentID == nil, "native-only setup loads writable choices before selection")
        model.select(id: "list-a", busy: true)
        model.create(named: "Blocked", busy: true)
        check(ui.writes == 0 && ui.createdNames.isEmpty, "busy settings cannot change or create a destination")
        model.select(id: "list-a", busy: false)
        check(ui.storedID as? String == "list-a" && model.currentID == "list-a", "settings selection persists and updates visible target")
        model.create(named: "Chosen list", busy: false)
        check(ui.storedID as? String == "new-list" && model.currentID == "new-list", "settings create works without a BB source")
        ui.lists.removeAll { $0.id == "new-list" }
        await model.refresh(busy: false)
        check(ui.storedID as? String == "new-list" && model.currentID == nil && model.status.contains("消失"), "missing selected list is shown clearly while retaining saved ID")

        let firstBB = DestinationFixture()
        _ = try firstBB.service.select(id: "list-a")
        check(!ReminderDestinationBBImportPolicy.previouslySynced(selection: firstBB.service.selection(), hasHashCheckpoint: false, legacyHint: firstBB.legacyImportHint), "explicit fresh target setup is not evidence of a prior BB import")
        let oldestBB = DestinationFixture()
        oldestBB.storedID = "list-a"
        check(ReminderDestinationBBImportPolicy.previouslySynced(selection: oldestBB.service.selection(), hasHashCheckpoint: false, legacyHint: false), "legacy ID-only installation retains BB import protection")
        _ = try oldestBB.service.select(id: "list-b")
        check(oldestBB.legacyImportHint, "first explicit target selection preserves legacy ID-only import evidence")
        check(ReminderDestinationBBImportPolicy.previouslySynced(selection: oldestBB.service.selection(), hasHashCheckpoint: false, legacyHint: oldestBB.legacyImportHint), "adding a selection revision never removes legacy import protection")
        check(ReminderDestinationBBImportPolicy.previouslySynced(selection: firstBB.service.selection(), hasHashCheckpoint: true, legacyHint: false), "existing BB hash checkpoint protects an explicitly changed empty target")
        let oldestCreate = DestinationFixture()
        oldestCreate.storedID = "list-a"
        _ = try oldestCreate.service.create(named: "Replacement")
        check(oldestCreate.legacyImportHint, "explicit create preserves old BB import evidence too")

        let legacy = DestinationFixture()
        let legacyToken = legacy.service.selection()
        try legacy.service.validate(legacyToken, calendarID: "list-a")
        try legacy.service.validateUnchanged(legacyToken)
        legacy.authorized = false
        rejects(.permission, "permission revoked before staging a new BB list blocks commit") { try legacy.service.validateUnchanged(legacyToken) }
        legacy.authorized = true
        check(legacy.writes == 0, "BB legacy validation permits an unsaved target without auto-selecting it")
        _ = try legacy.service.select(id: "list-b")
        rejects(.changed, "BB legacy unsaved write cannot commit after explicit target setup") { try legacy.service.validate(legacyToken, calendarID: "list-a") }
        print("ReminderDestinationTests: \(checks) checks passed (synthetic storage and list backend; no EventKit store created)")
    }
}
