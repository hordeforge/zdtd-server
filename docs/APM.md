# zdtd metrics and profiling harness

**Owns:** first-class instrumentation **inside** the Zig dedicated process.  
**Not:** sibling `7dtd-apm` (stock Unity Mono dedi, managed bridge, bpftrace suite).  
**Not:** mod or Harmony hooks.

Code: `src/apm/` (`metrics.zig`, `profiler.zig`, `report.zig`, `root.zig`).

## Why separate from 7dtd-apm

| 7dtd-apm | zdtd apm |
|---|---|
| External process + optional C# bridge | Linked into the **`zdtd`** binary |
| Assumes Mono / gmUpdate section names | Named **our** stages (net_poll, sim_entities, …) |
| Host eBPF/perf optional | Wall-clock + counters only (M0); expand later |
| Session folders / dashboard | Text / JSON lines we control |

Stock APM ladders remain useful as **design targets** (player O(N²) shapes). Runtime evidence for zdtd comes from **this harness** + loadgen.

## Model

```text
tick loop
  counters.inc / add          # rates, totals
  profiler.begin/end section  # latency hist per phase
  snapshot → text             # emitted after bounded --ticks/--once runs
           → JSON             # available through apm.report.writeJsonLine
```

### Counters (`CounterId`)

`ticks`, `net_packets_in/out`, `net_bytes_in/out`, `entities_ticked`,  
`packages_encoded`, `packages_broadcast`, `join_ok`, `join_fail`,
`net_poll_errors`, `net_payload_errors`, `net_send_errors`,
`reliable_window_drops`, `persistence_errors`, `stale_peers_reaped`,
`stream_errors`, `tick_overruns`, `encode_errors`, …

Extend the enum as features land. Prefer append-only ids for stable JSON keys.

### Sections (`Section`)

| Section | Intended use |
|---|---|
| `tick_total` | Whole 50 ms step |
| `net_poll` | Socket / LiteNet poll |
| `sim_entities` | Entity tick budget |
| `replicate` | Interest + encode |
| `chunk_stream` | Per-client chunk stream work |
| `save_io` | Region / snapshot disk |

Histograms: power-of-two ns buckets; report mean / p50 / p99 / max.

## Output

- **Text:** printed when a bounded `--ticks N` or `--once` run exits
- **JSON line:** `{"type":"zdtd_apm",...}` is emitted once per minute during
  unbounded runs and is also available through the report API

Signal-triggered dumps remain future work.

## Roadmap

| Phase | Deliverable |
|---|---|
| M0 | Counters + section hist + text/JSON report API (done) |
| M1 | Wire net/join/error counters + periodic JSON dump (done) |
| M3+ | Per-player / per-interest byte budgets |
| Later | Optional HTTP `/metrics` or unix socket; never depend on 7dtd-apm |

## Compare under load

1. Run zdtd with the same finite `--ticks N` value for each build.
2. Drive each run with the same `7dtd-loadgen` profile.
3. Compare the emitted text counters and `tick_total` latency statistics. For
   automated JSON comparison, call `apm.report.writeJsonLine` from the harness;
   there is no JSON CLI switch yet.

## Related

| Doc | Role |
|---|---|
| [../README.md](../README.md) | Project |
| [zig-clone.md](zig-clone.md) | Architecture |
| [../../7dtd-optimizer/docs/measured-scaling.md](../../7dtd-optimizer/docs/measured-scaling.md) | Stock scale shapes (design input) |
