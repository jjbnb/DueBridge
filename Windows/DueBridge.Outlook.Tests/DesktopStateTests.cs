using System.Text.Json;
using System.Security.Cryptography;
using DueBridge.Core;
using DueBridge.Windows;

internal static class DesktopStateTests
{
    internal static void Run()
    {
        const string legacy = """
            {"Blackboard":{"AccountId":"bb-a","Enabled":true,"LastSuccess":"2026-11-12T02:00:00Z"},
             "Mo":{},"LearningInZju":{},"BlackboardAddress":"synthetic-private-address",
             "BlackboardCourses":{"bb/task":"数学"},"OutlookAccount":{"HomeAccountId":"outlook-a","Username":"user@example.test"},
             "OutlookCalendar":{"Account":{"HomeAccountId":"outlook-a","Username":"user@example.test"},"CalendarId":"owned"},"Paused":false}
            """;
        var settings = JsonSerializer.Deserialize<LocalSettings>(legacy)!;
        Check(settings.Blackboard.Enabled && settings.Blackboard.AccountId == "bb-a" &&
            settings.OutlookCalendar?.CalendarId == "owned", "legacy upgrade preserves source consent and Outlook binding");
        using var serialized = JsonDocument.Parse(JsonSerializer.Serialize(settings));
        Check(serialized.RootElement.GetProperty("Blackboard").TryGetProperty("AutoRead", out var autoRead) &&
            autoRead.ValueKind == JsonValueKind.False, "legacy upgrade defaults desktop auto-read to off");
        Check(serialized.RootElement.GetProperty("Blackboard").TryGetProperty("TodoEnabled", out var todoEnabled) &&
            todoEnabled.ValueKind == JsonValueKind.False, "legacy upgrade never enables To Do writing implicitly");
        Check(!settings.Card.Visible && !settings.Card.Topmost, "upgrade does not open or pin card without consent");

        var now = DateTimeOffset.Parse("2026-11-13T02:00:00Z");
        var first = new CalendarEntry("same-task", "第一份作业", "private-session-data", null, now.AddHours(3))
            { CourseLabel = "物理" };
        var allDay = new CalendarEntry("all-day", "全天任务", "private-note", new DateOnly(2026, 11, 14), null)
            { CourseLabel = "数学" };
        var withSnapshot = settings.AcceptPreview(SourceKind.Blackboard,
            new("bb-a", [first, allDay]), "synthetic-private-address", now);
        Check(withSnapshot.Blackboard.LastRead == now && withSnapshot.Blackboard.LastSuccess == settings.Blackboard.LastSuccess,
            "reading a snapshot never reports an Outlook write as successful");
        Check(withSnapshot.Blackboard.Snapshot!.Entries.All(entry => entry.Notes == ""),
            "raw source notes never enter the persisted snapshot");
        Check(withSnapshot.Blackboard.Enabled, "same-account preview keeps existing write consent");
        var later = withSnapshot.AcceptPreview(SourceKind.Blackboard,
            new("bb-a", [first with { DueAt = now.AddHours(6) }, allDay]), "synthetic-private-address", now.AddMinutes(1));
        Check(later.DesktopEntries().Count == 2 && later.DesktopEntries()[0].Entry.DueAt == now.AddHours(6),
            "rescheduled task replaces its former deadline without adding a duplicate");
        var withMo = later.AcceptPreview(SourceKind.Mo,
            new("mo-a", [first with { DueAt = now.AddHours(1) }]), null, now);
        var withAllSources = withMo.AcceptPreview(SourceKind.LearningInZju,
            new("learning-a", [allDay with { Key = "learning-day" }]), null, now);
        Check(withAllSources.DesktopEntries().Select(row => row.Source).SequenceEqual(
            new[] { SourceKind.Mo, SourceKind.Blackboard, SourceKind.Blackboard, SourceKind.LearningInZju }),
            "all three sources merge in deadline order without cross-source key collisions");
        var cancelled = withAllSources.AcceptPreview(SourceKind.Mo,
            new("mo-a", [first with { Cancelled = true }]), null, now);
        Check(cancelled.DesktopEntries().Count == 3, "cancelled tasks disappear from the card");

        var safe = settings.AcceptPreview(SourceKind.Mo, new("mo-a", [first with
        {
            Title = "https://learn.intl.zju.edu.cn/webapps/calendar/calendarFeed/private-value",
            CourseLabel = "bad\ncourse"
        }]), null, now).DesktopEntries().Single().Entry;
        Check(safe.Title == "未命名截止事项" && safe.CourseLabel == "课程待确认" && safe.Notes == "",
            "display snapshot normalizes untrusted source text");
        var labelled = settings.AcceptPreview(SourceKind.Blackboard,
            new("bb-a", [first with { Key = "bb/task" }]), null, now);
        Check(labelled.DesktopEntries().Single().Entry.CourseLabel == "数学", "BB local course name is reflected in snapshot");
        var switched = labelled.WithSource(SourceKind.Blackboard, labelled.Blackboard with { AutoRead = true })
            .AcceptPreview(SourceKind.Blackboard, new("bb-b", [first with { Key = "bb/task" }]), "new-address", now);
        Check(!switched.Blackboard.Enabled && !switched.Blackboard.AutoRead && switched.Blackboard.LastSuccess is null &&
            switched.Blackboard.Snapshot?.AccountId == "bb-b" && switched.BlackboardCourses.Count == 0,
            "changing source account replaces snapshot and clears old consent and account-specific BB labels");
        var inconsistent = labelled.WithSource(SourceKind.Blackboard, labelled.Blackboard with { AccountId = "other" });
        Check(inconsistent.DesktopEntries().Count == 0, "a mismatched stored scope never becomes visible");
        var cloudSwitched = withSnapshot.WithSource(SourceKind.Blackboard, withSnapshot.Blackboard with { AutoRead = true })
            .ClearSyncConsent();
        Check(!cloudSwitched.Blackboard.Enabled && cloudSwitched.Blackboard.AutoRead && cloudSwitched.DesktopEntries().Count == 2,
            "switching Outlook resets cloud consent without destroying local snapshots or desktop auto-read consent");
        var roundTrip = JsonSerializer.Deserialize<LocalSettings>(JsonSerializer.Serialize(withAllSources))!;
        Check(roundTrip.DesktopEntries().Count == 4 && roundTrip.Blackboard.LastRead == now.AddMinutes(1),
            "restart restores merged snapshots and independent read timestamps");

        var local = new SourceBinding("bb-a", AutoRead: true);
        Check(RefreshIntent.For(local, paused: false, sourceReady: true, targetReady: false, readDue: true, writeDue: true)
            == new RefreshIntent(true, false), "desktop refresh works without Outlook");
        Check(RefreshIntent.For(new("bb-a", Enabled: true), false, true, true, false, true)
            == new RefreshIntent(true, true), "legacy Outlook-only consent still collects before writing");
        Check(RefreshIntent.For(new("bb-a", Enabled: true), false, true, true, false, true, localOnly: true)
            == new RefreshIntent(true, false), "manual card refresh never grants cloud write consent");
        Check(RefreshIntent.For(local, true, true, true, true, true) == new RefreshIntent(false, false),
            "global pause stops background reads and cloud writes");
        Check(RefreshIntent.For(local, true, true, true, true, true, localOnly: true) == new RefreshIntent(true, false),
            "explicit local refresh remains available while background work is paused");
        Check(RefreshIntent.For(new(), false, true, true, true, true, localOnly: true) == new RefreshIntent(false, false),
            "unbound source is not read by the card");
        Check(RefreshIntent.For(local, false, false, true, true, true) == new RefreshIntent(false, false),
            "a source requiring login is not polled automatically");
        Check(RefreshIntent.For(local, false, true, false, false, false) == new RefreshIntent(false, false),
            "a successful Beijing day does not read again on each countdown tick");

        var area = new DesktopBounds(-1920, 0, 1920, 1040);
        Check(DesktopBounds.Fit(new(4000, -200, 360, 480), area) == new DesktopBounds(-360, 0, 360, 480),
            "removed-monitor card is restored inside the available work area");
        Check(DesktopBounds.Fit(new(-3000, 0, 4000, 2000), area) == area,
            "oversized restored card fits the current monitor");
        Check(DesktopBounds.Fit(new(double.NaN, double.PositiveInfinity, -3, 0), new(0, 0, 1200, 800))
            == new DesktopBounds(0, 0, 360, 480), "invalid geometry cannot strand or crash the card");
        if (OperatingSystem.IsWindows())
        {
            var directory = Path.Combine(Path.GetTempPath(), "DueBridge-desktop-tests-" + Guid.NewGuid().ToString("N"));
            try
            {
                var store = new SettingsStore(directory);
                var todoAccount = new DueBridge.Outlook.OutlookAccount("todo-account", "todo@example.test");
                store.Save(withAllSources with { TodoAccount = todoAccount,
                    TodoList = new(todoAccount, "todo-list"), TodoPending = new() { ["pending-op"] = "合成待确认任务" } });
                var restored = store.Load();
                Check(restored.TodoPending.ContainsKey("pending-op") && restored.TodoList?.ListId == "todo-list",
                    "DPAPI restores To Do binding and pending operation guard");
                Check(restored.DesktopEntries().Count == 4 && restored.Blackboard.LastRead == now.AddMinutes(1),
                    "Windows DPAPI save and load restores all source snapshots");
                var path = Path.Combine(directory, "settings.dpapi");
                Check(!System.Text.Encoding.UTF8.GetString(File.ReadAllBytes(path)).Contains("synthetic-private-address", StringComparison.Ordinal),
                    "Windows storage never writes the private source address as plaintext");
                File.WriteAllText(path, "not-an-encrypted-snapshot");
                bool rejected = false;
                try { store.Load(); }
                catch (CryptographicException) { rejected = true; }
                Check(rejected, "corrupt encrypted storage is rejected rather than silently resetting settings");
                Console.WriteLine("Windows DPAPI snapshot checks passed.");
            }
            finally { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); }
        }
        else Console.WriteLine("Windows DPAPI snapshot checks require Windows (skipped on this host).");
        Check(DesktopBounds.PopupAt(1910,1030,new(0,0,1920,1040),360,480) == new DesktopBounds(1548,538,360,480),
            "tray popup opens above the pointer and stays inside the right work-area edge");
        Check(DesktopBounds.PopupAt(-1910,10,new(-1920,0,1920,1040),360,480) == new DesktopBounds(-1898,0,360,480),
            "tray popup handles a left-side monitor and top taskbar");
        Check(TrayClosePolicy.HideInsteadOfExit(true,false,false) &&
            !TrayClosePolicy.HideInsteadOfExit(false,false,false) &&
            !TrayClosePolicy.HideInsteadOfExit(true,true,false) &&
            !TrayClosePolicy.HideInsteadOfExit(true,false,true), "closing never traps an app without a tray icon or blocks explicit/session exit");
        TodoWorkspaceTests.StateChecks();
        Console.WriteLine("Desktop state checks passed.");
    }

    private static void Check(bool condition, string scenario)
    {
        if (!condition) throw new InvalidOperationException("Desktop: " + scenario);
    }
}
