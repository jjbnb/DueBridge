import Foundation
import CryptoKit

// Stable persisted identity; registration, rather than an enum case, grants support.
struct NativePlatform: RawRepresentable, Hashable {
    let rawValue: String
    init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 64,
              rawValue.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        self.rawValue = rawValue
    }
    static let mo = NativePlatform(rawValue: "mo")!
    static let learningInZJU = NativePlatform(rawValue: "learningInZJU")!
    var verifiedHost: String { SourceRegistry.production.descriptor(for: self)?.verifiedHost ?? "" }
}
enum NativeTaskKind: String { case homework, quiz, exam, practice }
enum NativeTaskError: Error {
    case unverifiedHost
    case invalidIdentifier
    case invalidDeadline
    case conflictingSnapshots
}

struct SourceScope: Equatable {
    let platform: NativePlatform
    let host: String
    let connectionID: UUID
    init(platform: NativePlatform, host: String, connectionID: UUID, registry: SourceRegistry = .production) throws {
        guard let registered = registry.descriptor(for: platform)?.verifiedHost, host == registered else { throw NativeTaskError.unverifiedHost }
        self.platform = platform; self.host = host; self.connectionID = connectionID
    }
}
struct NativeTaskIdentity: Hashable {
    let scope: SourceScope
    let courseID: String
    let kind: NativeTaskKind
    let taskID: String
    init(scope: SourceScope, courseID: String, kind: NativeTaskKind, taskID: String) throws {
        for field in [courseID, taskID] {
            guard !field.isEmpty, field.utf8.count <= 1024,
                  !field.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw NativeTaskError.invalidIdentifier
            }
        }
        self.scope = scope; self.courseID = courseID; self.kind = kind; self.taskID = taskID
    }

    // v1: each field is an unsigned 64-bit big-endian UTF-8 byte length, then bytes.
    // Domain/version and every scope field participate; snapshot content never does.
    private var canonicalEncoding: Data {
        let fields = ["bb-ddl/native-task-identity", "1", scope.platform.rawValue, scope.host,
                      scope.connectionID.uuidString.lowercased(), courseID, kind.rawValue, taskID]
        var encoding = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { encoding.append(contentsOf: $0) }
            encoding.append(bytes)
        }
        return encoding
    }
    var stableHash: String {
        SHA256.hash(data: canonicalEncoding).map { String(format: "%02x", $0) }.joined()
    }
    // Swift String equality folds canonical Unicode equivalents; native opaque IDs do not.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.canonicalEncoding == rhs.canonicalEncoding }
    func hash(into hasher: inout Hasher) { hasher.combine(canonicalEncoding) }
}
struct NativeDeadlineTask: Equatable {
    let identity: NativeTaskIdentity
    let courseName: String
    let title: String
    let deadline: Deadline?
    init(identity: NativeTaskIdentity, courseName: String, title: String, deadline: Deadline?) throws {
        if let deadline { try Self.validate(deadline) }
        self.identity = identity; self.courseName = courseName; self.title = title; self.deadline = deadline
    }

    private static func validate(_ deadline: Deadline) throws {
        guard deadline.date.timeIntervalSince1970.isFinite, deadline.date.timeIntervalSince1970 >= 0 else {
            throw NativeTaskError.invalidDeadline
        }
        let parts = deadline.components
        guard parts.year != nil, parts.month != nil, parts.day != nil,
              parts.timeZone == nil || parts.timeZone == deadline.timeZone,
              parts.calendar == nil || parts.calendar?.timeZone == deadline.timeZone else {
            throw NativeTaskError.invalidDeadline
        }
        var calendar = parts.calendar ?? Calendar(identifier: .gregorian)
        calendar.timeZone = deadline.timeZone
        let civilFields: Set<Calendar.Component> = [.era, .year, .month, .day, .weekday,
            .weekdayOrdinal, .quarter, .weekOfMonth, .weekOfYear, .yearForWeekOfYear]
        let actual = calendar.dateComponents(civilFields.union([.hour, .minute, .second, .nanosecond]), from: deadline.date)
        for field in civilFields {
            if let supplied = parts.value(for: field), supplied != actual.value(for: field) {
                throw NativeTaskError.invalidDeadline
            }
        }
        if let leapMonth = parts.isLeapMonth, leapMonth != actual.isLeapMonth {
            throw NativeTaskError.invalidDeadline
        }
        if deadline.isAllDay {
            guard deadline.date == calendar.startOfDay(for: deadline.date),
                  [parts.hour, parts.minute, parts.second, parts.nanosecond].allSatisfy({ $0 == nil || $0 == 0 }) else {
                throw NativeTaskError.invalidDeadline
            }
        } else {
            guard let hour = parts.hour, let minute = parts.minute,
                  hour == actual.hour, minute == actual.minute,
                  (parts.second ?? 0) == actual.second,
                  (parts.nanosecond ?? 0) == actual.nanosecond else {
                throw NativeTaskError.invalidDeadline
            }
        }
    }
}
struct NativeTaskSelection {
    let tasks: [NativeDeadlineTask]
    let skippedWithoutDeadline: Int
    static func select(_ candidates: [NativeDeadlineTask]) throws -> NativeTaskSelection {
        var unique = [NativeTaskIdentity: NativeDeadlineTask]()
        for candidate in candidates {
            if let previous = unique[candidate.identity], previous != candidate {
                throw NativeTaskError.conflictingSnapshots
            }
            unique[candidate.identity] = candidate
        }
        let tasks = unique.values.filter { $0.deadline != nil }.sorted {
            let left = $0.deadline!.date, right = $1.deadline!.date
            return left == right ? $0.identity.stableHash < $1.identity.stableHash : left < right
        }
        return NativeTaskSelection(tasks: tasks, skippedWithoutDeadline: unique.count - tasks.count)
    }
}
