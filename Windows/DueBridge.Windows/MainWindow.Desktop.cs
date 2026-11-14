using System.Windows;
using DueBridge.Core;

namespace DueBridge.Windows;

public partial class MainWindow
{
    private DesktopCard? _desktopCard;

    private static string DisplayTime(DateTimeOffset time) =>
        DeadlinePresentation.FormatDeadline(new("", "", "", null, time)) + "（北京时间）";

    private void OnShowDesktopCard(object sender, RoutedEventArgs e) => ShowDesktopCard();

    private void ShowDesktopCard()
    {
        if (_exiting) return;
        if (_desktopCard is not null)
        {
            if (_desktopCard.WindowState == WindowState.Minimized) _desktopCard.WindowState = WindowState.Normal;
            _desktopCard.Activate();
            return;
        }
        var settings = _settings.Card with { Visible = true };
        PersistCardSettings(settings);
        _desktopCard = new DesktopCard(settings, PersistCardSettings,
            async () => await SynchronizeAsync(automatic: false, localOnly: true), () =>
            {
                if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
                Show();
                Activate();
            });
        // Do not set Owner: minimizing the main window must leave the card visible.
        _desktopCard.Closed += (_, _) => _desktopCard = null;
        RenderDesktopCard();
        _desktopCard.Show();
    }

    private void PersistCardSettings(DesktopCardSettings card)
    {
        if (!_storageAvailable) return;
        try { Save(_settings with { Card = card }); }
        catch (LocalStorageException error) { Status.Text = error.Message; }
    }

    private async void OnToggleDesktopRead(object sender, RoutedEventArgs e)
    {
        var source = CurrentSource;
        bool requested = DesktopAutoReadBox.IsChecked == true;
        await ChangeAsync("正在保存桌面任务更新设置…", token =>
        {
            token.ThrowIfCancellationRequested();
            var binding = _settings.Source(source);
            if (binding.AccountId is null) return Task.CompletedTask;
            Save(_settings.WithSource(source, binding with { AutoRead = requested }));
            _readSchedule[source].Reset();
            Status.Text = requested ? "此来源将每天自动更新桌面任务。" : "此来源已改为手动更新桌面任务。";
            return Task.CompletedTask;
        });
        if (requested) await SynchronizeAsync(automatic: true, only: source);
    }

    private void RenderDesktopCard()
    {
        RenderCard(_desktopCard);
        RenderCard(_trayPopup);
    }

    private void RenderCard(DesktopCard? card)
    {
        if (card is null) return;
        var summaries = new List<string>();
        var details = new List<string>();
        foreach (var source in Sources)
        {
            var binding = _settings.Source(source);
            if (binding.AccountId is null) continue;
            var label = source == SourceKind.Blackboard ? "BB" : Label(source);
            var fullRead = binding.LastRead is { } time ? DisplayTime(time) : "尚未成功读取";
            var read = binding.LastRead is not null ? fullRead[5..] : fullRead;
            var mode = binding.AutoRead ? "每日更新" : "手动更新";
            var error = binding.ReadError is not null ? " · 更新失败" : "";
            summaries.Add($"{label} · {read.Replace("（北京时间）", "", StringComparison.Ordinal)} · {mode}{error}");
            details.Add($"{Label(source)}：{fullRead} · {mode}" + (binding.ReadError is { } issue ? "\n" + issue : ""));
        }
        bool hasSnapshot = Sources.Any(source => _settings.Source(source) is { Snapshot: { } snapshot } binding &&
            snapshot.AccountId == binding.AccountId);
        string status = !_storageAvailable ? "本地存储不可用，已停止自动更新"
            : _changing || _busy ? "正在处理任务…"
            : _settings.Paused ? "自动读取和 Outlook 写入已暂停"
            : Sources.Any(source => _settings.Source(source).ReadError is not null) ? "更新未完成，保留上次任务"
            : "按截止时间排序 · 北京时间";
        card.SetContent(_settings.DesktopEntries(), hasSnapshot, status,
            summaries.Count == 0 ? "尚未连接课程来源" : string.Join("\n", summaries), string.Join("\n\n", details),
            !_changing && !_busy && !_exiting && _storageAvailable && Sources.Any(source =>
                _settings.Source(source).AccountId is not null && !_needsSchoolLogin.Contains(source)));
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e)
        => _ = Dispatcher.InvokeAsync(() =>
        {
            if (!_exiting) _desktopCard?.EnsureVisibleAndSave();
        });
}
