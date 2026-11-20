namespace NetworkMonitor.Core;

public enum InterfaceKind { WiFi, Ethernet, Bluetooth, Tunnel, Loopback, Other }
public enum InterfaceQuality { Direct, Reconciled, Estimated, Unattributed, Invalid }

public sealed record InterfaceSnapshot(
    Guid Id,
    ulong Luid,
    uint Index,
    string Name,
    string Description,
    InterfaceKind Kind,
    bool IsHardware,
    bool IsOperational,
    bool IsMediaConnected,
    ulong ReceivedBytes,
    ulong SentBytes,
    DateTimeOffset CapturedAtUtc,
    long MonotonicTicks);

public sealed record InterfaceRate(
    Guid InterfaceId,
    string Name,
    InterfaceKind Kind,
    bool IsHardware,
    bool IsOperational,
    double DownloadBytesPerSecond,
    double UploadBytesPerSecond,
    ulong ReceivedBytes,
    ulong SentBytes,
    InterfaceQuality Quality,
    DateTimeOffset CapturedAtUtc)
{
    public string DownloadText => TrafficFormatting.Rate(DownloadBytesPerSecond);
    public string UploadText => TrafficFormatting.Rate(UploadBytesPerSecond);
}

public sealed record UsageDelta(
    Guid InterfaceId,
    DateTimeOffset StartUtc,
    DateTimeOffset EndUtc,
    ulong DownloadBytes,
    ulong UploadBytes,
    InterfaceQuality Quality);

public static class TrafficFormatting
{
    public static string Rate(double bytesPerSecond)
    {
        if (!double.IsFinite(bytesPerSecond) || bytesPerSecond < 0) bytesPerSecond = 0;
        string[] units = ["B/s", "KB/s", "MB/s", "GB/s"];
        var value = bytesPerSecond;
        var unit = 0;
        while (value >= 1000 && unit < units.Length - 1) { value /= 1000; unit++; }
        return $"{value:0.0} {units[unit]}";
    }

    public static string Data(ulong bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        double value = bytes;
        var unit = 0;
        while (value >= 1000 && unit < units.Length - 1) { value /= 1000; unit++; }
        return $"{value:0.##} {units[unit]}";
    }
}
