using NetworkMonitor.Core;
using Xunit;

namespace NetworkMonitor.Core.Tests;

public sealed class CounterRateCalculatorTests
{
    private static readonly Guid AdapterId = Guid.Parse("c134dc71-3857-4cde-9ac7-a1bd491d82ee");

    [Fact]
    public void FirstObservationEstablishesBaselineWithoutInventingUsage()
    {
        var calculator = new CounterRateCalculator(TimeSpan.FromSeconds(15));
        var result = calculator.Observe([Snapshot(100, 200, 0)]).Single();

        Assert.Null(result.Delta);
        Assert.Equal(0, result.Rate.DownloadBytesPerSecond);
        Assert.Equal(InterfaceQuality.Unattributed, result.Rate.Quality);
    }

    [Fact]
    public void ComputesReceiveAndSendRatesFromCounterDeltas()
    {
        var calculator = new CounterRateCalculator(TimeSpan.FromSeconds(15));
        calculator.Observe([Snapshot(1_000, 2_000, 0)]);

        var result = calculator.Observe([Snapshot(5_000, 4_000, 2 * System.Diagnostics.Stopwatch.Frequency)]).Single();

        Assert.Equal(2_000, result.Rate.DownloadBytesPerSecond);
        Assert.Equal(1_000, result.Rate.UploadBytesPerSecond);
        Assert.Equal((ulong)4_000, result.Delta!.DownloadBytes);
        Assert.Equal((ulong)2_000, result.Delta.UploadBytes);
        Assert.Equal(InterfaceQuality.Direct, result.Delta.Quality);
    }

    [Fact]
    public void CounterDecreaseIsInvalidAndCannotProduceNegativeSpeed()
    {
        var calculator = new CounterRateCalculator(TimeSpan.FromSeconds(15));
        calculator.Observe([Snapshot(5_000, 8_000, 0)]);

        var result = calculator.Observe([Snapshot(20, 30, System.Diagnostics.Stopwatch.Frequency)]).Single();

        Assert.Null(result.Delta);
        Assert.Equal(InterfaceQuality.Invalid, result.Rate.Quality);
        Assert.Equal(0, result.Rate.DownloadBytesPerSecond);
        Assert.Equal(0, result.Rate.UploadBytesPerSecond);
    }

    [Fact]
    public void LongSamplingGapKeepsInterfaceDeltaButMarksItUnattributed()
    {
        var calculator = new CounterRateCalculator(TimeSpan.FromSeconds(15));
        calculator.Observe([Snapshot(100, 200, 0)]);

        var result = calculator.Observe([Snapshot(1_100, 700, 20 * System.Diagnostics.Stopwatch.Frequency)]).Single();

        Assert.Equal(InterfaceQuality.Unattributed, result.Rate.Quality);
        Assert.Equal(0, result.Rate.DownloadBytesPerSecond);
        Assert.Equal((ulong)1_000, result.Delta!.DownloadBytes);
        Assert.Equal((ulong)500, result.Delta.UploadBytes);
        Assert.Equal(InterfaceQuality.Unattributed, result.Delta.Quality);
    }

    [Theory]
    [InlineData(1_000, "1.0 KB/s")]
    [InlineData(1_000_000, "1.0 MB/s")]
    public void FormatsRatesUsingDecimalUnits(double value, string expected) =>
        Assert.Equal(expected, TrafficFormatting.Rate(value));

    private static InterfaceSnapshot Snapshot(ulong received, ulong sent, long ticks) => new(
        AdapterId, 1, 1, "Wi-Fi", "Test adapter", InterfaceKind.WiFi, true, true, true,
        received, sent, DateTimeOffset.UnixEpoch.AddSeconds((double)ticks / System.Diagnostics.Stopwatch.Frequency), ticks);
}
