import Foundation

struct NativeCollectedSnapshot {
    let scope: SourceScope
    let accountFingerprint: String
    let candidates: [NativeDeadlineTask]
    let courseCount: Int
}

@MainActor final class NativeReadContext {
    private let session: NativeSessionReading
    private let account: String
    // Start/end identity probes reserve two reads; each source request reserves its identity probe too.
    private var remaining = 1198
    private let platform: NativePlatform
    private let registry: NativeAdapterRegistry
    init(_ session: NativeSessionReading, _ account: String, platform: NativePlatform, registry: NativeAdapterRegistry) {
        self.session = session; self.account = account; self.platform = platform; self.registry = registry
    }
    func fetch(_ request: NativeWebReadRequest) async throws -> Data {
        try Task.checkCancellation()
        try NativeWebPolicy.validate(request, platform: platform, registry: registry)
        guard remaining >= 2 else { throw NativeSessionError.budgetExceeded }
        remaining -= 2
        let data = try await session.read(request, expectedAccount: account)
        try Task.checkCancellation()
        guard data.count <= 8 * 1024 * 1024 else { throw NativeSessionError.budgetExceeded }
        return data
    }
}

@MainActor enum NativeTaskCollector {
    static func collect(scope: SourceScope, expectedAccount: String, session: NativeSessionReading, registry: NativeAdapterRegistry = .production) async throws -> NativeCollectedSnapshot {
        do {
            try Task.checkCancellation()
            guard let adapter = registry.adapter(for: scope.platform),
                  scope.host == adapter.descriptor.verifiedHost, NativeWebPolicy.validFingerprint(expectedAccount) else { throw NativeSessionError.unsafeRequest }
            guard try await session.verifyAccount() == expectedAccount else { throw NativeSessionError.accountChanged }
            try Task.checkCancellation()
            let reads = NativeReadContext(session, expectedAccount, platform: scope.platform, registry: registry)
            let result = try await adapter.collect(scope: scope, reads: reads)
            let candidates = result.candidates, courseCount = result.courseCount
            guard (0...500).contains(courseCount) else { throw NativeSessionError.budgetExceeded }
            _ = try NativeTaskSelection.select(candidates)
            guard candidates.allSatisfy({ $0.identity.scope == scope }) else { throw NativeSessionError.invalidResponse }
            guard try await session.verifyAccount() == expectedAccount else { throw NativeSessionError.accountChanged }
            try Task.checkCancellation()
            return NativeCollectedSnapshot(scope: scope, accountFingerprint: expectedAccount, candidates: candidates, courseCount: courseCount)
        } catch {
            session.cancel()
            if error is CancellationError { throw NativeSessionError.cancelled }
            if let known = error as? NativeSessionError { throw known }
            // Parser and server text is deliberately not exposed to a UI/log caller.
            throw NativeSessionError.invalidResponse
        }
    }
}
