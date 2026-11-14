using System.Windows;

namespace DueBridge.Windows;

public partial class App : Application
{
    private Mutex? _instance;
    private EventWaitHandle? _activation;
    private RegisteredWaitHandle? _activationWait;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _activation = new EventWaitHandle(false,EventResetMode.AutoReset,@"Local\DueBridge.Windows.Activate");
        _instance = new Mutex(initiallyOwned: true, @"Local\DueBridge.Windows", out bool first);
        if (!first)
        {
            _activation.Set();
            _activation.Dispose();
            _activation = null;
            _instance.Dispose();
            _instance = null;
            Shutdown();
            return;
        }

        var window = new MainWindow();
        MainWindow = window;
        _activationWait = ThreadPool.RegisterWaitForSingleObject(_activation, (_,_) =>
        {
            if (!Dispatcher.HasShutdownStarted)
                _ = Dispatcher.InvokeAsync(window.RestoreFromExternalLaunch);
        }, null, Timeout.Infinite, false);
        if (e.Args.Contains("--start-at-login", StringComparer.Ordinal))
            window.WindowState = WindowState.Minimized;
        window.Show();
    }

    protected override void OnSessionEnding(SessionEndingCancelEventArgs e)
    {
        (MainWindow as MainWindow)?.PrepareForSessionEnd();
        base.OnSessionEnding(e);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        (MainWindow as MainWindow)?.PrepareForSessionEnd();
        _activationWait?.Unregister(null);
        _activation?.Dispose();
        _instance?.ReleaseMutex();
        _instance?.Dispose();
        base.OnExit(e);
    }
}
