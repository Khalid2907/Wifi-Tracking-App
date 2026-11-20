# Network Monitor for Windows

Windows implementation lives in this directory and is separate from the macOS Swift application at the repository root.

## Current implementation slice

- WinUI 3 dashboard shell with live receive/send rates per interface.
- Passive counters from Windows IP Helper `GetIfTable2` / `MIB_IF_ROW2`.
- Counter reset and sampling-gap handling using monotonic elapsed time.
- Hardware Wi-Fi/Ethernet aggregate; virtual and tunnel interfaces remain separately visible.
- SQLite interface metadata and hourly usage aggregates, written in batches.
- Month-to-date chart grouped by local calendar day.
- Native Windows notification-area icon, hide-to-tray, restore, and Explorer-restart recovery.
- Suspend/resume baseline reset to avoid counting sleep time as an active sampling interval.
- Connected SSID label via the Windows connection-profile API, without BSSID or scan access.
- Core unit tests for baseline, rates, resets, sampling gaps, and decimal unit formatting.

Per-Wi-Fi-profile history/session attribution, BSSID consent flow, interface-selection settings, notifications, optional widget, complete settings/onboarding, and commercial signing are not implemented yet. The current project targets Windows 11; Windows 10 remains out of scope until the runtime and package are validated on supported Enterprise/LTSC editions. Do not treat the current slice as a releasable product.

## Build environment

Build on Windows 11 with Visual Studio 2026 (or a supported Visual Studio release with the Windows App SDK 2.7 workload), .NET 10 SDK, Windows SDK, and MSIX packaging tools installed. The current development host is macOS and does not have the .NET SDK; Windows build, test, run, packaging, and native interop validation remain outstanding.

```powershell
dotnet restore .\NetworkMonitor.sln
dotnet build .\NetworkMonitor.sln -c Debug -p:Platform=x64
dotnet test .\NetworkMonitor.sln -c Debug -p:Platform=x64
```

Use the `ARM64` solution platform for an ARM64 build. The package manifest has a development publisher identity; replace it with the real code-signing publisher before distributing a signed MSIX. The startup task is declared but is not yet exposed or registered through an in-app preference.

Usage history is stored in the current user's local app data at `%LOCALAPPDATA%\NetworkMonitor\usage.db`. The active SSID is displayed in memory but is not persisted; no BSSID, browsing data, or packet contents are collected. The app uses interface counters that include broadcast and multicast and should not be described as an ISP billing meter.

## Technical design

Read [the Phase 1 feasibility and architecture report](../../docs/windows/PHASE1-RESEARCH.md) for API semantics, compatibility policy, attribution limitations, privacy requirements, and the phased roadmap.
