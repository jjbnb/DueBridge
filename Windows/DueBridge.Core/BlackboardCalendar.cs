using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace DueBridge.Core;

public sealed class BlackboardException(string message, bool retryable = false) : Exception(message)
{
    public bool Retryable { get; } = retryable;
}

public static partial class BlackboardCalendar
{
    private sealed record Property(string Name, Dictionary<string, string> Parameters, string Value);
    private sealed record Revision(string Uid, string Title, string Notes, DateOnly? Date, DateTimeOffset? Instant,
        int Sequence, DateTimeOffset? Modified, bool Cancelled);

    [GeneratedRegex(@"\A[0-9]{8}T[0-9]{6}Z-_(blackboard\.platform\.gradebook2\.GradableItem)-(_[0-9]+_[0-9]+)@[A-Za-z0-9.-]+\z", RegexOptions.CultureInvariant)]
    private static partial Regex StableUid();

    public static IReadOnlyList<CalendarEntry> Parse(string source) => ParseWithWarnings(source).Entries;

    internal static (IReadOnlyList<CalendarEntry> Entries, IReadOnlyList<string> Warnings) ParseWithWarnings(string source)
    {
        var normalized = source.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n')
            .Trim(' ', '\t', '\n', '\uFEFF');
        if (!normalized.StartsWith("BEGIN:VCALENDAR\n", StringComparison.Ordinal) ||
            !normalized.EndsWith("\nEND:VCALENDAR", StringComparison.Ordinal) ||
            normalized.Contains("<html", StringComparison.OrdinalIgnoreCase))
            throw new BlackboardException("返回内容不是有效日历，请检查 BB 订阅链接。");

        var stack = new List<string>();
        var properties = new List<Property>();
        var selected = new Dictionary<string, Revision>(StringComparer.Ordinal);
        var recurrence = new HashSet<string>(StringComparer.Ordinal);
        var warnings = new HashSet<string>(StringComparer.Ordinal);
        bool sawVersion = false;
        bool sawCalendar = false;
        bool calendarCancelled = false;

        foreach (var line in Unfold(normalized))
        {
            var property = ReadProperty(line);
            switch (property.Name)
            {
                case "BEGIN":
                    string component = property.Value.ToUpperInvariant();
                    if ((stack.Count == 0 && component != "VCALENDAR") ||
                        (component == "VCALENDAR" && (sawCalendar || stack.Count != 0)) ||
                        (component == "VEVENT" && stack.Count != 1))
                        throw new BlackboardException("日历组件结构无效。");
                    if (component == "VCALENDAR")
                        sawCalendar = true;
                    if (component == "VEVENT")
                        properties.Clear();
                    stack.Add(component);
                    break;
                case "END":
                    if (stack.Count == 0 || !stack[^1].Equals(property.Value, StringComparison.OrdinalIgnoreCase))
                        throw new BlackboardException("日历组件未正确结束。");
                    if (stack[^1] == "VEVENT")
                    {
                        if (properties.Any(field => field.Name is "RRULE" or "RDATE" or "EXDATE" or "RECURRENCE-ID"))
                        {
                            recurrence.Add(RequiredUid(properties));
                            warnings.Add("已跳过含重复规则或例外的事件。");
                        }
                        else
                        {
                            var candidate = ReadRevision(properties);
                            if (!selected.TryGetValue(candidate.Uid, out var old) ||
                                candidate.Sequence > old.Sequence ||
                                (candidate.Sequence == old.Sequence && (candidate.Modified ?? DateTimeOffset.MinValue) >= (old.Modified ?? DateTimeOffset.MinValue)))
                                selected[candidate.Uid] = candidate;
                        }
                    }
                    stack.RemoveAt(stack.Count - 1);
                    break;
                default:
                    if (stack.Count == 0)
                        throw new BlackboardException("日历包含组件外的数据。");
                    if (stack.Count == 1 && property.Name == "VERSION")
                    {
                        if (property.Value != "2.0")
                            throw new BlackboardException("仅支持 iCalendar 2.0。");
                        sawVersion = true;
                    }
                    if (stack.Count == 1 && property.Name == "METHOD" && property.Value.Equals("CANCEL", StringComparison.OrdinalIgnoreCase))
                        calendarCancelled = true;
                    if (stack.Count == 2 && stack[^1] == "VEVENT")
                        properties.Add(property);
                    if (property.Name == "TRIGGER" && stack.Contains("VALARM"))
                        warnings.Add("已忽略日历内的提前提醒。");
                    break;
            }
        }
        if (stack.Count != 0 || !sawVersion)
            throw new BlackboardException("日历不完整或缺少版本。");

        var keys = new HashSet<string>(StringComparer.Ordinal);
        var entries = new List<CalendarEntry>();
        foreach (var revision in selected.Values.Where(revision => !recurrence.Contains(revision.Uid)))
        {
            bool cancelled = calendarCancelled || revision.Cancelled;
            if (revision.Date is null && revision.Instant is null && !cancelled)
                throw new BlackboardException("日历事件缺少 DTSTART 截止时间。");
            var match = StableUid().Match(revision.Uid);
            if (!match.Success)
                throw new BlackboardException("日历事件缺少已验证的 BB 稳定记录 ID。");
            string key = Hash($"learn.intl.zju.edu.cn|{match.Groups[1].Value}|{match.Groups[2].Value}");
            if (!keys.Add(key))
                throw new BlackboardException("多个日历事件指向同一个 BB 记录 ID，请核对日历。");
            const string safeNotes = "来源：Blackboard（BB）\n平台入口：https://learn.intl.zju.edu.cn/";
            entries.Add(new CalendarEntry(key, revision.Title, safeNotes, revision.Date, revision.Instant, cancelled));
        }
        return (entries.OrderBy(DeadlinePresentation.SortDeadline).ThenBy(entry => entry.Key, StringComparer.Ordinal).ToArray(),
            warnings.Order(StringComparer.Ordinal).ToArray());
    }

    internal static string Hash(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    private static IEnumerable<string> Unfold(string source)
    {
        var buffer = new StringBuilder();
        foreach (var line in source.Split('\n'))
        {
            if (line.StartsWith(' ') || line.StartsWith('\t'))
            {
                if (buffer.Length == 0)
                    throw new BlackboardException("日历折行格式无效。");
                buffer.Append(line.AsSpan(1));
                continue;
            }
            if (buffer.Length != 0)
                yield return buffer.ToString();
            buffer.Clear();
            buffer.Append(line);
        }
        if (buffer.Length != 0)
            yield return buffer.ToString();
    }

    private static Property ReadProperty(string line)
    {
        int split = Separator(line, ':');
        if (split <= 0)
            throw new BlackboardException("日历属性格式无效。");
        string header = line[..split];
        int position = Separator(header, ';');
        string name = position < 0 ? header : header[..position];
        if (name.Length == 0)
            throw new BlackboardException("日历属性名称无效。");
        var parameters = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        while (position >= 0)
        {
            header = header[(position + 1)..];
            position = Separator(header, ';');
            string token = position < 0 ? header : header[..position];
            int equal = token.IndexOf('=');
            if (equal <= 0 || !parameters.TryAdd(token[..equal], token[(equal + 1)..].Trim('"')))
                throw new BlackboardException("日历参数格式无效。");
        }
        return new Property(name.ToUpperInvariant(), parameters, line[(split + 1)..]);
    }

    private static int Separator(string text, char delimiter)
    {
        bool quoted = false;
        for (int i = 0; i < text.Length; i++)
        {
            if (text[i] == '"')
                quoted = !quoted;
            if (!quoted && text[i] == delimiter)
                return i;
        }
        return -1;
    }

    private static string RequiredUid(List<Property> properties)
    {
        string? uid = properties.FirstOrDefault(field => field.Name == "UID")?.Value;
        return string.IsNullOrWhiteSpace(uid) ? throw new BlackboardException("日历事件缺少 UID。") : uid;
    }

    private static Revision ReadRevision(List<Property> properties)
    {
        Property? Field(string name) => properties.FirstOrDefault(field => field.Name == name);
        string[] unique = ["UID", "DTSTART", "SUMMARY", "STATUS", "SEQUENCE", "LAST-MODIFIED"];
        if (unique.Any(name => properties.Count(field => field.Name == name) > 1))
            throw new BlackboardException("日历事件包含重复的关键属性。");
        int sequence = 0;
        if (Field("SEQUENCE") is { } version &&
            (!int.TryParse(version.Value, NumberStyles.None, CultureInfo.InvariantCulture, out sequence) || sequence < 0))
            throw new BlackboardException("日历事件版本号无效。");

        var (date, instant) = Field("DTSTART") is { } deadline ? ReadDate(deadline) : default;
        DateTimeOffset? modified = null;
        if (Field("LAST-MODIFIED") is { } modifiedProperty)
        {
            var modifiedDate = ReadDate(modifiedProperty);
            modified = modifiedDate.Instant ?? (modifiedDate.Date is { } day
                ? DeadlinePresentation.SortDeadline(new CalendarEntry("", "", "", day, null)) : null);
        }
        string title = Unescape(Field("SUMMARY")?.Value ?? "");
        return new Revision(RequiredUid(properties), title.Length == 0 ? "未命名截止事项" : title,
            Unescape(Field("DESCRIPTION")?.Value ?? ""), date, instant, sequence, modified,
            string.Equals(Field("STATUS")?.Value, "CANCELLED", StringComparison.OrdinalIgnoreCase));
    }

    private static (DateOnly? Date, DateTimeOffset? Instant) ReadDate(Property property)
    {
        string? type = property.Parameters.GetValueOrDefault("VALUE")?.ToUpperInvariant();
        string? zoneName = property.Parameters.GetValueOrDefault("TZID");
        var raw = property.Value;
        if (type == "DATE")
        {
            if (zoneName is null && DateOnly.TryParseExact(raw, "yyyyMMdd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var day))
                return (day, null);
            throw new BlackboardException("全天日期格式无效。");
        }
        if (type is not (null or "DATE-TIME"))
            throw new BlackboardException("不支持此日历日期类型。");

        bool utc = raw.EndsWith('Z');
        if ((utc && zoneName is not null) || !DateTime.TryParseExact(utc ? raw[..^1] : raw, "yyyyMMdd'T'HHmmss",
            CultureInfo.InvariantCulture, DateTimeStyles.None, out var local))
            throw new BlackboardException("日历日期格式无效。");
        var zone = utc ? TimeZoneInfo.Utc : DeadlinePresentation.Shanghai;
        if (zoneName is not null && !TimeZoneInfo.TryFindSystemTimeZoneById(zoneName, out zone))
            throw new BlackboardException("日历含无法识别的时区。");
        if (zone.IsInvalidTime(local))
            throw new BlackboardException("日历日期不存在或处于时区跳时区间。");
        var offset = zone.IsAmbiguousTime(local) ? zone.GetAmbiguousTimeOffsets(local).Max() : zone.GetUtcOffset(local);
        try { return (null, new DateTimeOffset(local, offset).ToUniversalTime()); }
        catch (ArgumentException) { throw new BlackboardException("日历日期超出支持范围。"); }
    }

    private static string Unescape(string value)
    {
        var text = new StringBuilder();
        for (int i = 0; i < value.Length; i++)
        {
            char character = value[i];
            if (character == '\\' && i + 1 < value.Length)
            {
                char next = value[i + 1];
                if (next is 'n' or 'N')
                {
                    text.Append('\n');
                    i++;
                    continue;
                }
                if (next is '\\' or ',' or ';')
                    character = value[++i];
            }
            text.Append(character);
        }
        return text.ToString();
    }
}
