using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using DueBridge.Core;

namespace DueBridge.Windows;

public partial class DesktopCard : Window
{
    private readonly Action<DesktopCardSettings> _persist;
    private readonly Action _refresh;
    private readonly Action _openMain;
    private IReadOnlyList<DesktopEntry> _entries = [];
    private DesktopRow[] _rows = [];
    private DesktopBounds? _lastBounds;
    private HwndSource? _source;
    private nint _handle;
    private bool _exitWithApplication;
    private bool _closing;

    internal DesktopCard(DesktopCardSettings settings, Action<DesktopCardSettings> persist, Action refresh, Action openMain, bool transient = false)
    {
        InitializeComponent();
        _persist = persist;
        _refresh = refresh;
        _openMain = openMain;
        _lastBounds = settings.Bounds;
        Topmost = settings.Topmost;
        Pin.IsChecked = Topmost;
        if (transient)
        {
            ShowInTaskbar = false;
            Pin.Visibility = Visibility.Collapsed;
            Deactivated += (_, _) => { if (!_closing) Close(); };
        }
        SourceInitialized += (_, _) =>
        {
            _handle = new WindowInteropHelper(this).Handle;
            _source = HwndSource.FromHwnd(_handle);
            _source?.AddHook(OnWindowMessage);
            ApplyBounds(_lastBounds);
        };
    }

    internal void SetContent(IReadOnlyList<DesktopEntry> entries, bool hasSnapshot, string state,
        string summary, string detail, bool canRefresh)
    {
        if (!_entries.SequenceEqual(entries))
        {
            _entries = entries;
            _rows = entries.Select(entry => new DesktopRow(entry, DateTimeOffset.UtcNow)).ToArray();
            Tasks.ItemsSource = _rows;
        }
        TaskCount.Text = $"{entries.Count} 项";
        UpdateState.Text = state;
        SourceSummary.Text = summary;
        SourceSummary.ToolTip = detail;
        RefreshButton.IsEnabled = canRefresh;
        EmptyState.Visibility = entries.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyTitle.Text = hasSnapshot ? "暂无截止事项" : "连接课程来源";
        EmptyDescription.Text = hasSnapshot ? "已读取的来源没有可显示的截止任务。" : "打开归期，读取课程预览后，任务会显示在这里。";
    }

    internal void UpdateCountdowns(DateTimeOffset now)
    {
        foreach (var row in _rows) row.Update(now);
    }

    private void OnDragHeader(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton == MouseButton.Left && e.ClickCount == 1)
        {
            DragMove();
            e.Handled = true;
        }
    }

    private void OnPin(object sender, RoutedEventArgs e)
    {
        Topmost = Pin.IsChecked == true;
        Persist(visible: true);
    }

    private void OnHide(object sender, RoutedEventArgs e) => Close();
    private void OnRefresh(object sender, RoutedEventArgs e) => _refresh();
    private void OnOpenMain(object sender, RoutedEventArgs e) => _openMain();

    internal void CloseForExit()
    {
        _exitWithApplication = true;
        Close();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        _closing = true;
        Persist(visible: _exitWithApplication);
        base.OnClosing(e);
    }

    protected override void OnClosed(EventArgs e)
    {
        if (_source is { IsDisposed: false }) _source.RemoveHook(OnWindowMessage);
        _source = null;
        _handle = 0;
        base.OnClosed(e);
    }

    private void Persist(bool visible)
    {
        // Win+D minimizes to a sentinel rectangle; never persist that as the next launch location.
        if (_handle != 0 && WindowState == WindowState.Normal && GetWindowRect(_handle, out var rect))
            _lastBounds = rect.Bounds;
        _persist(new(visible, Topmost, _lastBounds));
    }

    private nint OnWindowMessage(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (_closing) return 0;
        if (message == 0x0232) Persist(visible: true); // WM_EXITSIZEMOVE
        if (message == 0x02E0) // WM_DPICHANGED: clamp after WPF applies the suggested DPI rectangle.
            _ = Dispatcher.InvokeAsync(EnsureVisibleAndSave);
        return 0;
    }

    internal void EnsureVisibleAndSave() => ApplyBounds(null);

    internal void PositionNearPointer(double x,double y,DesktopBounds area)
    {
        if (_handle == 0 || !GetWindowRect(_handle,out var current)) return;
        ApplyBounds(DesktopBounds.PopupAt(x,y,area,current.Bounds.Width,current.Bounds.Height));
    }

    private void ApplyBounds(DesktopBounds? requested)
    {
        if (_closing || _handle == 0 || WindowState != WindowState.Normal || !GetWindowRect(_handle, out var current)) return;
        var desired = NativeRect.From(requested ?? current.Bounds);
        var monitor = MonitorFromRect(ref desired, 2); // MONITOR_DEFAULTTONEAREST
        var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (monitor == 0 || !GetMonitorInfo(monitor, ref info)) return;
        var fitted = DesktopBounds.Fit(desired.Bounds, info.Work.Bounds);
        SetWindowPos(_handle, 0, (int)fitted.Left, (int)fitted.Top, (int)fitted.Width, (int)fitted.Height,
            0x0004 | 0x0010); // SWP_NOZORDER | SWP_NOACTIVATE
        Persist(visible: true);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left, Top, Right, Bottom;
        internal readonly DesktopBounds Bounds => new(Left, Top, Right - Left, Bottom - Top);
        internal static NativeRect From(DesktopBounds bounds)
        {
            static int Number(double value, int fallback, int minimum, int maximum) =>
                double.IsFinite(value) ? (int)Math.Clamp(value, minimum, maximum) : fallback;
            int left = Number(bounds.Left, 0, -1_000_000, 1_000_000);
            int top = Number(bounds.Top, 0, -1_000_000, 1_000_000);
            return new() { Left = left, Top = top,
                Right = left + Number(bounds.Width > 0 ? bounds.Width : 360, 360, 1, 100_000),
                Bottom = top + Number(bounds.Height > 0 ? bounds.Height : 480, 480, 1, 100_000) };
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo
    {
        public int Size;
        public NativeRect Monitor, Work;
        public uint Flags;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(nint hwnd, out NativeRect rect);
    [DllImport("user32.dll")]
    private static extern nint MonitorFromRect(ref NativeRect rect, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetMonitorInfoW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(nint hwnd, nint after, int x, int y, int width, int height, uint flags);

    private sealed class DesktopRow(DesktopEntry task, DateTimeOffset now) : INotifyPropertyChanged
    {
        public string Title => task.Entry.Title;
        public string CourseAndSource => task.Entry.CourseLabel + " · " + (task.Source switch
        {
            SourceKind.Blackboard => "BB", SourceKind.Mo => "智海 MO", _ => "学在浙大"
        });
        public string Deadline => DeadlinePresentation.FormatDeadline(task.Entry);
        public string Countdown { get; private set; } = DeadlinePresentation.Countdown(task.Entry, now);
        public bool IsOverdue { get; private set; } = Overdue(task.Entry, now);
        public bool IsSoon { get; private set; } = Soon(task.Entry, now);
        public event PropertyChangedEventHandler? PropertyChanged;

        private static bool Overdue(CalendarEntry entry, DateTimeOffset at) => entry.AllDay is { } day
            ? day < DeadlinePresentation.ShanghaiDate(at) : entry.DueAt <= at;
        private static bool Soon(CalendarEntry entry, DateTimeOffset at) => !Overdue(entry, at) && (entry.AllDay is { } day
            ? day == DeadlinePresentation.ShanghaiDate(at) : entry.DueAt - at <= TimeSpan.FromHours(24));

        internal void Update(DateTimeOffset at)
        {
            var countdown = DeadlinePresentation.Countdown(task.Entry, at);
            var overdue = Overdue(task.Entry, at);
            var soon = Soon(task.Entry, at);
            if (Countdown == countdown && IsOverdue == overdue && IsSoon == soon) return;
            Countdown = countdown;
            IsOverdue = overdue;
            IsSoon = soon;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
        }
    }
}
