namespace DueBridge.Outlook;

public sealed record OutlookAccount(string HomeAccountId, string Username);

public sealed record OutlookCalendarBinding(OutlookAccount Account, string CalendarId);

public enum OutlookFailure
{
    Configuration,
    SignInRequired,
    SignInFailed,
    Storage,
    PermissionDenied,
    CalendarMissing,
    Throttled,
    Unavailable,
    UnexpectedResponse,
    ConflictingEvents
}

public sealed class OutlookException(OutlookFailure failure) : Exception(failure switch
{
    OutlookFailure.Configuration => "此版本尚未配置 Outlook 登录。",
    OutlookFailure.SignInRequired => "请重新登录已绑定的个人 Microsoft 账号。",
    OutlookFailure.SignInFailed => "未能登录个人 Microsoft 账号。",
    OutlookFailure.Storage => "无法访问此 Windows 用户的 Outlook 登录缓存。",
    OutlookFailure.PermissionDenied => "Outlook 日历权限不足，请重新授权。",
    OutlookFailure.CalendarMissing => "找不到已绑定的 DueBridge 日历，请重新设置。",
    OutlookFailure.Throttled => "Outlook 请求过于频繁，请稍后重试。",
    OutlookFailure.Unavailable => "Outlook 暂时无法访问，请稍后重试。",
    OutlookFailure.ConflictingEvents => "DueBridge 日历有归期无法安全更新的重复项目或会议。",
    _ => "Outlook 返回了无法处理的响应。"
})
{
    public OutlookFailure Failure { get; } = failure;
}
