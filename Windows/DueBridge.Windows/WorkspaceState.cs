using System.Text.Json;
using DueBridge.Core;
using DueBridge.Outlook;

namespace DueBridge.Windows;

internal enum SourceKind { Blackboard, Mo, LearningInZju }

internal sealed record SourceSnapshot(string AccountId, IReadOnlyList<CalendarEntry> Entries);

internal sealed record SourceBinding(
    string? AccountId = null, bool Enabled = false, DateTimeOffset? LastSuccess = null,
    bool AutoRead = false, DateTimeOffset? LastRead = null, SourceSnapshot? Snapshot = null, string? ReadError = null);

// Bounds are stored in native screen pixels, so monitor work areas and negative desktop coordinates agree.
internal sealed record DesktopBounds(double Left, double Top, double Width, double Height)
{
    internal static DesktopBounds Fit(DesktopBounds bounds, DesktopBounds area)
    {
        var width = Math.Min(double.IsFinite(bounds.Width) && bounds.Width > 0 ? bounds.Width : 360, area.Width);
        var height = Math.Min(double.IsFinite(bounds.Height) && bounds.Height > 0 ? bounds.Height : 480, area.Height);
        var left = double.IsFinite(bounds.Left) ? bounds.Left : area.Left;
        var top = double.IsFinite(bounds.Top) ? bounds.Top : area.Top;
        return new(Math.Clamp(left, area.Left, area.Left + area.Width - width),
            Math.Clamp(top, area.Top, area.Top + area.Height - height), width, height);
    }
}

internal sealed record DesktopCardSettings(bool Visible = false, bool Topmost = false, DesktopBounds? Bounds = null);
internal sealed record DesktopEntry(SourceKind Source, CalendarEntry Entry);

internal sealed record LocalSettings(
    SourceBinding Blackboard, SourceBinding Mo, SourceBinding LearningInZju,
    string? BlackboardAddress, Dictionary<string, string> BlackboardCourses,
    OutlookAccount? OutlookAccount, OutlookCalendarBinding? OutlookCalendar, bool Paused)
{
    public DesktopCardSettings Card { get; init; } = new();
    internal static LocalSettings Empty => new(new(), new(), new(), null, new(StringComparer.Ordinal), null, null, false);

    internal SourceBinding Source(SourceKind kind) => kind switch
    {
        SourceKind.Blackboard => Blackboard,
        SourceKind.Mo => Mo,
        SourceKind.LearningInZju => LearningInZju,
        _ => throw new ArgumentOutOfRangeException(nameof(kind))
    };

    internal LocalSettings WithSource(SourceKind kind, SourceBinding value) => kind switch
    {
        SourceKind.Blackboard => this with { Blackboard = value },
        SourceKind.Mo => this with { Mo = value },
        SourceKind.LearningInZju => this with { LearningInZju = value },
        _ => throw new ArgumentOutOfRangeException(nameof(kind))
    };

    internal LocalSettings ClearSyncConsent() => this with
    {
        Blackboard = Blackboard with { Enabled = false, LastSuccess = null },
        Mo = Mo with { Enabled = false, LastSuccess = null },
        LearningInZju = LearningInZju with { Enabled = false, LastSuccess = null }
    };

    internal LocalSettings AcceptPreview(SourceKind kind, SourcePreview preview, string? address, DateTimeOffset now)
    {
        var previous = Source(kind);
        bool changed = previous.AccountId != preview.AccountId;
        var binding = changed ? new SourceBinding(preview.AccountId) : previous;
        var entries = preview.Entries.Where(entry => !entry.Cancelled)
            .Select(entry => DeadlinePresentation.ForDesktop(entry, entry.CourseLabel))
            .GroupBy(entry => entry.Key, StringComparer.Ordinal).Select(group => group.Last()).ToArray();
        var updated = WithSource(kind, binding with
        {
            LastRead = now, ReadError = null, Snapshot = new(preview.AccountId, entries)
        });
        return kind == SourceKind.Blackboard ? updated with
        {
            BlackboardAddress = address ?? updated.BlackboardAddress,
            BlackboardCourses = changed ? new(StringComparer.Ordinal) : updated.BlackboardCourses
        } : updated;
    }

    internal IReadOnlyList<DesktopEntry> DesktopEntries() => Enum.GetValues<SourceKind>()
        .SelectMany(kind => Source(kind) is { Snapshot: { } snapshot } binding && binding.AccountId == snapshot.AccountId
            ? snapshot.Entries.Where(entry => !entry.Cancelled).Select(entry => new DesktopEntry(kind,
                DeadlinePresentation.ForDesktop(entry, kind == SourceKind.Blackboard
                    ? BlackboardCourses.GetValueOrDefault(entry.Key) ?? entry.CourseLabel : entry.CourseLabel)))
            : [])
        .OrderBy(row => DeadlinePresentation.SortDeadline(row.Entry)).ThenBy(row => row.Source)
        .ThenBy(row => row.Entry.Key, StringComparer.Ordinal).ToArray();

    internal void Validate()
    {
        if (Blackboard is null || Mo is null || LearningInZju is null || BlackboardCourses is null || Card is null ||
            (OutlookCalendar is { } target && (target.Account is null ||
                target.Account.HomeAccountId != OutlookAccount?.HomeAccountId || string.IsNullOrWhiteSpace(target.CalendarId))))
            throw new JsonException("Invalid DueBridge settings.");
        foreach (var kind in Enum.GetValues<SourceKind>())
            if (Source(kind).Snapshot is { } snapshot && (string.IsNullOrEmpty(snapshot.AccountId) ||
                snapshot.Entries is null || snapshot.Entries.Count > 50_000 || snapshot.Entries.Any(entry =>
                    entry is null || string.IsNullOrEmpty(entry.Key) ||
                    (entry.AllDay is null) == (entry.DueAt is null))))
                throw new JsonException("Invalid DueBridge snapshot.");
    }
}

internal sealed record RefreshIntent(bool Read, bool Write)
{
    internal static RefreshIntent For(SourceBinding binding, bool paused, bool sourceReady, bool targetReady,
        bool readDue, bool writeDue, bool localOnly = false)
    {
        if (!sourceReady || string.IsNullOrEmpty(binding.AccountId)) return new(false, false);
        bool write = !localOnly && !paused && targetReady && binding.Enabled && writeDue;
        return new(localOnly || (!paused && binding.AutoRead && readDue) || write, write);
    }
}
