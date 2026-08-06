# Performance measurement plan

The runtime records refresh count, AX candidate count, visible item count, and
refresh duration in `TaskbarStore.metrics`. OSLog writes one debug refresh record;
healthy steady state has no repeating timer or polling work.

## Provisional v1 budgets

These are engineering targets, not measured results:

| Metric | Provisional budget | Measurement scope |
| --- | --- | --- |
| Refresh duration | p95 ≤ 100 ms | 100 candidate windows on a representative session |
| Click-to-focus | p95 ≤ 150 ms | Click timestamp to selected app/window visibly focused |
| Idle CPU | < 0.5% average | Five minutes with no window events |
| Idle RSS | < 40 MB after warm-up | Activity Monitor/Leaks baseline after five minutes |
| Idle wakeups | < 5 wakeups/s average | Instruments Energy Log or Activity Monitor sample |

The budgets are provisional until real hardware, display topology, Accessibility
permissions, and representative applications are measured.

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
