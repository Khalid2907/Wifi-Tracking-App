using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using NetworkMonitor.App.Monitoring;
using NetworkMonitor.App.Native;
using NetworkMonitor.Core;

namespace NetworkMonitor.App;

public sealed partial class MainWindow : Window
{
    private readonly DispatcherTimer _historyRefresh = new() { Interval = TimeSpan.FromMinutes(1) };
    private readonly ShellTrayIcon _tray;
    private IReadOnlyList<InterfaceRate> _latest = [];
    private IReadOnlyDictionary<Guid, (long Download, long Upload)> _lifetime = new Dictionary<Guid, (long Download, long Upload)>();

    public MainWindow()
    {
        InitializeComponent();
        _tray = new ShellTrayIcon(this, Activate, Close, App.Monitor.HandlePowerTransition);
        App.Monitor.Updated += OnMonitorUpdated;
        Closed += OnClosed;
        _historyRefresh.Tick += async (_, _) => await RefreshHistoryAsync();
        _historyRefresh.Start();
        _ = RefreshHistoryAsync();
    }

    private void HideToTray_Click(object sender, RoutedEventArgs args) => _tray.HideWindow();

    private void OnMonitorUpdated(MonitorUpdate update)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (update.Error is not null)
            {
                StatusText.Text = "Monitoring error";
                StatusDot.Fill = new SolidColorBrush(Colors.OrangeRed);
                ErrorText.Text = update.Error;
                ErrorText.Visibility = Visibility.Visible;
                return;
            }

            ErrorText.Visibility = Visibility.Collapsed;
            NetworkLabel.Text = update.WifiSsid is null ? "No active Wi-Fi profile · statistics stored locally" : $"Wi-Fi · {update.WifiSsid} · statistics stored locally";
            StatusText.Text = "Monitoring";
            StatusDot.Fill = new SolidColorBrush(Colors.ForestGreen);
            _latest = update.Interfaces;
            UpdateInterfaceList();
            StatusText.Text = update.Interfaces.Any(i => i.Quality is InterfaceQuality.Invalid or InterfaceQuality.Unattributed)
                ? "Baseline or gap detected"
                : "Monitoring";

            // This aggregate deliberately includes only hardware Wi-Fi/Ethernet rows; virtual
            // adapters remain visible per-interface but are not blindly added to this total.
            var physical = update.Interfaces.Where(i => i.IsHardware && i.Kind is InterfaceKind.WiFi or InterfaceKind.Ethernet).ToArray();
            DownloadSpeed.Text = TrafficFormatting.Rate(physical.Sum(i => i.DownloadBytesPerSecond));
            UploadSpeed.Text = TrafficFormatting.Rate(physical.Sum(i => i.UploadBytesPerSecond));
        });
    }

    private async Task RefreshHistoryAsync()
    {
        try
        {
            var now = DateTime.Now;
            var usage = await App.Monitor.GetMonthByDayAsync(DateOnly.FromDateTime(now));
            var lifetime = await App.Monitor.GetLifetimeByInterfaceAsync();
            var totalDown = usage.Values.Sum(v => v.Download);
            var totalUp = usage.Values.Sum(v => v.Upload);
            var today = now.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
            var todayUsage = usage.GetValueOrDefault(today);

            await DispatcherQueue.EnqueueAsync(() =>
            {
                TodayDownload.Text = $"Today: {TrafficFormatting.Data((ulong)Math.Max(0, todayUsage.Download))}";
                TodayUpload.Text = $"Today: {TrafficFormatting.Data((ulong)Math.Max(0, todayUsage.Upload))}";
                TodayTotal.Text = TrafficFormatting.Data((ulong)Math.Max(0, todayUsage.Download + todayUsage.Upload));
                MonthTotal.Text = $"{TrafficFormatting.Data((ulong)Math.Max(0, totalDown + totalUp))} so far";
                _lifetime = lifetime;
                UpdateInterfaceList();
                DrawMonthChart(now, usage);
            });
        }
        catch (Exception ex)
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                ErrorText.Text = $"History could not be loaded: {ex.Message}";
                ErrorText.Visibility = Visibility.Visible;
            });
        }
    }

    private void UpdateInterfaceList()
    {
        InterfaceList.ItemsSource = _latest.OrderBy(i => i.Name).Select(rate =>
        {
            var usage = _lifetime.GetValueOrDefault(rate.InterfaceId);
            return new InterfaceDisplayRow(rate.Name, rate.Kind.ToString(), rate.DownloadText, rate.UploadText,
                TrafficFormatting.Data((ulong)Math.Max(0, usage.Download + usage.Upload)));
        }).ToArray();
    }

    private void DrawMonthChart(DateTime month, IReadOnlyDictionary<string, (long Download, long Upload)> usage)
    {
        MonthChart.Children.Clear();
        var days = DateTime.DaysInMonth(month.Year, month.Month);
        var totals = Enumerable.Range(1, days).Select(day =>
        {
            var key = new DateOnly(month.Year, month.Month, day).ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
            return usage.GetValueOrDefault(key);
        }).ToArray();
        var maximum = Math.Max(1L, totals.Max(item => item.Download + item.Upload));

        for (var index = 0; index < days; index++)
        {
            var item = totals[index];
            var availableHeight = 104d;
            var downHeight = Math.Max(0, availableHeight * item.Download / maximum);
            var upHeight = Math.Max(0, availableHeight * item.Upload / maximum);
            var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom, Spacing = 1 };
            if (upHeight > 0) stack.Children.Add(new Border { Height = upHeight, Background = new SolidColorBrush(ColorHelper.FromArgb(255, 56, 164, 131)), CornerRadius = new CornerRadius(3, 3, 0, 0) });
            if (downHeight > 0) stack.Children.Add(new Border { Height = downHeight, Background = new SolidColorBrush(ColorHelper.FromArgb(255, 57, 112, 222)), CornerRadius = new CornerRadius(3, 3, 0, 0) });

            var column = new StackPanel { Width = 20, Height = 132, VerticalAlignment = VerticalAlignment.Bottom, Spacing = 5 };
            var valueArea = new Grid { Height = 108, VerticalAlignment = VerticalAlignment.Bottom };
            valueArea.Children.Add(stack);
            ToolTipService.SetToolTip(valueArea, $"Day {index + 1}: ↓ {TrafficFormatting.Data((ulong)Math.Max(0, item.Download))} · ↑ {TrafficFormatting.Data((ulong)Math.Max(0, item.Upload))}");
            column.Children.Add(valueArea);
            column.Children.Add(new TextBlock { Text = (index + 1).ToString(), FontSize = 10, HorizontalAlignment = HorizontalAlignment.Center, Opacity = 0.55 });
            MonthChart.Children.Add(column);
        }
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        App.Monitor.Updated -= OnMonitorUpdated;
        _historyRefresh.Stop();
        _tray.Dispose();
        _ = App.Monitor.DisposeAsync();
    }
}

internal static class DispatcherQueueExtensions
{
    public static Task EnqueueAsync(this DispatcherQueue dispatcher, Action action)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!dispatcher.TryEnqueue(() =>
        {
            try { action(); completion.SetResult(); }
            catch (Exception ex) { completion.SetException(ex); }
        })) completion.SetException(new InvalidOperationException("The UI dispatcher is shutting down."));
        return completion.Task;
    }
}

internal sealed record InterfaceDisplayRow(string Name, string Kind, string DownloadText, string UploadText, string LifetimeText);
