namespace NetworkMonitor.Core;

/// <summary>Turns cumulative interface counters into rates. Counter discontinuities begin a fresh baseline.</summary>
public sealed class CounterRateCalculator(TimeSpan maximumAttributableGap)
{
    private readonly Dictionary<Guid, InterfaceSnapshot> _previous = [];
    private readonly TimeSpan _maximumAttributableGap = maximumAttributableGap;

    public IReadOnlyList<(InterfaceRate Rate, UsageDelta? Delta)> Observe(IReadOnlyList<InterfaceSnapshot> current)
    {
        var results = new List<(InterfaceRate, UsageDelta?)>(current.Count);
        var seen = new HashSet<Guid>();

        foreach (var now in current)
        {
            if (!seen.Add(now.Id)) continue;
            if (!_previous.TryGetValue(now.Id, out var before))
            {
                _previous[now.Id] = now;
                results.Add((CreateRate(now, 0, 0, InterfaceQuality.Unattributed), null));
                continue;
            }

            _previous[now.Id] = now;
            var elapsedTicks = now.MonotonicTicks - before.MonotonicTicks;
            if (elapsedTicks <= 0 || now.ReceivedBytes < before.ReceivedBytes || now.SentBytes < before.SentBytes)
            {
                results.Add((CreateRate(now, 0, 0, InterfaceQuality.Invalid), null));
                continue;
            }

            var elapsed = TimeSpan.FromSeconds((double)elapsedTicks / System.Diagnostics.Stopwatch.Frequency);
            var received = now.ReceivedBytes - before.ReceivedBytes;
            var sent = now.SentBytes - before.SentBytes;
            var quality = elapsed > _maximumAttributableGap ? InterfaceQuality.Unattributed : InterfaceQuality.Direct;
            var rate = CreateRate(now,
                quality == InterfaceQuality.Direct ? received / elapsed.TotalSeconds : 0,
                quality == InterfaceQuality.Direct ? sent / elapsed.TotalSeconds : 0,
                quality);
            // The interface counter delta remains useful even after a long sampling gap, but it
            // must not be treated as an instantaneous speed or attributed to a network session.
            var delta = new UsageDelta(now.Id, before.CapturedAtUtc, now.CapturedAtUtc, received, sent, quality);
            results.Add((rate, delta));
        }

        foreach (var missing in _previous.Keys.Except(seen).ToArray()) _previous.Remove(missing);
        return results;
    }

    public void Reset() => _previous.Clear();

    private static InterfaceRate CreateRate(InterfaceSnapshot s, double rx, double tx, InterfaceQuality quality) =>
        new(s.Id, s.Name, s.Kind, s.IsHardware, s.IsOperational, rx, tx, s.ReceivedBytes, s.SentBytes, quality, s.CapturedAtUtc);
}
