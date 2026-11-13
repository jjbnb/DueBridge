using System.Globalization;
using System.Text.Json;
using DueBridge.Core;
namespace DueBridge.Outlook;
internal sealed class TodoTaskProjection(CalendarEntry entry)
{
    private const string Start="[归期管理区开始]", End="[归期管理区结束]";
    private string Title => (entry.Cancelled?"[已取消] ":"")+entry.Title;
    private DateOnly? Day => entry.AllDay ?? (entry.DueAt is {} at ? DeadlinePresentation.ShanghaiDate(at):null);
    private string Block => Start+"\n截止（北京时间）："+(entry.DueAt is {} instant
        ? TimeZoneInfo.ConvertTime(instant,TimeZoneInfo.FindSystemTimeZoneById("China Standard Time")).ToString("yyyy-MM-dd HH:mm:ss",CultureInfo.InvariantCulture)
        : DeadlinePresentation.FormatDeadline(entry))+"\n"+entry.Notes+"\n"+End;
    private object Due => new {dateTime=Day!.Value.ToString("yyyy-MM-dd",CultureInfo.InvariantCulture)+"T00:00:00",timeZone="China Standard Time"};
    internal Dictionary<string,object> Create()
    {
        if(Day is null) throw new TodoException(TodoFailure.UnexpectedResponse);
        return new(){["title"]=Title,["dueDateTime"]=Due,["body"]=new {contentType="text",content=Block},["isReminderOn"]=false};
    }
    internal Dictionary<string,object> Update(JsonElement item)
    {
        var fields=new Dictionary<string,object>();
        if(GraphTransport.Text(item,"title")!=Title) fields["title"]=Title;
        if(Day is {} day)
        {
            bool matches=false;
            if(item.TryGetProperty("dueDateTime",out var due)&&due.ValueKind==JsonValueKind.Object)
            {
                var text=GraphTransport.Text(due,"dateTime");
                if(DateTime.TryParse(text,CultureInfo.InvariantCulture,DateTimeStyles.None,out var date) &&
                    GraphTransport.Text(due,"timeZone") is {} zoneName && TimeZoneInfo.TryFindSystemTimeZoneById(zoneName,out var zone))
                {
                    var local=DateTime.SpecifyKind(date,DateTimeKind.Unspecified);
                    matches=DeadlinePresentation.ShanghaiDate(new DateTimeOffset(local,zone.GetUtcOffset(local)))==day;
                }
            }
            if(!matches) fields["dueDateTime"]=Due;
            if(!item.TryGetProperty("body",out var body)||body.ValueKind!=JsonValueKind.Object ||
                !string.Equals(GraphTransport.Text(body,"contentType"),"text",StringComparison.OrdinalIgnoreCase))
                throw new TodoException(TodoFailure.ConflictingTasks);
            var old=GraphTransport.Text(body,"content")??"";
            var start=old.IndexOf(Start,StringComparison.Ordinal);var end=old.IndexOf(End,StringComparison.Ordinal);
            string next;
            if(start<0 && end<0) next=old+(old.Length==0?"":"\n\n")+Block;
            else
            {
                if(start<0||end<start||old.IndexOf(Start,start+Start.Length,StringComparison.Ordinal)>=0||
                    old.IndexOf(End,end+End.Length,StringComparison.Ordinal)>=0) throw new TodoException(TodoFailure.ConflictingTasks);
                next=old[..start]+Block+old[(end+End.Length)..];
            }
            if(next!=old)
            {
                if(GraphTransport.Text(item,"@odata.etag") is null) throw new TodoException(TodoFailure.ConflictingTasks);
                fields["body"]=new {contentType="text",content=next};
            }
        }
        return fields;
    }
}
