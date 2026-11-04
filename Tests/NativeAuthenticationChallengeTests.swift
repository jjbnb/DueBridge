// Synthetic fixtures only; public school domains test exact request policies.
import Foundation

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
    @MainActor static func main() {
        do {
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
