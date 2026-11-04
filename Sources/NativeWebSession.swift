import Foundation
import CryptoKit
import CoreFoundation
import AppKit
import WebKit

enum NativeSessionError: Error { case loginRequired, accountChanged, network, timeout, invalidResponse, unsafeRequest, cancelled, budgetExceeded }
struct NativeWebReadRequest {
    let method: String; let url: URL; let body: Data?
    init(method: String, url: URL, body: Data?) { self.method = method; self.url = url; self.body = body }
    init(_ r: MoReadRequest) { self.init(method: r.method, url: r.url, body: nil) }
    init(_ r: XzzdReadRequest) { self.init(method: r.method, url: r.url, body: r.body) }
}
@MainActor protocol NativeSessionReading: AnyObject {
    func verifyAccount() async throws -> String
    func read(_ request: NativeWebReadRequest, expectedAccount: String) async throws -> Data
    func cancel()
}
enum NativeWebPolicy {
    static func allowsDefaultAuthentication(_ method: String) -> Bool { method == NSURLAuthenticationMethodServerTrust }
    static func validFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func fingerprint(_ raw: String, platform: NativePlatform, registry: SourceRegistry = .production) throws -> String {
        guard let host = registry.descriptor(for: platform)?.verifiedHost else { throw NativeSessionError.unsafeRequest }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, raw.utf8.count <= 1024,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw NativeSessionError.loginRequired }
        var data = Data()
        for field in ["bb-ddl/native-account", "1", platform.rawValue, host, raw] {
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func navigationAllowed(_ url: URL, platform: NativePlatform, interactive: Bool, registry: NativeAdapterRegistry = .production) -> Bool {
        guard let adapter = registry.adapter(for: platform), let host = adapter.descriptor.verifiedHost else { return false }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443 else { return false }
        let hosts = interactive ? [host] + adapter.authentication.interactiveHosts : [host]
        return hosts.contains(parts.host ?? "")
    }
    static func validate(_ r: NativeWebReadRequest, platform: NativePlatform, registry: NativeAdapterRegistry = .production) throws {
        guard let adapter = registry.adapter(for: platform),
              navigationAllowed(r.url, platform: platform, interactive: false, registry: registry),
              let parts = URLComponents(url: r.url, resolvingAgainstBaseURL: false), parts.fragment == nil else { throw NativeSessionError.unsafeRequest }
        try adapter.validate(r)
    }
}
enum NativeWebScript {
    // Fixed source only: callers pass data arguments, never interpolate a URL/ID/token.
    // Runs in this app's isolated WebKit world on the exact platform origin.
    static var source: String { source(registry: .production) }
    static func source(registry: NativeAdapterRegistry) -> String {
        let entries = registry.sources.nativeDescriptors.compactMap { descriptor -> String? in
            guard let platform = descriptor.nativePlatform, let adapter = registry.adapter(for: platform), let host = descriptor.verifiedHost else { return nil }
            let key = String(data: try! JSONSerialization.data(withJSONObject: platform.rawValue, options: [.fragmentsAllowed]), encoding: .utf8)!
            let origin = String(data: try! JSONSerialization.data(withJSONObject: "https://\(host)", options: [.fragmentsAllowed]), encoding: .utf8)!
            return "\(key): {origin: \(origin), authentication: \(adapter.authentication.scriptObject)}"
        }.joined(separator: ",\n")
        return template.replacingOccurrences(of: "/*STATIC_AUTHENTICATION*/", with: entries)
    }
    private static let template = #"""
    const configurations = {/*STATIC_AUTHENTICATION*/};
    if (!Object.prototype.hasOwnProperty.call(configurations, platform)) return {error:'unsafeRequest'};
    const configuration = configurations[platform], origin = configuration.origin, authentication = configuration.authentication;
    const allowed = new Set(['loginRequired','accountChanged','network','timeout','invalidResponse','unsafeRequest','cancelled','budgetExceeded']);
    const fail = code => { throw code; };
    if (location.origin !== origin) return {error:'unsafeRequest'};
    const controller = new AbortController();
    const abortHandle = {requestID,controller};
    globalThis.__bbDDLAbort = abortHandle;
    let expired = false;
    const timer = setTimeout(() => { expired = true; controller.abort(); }, 30000);
    const validID = value => typeof value === 'string' && value.trim().length > 0 &&
        new TextEncoder().encode(value).length <= 1024 && !/[\u0000-\u001f\u007f-\u009f]/.test(value);
    async function read(url, method, body, html = false) {
        const headers = {'Accept':html ? 'text/html' : 'application/json', ...authentication.headers(body)};
        if (body !== null) headers['Content-Type'] = 'application/json';
        const response = await fetch(url, {method, body:body === null ? undefined : body, headers,
            credentials:'same-origin', redirect:'error', cache:'no-store', signal:controller.signal});
        if (response.status === 401 || response.status === 403) fail('loginRequired');
        if (!response.ok || response.redirected) fail('invalidResponse');
        const mime = (response.headers.get('Content-Type') || '').split(';')[0].trim().toLowerCase();
        if (html ? mime !== 'text/html' : !/^application\/(?:json|[a-z0-9!#$&^_.+-]+\+json)$/.test(mime)) fail('invalidResponse');
        if (!response.body) fail('invalidResponse');
        const reader = response.body.getReader(), chunks = [];
        let size = 0;
        while (true) {
            const next = await reader.read();
            if (next.done) break;
            size += next.value.byteLength;
            if (size > 8 * 1024 * 1024) { await reader.cancel(); controller.abort(); fail('budgetExceeded'); }
            chunks.push(next.value);
        }
        const bytes = new Uint8Array(size);
        let offset = 0;
        for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
        let text;
        try { text = new TextDecoder('utf-8', {fatal:true}).decode(bytes); } catch (_) { fail('invalidResponse'); }
        if (!html) {
            try { JSON.parse(text); } catch (_) { fail('invalidResponse'); }
        }
        return text;
    }
    try {
        if (operation === 'identity') return {identity:await authentication.identity(read)};
        if (operation !== 'read' || !validID(expectedIdentity)) fail('unsafeRequest');
        authentication.checkIdentity(expectedIdentity);
        const url = new URL(requestURL);
        if (url.origin !== origin || url.username || url.password || url.hash) fail('unsafeRequest');
        const payload = await read(url.href, requestMethod, requestBody);
        authentication.checkIdentity(expectedIdentity);
        return {payload};
    } catch (error) {
        return {error: expired ? 'timeout' : allowed.has(error) ? error : controller.signal.aborted ? 'cancelled' : 'network'};
    } finally {
        clearTimeout(timer);
        if (globalThis.__bbDDLAbort === abortHandle) delete globalThis.__bbDDLAbort;
    }
    """#
}

@MainActor final class NativeWebSession: NSObject, NativeSessionReading, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let platform: NativePlatform
    let storeID: UUID
    private let registry: NativeAdapterRegistry
    private(set) var lastError: NativeSessionError?
    private var webView: WKWebView?
    private var loginWindow: NSWindow?
    private var interactive = false
    private var generation: UInt64 = 0
    private var activeOperation: UUID?
    private var trackedNavigation: WKNavigation?
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var navigationDeadline: Task<Void, Never>?
    private var navigationDeadlineID: UUID?
    private var scriptContinuation: CheckedContinuation<Any, Error>?
    private var scriptDeadline: Task<Void, Never>?
    private var scriptID: UUID?

    // Deliberately inert: startup/panel construction cannot activate WebKit storage.
    init(platform: NativePlatform, storeID: UUID, registry: NativeAdapterRegistry = .production) {
        self.registry = registry
        self.platform = platform
        self.storeID = storeID
        super.init()
    }
    private func ensureView() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 760), configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        return view
    }
    // Root calls this only from an explicit Connect/reconnect action.
    func openLogin() {
        cancel()
        guard let adapter = registry.adapter(for: platform), storeID != UUID(uuidString: "00000000-0000-0000-0000-000000000000")! else { lastError = .unsafeRequest; return }
        lastError = nil
        interactive = true
        let view = ensureView()
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = adapter.authentication.loginTitle
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = view
        loginWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startNavigationDeadline()
        trackedNavigation = view.load(URLRequest(url: adapter.authentication.loginURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45))
    }
    func finishLogin() async throws -> String {
        guard interactive, let view = webView, let url = view.url,
              NativeWebPolicy.navigationAllowed(url, platform: platform, interactive: false, registry: registry), !view.isLoading else { throw NativeSessionError.loginRequired }
        let result = try await verifyAccount()
        interactive = false
        loginWindow?.orderOut(nil)
        close() // Release the full login SPA; subsequent reads start at robots.txt.
        return result
    }
    func verifyAccount() async throws -> String {
        try await run { id, epoch in
            try await self.prepareOrigin(id, epoch)
            let raw = try await self.identity(id, epoch)
            try self.check(id, epoch)
            return try NativeWebPolicy.fingerprint(raw, platform: self.platform, registry: self.registry.sources)
        }
    }
    func read(_ request: NativeWebReadRequest, expectedAccount: String) async throws -> Data {
        try NativeWebPolicy.validate(request, platform: platform, registry: registry)
        guard NativeWebPolicy.validFingerprint(expectedAccount), !interactive else { throw NativeSessionError.unsafeRequest }
        return try await run { id, epoch in
            try await self.prepareOrigin(id, epoch)
            let raw = try await self.identity(id, epoch)
            guard try NativeWebPolicy.fingerprint(raw, platform: self.platform, registry: self.registry.sources) == expectedAccount else { throw NativeSessionError.accountChanged }
            try self.check(id, epoch)
            let response = try await self.execute(operation: "read", request: request, expectedIdentity: raw)
            try self.check(id, epoch)
            guard let payload = response["payload"] as? String else { throw NativeSessionError.invalidResponse }
            let bytes = Data(payload.utf8)
            guard bytes.count <= 8 * 1024 * 1024 else { throw NativeSessionError.budgetExceeded }
            return bytes
        }
    }
    private func run<T>(_ action: (UUID, UInt64) async throws -> T) async throws -> T {
        guard !Task.isCancelled else { throw NativeSessionError.cancelled }
        guard activeOperation == nil else { throw NativeSessionError.unsafeRequest }
        let id = UUID(), epoch = generation
        activeOperation = id
        defer { if activeOperation == id { activeOperation = nil } }
        return try await withTaskCancellationHandler(operation: {
            do { return try await action(id, epoch) }
            catch {
                let safe = (error as? NativeSessionError) ?? (error is CancellationError ? .cancelled : .network)
                if activeOperation == id { lastError = safe }
                throw safe
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.activeOperation == id else { return }
                self.cancel()
            }
        })
    }
    private func check(_ id: UUID, _ epoch: UInt64) throws {
        guard activeOperation == id, generation == epoch, !Task.isCancelled else { throw NativeSessionError.cancelled }
    }
    private func prepareOrigin(_ id: UUID, _ epoch: UInt64) async throws {
        try check(id, epoch)
        guard let adapter = registry.adapter(for: platform), storeID != UUID(uuidString: "00000000-0000-0000-0000-000000000000")! else { throw NativeSessionError.unsafeRequest }
        let view = ensureView()
        if let url = view.url, NativeWebPolicy.navigationAllowed(url, platform: platform, interactive: false, registry: registry), !view.isLoading { return }
        guard !interactive else { throw NativeSessionError.loginRequired }
        try await withCheckedThrowingContinuation { continuation in
            navigationContinuation = continuation
            startNavigationDeadline()
            // A lightweight source-origin document suffices; no repeated SPA loads.
            trackedNavigation = view.load(URLRequest(url: adapter.authentication.backgroundURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45))
        }
        try check(id, epoch)
    }
    private func identity(_ id: UUID, _ epoch: UInt64) async throws -> String {
        let response = try await execute(operation: "identity", request: nil, expectedIdentity: nil)
        try check(id, epoch)
        guard let raw = response["identity"] as? String else { throw NativeSessionError.loginRequired }
        _ = try NativeWebPolicy.fingerprint(raw, platform: platform, registry: registry.sources)
        return raw
    }
    private func execute(operation: String, request: NativeWebReadRequest?, expectedIdentity: String?) async throws -> [String: Any] {
        guard let view = webView, let url = view.url,
              NativeWebPolicy.navigationAllowed(url, platform: platform, interactive: false, registry: registry), scriptContinuation == nil else { throw NativeSessionError.unsafeRequest }
        let ticket = UUID()
        let result: Any = try await withCheckedThrowingContinuation { continuation in
            scriptContinuation = continuation
            scriptID = ticket
            scriptDeadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
                guard let self, self.scriptID == ticket else { return }
                self.abortScript(ticket)
                self.finishScript(ticket, .failure(NativeSessionError.timeout))
            }
            let args: [String: Any] = ["platform": platform.rawValue, "operation": operation,
                "requestURL": request?.url.absoluteString ?? "", "requestMethod": request?.method ?? "GET",
                "requestBody": request?.body.flatMap { String(data: $0, encoding: .utf8) } as Any? ?? NSNull(),
                "expectedIdentity": expectedIdentity as Any? ?? NSNull(), "requestID": ticket.uuidString]
            view.callAsyncJavaScript(NativeWebScript.source(registry: registry), arguments: args, in: nil, in: .defaultClient) { [weak self] result in
                self?.finishScript(ticket, result)
            }
        }
        guard let object = result as? [String: Any] else { throw NativeSessionError.invalidResponse }
        if let code = object["error"] as? String {
            switch code {
            case "loginRequired": throw NativeSessionError.loginRequired
            case "accountChanged": throw NativeSessionError.accountChanged
            case "timeout": throw NativeSessionError.timeout
            case "unsafeRequest": throw NativeSessionError.unsafeRequest
            case "cancelled": throw NativeSessionError.cancelled
            case "budgetExceeded": throw NativeSessionError.budgetExceeded
            case "network": throw NativeSessionError.network
            default: throw NativeSessionError.invalidResponse
            }
        }
        return object
    }
    private func finishScript(_ ticket: UUID, _ result: Result<Any, Error>) {
        guard scriptID == ticket, let continuation = scriptContinuation else { return }
        scriptID = nil
        scriptContinuation = nil
        scriptDeadline?.cancel(); scriptDeadline = nil
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: (error as? NativeSessionError) ?? .network)
        }
    }
    private func abortScript(_ ticket: UUID) {
        // Ticket comparison prevents a delayed cancellation from aborting a new run.
        webView?.callAsyncJavaScript("if (globalThis.__bbDDLAbort?.requestID === requestID) globalThis.__bbDDLAbort.controller.abort();", arguments: ["requestID": ticket.uuidString], in: nil, in: .defaultClient, completionHandler: nil)
    }
    private func startNavigationDeadline() {
        navigationDeadline?.cancel()
        let ticket = UUID(), epoch = generation
        navigationDeadlineID = ticket
        navigationDeadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
            // Cancellation cannot retract a successful sleep already queued on
            // MainActor. Only this navigation and generation may settle timeout.
            guard let self, self.navigationDeadlineID == ticket, self.generation == epoch else { return }
            self.lastError = .timeout
            self.webView?.stopLoading()
            self.finishNavigation(.failure(NativeSessionError.timeout))
        }
    }
    private func finishNavigation(_ result: Result<Void, Error>) {
        navigationDeadlineID = nil
        navigationDeadline?.cancel(); navigationDeadline = nil
        trackedNavigation = nil
        let continuation = navigationContinuation
        navigationContinuation = nil
        continuation?.resume(with: result)
    }
    func cancel() {
        generation &+= 1
        activeOperation = nil
        if let ticket = scriptID {
            abortScript(ticket)
            finishScript(ticket, .failure(NativeSessionError.cancelled))
        }
        finishNavigation(.failure(NativeSessionError.cancelled))
        webView?.stopLoading()
        interactive = false
        let window = loginWindow
        loginWindow = nil
        window?.delegate = nil
        window?.close()
        // Drop the cancelled document so its delayed delegate callbacks cannot
        // complete a future operation's navigation or continue page activity.
        let oldView = webView
        webView = nil
        oldView?.navigationDelegate = nil
        oldView?.uiDelegate = nil
        oldView?.removeFromSuperview()
    }
    func close() { cancel() }
    func windowWillClose(_ notification: Notification) { cancel() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView, let url = navigationAction.request.url,
              NativeWebPolicy.navigationAllowed(url, platform: platform, interactive: interactive, registry: registry) else {
            lastError = .unsafeRequest
            finishNavigation(.failure(NativeSessionError.unsafeRequest))
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard webView === self.webView, let url = navigationResponse.response.url,
              NativeWebPolicy.navigationAllowed(url, platform: platform, interactive: interactive, registry: registry),
              let response = navigationResponse.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            lastError = .invalidResponse
            finishNavigation(.failure(NativeSessionError.invalidResponse))
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        if interactive, trackedNavigation !== navigation {
            trackedNavigation = navigation
            startNavigationDeadline()
        }
        if navigationDeadline == nil { startNavigationDeadline() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, navigation === trackedNavigation else { return }
        finishNavigation(.success(()))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, navigation === trackedNavigation else { return }
        navigationFailed(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, navigation === trackedNavigation else { return }
        navigationFailed(error)
    }
    private func navigationFailed(_ error: Error) {
        // WebKit error messages often contain private URLs; never propagate them.
        let safe: NativeSessionError = (error as NSError).code == NSURLErrorCancelled ? .cancelled : .network
        lastError = safe
        finishNavigation(.failure(safe))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        lastError = .network
        if let ticket = scriptID { finishScript(ticket, .failure(NativeSessionError.network)) }
        finishNavigation(.failure(NativeSessionError.network))
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard webView === self.webView, interactive, navigationAction.targetFrame == nil, let url = navigationAction.request.url,
              NativeWebPolicy.navigationAllowed(url, platform: platform, interactive: true, registry: registry) else {
            lastError = .unsafeRequest
            return nil
        }
        // SSO popups share the one visible login view and the same cookie store.
        startNavigationDeadline()
        trackedNavigation = webView.load(navigationAction.request)
        return nil
    }
    func authenticationDisposition(for protectionSpace: URLProtectionSpace, isCurrentView: Bool) -> URLSession.AuthChallengeDisposition {
        // The source page loads HTTPS resources from CDNs too. Default handling
        // validates their certificates through the OS; it never supplies credentials.
        return isCurrentView && NativeWebPolicy.allowsDefaultAuthentication(protectionSpace.authenticationMethod)
            ? .performDefaultHandling : .cancelAuthenticationChallenge
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(authenticationDisposition(for: challenge.protectionSpace, isCurrentView: webView === self.webView), nil)
    }
    // A background page cannot open credential or JavaScript modal dialogs.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
}
