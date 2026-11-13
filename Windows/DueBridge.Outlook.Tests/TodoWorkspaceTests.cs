using System.Text.Json;
using DueBridge.Core;
using DueBridge.Outlook;
using DueBridge.Windows;

internal static class TodoWorkspaceTests
{
    internal static void StateChecks()
    {
        MicrosoftPermissionPolicy.AssertGranted(MicrosoftPermission.Tasks, ["Tasks.ReadWrite"]);
        MicrosoftPermissionPolicy.AssertGranted(MicrosoftPermission.Calendar, ["https://graph.microsoft.com/Calendars.ReadWrite"]);
        Throws<OutlookException>(() => MicrosoftPermissionPolicy.AssertGranted(MicrosoftPermission.Tasks, ["Calendars.ReadWrite"]));
        Check(MicrosoftPermissionPolicy.Scope(MicrosoftPermission.Tasks) == "https://graph.microsoft.com/Tasks.ReadWrite",
            "To Do authorization requests its task permission rather than calendar permission");
        var state = BothTargets();
        var todoOff = state.ClearTodoConsent();
        Check(!todoOff.Mo.TodoEnabled && todoOff.Mo.Enabled && todoOff.Mo.AutoRead,
            "switching To Do preserves calendar and desktop consent");
        var calendarOff = state.ClearSyncConsent();
        Check(calendarOff.Mo.TodoEnabled && !calendarOff.Mo.Enabled, "switching calendar preserves To Do consent");
        var changed = state.AcceptPreview(SourceKind.Mo, new("new-school", []), null, DateTimeOffset.UtcNow);
        Check(!changed.Mo.TodoEnabled && !changed.Mo.Enabled && !changed.Mo.AutoRead,
            "switching source account resets both destinations' write consent");
        Check(RefreshIntent.For(state.Mo, false, true, false, false, false, todoReady: true, todoDue: true)
            == new RefreshIntent(true, false, true), "To Do-only writing works without Outlook calendar");
        Check(RefreshIntent.For(state.Mo, false, true, true, true, true, localOnly: true, todoReady: true, todoDue: true)
            == new RefreshIntent(true, false, false), "desktop refresh never writes to either cloud destination");
        Check(RefreshIntent.For(state.Mo, true, true, true, true, true, todoReady: true, todoDue: true)
            == new RefreshIntent(false, false, false), "pause blocks both cloud destinations");
        state = state with { TodoPending = new() { ["scope/pending"] = "合成作业" } };
        var restored = JsonSerializer.Deserialize<LocalSettings>(JsonSerializer.Serialize(state))!;
        restored.Validate();
        Check(restored.TodoPending["scope/pending"] == "合成作业" && restored.TodoList == state.TodoList && restored.Mo.TodoEnabled,
            "restart preserves To Do target, consent and unresolved creation guard");
        int journalSaves = 0;
        var journal = new SettingsTodoJournal(() => state, transform => { journalSaves++; return state = transform(state); });
        journal.Complete("not-pending");
        Check(journalSaves == 0, "unchanged synced tasks do not rewrite encrypted snapshots");
        journal.Begin("scope/two", "第二份合成作业");
        Check(state.TodoPending.Count == 2 && journal.IsPending("scope/two"), "journal persists before a cloud create");
        journal.Complete("scope/two");
        Check(state.TodoPending.Count == 1 && !journal.IsPending("scope/two"), "confirmed write clears only its own journal item");
        Console.WriteLine("To Do workspace state and permission checks passed.");
    }

    internal static async Task RefreshChecksAsync()
    {
        var now = DateTimeOffset.Parse("2026-11-13T02:00:00Z");
        var state = BothTargets();
        var entry = new CalendarEntry("task", "作业", "来源：智海 MO", null, now.AddHours(1)) { CourseLabel = "物理" };
        int reads = 0, todoWrites = 0;
        Task<SourcePreview> Read(SourceKind _, string? address, string? expected, CancellationToken token)
        {
            reads++;
            Check(expected == "school-a", "both targets share an account-verified source read");
            return Task.FromResult(new SourcePreview("school-a", [entry]));
        }
        var refresh = new WorkspaceRefresh(() => state, next => state = next, Read,
            (_, _, _) => throw new OutlookException(OutlookFailure.Unavailable), () => now,
            (target, entries, _) =>
            {
                todoWrites++;
                Check(target.Account.HomeAccountId == "todo-account" && entries.Single().Title == "【物理】作业" &&
                    entries.Single().Key == "[\"Mo\",\"school-a\",\"task\"]", "To Do receives source/account-scoped identity and course title");
                return Task.FromResult(new CalendarSyncResult(1, 0, 0));
            });
        var outcome = await refresh.RefreshAsync(SourceKind.Mo, new(true, true, true), default);
        Check(reads == 1 && todoWrites == 1 && state.Mo.LastRead == now && state.Mo.LastSuccess is null &&
            state.Mo.LastTodoSuccess == now && outcome.WriteError is OutlookException && outcome.TodoWritten?.Added == 1,
            "calendar failure neither discards the local read nor blocks To Do success");

        state = BothTargets();
        var todoFailure = new WorkspaceRefresh(() => state, next => state = next, Read,
            (_, _, _) => Task.FromResult(new CalendarSyncResult(1, 0, 0)), () => now,
            (_, _, _) => throw new TodoException(TodoFailure.Unavailable));
        outcome = await todoFailure.RefreshAsync(SourceKind.Mo, new(true, true, true), default);
        Check(state.Mo.LastSuccess == now && state.Mo.LastTodoSuccess is null && outcome.TodoError is TodoException,
            "To Do failure preserves calendar success and its independent checkpoint");

        state = BothTargets();
        var switched = new WorkspaceRefresh(() => state, next => state = next, Read, (_, _, _) =>
        {
            state = state.ClearTodoConsent() with { TodoList = null, TodoAccount = null };
            return Task.FromResult(new CalendarSyncResult(1, 0, 0));
        }, () => now, (_, _, _) => throw new Exception("must not reach the former To Do account"));
        outcome = await switched.RefreshAsync(SourceKind.Mo, new(true, true, true), default);
        Check(outcome.TodoError is WorkspaceBindingChangedException && state.Mo.LastTodoSuccess is null,
            "switching To Do during another destination write cannot use the former target");

        state = BothTargets();
        using var cancellation = new CancellationTokenSource();
        var cancelled = new WorkspaceRefresh(() => state, next => state = next, Read,
            (_, _, _) => throw new Exception("calendar was not selected"), () => now, (_, _, _) =>
        {
            cancellation.Cancel();
            return Task.FromResult(new CalendarSyncResult(1, 0, 0));
        });
        var readSchedule = new DailySyncSchedule();
        var calendarSchedule = new DailySyncSchedule();
        var todoSchedule = new DailySyncSchedule();
        try
        {
            await cancelled.RunScheduledAsync(SourceKind.Mo, new(true, false, true), readSchedule, calendarSchedule,
                cancellation.Token, todoSchedule);
            throw new Exception("expected cancellation");
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        Check(state.Mo.LastRead == now && state.Mo.LastTodoSuccess is null && todoSchedule.CanAttempt(null, now),
            "cancelled To Do write can catch up without losing a successful local read");
        Console.WriteLine("To Do independent destination refresh checks passed (4 scenarios).");
    }

    private static LocalSettings BothTargets()
    {
        var calendar = new OutlookCalendarBinding(new("calendar-account", "calendar@example.test"), "calendar-list");
        var todo = new TodoListBinding(new("todo-account", "todo@example.test"), "todo-list");
        return LocalSettings.Empty.WithSource(SourceKind.Mo, new("school-a", Enabled: true, AutoRead: true, TodoEnabled: true))
            with { OutlookAccount = calendar.Account, OutlookCalendar = calendar, TodoAccount = todo.Account, TodoList = todo };
    }

    private static void Check(bool value, string scenario)
    {
        if (!value) throw new InvalidOperationException("To Do workspace: " + scenario);
    }
    private static void Throws<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }
}
