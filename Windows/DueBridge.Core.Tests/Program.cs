using System.Net;
using System.Text;
using System.Text.Json;
using DueBridge.Core;

const string FeedRoot = "https://learn.intl.zju.edu.cn/webapps/calendar/calendarFeed/";
const string TestAddress = FeedRoot + "synthetic";
const string EmptyCalendar = "BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR";

using var fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "desktop-parity.json")));
string Data(string name) => fixture.RootElement.GetProperty(name).GetString()!;
var now = DateTimeOffset.Parse(Data("now"));
var original = BlackboardCalendar.Parse(Data("originalIcs"));
var updated = BlackboardCalendar.Parse(Data("rescheduledIcs"));
var timed = original.Single(entry => entry.Key == Data("timedKey"));
var allDay = original.Single(entry => entry.Key == Data("allDayKey"));
Equal(DateTimeOffset.Parse(Data("timedDueUtc")), timed.DueAt, "UTC instant");
Equal(DateOnly.Parse(Data("allDay")), allDay.AllDay, "civil date");
Equal<DateTimeOffset?>(null, allDay.DueAt, "civil date is not an instant");
Equal(DateTimeOffset.Parse(Data("rescheduledDueUtc")), updated.Single(entry => entry.Key == timed.Key).DueAt, "identity after reschedule");
Equal(Data("expectedTimedTitle"), DeadlinePresentation.ForCalendar(timed, Data("courseName")).Title, "calendar title");
Equal(timed, BlackboardCalendar.Parse(Data("originalIcs")).Single(entry => entry.Key == timed.Key), "repeatable read");
Equal("课程待确认", DeadlinePresentation.ForCalendar(timed, null).CourseLabel, "unknown course");
var privateContent = Data("originalIcs").Replace("SUMMARY:合成定时作业",
    "SUMMARY:" + TestAddress + "\nDESCRIPTION:" + TestAddress, StringComparison.Ordinal);
var privateEntry = DeadlinePresentation.ForCalendar(
    BlackboardCalendar.Parse(privateContent).Single(entry => entry.Key == timed.Key), TestAddress);
Equal(false, (privateEntry.Title + privateEntry.Notes).Contains(TestAddress, StringComparison.Ordinal),
    "BB subscription material never appears in calendar titles or descriptions");
Equal(true, DeadlinePresentation.NeedsCatchUp(DateTimeOffset.Parse("2026-10-24T15:59:59Z"), DateTimeOffset.Parse("2026-10-24T16:00:00Z")), "Shanghai midnight");
Equal(false, DeadlinePresentation.NeedsCatchUp(DateTimeOffset.Parse("2026-10-24T16:00:00Z"), DateTimeOffset.Parse("2026-10-24T16:00:01Z")), "once per Shanghai day");
Equal("今天到期（全天）", DeadlinePresentation.Countdown(allDay, new DateTimeOffset(allDay.AllDay!.Value.ToDateTime(new TimeOnly(23, 59)), TimeSpan.FromHours(8))), "all-day countdown uses Shanghai date");
Equal(false, DeadlinePresentation.IsBeforeToday(allDay, new DateTimeOffset(allDay.AllDay!.Value.ToDateTime(new TimeOnly(23, 59)), TimeSpan.FromHours(8))), "all-day event remains eligible until next day");

var schedule = new DailySyncSchedule();
Equal(true, schedule.CanAttempt(lastSuccess: null, now), "initial automatic catch-up");
schedule.MarkAttempt(now);
schedule.MarkTransientFailure();
Equal(false, schedule.CanAttempt(lastSuccess: null, now), "timer does not immediately repeat failed batch");
schedule.RearmAfterRecovery();
Equal(true, schedule.CanAttempt(lastSuccess: null, now), "wake or reconnect can catch up transient failure");
schedule.MarkAttempt(now);
schedule.RearmAfterRecovery();
Equal(false, schedule.CanAttempt(lastSuccess: null, now), "wake does not rearm a permanent failure");
Equal(false, schedule.CanAttempt(lastSuccess: now, now.AddMinutes(1)), "successful day does not repeat");
Equal(true, schedule.CanAttempt(lastSuccess: now, now.AddDays(1)), "new Shanghai day allows sync");

Equal(new Uri(TestAddress), BlackboardFeed.ValidateAddress("  " + TestAddress + "  "), "school calendar address");
foreach (var address in new[]
{
    "http://learn.intl.zju.edu.cn/webapps/calendar/calendarFeed/synthetic",
    "https://learn.intl.zju.edu.cn.evil.example/webapps/calendar/calendarFeed/synthetic",
    "https://name@learn.intl.zju.edu.cn/webapps/calendar/calendarFeed/synthetic",
    "https://learn.intl.zju.edu.cn:444/webapps/calendar/calendarFeed/synthetic",
    TestAddress + "#",
    FeedRoot + "%2e%2e/calendarFeed/synthetic",
    FeedRoot + "%5csynthetic",
    FeedRoot + "%0asynthetic",
    FeedRoot + "bad%"
})
    Throws<BlackboardException>(() => BlackboardFeed.ValidateAddress(address), "scope check");

var cancelled = BlackboardCalendar.Parse("""
    BEGIN:VCALENDAR
    VERSION:2.0
    METHOD:CANCEL
    BEGIN:VEVENT
    UID:20261110T020000Z-_blackboard.platform.gradebook2.GradableItem-_1_1@synthetic.example
    END:VEVENT
    END:VCALENDAR
    """).Single();
Equal(true, cancelled.Cancelled, "calendar-wide cancellation");
Equal<DateTimeOffset?>(null, cancelled.DueAt, "cancellation can omit deadline");
Throws<BlackboardException>(() => BlackboardCalendar.Parse("<html>login</html>"), "login page");
Throws<BlackboardException>(() => BlackboardCalendar.Parse("""
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:unknown-grammar
    DTSTART:20261110T020000Z
    END:VEVENT
    END:VCALENDAR
    """), "unverified identity cannot become a calendar entry");
Throws<BlackboardException>(() => BlackboardCalendar.Parse("""
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:20261110T020000Z-_blackboard.platform.gradebook2.GradableItem-_1_1@synthetic.example
    DTSTART;TZID=America/New_York:20260308T023000
    END:VEVENT
    END:VCALENDAR
    """), "nonexistent civil time is rejected");

using var redirects = new HttpClient(new SyntheticHandler(request =>
{
    if (request.RequestUri == new Uri(TestAddress))
        return new HttpResponseMessage(HttpStatusCode.Redirect) { Headers = { Location = new Uri(FeedRoot + "redirected") } };
    Equal(new Uri(FeedRoot + "redirected"), request.RequestUri, "redirect stays in scope");
    return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(EmptyCalendar, Encoding.UTF8, "text/calendar") };
}));
var feed = new BlackboardFeed(redirects);
Equal(0, (await feed.PreviewAsync(TestAddress, default)).Entries.Count, "same-scope redirect and empty feed");
using var offsite = new HttpClient(new SyntheticHandler(_ =>
    new HttpResponseMessage(HttpStatusCode.Redirect) { Headers = { Location = new Uri("https://example.org/login") } }));
await ThrowsAsync<BlackboardException>(() => new BlackboardFeed(offsite).PreviewAsync(TestAddress, default), "off-site redirect");
using var large = new HttpClient(new SyntheticHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
{
    Content = new ByteArrayContent(new byte[8 * 1024 * 1024 + 1])
}));
await ThrowsAsync<BlackboardException>(() => new BlackboardFeed(large).PreviewAsync(TestAddress, default), "declared download size");

var operation = new SyncOperation();
var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
var first = operation.TryRunAsync(async cancellation =>
{
    entered.SetResult();
    try { await Task.Delay(Timeout.InfiniteTimeSpan, cancellation); }
    finally { stopped.SetResult(); }
});
await entered.Task;
Equal(false, await operation.TryRunAsync(_ => throw new InvalidOperationException("Second task should never run")), "single flight");
await operation.CancelAndDrainAsync();
Equal(true, stopped.Task.IsCompleted, "binding change waits for old operation to stop");
Equal(true, await first, "cancellation drains cleanly");
Equal(true, await operation.TryRunAsync(_ => Task.CompletedTask), "gate reusable");

Console.WriteLine("DueBridge.Core synthetic checks passed.");

static void Equal<T>(T expected, T actual, string check)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
        throw new Exception($"{check}: expected {expected}, got {actual}");
}

static void Throws<TException>(Action action, string check) where TException : Exception
{
    try { action(); }
    catch (TException) { return; }
    throw new Exception($"{check}: expected {typeof(TException).Name}");
}

static async Task ThrowsAsync<TException>(Func<Task> action, string check) where TException : Exception
{
    try { await action(); }
    catch (TException) { return; }
    throw new Exception($"{check}: expected {typeof(TException).Name}");
}

sealed class SyntheticHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        => Task.FromResult(respond(request));
}
