import Foundation

enum NativeSyncError: Error {
    case malformedNotes, occupiedNotes, invalidURL, invalidHistory, wrongScope
    case duplicateReminders, missingKnownReminders, suspectedIdentityChange
}

struct NativeNoteMarker: Equatable {
    let scope: SourceScope
    let hash: String
    let alarmDate: Date?
}

enum NativeTaskNotes {
    private static let begin = "[ZJU-COURSE-TASK"
    private static let end = "[/ZJU-COURSE-TASK]"
    static func isCanonicalHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func label(_ platform: NativePlatform, registry: SourceRegistry) throws -> String {
        guard let label = registry.descriptor(for: platform)?.noteLabel else { throw NativeSyncError.malformedNotes }
        return label
    }
    private static func safeURL(_ url: URL, scope: SourceScope) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let decoded = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        return parts.scheme == "https" && parts.host == scope.host && parts.percentEncodedHost == scope.host &&
            parts.user == nil && parts.password == nil && parts.fragment == nil &&
            (parts.port == nil || parts.port == 443) &&
            !decoded.contains("[BB-DDL-SYNC") && !decoded.contains(begin) && !decoded.contains("[/ZJU-COURSE-TASK") &&
            !decoded.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private static func parsed(_ notes: String, registry: SourceRegistry) throws -> (NativeNoteMarker, Range<String.Index>)? {
        let begins = notes.components(separatedBy: begin).count - 1
        let ends = notes.components(separatedBy: "[/ZJU-COURSE-TASK").count - 1
        if begins == 0 && ends == 0 { return nil }
        guard begins == 1, ends == 1, let start = notes.range(of: begin),
              let finish = notes.range(of: end), start.lowerBound < finish.lowerBound else { throw NativeSyncError.malformedNotes }
        let span = start.lowerBound..<finish.upperBound
        let lines = String(notes[span]).components(separatedBy: "\n")
        let pattern = #"\A\[ZJU-COURSE-TASK v1 source=([A-Za-z0-9_-]{1,64}) scope=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}) uid=([0-9a-f]{64})\]\z"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let header = lines.first, let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else { throw NativeSyncError.malformedNotes }
        func field(_ index: Int) -> String { String(header[Range(match.range(at: index), in: header)!]) }
        guard let platform = NativePlatform(rawValue: field(1)), let descriptor = registry.descriptor(for: platform),
              let host = descriptor.verifiedHost, let uuid = UUID(uuidString: field(2)),
              lines.last == end, lines.count == 4 || lines.count == 5 else { throw NativeSyncError.malformedNotes }
        let scope = try SourceScope(platform: platform, host: host, connectionID: uuid, registry: registry)
        var body = Array(lines.dropFirst().dropLast())
        var alarm: Date?
        if body.first?.hasPrefix("alarm=") == true {
            guard let epoch = Double(body.removeFirst().dropFirst(6)), epoch.isFinite, epoch >= 0 else { throw NativeSyncError.malformedNotes }
            alarm = Date(timeIntervalSince1970: epoch)
        }
        guard body.count == 2, body[0] == "platform=\(try label(platform, registry: registry))", body[1].hasPrefix("url="),
              let url = URL(string: String(body[1].dropFirst(4))), safeURL(url, scope: scope) else { throw NativeSyncError.malformedNotes }
        return (NativeNoteMarker(scope: scope, hash: field(3), alarmDate: alarm), span)
    }
    static func marker(in notes: String, registry: SourceRegistry = .production) throws -> NativeNoteMarker? { try parsed(notes, registry: registry)?.0 }
    static func replacing(in notes: String, scope: SourceScope, hash: String, alarmDate: Date?, landingURL: URL? = nil, registry: SourceRegistry = .production) throws -> String {
        guard registry.descriptor(for: scope.platform)?.verifiedHost == scope.host else { throw NativeSyncError.wrongScope }
        guard isCanonicalHash(hash), alarmDate.map({ $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 >= 0 }) ?? true else { throw NativeSyncError.malformedNotes }
        let url = landingURL ?? URL(string: "https://\(scope.host)/")!
        guard safeURL(url, scope: scope) else { throw NativeSyncError.invalidURL }
        let old = try parsed(notes, registry: registry)
        if let old, old.0.scope != scope || old.0.hash != hash { throw NativeSyncError.occupiedNotes }
        var lines = ["\(begin) v1 source=\(scope.platform.rawValue) scope=\(scope.connectionID.uuidString.lowercased()) uid=\(hash)]"]
        if let alarmDate { lines.append("alarm=\(alarmDate.timeIntervalSince1970)") }
        lines += ["platform=\(try label(scope.platform, registry: registry))", "url=\(url.absoluteString)", end]
        let block = lines.joined(separator: "\n")
        if let old { var result = notes; result.replaceSubrange(old.1, with: block); return result }
        return notes + (notes.isEmpty || notes.hasSuffix("\n") ? "" : "\n") + block
    }
}

struct NativeReminderSnapshot: Equatable {
    let calendarItemID: String
    let marker: NativeNoteMarker?
    let isCompleted: Bool
    let notes: String
    let dueDate: Date?
    init(calendarItemID: String, isCompleted: Bool, notes: String, dueDate: Date?) throws {
        self.calendarItemID = calendarItemID; self.isCompleted = isCompleted
        self.notes = notes; self.dueDate = dueDate
        self.marker = try NativeTaskNotes.marker(in: notes)
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.calendarItemID == rhs.calendarItemID && lhs.marker == rhs.marker &&
            lhs.isCompleted == rhs.isCompleted && lhs.dueDate == rhs.dueDate &&
            lhs.notes.utf8.elementsEqual(rhs.notes.utf8)
    }
}
struct NativeTaskHistory {
    let scope: SourceScope
    let knownHashes: Set<String>
    let hasImported: Bool
}
struct NativeReminderOperation {
    let identity: NativeTaskIdentity
    let existingID: String?
    let title: String
    let notes: String
    let deadline: Deadline
    let previousToolAlarmDate: Date?
    let nextToolAlarmDate: Date?
}
struct NativeReminderPlan {
    let operations: [NativeReminderOperation]
    let added: Int
    let updated: Int
    let skippedPast: Int
    let skippedWithoutDeadline: Int
    let warnings: [String]
}
enum NativeTaskPlanner {
    static func plan(scope: SourceScope, candidates: [NativeDeadlineTask], existing: [NativeReminderSnapshot], history: NativeTaskHistory, now: Date, localTimeZone: TimeZone, registry: SourceRegistry = .production) throws -> NativeReminderPlan {
        guard history.scope == scope, candidates.allSatisfy({ $0.identity.scope == scope }) else { throw NativeSyncError.wrongScope }
        guard history.knownHashes.allSatisfy(NativeTaskNotes.isCanonicalHash) else { throw NativeSyncError.invalidHistory }
        // Validate shared identity semantics before filtering out undated/past tasks.
        let selection = try NativeTaskSelection.select(candidates)
        let requested = Set(candidates.map { $0.identity.stableHash })
        var byHash = [String: NativeReminderSnapshot]()
        var byID = [String: NativeReminderSnapshot]()
        for reminder in existing {
            guard let marker = reminder.marker, marker.scope == scope else { continue }
            if let previous = byID[reminder.calendarItemID], previous != reminder { throw NativeSyncError.duplicateReminders }
            if let previous = byHash[marker.hash], previous.calendarItemID != reminder.calendarItemID { throw NativeSyncError.duplicateReminders }
            byID[reminder.calendarItemID] = reminder
            byHash[marker.hash] = reminder
        }
        let recognized = Set(byHash.keys)
        if history.hasImported && !history.knownHashes.subtracting(recognized).isEmpty { throw NativeSyncError.missingKnownReminders }
        if history.hasImported && !requested.isEmpty && !history.knownHashes.isEmpty && requested.isDisjoint(with: history.knownHashes) { throw NativeSyncError.suspectedIdentityChange }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = localTimeZone
        let today = calendar.startOfDay(for: now)
        var operations = [NativeReminderOperation](), skippedPast = 0
        for task in selection.tasks {
            let hash = task.identity.stableHash
            let old = byHash[hash]
            let deadline = task.deadline!
            if old == nil {
                let isPast: Bool
                if deadline.isAllDay {
                    var parts = deadline.components; parts.timeZone = localTimeZone; parts.calendar = calendar
                    isPast = (calendar.date(from: parts) ?? .distantPast) < today
                } else { isPast = deadline.date < today }
                if isPast { skippedPast += 1; continue }
            }
            let completed = old?.isCompleted ?? false
            let alarm = completed ? nil : deadline.date
            // This wrapper is presentation-only; never sent to BB identity/planning.
            let event = FeedEvent(uid: "", title: task.title, details: "", deadline: deadline, sequence: 0, modified: nil, cancelled: false)
            let title = CoursePresentation.reminderTitle(for: event, isCompleted: completed, now: now, courseName: task.courseName)
            let notes = try NativeTaskNotes.replacing(in: old?.notes ?? "", scope: scope, hash: hash, alarmDate: alarm, registry: registry)
            operations.append(NativeReminderOperation(identity: task.identity, existingID: old?.calendarItemID, title: title, notes: notes, deadline: deadline, previousToolAlarmDate: old?.marker?.alarmDate, nextToolAlarmDate: alarm))
        }
        var warnings = [String]()
        if selection.skippedWithoutDeadline > 0 { warnings.append("无截止时间的事项已跳过，原提醒事项保持不变。") }
        if !recognized.subtracting(requested).isEmpty { warnings.append("来源中已消失的事项保持不变。") }
        return NativeReminderPlan(operations: operations, added: operations.filter { $0.existingID == nil }.count, updated: operations.filter { $0.existingID != nil }.count, skippedPast: skippedPast, skippedWithoutDeadline: selection.skippedWithoutDeadline, warnings: warnings)
    }
}
