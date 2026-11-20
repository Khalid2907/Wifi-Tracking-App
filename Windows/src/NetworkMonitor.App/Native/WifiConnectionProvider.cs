using Windows.Networking.Connectivity;

namespace NetworkMonitor.App.Native;

internal sealed class WifiConnectionProvider : IDisposable
{
    private bool _disposed;
    public event Action<WifiConnectionState?>? Changed;

    public WifiConnectionProvider()
    {
        NetworkInformation.NetworkStatusChanged += OnNetworkStatusChanged;
    }

    public WifiConnectionState? ReadCurrent()
    {
        try
        {
            var profiles = NetworkInformation.GetConnectionProfiles()
                .Where(profile => profile.IsWlanConnectionProfile)
                .Select(profile => (Profile: profile, Level: profile.GetNetworkConnectivityLevel()))
                .Where(item => item.Level != NetworkConnectivityLevel.None)
                .OrderByDescending(item => item.Level)
                .ToArray();

            if (profiles.Length == 0) return null;
            var selected = profiles[0].Profile;
            var ssid = selected.WlanConnectionProfileDetails.GetConnectedSsid();
            if (string.IsNullOrWhiteSpace(ssid)) return null;
            return new WifiConnectionState(ssid, selected.NetworkAdapter.NetworkAdapterId, DateTimeOffset.UtcNow);
        }
        catch (Exception)
        {
            // SSID is optional context. Counter monitoring continues if Windows does not expose it.
            return null;
        }
    }

    private void OnNetworkStatusChanged(object sender) => Changed?.Invoke(ReadCurrent());

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        NetworkInformation.NetworkStatusChanged -= OnNetworkStatusChanged;
    }
}

internal sealed record WifiConnectionState(string Ssid, Guid InterfaceId, DateTimeOffset ObservedUtc);
