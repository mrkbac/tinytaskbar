# Performance measurement plan

The runtime records refresh count, AX candidate count, visible item count, and
refresh duration in `TaskbarStore.metrics`. OSLog writes one debug refresh record;
healthy steady state has no repeating timer or polling work.

The deterministic debug overflow fixture exercises the real panel and projection
path without Accessibility or TCC changes:

```sh
bash scripts/build-app.sh --adhoc --configuration debug \
  --output dist/TinyTaskbar-Debug.app
dist/TinyTaskbar-Debug.app/Contents/MacOS/TinyTaskbar \
  --ui-test-fixture=overflow
```

The package test suite also projects 120 windows and exercises the injected provider
refresh/debounce path. The fixture is valid evidence for the real AppKit panel's idle
rendering cost, but not for real AX enumeration, wakeups, or click-to-focus latency.

## Scoped local measurements — 2026-08-07

Environment: macOS 26.5.1 (25F80), Apple M4 Max, app version 1.0.0 (1), one
interactive screen exposed to the Computer test session, Accessibility mocked only
by the DEBUG fixture. Settings had never been opened in the measured fixture
processes, exercising the normal lazy taskbar-only path.

| Scene | Sample | CPU | Physical footprint | RSS | Threads |
| --- | --- | --- | --- | --- | --- |
| Four-window normal fixture | 5 `top` samples over 10 s | 0.0% each | 14 MB, 15 MB peak | 50,144 KB | 3 |
| 120-window overflow fixture | 5 `top` samples over 10 s | 0.0% each | 35 MB, 37 MB peak | 77,968 KB | 3 |

`footprint` physical footprint and `ps` RSS are intentionally reported separately;
they are not interchangeable on macOS. The physical footprint is the memory budget
metric because it represents the process's charged physical memory. RSS remains a
useful diagnostic and is not hidden: it was about 49 MB for four mocked windows and
76 MB for 120 mocked windows.

As an additional release-mode denied/background control before the lazy-Settings
optimization, ten `top` samples over 20 seconds were all 0.0% CPU, physical footprint
was 26 MB, and a 10-second `sample` placed every one of 8,624 main-thread samples in
the ordinary AppKit event-loop Mach wait. This supports the no-polling design, but is
not a wakeups-per-second measurement.

A separate six-sample `top -d` run on the final four-window fixture reported delta
context switches of 0, 1, 0, 0, and 0 after the initial cumulative sample: about
0.1 context switches/s over the measured intervals. This is a useful non-privileged
wakeup proxy and is comfortably below the provisional rate, but it does not replace
an Instruments Energy Log wakeups trace.

## Provisional v1 budgets

These are engineering targets, not measured results:

| Metric | Provisional budget | Measurement scope |
| --- | --- | --- |
| Refresh duration | p95 ≤ 100 ms | 100 candidate windows on a representative session |
| Click-to-focus | p95 ≤ 150 ms | Click timestamp to selected app/window visibly focused |
| Idle CPU | < 0.5% average | Five minutes with no window events |
| Idle physical footprint | < 40 MB after warm-up | `footprint`/Activity Monitor after five minutes; report RSS separately |
| Idle wakeups | < 5 wakeups/s average | Instruments Energy Log or Activity Monitor sample |

The short local fixtures meet the CPU and physical-footprint budgets within their
scope. Five-minute real-AX, wakeup, refresh-latency, click-to-focus, multi-display,
fullscreen, and Stage Manager measurements remain required.

## Procedure

1. Build a Release ad-hoc or Developer ID app and record the version/build number.
2. Use Instruments Time Profiler and Points of Interest/OSLog to capture refresh
   duration and candidate/item counts while opening, moving, resizing, focusing,
   minimizing, and restoring representative windows.
3. Use Activity Monitor for idle CPU and RSS; use Instruments Energy Log or the
   system activity tools for idle wakeups. Record sample duration and whether
   Stage Manager, fullscreen, and multiple displays were active.
4. Measure click-to-focus from a timestamped UI click trace to the target window’s
   visible focus/raise event. The store’s activation request is synchronous only
   until AX returns; the user-visible completion must be measured in the interactive
   trace rather than inferred from request duration.
5. Repeat with a single display, two displays, fullscreen, Stage Manager, long
   titles, and many windows. Report p50/p95, candidate/item counts, and any skipped
   apps or AX errors.

No performance budget is represented as verified until those traces exist. A
single local build or a source-level absence of timers is not a production
performance result.
