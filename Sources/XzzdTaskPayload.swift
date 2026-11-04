import Foundation

struct XzzdCourse: Equatable { let id: String; let name: String }
struct XzzdCoursePage {
    let courses: [XzzdCourse]
    let page: Int
    let pageSize: Int
    let pages: Int
    let total: Int
}

enum XzzdTaskPayload {
    static func courses(_ data: Data) throws -> XzzdCoursePage {
        let root = try decode(CourseRoot.self, data)
        let page = root.page, size = root.page_size, pages = root.pages, total = root.total
        guard page > 0, size > 0, pages >= 0, total >= 0,
              page <= max(1, pages), root.courses.count <= size else { throw XzzdPayloadError.invalidPayload }
        if total == 0 {
            guard pages <= 1, page == 1, root.courses.isEmpty else { throw XzzdPayloadError.invalidPayload }
        } else {
            guard pages == (total - 1) / size + 1 else { throw XzzdPayloadError.invalidPayload }
        }
        var unique = [Data: XzzdCourse](), ordered = [XzzdCourse]()
        for record in root.courses {
            let course = XzzdCourse(id: record.id.value, name: try name(record.name))
            let key = Data(course.id.utf8)
            if let previous = unique[key] {
                guard Data(previous.name.utf8) == Data(course.name.utf8) else { throw XzzdPayloadError.invalidPayload }
            } else { unique[key] = course; ordered.append(course) }
        }
        let capacity = min(size, total - (page - 1) * size)
        guard unique.count == capacity else { throw XzzdPayloadError.invalidPayload }
        return XzzdCoursePage(courses: ordered, page: page, pageSize: size, pages: pages, total: total)
    }
    static func homeworks(_ data: Data, course: XzzdCourse, scope: SourceScope) throws -> [NativeDeadlineTask] {
        try tasks(decode(HomeworkRoot.self, data).homework_activities, course: course, scope: scope, kind: .homework)
    }
    static func exams(_ data: Data, course: XzzdCourse, scope: SourceScope) throws -> [NativeDeadlineTask] {
        try tasks(decode(ExamRoot.self, data).exams, course: course, scope: scope, kind: .exam)
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try XzzdJSONPreflight.validate(data)
        return try JSONDecoder().decode(type, from: data)
    }
    private static func name(_ value: String) throws -> String {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw XzzdPayloadError.invalidPayload }
        return value
    }
    private static func tasks(_ records: [TaskRecord], course: XzzdCourse, scope: SourceScope, kind: NativeTaskKind) throws -> [NativeDeadlineTask] {
        guard scope.platform == .learningInZJU else { throw XzzdPayloadError.invalidPayload }
        try XzzdID.validate(course.id)
        let courseName = try name(course.name)
        var snapshots = [NativeTaskIdentity: (NativeDeadlineTask, Bool?)](), ordered = [NativeDeadlineTask]()
        for record in records {
            let identity = try NativeTaskIdentity(scope: scope, courseID: course.id, kind: kind, taskID: record.id.value)
            let deadline = try NativeDeadlineParser.parse(record.end_time, naiveTimeZone: TimeZone(identifier: "Asia/Shanghai")!)
            let task = try NativeDeadlineTask(identity: identity, courseName: courseName, title: name(record.title), deadline: deadline)
            if let previous = snapshots[identity] {
                guard previous.0 == task, previous.1 == record.published else { throw NativeTaskError.conflictingSnapshots }
            } else {
                snapshots[identity] = (task, record.published)
                if record.published != false { ordered.append(task) }
            }
        }
        return ordered
    }
    private struct CourseRecord: Decodable { let id: XzzdID; let name: String }
    private struct CourseRoot: Decodable {
        let courses: [CourseRecord]
        let page: Int; let page_size: Int; let pages: Int; let total: Int
    }
    private enum CollectionKeys: String, CodingKey { case homework_activities, exams, page, page_size, pages, total }
    private static func validatePagination(_ fields: KeyedDecodingContainer<CollectionKeys>, count: Int) throws {
        let keys: [CollectionKeys] = [.page, .page_size, .pages, .total]
        guard keys.contains(where: { fields.contains($0) }) else { return }
        guard keys.allSatisfy({ fields.contains($0) }) else { throw XzzdPayloadError.invalidPayload }
        for key in keys {
            let value = try fields.decode(Int.self, forKey: key)
            let valid: Bool
            switch key {
            case .page: valid = value == 1
            case .page_size: valid = value > 0 && value >= count
            case .pages: valid = value == 1 || (value == 0 && count == 0)
            case .total: valid = value == count
            default: valid = false
            }
            guard valid else { throw XzzdPayloadError.invalidPayload }
        }
    }
    private struct HomeworkRoot: Decodable {
        let homework_activities: [TaskRecord]
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CollectionKeys.self)
            homework_activities = try fields.decode([TaskRecord].self, forKey: .homework_activities)
            try validatePagination(fields, count: homework_activities.count)
        }
    }
    private struct ExamRoot: Decodable {
        let exams: [TaskRecord]
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CollectionKeys.self)
            exams = try fields.decode([TaskRecord].self, forKey: .exams)
            try validatePagination(fields, count: exams.count)
        }
    }
    private struct TaskRecord: Decodable {
        let id: XzzdID
        let title: String
        let end_time: String?
        let published: Bool?
        enum CodingKeys: String, CodingKey { case id, title, end_time, published }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try fields.decode(XzzdID.self, forKey: .id)
            title = try fields.decode(String.self, forKey: .title)
            end_time = try fields.decodeIfPresent(String.self, forKey: .end_time)
            // Explicit null is not a publication boolean.
            published = fields.contains(.published) ? try fields.decode(Bool.self, forKey: .published) : nil
        }
    }
}

struct XzzdReadRequest {
    let method: String
    let url: URL
    let body: Data?
    static func courses(page: Int) throws -> Self {
        guard page > 0 else { throw XzzdPayloadError.invalidRequest }
        let body = try JSONSerialization.data(withJSONObject: [
            "page": page, "page_size": 100, "fields": "id,name",
            "conditions": ["status": ["ongoing", "notStarted", "ended"], "keyword": ""]
        ], options: [.sortedKeys])
        return try make(method: "POST", path: "/api/my-courses", body: body)
    }
    static func homeworks(courseID: String) throws -> Self {
        try make(method: "GET", path: "/api/course/" + segment(courseID) + "/homework-scores", query: [
            URLQueryItem(name: "fields", value: "id,title,data,start_time,end_time,published,is_in_progress")])
    }
    static func exams(courseID: String) throws -> Self {
        try make(method: "GET", path: "/api/courses/" + segment(courseID) + "/exams")
    }
    private static func segment(_ id: String) throws -> String {
        try XzzdID.validate(id)
        guard id != ".", id != "..", let encoded = id.addingPercentEncoding(withAllowedCharacters:
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) else { throw XzzdPayloadError.invalidRequest }
        return encoded
    }
    private static func make(method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil) throws -> Self {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "courses.zju.edu.cn"; parts.percentEncodedPath = path
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw XzzdPayloadError.invalidRequest }
        return Self(method: method, url: url, body: body)
    }
}

private enum XzzdPayloadError: Error { case invalidPayload, invalidRequest }
private struct XzzdID: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let field = try decoder.singleValueContainer()
        if let string = try? field.decode(String.self) { value = string }
        else { value = String(try field.decode(Int64.self)) }
        try Self.validate(value)
    }
    static func validate(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 1024,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw XzzdPayloadError.invalidPayload }
    }
}

// Foundation validates JSON grammar and typed decoding owns the schema. This narrow
// lexical preflight prevents Int64 decoding from rounding decimal/exponent IDs,
// and rejects ambiguous keys before Foundation can discard duplicates. It builds
// no value tree and never normalizes arbitrary-precision numbers.
private enum XzzdJSONPreflight {
    static func validate(_ data: Data) throws {
        _ = try JSONSerialization.jsonObject(with: data)
        guard let text = String(data: data, encoding: .utf8) else { throw XzzdPayloadError.invalidPayload }
        let pattern = #""(?:[^"\\]|\\.)*"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|[{}\[\],:]|true|false|null"#
        let regex = try NSRegularExpression(pattern: pattern)
        let source = text as NSString
        let tokens = regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }
        var frames = [Set<String>?]()
        let integerKeys: Set<String> = ["id", "_id", "page", "page_size", "pages", "total"]
        for (index, token) in tokens.enumerated() {
            switch token {
            case "{": frames.append(Set<String>())
            case "[": frames.append(nil)
            case "}", "]": frames.removeLast()
            default:
                guard token.first == "\"", index + 1 < tokens.count, tokens[index + 1] == ":" else { continue }
                let key = try JSONDecoder().decode(String.self, from: Data(token.utf8))
                guard var keys = frames.last ?? nil, keys.insert(key).inserted else { throw XzzdPayloadError.invalidPayload }
                frames[frames.count - 1] = keys
                if frames.count == 1 {
                    if key == "response" || key == "data" { throw XzzdPayloadError.invalidPayload }
                }
                if integerKeys.contains(key), index + 2 < tokens.count {
                    let number = tokens[index + 2]
                    if number.first == "-" || number.first?.isNumber == true {
                        guard !number.contains("."), !number.lowercased().contains("e"), Int64(number) != nil else { throw XzzdPayloadError.invalidPayload }
                    }
                }
            }
        }
    }
}
