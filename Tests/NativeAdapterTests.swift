// Synthetic fixtures only; public school domains test exact request policies.
import Foundation

private struct FixtureAdapter: NativePlatformAdapter {
    let descriptor: SourceDescriptor
    var authentication: NativeAuthenticationConfiguration {
        NativeAuthenticationConfiguration(loginTitle: "Fixture", loginURL: URL(string: "https://fixture.example/")!, backgroundURL: URL(string: "https://fixture.example/robots.txt")!, interactiveHosts: [], scriptObject: #"{headers(body){return {};},async identity(read){return 'fixture';},checkIdentity(expected){}}"#)
    }
    func validate(_ request: NativeWebReadRequest) throws {
        guard request.method == "GET", request.body == nil, request.url.absoluteString == "https://fixture.example/tasks" else { throw NativeSessionError.unsafeRequest }
    }
    @MainActor func collect(scope: SourceScope, reads: NativeReadContext) async throws -> NativeAdapterCollection {
        let bytes = try await reads.fetch(NativeWebReadRequest(method: "GET", url: URL(string: "https://fixture.example/tasks")!, body: nil))
        guard bytes == Data("complete fixture".utf8) else { throw NativeSessionError.invalidResponse }
        let identity = try NativeTaskIdentity(scope: scope, courseID: "synthetic-course", kind: .homework, taskID: "synthetic-task")
        let deadline = try NativeDeadlineParser.parse("2026-11-05T15:59:00Z", naiveTimeZone: TimeZone(secondsFromGMT: 0)!)
        return NativeAdapterCollection(candidates: [try NativeDeadlineTask(identity: identity, courseName: "Fixture", title: "Synthetic task", deadline: deadline)], courseCount: 1)
    }
}
@MainActor private final class AdapterFixtureSession: NativeSessionReading {
    var probes = 0, reads = 0, cancelled = false
    var fingerprints = [String]()
    let account = String(repeating: "a", count: 64)
    func verifyAccount() async throws -> String { probes += 1; return fingerprints.isEmpty ? account : fingerprints.removeFirst() }
    func read(_ request: NativeWebReadRequest, expectedAccount: String) async throws -> Data {
        guard expectedAccount == account else { throw NativeSessionError.accountChanged }
        reads += 1; return Data("complete fixture".utf8)
    }
    func cancel() { cancelled = true }
}
@main struct NativeAdapterTests {
    enum Failure: Error { case assertion(String) }
    @MainActor static var checks = 0
    @MainActor static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        checks += 1; if try !value() { throw Failure.assertion(label) }
    }
    @MainActor static func rejects(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }; throw Failure.assertion(label)
    }
    @MainActor static func main() async throws {
        let production = SourceRegistry.production
        try check(production.descriptors.map(\.stableID) == ["bb", "mo", "learningInZJU"], "production registry has three reviewed sources in display order")
        try check(production.descriptor(for: "xzzd") == .learningInZJU, "legacy runtime alias resolves stable source")
        try check(production.nativeDescriptors.map(\.runtimeSlot) == ["mo", "xzzd"], "native runtime aliases remain stable")
        try check(production.descriptor(for: "bb")?.nativePlatform == nil, "BB uses legacy facade")
        try check(production.descriptor(for: "missing") == nil, "unknown source does not acquire a fallback")
        try rejects("duplicate native identities reject") { _ = try SourceRegistry(descriptors: [.mo, .mo]) }
        let collision = SourceDescriptor(stableID: "fixture", displayName: "Fixture", icon: "book", runtimeSlot: "fixture", aliases: ["xzzd"], nativePlatform: nil, verifiedHost: nil, noteLabel: nil)
        try rejects("alias collisions reject") { _ = try SourceRegistry(descriptors: [.learningInZJU, collision]) }
        try rejects("missing native adapter rejects") { _ = try NativeAdapterRegistry(adapters: [MoPlatformAdapter()], sources: production) }
        try rejects("duplicate native adapters reject") { _ = try NativeAdapterRegistry(adapters: [MoPlatformAdapter(), MoPlatformAdapter(), LearningInZJUPlatformAdapter()], sources: production) }

        let unknown = NativePlatform(rawValue: "unregistered")!
        let connection = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        try rejects("unregistered source cannot mint a scope") { _ = try SourceScope(platform: unknown, host: "courses.zju.edu.cn", connectionID: connection) }
        try rejects("unregistered source cannot fingerprint an account") { _ = try NativeWebPolicy.fingerprint("opaque", platform: unknown) }
        try check(!NativeWebPolicy.navigationAllowed(URL(string: "https://courses.zju.edu.cn/")!, platform: unknown, interactive: true), "unknown source cannot inherit xzzd navigation")
        try rejects("unknown source cannot read xzzd endpoint") { try NativeWebPolicy.validate(NativeWebReadRequest(try XzzdReadRequest.courses(page: 1)), platform: unknown) }

        let fixture = NativePlatform(rawValue: "fixture")!
        let descriptor = SourceDescriptor(stableID: fixture.rawValue, displayName: "Synthetic fourth source", icon: "testtube.2", runtimeSlot: "fixture", aliases: [], nativePlatform: fixture, verifiedHost: "fixture.example", noteLabel: "Fixture")
        let sources = try SourceRegistry(descriptors: production.descriptors + [descriptor])
        let registry = try NativeAdapterRegistry(adapters: [MoPlatformAdapter(), LearningInZJUPlatformAdapter(), FixtureAdapter(descriptor: descriptor)], sources: sources)
        let scope = try SourceScope(platform: fixture, host: "fixture.example", connectionID: connection, registry: sources)
        let session = AdapterFixtureSession()
        let result = try await NativeTaskCollector.collect(scope: scope, expectedAccount: session.account, session: session, registry: registry)
        try check(result.courseCount == 1 && result.candidates.count == 1 && session.probes == 2 && session.reads == 1, "fourth adapter traverses bounded collector without core dispatch changes")
        try check(result.scope == scope && result.accountFingerprint == session.account, "fourth snapshot remains account scoped")
        let plan = try NativeTaskPlanner.plan(scope: scope, candidates: result.candidates, existing: [], history: NativeTaskHistory(scope: scope, knownHashes: [], hasImported: false), now: Date(timeIntervalSince1970: 0), localTimeZone: TimeZone(secondsFromGMT: 0)!, registry: sources)
        try check(plan.added == 1 && plan.operations[0].notes.contains("source=fixture"), "fourth adapter uses shared planner and notes")
        try check(try NativeTaskNotes.marker(in: plan.operations[0].notes, registry: sources)?.scope == scope, "registered fourth marker round trips")
        try check(try NativeTaskNotes.replacing(in: plan.operations[0].notes, scope: scope, hash: result.candidates[0].identity.stableHash, alarmDate: plan.operations[0].nextToolAlarmDate, registry: sources) == plan.operations[0].notes, "registered fourth marker reimport preserves bytes")
        try rejects("production rejects test-only fourth markers") { _ = try NativeTaskNotes.marker(in: plan.operations[0].notes) }
        try rejects("fourth source cannot read production endpoint") { try NativeWebPolicy.validate(NativeWebReadRequest(try XzzdReadRequest.courses(page: 1)), platform: fixture, registry: registry) }
        try rejects("production source cannot read fourth endpoint") { try NativeWebPolicy.validate(NativeWebReadRequest(method: "GET", url: URL(string: "https://fixture.example/tasks")!, body: nil), platform: .mo, registry: registry) }
        try check(!NativeWebPolicy.navigationAllowed(URL(string: "https://zjuam.zju.edu.cn/")!, platform: fixture, interactive: true, registry: registry), "SSO is adapter specific")
        let changed = AdapterFixtureSession(); changed.fingerprints = [changed.account, String(repeating: "b", count: 64)]
        do {
            _ = try await NativeTaskCollector.collect(scope: scope, expectedAccount: changed.account, session: changed, registry: registry)
            throw Failure.assertion("account change must reject fourth snapshot")
        } catch NativeSessionError.accountChanged { try check(changed.cancelled, "failed fourth collection cancels session") }

        let moScope = try SourceScope(platform: .mo, host: "mo.zju.edu.cn", connectionID: connection)
        let id = try NativeTaskIdentity(scope: moScope, courseID: "course-1", kind: .homework, taskID: "task-1")
        try check(try NativeWebPolicy.fingerprint("opaque", platform: .mo) == "71f1ffc6510661bb5f0bfc458157826f92bfc307e69cbc37b1f2fc58558687f2", "legacy account fingerprint bytes remain fixed")
        try check(id.stableHash == "3a2539f94b00d46d01693c6614716048bd39c5bc589ffae2e7fc778fec650f78", "legacy v1 identity bytes remain fixed")
        let notes = try NativeTaskNotes.replacing(in: "个人笔记\n", scope: moScope, hash: id.stableHash, alarmDate: nil)
        let expected = "个人笔记\n[ZJU-COURSE-TASK v1 source=mo scope=11111111-1111-1111-1111-111111111111 uid=3a2539f94b00d46d01693c6614716048bd39c5bc589ffae2e7fc778fec650f78]\nplatform=MO\nurl=https://mo.zju.edu.cn/\n[/ZJU-COURSE-TASK]"
        try check(notes == expected, "legacy notes bytes remain fixed")
        try check(try NativeTaskNotes.replacing(in: expected, scope: moScope, hash: id.stableHash, alarmDate: nil) == expected, "existing marker remains byte identical")
        try check(!NativeWebScript.source.contains("platform === 'mo'"), "shared transport has no source-specific fallback")
        try check(NativeWebScript.source(registry: registry).contains("fixture.example"), "fourth authentication registered in fixed transport")
        if let path = ProcessInfo.processInfo.environment["NATIVE_SCRIPT_OUTPUT"] {
            try NativeWebScript.source.write(toFile: path, atomically: true, encoding: .utf8)
        }
        print("PASS: \(checks) static adapter registry/compatibility checks (synthetic fourth source only)")
    }
}
