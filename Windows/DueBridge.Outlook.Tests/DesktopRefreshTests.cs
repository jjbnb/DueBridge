using DueBridge.Core;
using DueBridge.Outlook;
using DueBridge.Windows;

internal static class DesktopRefreshTests
{
    internal static async Task RunAsync()
    {
        var now = DateTimeOffset.Parse("2026-11-13T02:00:00Z");
        var target = new OutlookCalendarBinding(new("microsoft-a", "one@example.test"), "owned");
        var entry = new CalendarEntry("task-a", "作业", "source-details", null, now.AddDays(1));
        var initial = LocalSettings.Empty.WithSource(SourceKind.Mo, new("school-a", Enabled: true, AutoRead: true))
            with { OutlookAccount = target.Account, OutlookCalendar = target };
        var state = initial;
        int cloudWrites = 0;
        Task<SourcePreview> Read(SourceKind _, string? address, string? expected, CancellationToken token)
        {
            Check(expected == "school-a", "collector verifies the captured source account");
            return Task.FromResult(new SourcePreview("school-a", [entry]));
        }
        var local = new WorkspaceRefresh(() => state, next => state = next, Read,
            (_, _, _) => { cloudWrites++; return Task.FromResult(new CalendarSyncResult(1, 0, 0)); }, () => now);
        await local.RefreshAsync(SourceKind.Mo, new(true, false), default);
        Check(state.Mo.LastRead == now && state.DesktopEntries().Single().Entry.Title == "作业" && cloudWrites == 0,
            "local-only refresh publishes a restart snapshot without contacting Outlook");

        state = initial;
        var failedCloud = new WorkspaceRefresh(() => state, next => state = next, Read, (_, _, _) =>
        {
            Check(state.Mo.LastRead == now && state.Mo.LastSuccess is null,
                "snapshot is persisted before cloud write begins");
            throw new HttpRequestException("network-down");
        }, () => now);
        var failure = await failedCloud.RefreshAsync(SourceKind.Mo, new(true, true), default);
        Check(failure.WriteError is HttpRequestException && state.DesktopEntries().Count == 1 && state.Mo.LastSuccess is null,
            "failed Outlook write retains a successful local read without claiming write success");

        state = initial;
        var successful = new WorkspaceRefresh(() => state, next => state = next, Read, (_, entries, _) =>
        {
            Check(entries.Single().Title == "【课程待确认】作业 · 截止" && entries.Single().Notes == "source-details",
                "calendar receives a fresh normalized source entry rather than the display-only snapshot");
            return Task.FromResult(new CalendarSyncResult(1, 0, 0));
        }, () => now);
        var success = await successful.RefreshAsync(SourceKind.Mo, new(true, true), default);
        Check(state.Mo.LastSuccess == now && state.Mo.LastRead == now && success.Written?.Added == 1,
            "successful write advances only the captured source's cloud checkpoint");

        state = initial;
        using var cancellation = new CancellationTokenSource();
        var cancelled = new WorkspaceRefresh(() => state, next => state = next, async (kind, address, expected, token) =>
        {
            var result = await Read(kind, address, expected, token);
            cancellation.Cancel();
            return result;
        }, (_, _, _) => throw new Exception("forbidden-write"), () => now);
        await Fails<OperationCanceledException>(() => cancelled.RefreshAsync(SourceKind.Mo, new(true, true), cancellation.Token));
        Check(state.Mo.Snapshot is null && state.Mo.LastRead is null, "cancelled collector cannot publish a late snapshot");
        var reads = new DailySyncSchedule();
        var writes = new DailySyncSchedule();
        using var scheduledCancellation = new CancellationTokenSource();
        var scheduledCancelled = new WorkspaceRefresh(() => state, next => state = next, async (kind, address, expected, token) =>
        {
            var result = await Read(kind, address, expected, token);
            scheduledCancellation.Cancel();
            return result;
        }, (_, _, _) => throw new Exception("forbidden-write"), () => now);
        await Fails<OperationCanceledException>(() => scheduledCancelled.RunScheduledAsync(SourceKind.Mo,
            new(true, true), reads, writes, scheduledCancellation.Token));
        Check(reads.CanAttempt(state.Mo.LastRead, now) && writes.CanAttempt(state.Mo.LastSuccess, now),
            "cancelled scheduled read does not consume the Beijing day");

        state = initial;
        using var cloudCancellation = new CancellationTokenSource();
        var cloudCancelled = new WorkspaceRefresh(() => state, next => state = next, Read, (_, _, _) =>
        {
            cloudCancellation.Cancel();
            return Task.FromResult(new CalendarSyncResult(1, 0, 0));
        }, () => now);
        reads = new();
        writes = new();
        await Fails<OperationCanceledException>(() => cloudCancelled.RunScheduledAsync(SourceKind.Mo,
            new(true, true), reads, writes, cloudCancellation.Token));
        Check(state.Mo.LastRead == now && !reads.CanAttempt(state.Mo.LastRead, now) &&
            writes.CanAttempt(state.Mo.LastSuccess, now),
            "cancelled cloud write keeps the read checkpoint and allows cloud catch-up");

        state = initial;
        var otherSource = new WorkspaceRefresh(() => state, next => state = next,
            (_, _, _, _) => Task.FromResult(new SourcePreview("school-b", [entry])),
            (_, _, _) => throw new Exception("forbidden-write"), () => now);
        await Fails<SourceAccountChangedException>(() => otherSource.RefreshAsync(SourceKind.Mo, new(true, true), default));
        Check(state.Mo.Snapshot is null, "unexpected school account never becomes the active snapshot");

        state = initial;
        var changedBinding = new WorkspaceRefresh(() => state, next => state = next, async (kind, address, expected, token) =>
        {
            var result = await Read(kind, address, expected, token);
            state = state.WithSource(SourceKind.Mo, new("school-b"));
            return result;
        }, (_, _, _) => throw new Exception("forbidden-write"), () => now);
        await Fails<SourceAccountChangedException>(() => changedBinding.RefreshAsync(SourceKind.Mo, new(true, true), default));
        Check(state.Mo.AccountId == "school-b" && state.Mo.Snapshot is null, "late old-account read cannot replace a new binding");

        state = initial;
        var changedTarget = new WorkspaceRefresh(() => state, next => state = next, async (kind, address, expected, token) =>
        {
            var result = await Read(kind, address, expected, token);
            state = state.ClearSyncConsent() with { OutlookCalendar = null, OutlookAccount = null };
            return result;
        }, (_, _, _) => throw new Exception("forbidden-write"), () => now);
        var switched = await changedTarget.RefreshAsync(SourceKind.Mo, new(true, true), default);
        Check(switched.WriteError is WorkspaceBindingChangedException && state.Mo.LastRead == now && state.Mo.LastSuccess is null,
            "switching Outlook during a read keeps the local task but never contacts the old account");
        Console.WriteLine("Desktop refresh checks passed (9 scenarios).");
    }

    private static void Check(bool value, string scenario)
    {
        if (!value) throw new InvalidOperationException("Desktop refresh: " + scenario);
    }

    private static async Task Fails<T>(Func<Task> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }
}
