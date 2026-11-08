using System.ComponentModel;
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
    private readonly BlackboardFeed _blackboard;
    private readonly OutlookSignIn _signIn;
    private readonly OutlookCalendar _outlook;
    private readonly Dictionary<SourceKind, SchoolSource> _school;
    private readonly SyncOperation _operation = new();
    private readonly Dictionary<SourceKind, SourcePreview> _previews = [];
    private readonly Dictionary<SourceKind, DailySyncSchedule> _schedule = Sources.ToDictionary(kind => kind, _ => new DailySyncSchedule());
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

        SourcePicker.ItemsSource = Sources.Select(kind => new SourceOption(kind, Label(kind))).ToArray();
        SourcePicker.DisplayMemberPath = nameof(SourceOption.Name);
        SourcePicker.SelectedIndex = 0;
        try { StartAtLoginBox.IsChecked = StartAtLogin.IsEnabled(); }
        catch (Exception ex) when (IsStorageError(ex)) { StartAtLoginBox.IsEnabled = false; }

        Loaded += async (_, _) =>
        {
            SystemEvents.PowerModeChanged += OnPowerModeChanged;
            NetworkChange.NetworkAvailabilityChanged += OnNetworkAvailabilityChanged;
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
            _previews.Remove(source);
            RenderPreview();
            var preview = await ReadSourceAsync(source, address, expected: null, token);
            AcceptPreview(source, preview, address, token);
        });
    }

    private async void OnSchoolLogin(object sender, RoutedEventArgs e)
    {
        var source = CurrentSource;
        if (!_school.TryGetValue(source, out var school))
            return;
        await ChangeAsync($"请在学校登录窗口中完成 {Label(source)} 登录。", async token =>
        {
            _previews.Remove(source);
            RenderPreview();
            await school.LoginAsync(token);
            var preview = await school.PreviewAsync(token);
            AcceptPreview(source, preview, null, token);
        });
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
        if (changed)
        {
            var updated = _settings.WithSource(source, new SourceBinding(preview.AccountId));
            if (source == SourceKind.Blackboard)
                updated = updated with { BlackboardAddress = address };
            Save(updated);
        }
        _needsSchoolLogin.Remove(source);
        _schedule[source].Reset();
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
            _sourceMessages[source] = binding.Enabled ? "已停用此来源同步。" : "已启用此来源同步。";
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
            Status.Text = paused ? "全部来源已暂停同步。" : "已恢复已启用来源的自动同步。";
            return Task.CompletedTask;
        });
        if (!_settings.Paused)
            await SynchronizeAsync(automatic: true);
    }

    private async void OnSyncNow(object sender, RoutedEventArgs e) => await SynchronizeAsync(automatic: false);

    private async Task SynchronizeAsync(bool automatic, SourceKind? only = null)
    {
        if (_changing || _busy || !CanWrite || _settings.OutlookCalendar is not { } target)
            return;

        var now = DateTimeOffset.UtcNow;
        var inputs = Sources.Where(source => (only is null || source == only) && CanSyncSource(source) &&
            (!automatic || _schedule[source].CanAttempt(_settings.Source(source).LastSuccess, now))).ToArray();
        if (inputs.Length == 0)
            return;

        await RunAsync("正在同步已启用的来源…", async token =>
        {
            var summaries = new List<string>();
            foreach (var source in inputs)
            {
                token.ThrowIfCancellationRequested();
                if (!CanWrite)
                    break;

                _schedule[source].MarkAttempt(DateTimeOffset.UtcNow);
                var binding = _settings.Source(source);
                try
                {
                    var (preview, result) = await RetryAsync(async cancellation =>
                    {
                        var current = await ReadSourceAsync(source, _settings.BlackboardAddress, binding.AccountId, cancellation);
                        if (!string.Equals(current.AccountId, binding.AccountId, StringComparison.Ordinal))
                            throw new ChangedSourceException();
                        cancellation.ThrowIfCancellationRequested();
                        var entries = current.Entries.Select(entry => PresentForCalendar(source, entry)).ToArray();
                        var outcome = await _outlook.SyncAsync(target, entries, cancellation);
                        return (current, outcome);
                    }, token);

                    token.ThrowIfCancellationRequested();
                    Save(_settings.WithSource(source, binding with { LastSuccess = DateTimeOffset.UtcNow }));
                    _previews[source] = preview;
                    _sourceMessages[source] = $"新增 {result.Added}，更新 {result.Updated}，无变化 {result.Unchanged}。";
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    ObserveFailure(ex, source);
                    if (IsRetryable(ex))
                        _schedule[source].MarkTransientFailure();
                    _sourceMessages[source] = UserMessage(ex);
                }

                summaries.Add($"{Label(source)}　{_sourceMessages[source]}");
                RenderPreview();
            }
            Status.Text = string.Join("\n", summaries);
        });
    }

    private CalendarEntry PresentForCalendar(SourceKind source, CalendarEntry entry)
    {
        string? course = source == SourceKind.Blackboard
            ? _settings.BlackboardCourses.GetValueOrDefault(entry.Key) : entry.CourseLabel;
        return DeadlinePresentation.ForCalendar(entry, course);
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

    private sealed class ChangedSourceException : Exception
    {
        internal ChangedSourceException() : base("当前登录与绑定来源不同。请重新读取预览并确认同步设置。") { }
    }

    private void ObserveFailure(Exception ex, SourceKind? source = null)
    {
        if (ex is OutlookException outlook)
        {
            if (outlook.Failure is OutlookFailure.SignInRequired or OutlookFailure.PermissionDenied)
                _outlookNeedsLogin = true;
            if (outlook.Failure == OutlookFailure.CalendarMissing)
                _calendarMissing = true;
        }
        if (source is { } kind && ex is SchoolConnectionException { Retryable: false } or ChangedSourceException)
            _needsSchoolLogin.Add(kind);
    }

    private static string UserMessage(Exception ex) =>
        ex is BlackboardException or SchoolConnectionException or OutlookException or LocalStorageException or ChangedSourceException
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
        foreach (var schedule in _schedule.Values)
            schedule.RearmAfterRecovery();
        UpdateCountdowns();
        await SynchronizeAsync(automatic: true);
    }

    private void ResetSchedule()
    {
        foreach (var schedule in _schedule.Values)
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
        try { await _operation.CancelAndDrainAsync(); }
        catch (Exception) { /* The operation has stopped. */ }
        finally
        {
            _bbHttp.Dispose();
            _outlookHttp.Dispose();
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
        SchoolLoginButton.Visibility = isBb ? Visibility.Collapsed : Visibility.Visible;
        SchoolLoginButton.IsEnabled = canInterrupt;
        PreviewButton.IsEnabled = idle;
        var connection = binding.AccountId is null ? "尚未绑定" : "已绑定";
        var consent = binding.Enabled ? "同步已启用" : "同步未启用";
        string lastSuccess = binding.LastSuccess is { } time
            ? "上次成功 " + DeadlinePresentation.FormatDeadline(new CalendarEntry("", "", "", null, time)) + "（北京时间）"
            : "尚无成功记录";
        var sourceStatus = _sourceMessages.GetValueOrDefault(source) ?? "";
        if (_previews.TryGetValue(source, out var preview) && preview.Warnings.Count > 0)
            sourceStatus += " " + string.Join(" ", preview.Warnings);
        SourceStatus.Text = $"{connection} · {consent} · {lastSuccess}　{sourceStatus}".TrimEnd();

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
        SourceConsentButton.Content = binding.Enabled ? "停用此来源同步" : "启用此来源同步";
        SourceConsentButton.IsEnabled = binding.Enabled ? canInterrupt : idle && CanEnableSource(source);
        PauseButton.IsEnabled = canInterrupt && Sources.Any(kind => _settings.Source(kind).Enabled);
        PauseButton.Content = _settings.Paused ? "恢复全部同步" : "暂停全部同步";
        SyncButton.IsEnabled = idle && CanWrite && Sources.Any(CanSyncSource);
        CourseEditor.Visibility = isBb ? Visibility.Visible : Visibility.Collapsed;
        SaveCourseButton.IsEnabled = idle && PreviewGrid.SelectedItem is PreviewRow;
        ClearCourseButton.IsEnabled = SaveCourseButton.IsEnabled;
    }

    private void RenderPreview()
    {
        string? selectedKey = (PreviewGrid.SelectedItem as PreviewRow)?.Entry.Key;
        var source = CurrentSource;
        var now = DateTimeOffset.UtcNow;
        var rows = _previews.TryGetValue(source, out var preview)
            ? preview.Entries.OrderBy(DeadlinePresentation.SortDeadline).ThenBy(entry => entry.Key, StringComparer.Ordinal)
                .Select(entry => new PreviewRow(entry, PresentForCalendar(source, entry).CourseLabel, now)).ToArray()
            : [];
        PreviewGrid.ItemsSource = rows;
        PreviewGrid.SelectedItem = rows.FirstOrDefault(row => row.Entry.Key == selectedKey);
        UpdateCountdowns();
    }

    private void UpdateCountdowns()
    {
        var now = DateTimeOffset.UtcNow;
        if (PreviewGrid.ItemsSource is PreviewRow[] rows)
            foreach (var row in rows)
                row.Update(now);

        var earliest = _previews.SelectMany(pair => pair.Value.Entries.Select(entry => (pair.Key, Entry: entry)))
            .Where(item => !item.Entry.Cancelled && (item.Entry.DueAt >= now ||
                item.Entry.AllDay is { } day && day >= DeadlinePresentation.ShanghaiDate(now)))
            .OrderBy(item => DeadlinePresentation.SortDeadline(item.Entry)).FirstOrDefault();
        EarliestDeadline.Text = earliest.Entry is { } entry
            ? $"最早到期　{entry.Title} · {Label(earliest.Key)} · {DeadlinePresentation.FormatDeadline(entry)}"
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
