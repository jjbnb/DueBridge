using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Security;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using DueBridge.Core;
using DueBridge.Outlook;
using DueBridge.School;
using Microsoft.Win32;

namespace DueBridge.Windows;

public partial class MainWindow : Window
{
    private static readonly SourceKind[] Sources = Enum.GetValues<SourceKind>();
    private readonly SettingsStore _store = new();
    private readonly HttpClient _bbHttp = BlackboardFeed.CreateHttpClient();
    private readonly HttpClient _outlookHttp = OutlookCalendar.CreateHttpClient();
    private readonly HttpClient _todoHttp = OutlookCalendar.CreateHttpClient();
    private readonly OutlookSignIn _todoSignIn;
    private readonly TodoTasks _todo;
    private readonly Dictionary<SourceKind, DailySyncSchedule> _todoSchedule = Sources.ToDictionary(kind => kind, _ => new DailySyncSchedule());
    private bool _todoNeedsLogin, _todoListMissing;
    private readonly BlackboardFeed _blackboard;
    private readonly OutlookSignIn _signIn;
    private readonly OutlookCalendar _outlook;
    private readonly Dictionary<SourceKind, SchoolSource> _school;
    private readonly SyncOperation _operation = new();
    private readonly WorkspaceRefresh _refresh;
    private readonly Dictionary<SourceKind, SourcePreview> _previews = [];
    private readonly Dictionary<SourceKind, DailySyncSchedule> _schedule = Sources.ToDictionary(kind => kind, _ => new DailySyncSchedule());
    private readonly Dictionary<SourceKind, DailySyncSchedule> _readSchedule = Sources.ToDictionary(kind => kind, _ => new DailySyncSchedule());
    private readonly Dictionary<SourceKind, string> _sourceMessages = [];
    private readonly HashSet<SourceKind> _needsSchoolLogin = [];
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMinutes(1) };
    private LocalSettings _settings = LocalSettings.Empty;
    private SourceKind CurrentSource => (SourcePicker.SelectedItem as SourceOption)?.Kind ?? SourceKind.Blackboard;
    private bool _busy;
    private bool _changing;
    private bool _storageAvailable = true;
    private bool _outlookNeedsLogin;
    private bool _calendarMissing;
    private bool _exiting;
    private bool _allowClose;

    public MainWindow()
    {
        InitializeComponent();
        _blackboard = new BlackboardFeed(_bbHttp);
        _signIn = new OutlookSignIn(SettingsStore.OutlookClientId(), Path.Combine(_store.DataDirectory, "outlook.msalcache"));
        _outlook = new OutlookCalendar(_outlookHttp, _signIn.GetAccessTokenAsync);
        _school = new Dictionary<SourceKind, SchoolSource>
        {
            [SourceKind.Mo] = new(SchoolPlatform.Mo, _store.DataDirectory),
            [SourceKind.LearningInZju] = new(SchoolPlatform.LearningInZju, _store.DataDirectory)
        };

        try { _settings = _store.Load(); }
        catch (Exception ex) when (IsStorageError(ex))
        {
            _storageAvailable = false;
            Status.Text = "无法读取归期的本地设置。请检查当前 Windows 用户和数据目录。";
        }

        _todoSignIn = new OutlookSignIn(SettingsStore.OutlookClientId(), Path.Combine(_store.DataDirectory, "todo.msalcache"), MicrosoftPermission.Tasks);
        var journal = new SettingsTodoJournal(() => Dispatcher.Invoke(() => _settings), transform => Dispatcher.Invoke(() =>
        {
            Save(transform(_settings)); return _settings;
        }));
        _todo = new TodoTasks(_todoHttp, _todoSignIn.GetAccessTokenAsync, journal);
        _refresh = new WorkspaceRefresh(() => _settings, Save,
            (source, address, expected, token) => RetryAsync(cancellation => ReadSourceAsync(source, address, expected, cancellation), token),
            (target, entries, token) => RetryAsync(cancellation => _outlook.SyncAsync(target, entries, cancellation), token),
            () => DateTimeOffset.UtcNow, (target, entries, token) =>
            {
                if (!_storageAvailable) throw new LocalStorageException();
                return _todo.SyncAsync(target, entries, token);
            });
        foreach (var source in Sources)
            if (_settings.Source(source) is { Snapshot: { } snapshot } binding && snapshot.AccountId == binding.AccountId)
                _previews[source] = new(snapshot.AccountId, snapshot.Entries);

        SourcePicker.ItemsSource = Sources.Select(kind => new SourceOption(kind, Label(kind))).ToArray();
        SourcePicker.DisplayMemberPath = nameof(SourceOption.Name);
        SourcePicker.SelectedIndex = 0;
        try { StartAtLoginBox.IsChecked = StartAtLogin.IsEnabled(); }
        catch (Exception ex) when (IsStorageError(ex)) { StartAtLoginBox.IsEnabled = false; }

        Loaded += async (_, _) =>
        {
            SystemEvents.PowerModeChanged += OnPowerModeChanged;
            NetworkChange.NetworkAvailabilityChanged += OnNetworkAvailabilityChanged;
            SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
            if (_settings.Card.Visible) ShowDesktopCard();
            _timer.Start();
            await SynchronizeAsync(automatic: true);
        };
        _timer.Tick += async (_, _) =>
        {
            UpdateCountdowns();
            await SynchronizeAsync(automatic: true);
        };
        RenderControls();
    }

    private sealed record SourceOption(SourceKind Kind, string Name);

    private static string Label(SourceKind source) => source switch
    {
        SourceKind.Blackboard => "Blackboard（BB）",
        SourceKind.Mo => "智海 MO",
        _ => "学在浙大"
    };

    private static bool IsStorageError(Exception ex) =>
        ex is IOException or UnauthorizedAccessException or CryptographicException or JsonException or SecurityException;

    private void Save(LocalSettings updated)
    {
        try { _store.Save(updated); }
        catch (Exception ex) when (IsStorageError(ex))
        {
            _storageAvailable = false;
            throw new LocalStorageException();
        }
        _settings = updated;
    }

    private sealed class LocalStorageException : Exception
    {
        internal LocalStorageException() : base("无法保存归期设置。已停止同步，请检查本地数据目录后重新打开。") { }
    }

    private void OnSourceChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender != SourcePicker || SourcePicker.SelectedItem is null)
            return;
        BlackboardAddress.Clear();
        RenderPreview();
        RenderControls();
    }

    private async void OnPreview(object sender, RoutedEventArgs e)
    {
        var source = CurrentSource;
        var address = BlackboardAddress.Password.Trim();
        if (source == SourceKind.Blackboard && address.Length == 0)
            address = _settings.BlackboardAddress ?? "";

        await RunAsync($"正在读取 {Label(source)}…", async token =>
        {
            try
            {
                var preview = await ReadSourceAsync(source, address, expected: null, token);
                AcceptPreview(source, preview, address, token);
            }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                RecordReadFailure(source, error);
                throw;
            }
        });
    }

    private async void OnSchoolLogin(object sender, RoutedEventArgs e)
    {
        var source = CurrentSource;
        if (!_school.TryGetValue(source, out var school))
            return;
        await ChangeAsync($"请在学校登录窗口中完成 {Label(source)} 登录。", async token =>
        {
            try
            {
                await school.LoginAsync(token);
                var preview = await school.PreviewAsync(token);
                AcceptPreview(source, preview, null, token);
            }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                RecordReadFailure(source, error);
                throw;
            }
        });
    }

    private void OnOpenBlackboard(object sender, RoutedEventArgs e)
    {
        try
        {
            using var browser = Process.Start(new ProcessStartInfo(BlackboardFeed.SignInPage.AbsoluteUri)
            {
                UseShellExecute = true
            });
        }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException)
        {
            Status.Text = "无法打开默认浏览器，请在浏览器访问 " + BlackboardFeed.SignInPage.AbsoluteUri;
        }
    }

    private async Task<SourcePreview> ReadSourceAsync(SourceKind source, string? address, string? expected,
        CancellationToken token)
    {
        if (source == SourceKind.Blackboard)
            return await _blackboard.PreviewAsync(address ?? "", token);

        var school = _school[source];
        if (expected is not null)
            await school.VerifyAccountAsync(expected, token);
        return await school.PreviewAsync(token);
    }

    private void AcceptPreview(SourceKind source, SourcePreview preview, string? address, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var previous = _settings.Source(source);
        bool changed = !string.Equals(previous.AccountId, preview.AccountId, StringComparison.Ordinal);
        Save(_settings.AcceptPreview(source, preview, address, DateTimeOffset.UtcNow));
        _needsSchoolLogin.Remove(source);
        _schedule[source].Reset();
        _readSchedule[source].Reset();
        _previews[source] = preview;
        if (source == SourceKind.Blackboard)
            BlackboardAddress.Clear();
        _sourceMessages[source] = changed && previous.AccountId is not null
            ? "来源绑定已更新，请确认预览后重新启用同步。"
            : $"已读取 {preview.Entries.Count} 项。";
        Status.Text = _sourceMessages[source];
        RenderPreview();
    }

    private async void OnOutlookLogin(object sender, RoutedEventArgs e)
        => await ConnectOutlookAsync(_settings.OutlookAccount);

    private async void OnSwitchOutlook(object sender, RoutedEventArgs e)
        => await ConnectOutlookAsync(expected: null);

    private async Task ConnectOutlookAsync(OutlookAccount? expected)
    {
        await ChangeAsync("请在浏览器中完成个人 Outlook 授权。", async token =>
        {
            var old = _settings.OutlookAccount;
            var account = expected is null ? await _signIn.ConnectAsync(token) : await _signIn.ConnectAsync(expected, token);
            token.ThrowIfCancellationRequested();
            if (old?.HomeAccountId == account.HomeAccountId)
            {
                Save(_settings with
                {
                    OutlookAccount = account,
                    OutlookCalendar = _settings.OutlookCalendar is { } binding ? binding with { Account = account } : null
                });
            }
            else
            {
                Save(_settings.ClearSyncConsent() with { OutlookAccount = account, OutlookCalendar = null });
                _calendarMissing = false;
            }
            _outlookNeedsLogin = false;
            ResetSchedule();
            Status.Text = _settings.OutlookCalendar is null ? "Outlook 已授权。下一步设置 DueBridge 日历。" : "Outlook 授权已恢复。";
        });
    }

    private async void OnCreateCalendar(object sender, RoutedEventArgs e)
    {
        if (_settings.OutlookAccount is not { } account)
            return;
        await ChangeAsync("正在设置 DueBridge 日历…", async token =>
        {
            var binding = await _outlook.CreateCalendarAsync(account, token);
            token.ThrowIfCancellationRequested();
            Save(_settings.ClearSyncConsent() with { OutlookCalendar = binding });
            _calendarMissing = false;
            ResetSchedule();
            Status.Text = "DueBridge 日历已设置。请选择来源并启用同步。";
        });
    }

    private async void OnChangeSourceConsent(object sender, RoutedEventArgs e)
    {
        var source = CurrentSource;
        var binding = _settings.Source(source);
        if (!binding.Enabled && !CanEnableSource(source))
            return;

        await ChangeAsync("正在保存同步设置…", token =>
        {
            token.ThrowIfCancellationRequested();
            var current = _settings.Source(source);
            Save(_settings.WithSource(source, current with { Enabled = !binding.Enabled }));
            _schedule[source].Reset();
            _sourceMessages[source] = binding.Enabled ? "已停用此来源的 Outlook 同步。" : "已启用此来源的 Outlook 同步。";
            Status.Text = _sourceMessages[source];
            return Task.CompletedTask;
        });
        if (!binding.Enabled && _settings.Source(source).Enabled)
            await SynchronizeAsync(automatic: false, only: source);
    }

    private async void OnTogglePause(object sender, RoutedEventArgs e)
    {
        await ChangeAsync("正在更新同步设置…", token =>
        {
            token.ThrowIfCancellationRequested();
            var paused = !_settings.Paused;
            Save(_settings with { Paused = paused });
            if (!paused)
                ResetSchedule();
            Status.Text = paused ? "已暂停自动读取和 Outlook 写入，桌面卡片保留已有任务。" : "已恢复所选来源的自动读取和同步。";
            return Task.CompletedTask;
        });
        if (!_settings.Paused)
            await SynchronizeAsync(automatic: true);
    }

    private async void OnSyncNow(object sender, RoutedEventArgs e) => await SynchronizeAsync(automatic: false);

    private async Task SynchronizeAsync(bool automatic, SourceKind? only = null, bool localOnly = false)
    {
        if (_changing || _busy || _exiting || !_storageAvailable)
            return;

        var now = DateTimeOffset.UtcNow;
        var inputs = Sources.Where(source => only is null || source == only).Select(source =>
        {
            var binding = _settings.Source(source);
            var intent = RefreshIntent.For(binding, _settings.Paused,
                !_needsSchoolLogin.Contains(source), CanWrite,
                !automatic || _readSchedule[source].CanAttempt(binding.LastRead, now),
                !automatic || _schedule[source].CanAttempt(binding.LastSuccess, now), localOnly, CanWriteTodo,
                !automatic || _todoSchedule[source].CanAttempt(binding.LastTodoSuccess, now));
            return (Source: source, Intent: intent);
        }).Where(item => item.Intent.Read).ToArray();
        if (inputs.Length == 0)
            return;

        await RunAsync(localOnly ? "正在刷新桌面任务…" : "正在更新已启用的来源…", async token =>
        {
            var summaries = new List<string>();
            foreach (var (source, intent) in inputs)
            {
                token.ThrowIfCancellationRequested();
                try
                {
                    var outcome = await _refresh.RunScheduledAsync(source, intent, _readSchedule[source], _schedule[source], token, _todoSchedule[source]);
                    _previews[source] = outcome.Preview;
                    _needsSchoolLogin.Remove(source);
                    var messages = new List<string> { $"本地已更新 {outcome.Preview.Entries.Count} 项" };
                    if (outcome.WriteError is {} calendarError)
                    {
                        ObserveFailure(calendarError, source);
                        if (IsRetryable(calendarError)) _schedule[source].MarkTransientFailure();
                        messages.Add("Outlook：" + UserMessage(calendarError));
                    }
                    else if (outcome.Written is {} result) messages.Add($"Outlook 新增 {result.Added}，更新 {result.Updated}");
                    if (outcome.TodoError is {} todoError)
                    {
                        ObserveFailure(todoError, source);
                        if (IsRetryable(todoError)) _todoSchedule[source].MarkTransientFailure();
                        messages.Add("To Do：" + UserMessage(todoError));
                    }
                    else if (outcome.TodoWritten is {} todoResult) messages.Add($"To Do 新增 {todoResult.Added}，更新 {todoResult.Updated}");
                    _sourceMessages[source] = string.Join("；", messages);

                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    RecordReadFailure(source, ex);
                    if (IsRetryable(ex))
                    {
                        _readSchedule[source].MarkTransientFailure();
                        if (intent.Write) _schedule[source].MarkTransientFailure();
                        if (intent.WriteTodo) _todoSchedule[source].MarkTransientFailure();
                    }
                    _sourceMessages[source] = UserMessage(ex);
                }
                summaries.Add($"{Label(source)}　{_sourceMessages[source]}");
                RenderPreview();
            }
            Status.Text = string.Join("\n", summaries);
        });
    }

    private void RecordReadFailure(SourceKind source, Exception error)
    {
        ObserveFailure(error, source);
        if (_storageAvailable)
            Save(_settings.WithSource(source, _settings.Source(source) with { ReadError = UserMessage(error) }));
        RenderDesktopCard();
    }

    private static async Task<T> RetryAsync<T>(Func<CancellationToken, Task<T>> action, CancellationToken token)
    {
        TimeSpan[] backoff = [TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(8)];
        for (int i = 0; ; i++)
        {
            token.ThrowIfCancellationRequested();
            try { return await action(token); }
            catch (Exception ex) when (i < backoff.Length && IsRetryable(ex) &&
                ex is not OutlookException { Failure: OutlookFailure.Throttled })
            {
                await Task.Delay(backoff[i], token);
            }
        }
    }

    private static bool IsRetryable(Exception error) => error switch
    {
        TodoException todo => todo.Failure is TodoFailure.Unavailable or TodoFailure.Throttled,
        BlackboardException bb => bb.Retryable,
        SchoolConnectionException school => school.Retryable,
        OutlookException outlook => outlook.Failure is OutlookFailure.Throttled or OutlookFailure.Unavailable,
        _ => false
    };

    private bool CanWrite => _storageAvailable && !_settings.Paused && !_outlookNeedsLogin && !_calendarMissing &&
        _settings.OutlookCalendar is not null;

    private bool CanSyncSource(SourceKind source)
    {
        var binding = _settings.Source(source);
        return binding.Enabled && !string.IsNullOrEmpty(binding.AccountId) && !_needsSchoolLogin.Contains(source);
    }

    private bool CanEnableSource(SourceKind source)
    {
        var binding = _settings.Source(source);
        return _settings.OutlookCalendar is not null && !_outlookNeedsLogin && !_calendarMissing &&
            !_needsSchoolLogin.Contains(source) &&
            _previews.TryGetValue(source, out var preview) && binding.AccountId == preview.AccountId;
    }

    private void ObserveFailure(Exception ex, SourceKind? source = null)
    {
        if (ex is TodoException todo)
        {
            if (todo.Failure is TodoFailure.SignInRequired or TodoFailure.PermissionDenied) _todoNeedsLogin = true;
            if (todo.Failure == TodoFailure.ListMissing) _todoListMissing = true;
        }
        if (ex is OutlookException outlook)
        {
            if (outlook.Failure is OutlookFailure.SignInRequired or OutlookFailure.PermissionDenied)
                _outlookNeedsLogin = true;
            if (outlook.Failure == OutlookFailure.CalendarMissing)
                _calendarMissing = true;
        }
        if (source is { } kind && ex is SchoolConnectionException { Retryable: false } or SourceAccountChangedException)
            _needsSchoolLogin.Add(kind);
    }

    private static string UserMessage(Exception ex) =>
        ex is TodoException or TodoSetupException or BlackboardException or SchoolConnectionException or OutlookException or LocalStorageException or SourceAccountChangedException or WorkspaceBindingChangedException
            ? ex.Message : "操作未完成，请稍后重试。";

    private async Task RunAsync(string status, Func<CancellationToken, Task> action)
    {
        if (_changing || _busy || _exiting || !_storageAvailable)
            return;
        await _operation.TryRunAsync(async token =>
        {
            _busy = true;
            Status.Text = status;
            RenderControls();
            try { await action(token); }
            catch (Exception ex) when (ex is not OperationCanceledException || !token.IsCancellationRequested)
            {
                ObserveFailure(ex);
                Status.Text = UserMessage(ex);
            }
            finally
            {
                _busy = false;
                RenderPreview();
                RenderControls();
            }
        });
    }

    private async Task ChangeAsync(string status, Func<CancellationToken, Task> action)
    {
        if (_changing || _exiting || !_storageAvailable)
            return;
        _changing = true;
        RenderControls();
        try { await _operation.CancelAndDrainAsync(); }
        catch (Exception ex) { Status.Text = UserMessage(ex); }
        finally { _changing = false; }
        await RunAsync(status, action);
    }

    private void OnStartAtLogin(object sender, RoutedEventArgs e)
    {
        bool requested = StartAtLoginBox.IsChecked == true;
        try { StartAtLogin.Set(requested); }
        catch (Exception ex) when (IsStorageError(ex))
        {
            StartAtLoginBox.IsChecked = !requested;
            Status.Text = "无法保存 Windows 登录启动设置。";
        }
    }

    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Resume)
            _ = Dispatcher.InvokeAsync(CatchUpAfterRecovery);
    }

    private void OnNetworkAvailabilityChanged(object? sender, NetworkAvailabilityEventArgs e)
    {
        if (e.IsAvailable)
            _ = Dispatcher.InvokeAsync(CatchUpAfterRecovery);
    }

    private async void CatchUpAfterRecovery()
    {
        if (_exiting)
            return;
        foreach (var schedule in _schedule.Values.Concat(_readSchedule.Values).Concat(_todoSchedule.Values))
            schedule.RearmAfterRecovery();
        UpdateCountdowns();
        await SynchronizeAsync(automatic: true);
    }

    private void ResetSchedule()
    {
        foreach (var schedule in _schedule.Values.Concat(_readSchedule.Values).Concat(_todoSchedule.Values))
            schedule.Reset();
    }

    protected override async void OnClosing(CancelEventArgs e)
    {
        base.OnClosing(e);
        if (_allowClose)
            return;
        e.Cancel = true;
        if (_exiting)
            return;
        _exiting = true;
        _timer.Stop();
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        NetworkChange.NetworkAvailabilityChanged -= OnNetworkAvailabilityChanged;
        SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
        _desktopCard?.CloseForExit();
        try { await _operation.CancelAndDrainAsync(); }
        catch (Exception) { /* The operation has stopped. */ }
        finally
        {
            _bbHttp.Dispose();
            _outlookHttp.Dispose();
            _todoHttp.Dispose();
            _allowClose = true;
            // Closing synchronously from inside a Closing callback is unsupported.
            _ = Dispatcher.InvokeAsync(Close);
        }
    }

    private void RenderControls()
    {
        if (SourcePicker.SelectedItem is null)
            return;
        var source = CurrentSource;
        var binding = _settings.Source(source);
        bool idle = !_busy && !_changing && !_exiting && _storageAvailable;
        bool canInterrupt = !_changing && !_exiting && _storageAvailable;
        bool isBb = source == SourceKind.Blackboard;

        SourcePicker.IsEnabled = idle;
        BbInput.Visibility = isBb ? Visibility.Visible : Visibility.Collapsed;
        BlackboardAddress.IsEnabled = idle;
        BbLoginButton.Visibility = isBb ? Visibility.Visible : Visibility.Collapsed;
        BbLoginButton.IsEnabled = !_exiting;
        SchoolLoginButton.Visibility = isBb ? Visibility.Collapsed : Visibility.Visible;
        SchoolLoginButton.IsEnabled = canInterrupt;
        SchoolNetworkHint.Visibility = isBb ? Visibility.Collapsed : Visibility.Visible;
        PreviewButton.IsEnabled = idle;
        var connection = binding.AccountId is null ? "尚未绑定" : "已绑定";
        var consent = binding.Enabled ? "Outlook 同步已启用" : "Outlook 同步未启用";
        string lastSuccess = binding.LastSuccess is { } time
            ? "Outlook 上次成功 " + DeadlinePresentation.FormatDeadline(new CalendarEntry("", "", "", null, time)) + "（北京时间）"
            : "Outlook 尚无成功记录";
        var sourceStatus = _sourceMessages.GetValueOrDefault(source) ?? "";
        if (_previews.TryGetValue(source, out var preview) && preview.Warnings.Count > 0)
            sourceStatus += " " + string.Join(" ", preview.Warnings);
        var lastRead = binding.LastRead is { } read ? "本地读取 " + DisplayTime(read) : "尚无本地读取记录";
        SourceStatus.Text = $"{connection} · {lastRead} · {consent} · {lastSuccess}　{sourceStatus}".TrimEnd();

        OutlookLoginButton.IsEnabled = canInterrupt && (_previews.Count > 0 || _settings.OutlookAccount is not null);
        OutlookLoginButton.Content = _settings.OutlookAccount is null ? "授权个人 Outlook" : "重新授权 Outlook";
        SwitchAccountButton.Visibility = _settings.OutlookAccount is null ? Visibility.Collapsed : Visibility.Visible;
        SwitchAccountButton.IsEnabled = canInterrupt;
        CalendarButton.IsEnabled = idle && !_outlookNeedsLogin && _settings.OutlookAccount is not null &&
            (_settings.OutlookCalendar is null || _calendarMissing);
        TargetStatus.Text = _settings.OutlookAccount is not { } account ? "尚未授权个人 Outlook。"
            : (string.IsNullOrWhiteSpace(account.Username) ? "个人 Outlook 已授权" : account.Username)
                + (_outlookNeedsLogin ? " · 请重新授权" : "")
                + (_calendarMissing ? " · 请重新设置 DueBridge 日历"
                    : _settings.OutlookCalendar is null ? " · 尚未设置 DueBridge 日历" : " · 已绑定 DueBridge 日历");
        SourceConsentButton.Content = binding.Enabled ? "停用此来源到 Outlook" : "启用此来源到 Outlook";
        SourceConsentButton.IsEnabled = binding.Enabled ? canInterrupt : idle && CanEnableSource(source);
        DesktopAutoReadBox.IsEnabled = canInterrupt && (binding.AutoRead ||
            !_needsSchoolLogin.Contains(source) && _previews.TryGetValue(source, out var localPreview) && localPreview.AccountId == binding.AccountId);
        DesktopAutoReadBox.IsChecked = binding.AutoRead;
        DesktopCardButton.IsEnabled = !_exiting;
        PauseButton.IsEnabled = canInterrupt && (_settings.Paused || Sources.Any(kind =>
            _settings.Source(kind).Enabled || _settings.Source(kind).TodoEnabled || _settings.Source(kind).AutoRead));
        PauseButton.Content = _settings.Paused ? "恢复全部同步" : "暂停全部同步";
        SyncButton.IsEnabled = idle && !_settings.Paused && Sources.Any(kind =>
            !_needsSchoolLogin.Contains(kind) && _settings.Source(kind).AccountId is not null &&
            (_settings.Source(kind).AutoRead || CanWrite && CanSyncSource(kind) || CanWriteTodo && _settings.Source(kind).TodoEnabled));
        CourseEditor.Visibility = isBb ? Visibility.Visible : Visibility.Collapsed;
        SaveCourseButton.IsEnabled = idle && PreviewGrid.SelectedItem is PreviewRow;
        ClearCourseButton.IsEnabled = SaveCourseButton.IsEnabled;
        RenderTodoControls(idle, canInterrupt);
        RenderDesktopCard();
    }

    private void RenderPreview()
    {
        string? selectedKey = (PreviewGrid.SelectedItem as PreviewRow)?.Entry.Key;
        var source = CurrentSource;
        var now = DateTimeOffset.UtcNow;
        var rows = _settings.DesktopEntries().Where(row => row.Source == source)
            .Select(row => new PreviewRow(row.Entry, row.Entry.CourseLabel, now)).ToArray();
        PreviewGrid.ItemsSource = rows;
        PreviewGrid.SelectedItem = rows.FirstOrDefault(row => row.Entry.Key == selectedKey);
        UpdateCountdowns();
        RenderDesktopCard();
    }

    private void UpdateCountdowns()
    {
        var now = DateTimeOffset.UtcNow;
        _desktopCard?.UpdateCountdowns(now);
        if (PreviewGrid.ItemsSource is PreviewRow[] rows)
            foreach (var row in rows)
                row.Update(now);

        var earliest = _settings.DesktopEntries().Where(item => item.Entry.DueAt >= now ||
                item.Entry.AllDay is { } day && day >= DeadlinePresentation.ShanghaiDate(now)).FirstOrDefault();
        EarliestDeadline.Text = earliest is not null
            ? $"最早到期　{earliest.Entry.Title} · {Label(earliest.Source)} · {DeadlinePresentation.FormatDeadline(earliest.Entry)}"
            : "读取任一来源的预览后，可查看最早到期的任务。";
    }

    private void OnPreviewSelection(object sender, SelectionChangedEventArgs e)
    {
        if (sender != PreviewGrid || CourseInput is null)
            return;
        var key = (PreviewGrid.SelectedItem as PreviewRow)?.Entry.Key;
        CourseInput.Text = key is not null && CurrentSource == SourceKind.Blackboard
            ? _settings.BlackboardCourses.GetValueOrDefault(key) ?? "" : "";
        RenderControls();
    }

    private async void OnSaveCourse(object sender, RoutedEventArgs e) => await SaveCourseAsync(clear: false);
    private async void OnClearCourse(object sender, RoutedEventArgs e) => await SaveCourseAsync(clear: true);

    private async Task SaveCourseAsync(bool clear)
    {
        if (CurrentSource != SourceKind.Blackboard || PreviewGrid.SelectedItem is not PreviewRow row)
            return;
        var name = clear ? null : DeadlinePresentation.NormalizeCourse(CourseInput.Text);
        if (!clear && name is null)
        {
            Status.Text = "请输入单行课程名称。";
            return;
        }
        await RunAsync("正在保存课程名称…", token =>
        {
            token.ThrowIfCancellationRequested();
            var names = new Dictionary<string, string>(_settings.BlackboardCourses, StringComparer.Ordinal);
            if (name is null)
                names.Remove(row.Entry.Key);
            else
                names[row.Entry.Key] = name;
            Save(_settings with { BlackboardCourses = names });
            RenderPreview();
            Status.Text = name is null ? "已清除本地课程名称。" : "已保存本地课程名称。";
            return Task.CompletedTask;
        });
    }

    private sealed class PreviewRow(CalendarEntry entry, string course, DateTimeOffset now) : INotifyPropertyChanged
    {
        public CalendarEntry Entry { get; } = entry;
        public string Title => Entry.Title;
        public string Course { get; } = course;
        public string Deadline => DeadlinePresentation.FormatDeadline(Entry);
        public string Countdown { get; private set; } = DeadlinePresentation.Countdown(entry, now);
        public event PropertyChangedEventHandler? PropertyChanged;

        public void Update(DateTimeOffset time)
        {
            var next = DeadlinePresentation.Countdown(Entry, time);
            if (next == Countdown)
                return;
            Countdown = next;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Countdown)));
        }
    }
}
