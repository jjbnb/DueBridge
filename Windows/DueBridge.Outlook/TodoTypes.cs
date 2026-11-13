namespace DueBridge.Outlook;

public sealed record TodoListBinding(OutlookAccount Account, string ListId);

public interface ITodoWriteJournal
{
    bool IsPending(string operationKey);
    void Begin(string operationKey, string description);
    void Complete(string operationKey);
}

public enum TodoFailure
{
    SignInRequired,
    PermissionDenied,
    ListMissing,
    Throttled,
    Unavailable,
    UnexpectedResponse,
    ConflictingTasks,
    PendingCreation
}

public sealed class TodoException(TodoFailure failure) : Exception(failure switch
{
    TodoFailure.SignInRequired => "请重新登录已绑定的个人 Microsoft 账号。",
    TodoFailure.PermissionDenied => "Microsoft To Do 权限不足，请重新授权。",
    TodoFailure.ListMissing => "找不到已绑定的归期 To Do 列表，请重新设置。",
    TodoFailure.Throttled => "Microsoft To Do 请求过于频繁，请稍后重试。",
    TodoFailure.Unavailable => "Microsoft To Do 暂时无法访问，请稍后重试。",
    TodoFailure.ConflictingTasks => "归期 To Do 列表有无法安全更新的重复项目。",
    TodoFailure.PendingCreation => "上次创建结果尚未确认，请先在 To Do 核对并处理待确认记录。",
    _ => "Microsoft To Do 返回了无法处理的响应。"
})
{
    public TodoFailure Failure { get; } = failure;
}
