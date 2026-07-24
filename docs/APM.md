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
  snapshot → text or JSON     # periodic dump
```

### Counters (`CounterId`)

`ticks`, `net_packets_in/out`, `net_bytes_in/out`, `entities_ticked`,  
`packages_encoded`, `packages_broadcast`, `join_ok`, `join_fail`, …

Extend the enum as features land. Prefer append-only ids for stable JSON keys.

### Sections (`Section`)

| Section | Intended use |
|---|---|
| `tick_total` | Whole 50 ms step |
| `net_poll` | Socket / LiteNet poll |
| `net_decode` | Frame → packages → commands |
| `sim_apply` | Apply client commands |
| `sim_entities` | Entity tick budget |
| `replicate` | Interest + encode |
| `net_flush` | Send queues |
| `save_io` | Region / snapshot disk |

Histograms: power-of-two ns buckets; report mean / p50 / p99 / max.

## Output

- **Text:** human log / telnet later  
- **JSON line:** `{"type":"zdtd_apm",...}` for file tail / simple compare scripts  

M0: dump once at process exit (demo). Later: every N ticks, or on signal.

## Roadmap

| Phase | Deliverable |
|---|---|
| M0 | Counters + section hist + text/JSON report (done scaffold) |
| M1 | Wire net join counters; dump on interval |
| M3+ | Per-player / per-interest byte budgets |
| Later | Optional HTTP `/metrics` or unix socket; never depend on 7dtd-apm |

## Compare under load

1. Run zdtd with metrics dump interval.  
2. Drive with `7dtd-loadgen` (same profile as stock baselining if desired).  
3. Diff JSON ticks / p99 `tick_total` across builds **using zdtd output only**.

## Related

| Doc | Role |
|---|---|
| [../README.md](../README.md) | Project |
| [zig-clone.md](zig-clone.md) | Architecture |
| [../../7dtd-optimizer/docs/measured-scaling.md](../../7dtd-optimizer/docs/measured-scaling.md) | Stock scale shapes (design input) |
