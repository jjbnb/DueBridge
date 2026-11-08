using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using DueBridge.Core;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace DueBridge.School;

/// <summary>A school-origin browser profile plus a bounded, read-only collector.</summary>
public sealed class SchoolSource
{
    private static readonly Lazy<string> Script = new(() =>
    {
        using var stream = typeof(SchoolSource).Assembly.GetManifestResourceStream("DueBridge.School.SchoolBridge.js")
            ?? throw new InvalidOperationException("Missing school bridge resource.");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    });
    private readonly SchoolPolicy policy;
    private readonly string profileDirectory;
    private readonly SemaphoreSlim gate = new(1, 1);
    private CoreWebView2Environment? environment;

    public SchoolSource(SchoolPlatform platform, string dataDirectory)
    {
        policy = SchoolPolicy.For(platform);
        profileDirectory = Path.Combine(dataDirectory, "SchoolProfiles", policy.Id);
    }

    public async Task LoginAsync(CancellationToken token)
    {
        await gate.WaitAsync(token);
        try
        {
            using var browser = new BrowserWindow(policy, interactive: true);
            using var operation = CancellationTokenSource.CreateLinkedTokenSource(token, browser.ClosedToken);
            try
            {
                await InitializeAsync(browser, operation.Token);
                browser.Core.Navigate(policy.Login);
                await browser.ClosedTask.WaitAsync(token);
                if (!browser.Confirmed) throw new SchoolConnectionException("已关闭学校登录窗口。");
            }
            catch (OperationCanceledException) when (!token.IsCancellationRequested && browser.ClosedToken.IsCancellationRequested)
            {
                throw new SchoolConnectionException("已关闭学校登录窗口。");
            }
        }
        finally { gate.Release(); }
    }

    public Task<SourcePreview> PreviewAsync(CancellationToken token) =>
        ReadInProfileAsync(TimeSpan.FromMinutes(2), async (browser, context, ct) =>
        {
            string account = await IdentityAsync(browser, context, ct);
            var fingerprint = Fingerprint(account);
            var snapshot = await SchoolCatalog.CollectAsync(policy, fingerprint, (request, readToken) =>
                EvaluateAsync(browser, context, request, account, readToken), ct);
            if (await IdentityAsync(browser, context, ct) != account) throw AccountChanged();
            return snapshot;
        }, token);

    public async Task VerifyAccountAsync(string expectedAccountId, CancellationToken token)
    {
        await ReadInProfileAsync(TimeSpan.FromSeconds(45), async (browser, context, ct) =>
        {
            if (Fingerprint(await IdentityAsync(browser, context, ct)) != expectedAccountId) throw AccountChanged();
            return true;
        }, token);
    }

    private async Task<T> ReadInProfileAsync<T>(TimeSpan limit,
        Func<BrowserWindow, int, CancellationToken, Task<T>> read, CancellationToken token)
    {
        await gate.WaitAsync(token);
        try
        {
            using var browser = new BrowserWindow(policy, interactive: false);
            using var operation = CancellationTokenSource.CreateLinkedTokenSource(token, browser.ClosedToken);
            operation.CancelAfter(limit);
            try
            {
                await InitializeAsync(browser, operation.Token);
                await browser.NavigateForReadAsync(operation.Token);
                int context = await CreateContextAsync(browser, operation.Token);
                return await read(browser, context, operation.Token);
            }
            catch (OperationCanceledException) when (!token.IsCancellationRequested)
            {
                throw new SchoolConnectionException("读取学校任务超时，请检查连接后重试。", retryable: true);
            }
            catch (Exception error) when (error is JsonException or KeyNotFoundException or InvalidOperationException or COMException)
            {
                throw new SchoolConnectionException("学校网页会话已中断，请重新连接后重试。", retryable: true);
            }
        }
        finally { gate.Release(); }
    }

    private async Task InitializeAsync(BrowserWindow browser, CancellationToken token)
    {
        try
        {
            environment ??= await CoreWebView2Environment.CreateAsync(userDataFolder: profileDirectory).WaitAsync(token);
            await browser.InitializeAsync(environment, token);
        }
        catch (WebView2RuntimeNotFoundException)
        {
            throw new SchoolConnectionException("未找到 Microsoft Edge WebView2 运行时，请安装后重新打开归期。");
        }
        catch (Exception error) when (error is COMException or InvalidOperationException or UnauthorizedAccessException or IOException)
        {
            throw new SchoolConnectionException("无法打开本机学校登录会话，请关闭其他归期窗口后重试。");
        }
    }

    private static async Task<int> CreateContextAsync(BrowserWindow browser, CancellationToken token)
    {
        using var tree = await CallAsync(browser, "Page.getFrameTree", new { }, token);
        var frame = tree.RootElement.GetProperty("frameTree").GetProperty("frame");
        if (!browser.IsReadPage(frame.GetProperty("url").GetString()))
            throw new SchoolConnectionException("学校页面位置无法验证，本次未读取。");
        string? frameId = frame.GetProperty("id").GetString();
        if (string.IsNullOrEmpty(frameId)) throw new SchoolConnectionException("学校页面尚未加载完成。", true);
        using var world = await CallAsync(browser, "Page.createIsolatedWorld",
            new { frameId, worldName = "DueBridgeSchool" }, token);
        return world.RootElement.GetProperty("executionContextId").GetInt32();
    }

    private async Task<string> IdentityAsync(BrowserWindow browser, int context, CancellationToken token)
    {
        var id = await EvaluateAsync(browser, context, null, null, token);
        return SchoolPolicy.ValidId(id) ? id : throw new SchoolConnectionException("学校会话已过期，请重新登录。");
    }

    private async Task<string> EvaluateAsync(BrowserWindow browser, int context, SchoolRequest? request, string? expected, CancellationToken token)
    {
        if (!browser.IsReadPage(browser.Core.Source))
            throw new SchoolConnectionException("学校页面已改变，本次未读取。");
        string args = JsonSerializer.Serialize(new { platform = policy.Id, path = request?.Path, body = request?.Body, expected });
        using var response = await CallAsync(browser, "Runtime.evaluate",
            new { expression = "(" + Script.Value + ")(" + args + ")", contextId = context, awaitPromise = true, returnByValue = true }, token);
        if (response.RootElement.TryGetProperty("exceptionDetails", out _))
            throw new SchoolConnectionException("无法读取学校页面，请重新连接。");
        var result = response.RootElement.GetProperty("result").GetProperty("value");
        if (result.TryGetProperty("error", out var error))
        {
            throw error.GetString() switch
            {
                "login" => new SchoolConnectionException("学校会话已过期或尚未完成，请重新登录。"),
                "account" => AccountChanged(),
                "network" or "timeout" => new SchoolConnectionException("连接学校平台失败或超时，请检查网络后重试。", true),
                _ => new SchoolConnectionException("学校平台返回的数据无法校验，本次未同步。")
            };
        }
        return result.GetProperty("value").GetString() ?? throw new SchoolConnectionException("学校平台返回了无效内容。");
    }

    private static async Task<JsonDocument> CallAsync(BrowserWindow browser, string command, object args, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var raw = await browser.Core.CallDevToolsProtocolMethodAsync(command, JsonSerializer.Serialize(args)).WaitAsync(token);
        return JsonDocument.Parse(raw);
    }

    private string Fingerprint(string account) => SchoolPolicy.HashFields("bb-ddl/native-account", "1", policy.Id, policy.Host, account);
    private static SchoolConnectionException AccountChanged() => new("学校账号已变化，请重新连接并核对预览。");

    private sealed class BrowserWindow : IDisposable
    {
        private readonly SchoolPolicy policy;
        private readonly bool interactive;
        private readonly WebView2 view = new();
        private readonly Window window;
        private readonly TextBlock location = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10) };
        private readonly TaskCompletionSource closed = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly CancellationTokenSource closedSource = new();

        public bool Confirmed { get; private set; }
        public CoreWebView2 Core => view.CoreWebView2 ?? throw new InvalidOperationException("Browser not initialized.");
        public Task ClosedTask => closed.Task;
        public CancellationToken ClosedToken => closedSource.Token;

        public BrowserWindow(SchoolPolicy policy, bool interactive)
        {
            this.policy = policy;
            this.interactive = interactive;
            var panel = new DockPanel();
            if (interactive)
            {
                var toolbar = new DockPanel();
                var finish = new Button { Content = "登录完成，返回归期", Margin = new Thickness(8), Padding = new Thickness(10, 5, 10, 5) };
                DockPanel.SetDock(finish, Dock.Right);
                finish.Click += (_, _) => { Confirmed = true; window!.Close(); };
                toolbar.Children.Add(finish);
                location.Text = "请在学校页面完成登录。";
                toolbar.Children.Add(location);
                DockPanel.SetDock(toolbar, Dock.Top);
                panel.Children.Add(toolbar);
            }
            panel.Children.Add(view);
            window = new Window
            {
                Title = policy.Label + " · 学校登录",
                Width = interactive ? 1000 : 420, Height = interactive ? 740 : 320,
                ShowInTaskbar = interactive, ShowActivated = interactive, Opacity = interactive ? 1 : 0,
                WindowStartupLocation = WindowStartupLocation.CenterScreen, Content = panel
            };
            window.Closed += (_, _) =>
            {
                closed.TrySetResult();
                closedSource.Cancel();
            };
        }

        public async Task InitializeAsync(CoreWebView2Environment environment, CancellationToken token)
        {
            window.Show();
            await view.EnsureCoreWebView2Async(environment).WaitAsync(token);
            Core.Settings.AreDevToolsEnabled = false;
            Core.Settings.AreDefaultContextMenusEnabled = false;
            Core.Settings.AreHostObjectsAllowed = false;
            Core.Settings.IsWebMessageEnabled = false;
            Core.PermissionRequested += (_, args) => args.State = CoreWebView2PermissionState.Deny;
            Core.BasicAuthenticationRequested += (_, args) => args.Cancel = true;
            Core.ServerCertificateErrorDetected += (_, args) => args.Action = CoreWebView2ServerCertificateErrorAction.Cancel;
            Core.DownloadStarting += (_, args) => args.Cancel = true;
            Core.NewWindowRequested += (_, args) =>
            {
                args.Handled = true;
                if (interactive && args.IsUserInitiated && policy.AllowsNavigation(args.Uri, true)) Core.Navigate(args.Uri);
            };
            Core.FrameNavigationStarting += (_, args) => args.Cancel = !interactive || !policy.AllowsNavigation(args.Uri, true);
            // NavigationStarting can arrive after the engine starts a GET.
            // Intercept all document requests before relying on navigation cancellation.
            Core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.Document,
                CoreWebView2WebResourceRequestSourceKinds.All);
            Core.WebResourceRequested += (_, args) =>
            {
                var address = args.Request.Uri;
                if (interactive ? policy.AllowsNavigation(address, true) : IsReadPage(address)) return;
                Uri? upgraded = interactive && policy.IsCallbackCandidate(address)
                    ? policy.TryUpgradeCallback(address, args.Request.Method, args.Request.Content is not null) : null;
                args.Response = upgraded is null
                    ? environment.CreateWebResourceResponse(Stream.Null, 403, "Blocked", "Cache-Control: no-store")
                    : environment.CreateWebResourceResponse(Stream.Null, 307, "Temporary Redirect",
                        "Cache-Control: no-store\r\nLocation: " + upgraded.AbsoluteUri);
            };
            Core.NavigationStarting += (_, args) =>
            {
                if (interactive)
                {
                    args.Cancel = !policy.AllowsNavigation(args.Uri, true) && !policy.IsCallbackCandidate(args.Uri);
                    if (args.Cancel) location.Text = "页面跳转不在学校登录范围内。";
                }
                else args.Cancel = !IsReadPage(args.Uri);
            };
            if (interactive)
                Core.NavigationCompleted += (_, args) =>
                {
                    if (args.IsSuccess && Uri.TryCreate(Core.Source, UriKind.Absolute, out var page))
                        location.Text = "当前页面 · " + page.IdnHost;
                    else if (args.WebErrorStatus != CoreWebView2WebErrorStatus.OperationCanceled)
                        location.Text = "学校页面未能加载。请检查校园网或代理设置。";
                };
        }

        public bool IsReadPage(string? url) => string.Equals(url, policy.Background, StringComparison.Ordinal);

        public async Task NavigateForReadAsync(CancellationToken token)
        {
            var result = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            void Completed(object? sender, CoreWebView2NavigationCompletedEventArgs args)
            {
                if (IsReadPage(Core.Source)) result.TrySetResult(args.IsSuccess);
            }
            Core.NavigationCompleted += Completed;
            try
            {
                Core.Navigate(policy.Background);
                if (!await result.Task.WaitAsync(TimeSpan.FromSeconds(25), token))
                    throw new SchoolConnectionException("学校平台暂时无法访问，请检查网络。", retryable: true);
            }
            catch (TimeoutException)
            {
                throw new SchoolConnectionException("学校页面加载超时，请检查连接后重试。", retryable: true);
            }
            finally { Core.NavigationCompleted -= Completed; }
        }

        public void Dispose()
        {
            if (!ClosedTask.IsCompleted) window.Close();
            view.Dispose();
            closedSource.Dispose();
        }
    }
}
