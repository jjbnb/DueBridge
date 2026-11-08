import Foundation
import CryptoKit

struct NetworkFailure: Error {}
enum RestoreFailure: Error { case missing, denied, unavailable, invalid }
enum LoginAvailability: Equatable { case enabled, requiresApproval, notRegistered, notFound }
struct RetryCheckpoint: Codable, Equatable {
    var cycle: Date
    var count: Int
    var deadline: Date?
}
struct RestartMetadata: Codable {
    var version = 1
    var fingerprint: String
    var desiredEnabled: Bool
    var lastSuccess: Date?
    var retry: RetryCheckpoint?
    var blockedDay: Date?
    var remindersConfigured: Bool?
    var calendarScopeFingerprint: String?
}
@MainActor protocol RestartSettings {
    func load() -> RestartMetadata?
    func save(_ value: RestartMetadata?)
}
@MainActor protocol RestartVault {
    func read(interactive: Bool) async throws -> String
    func save(_ value: String) async throws
}
@MainActor protocol RestartLogin {
    func status() -> LoginAvailability
    func register() throws -> LoginAvailability
    func unregister() async throws
    func openSettings()
}
@MainActor protocol SyncScheduling {
    func schedule(at date: Date, action: @escaping () -> Void)
    func cancel()
}
@MainActor struct SyncServices {
    var fetch: (String) async throws -> Feed
    var requestAccess: () async throws -> Void
    var authorized: () -> Bool
    var reconcile: (Feed, [String: String], @escaping () -> Bool) async throws -> SyncResult
    var now: () -> Date
    var loadCourses: () -> [String: String]
    var saveCourses: ([String: String]) -> Void
    var scheduler: SyncScheduling
}
@MainActor final class RestartRestore {
    let settings: RestartSettings
    let vault: RestartVault
    let login: RestartLogin
    private(set) var metadata: RestartMetadata?
    var configured: Bool { metadata != nil }
    init(settings: RestartSettings, vault: RestartVault, login: RestartLogin) {
        self.settings = settings; self.vault = vault; self.login = login
        if let record = settings.load(), record.version == 1,
           record.fingerprint.count == 64,
           record.fingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
            metadata = record
        }
    }
    nonisolated static func fingerprint(_ address: String) -> String {
        SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func persist() { settings.save(metadata) }
    func setIntent(_ enabled: Bool) {
        guard metadata != nil else { return }
        metadata?.desiredEnabled = enabled
        if enabled { metadata?.remindersConfigured = true }
        else { metadata?.retry = nil }
        persist()
    }
    func configure(address: String, lastSuccess: Date?, retry: RetryCheckpoint? = nil, blockedDay: Date? = nil,
                   desiredEnabled: Bool = true, remindersConfigured: Bool? = nil, calendarScopeFingerprint: String? = nil) {
        metadata = RestartMetadata(fingerprint: Self.fingerprint(address), desiredEnabled: desiredEnabled, lastSuccess: lastSuccess,
                                   retry: retry, blockedDay: blockedDay, remindersConfigured: remindersConfigured,
                                   calendarScopeFingerprint: calendarScopeFingerprint)
        persist()
    }
    func setCalendarScopeFingerprint(_ fingerprint: String, address: String) {
        guard metadata?.fingerprint == Self.fingerprint(address), metadata?.calendarScopeFingerprint != fingerprint else { return }
        metadata?.calendarScopeFingerprint = fingerprint
        persist()
    }
    func disable() { metadata = nil; persist() }
    func validatedSuccess(address: String, now: Date) -> Date? {
        guard let record = metadata, record.fingerprint == Self.fingerprint(address),
              let date = record.lastSuccess, Self.valid(date, now: now) else { return nil }
        return date
    }
    nonisolated private static func valid(_ date: Date, now: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && date.timeIntervalSince1970 >= 0 && date <= now
    }
    nonisolated static func validSuccessDate(_ date: Date?, now: Date) -> Date? {
        guard let date, valid(date, now: now) else { return nil }
        return date
    }
    func automaticAllowed(address: String, lastSuccess: Date?, now: Date) -> Bool {
        // A clock correction can invalidate a live controller's checkpoint as
        // well as the persisted copy. Validate before applying same-day dedup.
        normalize(now: now)
        guard DailySchedule.needsCatchUp(lastSuccess: Self.validSuccessDate(lastSuccess, now: now), now: now) else { return false }
        guard metadata?.fingerprint == Self.fingerprint(address) else { return true }
        guard metadata?.blockedDay == nil else { return false }
        guard let retry = metadata?.retry else { return true }
        return retry.deadline.map { now >= $0 } ?? false
    }
    func nextCheck(now: Date) -> Date {
        normalize(now: now)
        let midnight = DailySchedule.nextMidnight(after: now)
        guard let retry = metadata?.retry, let deadline = retry.deadline, deadline > now else { return midnight }
        return min(midnight, deadline)
    }
    private func normalize(now: Date) {
        guard var record = metadata else { return }
        var changed = false
        if let date = record.lastSuccess, !Self.valid(date, now: now) { record.lastSuccess = nil; changed = true }
        if let date = record.blockedDay, !Self.valid(date, now: now) { record.blockedDay = nil; changed = true }
        if let retry = record.retry {
            let validCycle = retry.cycle == DailySchedule.midnight(for: now)
            let validCount = (1...3).contains(retry.count)
            let validDeadline = retry.deadline.map {
                $0.timeIntervalSince1970.isFinite && $0 >= retry.cycle && $0 <= now.addingTimeInterval(900)
            } ?? (retry.count == 3)
            if !validCycle || !validCount || !validDeadline { record.retry = nil; changed = true }
        }
        if changed { metadata = record; persist() }
    }
    func recordSuccess(address: String, now: Date) {
        guard metadata?.fingerprint == Self.fingerprint(address) else { return }
        metadata?.lastSuccess = now; metadata?.retry = nil; metadata?.blockedDay = nil; persist()
    }
    func recordFailure(address: String, network: Bool, now: Date) {
        guard metadata?.fingerprint == Self.fingerprint(address) else { return }
        normalize(now: now)
        if network {
            metadata?.blockedDay = nil
            let count = metadata?.retry?.count ?? 0
            let delays: [TimeInterval] = [60, 300, 900]
            metadata?.retry = RetryCheckpoint(cycle: DailySchedule.midnight(for: now), count: min(count + 1, 3),
                                               deadline: count < 3 ? now.addingTimeInterval(delays[count]) : nil)
        } else { metadata?.retry = nil; metadata?.blockedDay = now }
        persist()
    }
}
