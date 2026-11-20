using NetworkMonitor.App.Native;
using NetworkMonitor.Core;

namespace NetworkMonitor.App.Monitoring;

internal sealed class NetworkMonitorService : IAsyncDisposable
{
    private readonly IpHelperSnapshotProvider _provider = new();
    private readonly WifiConnectionProvider _wifiProvider = new();
    private readonly CounterRateCalculator _calculator = new(TimeSpan.FromSeconds(15));
    private readonly UsageStore _store;
    private readonly CancellationTokenSource _stop = new();
    private readonly Dictionary<Guid, PendingUsage> _pending = [];
    private readonly Dictionary<Guid, InterfaceSnapshot> _lastSnapshots = [];
    private readonly object _calculatorGate = new();
    private Task? _worker;
    private volatile bool _suspended;
    private readonly object _wifiGate = new();
    private WifiConnectionState? _wifiState;
    private InterfaceRate[] _lastRates = [];

    public event Action<MonitorUpdate>? Updated;

    public NetworkMonitorService(string dataDirectory)
    {
        _store = new UsageStore(Path.Combine(dataDirectory, "usage.db"));
        _wifiState = _wifiProvider.ReadCurrent();
        _wifiProvider.Changed += OnWifiChanged;
    }

    public async Task StartAsync()
    {
        await _store.InitializeAsync(_stop.Token);
        _worker = RunAsync(_stop.Token);
    }

    public void ReportError(string message) => Updated?.Invoke(CreateUpdate([], message));

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(3));
        var lastFlush = System.Diagnostics.Stopwatch.GetTimestamp();
        while (!cancellationToken.IsCancellationRequested)
        {
            if (_suspended)
            {
                try { await timer.WaitForNextTickAsync(cancellationToken); }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
                continue;
            }
            try
            {
                var snapshots = _provider.Capture();
                IReadOnlyList<(InterfaceRate Rate, UsageDelta? Delta)> rates;
                lock (_calculatorGate)
                {
                    if (_suspended) continue;
                    rates = _calculator.Observe(snapshots);
                }
                foreach (var snapshot in snapshots) _lastSnapshots[snapshot.Id] = snapshot;
                foreach (var (rate, delta) in rates)
                {
                    if (delta is null) continue;
                    if (!_pending.TryGetValue(rate.InterfaceId, out var pending))
                        _pending[rate.InterfaceId] = pending = new PendingUsage(delta.StartUtc, delta.EndUtc, 0, 0, delta.Quality);
                    pending.EndUtc = delta.EndUtc;
                    pending.DownloadBytes = checked(pending.DownloadBytes + delta.DownloadBytes);
                    pending.UploadBytes = checked(pending.UploadBytes + delta.UploadBytes);
                    pending.Quality = (InterfaceQuality)Math.Max((int)pending.Quality, (int)delta.Quality);
                }
                var now = System.Diagnostics.Stopwatch.GetTimestamp();
                if (System.Diagnostics.Stopwatch.GetElapsedTime(lastFlush, now) >= TimeSpan.FromSeconds(30))
                {
                    await FlushAsync(cancellationToken);
                    lastFlush = now;
                }
                lock (_wifiGate) _lastRates = rates.Select(r => r.Rate).ToArray();
                Updated?.Invoke(CreateUpdate(_lastRates, null));
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
            catch (Exception ex)
            {
                Updated?.Invoke(CreateUpdate([], ex.Message));
            }

            try { await timer.WaitForNextTickAsync(cancellationToken); }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
        }
        await FlushAsync(CancellationToken.None);
    }

    private void OnWifiChanged(WifiConnectionState? state)
    {
        lock (_wifiGate)
        {
            _wifiState = state;
            Updated?.Invoke(CreateUpdate(_lastRates, null));
        }
    }

    private MonitorUpdate CreateUpdate(IReadOnlyList<InterfaceRate> rates, string? error)
    {
        lock (_wifiGate) return new MonitorUpdate(rates, error, _wifiState?.Ssid, _wifiState?.InterfaceId);
    }

    public void HandlePowerTransition(bool resumed)
    {
        if (!resumed)
        {
            _suspended = true;
            return;
        }
        lock (_calculatorGate)
        {
            _calculator.Reset();
            _suspended = false;
        }
    }

    private async Task FlushAsync(CancellationToken cancellationToken)
    {
        if (_pending.Count == 0) return;
        var records = new List<(InterfaceSnapshot Snapshot, UsageDelta? Delta)>(_pending.Count);
        foreach (var (id, pending) in _pending)
        {
            if (!_lastSnapshots.TryGetValue(id, out var snapshot)) continue;
            records.Add((snapshot, new UsageDelta(id, pending.StartUtc, pending.EndUtc,
                pending.DownloadBytes, pending.UploadBytes, pending.Quality)));
        }
        if (records.Count == 0) return;
        await _store.RecordBatchAsync(records, cancellationToken);
        _pending.Clear();
    }

    public Task<IReadOnlyDictionary<string, (long Download, long Upload)>> GetMonthByDayAsync(DateOnly month, CancellationToken cancellationToken = default) =>
        _store.GetMonthByDayAsync(month, cancellationToken);

    public Task<IReadOnlyDictionary<Guid, (long Download, long Upload)>> GetLifetimeByInterfaceAsync(CancellationToken cancellationToken = default) =>
        _store.GetLifetimeByInterfaceAsync(cancellationToken);

    public async ValueTask DisposeAsync()
    {
        _stop.Cancel();
        _wifiProvider.Dispose();
        if (_worker is not null)
        {
            try { await _worker; } catch (OperationCanceledException) { }
        }
        _stop.Dispose();
    }
}

internal sealed record MonitorUpdate(IReadOnlyList<InterfaceRate> Interfaces, string? Error, string? WifiSsid, Guid? WifiInterfaceId);

internal sealed class PendingUsage(DateTimeOffset startUtc, DateTimeOffset endUtc, ulong downloadBytes, ulong uploadBytes, InterfaceQuality quality)
{
    public DateTimeOffset StartUtc { get; } = startUtc;
    public DateTimeOffset EndUtc { get; set; } = endUtc;
    public ulong DownloadBytes { get; set; } = downloadBytes;
    public ulong UploadBytes { get; set; } = uploadBytes;
    public InterfaceQuality Quality { get; set; } = quality;
}
