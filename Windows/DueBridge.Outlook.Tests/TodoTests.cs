using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using DueBridge.Core;
using DueBridge.Outlook;

internal static class TodoTests
{
    private const string Lists = "/v1.0/me/todo/lists";
    private const string Target = Lists + "/dedicated";
    private const string Tasks = Target + "/tasks";
    private const string ListProperty = "String {7ce84863-2e9c-4f3e-8de7-c4fa72916a44} Name DueBridgeTodoList";
    private const string TaskProperty = "String {7ce84863-2e9c-4f3e-8de7-c4fa72916a44} Name DueBridgeTodoEntry";
    private const string Start = "[归期管理区开始]";
    private const string End = "[归期管理区结束]";
    private static readonly OutlookAccount Account = new("home-a", "one@example.test");
    private static readonly TodoListBinding Binding = new(Account, "dedicated");
    private static readonly CalendarEntry Day = new("bb/source-one/course/task", "【数学】Review", "来源：课程作业", new DateOnly(2026, 11, 9), null);
    private static readonly CalendarEntry Timed = new("mo/source-two/course/task", "【物理】Read", "来源：课程阅读", null,
        new DateTimeOffset(2026, 11, 9, 18, 20, 0, TimeSpan.FromHours(-5)));

    public static async Task RunAsync()
    {
        await Run("Creates marked dedicated list without adopting personal same-name lists", async () =>
        {
            var graph = new Graph(); var journal = new Journal();
            graph.Add(HttpMethod.Get, Lists, _ => Page(new { id = "personal", displayName = "归期 · 课程 DDL" }));
            graph.Add(HttpMethod.Post, Lists, request =>
            {
                Check(journal.Pending.Count == 1);
                Check(journal.Pending.Keys.Single().StartsWith(TodoTasks.PendingPrefix(Account), StringComparison.Ordinal));
                Equal("归期 · 课程 DDL", Text(request.Body, "displayName"));
                Property(request.Body, ListProperty, "1");
                return Json(List(), HttpStatusCode.Created);
            });
            Equal(Binding, await Client(graph, journal).CreateListAsync(Account));
            Equal(0, journal.Pending.Count); graph.Done();
        });
        await Run("List inventory follows pagination and rejects duplicate owned markers", async () =>
        {
            var graph = new Graph(); var journal = new Journal();
            graph.Add(HttpMethod.Get, Lists, _ => Next(Lists, List()));
            graph.Add(HttpMethod.Get, Lists, _ => Page(List("second")));
            await Fails(TodoFailure.ConflictingTasks, () => Client(graph, journal).CreateListAsync(Account));
            Equal(0, journal.Pending.Count); graph.Done();
        });
        await Run("Lost list response is recovered from its marker", async () =>
        {
            var graph = new Graph(); var journal = new Journal();
            graph.Add(HttpMethod.Get, Lists, _ => Page());
            graph.Add(HttpMethod.Post, Lists, _ => throw new HttpRequestException("secret"));
            graph.Add(HttpMethod.Get, Lists, _ => Next(Lists));
            graph.Add(HttpMethod.Get, Lists, _ => Page(List()));
            Equal(Binding, await Client(graph, journal).CreateListAsync(Account));
            Equal(0, journal.Pending.Count); graph.Done();
        });
        await Run("Unconfirmed list creation persists across client restarts and blocks another POST", async () =>
        {
            var graph = new Graph(); var journal = new Journal();
            graph.Add(HttpMethod.Get, Lists, _ => Page());
            graph.Add(HttpMethod.Post, Lists, _ => new HttpResponseMessage(HttpStatusCode.Created) { Content = new StringContent("invalid") });
            graph.Add(HttpMethod.Get, Lists, _ => Page());
            await Fails(TodoFailure.PendingCreation, () => Client(graph, journal).CreateListAsync(Account));
            Equal(1, journal.Pending.Count);
            graph.Add(HttpMethod.Get, Lists, _ => Page());
            await Fails(TodoFailure.PendingCreation, () => Client(graph, journal).CreateListAsync(Account));
            graph.Add(HttpMethod.Get, Lists, _ => Page(List()));
            Equal(Binding, await Client(graph, journal).CreateListAsync(Account));
            Equal(0, journal.Pending.Count); graph.Done();
        });
        await Run("Creates task atomically with marker, day-only Beijing due date and no reminders", async () =>
        {
            var graph = new Graph(); var journal = new Journal(); Inventory(graph);
            graph.Add(HttpMethod.Get, Tasks, _ => Page());
            graph.Add(HttpMethod.Post, Tasks, request =>
            {
                Equal(1, journal.Pending.Count);
                Property(request.Body, TaskProperty, Hash(Day.Key));
                Equal("【数学】Review", Text(request.Body, "title"));
                Equal(false, request.Body.GetProperty("isReminderOn").GetBoolean());
                Date(request.Body, "2026-11-09T00:00:00");
                Check(Text(request.Body.GetProperty("body"), "content")!.Contains("2026-11-09 全天", StringComparison.Ordinal));
                return Json(new { id = "created" }, HttpStatusCode.Created);
            });
            Equal(new CalendarSyncResult(1, 0, 0), await Client(graph, journal).SyncAsync(Binding, [Day]));
            Equal(0, journal.Pending.Count); graph.Done();
        });
        await Run("Timed deadline converts to Beijing day and keeps precise time in body", async () =>
        {
            var graph = new Graph(); Inventory(graph); graph.Add(HttpMethod.Get, Tasks, _ => Page());
            graph.Add(HttpMethod.Post, Tasks, request =>
            {
                Date(request.Body, "2026-11-10T00:00:00");
                Check(Text(request.Body.GetProperty("body"), "content")!.Contains("2026-11-10 07:20", StringComparison.Ordinal));
                return Json(new { id = "timed" }, HttpStatusCode.Created);
            });
            await Client(graph).SyncAsync(Binding, [Timed]); graph.Done();
        });
        await Run("Full task pagination catches duplicate markers before any write", async () =>
        {
            var graph = new Graph(); Inventory(graph);
            graph.Add(HttpMethod.Get, Tasks, _ => Next(Tasks, TaskItem("one", Day)));
            graph.Add(HttpMethod.Get, Tasks, _ => Page(TaskItem("two", Day)));
            await Fails(TodoFailure.ConflictingTasks, () => Client(graph).SyncAsync(Binding, [Timed, Day])); graph.Done();
        });
        await Run("Reschedule replaces managed body block and preserves personal text and completed fields", async () =>
        {
            var graph = new Graph(); var changed = Day with { AllDay = new DateOnly(2026, 11, 12), Notes = "来源：更新后的作业入口" };
            var item = TaskItem("one", Day, $"Personal before\n{Start}\nold\n{End}\nPersonal after");
            Inventory(graph); graph.Add(HttpMethod.Get, Tasks, _ => Page(item));
            graph.Add(HttpMethod.Patch, Tasks + "/one", request =>
            {
                Equal("W/\"v1\"", request.IfMatch);
                foreach (var field in new[] { "status", "completedDateTime", "importance", "isReminderOn", "reminderDateTime", "checklistItems" })
                    Check(!request.Body.TryGetProperty(field, out _));
                var content = Text(request.Body.GetProperty("body"), "content")!;
                Check(content.StartsWith("Personal before\n", StringComparison.Ordinal));
                Check(content.EndsWith("\nPersonal after", StringComparison.Ordinal));
                Check(content.Contains("2026-11-12 全天", StringComparison.Ordinal));
                Check(content.Contains(changed.Notes, StringComparison.Ordinal));
                Check(!content.Contains("\nold\n", StringComparison.Ordinal));
                Date(request.Body, "2026-11-12T00:00:00");
                return Json(new { });
            });
            Equal(new CalendarSyncResult(0, 1, 0), await Client(graph).SyncAsync(Binding, [changed])); graph.Done();
        });
        await Run("Repeated sync is unchanged and vanished source items remain untouched", async () =>
        {
            var graph = new Graph(); Inventory(graph); graph.Add(HttpMethod.Get, Tasks, _ => Page(TaskItem("one", Day), TaskItem("old", Timed)));
            Equal(new CalendarSyncResult(0, 0, 1), await Client(graph).SyncAsync(Binding, [Day])); graph.Done();
        });
        await Run("New cancelled or past tasks are skipped but existing cancellations retain completion", async () =>
        {
            var graph = new Graph(); Inventory(graph); graph.Add(HttpMethod.Get, Tasks, _ => Page(TaskItem("one", Day)));
            graph.Add(HttpMethod.Patch, Tasks + "/one", request =>
            {
                Equal("[已取消] 【数学】Review", Text(request.Body, "title"));
                Check(!request.Body.TryGetProperty("status", out _)); return Json(new { });
            });
            Equal(new CalendarSyncResult(0, 1, 2), await Client(graph).SyncAsync(Binding,
                [Day with { Cancelled = true }, Timed with { Cancelled = true }, Day with { Key = "old", AllDay = new DateOnly(2026, 11, 7) }])); graph.Done();
        });
        await Run("Lost task response recovers once and clears durable pending guard", async () =>
        {
            var graph = new Graph(); var journal = new Journal(); Inventory(graph); graph.Add(HttpMethod.Get, Tasks, _ => Page());
            graph.Add(HttpMethod.Post, Tasks, _ => throw new HttpRequestException("secret"));
            graph.Add(HttpMethod.Get, Tasks, _ => Page(TaskItem("recovered", Day)));
            Equal(new CalendarSyncResult(1, 0, 0), await Client(graph, journal).SyncAsync(Binding, [Day]));
            Equal(0, journal.Pending.Count); graph.Done();
        });
        await Run("Absent ambiguous creation blocks all later writes until recovered after restart", async () =>
        {
            var graph = new Graph(); var journal = new Journal(); Inventory(graph); graph.Add(HttpMethod.Get, Tasks, _ => Page());
            graph.Add(HttpMethod.Post, Tasks, _ => Json(new { detail = "secret" }, HttpStatusCode.ServiceUnavailable));
            graph.Add(HttpMethod.Get, Tasks, _ => Page());
            await Fails(TodoFailure.PendingCreation, () => Client(graph, journal).SyncAsync(Binding, [Day])); Equal(1, journal.Pending.Count);
            Inventory(graph); graph.Add(HttpMethod.Get, Tasks, _ => Page());
            await Fails(TodoFailure.PendingCreation, () => Client(graph, journal).SyncAsync(Binding, [Timed, Day]));
            Inventory(graph); graph.Add(HttpMethod.Get, Tasks, _ => Page(TaskItem("one", Day)));
            Equal(new CalendarSyncResult(0, 0, 1), await Client(graph, journal).SyncAsync(Binding, [Day]));
            Equal(0, journal.Pending.Count); graph.Done();
        });
        await Run("Partial success retry recovers both markers without another POST", async () =>
        {
            var graph = new Graph(); var journal = new Journal(); Inventory(graph); graph.Add(HttpMethod.Get, Tasks, _ => Page());
            graph.Add(HttpMethod.Post, Tasks, _ => Json(new { id = "one" }, HttpStatusCode.Created));
            graph.Add(HttpMethod.Post, Tasks, _ => throw new HttpRequestException("secret"));
            graph.Add(HttpMethod.Get, Tasks, _ => Page(TaskItem("one", Day)));
            await Fails(TodoFailure.PendingCreation, () => Client(graph, journal).SyncAsync(Binding, [Day, Timed]));
            Inventory(graph); graph.Add(HttpMethod.Get, Tasks, _ => Page(TaskItem("one", Day), TaskItem("two", Timed)));
            Equal(new CalendarSyncResult(0, 0, 2), await Client(graph, journal).SyncAsync(Binding, [Day, Timed])); Equal(0, journal.Pending.Count); graph.Done();
        });
        await Run("Unmarked, shared, built-in and wrong owned lists never receive writes", async () =>
        {
            foreach (var mutation in new Action<JsonNode>[] {
                node => node["singleValueExtendedProperties"] = new JsonArray(), node => node["isOwner"] = false,
                node => node["isShared"] = true, node => node["wellknownListName"] = "defaultList", node => node["id"] = "other" })
            {
                var graph = new Graph(); var node = JsonSerializer.SerializeToNode(List())!; mutation(node);
                graph.Add(HttpMethod.Get, Lists, _ => Page(node));
                await Fails(TodoFailure.ListMissing, () => Client(graph).SyncAsync(Binding, [Day])); graph.Done();
            }
        });
        await Run("Duplicate input keys are rejected before any network call", async () =>
        {
            var graph = new Graph(); await Fails(TodoFailure.ConflictingTasks,
                () => Client(graph).SyncAsync(Binding, [Day, Day])); graph.Done();
        });
        await Run("Different source and Microsoft account guards do not inherit pending writes", async () =>
        {
            var graph = new Graph(); var journal = new Journal();
            var other = new OutlookAccount("home-b", "two@example.test");
            Check(TodoTasks.PendingPrefix(Account) != TodoTasks.PendingPrefix(other));
            Check(!TodoTasks.PendingPrefix(Account).Contains("home-a", StringComparison.Ordinal));
            Inventory(graph); graph.Add(HttpMethod.Get, Tasks, _ => Page(TaskItem("old-scope", Day)));
            graph.Add(HttpMethod.Post, Tasks, request =>
            {
                Property(request.Body, TaskProperty, Hash("bb/another-source/course/task"));
                Equal("token-one", request.Token); return Json(new { id = "new-scope" }, HttpStatusCode.Created);
            });
            await Client(graph, journal).SyncAsync(Binding, [Day with { Key = "bb/another-source/course/task" }]); graph.Done();
        });
        await Run("Auth and malformed inventories stop without leaking remote error details", async () =>
        {
            foreach (var pair in new[] { (HttpStatusCode.Unauthorized, TodoFailure.SignInRequired),
                (HttpStatusCode.Forbidden, TodoFailure.PermissionDenied), (HttpStatusCode.NotFound, TodoFailure.ListMissing),
                (HttpStatusCode.TooManyRequests, TodoFailure.Throttled), (HttpStatusCode.ServiceUnavailable, TodoFailure.Unavailable) })
            {
                var graph = new Graph(); graph.Add(HttpMethod.Get, Lists, _ => Json(new { detail = "secret token-one home-a" }, pair.Item1));
                await Fails(pair.Item2, () => Client(graph).SyncAsync(Binding, [Day])); graph.Done();
            }
            var bad = new Graph(); bad.Add(HttpMethod.Get, Lists, _ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("invalid") });
            await Fails(TodoFailure.UnexpectedResponse, () => Client(bad).SyncAsync(Binding, [Day])); bad.Done();
        });
        await Run("Rejected POST clears journal and throttling does not repeat a POST", async () =>
        {
            foreach (var pair in new[] { (HttpStatusCode.Forbidden, TodoFailure.PermissionDenied),
                (HttpStatusCode.TooManyRequests, TodoFailure.Throttled), (HttpStatusCode.Conflict, TodoFailure.ConflictingTasks) })
            {
                var graph = new Graph(); var journal = new Journal(); Inventory(graph); graph.Add(HttpMethod.Get, Tasks, _ => Page());
                graph.Add(HttpMethod.Post, Tasks, _ => Json(new { detail = "secret" }, pair.Item1));
                await Fails(pair.Item2, () => Client(graph, journal).SyncAsync(Binding, [Day])); Equal(0, journal.Pending.Count); graph.Done();
            }
        });
        await Run("Concurrent user edit stops on If-Match conflict", async () =>
        {
            var graph = new Graph(); Inventory(graph); graph.Add(HttpMethod.Get, Tasks, _ => Page(TaskItem("one", Day)));
            graph.Add(HttpMethod.Patch, Tasks + "/one", _ => Json(new { detail = "secret" }, HttpStatusCode.PreconditionFailed));
            await Fails(TodoFailure.ConflictingTasks, () => Client(graph).SyncAsync(Binding, [Day with { Title = "changed" }])); graph.Done();
        });
        await Run("Pause after inventory prevents creation and cancelled create keeps its journal", async () =>
        {
            var graph = new Graph(); using var pause = new CancellationTokenSource(); Inventory(graph);
            graph.Add(HttpMethod.Get, Tasks, _ => { pause.Cancel(); return Page(); });
            await Cancelled(() => Client(graph).SyncAsync(Binding, [Day], pause.Token)); graph.Done();
            var during = new Graph(); var journal = new Journal(); using var cancel = new CancellationTokenSource(); Inventory(during);
            during.Add(HttpMethod.Get, Tasks, _ => Page());
            during.Add(HttpMethod.Post, Tasks, _ => { cancel.Cancel(); throw new OperationCanceledException(cancel.Token); });
            await Cancelled(() => Client(during, journal).SyncAsync(Binding, [Day], cancel.Token)); Equal(1, journal.Pending.Count);
            Inventory(during); during.Add(HttpMethod.Get, Tasks, _ => Page());
            await Fails(TodoFailure.PendingCreation, () => Client(during, journal).SyncAsync(Binding, [Day])); during.Done();
        });
        await Run("Pagination cannot escape the selected To Do collection", async () =>
        {
            foreach (var next in new[] { "https://evil.test/steal", "https://graph.microsoft.com/v1.0/me/calendars", "https://graph.microsoft.com" + Tasks + "#fragment" })
            {
                var graph = new Graph(); Inventory(graph);
                graph.Add(HttpMethod.Get, Tasks, _ => Json(new Dictionary<string, object> { ["value"] = Array.Empty<object>(), ["@odata.nextLink"] = next }));
                await Fails(TodoFailure.UnexpectedResponse, () => Client(graph).SyncAsync(Binding, [Day])); graph.Done();
            }
        });
        await Run("Equivalent UTC due date is not rewritten", async () =>
        {
            var graph = new Graph(); Inventory(graph);
            var item = JsonSerializer.SerializeToNode(TaskItem("one", Day))!;
            item["dueDateTime"] = JsonSerializer.SerializeToNode(new {dateTime="2026-11-08T16:00:00",timeZone="UTC"});
            graph.Add(HttpMethod.Get, Tasks, _ => Page(item));
            Equal(new CalendarSyncResult(0,0,1), await Client(graph).SyncAsync(Binding,[Day])); graph.Done();
        });
        await Run("Precise deadline seconds survive the task details", async () =>
        {
            var graph = new Graph(); Inventory(graph); graph.Add(HttpMethod.Get, Tasks, _ => Page());
            graph.Add(HttpMethod.Post, Tasks, request =>
            {
                Check(Text(request.Body.GetProperty("body"),"content")!.Contains("2026-11-10 07:20:59",StringComparison.Ordinal));
                return Json(new {id="seconds"},HttpStatusCode.Created);
            });
            await Client(graph).SyncAsync(Binding,[Timed with {DueAt=Timed.DueAt!.Value.AddSeconds(59)}]); graph.Done();
        });
        Console.WriteLine("To Do synthetic HTTP tests passed.");
    }

    private static TodoTasks Client(Graph graph, Journal? journal = null) => new(new HttpClient(graph), (account, token) =>
    { Equal(Account, account); token.ThrowIfCancellationRequested(); return System.Threading.Tasks.Task.FromResult("token-one"); }, journal ?? new Journal(), new Clock());
    private static void Inventory(Graph graph) => graph.Add(HttpMethod.Get, Lists, _ => Page(List()));
    private static object List(string id = "dedicated") => new { id, displayName = "归期 · 课程 DDL", isOwner = true, isShared = false,
        wellknownListName = "none", singleValueExtendedProperties = new[] { new { id = ListProperty, value = "1" } } };
    private static object TaskItem(string id, CalendarEntry entry, string? body = null)
    {
        string deadline = entry.AllDay is { } day ? day.ToString("yyyy-MM-dd") + " 全天" : "2026-11-10 07:20:00";
        string due = entry.AllDay is { } date ? date.ToString("yyyy-MM-dd") + "T00:00:00" : "2026-11-10T00:00:00";
        return new Dictionary<string, object> { ["id"] = id, ["title"] = entry.Title,
            ["@odata.etag"] = "W/\"v1\"", ["status"] = "completed", ["importance"] = "high", ["isReminderOn"] = true,
            ["completedDateTime"] = new { dateTime = "2026-11-08T12:00:00", timeZone = "China Standard Time" },
            ["reminderDateTime"] = new { dateTime = "2026-11-08T11:00:00", timeZone = "China Standard Time" },
            ["checklistItems"] = new[] { new { id = "personal-subtask", displayName = "Personal", isChecked = true } },
            ["dueDateTime"] = new { dateTime = due, timeZone = "China Standard Time" },
            ["body"] = new { contentType = "text", content = body ?? $"{Start}\n截止（北京时间）：{deadline}\n{entry.Notes}\n{End}" },
            ["singleValueExtendedProperties"] = new[] { new { id = TaskProperty, value = Hash(entry.Key) } } };
    }
    private static string Hash(string key) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key)));
    private static HttpResponseMessage Json(object value, HttpStatusCode status = HttpStatusCode.OK) => new(status) { Content = JsonContent.Create(value) };
    private static HttpResponseMessage Page(params object[] values) => Json(new { value = values });
    private static HttpResponseMessage Next(string path, params object[] values) => Json(new Dictionary<string, object> { ["value"] = values, ["@odata.nextLink"] = "https://graph.microsoft.com" + path + "?$skip=100" });
    private static string? Text(JsonElement item, string name) => item.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    private static void Property(JsonElement item, string name, string value)
    { var property = item.GetProperty("singleValueExtendedProperties")[0]; Equal(name, Text(property, "id")); Equal(value, Text(property, "value")); }
    private static void Date(JsonElement item, string value)
    { Equal(value, Text(item.GetProperty("dueDateTime"), "dateTime")); Equal("China Standard Time", Text(item.GetProperty("dueDateTime"), "timeZone")); }
    private static async Task Fails(TodoFailure expected, Func<Task> action)
    {
        try { await action(); } catch (TodoException error)
        { Equal(expected, error.Failure); Check(error.InnerException is null); foreach (var secret in new[] { "secret", "token-one", "home-a" }) Check(!error.Message.Contains(secret, StringComparison.Ordinal)); return; }
        throw new Exception($"Expected {expected}.");
    }
    private static async Task Cancelled(Func<Task> action)
    { try { await action(); } catch (OperationCanceledException) { return; } throw new Exception("Expected cancellation."); }
    private static async Task Run(string name, Func<Task> action)
    { try { await action(); } catch (Exception error) { throw new Exception(name, error); } Console.WriteLine("PASS ToDo " + name); }
    private static void Check(bool condition) { if (!condition) throw new Exception("Assertion failed."); }
    private static void Equal<T>(T expected, T actual)
    { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new Exception($"Expected {expected}, got {actual}."); }
    private sealed class Clock : TimeProvider { public override DateTimeOffset GetUtcNow() => new(2026, 11, 7, 17, 0, 0, TimeSpan.Zero); }
    private sealed class Journal : ITodoWriteJournal
    {
        internal Dictionary<string, string> Pending { get; } = new(StringComparer.Ordinal);
        public bool IsPending(string operationKey) => Pending.ContainsKey(operationKey);
        public void Begin(string operationKey, string description) { Check(!Pending.ContainsKey(operationKey)); Pending.Add(operationKey, description); }
        public void Complete(string operationKey) => Pending.Remove(operationKey);
    }
    private sealed record Request(JsonElement Body, string? Token, string? IfMatch);
    private sealed class Graph : HttpMessageHandler
    {
        private readonly Queue<(HttpMethod Method, string Path, Func<Request, HttpResponseMessage> Reply)> replies = [];
        internal void Add(HttpMethod method, string path, Func<Request, HttpResponseMessage> reply) => replies.Enqueue((method, path, reply));
        internal void Done() => Equal(0, replies.Count);
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (!replies.TryDequeue(out var expected)) throw new Exception("Unexpected request " + request.Method + " " + request.RequestUri);
            Equal(expected.Method, request.Method); Equal(expected.Path, request.RequestUri!.AbsolutePath);
            Equal("https", request.RequestUri.Scheme); Equal("graph.microsoft.com", request.RequestUri.Host);
            JsonElement body = default;
            if (request.Content is not null) { using var doc = JsonDocument.Parse(await request.Content.ReadAsStringAsync(cancellationToken)); body = doc.RootElement.Clone(); }
            return expected.Reply(new(body, request.Headers.Authorization?.Parameter,
                request.Headers.TryGetValues("If-Match", out var values) ? string.Join(", ", values) : null));
        }
    }
}
