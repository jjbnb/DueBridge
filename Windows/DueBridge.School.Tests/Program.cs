using DueBridge.School;
using DueBridge.Core;

static void Check(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}

var mo = SchoolPolicy.For(SchoolPlatform.Mo);
var learning = SchoolPolicy.For(SchoolPlatform.LearningInZju);
var legacy = "http://mo.zju.edu.cn/user/login?state=abc%2Bdef";
Check(mo.TryUpgradeCallback(legacy, "GET", false)?.AbsoluteUri ==
    "https://mo.zju.edu.cn/user/login?state=abc%2Bdef", "exact MO GET is upgraded without changing query");
Check(mo.TryUpgradeCallback(legacy, "POST", false) is null &&
      mo.TryUpgradeCallback(legacy, "GET", true) is null &&
      mo.TryUpgradeCallback("http://mo.zju.edu.cn:80/user/login", "GET", false) is null,
    "unsafe callback cannot be replayed");
Check(!mo.AllowsNavigation("https://mo.zju.edu.cn.evil.example/", true) &&
      !mo.AllowsNavigation("https://zjuam.zju.edu.cn/", false) &&
      mo.AllowsNavigation("https://zjuam.zju.edu.cn/", true), "interactive origin rules");

const string moSection = """
    {"response":{"info":{"_id":9007199254740993,"name_cn":"合成课程"},
    "homework_sections":[{"units":[{"_id":"a","zh_name":"定时作业","end_time":"2026-11-16 15:59:00"}]},
    {"units":[{"_id":"b","zh_name":"无截止作业","end_time":null}]}],
    "paper_sections":[{"_id":"a","name_cn":"练习","question_paper":{"end_time":"2026-11-18T22:00:00+08:00"}}]}}
    """;
Task<string> ReadMo(SchoolRequest request, CancellationToken _)
{
    if (request.Path.StartsWith("/pyapi/course/section/", StringComparison.Ordinal))
    {
        Check(request.Path.Contains("/9007199254740993?", StringComparison.Ordinal), "opaque number is exact");
        return Task.FromResult(moSection);
    }
    return Task.FromResult(request.Path.Contains("learning_status=learning", StringComparison.Ordinal)
        ? """{"objects":[{"_id":9007199254740993,"name_cn":"合成课程"}],"count":1}"""
        : """{"objects":[],"count":0}""");
}
var mp = await SchoolCatalog.CollectAsync(mo, "account-a", ReadMo, default);
Check(mp.Entries.Count == 2 && DeadlinePresentation.ForCalendar(mp.Entries[0], mp.Entries[0].CourseLabel).Title ==
    "【合成课程】定时作业 · 截止", "MO published dated tasks");
Check(mp.Entries[0].DueAt == DateTimeOffset.Parse("2026-11-16T15:59:00Z"), "MO naive time uses UTC");
Check(mp.Entries[0].Key != mp.Entries[1].Key, "same ID in different kinds does not collide");
var renamed = await SchoolCatalog.CollectAsync(mo, "account-a", async (r, c) =>
    (await ReadMo(r, c)).Replace("定时作业", "改名作业").Replace("2026-11-16 15:59:00", "2026-11-17 15:59:00"), default);
Check(mp.Entries[0].Key == renamed.Entries[0].Key, "title and due edits leave identity stable");
var different = await SchoolCatalog.CollectAsync(mo, "account-b", ReadMo, default);
Check(mp.Entries[0].Key != different.Entries[0].Key, "different account is isolated");

Task<string> ReadLearning(SchoolRequest request, CancellationToken _) => Task.FromResult(
    request.Path == "/api/my-courses"
    ? """{"courses":[{"id":"c","name":"合成课程"}],"page":1,"page_size":100,"pages":1,"total":1}"""
    : request.Path.EndsWith("/exams", StringComparison.Ordinal)
        ? """{"exams":[{"id":"a","title":"考试","end_time":"2026-11-16 23:59:00","published":true}]}"""
        : """{"homework_activities":[{"id":"a","title":"隐藏作业","end_time":"2026-11-16 23:59:00","published":false}]}""");
var xp = await SchoolCatalog.CollectAsync(learning, "account-a", ReadLearning, default);
Check(xp.Entries.Count == 1 && xp.Entries[0].DueAt == mp.Entries[0].DueAt, "learning portal uses Shanghai and skips unpublished tasks");
try
{
    await SchoolCatalog.CollectAsync(learning, "account-a", async (r, c) =>
        (await ReadLearning(r, c)).Replace("\"total\":1", "\"total\":2"), default);
    throw new InvalidOperationException("incomplete data was accepted");
}
catch (SchoolConnectionException) { }
Console.WriteLine("PASS: Windows school adapters (synthetic authenticated data and navigation policy)");
