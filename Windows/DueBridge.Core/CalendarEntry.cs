namespace DueBridge.Core;

public sealed record CalendarEntry(
    string Key, string Title, string Notes, DateOnly? AllDay, DateTimeOffset? DueAt, bool Cancelled = false)
{
    public string CourseLabel { get; init; } = DeadlinePresentation.UnknownCourse;
}

public sealed record SourcePreview(string AccountId, IReadOnlyList<CalendarEntry> Entries)
{
    public IReadOnlyList<string> Warnings { get; init; } = [];
}

public sealed record CalendarSyncResult(int Added, int Updated, int Unchanged);
