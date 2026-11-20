using Microsoft.UI.Xaml;
using NetworkMonitor.App.Monitoring;

namespace NetworkMonitor.App;

public partial class App : Application
{
    internal static NetworkMonitorService Monitor { get; private set; } = null!;
    private Window? _window;

    public App()
    {
        InitializeComponent();
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        Monitor = new NetworkMonitorService(Path.Combine(local, "NetworkMonitor"));
        _window = new MainWindow();
        _window.Activate();
        try { await Monitor.StartAsync(); }
        catch (Exception ex) { Monitor.ReportError($"The local usage database could not be opened: {ex.Message}"); }
    }
}
