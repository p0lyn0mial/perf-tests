## Investigation Notes: 5K Periodic Scale Test Failure After WatchListCompression Enablement

### Test Failure

**Failed run**: [2074539413072777216](https://prow.k8s.io/view/gs/kubernetes-ci-logs/logs/ci-kubernetes-e2e-gce-scale-performance-5000/2074539413072777216) (Jul 7, 1h51m)
**SLO violation**: `serviceaccounts/token POST` P99 at 1,044ms — 44ms over the 1s threshold. Single violation.

### Runs Compared

| Run | Date | Duration | Compression | Result | sa/token P99 |
|---|---|---|---|---|---|
| [2072365065708769280](https://prow.k8s.io/view/gcs/kubernetes-ci-logs/logs/ci-kubernetes-e2e-gce-scale-performance-5000/2072365065708769280) | Jul 1 | 3h28m | OFF | PASS | 703ms |
| [2074539413072777216](https://prow.k8s.io/view/gs/kubernetes-ci-logs/logs/ci-kubernetes-e2e-gce-scale-performance-5000/2074539413072777216) | Jul 7 | 1h51m | ON | FAIL | 1,044ms |
| [2075264067504705536](https://prow.k8s.io/view/gs/kubernetes-ci-logs/logs/ci-kubernetes-e2e-gce-scale-performance-5000/2075264067504705536) | Jul 9 | 3h32m | ON | PASS | 798ms |

The Jul 1 run (no compression, similar duration) is the proper baseline. Comparing against the short Jul 3 run (56m) gives misleading regression numbers.

### What We Checked and Confirmed

**1. Request latency is dominated by APF wait time.**

We parsed 250K non-WATCH requests from KAS HTTP log traces during the load phase. Each trace includes `fl_priorityandfairness` (APF wait), `apf_execution_time` (execution after dispatch), and `latency` (total). The breakdown: 92.5% APF wait, 3.5% execution, 4% other. This holds across all verbs (GET, POST, PUT, PATCH, DELETE).

Prometheus metrics confirm the same: `apiserver_flowcontrol_request_wait_duration_seconds` P99 peaks at 13-15s while `apiserver_flowcontrol_request_execution_seconds` P99 stays below 1s in all three runs.

**2. All 429s originate from APF.**

We compared `sum(rate(apiserver_request_total{code="429"}[5m]))` vs `sum(rate(apiserver_flowcontrol_rejected_requests_total[5m]))`. The difference is ~3 req/s against a total of ~1,300/s — noise. Zero 429s from watch cache unready (`TooLargeResourceVersion`) or other sources. Rejection reason from Prometheus: 1.3M `queue-full`, 26K `time-out` for `system-nodes` flow schema.

**3. APF saturation occurs in all three runs.**

| Run | Total 429s | APF Wait P99 peak | APF Exec P99 peak |
|---|---|---|---|
| Jul 1 (PASS) | 1,205K | 13.0s | 0.77s |
| Jul 7 (FAIL) | 1,365K | 14.7s | 0.94s |
| Jul 9 (PASS) | 1,107K | 13.0s | 0.92s |

The `system-nodes` flow schema saturates during the load phase in every run. The machine (c4-standard-96, 96 vCPUs, 384 GB RAM) uses 25-32% CPU during the spike.

**4. Mutex contention in CPU profiles is similar across runs.**

We analyzed all CPU profiles (18 for Jul 1, 21 for Jul 7, 19 for Jul 9). `runtime.lock2` + `runtime.mutexSampleContention` combined ranges:
- Jul 1 (PASS): 13-20%
- Jul 7 (FAIL): 13-22%
- Jul 9 (PASS): 12-19%

Pprof tree view of `mutexSampleContention` callers shows HTTP/2 transport functions (`serverConn.serve`, `readFrames`, `writeFrameAsync`) as the top contributors. APF appears at ~1% of contention.

**5. Measured differences between Jul 1 (PASS, no compression) and Jul 7 (FAIL, compression).**

| Metric | Jul 1 | Jul 7 | Change |
|---|---|---|---|
| sa/token POST P99 | 703ms | 1,044ms | +48% |
| WatchList avg duration | 1,891ms | 2,300ms | +22% |
| Terminated endpointslice watchers | 20K | 58K | +176% |
| Mutex wait total | 2,107K s | 2,744K s | +30% |
| Lock+mutex CPU | 13-20% | 13-22% | +2pp |
| APF Wait P99 peak | 13.0s | 14.7s | +13% |
| Total 429s | 1,205K | 1,365K | +13% |

73 commits landed between these runs, including the WatchListCompression feature gate enablement.

**6. The FAIL run has a second APF wait spike at 19:20.**

Prometheus time-series shows APF wait P99 drops to ~300ms at 19:15 then spikes back to 13-15s at 19:20-19:25. This coincides with terminated endpointslice watchers climbing from 42K to 50K. During this window, `system-nodes` execution P99 rises to 983ms (vs 329ms in the Jul 1 run at the same phase).

The Jul 1 run also has a late terminated watcher burst (13K → 20K at 19:30) but without a corresponding APF wait spike.

**7. `waitUntilFreshLocked` does not produce errors.**

Zero `TooLargeResourceVersion` errors in KAS logs across all runs. Zero HTTP 504s from this path. The `apiserver_watch_cache_read_wait_seconds` P99 spikes to 1.5s for configmaps in the FAIL run at 18:55 and 19:20 (vs 400ms in Jul 1 at the same points), confirming the function adds latency but always succeeds within its 3-second timeout.

**8. No compression CPU overhead observed.**

No gzip/compress/flate functions appear in any CPU profile from any run, including early profiles during initial WatchList sync.

**9. Heap and GC are not factors.**

Jul 7 FAIL: heap live 7.1 GB, GC pauses total 0.49s over 111 minutes.
Jul 1 PASS: heap live 8.7 GB, GC pauses total 0.31s over 208 minutes.
Heap is smaller in the FAIL run. GC pauses are negligible in both.

**10. Workload is the same across runs.**

Core workload API counts (pods POST, pods DELETE, deployments POST/DELETE) differ by <1% between Jul 1 and Jul 7. Background operations (leases PUT, events POST) increase proportionally to test duration.

### What We Did Not Determine

1. What specifically causes 2.8x more terminated endpointslice watchers in the FAIL run (58K vs 21K) when WatchList duration increases only 22%.
2. What triggers the second APF pressure wave at 19:20 in the FAIL run — specifically, why execution P99 spikes to 983ms at that moment.
3. Whether the Jul 9 improvement is from specific code changes or test variability (161 commits landed between Jul 7 and Jul 9).
4. Whether `waitUntilFreshLocked` contention (observed in Prometheus as 1.5s P99 spikes) contributes to the execution slowdown that re-fills APF queues.

### Related

- [kubernetes/kubernetes#138670](https://github.com/kubernetes/kubernetes/issues/138670) — Latency differences between LIST and WatchList at large scale
