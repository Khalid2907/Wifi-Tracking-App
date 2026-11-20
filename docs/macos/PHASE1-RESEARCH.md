# Phase 1 — Advanced Network Monitor feasibility and architecture

**Status:** Research findings with follow-on implementation notes. The original assessment was read-only; subsequent user-directed work has changed the application and database schema.

## Executive recommendation

The initial project collector used `getifaddrs()` and interpreted `ifa_data` as `if_data`; in the active macOS SDK, `if_data.ifi_ibytes` and `ifi_obytes` are 32-bit fields. At 1 Gbit/s a 32-bit byte counter can wrap in about 34 seconds; at 10 Gbit/s it can wrap in about 3.4 seconds. The collector has since been changed to prefer `sysctl` with `NET_RT_IFLIST2` and `if_msghdr2`/`if_data64`, falling back to `getifaddrs()` and surfacing that fallback in the dashboard. The 64-bit parser compiles and the app launches locally, but it still requires counter comparisons under high throughput and validation on each supported macOS release before its accuracy is established.

Use the 64-bit per-interface counters in `if_data64`, obtained from the BSD routing interface list (`sysctl` with `NET_RT_IFLIST2` / `if_msghdr2`). Keep the parser isolated behind a counter-provider interface, validate it against supported macOS releases, and retain a clearly marked fallback only if the 64-bit source is unavailable. The current SDK headers define both structures in `net/if_var.h` and `if_msghdr2` in `net/if.h`; these low-level BSD interfaces need integration tests because Apple’s online framework documentation does not describe them as a high-level monitoring API.

Build one engine that records each interface independently. Derive a system total from an explicit set of eligible physical interfaces and known topology relationships. Do not call that total “internet usage” or “provider-billed usage”: interface counters include link-level traffic and local network traffic, and macOS does not expose a passive counter that perfectly attributes all bytes to the public internet. If the interface graph is ambiguous, show the ambiguity and let the user choose interfaces instead of silently claiming a deduplicated total.

## API assessment

| API | Recommended role | Limits |
| --- | --- | --- |
| `sysctl` + `NET_RT_IFLIST2` / `if_msghdr2` | Enumerate current kernel interfaces and read 64-bit byte counters, flags, index, and link metadata in one snapshot. | BSD routing-message parsing is lower-level than a framework API. Validate message lengths, versions, indices, and SDK behavior; never assume names or list order are stable. |
| `getifaddrs()` | Address and basic live-interface discovery; a compatibility fallback and cross-check. | Its `ifa_data` is currently represented by the 32-bit `if_data` structure in the SDK. Do not use that counter as the high-throughput source without explicit wrap handling and validation. |
| System Configuration (`SCNetworkInterfaceCopyAll`, BSD-name/type accessors) | Map configured network services to kernel BSD names and identify configured Wi-Fi, Ethernet, bond, and VLAN interfaces. | Configuration enumeration is not a complete substitute for the live kernel interface list; join by BSD name and keep unmatched kernel interfaces classified as unknown. [`SCNetworkInterfaceCopyAll`](https://developer.apple.com/documentation/systemconfiguration/scnetworkinterfacecopyall%28%29), [`SCNetworkInterfaceGetBSDName`](https://developer.apple.com/documentation/systemconfiguration/scnetworkinterfacegetbsdname%28_%3A%29) |
| System Configuration bond/VLAN APIs | Resolve known parent/member relationships before aggregation. | Expose useful relationships for configured bonds and VLANs, but do not establish a universal parent graph for every VPN, bridge, container, or third-party virtual device. [`SCNetworkConfiguration`](https://developer.apple.com/documentation/systemconfiguration/scnetworkconfiguration) |
| `NWInterface` / `NWPathMonitor` | Classify path interface type, observe path availability and connectivity changes. | `NWInterface.InterfaceType.other` intentionally includes virtual or unknown types; path monitoring is not a byte counter and is not a complete inventory of traffic. [`InterfaceType`](https://developer.apple.com/documentation/network/nwinterface/interfacetype), [`NWPathMonitor`](https://developer.apple.com/documentation/network/nwpathmonitor) |
| CoreWLAN | Identify Wi-Fi interfaces and observe Wi-Fi state/events. Reuse one long-lived `CWWiFiClient`. | Apple describes the client as heavy. Keep it out of the sampling loop; refresh its inventory on events or at a slow reconciliation interval. SSID access is optional and has additional privacy/entitlement considerations. [`CoreWLAN`](https://developer.apple.com/documentation/CoreWLAN), [`CWWiFiClient`](https://developer.apple.com/documentation/corewlan/cwwificlient) |
| `SCDynamicStore` | Receive configuration changes and trigger interface rediscovery. | Treat notifications as invalidation signals, then rebuild a coherent snapshot; do not depend on a single notification representing every hardware transition. [`SCDynamicStore`](https://developer.apple.com/documentation/systemconfiguration/scdynamicstore-gb2) |
| `NSWorkspace` sleep/wake notifications | Flush pending aggregates before sleep; take fresh counter and identity baselines on wake. | There is no sampling while the machine sleeps. Do not convert a sleep gap into a speed estimate. [`didWakeNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification) |
| `SMAppService.mainApp` | Optional user-approved launch at login for a menu-bar utility. | Keeps the app available in the user session; it is not a privileged always-on system daemon and cannot guarantee observation through logout, force quit, or termination. [`SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice) |

`MenuBarExtra` is available for a macOS 13+ deployment. A floating panel can use AppKit `NSPanel` with SwiftUI hosted content; the panel is presentation only and must subscribe to the same state publisher as the dashboard and menu extra. [`MenuBarExtra`](https://developer.apple.com/documentation/swiftui/menubarextra)

## Interface detection and identity

1. **Enumerate live interfaces** from the 64-bit route/interface snapshot. Use the interface index only as a live lookup key; it can change after detach, reboot, or reconfiguration.
2. **Enrich classifications** by joining System Configuration and CoreWLAN records to BSD names. Use kernel flags and link type to identify loopback and point-to-point/tunnel-like links. Use explicit System Configuration relationships for bonds and VLANs.
3. **Resolve physical status conservatively.** Wi-Fi and configured Ethernet are strong categories; configured bond/VLAN and PPP/IPsec are logical categories. Use I/O Registry hardware ancestry as an additional physical-device signal only after verifying it across supported hardware. A name prefix such as `en0`, `utun`, or `bridge` is not a durable identity or sufficient classifier. Put unknowns in an “Other / needs review” category and exclude them from the default aggregate until a user selects them.
4. **Maintain identity confidence.** Prefer an OS service identifier or verified hardware-registry path where available; retain BSD name, interface index, link type, and a locally stored hardware-address fingerprint as matching evidence, not as the identity itself. MAC addresses can be private/randomized and interface indices/names can be reused. When evidence is insufficient, create a new interface lifetime rather than merging unrelated devices. Record `identityConfidence` and any re-identification decision.
5. **Track interface state and sessions.** Combine kernel `UP`/`RUNNING` state, path events, CoreWLAN events, and sampled counter presence. A session begins when a monitored interface becomes usable and ends on a confirmed disconnect/removal; gaps and app downtime remain explicit. Connection duration is observed duration, not a claim about periods the app did not observe.

The current SDK’s `NWInterface.InterfaceType` categories are useful for path context but insufficient to prove that an interface is physical: `other` includes virtual and unknown networks. System Configuration exposes bond member and VLAN physical-parent queries, which gives a reliable exclusion rule for those known topologies, but not for every third-party virtual interface.

## Traffic accounting and aggregation

- Keep raw per-interface received/transmitted counters and deltas as the measurement truth. Calculate rate from the 64-bit delta divided by `ContinuousClock` elapsed time. Store the byte delta unsmoothed; smooth only the displayed rate.
- Treat a counter decrease as reset/replacement unless the provider documents a fixed-width wrap. The 64-bit source makes wrap practically remote. Record a reset and start a new baseline; do not emit a negative delta.
- On process restart, a prior counter baseline may be reconciled only when boot identity, interface identity, and monotonic counter continuity all match. Attribute the recovered delta to a **gap interval**, not to fabricated per-minute samples. If the device rebooted, the interface changed, or counters decreased, mark the interval unobserved.
- Exclude loopback and logical interfaces from the default physical aggregate. Where a bond or VLAN is selected, aggregate its logical counter or its physical member counters according to one documented policy, never both for the same traffic. Preserve individual counters for interface cards even when they are omitted from the aggregate.
- For uncertain bridges, VPNs, containers, or third-party adapters, do not guess a deduplication multiplier. Exclude them by default, expose their independent stats, and let the user add them to a custom set. Set an aggregate quality flag when topology is incomplete.
- Define “System aggregate” as **the sum of interface byte counters for the selected eligible interface set**, with the exact membership and overlap status visible. It is not internet-only, application payload, or provider-billed usage. `NWPathMonitor` can describe an available path but cannot convert interface counters into internet-only traffic.

## Recommended modules and data flow

```text
SCDynamicStore / CoreWLAN / NWPathMonitor
                   │ change events
                   ▼
NetworkInterfaceManager ──► CounterProvider (64-bit sysctl snapshot)
                   │ InterfaceSnapshot[]
                   ▼
NetworkMonitoringEngine actor
   ├── counter deltas, rates, reset/gap quality
   ├── bounded SamplingBuffer (rates, peaks, session view)
   └── TrafficAggregationEngine (explicit set + topology rules)
                   │ one MonitorSnapshot stream
       ┌───────────┼──────────────┐
       ▼           ▼              ▼
 Dashboard     MenuBarExtra    Optional NSPanel widget
                   │
                   ▼ batched aggregate writes
             HistoricalDataStore actor (SQLite)
```

`NetworkMonitoringEngine` has no SwiftUI dependency and owns the only counter sampler. Interface discovery and counter reading are separate protocols so low-level API changes and test fixtures do not leak into presentation. `SamplingBuffer` is a bounded ring per interface, sized by duration (default 15 minutes; user range 5–30 minutes), not an unbounded array. The three presentation surfaces consume a common immutable snapshot stream. UI delivery is demand-aware: the menu bar updates only with sampled values; dashboard and widget subscriptions stop rendering while hidden.

## Database proposal

Use a versioned SQLite schema with integer byte values, UTC epoch boundaries, foreign keys, and query indexes. Batch writes in one transaction on an aggregate cadence (for example, every 60 seconds and at sleep/clean shutdown); never persist each 2–5 second speed sample.

```sql
interfaces(
  interface_id TEXT PRIMARY KEY,
  stable_key TEXT,
  last_bsd_name TEXT NOT NULL,
  display_name TEXT,
  interface_type TEXT NOT NULL,
  topology_parent_id TEXT,
  identity_confidence TEXT NOT NULL,
  first_seen_utc INTEGER NOT NULL,
  last_seen_utc INTEGER NOT NULL
)

usage_buckets(
  interface_id TEXT NOT NULL,
  resolution TEXT NOT NULL,          -- five_minute, hour, day, month, year
  start_utc INTEGER NOT NULL,
  end_utc INTEGER NOT NULL,
  timezone_id TEXT,                  -- present for calendar buckets
  local_period_key TEXT,
  downloaded_bytes INTEGER NOT NULL,
  uploaded_bytes INTEGER NOT NULL,
  peak_down_bps REAL,
  peak_up_bps REAL,
  observed_seconds INTEGER NOT NULL,
  quality_flags INTEGER NOT NULL,
  PRIMARY KEY(interface_id, resolution, start_utc)
)

aggregate_sets(
  aggregate_set_id TEXT PRIMARY KEY, -- hash/version of policy and member IDs
  policy TEXT NOT NULL,
  created_utc INTEGER NOT NULL,
  overlap_status TEXT NOT NULL
)

aggregate_buckets(
  aggregate_set_id TEXT NOT NULL,
  resolution TEXT NOT NULL,
  start_utc INTEGER NOT NULL,
  end_utc INTEGER NOT NULL,
  downloaded_bytes INTEGER NOT NULL,
  uploaded_bytes INTEGER NOT NULL,
  quality_flags INTEGER NOT NULL,
  PRIMARY KEY(aggregate_set_id, resolution, start_utc)
)

sessions(
  session_id TEXT PRIMARY KEY,
  interface_id TEXT NOT NULL,
  start_utc INTEGER NOT NULL,
  end_utc INTEGER,
  downloaded_bytes INTEGER NOT NULL,
  uploaded_bytes INTEGER NOT NULL,
  quality_flags INTEGER NOT NULL
)
```

Index bucket lookups by `(resolution, start_utc)` and `(interface_id, resolution, start_utc)`. Use SQLite transactions for batched upserts, `PRAGMA integrity_check` for diagnostics, and SQLite’s backup API for consistent backups while WAL is active. Do not copy only the main database file while WAL writes are pending.

**Retention/resolution:** Keep five-minute aggregate bins for the recent 90 days to support local-day re-bucketing after timezone changes; roll older data into daily UTC-bounded calendar records with the timezone ID used when finalized. Preserve daily indefinitely, and materialize monthly/yearly summaries as derived, rebuildable records. Keep hourly records only for the recent 13 months if query needs justify them. Do not keep permanent raw samples. This meets “unlimited aggregate history” while bounding fine-grained storage. Clearly mark that old finalized daily rows remain attributed to the recorded timezone; changing the reporting zone cannot split those already-coarsened records exactly.

`quality_flags` should distinguish normal observed deltas, counter reset, interface identity uncertain, interval gap, counter source fallback, and possible topology overlap. `observed_seconds` lets averages exclude unobserved gaps instead of treating them as zero traffic.

## Time and lifecycle policy

- Use UTC integer timestamps for all intervals. Use `ContinuousClock` for elapsed speed calculations; do not use wall-clock time for a rate denominator.
- For local calendar reporting, persist the IANA timezone identifier and UTC start/end boundaries associated with each finalized daily/monthly bucket. Recompute recent views from fine-grained UTC buckets when the user changes timezone; retain older daily labels in their recorded timezone rather than silently shifting historical usage.
- Use one configurable counter interval, initially 5 seconds (supported range 2–10 seconds), with timer leeway. This is distinct from UI refresh frequency. A closed dashboard has no view timer. Do not enumerate CoreWLAN or System Configuration on each sample.
- Event sources invalidate interface snapshots; rescan on configuration/interface events and perform a slow reconciliation (for example, every 1–5 minutes). Use `NWPathMonitor` for path events, not counters.
- On sleep, flush the transaction and stop scheduled work; on wake, re-enumerate and establish a fresh baseline before calculating rates. A same-boot monotonic counter delta can recover total bytes across a gap but cannot honestly recreate their minute-by-minute distribution.
- Stay in the user process. Offer `SMAppService.mainApp` launch-at-login as an explicit option. Do not add a LaunchDaemon. If the user quits, logs out, or force-quits the app, observation stops; document gaps and only reconcile totals when continuity is provable.

## Privacy and permissions

All counter collection and storage stays local. Do not inspect packet payloads or add a network extension/privileged helper. App Sandbox and distribution signing need a separate compatibility test for the chosen BSD sysctl route-list read and CoreWLAN calls; CoreWLAN’s client-vended interface objects are the sandbox-safe path Apple documents. Request notification permission only when alerts are enabled. SSID is optional and should not be required for traffic tracking.

## Performance plan

- One 5-second counter task for all interfaces; no per-interface timers.
- Read a single 64-bit interface snapshot per sample. Cache enrichment/classification until an interface event or slow reconciliation.
- Compute per-interface deltas once, then aggregate from those deltas. Publish one value snapshot per sample, not one UI mutation per field.
- Keep 5–30 minutes of temporary rates in bounded rings. Load historical data on demand and page by indexed time range.
- Batch database updates (target one transaction per minute under traffic); flush on sleep/clean shutdown. No disk write for every sample.
- Profile the release app with Instruments Time Profiler, Allocations, and Energy Log, then compare monitoring enabled versus disabled for the same workload. Record machine, OS, sampling interval, duration, active traffic, UI state, baseline, median/peak CPU, memory, write count, and wakeups. Existing short idle readings are not a valid baseline or proof of negligible energy impact.

## Technical limits and decisions to validate

1. The 64-bit sysctl route-list format is low-level. The workspace now uses it as the primary source, but its parser, high-throughput counter behavior, and sandbox behavior must be verified on every supported macOS line before rollout.
2. There is no universal public classification API that proves every live interface is a physical device or identifies every bridge/VPN/container parent relationship. Use conservative classification, explicit topology where System Configuration provides it, and transparent “unknown/possible overlap” status.
3. Passive interface counters are not internet-only or provider-billing counters; local LAN and protocol bytes can be included.
4. Connection duration and session history are exact only while observed. Restart reconciliation can recover aggregate bytes under same-boot continuity, not missing timing detail.
5. Calendar summaries after coarsening retain their original timezone attribution. Fine recent buckets can be reinterpreted; old daily totals cannot be split perfectly after a timezone change.
6. App Store sandboxing, notarization, and login-item behavior require verification with a signed distribution build. The current workspace uses SwiftPM and an ad-hoc local app bundle, not a distribution-ready signed Xcode project.
7. Existing history is daily and scope-based, and cannot be truthfully converted into independent per-interface history. Preserve it as legacy history with unknown attribution/measurement confidence.

## Phased implementation plan

1. **Validate architecture/API assumptions:** prototype the 64-bit interface snapshot; compare counters against macOS tools on Wi-Fi, Ethernet, simultaneous links, a bond/VLAN, VPN, and a high-throughput transfer. Verify sandbox behavior and interface metadata across the supported OS range.
2. **Monitoring MVP:** create interface identity/classification, 64-bit counter provider, per-interface rates and byte deltas, explicit aggregation membership, reset/gap validity, and event-driven discovery. No new dashboard work until accounting passes the prototype checks.
3. **Persistence:** version and migrate SQLite; preserve existing daily data as legacy; implement five-minute/hour/day aggregates, UTC boundaries, quality flags, transactions, integrity checking, and backup/restore.
4. **Shared state and menu bar:** make menu bar and dashboard consume the single engine; implement per-interface cards, selected-set aggregate, and indexed history charts.
5. **Sessions and advanced settings:** connection event history, limits, notifications, CSV, startup setting, and data management.
6. **Optional floating widget:** add a single-window `NSPanel` presentation that consumes the shared snapshot; suspend its rendering while hidden.
7. **Profiling and validation:** expand counter/classifier/aggregation/timezone/migration tests, perform hardware/network integration tests, profile against a disabled baseline, and publish only measured resource results.

## Existing project baseline

The workspace currently contains a SwiftPM macOS 13 app, a menu bar/dashboard UI, a monitor model, a SQLite daily store, and an executable check harness. It uses 64-bit route-list counters when available, monotonic elapsed time for rates, visible counter-source/reset/gap notices, daily download/upload charts, and per-SSID-name aggregates. Per-network records remain SSID-based and do not use BSSID-safe access-point identities, profile management, attribution-confidence records, or boundary event sessions. The app also lacks a topology graph, multi-resolution permanent aggregates, background database worker, floating widget, and complete recovery/backup features. It remains a development prototype rather than a commercial release.

## Review gate

Recommended decisions for review: (1) keep the 64-bit `NET_RT_IFLIST2` snapshot as primary only after integration validation; (2) define all-interface totals as selected, classified physical-link counters with explicit overlap confidence; and (3) retain five-minute buckets for 90 days, then daily aggregates indefinitely with recorded timezone attribution. Current local implementation changes do not validate those release decisions.

## Per-Wi-Fi-network attribution extension

### Feasibility and API roles

CoreWLAN exposes the current Wi-Fi interface state and network properties, including SSID, BSSID, and supported security information. Its event delegate can report link, SSID, and BSSID changes. Subscribe to only those relevant events with one long-lived `CWWiFiClient`; treat each callback as an invalidation signal and immediately re-read the interface state. Do not subscribe to scan-cache or link-quality events for usage accounting. Apple documents `bssidDidChange`, `ssidDidChange`, and `linkDidChange` as separate event types and delegate callbacks ([`CWEventDelegate`](https://developer.apple.com/documentation/corewlan/cweventdelegate), [`CWEventType.bssidDidChange`](https://developer.apple.com/documentation/corewlan/cweventtype/bssiddidchange), [`CWEventType.linkDidChange`](https://developer.apple.com/documentation/corewlan/cweventtype/linkdidchange), [`CWNetwork`](https://developer.apple.com/documentation/corewlan/cwnetwork)).

`NWPathMonitor` can add path availability/interface context, but it does not identify which packets belong to a Wi-Fi network and does not supply byte counters. The per-interface counter provider remains the source of byte deltas. CoreWLAN association events provide timing clues, not packet-level attribution or an exact kernel counter boundary.

### Identity model and privacy

Keep three identities separate: (1) the physical Wi-Fi interface, (2) an access point (BSSID), and (3) a user-managed logical network profile. Give profiles app-generated UUIDs. Treat SSID as a display label and grouping hint only: identical SSIDs and security modes do not prove a shared network. Treat BSSID as an AP identifier, not the profile identity; a BSSID change can be roaming, but could also be a different network with a reused SSID.

Store BSSID only as a keyed HMAC token using a random per-install secret protected by Keychain. Do not use a plain unsalted hash, which is reversible by enumeration of the small BSSID address space. The token permits local repeat matching while avoiding direct BSSID storage. Store SSID locally only as needed for the user-facing label; allow a user alias to replace it. Do not transmit either value. If the Keychain secret is lost, do not attempt to link old and new AP tokens.

Create an unassigned profile candidate when there is insufficient evidence to decide whether an AP belongs to an existing logical network. BSSID roaming can be suggested as a likely match when SSID and security are consistent and the transition is contiguous, but automatically merging it is an inference. Offer user actions to rename, merge, split, or exclude profiles and preserve the mapping audit trail. No public CoreWLAN property supplies a guaranteed stable logical-network identifier across APs. Therefore automatic grouping cannot satisfy both “never merge identical SSIDs incorrectly” and “always merge roaming APs” with certainty; expose confidence and keep ambiguous profiles separate pending user action.

### Attribution and transition policy

The `NetworkTrafficAttributionEngine` consumes the shared counter snapshots and CoreWLAN events; it does not poll separately. For each Wi-Fi interface:

1. Keep the last counter snapshot with both UTC wall time and a monotonic timestamp, plus the last resolved profile/AP identity.
2. On link, SSID, BSSID, sleep/wake, or interface-lifecycle events, take a counter snapshot and re-read CoreWLAN state promptly.
3. Close the old session at the event observation time. The counter delta since the preceding sample spans an unknown portion before/after the actual association boundary, so retain it in interface totals and record it as unattributed/uncertain unless independent evidence establishes a safe split.
4. Establish a fresh baseline for the new state and start a new session only after identity resolution. Attribute subsequent deltas to the active profile while the association remains stable.
5. On disconnect, identity loss, counter reset, interface replacement, or long sampling gap, close or suspend the session and mark the boundary/gap. Do not extrapolate rates or assign a mixed interval wholly to either profile.

This conservative policy means per-profile totals may be lower than interface totals by explicitly reported uncertain bytes. It avoids silently moving bytes to the wrong Wi-Fi profile. Interface-level totals remain the canonical measurement and reconciliation ceiling; profile totals plus uncertain Wi-Fi bytes should reconcile to Wi-Fi interface deltas within documented observation boundaries. Ethernet or other interfaces never become Wi-Fi-profile usage.

### Integrity and persistence extensions

Keep measurement quality and attribution quality as separate dimensions. Counter validity values should include observed, reset, rollover-reconciled, gap-reconciled, and unavailable. Attribution values should include profile-observed, identity-inferred, and unattributed-transition. Preserve raw byte deltas and observed durations; never turn a missing interval into a synthetic average. Run consistency checks in transactions: nonnegative byte counts, nonoverlapping session bounds per interface, no duplicate interval key, and conservation of each interface delta across profile buckets plus the uncertain bucket.

Add these SQLite entities to the earlier proposal:

```sql
network_profiles(
  profile_id TEXT PRIMARY KEY,
  user_label TEXT,
  observed_ssid TEXT,
  first_seen_utc INTEGER NOT NULL,
  last_seen_utc INTEGER NOT NULL,
  excluded INTEGER NOT NULL DEFAULT 0
)

access_points(
  access_point_id TEXT PRIMARY KEY, -- keyed HMAC token; never raw BSSID
  profile_id TEXT,                  -- null until resolved or user-assigned
  interface_id TEXT NOT NULL,
  observed_ssid TEXT,
  security_type TEXT,
  first_seen_utc INTEGER NOT NULL,
  last_seen_utc INTEGER NOT NULL
)

network_sessions(
  session_id TEXT PRIMARY KEY,
  profile_id TEXT,
  access_point_id TEXT,
  interface_id TEXT NOT NULL,
  start_utc INTEGER NOT NULL,
  end_utc INTEGER,
  observed_duration_seconds INTEGER NOT NULL,
  attribution_quality TEXT NOT NULL
)

network_usage_buckets(
  profile_id TEXT,                  -- null means unresolved/unattributed
  interface_id TEXT NOT NULL,
  resolution TEXT NOT NULL,
  start_utc INTEGER NOT NULL,
  end_utc INTEGER NOT NULL,
  downloaded_bytes INTEGER NOT NULL,
  uploaded_bytes INTEGER NOT NULL,
  observed_seconds INTEGER NOT NULL,
  counter_quality TEXT NOT NULL,
  attribution_quality TEXT NOT NULL,
  PRIMARY KEY(interface_id, resolution, start_utc, profile_id)
)

network_transition_events(
  event_id TEXT PRIMARY KEY,
  interface_id TEXT NOT NULL,
  observed_utc INTEGER NOT NULL,
  monotonic_ticks INTEGER NOT NULL,
  event_type TEXT NOT NULL,
  old_profile_id TEXT,
  new_profile_id TEXT,
  resolution_confidence TEXT NOT NULL
)

measurement_integrity_records(
  record_id TEXT PRIMARY KEY,
  interface_id TEXT,
  profile_id TEXT,
  start_utc INTEGER NOT NULL,
  end_utc INTEGER NOT NULL,
  issue TEXT NOT NULL,
  details TEXT
)
```

Use mapping-history rows for user merges/splits so past attribution changes are explicit and reversible. In implementation, use a non-null scope key (for example, a reserved `unattributed` ID) in the bucket primary key because SQLite treats NULL values as distinct in composite unique keys. Keep aggregate interface buckets as the canonical totals; network buckets are an attribution partition and must not be added again to system totals. For average speeds, use only observed seconds, and label them as observed-session averages.

### Validation matrix and acceptance boundary

Unit tests should cover transition ordering, same-SSID/different-BSSID candidate separation, roaming suggestions, counter reset at a boundary, rapid switching, event/snapshot races, duplicate callback suppression, session non-overlap, and per-interface conservation into attributed plus uncertain buckets. Integration validation should include two distinct SSIDs, identical SSIDs on independent networks, multiple APs for one configured profile, roaming, disconnect/reconnect, Wi-Fi/Ethernet changes, sleep/wake, and restart during a session. Verify CoreWLAN entitlements/privacy behavior on each supported macOS release and signed/sandboxed distribution build before relying on SSID/BSSID access.

Acceptance must be phrased carefully: every *resolved* profile has independent persistent history; uncertain bytes stay visible and do not get assigned arbitrarily; user-reviewed roaming matches can avoid duplicate logical profiles. Fully automatic logical-network identity and exact bytes at an association boundary are not achievable from passive public APIs alone. The result is accurate interface measurement with confidence-qualified profile attribution, not packet-exact per-network accounting.

### Updated implementation sequence

Add a network-attribution phase after the 64-bit counter provider and per-interface persistence are validated: first build an event recorder and transition simulator; then store privacy-preserving AP tokens, profiles, sessions, and uncertain deltas; then add profile management and charts. Keep the dashboard and menu bar changes after accounting tests. Profile the added CoreWLAN event subscription and SQLite writes against the same monitoring-disabled baseline; it should add event-driven identity reads, not a second sampling loop.
