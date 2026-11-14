using System.ComponentModel;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows;
using Forms = System.Windows.Forms;
namespace DueBridge.Windows;
public partial class MainWindow
{
    private Forms.NotifyIcon? _trayIcon;
    private Icon? _trayImage;
    private DesktopCard? _trayPopup;
    private bool _explicitExit, _sessionEnding;
    private long _popupDismissed;

    private void InitializeTray()
    {
        try
        {
            using var stream = typeof(MainWindow).Assembly.GetManifestResourceStream("DueBridge.Brand.png")!;
            using var bitmap = new Bitmap(stream);
            using var small = new Bitmap(bitmap,32,32);
            var handle = small.GetHicon();
            try { using var borrowed = System.Drawing.Icon.FromHandle(handle); _trayImage = (Icon)borrowed.Clone(); }
            finally { DestroyIcon(handle); }
            var menu = new Forms.ContextMenuStrip();
            menu.Items.Add("查看 DDL 列表",null,(_,_) => Dispatcher.Invoke(ShowTrayPopup));
            menu.Items.Add("打开主窗口",null,(_,_) => Dispatcher.Invoke(OpenMainFromTray));
            menu.Items.Add("立即更新",null,async (_,_) => await Dispatcher.InvokeAsync(() => SynchronizeAsync(automatic:false)).Task.Unwrap());
            menu.Items.Add(new Forms.ToolStripSeparator());
            menu.Items.Add("退出归期",null,(_,_) => Dispatcher.Invoke(() => { _explicitExit=true; Close(); }));
            _trayIcon = new Forms.NotifyIcon { Icon=_trayImage,Text="归期 · 点击查看课程截止事项",ContextMenuStrip=menu,Visible=true };
            _trayIcon.MouseClick += (_,e) =>
            {
                if(e.Button==Forms.MouseButtons.Left) Dispatcher.Invoke(() =>
                {
                    if(Environment.TickCount64-_popupDismissed>250) ShowTrayPopup();
                });
            };
            if(Environment.GetCommandLineArgs().Contains("--start-at-login",StringComparer.Ordinal)) Hide();
        }
        catch(Exception error) when(error is ArgumentException or InvalidOperationException or Win32Exception or System.IO.IOException)
        {
            DisposeTray();
            Status.Text="通知区图标不可用，关闭主窗口仍会退出。";
        }
    }
    private void OnExplicitExit(object sender,RoutedEventArgs e) { _explicitExit=true; Close(); }
    private void OpenMainFromTray()
    {
        _trayPopup?.Close();
        if(WindowState==WindowState.Minimized) WindowState=WindowState.Normal;
        Show();Activate();
    }
    private void ShowTrayPopup()
    {
        if(_exiting) return;
        if(_trayPopup is not null) { _trayPopup.Close(); return; }
        var cursor=Forms.Cursor.Position;
        var work=Forms.Screen.FromPoint(cursor).WorkingArea;
        var area=new DesktopBounds(work.Left,work.Top,work.Width,work.Height);
        _trayPopup=new DesktopCard(new(Visible:true,Topmost:true),_=>{},
            async ()=>await SynchronizeAsync(automatic:false,localOnly:true),OpenMainFromTray,transient:true);
        _trayPopup.Closed+=(_,_)=> { _trayPopup=null;_popupDismissed=Environment.TickCount64; };
        RenderDesktopCard();_trayPopup.Show();_trayPopup.PositionNearPointer(cursor.X,cursor.Y,area);_trayPopup.Activate();
    }
    private void DisposeTray()
    {
        if(_trayIcon is {} icon)
        {
            _trayIcon=null;icon.Visible=false;
            var menu=icon.ContextMenuStrip;icon.Dispose();menu?.Dispose();
        }
        _trayImage?.Dispose();_trayImage=null;
    }
    internal void RestoreFromExternalLaunch() { if (!_exiting) OpenMainFromTray(); }
    private void StopExitUi()
    {
        _timer.Stop();
        Microsoft.Win32.SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        System.Net.NetworkInformation.NetworkChange.NetworkAvailabilityChanged -= OnNetworkAvailabilityChanged;
        Microsoft.Win32.SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
        DisposeTray();
        _trayPopup?.CloseForExit();
        _desktopCard?.CloseForExit();
    }
    internal void PrepareForSessionEnd()
    {
        _sessionEnding=true;_explicitExit=true;_exiting=true;
        StopExitUi();
        CancelForSessionEnd();
        _bbHttp.Dispose();_outlookHttp.Dispose();_todoHttp.Dispose();
    }
    private async void CancelForSessionEnd()
    {
        try { await _operation.CancelAndDrainAsync(); }
        catch (Exception) { /* Session teardown must not wait for network or UI continuations. */ }
    }
    [DllImport("user32.dll")]
    [return:MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(nint icon);
}
