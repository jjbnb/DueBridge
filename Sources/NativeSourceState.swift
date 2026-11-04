import Foundation

enum NativeStateError: Error { case invalidState }
struct NativeConnectionState: Codable {
    var id = UUID()
    var accountFingerprint: String
    var desiredEnabled = false
    var restoreEnabled = false
    var knownHashes = Set<String>()
    var hasImported = false
    var lastSuccess: Date?
    var retry: RetryCheckpoint?
    var blocked = false
    mutating func recordFailure(network: Bool, now: Date) {
        normalize(now: now)
        if network {
            blocked = false
            let count = retry?.count ?? 0
            let delays: [TimeInterval] = [60, 300, 900]
            retry = RetryCheckpoint(cycle: DailySchedule.midnight(for: now), count: min(count + 1, 3),
                                    deadline: count < 3 ? now.addingTimeInterval(delays[count]) : nil)
        } else { blocked = true; retry = nil }
    }
    mutating func recordSuccess(hashes: Set<String>, now: Date) {
        knownHashes = hashes; hasImported = true; lastSuccess = now; retry = nil; blocked = false
    }
    private mutating func normalize(now: Date) {
        if let lastSuccess, !lastSuccess.timeIntervalSince1970.isFinite || lastSuccess < Date(timeIntervalSince1970: 0) || lastSuccess > now { self.lastSuccess = nil }
        if let retry, retry.cycle != DailySchedule.midnight(for: now) || !(1...3).contains(retry.count) ||
            retry.deadline.map({ !$0.timeIntervalSince1970.isFinite || $0 < retry.cycle || $0 > now.addingTimeInterval(900) }) ?? (retry.count != 3) { self.retry = nil }
    }
    mutating func automaticDue(now: Date) -> Bool {
        normalize(now: now)
        guard desiredEnabled, !blocked else { return false }
        if let retry { return retry.deadline.map { now >= $0 } ?? false }
        return DailySchedule.needsCatchUp(lastSuccess: lastSuccess, now: now)
    }
    mutating func nextCheck(now: Date) -> Date? {
        normalize(now: now)
        guard desiredEnabled, !blocked else { return nil }
        let midnight = DailySchedule.nextMidnight(after: now)
        if let deadline = retry?.deadline, deadline > now { return min(midnight, deadline) }
        return midnight
    }
}
struct NativePlatformState: Codable {
    var version = 1
    var storeID = UUID()
    var activeID: UUID?
    var connections = [NativeConnectionState]()
    var active: NativeConnectionState? { connections.first { $0.id == activeID } }
    mutating func connect(fingerprint: String) throws -> NativeConnectionState {
        guard Self.hash(fingerprint) else { throw NativeStateError.invalidState }
        _ = try validated()
        let target = connections.firstIndex { $0.accountFingerprint == fingerprint }
        if target == nil && connections.count >= 50 { throw NativeStateError.invalidState }
        for index in connections.indices where connections[index].id != target.map({ connections[$0].id }) {
            connections[index].desiredEnabled = false; connections[index].restoreEnabled = false
            connections[index].retry = nil
        }
        if let target { activeID = connections[target].id; return connections[target] }
        let added = NativeConnectionState(accountFingerprint: fingerprint)
        connections.append(added); activeID = added.id
        return added
    }
    mutating func update(_ value: NativeConnectionState) throws {
        guard let index = connections.firstIndex(where: { $0.id == value.id }), connections[index].accountFingerprint == value.accountFingerprint else { throw NativeStateError.invalidState }
        var updated = self; updated.connections[index] = value
        self = try updated.validated()
    }
    private static func hash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func validated() throws -> Self {
        guard version == 1, connections.count <= 50,
              Set(connections.map(\.id)).count == connections.count,
              Set(connections.map(\.accountFingerprint)).count == connections.count,
              activeID == nil || connections.contains(where: { $0.id == activeID }) else { throw NativeStateError.invalidState }
        for c in connections {
            guard Self.hash(c.accountFingerprint), c.knownHashes.count <= 100_000,
                  c.knownHashes.allSatisfy(Self.hash), c.hasImported || c.knownHashes.isEmpty,
                  c.id == activeID || (!c.desiredEnabled && !c.restoreEnabled) else { throw NativeStateError.invalidState }
            if let last = c.lastSuccess, !last.timeIntervalSince1970.isFinite || last.timeIntervalSince1970 < 0 { throw NativeStateError.invalidState }
            if let r = c.retry {
                guard (1...3).contains(r.count), r.cycle.timeIntervalSince1970.isFinite, r.cycle.timeIntervalSince1970 >= 0,
                      r.deadline.map({ $0.timeIntervalSince1970.isFinite && $0 >= r.cycle }) ?? (r.count == 3) else { throw NativeStateError.invalidState }
            }
        }
        return self
    }
}
@MainActor final class NativeStateStore {
    private let read: (String) -> Data?
    private let write: (String, Data) -> Void
    init(read: @escaping (String) -> Data?, write: @escaping (String, Data) -> Void) { self.read = read; self.write = write }
    private func key(_ platform: NativePlatform) -> String { "nativeCourses.v1." + platform.rawValue }
    func load(_ platform: NativePlatform) throws -> NativePlatformState? {
        guard let data = read(key(platform)) else { return nil }
        guard data.count <= 16 * 1024 * 1024 else { throw NativeStateError.invalidState }
        do { return try JSONDecoder().decode(NativePlatformState.self, from: data).validated() }
        catch { throw NativeStateError.invalidState }
    }
    func save(_ value: NativePlatformState, for platform: NativePlatform) throws {
        let data = try JSONEncoder().encode(value.validated())
        guard data.count <= 16 * 1024 * 1024 else { throw NativeStateError.invalidState }
        write(key(platform), data)
    }
}
