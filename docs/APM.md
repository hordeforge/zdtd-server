# zdtd metrics and profiling harness

> **What this is:** the native instrumentation inside the Zig dedi, counters, section timers, and text/JSON reports that prove the 50 ms tick budget.

> **Related:** [ARCHITECTURE §11](ARCHITECTURE.md#11-observability-apm) · [ARCHITECTURE §3](ARCHITECTURE.md#3-process-lifecycle-and-the-50-ms-tick) · [STATUS](STATUS.md) · [AUTHORITY](AUTHORITY.md) · [SCALE](SCALE.md) · [STD_ABSTRACTIONS](STD_ABSTRACTIONS.md)

**Owns:** first-class instrumentation **inside** the Zig dedicated process.  
**Not:** sibling `7dtd-server-apm` (stock Unity Mono dedi, managed bridge, bpftrace suite).  
**Not:** mod or Harmony hooks.

Code: `src/apm/` (`metrics.zig`, `profiler.zig`, `report.zig`, `root.zig`).

## Why separate from 7dtd-server-apm

| 7dtd-server-apm | zdtd apm |
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

```mermaid
flowchart LR
    LOOP[tick loop<br/>server/game/step.zig] --> CNT[counters.inc/add<br/>apm/metrics.zig]
    LOOP --> PRF[profiler scope<br/>apm/profiler.zig]
    CNT --> SNAP[snapshot<br/>apm/report.zig]
    PRF --> SNAP
    SNAP --> TXT[text dump<br/>--ticks/--once]
    SNAP --> JSON[JSON line<br/>stdout zdtd_apm]
    LOOP --> WEBUI[tick-end WebSnapshot<br/>server/webui.zig]
    WEBUI --> API[/api/apm.json<br/>zdtd_webui_apm]
```

### Counters (`CounterId`)

`ticks`, `net_packets_in/out`, `net_bytes_in/out`, `entities_ticked`,  
`packages_encoded`, `packages_broadcast`, `join_ok`, `join_fail`,
`net_poll_errors`, `net_payload_errors`, `net_send_errors`,
`reliable_window_drops`, `persistence_errors`, `stale_peers_reaped`,
`stream_errors`, `tick_overruns`, `encode_errors`,
`phase_rejects`, `ownership_rejects`, `bounds_rejects`, `movement_rejects`,
`decode_rejects`, `reconnects`, `buff_rejects`, `inv_ledger_events`,
`c2s_throttle`, `c2s_malformed`, `c2s_rejects`, `c2s_unhandled`,
`c2s_version_rejects`, `c2s_stock_invtx`,
`evidence_events`, `guard_quarantines`, `guard_kicks`, `guard_would_kicks`,
`quarantine_rejects`, `load_shed_drops`, `hard_ceiling_downgrades` (T20:
client-informed `.hard` events downgraded to `.strong` at the authority ceiling),
`survival_players`, `vm_recomputes`, `path_replans_denied`, …

Privileged admin and player-console activity is counted by `admin_commands`
and `player_console_commands`. Command audit logs contain the source and verb
only, keeping free-form arguments such as chat text and coordinates out of logs.

Perf-evidence counters (always on, independent of the `[perf]` switches):

| Counter | Meaning |
|---|---|
| `chunk_flush_queued` | Chunk payloads handed to the background writer |
| `chunk_flush_written` | Chunk payloads the writer completed |
| `chunk_flush_errors` | Background chunk writes that failed (also `persistence_errors`) |
| `chunk_flush_sync` | Async submits that fell back to an inline write |
| `chunk_flush_waits` | Reads / evictions that blocked on a queued write |
| `terrain_snap_chunks` | Chunk coverage summed across rebuilds (divide by the `terrain_snap` section count for the mean window) |
| `terrain_snap_misses` | Path probes that fell through to the locked hook |
| `sleeper_volumes_scanned` | Sleeper volumes tested per scan pass |
| `te_scan_cells` | Cells walked by the one-time storage-TE chunk scan |
| `path_replans` | A* replans issued by the AI phase |
| `replicate_candidates` | Entities the replicate pass considered (dirty ∪ mobs off heartbeat, all live entities on it) |
| `replicate_fanouts` | Framed replication packages handed to a peer (EntitySpawn, PosAndRot, Speeds, AliveFlags) |
| `replicate_encodes_skipped` | Candidates that wanted a motion send but had no observer in range |

The replication trio is the M11 acceptance check. Cost must track *entities
that changed × interested peers*, not players squared:

- `replicate_candidates / ticks` follows world change, not the slot table. Add
  static entities and the off-heartbeat figure must not move.
- `replicate_fanouts / packages_encoded` is the fan-out ratio. Adding a viewer
  raises fan-outs and leaves encodes flat: serialize-once means each package is
  built once and memcpy'd per peer. If encodes start scaling with player count,
  a per-peer encode has crept back in.
- `replicate_encodes_skipped` is pure interest savings (an entity nobody can
  see is never serialized).

`src/server/scenarios.zig` pins both shapes so a regression fails `make check`
rather than showing up as a frame-time drift under load.

Extend the enum as features land. Prefer append-only ids for stable JSON keys.
`apm.report.max_text_bytes` / `max_json_bytes` are derived from the enums at
comptime; call sites size their fixed dump buffers from those, so a new id can
never silently truncate a report.

### Sections (`Section`)

| Section | Intended use |
|---|---|
| `tick_total` | Whole 50 ms step |
| `net_poll` | Socket / LiteNet poll |
| `sim_entities` | Entity tick budget |
| `replicate` | Interest + encode |
| `chunk_stream` | Per-client chunk stream work |
| `save_io` | Region / snapshot disk |
| `save_encode` | Chunk serialize on the tick thread (subset of `save_io`) |
| `save_flush_wait` | Blocking wait on the background chunk writer |
| `terrain_snap` | Per-tick rebuild of the terrain blocked snapshot |
| `sleeper_scan` | Sleeper-volume player test pass (serial or job batch) |
| `te_scan` | One-time storage-TE block scan of a streamed chunk |
| `chunk_gen` | Resident-miss chunk materialization: disk load or procedural gen |
| `survival` | Per-player passive-effects VM + survival stats pass (P4b; `survival_players` / `vm_recomputes`) |
| `join` | Join-phase C2S handling on the tick (login/enter/spawn handlers: spawn-area core + join bundle + respawn logic) |
| `join_drain` | Paced spawn-area drain pass: one pass = the shared per-tick drain budget of chunk bodies + per-chunk ACK yields |

`save_encode`, `save_flush_wait`, `terrain_snap`, `sleeper_scan`, `te_scan` and
`chunk_gen`
are **always on**, including when the matching `[perf]` switch is off. They are
the evidence the switches are gated on: turn a switch on only after its section
shows real cost. See docs/SCALE.md.

Histograms: power-of-two ns buckets; report mean / p50 / p99 / max.

## Output

- **Text:** printed when a bounded `--ticks N` or `--once` run exits; also via
  admin TCP / WebUI console command `apm` (alias `metrics`). This dump walks
  every `CounterId` and `Section` from `src/apm/`.
- **JSON line (stdout):** `{"type":"zdtd_apm",...}` from
  `apm.report.writeJsonLine`, emitted once per minute during unbounded runs.
  It carries the full counter and section maps. When emitted from the live
  loop it also includes an `"ops"` object with instantaneous gauges
  (`tick`, `joined`, `entered`, `peers_alive`, `zombies`, `chunks`). Written
  to **stdout** (human diagnostics stay on stderr), so
  `1>metrics.jsonl 2>server.log` yields a parseable line stream without
  interleaved `zdtd:` free text.
- **WebUI `/api/apm.json`:** a different schema,
  `{"type":"zdtd_webui_apm",...}` from `server/webui.zig` `renderApmJson`.
  It is a tick-end `WebSnapshot` subset for the dashboard (load, selected
  error counters, section means/p99, player roster), not the full
  `CounterId` map. See [WEBUI.md](WEBUI.md).
- **Admin `status`:** one-line load + key error counters (overruns, encode/send
  errors, window drops, persist errors). `guardstats` remains authority rejects.

Signal-triggered dumps remain future work.

## Optional Tracy markers

Off by default: zero overhead, zero dependency. `apm.tracy.Zone` is zero-sized
when the flag is off, no `___tracy_*` symbol is referenced, and the default
build links no libc. `src/apm/` stays the single source of truth; Tracy is a
viewer on top of it.

Tracy is **not vendored** and is **not a Zig package dependency** (see
`README.md`: the package fetches nothing). The operator supplies a checkout:

```bash
git clone --depth 1 https://github.com/wolfpld/tracy /path/to/tracy
zig build -Dtracy=true -Dtracy-src=/path/to/tracy \
          -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe
```

`-Dtracy-src` must point at a checkout containing `public/TracyClient.cpp`,
which is compiled as one C++ TU with `-DTRACY_ENABLE` and linked via
`link_libcpp`. The explicit `-Dtarget=x86_64-linux-gnu` is needed on hosts whose
gcc crt objects carry `.sframe` sections the Zig 0.16 self-hosted ELF linker
rejects (`unhandled relocation type R_X86_64_PC64 ... crt1.o:.sframe`; forcing
`-flld` instead makes LLD crash). The explicit target makes Zig use its own
bundled glibc CRT. Only the Tracy build is affected, because only it pulls in
host libc.

`-Dtracy=true` **without** `-Dtracy-src` fails the build with one named message
and no stack trace. It is deliberately not a silent no-op shim: a shim would let
an operator believe they were profiling when they were not.

### Mapping

Every `apm.profiler.scope(...)` call site emits one Tracy zone named after its
`Section` tag. There is nothing to annotate per call site.

| `Section` tag | Tracy zone |
|---|---|
| `tick_total` | `tick_total` (also closes one Tracy **frame** per server tick) |
| `net_poll` | `net_poll` |
| `sim_entities` | `sim_entities` |
| `replicate` | `replicate` |
| `chunk_stream` | `chunk_stream` |
| `save_io` | `save_io` |
| `save_encode` | `save_encode` |
| `save_flush_wait` | `save_flush_wait` |
| `terrain_snap` | `terrain_snap` |
| `sleeper_scan` | `sleeper_scan` |
| `te_scan` | `te_scan` |
| `chunk_gen` | `chunk_gen` |

`Section` is non-exhaustive; a tag outside the named set gets an *inactive*
zone (an allocation-free no-op pair in the Tracy client) rather than a
fabricated name, matching the same guard `Profiler.begin`/`end` already use.
Zones are attached to `scope`/`Scope.end` and not to raw `begin`/`end` because
Tracy validates strict LIFO nesting per thread and only the scope API
guarantees it.

### Limits

- `make check` / CI never build the `-Dtracy=true` path: it needs an external
  checkout and there is no network fetch. That path is verified by manual
  operator runs only.
- Only zone begin/end and the per-tick frame mark are mapped. No Tracy plots for
  apm counters, no lock zones, no memory-allocation tracking, no message,
  callstack, or GPU zones. Deliberate YAGNI, not oversights.
- Zones exist only where an `apm.profiler.scope` already exists (the named
  `Section` tags). Work with no apm section (worldgen, chunk-encode internals,
  job-pool worker threads) shows up as unmarked time inside its parent zone.
  Adding a `Section` is the documented way to get a zone. Worker threads spawned
  by `ecs` jobs emit nothing, because `ecs` must not import `apm`
  (`scripts/lint-architecture.sh`).
- The `extern` `___tracy_c_zone_context` mirror in `src/apm/tracy.zig` is valid
  only for a client compiled **without** `TRACY_ON_DEMAND`, which appends a
  `uint64_t connectionId` to a struct returned by value. `build.zig` owns the C
  flag list and never defines it, so this cannot drift in-tree; hand-editing
  those flags would silently corrupt the returned struct.
- **Not verified in-tree.** Tracy is not vendored and no checkout exists on the
  build host, so neither `make check` nor CI ever compiles the `-Dtracy` path.
  The bindings are IL/header-grounded and the disabled path is unit tested, but
  "links and runs against a real Tracy client" rests on an operator run with
  `-Dtracy-src`. Treat it as untested until an operator reports otherwise.
- A `-Dtracy` binary links libc++/libc, which the default build does not, so it
  takes a different C start path and libc-vs-syscall routing in std. It is an
  opt-in profiling build; never ship one as a release artifact. `make release`
  does not pass the flag.

## Roadmap

| Phase | Deliverable |
|---|---|
| M0 | Counters + section hist + text/JSON report API (done) |
| M1 | Wire net/join/error counters + periodic JSON dump (done) |
| M1b | Ops gauges in JSON; admin `apm` dump; rate-limited encode/send/phase logs (done) |
| M1c | Optional Tracy zones over apm sections (opt-in, operator-supplied client) (done) |
| M3+ | Per-player / per-interest byte budgets |
| Later | Optional HTTP `/metrics` or unix socket; never depend on 7dtd-server-apm |

## Compare under load

1. Run zdtd with the same finite `--ticks N` value for each build.
2. Drive each run with the same `7dtd-loadgen` profile.
3. Compare the emitted text counters and `tick_total` latency statistics. For
   automated JSON comparison, call `apm.report.writeJsonLine` from the harness;
   there is no JSON CLI switch yet.

## Related

| Doc | Role |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | System overview (APM §11) |
| [ZIG_CLONE.md](ZIG_CLONE.md) | Founding architecture |
| [AUTHORITY.md](AUTHORITY.md) | Guard/phase counters consumed here |
| [SCALE.md](SCALE.md) | M11 acceptance checks (replicate trio, perf switches) |
| [WEBUI.md](WEBUI.md) | Dashboard reads the snapshot + `/api/apm.json` |
| [../README.md](../README.md) | Project |
| [../../7dtd-server-optimizer/docs/measured-scaling.md](../../7dtd-server-optimizer/docs/measured-scaling.md) | Stock scale shapes (design input) |
