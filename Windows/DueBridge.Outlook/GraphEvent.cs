using System.Globalization;
using System.Text.Json;
using DueBridge.Core;

namespace DueBridge.Outlook;

internal sealed class GraphEvent
{
    private const string ChinaTimeZone = "China Standard Time";
    private static readonly TimeZoneInfo Shanghai = TimeZoneInfo.FindSystemTimeZoneById(ChinaTimeZone);

    private readonly string subject;
    private readonly DateTime? start;
    private readonly DateTime? end;
    private readonly string timeZone;
    private readonly bool allDay;

    internal GraphEvent(CalendarEntry entry)
    {
        subject = entry.Cancelled ? $"[已取消] {entry.Title}" : entry.Title;
        allDay = entry.AllDay is not null;
        timeZone = allDay ? ChinaTimeZone : "UTC";
        if (entry.AllDay is { } day)
        {
            if (day == DateOnly.MaxValue || entry.DueAt is not null)
                throw GraphTransport.Unexpected();
            start = day.ToDateTime(TimeOnly.MinValue);
            end = start.Value.AddDays(1);
        }
        else if (entry.DueAt is { } instant)
        {
            start = instant.UtcDateTime;
            if (start > DateTime.MaxValue.AddMinutes(-1))
                throw GraphTransport.Unexpected();
            end = start.Value.AddMinutes(1);
        }
    }

    internal bool HasDeadline => start.HasValue;

    internal Dictionary<string, object> ManagedFields()
    {
        var fields = new Dictionary<string, object>
        {
            ["subject"] = subject,
            ["showAs"] = "free",
            ["isReminderOn"] = false
        };
        if (start is { } from && end is { } to)
        {
            fields["isAllDay"] = allDay;
            fields["start"] = FormatDate(from);
            fields["end"] = FormatDate(to);
        }
        return fields;
    }

    private object FormatDate(DateTime date)
        => new { dateTime = date.ToString("yyyy-MM-dd'T'HH:mm:ss.FFFFFFF", CultureInfo.InvariantCulture), timeZone };

    internal bool Matches(JsonElement existing)
        => GraphTransport.Text(existing, "subject") == subject &&
            GraphTransport.Text(existing, "showAs") == "free" &&
            FlagIs(existing, "isReminderOn", false) &&
            (!HasDeadline || (FlagIs(existing, "isAllDay", allDay) &&
                ReadDate(existing, "start") == AsInstant(start!.Value) &&
                ReadDate(existing, "end") == AsInstant(end!.Value)));

    internal static bool IsSafeToUpdate(JsonElement existing)
        => FlagIs(existing, "isOnlineMeeting", false) &&
            existing.TryGetProperty("attendees", out var attendees) &&
            attendees.ValueKind == JsonValueKind.Array && attendees.GetArrayLength() == 0;

    internal static bool FlagIs(JsonElement item, string key, bool value)
        => item.TryGetProperty(key, out var property) && property.ValueKind == (value ? JsonValueKind.True : JsonValueKind.False);

    private DateTimeOffset AsInstant(DateTime value)
        => allDay
            ? new DateTimeOffset(value, Shanghai.GetUtcOffset(value))
            : new DateTimeOffset(value, TimeSpan.Zero);

    private static DateTimeOffset? ReadDate(JsonElement existing, string key)
    {
        if (!existing.TryGetProperty(key, out var date) || date.ValueKind != JsonValueKind.Object)
            return null;
        var text = GraphTransport.Text(date, "dateTime");
        var zoneName = GraphTransport.Text(date, "timeZone");
        if (text is null || zoneName is null ||
            !DateTime.TryParseExact(text, "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF", CultureInfo.InvariantCulture,
                DateTimeStyles.None, out var local) ||
            !TimeZoneInfo.TryFindSystemTimeZoneById(zoneName, out var zone))
            return null;
        return new DateTimeOffset(local, zone.GetUtcOffset(local));
    }
}
