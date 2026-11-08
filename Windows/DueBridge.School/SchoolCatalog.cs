using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using DueBridge.Core;

namespace DueBridge.School;

internal sealed class SchoolCatalog(
    SchoolPolicy school, string account, Func<SchoolRequest, CancellationToken, Task<string>> read, CancellationToken token)
{
    private const int PageSize = 100;
    private const int MaxCourses = 500;
    private const int MaxRequests = 1100;
    private const int MaxBytes = 32 * 1024 * 1024;
    private const int MaxTasks = 5000;
    private readonly Dictionary<string, Candidate> tasks = new(StringComparer.Ordinal);
    private int requests;
    private int bytes;

    private sealed record Course(string Id, string Name);
    private sealed record Candidate(string Course, string Title, DateTimeOffset? DueAt, bool Published);

    public static Task<SourcePreview> CollectAsync(SchoolPolicy school, string account,
        Func<SchoolRequest, CancellationToken, Task<string>> read, CancellationToken token) =>
        new SchoolCatalog(school, account, read, token).CollectAsync();

    private async Task<SourcePreview> CollectAsync()
    {
        try
        {
            if (school.Platform == SchoolPlatform.Mo) await CollectMoAsync();
            else await CollectLearningAsync();
            return new SourcePreview(account, tasks
                .Where(item => item.Value.Published && item.Value.DueAt.HasValue)
                .Select(item => new CalendarEntry(item.Key, item.Value.Title,
                    $"来源：{school.Label}\n平台入口：{school.Origin}/", null, item.Value.DueAt)
                    { CourseLabel = item.Value.Course })
                .OrderBy(item => item.DueAt).ThenBy(item => item.Key, StringComparer.Ordinal).ToArray());
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException or FormatException
            or ArgumentException or OverflowException)
        {
            throw Invalid();
        }
    }

    private async Task<JsonDocument> ReadAsync(string path, string? body = null)
    {
        token.ThrowIfCancellationRequested();
        if (++requests > MaxRequests) throw Invalid();
        var text = await read(new SchoolRequest(path, body), token);
        bytes += Encoding.UTF8.GetByteCount(text);
        if (bytes > MaxBytes) throw Invalid();
        var document = JsonDocument.Parse(text);
        try { CheckJson(document.RootElement); }
        catch { document.Dispose(); throw; }
        return document;
    }

    private static void CheckJson(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var member in element.EnumerateObject())
            {
                if (!names.Add(member.Name)) throw Invalid();
                CheckJson(member.Value);
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in element.EnumerateArray()) CheckJson(item);
        }
    }

    private async Task CollectMoAsync()
    {
        var courses = new Dictionary<string, Course>(StringComparer.Ordinal);
        foreach (var status in new[] { "pending", "learning", "finished" })
        {
            var seen = new HashSet<string>(StringComparer.Ordinal);
            int? baseline = null;
            for (int page = 1; page <= MaxCourses / PageSize + 1; page++)
            {
                using var document = await ReadAsync(
                    $"/pyapi/course?group=my&type=all&learning_status={status}&page_no={page}&page_size={PageSize}");
                var root = Unwrap(document.RootElement);
                int total = int.Parse(ExactInteger(root.GetProperty("count")), CultureInfo.InvariantCulture);
                if (total < 0 || total > MaxCourses || baseline.HasValue && baseline != total) throw Invalid();
                baseline = total;
                var objects = root.GetProperty("objects");
                var records = objects.ValueKind switch
                {
                    JsonValueKind.Array => objects.EnumerateArray().ToArray(),
                    JsonValueKind.Object => objects.EnumerateObject().Select(item => item.Value).ToArray(),
                    _ => throw Invalid()
                };
                var batch = new Dictionary<string, Course>(StringComparer.Ordinal);
                foreach (var item in records)
                    AddCourse(batch, new Course(MoId(item), Name(item, "name_cn", "name")));
                if (batch.Count != Math.Min(PageSize, total - seen.Count)) throw Invalid();
                foreach (var course in batch.Values)
                {
                    if (!seen.Add(course.Id)) throw Invalid();
                    AddCourse(courses, course);
                }
                if (courses.Count > MaxCourses) throw Invalid();
                if (seen.Count == total) break;
            }
            if (seen.Count != baseline) throw Invalid();
        }

        foreach (var course in courses.Values)
        {
            using var document = await ReadAsync("/pyapi/course/section/" + Segment(course.Id) + "?is_backstage=false");
            var root = Unwrap(document.RootElement);
            var info = root.GetProperty("info");
            if (MoId(info) != course.Id) throw Invalid();
            var courseName = OptionalName(info, "name_cn", "name") ?? course.Name;
            foreach (var item in root.GetProperty("homework_sections").EnumerateArray())
            {
                var units = item.GetProperty("units").EnumerateArray().ToArray();
                if (units.Length == 0 || units.Any(unit => unit.ValueKind != JsonValueKind.Object)) throw Invalid();
                var unit = units[0];
                if (unit.TryGetProperty("hide_in_list", out var hidden) && hidden.GetBoolean()) continue;
                Add(course.Id, courseName, "homework", MoId(unit), Name(unit, "zh_name", "name"), Deadline(unit, TimeZoneInfo.Utc), true);
            }
            foreach (var paper in root.GetProperty("paper_sections").EnumerateArray())
                Add(course.Id, courseName, "practice", MoId(paper), Name(paper, "name_cn"),
                    Deadline(paper.GetProperty("question_paper"), TimeZoneInfo.Utc), true);
        }
    }

    private async Task CollectLearningAsync()
    {
        var courses = new Dictionary<string, Course>(StringComparer.Ordinal);
        int? total = null;
        for (int page = 1; page <= MaxCourses / PageSize + 1; page++)
        {
            string body = JsonSerializer.Serialize(new { page, page_size = PageSize, fields = "id,name",
                conditions = new { status = new[] { "ongoing", "notStarted", "ended" }, keyword = "" } });
            using var document = await ReadAsync("/api/my-courses", body);
            var root = document.RootElement;
            int count = root.GetProperty("total").GetInt32();
            int pages = root.GetProperty("pages").GetInt32();
            if (count < 0 || count > MaxCourses || total.HasValue && count != total ||
                root.GetProperty("page").GetInt32() != page || root.GetProperty("page_size").GetInt32() != PageSize ||
                (count == 0 ? pages is < 0 or > 1 : pages != (count + PageSize - 1) / PageSize)) throw Invalid();
            total = count;
            var pageRecords = root.GetProperty("courses").EnumerateArray().ToArray();
            var batch = new Dictionary<string, Course>(StringComparer.Ordinal);
            foreach (var item in pageRecords) AddCourse(batch, new Course(Id(item.GetProperty("id")), Name(item, "name")));
            if (pageRecords.Length > PageSize || batch.Count != Math.Min(PageSize, count - courses.Count)) throw Invalid();
            foreach (var course in batch.Values) if (!courses.TryAdd(course.Id, course)) throw Invalid();
            if (page >= pages) break;
        }
        if (courses.Count != total) throw Invalid();

        var zone = TimeZoneInfo.FindSystemTimeZoneById("Asia/Shanghai");
        foreach (var course in courses.Values)
        {
            var segment = Segment(course.Id);
            using var homework = await ReadAsync("/api/course/" + segment +
                "/homework-scores?fields=id,title,data,start_time,end_time,published,is_in_progress");
            AddLearning(homework.RootElement, "homework_activities", "homework", course, zone);
            using var exams = await ReadAsync("/api/courses/" + segment + "/exams");
            AddLearning(exams.RootElement, "exams", "exam", course, zone);
        }
    }

    private void AddLearning(JsonElement root, string field, string kind, Course course, TimeZoneInfo zone)
    {
        var records = root.GetProperty(field).EnumerateArray().ToArray();
        if (root.TryGetProperty("page", out _) || root.TryGetProperty("page_size", out _) ||
            root.TryGetProperty("pages", out _) || root.TryGetProperty("total", out _))
        {
            int size = root.GetProperty("page_size").GetInt32();
            int pages = root.GetProperty("pages").GetInt32();
            if (root.GetProperty("page").GetInt32() != 1 || size <= 0 || size < records.Length ||
                (pages != 1 && !(pages == 0 && records.Length == 0)) || root.GetProperty("total").GetInt32() != records.Length)
                throw Invalid();
        }
        foreach (var item in records)
        {
            bool published = !item.TryGetProperty("published", out var value) || value.GetBoolean();
            Add(course.Id, course.Name, kind, Id(item.GetProperty("id")), Name(item, "title"), Deadline(item, zone), published);
        }
    }

    private void Add(string course, string courseName, string kind, string id, string title, DateTimeOffset? deadline, bool published)
    {
        var key = SchoolPolicy.HashFields("DueBridge/Windows/course-task/v1", school.Id, school.Host, account, course, kind, id);
        var value = new Candidate(courseName, title, deadline, published);
        if (tasks.TryGetValue(key, out var previous))
        {
            if (previous != value) throw Invalid();
        }
        else if (tasks.Count == MaxTasks) throw Invalid();
        else tasks.Add(key, value);
    }

    private static void AddCourse(Dictionary<string, Course> courses, Course course)
    {
        if (courses.TryGetValue(course.Id, out var old) && old != course) throw Invalid();
        courses[course.Id] = course;
    }

    private static JsonElement Unwrap(JsonElement value) =>
        value.TryGetProperty("response", out var response) ? response : value;

    private static string MoId(JsonElement value)
    {
        string? id = value.TryGetProperty("id", out var first) ? Id(first) : null;
        string? underscored = value.TryGetProperty("_id", out var second) ? Id(second) : null;
        if (id is not null && underscored is not null && id != underscored) throw Invalid();
        return underscored ?? id ?? throw Invalid();
    }

    private static string Id(JsonElement value)
    {
        string? id = value.ValueKind == JsonValueKind.String ? value.GetString() : ExactInteger(value);
        return SchoolPolicy.ValidId(id) ? id! : throw Invalid();
    }

    // Preserve decimal IDs before any floating point conversion.
    private static string ExactInteger(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Number) throw Invalid();
        string raw = value.GetRawText();
        if (raw.Length > 2048) throw Invalid();
        var pieces = raw.ToLowerInvariant().Split('e');
        int exponent = pieces.Length == 2 ? int.Parse(pieces[1], CultureInfo.InvariantCulture) : 0;
        if (exponent is < -2048 or > 2048) throw Invalid();
        string mantissa = pieces[0].TrimStart('-');
        int dot = mantissa.IndexOf('.');
        int scale = (dot < 0 ? 0 : mantissa.Length - dot - 1) - exponent;
        string digits = mantissa.Replace(".", "", StringComparison.Ordinal).TrimStart('0');
        if (digits.Length == 0) return "0";
        if (scale > 0)
        {
            if (scale >= digits.Length || digits[^scale..].Any(c => c != '0')) throw Invalid();
            digits = digits[..^scale];
        }
        if (scale < 0)
        {
            if (digits.Length - scale > 1024) throw Invalid();
            digits += new string('0', -scale);
        }
        return raw[0] == '-' ? "-" + digits : digits;
    }

    private static string Segment(string id) => id is "." or ".." ? throw Invalid() : Uri.EscapeDataString(id);
    private static string Name(JsonElement item, params string[] fields) => OptionalName(item, fields) ?? throw Invalid();
    private static string? OptionalName(JsonElement item, params string[] fields)
    {
        foreach (var field in fields)
        {
            if (!item.TryGetProperty(field, out var value) || value.ValueKind == JsonValueKind.Null) continue;
            string text = value.GetString()?.Trim() ?? "";
            if (text.Length > 2048 || text.Any(char.IsControl)) throw Invalid();
            if (text.Length > 0) return text;
        }
        return null;
    }

    private static readonly Regex Timestamp = new(
        @"\A([0-9]{4}-[0-9]{2}-[0-9]{2})[ T]([0-9]{2}:[0-9]{2}:[0-9]{2})(?:\.([0-9]+))?(?:[Zz]|([+-])([0-9]{2}):?([0-9]{2}))?\z",
        RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));

    private static DateTimeOffset? Deadline(JsonElement item, TimeZoneInfo naiveZone)
    {
        if (!item.TryGetProperty("end_time", out var raw) || raw.ValueKind == JsonValueKind.Null) return null;
        var text = raw.GetString()?.Trim();
        if (string.IsNullOrEmpty(text)) return null;
        if (text.Length > 128) throw Invalid();
        var match = Timestamp.Match(text);
        if (!match.Success) throw Invalid();
        var date = DateTime.ParseExact(match.Groups[1].Value + "T" + match.Groups[2].Value, "yyyy-MM-dd'T'HH:mm:ss",
            CultureInfo.InvariantCulture, DateTimeStyles.None);
        if (match.Groups[3].Success)
            date = date.AddTicks(int.Parse(match.Groups[3].Value.PadRight(7, '0')[..7], CultureInfo.InvariantCulture));
        TimeSpan offset;
        if (match.Groups[4].Success)
        {
            int hours = int.Parse(match.Groups[5].Value, CultureInfo.InvariantCulture);
            int minutes = int.Parse(match.Groups[6].Value, CultureInfo.InvariantCulture);
            if (hours > 23 || minutes > 59) throw Invalid();
            offset = TimeSpan.FromMinutes((60 * hours + minutes) * (match.Groups[4].Value == "-" ? -1 : 1));
        }
        else if (text.EndsWith('Z') || text.EndsWith('z')) offset = TimeSpan.Zero;
        else
        {
            if (naiveZone.IsInvalidTime(date)) throw Invalid();
            offset = naiveZone.GetUtcOffset(date);
        }
        var utc = new DateTimeOffset(date - offset, TimeSpan.Zero);
        return utc >= DateTimeOffset.UnixEpoch ? utc : throw Invalid();
    }

    private static SchoolConnectionException Invalid() => new("学校平台返回的数据不完整或格式已变化，本次未同步。");
}
