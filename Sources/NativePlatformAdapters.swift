import Foundation
import CoreFoundation

// These implementations are compiled into the app. They only receive a bounded read
// context; no settings, reminders, cookies or scheduler are exposed to collection.
struct NativeAuthenticationConfiguration {
    let loginTitle: String
    let loginURL: URL
    let backgroundURL: URL
    let interactiveHosts: [String]
    // Fixed reviewed JavaScript object; never supplied by a website or settings.
    let scriptObject: String
}
struct NativeAdapterCollection {
    let candidates: [NativeDeadlineTask]
    let courseCount: Int
}
protocol NativePlatformAdapter {
    var descriptor: SourceDescriptor { get }
    var authentication: NativeAuthenticationConfiguration { get }
    func validate(_ request: NativeWebReadRequest) throws
    @MainActor func collect(scope: SourceScope, reads: NativeReadContext) async throws -> NativeAdapterCollection
}
struct NativeAdapterRegistry {
    let sources: SourceRegistry
    private let adapters: [NativePlatform: any NativePlatformAdapter]
    static let production = try! NativeAdapterRegistry(adapters: [MoPlatformAdapter(), LearningInZJUPlatformAdapter()], sources: .production)
    init(adapters: [any NativePlatformAdapter], sources: SourceRegistry) throws {
        var registered = [NativePlatform: any NativePlatformAdapter]()
        for adapter in adapters {
            let descriptor = adapter.descriptor
            guard let platform = descriptor.nativePlatform, sources.descriptor(for: platform) == descriptor,
          let host = descriptor.verifiedHost,
          Self.safeEntry(adapter.authentication.loginURL, host: host),
          Self.safeEntry(adapter.authentication.backgroundURL, host: host),
          !adapter.authentication.scriptObject.isEmpty,
          adapter.authentication.interactiveHosts.allSatisfy({ Self.safeHost($0) }) else { throw SourceRegistryError.adapterMismatch }
            guard registered.updateValue(adapter, forKey: platform) == nil else { throw SourceRegistryError.duplicateIdentity }
        }
        guard registered.count == sources.nativeDescriptors.count else { throw SourceRegistryError.adapterMismatch }
        self.adapters = registered; self.sources = sources
    }
    private static func safeEntry(_ url: URL, host: String) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme == "https" && parts.host == host && parts.percentEncodedHost == host && parts.user == nil && parts.password == nil && parts.port == nil && parts.fragment == nil && parts.query == nil
    }
    private static func safeHost(_ host: String) -> Bool {
        guard let url = URL(string: "https://\(host)/"), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.host == host && parts.percentEncodedHost == host && parts.user == nil && parts.password == nil && parts.port == nil && parts.path == "/" && parts.query == nil && parts.fragment == nil
    }
    func adapter(for platform: NativePlatform) -> (any NativePlatformAdapter)? { adapters[platform] }
}

struct MoPlatformAdapter: NativePlatformAdapter {
    let descriptor = SourceDescriptor.mo
    let authentication = NativeAuthenticationConfiguration(
        loginTitle: "MO 登录", loginURL: URL(string: "https://mo.zju.edu.cn/")!, backgroundURL: URL(string: "https://mo.zju.edu.cn/robots.txt")!,
        interactiveHosts: ["zjuam.zju.edu.cn", "identity.zju.edu.cn"], scriptObject: #"""
    {
        binding() {
            const id = localStorage.getItem('user_obj_id'), user = localStorage.getItem('user_ID'), token = localStorage.getItem('token');
            if (!validID(id) || !validID(user) || user === '.' || user === '..' || typeof token !== 'string' || !token || token.length > 32768 || /[\r\n]/.test(token)) fail('loginRequired');
            return {id,user,token};
        },
        headers(body) { return {Authorization:'Bearer ' + this.binding().token}; },
        async identity(read) {
            const binding = this.binding();
            const text = await read(origin + '/pyapi/user/profile/' + encodeURIComponent(binding.user), 'GET', null);
            const root = JSON.parse(text), profile = root.response === undefined ? root : root.response;
            if (!profile || typeof profile !== 'object' || profile._id !== binding.id ||
                (profile.user_ID !== undefined && String(profile.user_ID) !== binding.user)) fail('loginRequired');
            const current = this.binding();
            if (current.id !== binding.id || current.user !== binding.user) fail('accountChanged');
            return binding.id;
        },
        checkIdentity(expected) { if (this.binding().id !== expected) fail('accountChanged'); }
    }
    """#)
    func validate(_ r: NativeWebReadRequest) throws {
        let parts = URLComponents(url: r.url, resolvingAgainstBaseURL: false)!
        func same(_ candidate: NativeWebReadRequest) -> Bool {
            var actual = parts, wanted = URLComponents(url: candidate.url, resolvingAgainstBaseURL: false)!
            actual.port = nil; wanted.port = nil
            return r.method == candidate.method && r.body == candidate.body && actual == wanted
        }
        let path = parts.percentEncodedPath
        guard r.method == "GET", r.body == nil else { throw NativeSessionError.unsafeRequest }
        if path == "/pyapi/course" {
            let queries = parts.queryItems ?? []
            if let pageText = queries.first(where: { $0.name == "page_no" })?.value,
               let page = Int(pageText), (1...100).contains(page),
               let status = queries.first(where: { $0.name == "learning_status" })?.value,
               let descriptor = try? MoReadRequest.courses(status: status, page: page), same(NativeWebReadRequest(descriptor)) { return }
        } else if path.hasPrefix("/pyapi/course/section/"),
                  let id = String(path.dropFirst("/pyapi/course/section/".count)).removingPercentEncoding,
                  let descriptor = try? MoReadRequest.course(id: id), same(NativeWebReadRequest(descriptor)) { return }
        throw NativeSessionError.unsafeRequest
    }
    @MainActor func collect(scope: SourceScope, reads: NativeReadContext) async throws -> NativeAdapterCollection {
        let courses = try await courses(reads)
        let courseCount = courses.count
        var tasks = [NativeDeadlineTask]()
        for course in courses {
            let data = try await reads.fetch(NativeWebReadRequest(MoReadRequest.course(id: course.id)))
            tasks += try MoTaskPayload.tasks(data, course: course, scope: scope)
        }
        return NativeAdapterCollection(candidates: tasks, courseCount: courseCount)
    }
    private func courses(_ reads: NativeReadContext) async throws -> [MoCourse] {
        var union = [Data: MoCourse](), ordered = [MoCourse]()
        for status in ["pending", "learning", "finished"] {
            var page = 1, total: Int?, seen = Set<Data>()
            while true {
                guard page <= 100 else { throw NativeSessionError.budgetExceeded }
                let data = try await reads.fetch(NativeWebReadRequest(MoReadRequest.courses(status: status, page: page)))
                let result = try MoTaskPayload.courses(data)
                guard result.total <= 500 else { throw NativeSessionError.budgetExceeded }
                guard total == nil || total == result.total else { throw NativeSessionError.invalidResponse }
                total = result.total
                let expected = min(100, result.total - seen.count)
                guard expected >= 0, result.courses.count == expected else { throw NativeSessionError.invalidResponse }
                for course in result.courses {
                    let key = Data(course.id.utf8)
                    guard seen.insert(key).inserted else { throw NativeSessionError.invalidResponse }
                    if let previous = union[key] {
                        guard Data(previous.name.utf8) == Data(course.name.utf8) else { throw NativeSessionError.invalidResponse }
                    } else {
                        guard union.count < 500 else { throw NativeSessionError.budgetExceeded }
                        union[key] = course; ordered.append(course)
                    }
                }
                if seen.count == result.total { break }
                guard !result.courses.isEmpty else { throw NativeSessionError.invalidResponse }
                page += 1
            }
        }
        return ordered
    }
}

struct LearningInZJUPlatformAdapter: NativePlatformAdapter {
    let descriptor = SourceDescriptor.learningInZJU
    let authentication = NativeAuthenticationConfiguration(
        loginTitle: "学在浙大登录", loginURL: URL(string: "https://courses.zju.edu.cn/")!, backgroundURL: URL(string: "https://courses.zju.edu.cn/robots.txt")!,
        interactiveHosts: ["zjuam.zju.edu.cn", "identity.zju.edu.cn"], scriptObject: #"""
    {
        headers(body) {
            const headers = {};
            if (body !== null) {
                const match = document.cookie.split(';').map(v=>v.trim()).find(v=>v.startsWith('XSRF-TOKEN='));
                if (match) {
                    try { headers['X-XSRF-TOKEN'] = decodeURIComponent(match.slice(11)); }
                    catch (_) { fail('invalidResponse'); }
                }
            }
            return headers;
        },
        async identity(read) {
            const html = await read(origin + '/user/index', 'GET', null, true);
            const node = new DOMParser().parseFromString(html, 'text/html').querySelector('#userId');
            const identity = node && (node.getAttribute('data-id') || node.value || node.getAttribute('value'));
            if (!validID(identity)) fail('loginRequired');
            return identity;
        },
        checkIdentity(expected) {}
    }
    """#)
    func validate(_ r: NativeWebReadRequest) throws {
        let parts = URLComponents(url: r.url, resolvingAgainstBaseURL: false)!
        func same(_ candidate: NativeWebReadRequest) -> Bool {
            var actual = parts, wanted = URLComponents(url: candidate.url, resolvingAgainstBaseURL: false)!
            actual.port = nil; wanted.port = nil
            return r.method == candidate.method && r.body == candidate.body && actual == wanted
        }
        let path = parts.percentEncodedPath
        if path == "/api/my-courses", r.method == "POST", let body = r.body,
           let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let number = fields["page"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           (1...100).contains(number.intValue),
           let descriptor = try? XzzdReadRequest.courses(page: number.intValue), same(NativeWebReadRequest(descriptor)) { return }
        if path.hasPrefix("/api/course/"), path.hasSuffix("/homework-scores"),
           let id = String(path.dropFirst("/api/course/".count).dropLast("/homework-scores".count)).removingPercentEncoding,
           let descriptor = try? XzzdReadRequest.homeworks(courseID: id), same(NativeWebReadRequest(descriptor)) { return }
        if path.hasPrefix("/api/courses/"), path.hasSuffix("/exams"),
           let id = String(path.dropFirst("/api/courses/".count).dropLast("/exams".count)).removingPercentEncoding,
           let descriptor = try? XzzdReadRequest.exams(courseID: id), same(NativeWebReadRequest(descriptor)) { return }
        throw NativeSessionError.unsafeRequest
    }
    @MainActor func collect(scope: SourceScope, reads: NativeReadContext) async throws -> NativeAdapterCollection {
        let courses = try await courses(reads)
        let courseCount = courses.count
        var tasks = [NativeDeadlineTask]()
        for course in courses {
            let homework = try await reads.fetch(NativeWebReadRequest(XzzdReadRequest.homeworks(courseID: course.id)))
            tasks += try XzzdTaskPayload.homeworks(homework, course: course, scope: scope)
            let exams = try await reads.fetch(NativeWebReadRequest(XzzdReadRequest.exams(courseID: course.id)))
            tasks += try XzzdTaskPayload.exams(exams, course: course, scope: scope)
        }
        return NativeAdapterCollection(candidates: tasks, courseCount: courseCount)
    }
    private func courses(_ reads: NativeReadContext) async throws -> [XzzdCourse] {
        var page = 1, baseline: (Int, Int, Int)?, union = [Data: XzzdCourse](), ordered = [XzzdCourse]()
        while true {
            guard page <= 100 else { throw NativeSessionError.budgetExceeded }
            let data = try await reads.fetch(NativeWebReadRequest(XzzdReadRequest.courses(page: page)))
            let result = try XzzdTaskPayload.courses(data)
            guard result.total <= 500, result.pages <= 100 else { throw NativeSessionError.budgetExceeded }
            guard result.page == page, result.pageSize == 100 else { throw NativeSessionError.invalidResponse }
            let metadata = (result.total, result.pages, result.pageSize)
            if let baseline { guard baseline == metadata else { throw NativeSessionError.invalidResponse } }
            else { baseline = metadata }
            let expected = min(100, result.total - ordered.count)
            guard expected >= 0, result.courses.count == expected else { throw NativeSessionError.invalidResponse }
            for course in result.courses {
                let key = Data(course.id.utf8)
                guard union[key] == nil else { throw NativeSessionError.invalidResponse }
                union[key] = course; ordered.append(course)
            }
            if page >= result.pages {
                guard ordered.count == result.total else { throw NativeSessionError.invalidResponse }
                return ordered
            }
            guard !result.courses.isEmpty else { throw NativeSessionError.invalidResponse }
            page += 1
        }
    }
}
