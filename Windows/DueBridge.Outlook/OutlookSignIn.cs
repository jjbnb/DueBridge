using System.Diagnostics;
using System.Security.Cryptography;
using Microsoft.Identity.Client;
using Microsoft.Identity.Client.Extensions.Msal;

namespace DueBridge.Outlook;

public enum MicrosoftPermission { Calendar, Tasks }

public static class MicrosoftPermissionPolicy
{
    public static string Scope(MicrosoftPermission permission) => permission switch
    {
        MicrosoftPermission.Calendar => "https://graph.microsoft.com/Calendars.ReadWrite",
        MicrosoftPermission.Tasks => "https://graph.microsoft.com/Tasks.ReadWrite",
        _ => throw new ArgumentOutOfRangeException(nameof(permission))
    };

    public static void AssertGranted(MicrosoftPermission permission, IEnumerable<string> granted)
    {
        var qualified = Scope(permission);
        var shortScope = qualified["https://graph.microsoft.com/".Length..];
        if (!granted.Any(scope => scope.Equals(qualified, StringComparison.OrdinalIgnoreCase) ||
            scope.Equals(shortScope, StringComparison.OrdinalIgnoreCase)))
            throw new OutlookException(OutlookFailure.PermissionDenied);
    }
}

public sealed class OutlookSignIn(string clientId, string cachePath, MicrosoftPermission permission = MicrosoftPermission.Calendar)
{
    private const string ConsumersAuthority = "https://login.microsoftonline.com/consumers";
    private const string ConsumersTenant = "9188040d-6c67-4c5b-b112-36a304b66dad";
    private readonly string[] scopes = [MicrosoftPermissionPolicy.Scope(permission)];

    private readonly SemaphoreSlim gate = new(1, 1);
    private IPublicClientApplication? application;

    public Task<OutlookAccount> ConnectAsync(CancellationToken cancellationToken = default)
        => ConnectCoreAsync(null, cancellationToken);

    public Task<OutlookAccount> ConnectAsync(OutlookAccount expectedAccount, CancellationToken cancellationToken = default)
        => ConnectCoreAsync(expectedAccount, cancellationToken);

    private Task<OutlookAccount> ConnectCoreAsync(OutlookAccount? expected, CancellationToken cancellationToken)
        => WithApplicationAsync(async app =>
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromMinutes(5));
            var request = app.AcquireTokenInteractive(scopes)
                .WithUseEmbeddedWebView(false)
                .WithPrompt(Prompt.SelectAccount)
                .WithSystemWebViewOptions(new SystemWebViewOptions
                {
                    HtmlMessageSuccess = "<p>Microsoft 账号已验证。请关闭此页面并返回 DueBridge。</p>",
                    HtmlMessageError = "<p>Microsoft 账号登录未完成。请关闭此页面并返回 DueBridge。</p>"
                });
            if (!string.IsNullOrWhiteSpace(expected?.Username))
                request = request.WithLoginHint(expected.Username);
            var result = await request.ExecuteAsync(timeout.Token).ConfigureAwait(false);
            var signedIn = result.Account;
            if (signedIn?.HomeAccountId?.Identifier is not { Length: > 0 } identifier)
                throw new OutlookException(OutlookFailure.SignInFailed);

            if (expected is not null && !string.Equals(identifier, expected.HomeAccountId, StringComparison.Ordinal))
            {
                // Keep the cache: this account may still be bound to the other optional destination.
                throw new OutlookException(OutlookFailure.SignInRequired);
            }

            ValidateResult(result);
            return new OutlookAccount(identifier, signedIn.Username ?? "");
        }, OutlookFailure.SignInFailed, cancellationToken);

    public Task<string> GetAccessTokenAsync(OutlookAccount account, CancellationToken cancellationToken = default)
        => WithApplicationAsync(async app =>
        {
            var cached = await app.GetAccountAsync(account.HomeAccountId).ConfigureAwait(false);
            if (!string.Equals(cached?.HomeAccountId?.Identifier, account.HomeAccountId, StringComparison.Ordinal) ||
                cached is null)
                throw new OutlookException(OutlookFailure.SignInRequired);
            cancellationToken.ThrowIfCancellationRequested();
            var result = await app.AcquireTokenSilent(scopes, cached).ExecuteAsync(cancellationToken).ConfigureAwait(false);
            if (!string.Equals(result.Account?.HomeAccountId?.Identifier, account.HomeAccountId, StringComparison.Ordinal))
                throw new OutlookException(OutlookFailure.SignInRequired);
            ValidateResult(result);
            return result.AccessToken;
        }, OutlookFailure.Unavailable, cancellationToken);

    public Task DisconnectAsync(OutlookAccount account)
        => WithApplicationAsync(async app =>
        {
            var cached = await app.GetAccountAsync(account.HomeAccountId).ConfigureAwait(false);
            if (cached is not null)
                await app.RemoveAsync(cached).ConfigureAwait(false);
            return true;
        }, OutlookFailure.Storage, CancellationToken.None);

    private void ValidateResult(AuthenticationResult result)
    {
        if (!string.Equals(result.TenantId, ConsumersTenant, StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(result.AccessToken))
            throw new OutlookException(OutlookFailure.SignInFailed);
        MicrosoftPermissionPolicy.AssertGranted(permission, result.Scopes);
    }

    private async Task<T> WithApplicationAsync<T>(Func<IPublicClientApplication, Task<T>> action,
        OutlookFailure defaultFailure, CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            application ??= await CreateApplicationAsync().ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            return await action(application).ConfigureAwait(false);
        }
        catch (MsalUiRequiredException) { throw new OutlookException(OutlookFailure.SignInRequired); }
        catch (Exception error) when (error is MsalCachePersistenceException or IOException or UnauthorizedAccessException or CryptographicException)
        { throw new OutlookException(OutlookFailure.Storage); }
        catch (Exception error) when (error is MsalException or HttpRequestException or TimeoutException)
        { throw new OutlookException(defaultFailure); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { throw new OutlookException(defaultFailure); }
        finally { gate.Release(); }
    }

    private async Task<IPublicClientApplication> CreateApplicationAsync()
    {
        if (!OperatingSystem.IsWindows() || !Guid.TryParse(clientId, out var parsed) || parsed == Guid.Empty)
            throw new OutlookException(OutlookFailure.Configuration);

        var app = PublicClientApplicationBuilder.Create(parsed.ToString())
            .WithAuthority(ConsumersAuthority)
            .WithRedirectUri("http://localhost")
            .Build();

        // The Windows storage accessor uses DPAPI for the current user. Never enable the unprotected fallback.
        string fullPath;
        try { fullPath = Path.GetFullPath(cachePath); }
        catch (ArgumentException) { throw new OutlookException(OutlookFailure.Storage); }
        var name = Path.GetFileName(fullPath);
        var directory = Path.GetDirectoryName(fullPath);
        if (string.IsNullOrEmpty(name) || directory is null)
            throw new OutlookException(OutlookFailure.Storage);
        var storage = new StorageCreationPropertiesBuilder(name, directory).Build();
        var cache = await MsalCacheHelper.CreateAsync(storage, new TraceSource("DueBridge.Outlook", SourceLevels.Off))
            .ConfigureAwait(false);
        cache.VerifyPersistence();
        cache.RegisterCache(app.UserTokenCache);
        return app;
    }
}
