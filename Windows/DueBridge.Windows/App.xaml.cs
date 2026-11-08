using System.Windows;

namespace DueBridge.Windows;

public partial class App : Application
{
    private Mutex? _instance;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _instance = new Mutex(initiallyOwned: true, @"Local\DueBridge.Windows", out bool first);
        if (!first)
        {
            _instance.Dispose();
            _instance = null;
            Shutdown();
            return;
        }

        var window = new MainWindow();
        MainWindow = window;
        if (e.Args.Contains("--start-at-login", StringComparer.Ordinal))
            window.WindowState = WindowState.Minimized;
        window.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _instance?.ReleaseMutex();
        _instance?.Dispose();
        base.OnExit(e);
    }
}
