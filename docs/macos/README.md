# macOS implementation

This document describes the Swift application at the repository root. Start with the [repository README](../../README.md) for both platform targets.

## Requirements

- macOS 13 or later
- Swift 6 toolchain (Xcode or Command Line Tools)

## Build and run

```sh
./BuildApp.sh
open "build/WiFi Monitor.app"
```

To build without creating an app bundle, run `swift build`. The app appears in the menu bar; select **Open Dashboard** for the larger view. Settings are available from the app's standard Settings scene where supported by the host app.

Run `swift run WiFiMonitorChecks` for checks of counter deltas and resets, scope-separated daily persistence, restart persistence, and rate unit formatting.

## Measurement and privacy

The monitor samples macOS `NET_RT_IFLIST2` interface records and uses their 64-bit byte counters when available. If that snapshot cannot be read, it falls back to `getifaddrs()` 32-bit counters and shows a dashboard notice. Rates use monotonic elapsed time. Wi-Fi mode includes interfaces CoreWLAN reports as Wi-Fi. All interfaces mode sums visible non-loopback interface counters; VPNs, bridges, and virtual adapters can overlap and may therefore double-count. These are interface byte counts, not provider-billed usage or application payload counts.

Daily totals are accumulated locally in SQLite under `~/Library/Application Support/WiFi Monitor/usage.sqlite`, separately for Wi-Fi, all interfaces, and each manually selected interface. The Wi-Fi Networks section shows per-name lifetime and current-day totals. Per-network traffic is recorded only when the observed SSID stays stable across a counter interval; intervals around detected network changes are omitted from per-network totals. Identical SSIDs are grouped, so these summaries are not proof of a unique physical network. The monthly chart shows one download/upload bar pair per calendar day; the yearly view groups usage by month. The dashboard also compares calendar weeks and months and exports daily totals for the selected scope to CSV. Download/upload peaks and averages are shown for the current app session. Writes are batched for approximately 15 seconds, so force-quit can lose the pending interval.

Settings include Wi-Fi, all-interface, or manually selected interface monitoring; a 2, 5, or 10 second sample interval; menu bar display; optional daily/weekly/monthly limits; configurable notification percentages; and launch at login. On first run, launch at login is enabled to match the background-monitoring workflow; macOS may require approval in System Settings. Closing the dashboard keeps the menu bar monitor running. Choose Quit from the menu bar to stop monitoring; the login item starts it again at the next sign-in. Notifications are evaluated alongside samples, at most once per minute, and use macOS notification permission. Set a limit to 0 to disable that period's limit.

Wi-Fi network names are obtained through CoreWLAN when available and may be unavailable in some system or privacy states. The app stores those names locally in its usage database. No privileged helper is installed. Monitoring stops across system sleep and takes a new counter baseline after wake; traffic during app downtime cannot be reconstructed. Counter resets and sampling gaps are surfaced as measurement notices when detected.

## Architecture

- `NetworkInterfaceManager`: obtains CoreWLAN Wi-Fi names and 64-bit BSD route-list counters, with a marked 32-bit fallback.
- `MonitorModel` / `NetworkMonitoringEngine`: samples on a utility queue, handles path and sleep/wake changes, and publishes the latest snapshot.
- `UsageStore`: stores daily download/upload totals in SQLite.
- `WiFiMonitorApp`: native SwiftUI menu bar, dashboard, and settings UI.

The default sampling interval is five seconds with one second timer leeway. Sampling rates are configurable at 2, 5, or 10 seconds. The monitor has no packet capture path. A short idle sample is recorded in [BENCHMARK.md](BENCHMARK.md); it is not a sustained battery or long-duration profile.

The Swift package targets macOS 13 for `MenuBarExtra`. The app bundle is assembled by `BuildApp.sh`; signing is ad hoc for local execution and is not suitable for distribution. See [PUBLISHING_CHECKLIST.md](PUBLISHING_CHECKLIST.md) for release blockers.
