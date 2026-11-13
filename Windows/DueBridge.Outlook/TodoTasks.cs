using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using DueBridge.Core;

namespace DueBridge.Outlook;

public sealed class TodoTasks(HttpClient httpClient,
    Func<OutlookAccount, CancellationToken, Task<string>> getAccessToken,
    ITodoWriteJournal journal, TimeProvider? timeProvider = null)
{
    private const string Lists = "me/todo/lists";
    private const string ListProperty = "String {7ce84863-2e9c-4f3e-8de7-c4fa72916a44} Name DueBridgeTodoList";
    private const string EntryProperty = "String {7ce84863-2e9c-4f3e-8de7-c4fa72916a44} Name DueBridgeTodoEntry";
    private readonly SemaphoreSlim gate = new(1, 1);
    private static string Hash(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    public static string PendingPrefix(OutlookAccount account) => Hash(account.HomeAccountId) + "/";
    private static string Id(JsonElement item) => Text(item,"id") is { Length: > 0 } id ? id : throw Error();
    private static string? Text(JsonElement item,string key) => GraphTransport.Text(item,key);
    private static TodoException Error() => new(TodoFailure.UnexpectedResponse);
    private static string Marker(JsonElement item,string property)
    {
        if (!item.TryGetProperty("singleValueExtendedProperties",out var array)) return "";
        if(array.ValueKind!=JsonValueKind.Array) throw Error();
        var matches=array.EnumerateArray().Where(p=>Text(p,"id")==property).ToArray();
        if(matches.Length>1) throw new TodoException(TodoFailure.ConflictingTasks);
        return matches.Length==0 ? "" : Text(matches[0],"value") ?? throw Error();
    }
    private static bool Owned(JsonElement item) => item.TryGetProperty("isOwner",out var owner) && owner.ValueKind==JsonValueKind.True &&
        item.TryGetProperty("isShared",out var shared) && shared.ValueKind==JsonValueKind.False && Text(item,"wellknownListName")=="none";
    private static string Expand(string property) => "?$expand="+Uri.EscapeDataString("singleValueExtendedProperties($filter=id eq '"+property+"')");
    private async Task<string> Token(OutlookAccount account,CancellationToken ct)
    {
        try { var token=await getAccessToken(account,ct); return !string.IsNullOrWhiteSpace(token)?token:throw new TodoException(TodoFailure.SignInRequired); }
        catch(OutlookException e) { throw new TodoException(e.Failure switch { OutlookFailure.SignInRequired=>TodoFailure.SignInRequired,
            OutlookFailure.PermissionDenied=>TodoFailure.PermissionDenied,_=>TodoFailure.Unavailable }); }
    }
    private async Task<JsonElement> Send(HttpMethod method,string path,string token,object? body,CancellationToken ct,string? etag=null)
    {
        ct.ThrowIfCancellationRequested();
        using var timeout=CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        var io=timeout.Token;
        using var request=new HttpRequestMessage(method,new Uri(GraphTransport.Root,path));
        request.Headers.Authorization=new AuthenticationHeaderValue("Bearer",token);
        if(etag is not null) request.Headers.TryAddWithoutValidation("If-Match",etag);
        if(body is not null) request.Content=JsonContent.Create(body);
        try
        {
            using var response=await httpClient.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,io);
            if(!response.IsSuccessStatusCode) throw new TodoException(response.StatusCode switch {
                HttpStatusCode.Unauthorized=>TodoFailure.SignInRequired,HttpStatusCode.Forbidden=>TodoFailure.PermissionDenied,
                HttpStatusCode.NotFound or HttpStatusCode.Gone=>TodoFailure.ListMissing,HttpStatusCode.TooManyRequests=>TodoFailure.Throttled,
                HttpStatusCode.Conflict or HttpStatusCode.PreconditionFailed=>TodoFailure.ConflictingTasks,
                _ when (int)response.StatusCode>=500 || response.StatusCode==HttpStatusCode.RequestTimeout=>TodoFailure.Unavailable,
                _=>TodoFailure.UnexpectedResponse });
            if(method==HttpMethod.Patch) return default;
            if(response.Content.Headers.ContentLength>8*1024*1024) throw Error();
            await using var stream=await response.Content.ReadAsStreamAsync(io);
            using var data=new MemoryStream(); var buffer=new byte[16384]; int n;
            while((n=await stream.ReadAsync(buffer,io))>0) { if(data.Length+n>8*1024*1024) throw Error(); data.Write(buffer,0,n); }
            using var document=JsonDocument.Parse(data.ToArray());
            if(document.RootElement.ValueKind!=JsonValueKind.Object) throw Error();
            return document.RootElement.Clone();
        }
        catch(JsonException) { throw Error(); }
        catch(Exception e) when(e is HttpRequestException or IOException || e is OperationCanceledException && !ct.IsCancellationRequested)
        { throw new TodoException(TodoFailure.Unavailable); }
    }
    private async Task<List<JsonElement>> Inventory(string path,string token,CancellationToken ct)
    {
        int totalCharacters=0;
        var result=new List<JsonElement>(); var visited=new HashSet<string>(); string? page=path;
        for(int count=0;page is not null && count<200;count++)
        {
            if(!visited.Add(page)) throw Error();
            var item=await Send(HttpMethod.Get,page,token,null,ct);
            totalCharacters+=item.GetRawText().Length; if(totalCharacters>16*1024*1024) throw Error();
            if(!item.TryGetProperty("value",out var values)||values.ValueKind!=JsonValueKind.Array) throw Error();
            foreach(var value in values.EnumerateArray()) { if(value.ValueKind!=JsonValueKind.Object) throw Error(); result.Add(value.Clone()); }
            page=null;
            if(item.TryGetProperty("@odata.nextLink",out var next)&&next.ValueKind!=JsonValueKind.Null)
            {
                if(next.ValueKind!=JsonValueKind.String||!Uri.TryCreate(next.GetString(),UriKind.Absolute,out var uri)||
                    uri.Scheme!="https"||uri.Host!="graph.microsoft.com"||!uri.IsDefaultPort||uri.UserInfo!=""||uri.Fragment!=""||
                    uri.AbsolutePath!=new Uri(GraphTransport.Root,path).AbsolutePath) throw Error();
                page=uri.PathAndQuery["/v1.0/".Length..];
            }
        }
        if(page is not null) throw Error(); return result;
    }
    private async Task<string?> FindList(string token,CancellationToken ct)
    {
        var lists=await Inventory(Lists+Expand(ListProperty),token,ct);
        var owned=lists.Where(l=>Marker(l,ListProperty)=="1"&&Owned(l)).Select(Id).Distinct().ToArray();
        if(owned.Length>1) throw new TodoException(TodoFailure.ConflictingTasks);
        return owned.FirstOrDefault();
    }
    public async Task<TodoListBinding> CreateListAsync(OutlookAccount account,CancellationToken cancellationToken=default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            var token=await Token(account,cancellationToken); var key=PendingPrefix(account)+"list";
            var found=await FindList(token,cancellationToken);
            if(found is not null) { journal.Complete(key); return new(account,found); }
            if(journal.IsPending(key)) throw new TodoException(TodoFailure.PendingCreation);
            journal.Begin(key,"创建归期 · 课程 DDL 列表");
            try
            {
                var created=await Send(HttpMethod.Post,Lists,token,new { displayName="归期 · 课程 DDL",
                    singleValueExtendedProperties=new[]{new {id=ListProperty,value="1"}} },cancellationToken);
                var id=Id(created); journal.Complete(key); return new(account,id);
            }
            catch(TodoException e)
            {
                if(Rejected(e)) { journal.Complete(key); throw; }
                found=await FindList(token,cancellationToken);
                if(found is null) throw new TodoException(TodoFailure.PendingCreation);
                journal.Complete(key); return new(account,found);
            }
        }
        finally { gate.Release(); }
    }
    private static bool Rejected(TodoException e) => e.Failure is TodoFailure.PermissionDenied or TodoFailure.SignInRequired or
        TodoFailure.Throttled or TodoFailure.ConflictingTasks or TodoFailure.ListMissing;
    private async Task<Dictionary<string,JsonElement>> FindTasks(string path,string token,HashSet<string> wanted,CancellationToken ct)
    {
        var found=new Dictionary<string,JsonElement>();
        foreach(var item in await Inventory(path+Expand(EntryProperty),token,ct))
        {
            var marker=Marker(item,EntryProperty); if(!wanted.Contains(marker)) continue;
            if(found.TryGetValue(marker,out var previous)&&Id(previous)!=Id(item)) throw new TodoException(TodoFailure.ConflictingTasks);
            found[marker]=item;
        }
        return found;
    }
    public async Task<CalendarSyncResult> SyncAsync(TodoListBinding binding,IReadOnlyList<CalendarEntry> entries,CancellationToken cancellationToken=default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            var wanted=new HashSet<string>(); foreach(var entry in entries)
                if(string.IsNullOrWhiteSpace(entry.Key)||!wanted.Add(Hash(entry.Key))) throw new TodoException(TodoFailure.ConflictingTasks);
            var token=await Token(binding.Account,cancellationToken);
            if(await FindList(token,cancellationToken)!=binding.ListId) throw new TodoException(TodoFailure.ListMissing);
            var path=Lists+"/"+Uri.EscapeDataString(binding.ListId)+"/tasks";
            var existing=await FindTasks(path,token,wanted,cancellationToken);
            string Key(string marker)=>PendingPrefix(binding.Account)+Hash(binding.ListId)+"/"+marker;
            foreach(var marker in existing.Keys) journal.Complete(Key(marker));
            // Preflight every wanted pending operation before making any new writes.
            foreach(var marker in wanted) if(journal.IsPending(Key(marker))) throw new TodoException(TodoFailure.PendingCreation);
            int added=0,updated=0,unchanged=0;
            foreach(var entry in entries)
            {
                cancellationToken.ThrowIfCancellationRequested(); var marker=Hash(entry.Key); var key=Key(marker);
                var projection=new TodoTaskProjection(entry);
                if(existing.TryGetValue(marker,out var item))
                {
                    var fields=projection.Update(item);
                    if(fields.Count==0) { unchanged++; continue; }
                    await Send(HttpMethod.Patch,path+"/"+Uri.EscapeDataString(Id(item)),token,fields,cancellationToken,Text(item,"@odata.etag"));
                    updated++; continue;
                }
                if(entry.Cancelled||DeadlinePresentation.IsBeforeToday(entry,(timeProvider??TimeProvider.System).GetUtcNow())) { unchanged++;continue; }
                journal.Begin(key,entry.Title);
                try
                {
                    var payload=projection.Create(); payload["singleValueExtendedProperties"]=new[]{new{id=EntryProperty,value=marker}};
                    Id(await Send(HttpMethod.Post,path,token,payload,cancellationToken)); journal.Complete(key); added++;
                }
                catch(TodoException e)
                {
                    if(Rejected(e)) { journal.Complete(key);throw; }
                    existing=await FindTasks(path,token,wanted,cancellationToken);
                    if(!existing.ContainsKey(marker)) throw new TodoException(TodoFailure.PendingCreation);
                    journal.Complete(key);added++;
                }
            }
            return new(added,updated,unchanged);
        }
        finally { gate.Release(); }
    }
}
