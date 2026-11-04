// Synthetic fixtures only; public school domains test exact request policies.
import Foundation

private struct LoginEntryFixtureAdapter: NativePlatformAdapter {
    let descriptor = SourceDescriptor.mo
    let authentication: NativeAuthenticationConfiguration
    init(login: String, background: String = "https://mo.zju.edu.cn/robots.txt", hosts: [String] = ["zjuam.zju.edu.cn"]) {
        authentication = NativeAuthenticationConfiguration(loginTitle: "Fixture", loginURL: URL(string: login)!, backgroundURL: URL(string: background)!, interactiveHosts: hosts, scriptObject: MoPlatformAdapter().authentication.scriptObject)
    }
    func validate(_ request: NativeWebReadRequest) throws { throw NativeSessionError.unsafeRequest }
    @MainActor func collect(scope: SourceScope, reads: NativeReadContext) async throws -> NativeAdapterCollection { throw NativeSessionError.unsafeRequest }
}

@main struct NativeAuthenticationChallengeTests {
    @MainActor static var checks = 0
    enum Failure: Error { case failed(String) }
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard value() else { throw Failure.failed(message) }
    }
    static func space(host: String, method: String) -> URLProtectionSpace {
        URLProtectionSpace(host: host, port: 443, protocol: "https", realm: nil, authenticationMethod: method)
    }
    @MainActor static func loginEntry() throws {
        let login = MoPlatformAdapter().authentication.loginURL
        let parts = URLComponents(url: login, resolvingAgainstBaseURL: false)!
        try check(parts.scheme == "https" && parts.host == "zjuam.zju.edu.cn" && parts.path == "/cas/oauth2.0/authorize", "MO opens the published passport entry directly before the MO SPA")
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        try check(query == ["response_type": "code", "client_id": "mU53a5ysj5jfo8PUvP", "redirect_uri": "http://mo.zju.edu.cn/user/login"], "MO keeps the published public OAuth registration unchanged")
        let accepted = ["https://zjuam.zju.edu.cn/cas/login?service=synthetic", "https://mo.zju.edu.cn/user/login?from=synthetic", "https://zjuam.zju.edu.cn:443/cas/login?service=synthetic"]
        for url in accepted {
            let registry = try NativeAdapterRegistry(adapters: [LoginEntryFixtureAdapter(login: url), LearningInZJUPlatformAdapter()], sources: .production)
            try check(registry.adapter(for: .mo) != nil, "reviewed HTTPS login entry may carry a public query on an explicit login host")
        }
        let rejected = [
            LoginEntryFixtureAdapter(login: "http://zjuam.zju.edu.cn/cas/login"),
            LoginEntryFixtureAdapter(login: "https://other.zju.edu.cn/cas/login"),
            LoginEntryFixtureAdapter(login: "https://user:pass@zjuam.zju.edu.cn/cas/login"),
            LoginEntryFixtureAdapter(login: "https://zjuam.zju.edu.cn:444/cas/login"),
            LoginEntryFixtureAdapter(login: "https://zjuam.zju.edu.cn/cas/login#fragment"),
            LoginEntryFixtureAdapter(login: "https://zjuam.zju.edu.cn/cas/login", background: "https://zjuam.zju.edu.cn/robots.txt"),
            LoginEntryFixtureAdapter(login: "https://zjuam.zju.edu.cn/cas/login", background: "https://mo.zju.edu.cn/robots.txt?query=synthetic"),
            LoginEntryFixtureAdapter(login: "https://zjuam.zju.edu.cn/cas/login", background: "https://mo.zju.edu.cn:443/robots.txt"),
            LoginEntryFixtureAdapter(login: "https://mo.zju.edu.cn/", hosts: ["zjuam.zju.edu.cn/path"])
        ]
        for adapter in rejected {
            var refused = false
            do { _ = try NativeAdapterRegistry(adapters: [adapter, LearningInZJUPlatformAdapter()], sources: .production) }
            catch SourceRegistryError.adapterMismatch { refused = true }
            try check(refused, "invalid login or background entry remains rejected by the adapter registry")
        }
    }
    @MainActor static func callbackUpgrade() throws {
        let raw = "http://mo.zju.edu.cn/user/login?code=synthetic%2F%2B%25+value&state=%2f&redirect_uri=http%3A%2F%2Fexample.test%2F#synthetic%2Ffragment"
        var request = URLRequest(url: URL(string: raw)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 17)
        request.setValue("synthetic", forHTTPHeaderField: "X-Test")
        let upgraded = NativeWebPolicy.interactiveNavigationUpgrade(request, platform: .mo, interactive: true, isMainFrame: true)
        try check(upgraded?.url?.absoluteString == "https" + raw.dropFirst(4), "published MO HTTP callback upgrades to HTTPS without rewriting encoded query or fragment")
        try check(upgraded?.httpMethod == request.httpMethod && upgraded?.allHTTPHeaderFields == request.allHTTPHeaderFields && upgraded?.cachePolicy == request.cachePolicy && upgraded?.timeoutInterval == 17, "callback upgrade changes only the request URL scheme")
        for platform in [NativePlatform.mo, .learningInZJU] {
            for interactive in [false, true] {
                for mainFrame in [false, true] where platform != .mo || !interactive || !mainFrame {
                    try check(NativeWebPolicy.interactiveNavigationUpgrade(request, platform: platform, interactive: interactive, isMainFrame: mainFrame) == nil, "callback exception is limited to interactive MO main-frame navigation")
                }
            }
        }
        for raw in ["http://mo.zju.edu.cn/", "http://mo.zju.edu.cn/user/login/", "http://mo.zju.edu.cn/user/%6cogin", "http://mo.zju.edu.cn/pyapi/course", "http://zjuam.zju.edu.cn/user/login", "http://evil.test/user/login", "http://mo.zju.edu.cn:80/user/login", "http://mo.zju.edu.cn:443/user/login", "http://u:p@mo.zju.edu.cn/user/login", "https://mo.zju.edu.cn/user/login", "http://mo.zju.edu.cn/user/login/../login"] {
            let other = URLRequest(url: URL(string: raw)!)
            try check(NativeWebPolicy.interactiveNavigationUpgrade(other, platform: .mo, interactive: true, isMainFrame: true) == nil, "callback upgrade rejects every other host, path, port, scheme or userinfo")
        }
        for method in ["POST", "PUT", "HEAD", "DELETE"] {
            var other = request; other.httpMethod = method
            try check(NativeWebPolicy.interactiveNavigationUpgrade(other, platform: .mo, interactive: true, isMainFrame: true) == nil, "callback upgrade cannot replay another HTTP method")
        }
        var body = request; body.httpBody = Data("synthetic".utf8)
        try check(NativeWebPolicy.interactiveNavigationUpgrade(body, platform: .mo, interactive: true, isMainFrame: true) == nil, "callback upgrade refuses requests carrying a body")
        var stream = request; stream.httpBodyStream = InputStream(data: Data("synthetic".utf8))
        try check(NativeWebPolicy.interactiveNavigationUpgrade(stream, platform: .mo, interactive: true, isMainFrame: true) == nil, "callback upgrade refuses requests carrying a body stream")
        try check(!NativeWebPolicy.navigationAllowed(request.url!, platform: .mo, interactive: true), "raw HTTP callback remains forbidden to transport")
        var refusedAPI = false
        do { try NativeWebPolicy.validate(NativeWebReadRequest(method: "GET", url: request.url!, body: nil), platform: .mo) }
        catch NativeSessionError.unsafeRequest { refusedAPI = true }
        try check(refusedAPI, "HTTP callback never becomes an allowed background/API request")
    }
    @MainActor static func main() {
        do {
            try loginEntry()
            try callbackUpgrade()
            for platform in [NativePlatform.mo, .learningInZJU] {
                let session = NativeWebSession(platform: platform, storeID: UUID())
                for host in [platform.verifiedHost, "zju-frontend.momodel.cn", "other-cdn.example"] {
                    let serverTrust = space(host: host, method: NSURLAuthenticationMethodServerTrust)
                    try check(session.authenticationDisposition(for: serverTrust, isCurrentView: true) == .performDefaultHandling,
                        "current view TLS must use normal system certificate validation for \(host)")
                    try check(session.authenticationDisposition(for: serverTrust, isCurrentView: false) == .cancelAuthenticationChallenge,
                        "stale/wrong view TLS challenge must be cancelled")
                    for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodNTLM] {
                        let credentials = space(host: host, method: method)
                        for current in [true, false] {
                            try check(session.authenticationDisposition(for: credentials, isCurrentView: current) == .cancelAuthenticationChallenge,
                                "credential challenge must remain cancelled for every host and view")
                        }
                    }
                }
                // Trust handling for fetched subresources does not authorize page navigation.
                let cdn = URL(string: "https://zju-frontend.momodel.cn/index.js")!
                for interactive in [true, false] {
                    try check(!NativeWebPolicy.navigationAllowed(cdn, platform: platform, interactive: interactive), "CDN must not become an allowed navigation origin")
                }
                var rejectedAPI = false
                do { try NativeWebPolicy.validate(NativeWebReadRequest(method: "GET", url: cdn, body: nil), platform: platform) }
                catch NativeSessionError.unsafeRequest { rejectedAPI = true }
                catch {}
                try check(rejectedAPI, "CDN must not become an allowed API origin")
                session.close() // Constructor/decision/close paths stay inert: no view/store/window.
            }
            print("PASS: \(checks) offline authentication challenge checks")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }
}
