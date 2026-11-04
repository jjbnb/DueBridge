// Synthetic fixtures only; public school domains test exact request policies.
import Foundation

@main
struct XzzdTaskPayloadTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) {
        checks += 1
        do { if try !value() { print("FAIL: \(message)"); exit(1) } }
        catch { print("FAIL: \(message): \(error)"); exit(1) }
    }
    static func rejects(_ message: String, _ run: () throws -> Void) {
        do { try run(); check(false, message) } catch { check(true, message) }
    }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
    static func page(_ courses: [Any], page: Any = 1, size: Any = 100, pages: Any = 1, total: Any = 1) -> [String: Any] {
        ["courses": courses, "page": page, "page_size": size, "pages": pages, "total": total]
    }
    static let course = XzzdCourse(id: "100001", name: "Synthetic course")
    static func main() throws {
        switch CommandLine.arguments.dropFirst().first {
        case "tasks": try tasks()
        case "requests": try requests()
        default: try courses(); try tasks(); try requests()
        }
        print("PASS: \(checks) xzzd payload checks")
    }
    static func courses() throws {
        // Catches envelope guessing, dropped pagination, ID rounding and conflicting course names.
        let c: [String: Any] = ["id": 100001, "name": "Synthetic course"]
        check(try XzzdTaskPayload.courses(json(page([c]))).courses == [course], "root course collection accepted")
        let result = try XzzdTaskPayload.courses(json(page([c, c], page: 2, pages: 2, total: 101)))
        check(result.courses == [course], "root course records use exact id/name and coalesce")
        check(result.page == 2 && result.pageSize == 100 && result.pages == 2 && result.total == 101, "pagination preserved for later enumeration")
        check(try XzzdTaskPayload.courses(json(page([], pages: 0, total: 0))).courses.isEmpty, "zero-page empty collection allowed")
        check(try XzzdTaskPayload.courses(json(page([], pages: 1, total: 0))).total == 0, "empty first page allowed")
        let other: [String: Any] = ["id": 100002, "name": "Other course"]
        rejects("two distinct courses cannot fit last-page capacity of one") {
            _ = try XzzdTaskPayload.courses(json(page([c, other], page: 2, pages: 2, total: 101)))
        }
        rejects("short earlier course page cannot conceal missing courses") {
            _ = try XzzdTaskPayload.courses(json(page([c], pages: 2, total: 101)))
        }
        rejects("duplicate earlier courses cannot conceal missing distinct courses") {
            _ = try XzzdTaskPayload.courses(json(page([c, c], size: 2, pages: 2, total: 3)))
        }
        check(try XzzdTaskPayload.courses(json(page([c, other], size: 2, pages: 2, total: 3))).courses.count == 2, "full earlier course page accepted")
        check(try XzzdTaskPayload.courses(json(page([c], page: 2, pages: 2, total: 101))).courses == [course], "valid last-page capacity of one accepted")
        for invalid: Any in [[], ["response": page([c])], ["data": page([c])], ["courses": [c]], ["page": 1, "page_size": 100, "pages": 1, "total": 0], page([c], page: 0), page([c], size: 0), page([c], pages: 0), page([c], total: -1), page([c], page: 2), page([c], total: 0), page([c], total: 101), page([c], size: true), page([c], total: 1.25), page([c, ["id": 100001, "name": "Changed"]], total: 2), page([["id": "x"]]), page([["id": "x", "name": " "]]), page(["bad"])] {
            rejects("invalid root/course/pagination fails closed") { _ = try XzzdTaskPayload.courses(json(invalid)) }
        }
        for raw in ["true", "null", "1.25", "1.00000000000000001", "1.00000000000000000000000000000000000000001", "9223372036854775808", "1e1000", "[]", "{}", #"""#] {
            let data = Data(("{\"courses\":[{\"id\":" + raw + ",\"name\":\"Course\"}],\"page\":1,\"page_size\":100,\"pages\":1,\"total\":1}").utf8)
            rejects("unsupported ID \(raw) never becomes rounded identity") { _ = try XzzdTaskPayload.courses(data) }
        }
        for raw in ["9007199254740993", "9223372036854775807", "-9223372036854775808"] {
            let data = Data(("{\"courses\":[{\"id\":" + raw + ",\"name\":\"Course\"}],\"page\":1,\"page_size\":100,\"pages\":1,\"total\":1}").utf8)
            check(try XzzdTaskPayload.courses(data).courses.first?.id == raw, "bounded integer IDs stay exact beyond Double precision")
        }
        for raw in [
            #"{"courses":[{"id":"a","id":"b","name":"A"}],"page":1,"page_size":100,"pages":1,"total":1}"#,
            #"{"courses":[{"id":"a","name":"A","é":1,"e\u0301":2}],"page":1,"page_size":100,"pages":1,"total":1}"#,
            #"{"courses":[],"page":1,"page_size":100,"pages":0,"total":0.00000000000000000001}"#,
            #"{"response":{},"courses":[],"page":1,"page_size":100,"pages":0,"total":0}"#
        ] {
            rejects("ambiguous keys, mixed envelopes and fractional metadata rejected") { _ = try XzzdTaskPayload.courses(Data(raw.utf8)) }
        }
        rejects("HTML rejected") { _ = try XzzdTaskPayload.courses(Data("<html>login</html>".utf8)) }
    }
    static func tasks() throws {
        let scope = try SourceScope(platform: .learningInZJU, host: "courses.zju.edu.cn", connectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let mo = try SourceScope(platform: .mo, host: "mo.zju.edu.cn", connectionID: scope.connectionID)
        func read(_ records: [Any], exam: Bool = false) throws -> [NativeDeadlineTask] {
            let data = try json([exam ? "exams" : "homework_activities": records])
            return exam ? try XzzdTaskPayload.exams(data, course: course, scope: scope) : try XzzdTaskPayload.homeworks(data, course: course, scope: scope)
        }
        // Catches UTC default, activity-ID substitution, kind collisions and invented completion filtering.
        let h: [String: Any] = ["id": 200001, "title": "Synthetic task", "end_time": "2026-11-05 23:59:00", "submitted": true, "status_code": "submitted", "score": 9.25, "is_closed": true]
        check(try read([h]).count == 1, "homework collection with fractional score accepted")
        let homework = try read([h])[0]
        let exam = try read([h.merging(["activity_id": "different", "learning_activity_id": "other"]) { _, new in new }], exam: true)[0]
        check(homework.deadline?.date.timeIntervalSince1970 == 1793894340, "school-local Nov5 23:59 means 15:59 UTC")
        check(homework.deadline?.components.hour == 23 && homework.deadline?.components.minute == 59 && homework.deadline?.isAllDay == false, "civil deadline and time-of-day preserved")
        check(homework.identity.taskID == "200001" && exam.identity.taskID == "200001" && exam.identity.kind == .exam && homework.identity.kind == .homework && homework.identity != exam.identity, "exam.id preserved and kinds never collide")
        check(homework.courseName == "Synthetic course" && homework.title == "Synthetic task" && homework.identity.courseID == "100001", "verified course name and identity supplied")
        for explicit in ["2026-11-05T15:59:00Z", "2026-11-05T23:59:00+08:00", "2026-11-05T10:29:00-0530"] {
            check(try read([["id": "a", "title": "T", "end_time": explicit]])[0].deadline?.date == homework.deadline?.date, "explicit zones honored")
        }
        let absent: [[String: Any]] = [["id": "a", "title": "A", "start_time": "2026-11-05 23:59:00", "answer_deadline": "2026-11-05 23:59:00", "data": ["end_time": "2026-11-05 23:59:00"], "resubmit_record": ["closed_time": "2026-11-05 23:59:00"]], ["id": "b", "title": "B", "end_time": NSNull()], ["id": "c", "title": "C", "end_time": " \n "]]
        let undated = try read(absent)
        check(undated.count == 3 && undated.allSatisfy { $0.deadline == nil }, "no deadline candidates retained without guessed fallback")
        check(try NativeTaskSelection.select(undated + [homework, exam]).skippedWithoutDeadline == 3, "shared selection counts undated candidates")
        check(try read([h, h]).count == 1, "identical snapshots coalesce")
        check(try read([h, h.merging(["submitted": false, "score": 87.5, "status_code": "unsubmitted", "is_closed": false]) { _, new in new }]).count == 1, "score and completion indicators do not change task snapshot")
        rejects("publication snapshots conflict before exclusion") { _ = try read([["id": "a", "title": "A", "published": false], ["id": "a", "title": "A", "published": true]]) }
        let opaque = try read([["id": "a/b?课程", "title": "Opaque"]])[0]
        check(opaque.identity.taskID == "a/b?课程", "opaque string task identity preserved")
        check(try read([["id": "a", "title": "A", "published": false]]).isEmpty, "explicit unpublished excluded")
        check(try read([["id": "a", "title": "A", "published": true]]).count == 1, "explicit publication accepted")
        check(try read([]).isEmpty && read([], exam: true).isEmpty, "explicit empty collections accepted")
        check(try read([["id": "past", "title": "Past", "end_time": "1970-01-01T00:00:00Z"]])[0].deadline?.date.timeIntervalSince1970 == 0, "no first-import past filtering")
        for examReader in [false, true] {
            let collection = examReader ? "exams" : "homework_activities"
            let complete = try json([collection: [h], "page": 1, "page_size": 100, "pages": 1, "total": 1])
            check(try (examReader ? XzzdTaskPayload.exams(complete, course: course, scope: scope) : XzzdTaskPayload.homeworks(complete, course: course, scope: scope)).count == 1, "complete single-page task metadata accepted")
            // Each otherwise-valid proper subset leaves the whole collection unproven.
            for records: [Any] in [[h], []] {
                for metadata: [String: Any] in [
                    ["page": 1], ["page_size": 100], ["pages": 1], ["total": records.count],
                    ["page": 1, "page_size": 100], ["page": 1, "pages": 1], ["page": 1, "total": records.count],
                    ["page_size": 100, "pages": 1], ["page_size": 100, "total": records.count], ["pages": 1, "total": records.count],
                    ["page": 1, "page_size": 100, "pages": 1], ["page": 1, "page_size": 100, "total": records.count],
                    ["page": 1, "pages": 1, "total": records.count], ["page_size": 100, "pages": 1, "total": records.count]
                ] {
                    rejects("\(collection) rejects incomplete pagination with \(records.count) records and keys \(metadata.keys.sorted())") {
                        let data = try json(metadata.merging([collection: records]) { _, new in new })
                        _ = examReader ? try XzzdTaskPayload.exams(data, course: course, scope: scope) : try XzzdTaskPayload.homeworks(data, course: course, scope: scope)
                    }
                }
            }
            for pages in [0, 1] {
                let empty = try json([collection: [], "page": 1, "page_size": 100, "pages": pages, "total": 0])
                check(try (examReader ? XzzdTaskPayload.exams(empty, course: course, scope: scope) : XzzdTaskPayload.homeworks(empty, course: course, scope: scope)).isEmpty, "complete empty task pagination accepted")
            }
            for metadata: [String: Any] in [["page": 2], ["pages": 2], ["total": 2], ["page_size": 0], ["page": true], ["total": NSNull()]] {
                rejects("partial or malformed task pagination rejected") {
                    let data = try json(metadata.merging([collection: [h]]) { _, new in new })
                    _ = examReader ? try XzzdTaskPayload.exams(data, course: course, scope: scope) : try XzzdTaskPayload.homeworks(data, course: course, scope: scope)
                }
            }
            for raw in ["1.00000000000000001", "1e0", "1.0", "true", "9223372036854775808"] {
                rejects("task numeric ID cannot round") {
                    let data = Data(("{\"" + collection + "\":[{\"id\":" + raw + ",\"title\":\"T\"}]}").utf8)
                    _ = examReader ? try XzzdTaskPayload.exams(data, course: course, scope: scope) : try XzzdTaskPayload.homeworks(data, course: course, scope: scope)
                }
            }
            for invalid: Any in [[], [:], ["data": [examReader ? "exams" : "homework_activities": []]], [examReader ? "exams" : "homework_activities": NSNull()], [examReader ? "exams" : "homework_activities": [:]]] {
                rejects("unsupported collection schema rejected") {
                    let data = try json(invalid)
                    _ = examReader ? try XzzdTaskPayload.exams(data, course: course, scope: scope) : try XzzdTaskPayload.homeworks(data, course: course, scope: scope)
                }
            }
            for record: [String: Any] in [["title": "T", "activity_id": 1], ["id": true, "title": "T"], ["id": 1.2, "title": "T"], ["id": "a"], ["id": "a", "title": " "], ["id": "a", "title": "T", "published": "true"], ["id": "a", "title": "T", "published": NSNull()], ["id": "a", "title": "T", "end_time": 123]] {
                rejects("invalid task fields rejected") { _ = try read([record], exam: examReader) }
            }
            for deadline in ["bad", "2026-11-05", "1969-12-31T23:59:59Z", "2026-02-30 23:59:00"] {
                rejects("invalid nonempty deadline fails whole course") { _ = try read([h, ["id": "bad", "title": "Bad", "end_time": deadline]], exam: examReader) }
            }
            for changed in [["id": 200001, "title": "Changed"], ["id": 200001, "title": "Synthetic task"]] {
                rejects("conflict before filtering even when one deadline missing") { _ = try read([h, changed], exam: examReader) }
            }
            rejects("MO scope rejected") {
                let data = try json([examReader ? "exams" : "homework_activities": []])
                _ = examReader ? try XzzdTaskPayload.exams(data, course: course, scope: mo) : try XzzdTaskPayload.homeworks(data, course: course, scope: mo)
            }
        }
    }
    static func requests() throws {
        // Catches wrong method/body envelope, endpoint mutations, path injection and supplied arbitrary URLs.
        check(try XzzdReadRequest.courses(page: 2).method == "POST", "course search descriptor provided")
        let request = try XzzdReadRequest.courses(page: 2)
        check(request.method == "POST" && request.url.absoluteString == "https://courses.zju.edu.cn/api/my-courses", "source-confirmed course search method and host")
        let body = try JSONSerialization.jsonObject(with: request.body!) as! NSDictionary
        check(body == ["page": 2, "page_size": 100, "fields": "id,name", "conditions": ["status": ["ongoing", "notStarted", "ended"], "keyword": ""]] as NSDictionary, "course pagination and conditions use JSON object body")
        let homework = try XzzdReadRequest.homeworks(courseID: "100001")
        let parts = URLComponents(url: homework.url, resolvingAgainstBaseURL: false)!
        check(homework.method == "GET" && homework.body == nil && parts.path == "/api/course/100001/homework-scores", "homework uses read-only scores helper")
        check(parts.queryItems == [URLQueryItem(name: "fields", value: "id,title,data,start_time,end_time,published,is_in_progress")], "deadline/publication fields requested")
        let exam = try XzzdReadRequest.exams(courseID: "100001")
        check(exam.method == "GET" && exam.body == nil && exam.url.absoluteString == "https://courses.zju.edu.cn/api/courses/100001/exams", "exam uses independent unpaged collection")
        let escaped = try XzzdReadRequest.exams(courseID: "a/b?x=1#% 课程")
        check(escaped.url.absoluteString == "https://courses.zju.edu.cn/api/courses/a%2Fb%3Fx%3D1%23%25%20%E8%AF%BE%E7%A8%8B/exams", "opaque ID stays one encoded segment")
        for invalid in ["", ".", "..", "bad\nID", String(repeating: "x", count: 1025)] {
            rejects("unsafe request ID rejected") { _ = try XzzdReadRequest.exams(courseID: invalid) }
            rejects("unsafe homework ID rejected") { _ = try XzzdReadRequest.homeworks(courseID: invalid) }
        }
        rejects("invalid page rejected") { _ = try XzzdReadRequest.courses(page: 0) }
    }
}
