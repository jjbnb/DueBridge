import Foundation

/// Local course labels are keyed only by the already-verified anonymous BB identity.
enum CourseAssignments {
    static let settingsKey = "courseNamesByStableUIDV1"

    static func key(for event: FeedEvent) -> String? {
        guard FeedIdentity.stableKey(uid: event.uid) != nil else { return nil }
        return ManagedNotes.marker(uid: event.uid)
    }

    static func normalizedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        guard !name.isEmpty, name.rangeOfCharacter(from: forbidden) == nil else { return nil }
        return name
    }

    static func name(for event: FeedEvent, in assignments: [String: String]) -> String? {
        guard let key = key(for: event), let raw = assignments[key] else { return nil }
        return normalizedName(raw)
    }

    /// Validate saved data without reading any other setting or persisting raw identifiers.
    static func validated(_ values: [String: Any]) -> [String: String] {
        var result = [String: String]()
        for (key, value) in values {
            guard key.utf8.count == 64,
                  key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let raw = value as? String, let name = normalizedName(raw) else { continue }
            result[key] = name
        }
        return result
    }
}

enum CoursePresentation {
    static func reminderTitle(for event: FeedEvent, isCompleted: Bool, now: Date, courseName: String?) -> String {
        let name = courseName.flatMap(CourseAssignments.normalizedName) ?? "课程待确认"
        return "【\(name)】" + CountdownPresentation.reminderTitle(for: event, isCompleted: isCompleted, now: now)
    }
}
