using DueBridge.Core;
using DueBridge.Outlook;

namespace DueBridge.Windows;

internal sealed record RefreshOutcome(SourcePreview Preview, CalendarSyncResult? Written = null, Exception? WriteError = null,
    CalendarSyncResult? TodoWritten = null, Exception? TodoError = null);

internal sealed class SourceAccountChangedException : Exception
{
    internal SourceAccountChangedException() : base("当前登录与绑定来源不同。请重新读取预览并确认更新设置。") { }
}

internal sealed class WorkspaceBindingChangedException : Exception
{
    internal WorkspaceBindingChangedException() : base("同步绑定已变化，已停止向原目标写入。请重新确认同步设置。") { }
}

internal sealed class WorkspaceRefresh(
    Func<LocalSettings> current, Action<LocalSettings> save,
    Func<SourceKind, string?, string?, CancellationToken, Task<SourcePreview>> read,
    Func<OutlookCalendarBinding, IReadOnlyList<CalendarEntry>, CancellationToken, Task<CalendarSyncResult>> write,
    Func<DateTimeOffset> now,
    Func<TodoListBinding, IReadOnlyList<CalendarEntry>, CancellationToken, Task<CalendarSyncResult>>? writeTodo = null)
{
    internal async Task<RefreshOutcome> RunScheduledAsync(SourceKind source, RefreshIntent intent,
        DailySyncSchedule reads, DailySyncSchedule writes, CancellationToken token, DailySyncSchedule? todoSchedule = null)
    {
        token.ThrowIfCancellationRequested();
        reads.MarkAttempt(now());
        if (intent.Write) writes.MarkAttempt(now());
        if (intent.WriteTodo) todoSchedule?.MarkAttempt(now());
        try { return await RefreshAsync(source, intent, token); }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            // Reset attempts only; successful read/write timestamps remain the source of truth.
            reads.Reset();
            if (intent.Write) writes.Reset();
            if (intent.WriteTodo) todoSchedule?.Reset();
            throw;
        }
    }

    internal async Task<RefreshOutcome> RefreshAsync(SourceKind source, RefreshIntent intent, CancellationToken token)
    {
        if (!intent.Read) throw new InvalidOperationException("No source read requested.");
        token.ThrowIfCancellationRequested();
        var captured = current();
        var expected = captured.Source(source).AccountId;
        if (string.IsNullOrEmpty(expected)) throw new SourceAccountChangedException();
        var preview = await read(source, captured.BlackboardAddress, expected, token);
        token.ThrowIfCancellationRequested();
        if (preview.AccountId != expected || current().Source(source).AccountId != expected)
            throw new SourceAccountChangedException();

        // Commit the local result first: a later cloud failure must not discard the user's tasks.
        save(current().AcceptPreview(source, preview, captured.BlackboardAddress, now()));
        CalendarSyncResult? calendarResult = null, todoResult = null;
        Exception? calendarError = null, todoError = null;
        if (intent.Write) try
        {
            var latest = current();
            if (latest.Paused || !latest.Source(source).Enabled || captured.OutlookCalendar is not { } target ||
                latest.OutlookCalendar != target || latest.OutlookAccount?.HomeAccountId != target.Account.HomeAccountId)
                throw new WorkspaceBindingChangedException();
            var entries = preview.Entries.Select(entry => DeadlinePresentation.ForCalendar(entry,
                source == SourceKind.Blackboard ? latest.BlackboardCourses.GetValueOrDefault(entry.Key) : entry.CourseLabel)).ToArray();
            var result = await write(target, entries, token);
            token.ThrowIfCancellationRequested();
            latest = current();
            if (latest.Source(source).AccountId != expected || latest.OutlookCalendar != target ||
                !latest.Source(source).Enabled || latest.Paused)
                throw new WorkspaceBindingChangedException();
            save(latest.WithSource(source, latest.Source(source) with { LastSuccess = now() }));
            calendarResult = result;
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            calendarError = error;
        }
        token.ThrowIfCancellationRequested();
        if (intent.WriteTodo) try
        {
            var latest = current();
            if (latest.Paused || !latest.Source(source).TodoEnabled || latest.Source(source).AccountId != expected ||
                captured.TodoList is not { } target || latest.TodoList != target ||
                latest.TodoAccount?.HomeAccountId != target.Account.HomeAccountId || writeTodo is null)
                throw new WorkspaceBindingChangedException();
            var entries = preview.Entries.Select(entry => DeadlinePresentation.ForTodo(entry,
                source == SourceKind.Blackboard ? latest.BlackboardCourses.GetValueOrDefault(entry.Key) : entry.CourseLabel)
                with { Key = System.Text.Json.JsonSerializer.Serialize(new[] { source.ToString(), expected, entry.Key }) }).ToArray();
            var result = await writeTodo(target, entries, token);
            token.ThrowIfCancellationRequested();
            latest = current();
            if (latest.Source(source).AccountId != expected || latest.TodoList != target ||
                !latest.Source(source).TodoEnabled || latest.Paused)
                throw new WorkspaceBindingChangedException();
            save(latest.WithSource(source, latest.Source(source) with { LastTodoSuccess = now() }));
            todoResult = result;
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            todoError = error;
        }
        return new(preview, calendarResult, calendarError, todoResult, todoError);
    }
}
