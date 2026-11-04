// Synthetic fixtures only; public school domains test exact request policies.
import Foundation

@main
struct MoTaskPayloadTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) {
        checks += 1
        do { if try !value() { print("FAIL: \(message)"); exit(1) } }
        catch { print("FAIL: \(message): \(error.localizedDescription)"); exit(1) }
    }
    static func rejects(_ message: String, _ run: () throws -> Void) {
        do { try run(); check(false, message) } catch { check(true, message) }
    }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
    static let utc = TimeZone(secondsFromGMT: 0)!
    static let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    static func main() throws {
        // Removing strict time parsing, changing the naive zone or silently normalizing dates must fail these.
        let naive = try NativeDeadlineParser.parse("2026-11-05 15:59:00", naiveTimeZone: utc)
        check(naive?.date.timeIntervalSince1970 == 1793894340, "naive MO deadline is UTC")
        check(naive?.components.hour == 23 && naive?.components.minute == 59 && naive?.isAllDay == false && naive?.timeZone == shanghai, "deadline renders Shanghai civil time")
        let local = try NativeDeadlineParser.parse("2026-11-05 15:59:00", naiveTimeZone: shanghai)
        check(naive!.date.timeIntervalSince(local!.date) == 28800, "caller selects naive convention with eight hour difference")
        for zone in [utc, shanghai] {
            check(try NativeDeadlineParser.parse("2026-11-05T15:59:00Z", naiveTimeZone: zone)?.date == naive?.date, "Z ignores naive convention")
            check(try NativeDeadlineParser.parse("2026-11-05T23:59:00+08:00", naiveTimeZone: zone)?.date == naive?.date, "numeric offset retains actual instant")
            check(try NativeDeadlineParser.parse("2026-11-05T10:29:00-0530", naiveTimeZone: zone)?.date == naive?.date, "negative compact offset supported")
        }
        let fractional = try NativeDeadlineParser.parse("2026-11-05T15:59:00.125Z", naiveTimeZone: utc)!
        check(abs(fractional.date.timeIntervalSince1970 - 1793894340.125) < 0.00001, "fractional seconds preserved")
        check(try NativeDeadlineParser.parse("2024-02-29 00:00:00", naiveTimeZone: utc) != nil, "Gregorian leap day supported")
        for empty in [nil, "", " \n "] as [String?] { check(try NativeDeadlineParser.parse(empty, naiveTimeZone: utc) == nil, "missing or blank deadline stays nil") }
        for invalid in ["2026-02-29 12:00:00", "2026-04-31 12:00:00", "2026-13-01 12:00:00", "2026-01-00 12:00:00", "2026-01-01 24:00:00", "2026-01-01 23:60:00", "2026-01-01 23:59:60", "2026-11-05", "15:59:00", "nan", "Infinity", "1969-12-31T23:59:59Z", "2026-11-05T15:59:00+24:00", "2026-11-05T15:59:00Zsecret", "2026-1-5 15:59:00"] {
            rejects("malformed nonempty deadline rejected") { _ = try NativeDeadlineParser.parse(invalid, naiveTimeZone: utc) }
        }
        rejects("pre-epoch fractional timestamp cannot round up to epoch") {
            _ = try NativeDeadlineParser.parse("1969-12-31T23:59:59.999999999999999999Z", naiveTimeZone: utc)
        }
        check(try NativeDeadlineParser.parse("1970-01-01T00:00:00Z", naiveTimeZone: utc)?.date.timeIntervalSince1970 == 0, "past/epoch deadlines retained")
        try courses()
        try tasks()
        try requests()
        print("PASS: \(checks) MO payload checks")
    }
    static func courses() throws {
        // Catches guessed envelopes, silent page completeness, boolean IDs, and conflicting snapshots.
        let unicodeKeys = Data(#"{"objects":{"\u00e9":{"id":"a","name":"A"},"e\u0301":{"id":"b","name":"B"}},"count":2}"#.utf8)
        rejects("distinct canonically equivalent JSON keys reject before course loss") { _ = try MoTaskPayload.courses(unicodeKeys) }
        let repeatedKey = Data(#"{"objects":{"same":{"id":"a","name":"A"},"same":{"id":"b","name":"B"}},"count":2}"#.utf8)
        rejects("conflicting repeated exact JSON keys reject before overwrite") { _ = try MoTaskPayload.courses(repeatedKey) }
        let c: [String: Any] = ["_id": "c1", "name_cn": "Course"]
        let page = try MoTaskPayload.courses(json(["response": ["objects": [c, c], "count": 4]]))
        check(page.total == 4 && page.courses == [MoCourse(id: "c1", name: "Course")], "wrapped course page coalesces exact duplicates without requiring complete pagination")
        let dictionary = try MoTaskPayload.courses(json(["objects": ["key": ["id": 42, "name": "Numeric"]], "count": 1]))
        check(dictionary.courses.first?.id == "42", "dictionary values and integer IDs accepted")
        check(try MoTaskPayload.courses(json(["objects": [], "count": 0])).courses.isEmpty, "valid empty page accepted")
        check(try MoTaskPayload.courses(json(["objects": [:], "count": 0])).total == 0, "empty dictionary page accepted")
        check(try MoTaskPayload.courses(json(["objects": [["id": 42, "_id": "42", "name": "Same"]], "count": 1])).courses.count == 1, "matching alternate IDs accepted")
        for invalid: Any in [[], ["data": ["objects": [c], "count": 1]], ["objects": [c]], ["count": 0], ["objects": [], "count": -1], ["objects": [], "count": true], ["objects": [], "count": 0.5], ["response": NSNull(), "objects": [], "count": 0], ["objects": [c], "count": 0], ["objects": ["bad"], "count": 1], ["objects": [["id": "x"]], "count": 1], ["objects": [c, ["id": "c1", "name": "Other"]], "count": 2]] {
            rejects("invalid course page fails closed") { _ = try MoTaskPayload.courses(json(invalid)) }
        }
        for id: Any in [true, 1.25, "", NSNull(), [], [:]] {
            rejects("invalid identifier type rejected") { _ = try MoTaskPayload.courses(json(["objects": [["id": id, "name": "Course"]], "count": 1])) }
        }
        rejects("conflicting alternate course IDs rejected") { _ = try MoTaskPayload.courses(json(["objects": [["id": "a", "_id": "b", "name": "Course"]], "count": 1])) }
        for numeric in ["1.00000000000000001", "1.00000000000000000000000000000000000000001"] {
            let payload = Data(("{\"objects\":[{\"id\":" + numeric + ",\"name\":\"Fraction\"}],\"count\":1}").utf8)
            rejects("nonintegral numeric IDs never round into identities") { _ = try MoTaskPayload.courses(payload) }
        }
        let escapedCourse = try MoTaskPayload.courses(json(["objects": [["id": "课程\"\\ID", "name": "中文\nName"]], "count": 1]))
        check(escapedCourse.courses.first?.id == "课程\"\\ID" && escapedCourse.courses.first?.name == "中文\nName", "JSON escapes and UTF8 names survive exact-number reading")
        let wide = Data(#"{"objects":[{"id":12345678901234567890123456789012345678901234567890,"name":"Wide"}],"count":1}"#.utf8)
        check(try MoTaskPayload.courses(wide).courses.first?.id == "12345678901234567890123456789012345678901234567890", "wide integer identity never rounds through Decimal")
        let large = Data(#"{"objects":[{"id":9007199254740993,"name":"Large"}],"count":1}"#.utf8)
        check(try MoTaskPayload.courses(large).courses.first?.id == "9007199254740993", "large integer ID remains exact decimal text")
    }
    static let course = MoCourse(id: "c1", name: "Listed course")
    static func scope(_ platform: NativePlatform = .mo) throws -> SourceScope {
        try SourceScope(platform: platform, host: platform.verifiedHost, connectionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    }
    static func detail(_ homework: [[String: Any]] = [], _ papers: [[String: Any]] = []) -> [String: Any] {
        ["info": ["_id": "c1", "name_cn": "Current course"], "homework_sections": homework, "paper_sections": papers]
    }
    static func read(_ object: Any) throws -> [NativeDeadlineTask] { try MoTaskPayload.tasks(json(object), course: course, scope: scope()) }
    static func tasks() throws {
        // Catches unit/section/template identity confusion, recursive flattening and deadline fallbacks.
        let unit: [String: Any] = ["id": "u1", "zh_name": "Homework", "end_time": "2026-11-05 15:59:00", "homework_submitted": true]
        let hw: [String: Any] = ["id": "h1", "units": [unit, ["id": "video", "name": "Video", "end_time": "invalid"]]]
        let paper: [String: Any] = ["id": "p1", "name_cn": "Paper", "end_time": "invalid", "question_paper": ["question_paper_id": "template", "end_time": "2026-11-06T00:00:00Z", "score": 100]]
        var secondPaper = paper; secondPaper["id"] = "p2"
        let candidates = try read(["response": detail([hw], [paper, secondPaper])])
        check(candidates.count == 3, "only first homework unit and each enclosing paper section become candidates")
        let homework = candidates.first { $0.identity.kind == .homework }!
        check(homework.identity.taskID == "u1" && homework.identity.courseID == "c1" && homework.title == "Homework", "homework uses durable unit identity and unit title")
        check(homework.courseName == "Current course" && homework.deadline?.date.timeIntervalSince1970 == 1793894340, "current detail name and unit end_time win")
        check(Set(candidates.filter { $0.identity.kind == .practice }.map { $0.identity.taskID }) == ["p1", "p2"], "reused paper template has distinct section identities")
        check(candidates.filter { $0.identity.kind == .practice }.allSatisfy { $0.deadline?.date.timeIntervalSince1970 == 1793923200 }, "paper uses nested question_paper.end_time")
        check(try NativeTaskSelection.select(candidates).tasks.count == 3, "submitted and scored tasks remain eligible")
        check(try read(detail()).isEmpty, "valid empty detail accepted")
        var fallback = detail(); fallback["info"] = ["id": "c1"]
        fallback["homework_sections"] = [["units": [["_id": 99, "name": "Fallback", "start_time": "2026-01-01 00:00:00", "answer_deadline": "2026-11-05 15:59:00"]]]]
        let noDeadline = try read(fallback)
        check(noDeadline.count == 1 && noDeadline[0].deadline == nil && noDeadline[0].courseName == "Listed course" && noDeadline[0].identity.taskID == "99", "missing end_time preserves candidate without fallback")
        check(try NativeTaskSelection.select(noDeadline).skippedWithoutDeadline == 1, "caller can count missing deadlines")
        for empty: Any in [NSNull(), "", " "] {
            check(try read(detail([["units": [["id": "u1", "name": "No deadline", "end_time": empty]]]])).first?.deadline == nil, "null/blank deadlines preserved")
        }
        let missingPaper = try read(detail([], [["id": "p0", "name_cn": "Unscheduled", "question_paper": ["start_time": "2026-11-05 15:59:00", "answer_deadline": "2026-11-06 15:59:00", "objective_time_limit": 60]]]))
        check(missingPaper.count == 1 && missingPaper[0].deadline == nil, "paper start/answer deadline/time limit never synthesize deadline")
        var hidden = unit; hidden["hide_in_list"] = true
        check(try read(detail([["units": [hidden]]])).isEmpty, "hidden homework excluded")
        var visible = unit; visible["hide_in_list"] = false
        check(try read(detail([["units": [visible]]])).count == 1, "explicit false remains visible")
        check(try read(detail([hw, hw], [paper, paper])).count == 2, "exact duplicate task snapshots coalesce")
        var changed = unit; changed["end_time"] = NSNull()
        rejects("deadline-vs-nil duplicate conflict rejected") { _ = try read(detail([hw, ["units": [changed]]])) }
        changed = unit; changed["zh_name"] = "Renamed"
        rejects("title duplicate conflict rejected") { _ = try read(detail([hw, ["units": [changed]]])) }
        for bad: Any in [["info": ["id": "wrong"], "homework_sections": [], "paper_sections": []], ["info": ["id": "c1", "_id": "wrong"], "homework_sections": [], "paper_sections": []], ["homework_sections": [], "paper_sections": []], ["info": ["id": "c1"]], ["info": ["id": "c1"], "homework_sections": [], "paper_sections": [:]], detail([["student_question": ["end_time": "2026-11-05 15:59:00"]]]), detail([["units": []]]), detail([["units": ["bad"]]]), detail([["units": [unit, "bad"]]]), detail([], [["id": "p", "name_cn": "Paper"]]), detail([], [["id": "p", "name_cn": "Paper", "question_paper": NSNull()]])] {
            rejects("invalid detail rejects whole course") { _ = try read(bad) }
        }
        for key in ["hide_in_list", "end_time", "id", "zh_name"] {
            var bad = unit; bad[key] = key == "hide_in_list" ? 1 : true
            rejects("invalid unit field rejects course") { _ = try read(detail([hw, ["units": [bad]]])) }
        }
        var ambiguous = unit; ambiguous["_id"] = "different"
        rejects("conflicting unit alternate ID rejected") { _ = try read(detail([["units": [ambiguous]]])) }
        var invalidPaper = paper; invalidPaper["_id"] = "different"
        rejects("conflicting paper alternate ID rejected") { _ = try read(detail([], [invalidPaper])) }
        invalidPaper = paper; invalidPaper["question_paper"] = ["end_time": "2026-11-05"]
        rejects("date-only paper deadline rejected") { _ = try read(detail([], [invalidPaper])) }
        var fractionalUnit = unit; fractionalUnit["end_time"] = "2026-11-05T15:59:00.125Z"
        check(try read(detail([["units": [fractionalUnit]]])).first?.deadline?.date.timeIntervalSince1970 == 1793894340.125, "fractional deadline remains coherent through reviewed model validation")
        var badDeadline = unit; badDeadline["end_time"] = "2026-02-30 12:00:00"
        rejects("invalid deadline fails entire course") { _ = try read(detail([hw, ["units": [badDeadline]]])) }
        rejects("wrong platform scope rejected") { _ = try MoTaskPayload.tasks(json(detail()), course: course, scope: scope(.learningInZJU)) }
        let sensitive = Data(#"{"response":"secret-token-at-private-url"}"#.utf8)
        do { _ = try MoTaskPayload.tasks(sensitive, course: course, scope: scope()); check(false, "error expected") }
        catch { check(!error.localizedDescription.contains("secret") && !error.localizedDescription.contains("private"), "errors do not echo payload content") }
    }
    static func requests() throws {
        // Catches accidentally writable endpoints, loose hosts, dropped pagination and opaque path injection.
        for status in ["pending", "learning", "finished"] {
            let request = try MoReadRequest.courses(status: status, page: 2)
            let parts = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
            let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            check(request.method == "GET" && parts.scheme == "https" && parts.host == "mo.zju.edu.cn" && parts.path == "/pyapi/course", "read-only verified collection endpoint")
            check(query == ["group": "my", "type": "all", "learning_status": status, "page_no": "2", "page_size": "100"], "complete course filter and paging query")
        }
        for status in ["all", "unstarted", "learning&token=secret", ""] { rejects("unsupported collection status rejected") { _ = try MoReadRequest.courses(status: status, page: 1) } }
        for page in [0, -1] { rejects("nonpositive pages rejected") { _ = try MoReadRequest.courses(status: "learning", page: page) } }
        for id in ["opaque/id?token=x#fragment", "https://evil.test/a", "百分号% 空格", "a\\b", "a%2Fb"] {
            let request = try MoReadRequest.course(id: id)
            let parts = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
            check(request.method == "GET" && parts.host == "mo.zju.edu.cn" && parts.scheme == "https" && parts.user == nil && parts.password == nil && parts.fragment == nil, "opaque ID cannot change authority or fragment")
            check(parts.queryItems == [URLQueryItem(name: "is_backstage", value: "false")], "opaque ID cannot inject query")
            let segment = String(parts.percentEncodedPath.dropFirst("/pyapi/course/section/".count))
            check(!segment.contains("/") && segment.removingPercentEncoding == id, "ID encoded as exactly one reversible path segment")
        }
        for invalid in ["", ".", "..", "a\n"] { rejects("unsafe path ID rejected") { _ = try MoReadRequest.course(id: invalid) } }
    }

}
