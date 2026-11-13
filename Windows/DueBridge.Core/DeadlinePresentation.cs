using System.Globalization;

namespace DueBridge.Core;

public static class DeadlinePresentation
{
    public const string UnknownCourse = "课程待确认";

    internal static TimeZoneInfo Shanghai { get; } = TimeZoneInfo.TryFindSystemTimeZoneById("Asia/Shanghai", out var zone)
        ? zone : TimeZoneInfo.FindSystemTimeZoneById("China Standard Time");

    public static DateOnly ShanghaiDate(DateTimeOffset value)
        => DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(value, Shanghai).DateTime);

    public static bool NeedsCatchUp(DateTimeOffset? lastSuccess, DateTimeOffset now)
        => lastSuccess is null || ShanghaiDate(lastSuccess.Value) < ShanghaiDate(now);

    public static bool IsBeforeToday(CalendarEntry entry, DateTimeOffset now)
    {
        var date = entry.AllDay ?? (entry.DueAt is { } instant ? ShanghaiDate(instant) : (DateOnly?)null);
        return date.HasValue && date.Value < ShanghaiDate(now);
    }

    public static DateTimeOffset SortDeadline(CalendarEntry entry)
    {
        if (entry.AllDay is not { } day)
            return entry.DueAt ?? DateTimeOffset.MaxValue;
        var midnight = day.ToDateTime(TimeOnly.MinValue);
        return TimeZoneInfo.ConvertTimeToUtc(midnight, Shanghai);
    }

    public static string? NormalizeCourse(string? raw)
    {
        var trimmed = raw?.Trim();
        return string.IsNullOrEmpty(trimmed) || trimmed.Any(character =>
            char.IsControl(character) || character is '\u2028' or '\u2029') ? null : trimmed;
    }

    public static CalendarEntry ForCalendar(CalendarEntry entry, string? course)
    {
        var name = CalendarText(course, UnknownCourse);
        var title = CalendarText(entry.Title, "未命名截止事项");
        return entry with { Title = $"【{name}】{title} · 截止", CourseLabel = name };
    }

    public static CalendarEntry ForDesktop(CalendarEntry entry, string? course) => entry with
    {
        Title = CalendarText(entry.Title, "未命名截止事项"),
        CourseLabel = CalendarText(course, UnknownCourse),
        Notes = ""
    };

    public static CalendarEntry ForTodo(CalendarEntry entry, string? course) => entry with
    {
        Title = $"【{CalendarText(course, UnknownCourse)}】{CalendarText(entry.Title, "未命名截止事项")}",
        CourseLabel = CalendarText(course, UnknownCourse)
    };

    private static string CalendarText(string? text, string fallback)
    {
        var value = NormalizeCourse(text);
        return value is null || value.Contains("calendarFeed", StringComparison.OrdinalIgnoreCase) ? fallback : value;
    }

    public static string FormatDeadline(CalendarEntry entry)
    {
        if (entry.AllDay is { } date)
            return date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) + " 全天";
        return entry.DueAt is { } due
            ? TimeZoneInfo.ConvertTime(due, Shanghai).ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture)
            : "—";
    }

    public static string Countdown(CalendarEntry entry, DateTimeOffset now)
    {
        if (entry.Cancelled)
            return "已取消";
        if (entry.AllDay is { } date)
        {
            int days = date.DayNumber - ShanghaiDate(now).DayNumber;
            var label = days switch
            {
                < 0 => $"已逾期 {-days} 天",
                0 => "今天到期",
                1 => "明天到期",
                _ => $"还有 {days} 天"
            };
            return label + "（全天）";
        }
        if (entry.DueAt is not { } due)
            return "—";
        var remaining = due - now;
        if (remaining == TimeSpan.Zero)
            return "已到期";
        var prefix = remaining > TimeSpan.Zero ? "还剩 " : "已逾期 ";
        var distance = remaining.Duration();
        if (distance.TotalMinutes < 1)
            return prefix + "不足 1 分钟";
        if (distance.Days > 0)
            return prefix + $"{distance.Days} 天" + (distance.Hours > 0 ? $" {distance.Hours} 小时" : "");
        if (distance.Hours > 0)
            return prefix + $"{distance.Hours} 小时" + (distance.Minutes > 0 ? $" {distance.Minutes} 分钟" : "");
        return prefix + $"{distance.Minutes} 分钟";
    }
}
