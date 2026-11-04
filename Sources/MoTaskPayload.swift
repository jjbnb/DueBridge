import Foundation

struct MoCourse: Equatable { let id: String; let name: String }
struct MoCoursePage { let courses: [MoCourse]; let total: Int }
enum MoTaskPayload {
    static func courses(_ data: Data) throws -> MoCoursePage {
        do {
            let root = try unwrap(data)
            let records: [MoJSON]
            switch root["objects"] {
            case .array(let values): records = values
            case .object(let values): records = Array(values.values)
            default: throw MoPayloadError.invalidPayload
            }
            guard case .number(let count)? = root["count"], let total = integer(count).flatMap(Int.init), total >= 0 else { throw MoPayloadError.invalidPayload }
            var unique = [Data: MoCourse]()
            for record in records {
                guard case .object(let fields) = record else { throw MoPayloadError.invalidPayload }
                let course = MoCourse(id: try identifier(fields), name: try requiredName(fields, keys: ["name_cn", "name"]))
                let key = Data(course.id.utf8)
                if let previous = unique[key], Data(previous.name.utf8) != Data(course.name.utf8) { throw MoPayloadError.invalidPayload }
                unique[key] = course
            }
            guard total >= unique.count else { throw MoPayloadError.invalidPayload }
            return MoCoursePage(courses: Array(unique.values), total: total)
        } catch { throw MoPayloadError.invalidPayload }
    }
    private static func unwrap(_ data: Data) throws -> [String: MoJSON] {
        guard case .object(let root) = try MoJSON.parse(data) else { throw MoPayloadError.invalidPayload }
        if let response = root["response"] {
            guard case .object(let wrapped) = response else { throw MoPayloadError.invalidPayload }
            return wrapped
        }
        return root
    }
    private static func integer(_ raw: String) -> String? {
        // Work on decimal digits, never a floating-point or bounded Decimal approximation.
        var text = raw.lowercased()
        let negative = text.first == "-"
        if negative { text.removeFirst() }
        let pieces = text.split(separator: "e", omittingEmptySubsequences: false)
        let mantissa = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        var digits = mantissa.joined()
        if digits.allSatisfy({ $0 == "0" }) { return "0" }
        guard pieces.count == 1 || Int(pieces[1]) != nil else { return nil }
        let exponent = pieces.count == 2 ? Int(pieces[1])! : 0
        guard (-2048...2048).contains(exponent) else { return nil }
        let scale = (mantissa.count == 2 ? mantissa[1].count : 0) - exponent
        if scale > 0 {
            guard scale <= digits.count, digits.suffix(scale).allSatisfy({ $0 == "0" }) else { return nil }
            digits.removeLast(scale)
        } else if scale < 0 {
            guard digits.count - scale <= 1024 else { return nil }
            digits += String(repeating: "0", count: -scale)
        }
        digits = String(digits.drop(while: { $0 == "0" }))
        guard !digits.isEmpty, digits.count <= 1024 else { return nil }
        return (negative ? "-" : "") + digits
    }
    private static func identifier(_ fields: [String: MoJSON]) throws -> String {
        func value(_ field: MoJSON) throws -> String {
            let text: String
            switch field {
            case .string(let string): text = string
            case .number(let number):
                guard let exact = integer(number) else { throw MoPayloadError.invalidPayload }
                text = exact
            default: throw MoPayloadError.invalidPayload
            }
            guard !text.isEmpty, text.utf8.count <= 1024,
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw MoPayloadError.invalidPayload }
            return text
        }
        let id = try fields["id"].map(value), underscore = try fields["_id"].map(value)
        if let id, let underscore, Data(id.utf8) != Data(underscore.utf8) { throw MoPayloadError.invalidPayload }
        guard let result = underscore ?? id else { throw MoPayloadError.invalidPayload }
        return result
    }
    private static func optionalName(_ fields: [String: MoJSON], keys: [String]) throws -> String? {
        for key in keys {
            guard let field = fields[key] else { continue }
            if case .null = field { continue }
            guard case .string(let value) = field else { throw MoPayloadError.invalidPayload }
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return nil
    }
    private static func requiredName(_ fields: [String: MoJSON], keys: [String]) throws -> String {
        guard let value = try optionalName(fields, keys: keys) else { throw MoPayloadError.invalidPayload }
        return value
    }
    static func tasks(_ data: Data, course: MoCourse, scope: SourceScope) throws -> [NativeDeadlineTask] {
        do {
            guard scope.platform == .mo else { throw MoPayloadError.invalidPayload }
            let root = try unwrap(data)
            guard case .object(let info)? = root["info"],
                  case .array(let homework)? = root["homework_sections"],
                  case .array(let papers)? = root["paper_sections"],
                  Data(try identifier(info).utf8) == Data(course.id.utf8) else { throw MoPayloadError.invalidPayload }
            let courseName = try optionalName(info, keys: ["name_cn", "name"]) ?? course.name
            var unique = [NativeTaskIdentity: NativeDeadlineTask]()
            func append(_ fields: [String: MoJSON], title: String, kind: NativeTaskKind, deadline: MoJSON?) throws {
                let raw: String?
                switch deadline {
                case .none, .null?: raw = nil
                case .string(let string)?: raw = string
                default: throw MoPayloadError.invalidPayload
                }
                let identity = try NativeTaskIdentity(scope: scope, courseID: course.id, kind: kind, taskID: identifier(fields))
                let task = try NativeDeadlineTask(identity: identity, courseName: courseName, title: title,
                    deadline: NativeDeadlineParser.parse(raw, naiveTimeZone: TimeZone(secondsFromGMT: 0)!))
                if let previous = unique[identity], previous != task { throw MoPayloadError.invalidPayload }
                unique[identity] = task
            }
            for record in homework {
                guard case .object(let section) = record,
                      case .array(let units)? = section["units"], !units.isEmpty,
                      units.allSatisfy({ if case .object = $0 { return true }; return false }),
                      case .object(let unit) = units[0] else { throw MoPayloadError.invalidPayload }
                if let hidden = unit["hide_in_list"] {
                    guard case .bool(let value) = hidden else { throw MoPayloadError.invalidPayload }
                    if value { continue }
                }
                try append(unit, title: requiredName(unit, keys: ["zh_name", "name"]), kind: .homework, deadline: unit["end_time"])
            }
            for record in papers {
                guard case .object(let section) = record, case .object(let paper)? = section["question_paper"] else { throw MoPayloadError.invalidPayload }
                try append(section, title: requiredName(section, keys: ["name_cn"]), kind: .practice, deadline: paper["end_time"])
            }
            return Array(unique.values)
        } catch { throw MoPayloadError.invalidPayload }
    }
}
struct MoReadRequest {
    let method: String
    let url: URL
    static func courses(status: String, page: Int) throws -> Self {
        guard ["pending", "learning", "finished"].contains(status), page > 0 else { throw MoPayloadError.invalidRequest }
        return try make(path: "/pyapi/course", query: [
            URLQueryItem(name: "group", value: "my"), URLQueryItem(name: "type", value: "all"),
            URLQueryItem(name: "learning_status", value: status), URLQueryItem(name: "page_no", value: String(page)),
            URLQueryItem(name: "page_size", value: "100")])
    }
    static func course(id: String) throws -> Self {
        guard !id.isEmpty, id != ".", id != "..", id.utf8.count <= 1024,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let segment = id.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_~")) else { throw MoPayloadError.invalidRequest }
        return try make(path: "/pyapi/course/section/" + segment, query: [URLQueryItem(name: "is_backstage", value: "false")])
    }
    private static func make(path: String, query: [URLQueryItem]) throws -> Self {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "mo.zju.edu.cn"
        parts.percentEncodedPath = path; parts.queryItems = query
        guard let url = parts.url else { throw MoPayloadError.invalidRequest }
        return Self(method: "GET", url: url)
    }
}

private enum MoPayloadError: LocalizedError {
    case invalidPayload, invalidRequest
    var errorDescription: String? {
        switch self {
        case .invalidPayload: return "MO task data has an unsupported or invalid format."
        case .invalidRequest: return "MO read request has invalid parameters."
        }
    }
}

// Foundation validates JSON grammar; this small value reader preserves number lexemes.
// Exact opaque IDs must never be rounded by NSNumber, Double, or Decimal decoding.
private enum MoJSON {
    case object([String: MoJSON]), array([MoJSON]), string(String), number(String), bool(Bool), null
    static func parse(_ data: Data) throws -> MoJSON {
        guard String(data: data, encoding: .utf8) != nil else { throw MoPayloadError.invalidPayload }
        _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        var reader = Reader(bytes: Array(data))
        return try reader.value()
    }
    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func string() throws -> String {
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 92 { index += 1 }
                else if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
            }
            throw MoPayloadError.invalidPayload
        }
        mutating func value() throws -> MoJSON {
            space()
            guard index < bytes.count else { throw MoPayloadError.invalidPayload }
            switch bytes[index] {
            case 123:
                index += 1; space()
                var fields = [String: MoJSON]()
                if bytes[index] == 125 { index += 1; return .object(fields) }
                while true {
                    space(); let key = try string(); space(); index += 1
                    // Reject exact duplicates and canonical Unicode collisions before Swift's
                    // String-keyed storage can silently discard an object member.
                    guard fields[key] == nil else { throw MoPayloadError.invalidPayload }
                    fields[key] = try value(); space()
                    let delimiter = bytes[index]; index += 1
                    if delimiter == 125 { return .object(fields) }
                }
            case 91:
                index += 1; space()
                var values = [MoJSON]()
                if bytes[index] == 93 { index += 1; return .array(values) }
                while true {
                    values.append(try value()); space()
                    let delimiter = bytes[index]; index += 1
                    if delimiter == 93 { return .array(values) }
                }
            case 34: return .string(try string())
            case 116: index += 4; return .bool(true)
            case 102: index += 5; return .bool(false)
            case 110: index += 4; return .null
            default:
                let start = index
                while index < bytes.count && "-+0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
                guard index > start else { throw MoPayloadError.invalidPayload }
                return .number(String(decoding: bytes[start..<index], as: UTF8.self))
            }
        }
    }
}
