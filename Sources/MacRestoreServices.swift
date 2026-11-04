import Foundation
import Security
import ServiceManagement

// This adapter reads only the new versioned nonsecret metadata. Legacy source,
// syncEnabled, and Keychain services are intentionally never queried.
@MainActor final class MacRestartSettings: RestartSettings {
    static let key = "restartRestore.v1.metadata"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> RestartMetadata? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(RestartMetadata.self, from: data)
    }
    func save(_ value: RestartMetadata?) {
        if let value, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.key) }
        else { defaults.removeObject(forKey: Self.key) }
    }
}

@MainActor final class MacRestartVault: RestartVault {
    // A separate namespace means old consent and old items cannot be reused.
    private nonisolated static let service = "org.duebridge.community.restart.v1"
    private nonisolated static let account = "calendarFeed"
    private nonisolated static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
    private nonisolated static func failure(_ status: OSStatus) -> RestoreFailure {
        switch status {
        case errSecItemNotFound: return .missing
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed: return .denied
        default: return .unavailable
        }
    }
    func read(interactive: Bool) async throws -> String {
        // SecItemCopyMatching can block. Never run it on the UI actor; background
        // startup explicitly forbids OS authentication UI. Only the recovery
        // button enters the interactive path after new consent exists.
        try await Task.detached(priority: .utility) {
            var query = Self.query()
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecUseAuthenticationUI as String] = interactive ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess else { throw Self.failure(status) }
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw RestoreFailure.invalid }
            return value
        }.value
    }
    func save(_ value: String) async throws {
        try await Task.detached(priority: .utility) {
            var query = Self.query()
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIAllow
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
            if status == errSecItemNotFound {
                var item = Self.query()
                item[kSecValueData as String] = Data(value.utf8)
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                let added = SecItemAdd(item as CFDictionary, nil)
                guard added == errSecSuccess else { throw Self.failure(added) }
            } else if status != errSecSuccess {
                // Permission failures must never erase/recreate an existing item.
                throw Self.failure(status)
            }
        }.value
    }
}

@MainActor final class MacRestartLogin: RestartLogin {
    func status() -> LoginAvailability {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }
    func register() throws -> LoginAvailability {
        try SMAppService.mainApp.register()
        return status()
    }
    func unregister() async throws { try await SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor final class DailySyncScheduler: SyncScheduling {
    private var timer: Timer?
    func schedule(at date: Date, action: @escaping () -> Void) {
        cancel()
        let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
            Task { @MainActor in action() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func cancel() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }
}

extension SyncServices {
    @MainActor static func live(gate: ReminderWriteGate? = nil, scheduler: SyncScheduling? = nil, readGate: SourceReadGate? = nil) -> SyncServices {
        var writer: ReminderWriter?
        func client() -> ReminderWriter {
            if let writer { return writer }
            let created = ReminderWriter(); writer = created; return created
        }
        return SyncServices(fetch: { address in
                                if let readGate { return try await readGate.withPermit { try await FeedFetcher.fetch(address) } }
                                return try await FeedFetcher.fetch(address)
                            },
                            requestAccess: { try await client().requestAccess() },
                            authorized: { ReminderWriter.authorized },
                            reconcile: { feed, courses, shouldContinue in
                                if let gate {
                                    return try await gate.withPermit(shouldContinue: shouldContinue) {
                                        try await client().reconcile(feed, courseNames: courses, shouldContinue: shouldContinue)
                                    }
                                }
                                return try await client().reconcile(feed, courseNames: courses, shouldContinue: shouldContinue)
                            },
                            now: Date.init,
                            loadCourses: { CourseAssignments.validated(UserDefaults.standard.dictionary(forKey: CourseAssignments.settingsKey) ?? [:]) },
                            saveCourses: { UserDefaults.standard.set($0, forKey: CourseAssignments.settingsKey) },
                            scheduler: scheduler ?? DailySyncScheduler())
    }
}
extension RestartRestore {
    @MainActor static func live(login: RestartLogin? = nil) -> RestartRestore {
        RestartRestore(settings: MacRestartSettings(), vault: MacRestartVault(), login: login ?? MacRestartLogin())
    }
}
