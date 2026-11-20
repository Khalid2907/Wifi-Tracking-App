# Initial runtime sample

This historical sample predates the 64-bit counter reader and recent dashboard changes. It is retained as a baseline record only; it does not measure the current build and is not a release performance result. No new profiling has been completed for the hardened build.

Recorded 2026-11-20 on macOS 27.2.1 (Apple M5), using `top -l 7 -s 5 -pid <app-pid> -stats pid,cpu,mem,time,threads` against the release `.app`. The app ran in its normal background menu bar state, with no dashboard open, for about 30 seconds after a short startup warm-up. Sampling was set to five seconds.

| Metric | Observed |
| --- | --- |
| CPU snapshots | 0.5–0.7% in the five-second `top` samples after the initial sample |
| Process CPU time | 0.40 s at first sample; 0.61 s at last sample (about 0.7% of one core over the 30-second interval) |
| Resident memory | 22–24 MB |
| Threads | 6 |

This is a brief idle sample, not a sustained benchmark. It does not establish battery impact, wakeups per hour, disk writes per hour, traffic accuracy, high-throughput behavior, or performance with the dashboard open. There was no monitoring-disabled baseline, so this does not isolate incremental overhead. The original CPU goal of below 0.1% average has not been demonstrated; the short sample is above that target. A longer Instruments Energy Log and Activity Monitor comparison is still needed before making performance claims.
