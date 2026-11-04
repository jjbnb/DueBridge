// Synthetic fixtures only; public school domains test exact request policies.
import Foundation

@MainActor final class FixtureSession: NativeSessionReading {
    var identity = String(repeating: "a", count: 64)
    var identities = [String]()
    var requests = [NativeWebReadRequest]()
    var response: (NativeWebReadRequest, Int) throws -> Data
    init(_ response: @escaping (NativeWebReadRequest, Int) throws -> Data) { self.response = response }
    func verifyAccount() async throws -> String { identities.isEmpty ? identity : identities.removeFirst() }
    func read(_ request: NativeWebReadRequest, expectedAccount: String) async throws -> Data {
        guard expectedAccount == identity else { throw NativeSessionError.accountChanged }
        requests.append(request)
        return try response(request, requests.count)
    }
    func cancel() {}
}

@main struct NativeCollectorTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        checks += 1
        if try !value() { throw TestFailure.failed(name) }
    }
    enum TestFailure: Error { case failed(String) }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    static func course(_ n: Int, name: String? = nil) -> [String: Any] { ["id": "c\(n)", "name": name ?? "Course \(n)"] }
    static func moPage(_ records: [[String: Any]], _ count: Int) throws -> Data { try json(["objects": records, "count": count]) }
    static func detail(_ id: String) throws -> Data {
        try json(["info": ["id": id], "homework_sections": [["units": [["id": "task", "name": "Undated"]]]], "paper_sections": []])
    }
    @MainActor static func scope(_ p: NativePlatform) throws -> SourceScope { try SourceScope(platform: p, host: p.verifiedHost, connectionID: UUID()) }
    @MainActor static func collect(_ session: FixtureSession, _ p: NativePlatform = .mo) async throws -> NativeCollectedSnapshot {
        try await NativeTaskCollector.collect(scope: scope(p), expectedAccount: String(repeating: "a", count: 64), session: session)
    }
    @MainActor static func rejects(_ name: String, _ run: () async throws -> Void) async throws {
        do { try await run() } catch { try check(true, name); return }
        try check(false, name)
    }
    static func items(_ r: NativeWebReadRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    @MainActor static func main() async throws {
        let session = FixtureSession { r, _ in
            if r.url.path == "/pyapi/course" {
                let q = items(r), status = q["learning_status"]!, page = Int(q["page_no"]!)!
                if status == "pending" { return try moPage(page == 1 ? (0..<100).map { course($0) } : [course(100)], 101) }
                if status == "learning" { return try moPage([course(0)], 1) }
                return try moPage([], 0)
            }
            return try detail(r.url.lastPathComponent)
        }
        let result = try await collect(session)
        try check(result.courseCount == 101 && result.candidates.count == 101, "MO all statuses/pages union and one detail per course")
        try check(result.candidates.allSatisfy { $0.deadline == nil }, "undated candidates retained")
        try check(session.requests.count == 105, "MO descriptors enumerate 4 pages plus 101 details")
        try check(result.accountFingerprint == String(repeating: "a", count: 64), "snapshot binds expected fingerprint")
        for p in [NativePlatform.mo, .learningInZJU] {
            let empty = FixtureSession { _, _ in p == .mo ? try moPage([], 0) : try json(["courses": [], "page": 1, "page_size": 100, "pages": 0, "total": 0]) }
            let snapshot = try await collect(empty, p)
            try check(snapshot.courseCount == 0 && snapshot.candidates.isEmpty, "explicit empty source is complete")
        }
        try await bounds()
        try await invalidMO()
        try await xzzd()
        try await security()
        print("PASS: \(checks) native collector/session policy checks")
    }
    @MainActor static func bounds() async throws {
        for platform in [NativePlatform.mo, .learningInZJU] {
            let tooMany = FixtureSession { _, _ in
                if platform == .mo { return try moPage((0..<100).map { course($0) }, 501) }
                return try json(["courses": (0..<100).map { course($0) }, "page": 1, "page_size": 100, "pages": 6, "total": 501])
            }
            var bounded = false
            do { _ = try await collect(tooMany, platform) } catch NativeSessionError.budgetExceeded { bounded = true } catch {}
            try check(bounded && tooMany.requests.count == 1, "501-course source stops at first bounded metadata")
        }
        let maximum = FixtureSession { r, _ in
            if r.url.path != "/pyapi/course" { return try detail(r.url.lastPathComponent) }
            let q = items(r)
            guard q["learning_status"] == "pending" else { return try moPage([], 0) }
            let start = (Int(q["page_no"]!)! - 1) * 100
            return try moPage((start..<(start+100)).map { course($0) }, 500)
        }
        let snapshot = try await collect(maximum)
        try check(snapshot.courseCount == 500 && snapshot.candidates.count == 500, "inclusive 500-course MO boundary is complete")
        let oversized = FixtureSession { _, _ in Data(repeating: 32, count: 8 * 1024 * 1024 + 1) }
        var bounded = false
        do { _ = try await collect(oversized) } catch NativeSessionError.budgetExceeded { bounded = true } catch {}
        try check(bounded && oversized.requests.count == 1, "collector also bounds injected response bytes")
    }
    @MainActor static func invalidMO() async throws {
        for mode in ["partial", "empty", "repeat", "count", "tooMany", "conflict", "auth", "malformed"] {
            let s = FixtureSession { r, _ in
                if mode == "auth" { throw NativeSessionError.loginRequired }
                if mode == "malformed" { return Data("<html>login</html>".utf8) }
                let q = items(r), status = q["learning_status"]!, page = Int(q["page_no"]!)!
                if mode == "tooMany" { return try moPage([], 501) }
                if mode == "conflict" { return try moPage([course(1, name: status)], 1) }
                if status != "pending" { return try moPage([], 0) }
                if mode == "partial" { return try moPage([course(1)], 101) }
                if mode == "empty" { return try moPage([], 1) }
                if mode == "repeat" { return try moPage((0..<100).map { course($0) }, 101) }
                return try moPage(page == 1 ? (0..<100).map { course($0) } : [course(100)], page == 1 ? 101 : 102)
            }
            try await rejects("MO rejects \(mode) without snapshot") { _ = try await collect(s) }
        }
        let changed = FixtureSession { _, _ in try moPage([], 0) }
        changed.identities = [changed.identity, String(repeating: "b", count: 64)]
        try await rejects("account switch after collection rejects snapshot") { _ = try await collect(changed) }
        let before = FixtureSession { _, _ in throw TestFailure.failed("unexpected read") }
        before.identities = [String(repeating: "b", count: 64)]
        try await rejects("account switch at start rejects") { _ = try await collect(before) }
        try check(before.requests.isEmpty, "start mismatch performs no task reads")
        let cancelled = FixtureSession { _, _ in try moPage([], 0) }
        let task = Task { @MainActor in try await collect(cancelled) }; task.cancel()
        try await rejects("cancelled collection yields no snapshot") { _ = try await task.value }
    }
    @MainActor static func xzzd() async throws {
        func page(_ records: [[String: Any]], _ p: Int, _ total: Int, _ size: Int = 100) throws -> Data {
            try json(["courses": records, "page": p, "page_size": size, "pages": total == 0 ? 0 : (total - 1) / size + 1, "total": total])
        }
        let s = FixtureSession { r, _ in
            if r.url.path == "/api/my-courses" {
                let b = try JSONSerialization.jsonObject(with: r.body!) as! [String: Any]
                guard r.method == "POST", b["fields"] as? String == "id,name" else { throw TestFailure.failed("wrong course routing") }
                let p = b["page"] as! Int
                return try page(p == 1 ? (0..<100).map { course($0) } : [course(100)], p, 101)
            }
            return try json([r.url.path.hasSuffix("/exams") ? "exams" : "homework_activities": [["id": "same", "title": "Task", "end_time": "2026-11-05 23:59:00"]]])
        }
        let result = try await collect(s, .learningInZJU)
        try check(result.courseCount == 101 && result.candidates.count == 202, "xzzd gathers every course and both task kinds")
        try check(s.requests.count == 204, "xzzd uses two course pages and two endpoints per course")
        try check(Set(result.candidates.map { $0.identity.kind.rawValue }) == ["homework", "exam"], "same task IDs stay isolated by kind")
        for mode in ["partial", "repeat", "page", "size", "count", "name", "cap", "budget", "taskPagination"] {
            let bad = FixtureSession { r, _ in
                if r.url.path != "/api/my-courses" {
                    return try json([r.url.path.hasSuffix("/exams") ? "exams" : "homework_activities": [], "pages": mode == "taskPagination" ? 2 : 1])
                }
                let b = try JSONSerialization.jsonObject(with: r.body!) as! [String: Any], p = b["page"] as! Int
                if mode == "cap" { return try page([], p, 501) }
                if mode == "budget" {
                    let start = (p - 1) * 100, end = min(300, start + 100)
                    return try page((start..<end).map { course($0) }, p, 300)
                }
                if mode == "taskPagination" { return try page([course(1)], p, 1) }
                if mode == "partial" { return try page([course(0)], p, 101) }
                if mode == "repeat" { return try page((0..<100).map { course($0) }, p, 101) }
                if mode == "page" { return try page((0..<100).map { course($0) }, 1, 101) }
                if mode == "size" { return try page(p == 1 ? (0..<100).map { course($0) } : [course(100)], p, 101, p == 1 ? 100 : 101) }
                if mode == "count" { return try page(p == 1 ? (0..<100).map { course($0) } : [course(100)], p, p == 1 ? 101 : 102) }
                return try page(p == 1 ? (0..<100).map { course($0) } : [course(0, name: "Different")], p, 101)
            }
            try await rejects("xzzd rejects \(mode) without partial snapshot") { _ = try await collect(bad, .learningInZJU) }
            try check(bad.requests.count <= 599, "bounded session request budget")
        }
    }
    @MainActor static func security() async throws {
        let mo = NativePlatform.mo, x = NativePlatform.learningInZJU
        let valid = [NativeWebReadRequest(try MoReadRequest.courses(status: "pending", page: 1)), NativeWebReadRequest(try MoReadRequest.course(id: "a/b?x"))]
        for request in valid { try NativeWebPolicy.validate(request, platform: mo); try check(true, "reviewed MO descriptor allowed") }
        for request in [NativeWebReadRequest(try XzzdReadRequest.courses(page: 1)), NativeWebReadRequest(try XzzdReadRequest.homeworks(courseID: "a/b")), NativeWebReadRequest(try XzzdReadRequest.exams(courseID: "a/b"))] {
            try NativeWebPolicy.validate(request, platform: x); try check(true, "reviewed xzzd descriptor allowed")
        }
        for raw in ["http://mo.zju.edu.cn/pyapi/course", "https://evil.test/pyapi/course", "https://mo.zju.edu.cn:444/pyapi/course", "https://u:p@mo.zju.edu.cn/pyapi/course", "https://mo.zju.edu.cn/pyapi/course#fragment", "https://mo.zju.edu.cn/pyapi/course?page_no=1", "https://mo.zju.edu.cn/pyapi/course/section/../delete?is_backstage=false"] {
            try await rejects("unsafe URL/route rejected") { try NativeWebPolicy.validate(NativeWebReadRequest(method: "GET", url: URL(string: raw)!, body: nil), platform: mo) }
        }
        for body in [Data("{}".utf8), Data(#"{"page":true,"page_size":100,"fields":"id,name","conditions":{}}"#.utf8), Data(#"{"page":1,"page_size":100,"fields":"id,name","conditions":{"delete":true}}"#.utf8)] {
            try await rejects("unreviewed POST body rejected") { try NativeWebPolicy.validate(NativeWebReadRequest(method: "POST", url: URL(string: "https://courses.zju.edu.cn/api/my-courses")!, body: body), platform: x) }
        }
        try check(NativeWebPolicy.navigationAllowed(URL(string: "https://zjuam.zju.edu.cn/cas/login")!, platform: mo, interactive: true), "verified SSO interactive allowed")
        try check(!NativeWebPolicy.navigationAllowed(URL(string: "https://identity.zju.edu.cn/")!, platform: mo, interactive: false), "background SSO blocked")
        try check(!NativeWebPolicy.navigationAllowed(URL(string: "https://evil.zju.edu.cn/")!, platform: mo, interactive: true), "no wildcard navigation")
        let a = try NativeWebPolicy.fingerprint("opaque", platform: mo), b = try NativeWebPolicy.fingerprint("opaque", platform: x)
        try check(a.count == 64 && a != b && a != "opaque", "domain-separated opaque fingerprint")
        try check(NativeWebPolicy.allowsDefaultAuthentication(NSURLAuthenticationMethodServerTrust), "normal system TLS validation allowed")
        try check(!NativeWebPolicy.allowsDefaultAuthentication(NSURLAuthenticationMethodHTTPBasic), "HTTP auth cannot trigger a credentials popup")
        try check(!NativeWebPolicy.allowsDefaultAuthentication(NSURLAuthenticationMethodClientCertificate), "client certificate auth cannot trigger a popup")
        let invalidFingerprint = FixtureSession { _, _ in throw TestFailure.failed("unexpected read") }
        try await rejects("invalid fingerprint rejected before activation") {
            _ = try await NativeTaskCollector.collect(scope: scope(.mo), expectedAccount: "raw-account", session: invalidFingerprint)
        }
        let bytes = FixtureSession { r, _ in
            if r.url.path != "/pyapi/course" { return try detail(r.url.lastPathComponent) }
            let status = items(r)["learning_status"]!
            if status == "finished" { return try moPage([], 0) }
            return try moPage([["id": status == "pending" ? "é" : "e\u{301}", "name": "Opaque"]], 1)
        }
        let byteSnapshot = try await collect(bytes)
        try check(byteSnapshot.courseCount == 2, "opaque course IDs deduplicate by UTF8 bytes")
        let adapter = NativeWebSession(platform: mo, storeID: UUID())
        adapter.cancel(); adapter.close() // Inert constructor/cancel/close must not touch WebKit persistence.
        let cancelled = Task { @MainActor in try await adapter.verifyAccount() }
        cancelled.cancel()
        var wasCancelled = false
        do { _ = try await cancelled.value } catch NativeSessionError.cancelled { wasCancelled = true } catch {}
        try check(wasCancelled, "pre-cancelled adapter verification fails before creating a store")
        let zero = NativeWebSession(platform: mo, storeID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        var rejectedStore = false
        do { _ = try await zero.verifyAccount() } catch NativeSessionError.unsafeRequest { rejectedStore = true } catch {}
        try check(rejectedStore, "invalid store UUID fails before creating a store")
        if let output = ProcessInfo.processInfo.environment["NATIVE_SCRIPT_OUTPUT"] { try NativeWebScript.source.write(toFile: output, atomically: true, encoding: .utf8) }
    }
}
