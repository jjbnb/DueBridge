using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using DueBridge.Core;
using DueBridge.Outlook;

var callback = OutlookSignIn.CreateBrowserOptions();
foreach (var (page, expected) in new[] {
    (callback.HtmlMessageSuccess, "Microsoft 账号已验证。请关闭此页面并返回 DueBridge。"),
    (callback.HtmlMessageError, "Microsoft 账号登录未完成。请关闭此页面并返回 DueBridge。") })
{
    if (page is null || page.Any(c => c > 127))
        throw new Exception("Microsoft callback must survive a legacy browser charset without mojibake.");
    if (!WebUtility.HtmlDecode(Encoding.ASCII.GetString(Encoding.UTF8.GetBytes(page))).Contains(expected, StringComparison.Ordinal))
        throw new Exception("Microsoft callback lost its Chinese success/error message.");
}
Console.WriteLine("Microsoft callback encoding checks passed.");

await TodoTests.RunAsync();
DesktopStateTests.Run();
await DesktopRefreshTests.RunAsync();

const string calendarPath = "/v1.0/me/calendars";
const string targetPath = calendarPath + "/dedicated";
const string eventPath = "/v1.0/me/calendars/dedicated/events";
const string calendarProperty = "String {7ce84863-2e9c-4f3e-8de7-c4fa72916a44} Name DueBridgeCalendar";
const string eventProperty = "String {7ce84863-2e9c-4f3e-8de7-c4fa72916a44} Name DueBridgeEntry";
var account = new OutlookAccount("home-a", "one@example.test");
var otherAccount = new OutlookAccount("home-b", "two@example.test");
var binding = new OutlookCalendarBinding(account, "dedicated");
var allDay = new CalendarEntry("bb/course1/task1", "Review", "Course details", new DateOnly(2026, 11, 9), null);
var timed = new CalendarEntry("mo/account/task2", "Read", "Course details", null,
    new DateTimeOffset(2026, 11, 9, 18, 20, 0, TimeSpan.FromHours(-5)));
var yesterday = allDay with { Key = "old", AllDay = new DateOnly(2026, 11, 7) };

await Run("Creates a dedicated calendar without adopting the same name", async () =>
{
    var graph = new FakeGraph();
    graph.Respond(HttpMethod.Get, calendarPath, _ => Page(new { id = "user-owned", name = "DueBridge" }));
    graph.Respond(HttpMethod.Post, calendarPath, request =>
    {
        Equal("DueBridge", request.Body.GetProperty("name").GetString());
        Equal(calendarProperty, request.Body.GetProperty("singleValueExtendedProperties")[0].GetProperty("id").GetString());
        return Json(new { id = "dedicated" }, HttpStatusCode.Created);
    });
    Equal(binding, await Client(graph).CreateCalendarAsync(account));
    graph.Done();
});

await Run("Recovers an owned calendar whose create response was lost", async () =>
{
    var graph = new FakeGraph();
    graph.Respond(HttpMethod.Get, calendarPath, _ => Page());
    graph.Respond(HttpMethod.Post, calendarPath, _ => throw new HttpRequestException("secret"));
    graph.Respond(HttpMethod.Get, calendarPath, _ => Page(new
    {
        id = "dedicated",
        name = "Renamed in Outlook",
        isDefaultCalendar = false,
        isSharedWithMe = false,
        canEdit = true,
        singleValueExtendedProperties = new[] { new { id = calendarProperty, value = "1" } }
    }));
    Equal(binding, await Client(graph).CreateCalendarAsync(account));
    graph.Done();
});

await Run("An empty preview still verifies the bound target", async () =>
{
    var graph = new FakeGraph();
    graph.Respond(HttpMethod.Get, targetPath, _ => Json(new { id = "dedicated" }));
    await Fails(OutlookFailure.CalendarMissing, () => Client(graph).SyncAsync(binding, []));
    graph.Done();
});

await Run("A marked default calendar is rejected before listing its events", async () =>
{
    var graph = new FakeGraph();
    graph.Respond(HttpMethod.Get, targetPath, _ => Json(OwnedCalendar(isDefault: true)));
    await Fails(OutlookFailure.PermissionDenied, () => Client(graph).SyncAsync(binding, [allDay]));
    graph.Done();
});

await Run("Missing event marker with matching transaction ID blocks duplicate creation", async () =>
{
    var graph = new FakeGraph();
    Target(graph);
    graph.Respond(HttpMethod.Get, eventPath, _ => Page());
    string? transaction = null;
    graph.Respond(HttpMethod.Post, eventPath, request =>
    {
        transaction = request.Body.GetProperty("transactionId").GetString();
        return Json(new { id = "created" }, HttpStatusCode.Created);
    });
    Target(graph);
    graph.Respond(HttpMethod.Get, eventPath, _ => Page(new { id = "created", transactionId = transaction, subject = "Edited" }));
    var client = Client(graph);
    Equal(new CalendarSyncResult(1, 0, 0), await client.SyncAsync(binding, [allDay]));
    await Fails(OutlookFailure.ConflictingEvents, () => client.SyncAsync(binding, [allDay]));
    graph.Done();
});

await Run("Creates local midnight dates and exact timed instants without notifications", async () =>
{
    var graph = new FakeGraph();
    Target(graph);
    graph.Respond(HttpMethod.Get, eventPath, request =>
    {
        Check(request.Query.Contains("$expand=singleValueExtendedProperties", StringComparison.Ordinal));
        Check(!request.Query.Contains("startDateTime", StringComparison.Ordinal));
        Check(request.Prefer.Contains("China Standard Time", StringComparison.Ordinal));
        return Page(new { id = "unmanaged", subject = "Review" });
    });
    graph.Respond(HttpMethod.Post, eventPath, request =>
    {
        var body = request.Body;
        Equal("Review", body.GetProperty("subject").GetString());
        Equal("free", body.GetProperty("showAs").GetString());
        Equal(false, body.GetProperty("isReminderOn").GetBoolean());
        Equal(false, body.GetProperty("isOnlineMeeting").GetBoolean());
        Equal(0, body.GetProperty("attendees").GetArrayLength());
        Equal("Course details", body.GetProperty("body").GetProperty("content").GetString());
        Equal(true, body.GetProperty("isAllDay").GetBoolean());
        Date(body, "start", "2026-11-09T00:00:00", "China Standard Time");
        Date(body, "end", "2026-11-10T00:00:00", "China Standard Time");
        Equal(eventProperty, body.GetProperty("singleValueExtendedProperties")[0].GetProperty("id").GetString());
        Equal(Marker(allDay.Key), body.GetProperty("singleValueExtendedProperties")[0].GetProperty("value").GetString());
        Check(Guid.TryParse(body.GetProperty("transactionId").GetString(), out _));
        return Json(new { id = "created-a" }, HttpStatusCode.Created);
    });
    graph.Respond(HttpMethod.Post, eventPath, request =>
    {
        Equal(false, request.Body.GetProperty("isAllDay").GetBoolean());
        Date(request.Body, "start", "2026-11-09T23:20:00", "UTC");
        Date(request.Body, "end", "2026-11-09T23:21:00", "UTC");
        return Json(new { id = "created-b" }, HttpStatusCode.Created);
    });
    var notCreated = timed with { Key = "new-cancelled", Cancelled = true };
    Equal(new CalendarSyncResult(2, 0, 2), await Client(graph).SyncAsync(binding, [allDay, timed, yesterday, notCreated]));
    graph.Done();
});

await Run("Finds existing past events on later pages and preserves user notes", async () =>
{
    var graph = new FakeGraph();
    Target(graph);
    graph.Respond(HttpMethod.Get, eventPath, _ => NextPage("https://graph.microsoft.com" + eventPath + "?$skip=42",
        Event("other-source", "xzzd/other/task", "Old event", "2026-11-06T00:00:00", "2026-11-07T00:00:00")));
    graph.Respond(HttpMethod.Get, eventPath, request =>
    {
        Equal("?$skip=42", request.Query);
        return Page(Event("old-item", yesterday.Key, "Review", "2026-11-07T00:00:00", "2026-11-08T00:00:00"));
    });
    graph.Respond(HttpMethod.Patch, eventPath + "/old-item", request =>
    {
        Equal("[已取消] Review", request.Body.GetProperty("subject").GetString());
        Check(!request.Body.TryGetProperty("body", out _));
        Check(!request.Body.TryGetProperty("attendees", out _));
        Check(!request.Body.TryGetProperty("transactionId", out _));
        return Json(new { id = "old-item" });
    });
    Equal(new CalendarSyncResult(0, 1, 0), await Client(graph).SyncAsync(binding, [yesterday with { Cancelled = true }]));
    graph.Done();
});

await Run("Leaves unchanged events unchanged when Graph returns UTC times", async () =>
{
    var graph = new FakeGraph();
    Target(graph);
    graph.Respond(HttpMethod.Get, eventPath, _ => Page(Event("known", allDay.Key, "Review",
        "2026-11-08T16:00:00.0000000", "2026-11-09T16:00:00.0000000", "UTC")));
    Equal(new CalendarSyncResult(0, 0, 1), await Client(graph).SyncAsync(binding, [allDay]));
    graph.Done();
});

await Run("Another source's duplicate markers do not block this source's sync", async () =>
{
    var graph = new FakeGraph();
    Target(graph);
    graph.Respond(HttpMethod.Get, eventPath, _ => Page(
        Event("other-one", timed.Key, "Read", "2026-11-07T00:00:00", "2026-11-08T00:00:00"),
        Event("other-two", timed.Key, "Read", "2026-11-07T00:00:00", "2026-11-08T00:00:00")));
    graph.Respond(HttpMethod.Post, eventPath, _ => Json(new { id = "created" }, HttpStatusCode.Created));
    Equal(new CalendarSyncResult(1, 0, 0), await Client(graph).SyncAsync(binding, [allDay]));
    graph.Done();
});

await Run("Matching duplicate markers are ambiguous and stop writes", async () =>
{
    var graph = new FakeGraph();
    Target(graph);
    graph.Respond(HttpMethod.Get, eventPath, _ => Page(
        Event("one", allDay.Key, "Review", "2026-11-09T00:00:00", "2026-11-10T00:00:00"),
        Event("two", allDay.Key, "Review", "2026-11-09T00:00:00", "2026-11-10T00:00:00")));
    await Fails(OutlookFailure.ConflictingEvents, () => Client(graph).SyncAsync(binding, [allDay]));
    graph.Done();
});

await Run("Loss of a source deadline preserves the existing event", async () =>
{
    var graph = new FakeGraph();
    Target(graph);
    graph.Respond(HttpMethod.Get, eventPath, _ => Page(Event("known", allDay.Key, "Review",
        "2026-11-09T00:00:00", "2026-11-10T00:00:00")));
    var undated = allDay with { Title = "Renamed without a due date", AllDay = null };
    Equal(new CalendarSyncResult(0, 0, 1), await Client(graph).SyncAsync(binding, [undated]));
    graph.Done();
});

await Run("Fails closed on untrusted page URLs before doing any writes", async () =>
{
    foreach (var link in new[]
    {
        "https://graph.microsoft.com.evil.test" + eventPath,
        "https://graph.microsoft.com@evil.test" + eventPath,
        "http://graph.microsoft.com" + eventPath,
        "https://graph.microsoft.com:444" + eventPath,
        "https://graph.microsoft.com/v1.0/me/events?$skip=2",
        "https://graph.microsoft.com" + eventPath + "#fragment"
    })
    {
        var graph = new FakeGraph();
        Target(graph);
        graph.Respond(HttpMethod.Get, eventPath, _ => NextPage(link));
        await Fails(OutlookFailure.UnexpectedResponse, () => Client(graph).SyncAsync(binding, [allDay]));
        graph.Done();
    }
});

await Run("Repeated throttling is bounded and retry reuses the idempotency key", async () =>
{
    var graph = new FakeGraph();
    Target(graph);
    graph.Respond(HttpMethod.Get, eventPath, _ => Page());
    string? transaction = null;
    for (var i = 0; i < 3; i++)
    {
        graph.Respond(HttpMethod.Post, eventPath, request =>
        {
            var sent = request.Body.GetProperty("transactionId").GetString();
            transaction ??= sent;
            Equal(transaction, sent);
            var response = Json(new { detail = "redact token-one / homework" }, HttpStatusCode.TooManyRequests);
            response.Headers.RetryAfter = new RetryConditionHeaderValue(TimeSpan.Zero);
            return response;
        });
    }
    await Fails(OutlookFailure.Throttled, () => Client(graph).SyncAsync(binding, [allDay]));
    graph.Done();
});

await Run("An excessive Retry-After delay defers to a future sync", async () =>
{
    var graph = new FakeGraph();
    var clock = new FixedClock();
    Target(graph);
    graph.Respond(HttpMethod.Get, eventPath, _ =>
    {
        var response = Json(new { }, HttpStatusCode.TooManyRequests);
        response.Headers.RetryAfter = new RetryConditionHeaderValue(TimeSpan.FromMinutes(2));
        return response;
    });
    var client = Client(graph, clock: clock);
    await Fails(OutlookFailure.Throttled, () => client.SyncAsync(binding, [allDay]));
    await Fails(OutlookFailure.Throttled, () => client.SyncAsync(binding, [timed]));
    clock.Advance(TimeSpan.FromMinutes(2));
    Target(graph);
    Equal(new CalendarSyncResult(0, 0, 0), await client.SyncAsync(binding, []));
    graph.Done();
});

await Run("An expired token or missing target cannot trigger writes to another calendar", async () =>
{
    foreach (var (status, error) in new[]
    {
        (HttpStatusCode.Unauthorized, OutlookFailure.SignInRequired),
        (HttpStatusCode.Forbidden, OutlookFailure.PermissionDenied),
        (HttpStatusCode.NotFound, OutlookFailure.CalendarMissing)
    })
    {
        var graph = new FakeGraph();
        graph.Respond(HttpMethod.Get, targetPath, _ => Json(new { detail = "secret" }, status));
        await Fails(error, () => Client(graph).SyncAsync(binding, [allDay]));
        graph.Done();
    }
});

await Run("Finds accepted posts by marker after losing the response", async () =>
{
    var graph = new FakeGraph();
    Target(graph);
    graph.Respond(HttpMethod.Get, eventPath, _ => Page());
    graph.Respond(HttpMethod.Post, eventPath, _ => throw new HttpRequestException("secret"));
    graph.Respond(HttpMethod.Get, eventPath, _ => Page(Event("accepted", allDay.Key, "Review",
        "2026-11-09T00:00:00", "2026-11-10T00:00:00")));
    Equal(new CalendarSyncResult(1, 0, 0), await Client(graph).SyncAsync(binding, [allDay]));
    graph.Done();
});

await Run("A subsequent sync recovers partial success without duplicating the accepted event", async () =>
{
    var graph = new FakeGraph();
    Target(graph);
    graph.Respond(HttpMethod.Get, eventPath, _ => Page());
    graph.Respond(HttpMethod.Post, eventPath, _ => Json(new { id = "accepted" }, HttpStatusCode.Created));
    graph.Respond(HttpMethod.Post, eventPath, _ => Json(new { detail = "home-a / private" }, HttpStatusCode.ServiceUnavailable));
    var existing = Event("accepted", allDay.Key, "Review", "2026-11-09T00:00:00", "2026-11-10T00:00:00");
    graph.Respond(HttpMethod.Get, eventPath, _ => Page(existing));
    Target(graph);
    graph.Respond(HttpMethod.Get, eventPath, _ => Page(existing));
    graph.Respond(HttpMethod.Post, eventPath, request =>
    {
        Equal("Read", request.Body.GetProperty("subject").GetString());
        return Json(new { id = "second" }, HttpStatusCode.Created);
    });
    var client = Client(graph);
    await Fails(OutlookFailure.Unavailable, () => client.SyncAsync(binding, [allDay, timed]));
    Equal(new CalendarSyncResult(1, 0, 1), await client.SyncAsync(binding, [allDay, timed]));
    graph.Done();
});

await Run("An account switch cannot retarget a captured operation", async () =>
{
    var graph = new FakeGraph();
    var current = account;
    var accounts = new List<OutlookAccount>();
    var client = Client(graph, (captured, _) =>
    {
        accounts.Add(captured);
        return Task.FromResult(captured == account ? "token-one" : "token-two");
    });
    Target(graph);
    graph.Respond(HttpMethod.Get, eventPath, request =>
    {
        current = otherAccount;
        Equal("token-one", request.Token);
        return Page();
    });
    graph.Respond(HttpMethod.Post, eventPath, request =>
    {
        Equal("token-one", request.Token);
        return Json(new { id = "created" }, HttpStatusCode.Created);
    });
    Equal(new CalendarSyncResult(1, 0, 0), await client.SyncAsync(binding, [allDay]));
    Equal(otherAccount, current);
    Check(accounts.Count > 0 && accounts.All(value => value == account));
    graph.Done();
});

await Run("Pause after inventory prevents the subsequent write", async () =>
{
    var graph = new FakeGraph();
    using var pause = new CancellationTokenSource();
    Target(graph);
    graph.Respond(HttpMethod.Get, eventPath, _ =>
    {
        pause.Cancel();
        return Page();
    });
    try
    {
        await Client(graph).SyncAsync(binding, [allDay], pause.Token);
        throw new Exception("Expected cancellation");
    }
    catch (OperationCanceledException) when (pause.IsCancellationRequested) { }
    graph.Done();
});

await Run("Will not send an update to attendees added by the calendar owner", async () =>
{
    var graph = new FakeGraph();
    var eventWithAttendees = JsonSerializer.SerializeToNode(Event("edited", allDay.Key, "Review",
        "2026-11-09T00:00:00", "2026-11-10T00:00:00"))!;
    eventWithAttendees["attendees"] = JsonNode.Parse("""[{"emailAddress":{"address":"person@example.test"}}]""");
    Target(graph);
    graph.Respond(HttpMethod.Get, eventPath, _ => Page(eventWithAttendees));
    await Fails(OutlookFailure.ConflictingEvents,
        () => Client(graph).SyncAsync(binding, [allDay with { Cancelled = true }]));
    graph.Done();
});

Console.WriteLine("Outlook synthetic HTTP tests passed.");

OutlookCalendar Client(FakeGraph graph, Func<OutlookAccount, CancellationToken, Task<string>>? tokens = null,
    TimeProvider? clock = null)
    => new(new HttpClient(graph), tokens ?? ((bound, _) =>
    {
        Equal(account, bound);
        return Task.FromResult("token-one");
    }), clock ?? new FixedClock());

void Target(FakeGraph graph) => graph.Respond(HttpMethod.Get, targetPath, request =>
{
    Check(request.Query.Contains("$expand=singleValueExtendedProperties", StringComparison.Ordinal));
    return Json(OwnedCalendar());
});

object OwnedCalendar(bool isDefault = false) => new
{
    id = "dedicated",
    isDefaultCalendar = isDefault,
    isSharedWithMe = false,
    canEdit = true,
    singleValueExtendedProperties = new[] { new { id = calendarProperty, value = "1" } }
};

object Event(string id, string key, string subject, string start, string end, string zone = "China Standard Time") =>
    new
    {
        id,
        subject,
        isAllDay = true,
        showAs = "free",
        isReminderOn = false,
        isOnlineMeeting = false,
        attendees = Array.Empty<object>(),
        body = new { contentType = "text", content = "User notes" },
        start = new { dateTime = start, timeZone = zone },
        end = new { dateTime = end, timeZone = zone },
        singleValueExtendedProperties = new[] { new { id = eventProperty, value = Marker(key) } }
    };

static string Marker(string key) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key)));
static HttpResponseMessage Page(params object[] entries) => Json(new { value = entries });
static HttpResponseMessage NextPage(string link, params object[] entries) =>
    Json(new Dictionary<string, object> { ["@odata.nextLink"] = link, ["value"] = entries });
static HttpResponseMessage Json(object value, HttpStatusCode status = HttpStatusCode.OK) =>
    new(status) { Content = JsonContent.Create(value) };

static void Date(JsonElement eventBody, string field, string expected, string zone)
{
    var value = eventBody.GetProperty(field);
    Equal(expected, value.GetProperty("dateTime").GetString());
    Equal(zone, value.GetProperty("timeZone").GetString());
}

static async Task Fails(OutlookFailure expected, Func<Task> run)
{
    try { await run(); }
    catch (OutlookException error)
    {
        Equal(expected, error.Failure);
        Check(!error.Message.Contains("secret", StringComparison.Ordinal));
        Check(!error.Message.Contains("token-one", StringComparison.Ordinal));
        Check(!error.Message.Contains("home-a", StringComparison.Ordinal));
        Check(error.InnerException is null);
        return;
    }
    throw new Exception($"Expected {expected}.");
}

static void Equal<T>(T expected, T actual)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
        throw new Exception($"Expected {expected}, got {actual}.");
}

static void Check(bool condition)
{
    if (!condition) throw new Exception("Assertion failed.");
}

static async Task Run(string name, Func<Task> test)
{
    try { await test(); }
    catch (Exception error) { throw new Exception(name, error); }
    Console.WriteLine($"PASS {name}");
}

sealed class FixedClock : TimeProvider
{
    private DateTimeOffset now = new(2026, 11, 7, 17, 0, 0, TimeSpan.Zero);
    public override DateTimeOffset GetUtcNow() => now;
    public void Advance(TimeSpan time) => now += time;
}

sealed record GraphRequest(JsonElement Body, string? Token, string Query, string Prefer);

sealed class FakeGraph : HttpMessageHandler
{
    private readonly Queue<(HttpMethod Method, string Path, Func<GraphRequest, HttpResponseMessage> Reply)> replies = [];

    public void Respond(HttpMethod method, string path, Func<GraphRequest, HttpResponseMessage> reply)
        => replies.Enqueue((method, path, reply));

    public void Done()
    {
        if (replies.Count != 0) throw new Exception($"{replies.Count} expected Graph requests were missing.");
    }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var uri = request.RequestUri!;
        if (!replies.TryDequeue(out var expected) || request.Method != expected.Method || uri.AbsolutePath != expected.Path ||
            uri.Scheme != "https" || uri.Host != "graph.microsoft.com" || !uri.IsDefaultPort)
            throw new Exception($"Unexpected Graph request {request.Method} {uri}");

        JsonElement body = default;
        if (request.Content is not null)
        {
            using var document = JsonDocument.Parse(await request.Content.ReadAsStringAsync(cancellationToken));
            body = document.RootElement.Clone();
        }
        return expected.Reply(new GraphRequest(body, request.Headers.Authorization?.Parameter,
            Uri.UnescapeDataString(uri.Query),
            request.Headers.TryGetValues("Prefer", out var prefer) ? string.Join(", ", prefer) : ""));
    }
}
