# Publishing readiness

## Current status

The project builds as a native SwiftUI macOS app and has local, passive interface monitoring, a menu bar surface, daily aggregates, Wi-Fi-name summaries, export, and user settings. It is suitable for continued development and local evaluation. It is **not yet ready for commercial publication**.

## Release blockers

- Replace `com.local.wifimonitor` with a bundle identifier owned by the publisher. Set the final publisher name, copyright, support URL, privacy-policy URL, and release version. The current icon is a first-party placeholder and should be approved or replaced with final brand artwork.
- Sign with the publisher's Developer ID certificate, enable Hardened Runtime, notarize the final artifact, and verify Gatekeeper installation on a clean Mac. The current build script signs ad hoc for local use.
- Decide whether distribution is direct-only or also Mac App Store. Validate CoreWLAN SSID access and `NET_RT_IFLIST2` counter access under the final sandbox, entitlement, and signing configuration. Do not assume the local build proves sandbox compatibility.
- Exercise 64-bit counter parsing against actual Wi-Fi, Ethernet, VPN, bridge, and virtual-interface traffic on each supported macOS release. Confirm resets, interface removal, sleep/wake, and high-throughput transfers. The 32-bit `getifaddrs()` fallback is explicitly lower confidence.
- Review the measurement labels with real traffic: the system total is selected interface traffic, not internet-only or provider-billed usage. Network summaries are grouped by SSID. Identical SSIDs can represent different networks, and intervals crossing an SSID change are omitted from those summaries.
- Run persistence and migration checks against existing user databases, interruption/force-quit scenarios, disk-full conditions, backup/restore, and timezone changes. Current usage history is local-calendar daily data; it does not provide an exact reconstruction of times when the app was not observing.
- Complete a real hardware test matrix for every supported CPU architecture and macOS version. Establish sustained CPU, memory, wakeup, energy, and disk-write baselines with monitoring on and off. The short sample in `BENCHMARK.md` is not sufficient for release claims.
- Review onboarding, accessibility, privacy disclosures, diagnostics, data deletion, and customer support content. The app currently has no commercial update, support, or release-signing workflow.

## Before each candidate release

1. Run the unit and integration checks, including the counter parser and database migration scenarios.
2. Build release artifacts for every supported architecture and verify their signatures.
3. Validate installation, first launch, upgrade, launch-at-login, sleep/wake, and uninstall on clean user accounts.
4. Inspect the final app bundle and exported diagnostics for identifiers, SSIDs, and other local network information.
5. Attach the benchmark environment and raw results to the release record; do not turn targets into performance claims without measurements.
