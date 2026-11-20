# WiFi Tracking App

Two native desktop implementations live in this repository:

| Platform | Project | Status |
|---|---|---|
| macOS | Swift + SwiftUI in `Sources/` | Local development app with menu bar monitoring, dashboard, history, and settings. Distribution still needs signing, notarization, and hardware validation. |
| Windows | C# + .NET 10 + WinUI 3 in [`Windows/`](Windows/) | Early Windows 11 implementation slice. It is not release-ready; per-Wi-Fi historical attribution and Windows build/device validation are outstanding. |

Both implementations use passive operating-system interface counters. They do not inspect packet contents or send collected usage statistics to a service. Network interface counters are not guaranteed to match an ISP's billable totals, and virtual/VPN layers may overlap.

## macOS

Requirements: macOS 13 or later and Swift 6.

```sh
swift run WiFiMonitorChecks
./BuildApp.sh
open "build/WiFi Monitor.app"
```

The macOS app stores its local usage database in `~/Library/Application Support/WiFi Monitor/usage.sqlite`. See [`docs/macos/README.md`](docs/macos/README.md) for measurement behavior and development details.

## Windows

Requirements: Windows 11, .NET 10 SDK, Windows App SDK 2.7, Visual Studio/MSBuild, and MSIX tooling. Windows 10 is not currently a supported target in this implementation.

```powershell
cd .\Windows
dotnet restore .\NetworkMonitor.sln
dotnet build .\NetworkMonitor.sln -c Debug -p:Platform=x64
dotnet test .\tests\NetworkMonitor.Core.Tests\NetworkMonitor.Core.Tests.csproj
```

For ARM64, use `-p:Platform=ARM64`. Windows usage data is stored per user under `%LOCALAPPDATA%\NetworkMonitor\usage.db`. See [`Windows/README.md`](Windows/README.md) for current scope and limitations.

## Documentation

- [macOS technical research](docs/macos/PHASE1-RESEARCH.md)
- [macOS publishing checklist](docs/macos/PUBLISHING_CHECKLIST.md)
- [macOS benchmark notes](docs/macos/BENCHMARK.md)
- [Windows feasibility and architecture](docs/windows/PHASE1-RESEARCH.md)

The benchmark file is a short historical macOS sample, not a sustained performance claim. No Windows benchmark has been recorded.
