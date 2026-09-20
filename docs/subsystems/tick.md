# Process loop and the 50 ms tick

This page owns the server process loop: the order in which `main` builds a `Game`, the fixed-step loop that drives `Game.step`, the ordered schedule inside one tick, the 20 TPS budget policy when a tick runs long, and the handoff surfaces that in-process tests and the APM harness use. It does not own what each phase computes: LiteNet framing and peers belong to `litenet`, entity and block state to `ecs` and `world`, interest and the chunk stream to their own pages, and the counter and histogram internals to `apm`.

The subsystem lives in the `server` package, which the package header describes as the top of the dependency stack: "Dependency direction: top of the stack. May import all other src packages." (`src/server/root.zig:4`). Only the executable root and the fuzz target import it - `src/main.zig:5` imports `server/game.zig`, and `src/fuzz.zig:18` onwards import individual `server/*.zig` leaves, so no lower package may call into the loop.

Sources: [`src/main.zig`](../../src/main.zig), [`src/server/game.zig`](../../src/server/game.zig), [`src/server/game/step.zig`](../../src/server/game/step.zig), [`src/server/game/tick.zig`](../../src/server/game/tick.zig), [`src/server/game/harness.zig`](../../src/server/game/harness.zig), [`src/server/game/lifecycle.zig`](../../src/server/game/lifecycle.zig), [`src/util/clock.zig`](../../src/util/clock.zig), [`src/protocol.zig`](../../src/protocol.zig)

## Tick rate and the Game state that belongs to the loop

The rate is one constant, shared by the wire challenge block, the sim step delta, and the pacer. There is no second definition of the tick length anywhere in the loop.

The tick rate (`src/protocol.zig:19`):

```zig
/// Stock GameTimer target (research closed-gaps / loop)
pub const ticks_per_second: u32 = 20;
pub const tick_ns: u64 = 1_000_000_000 / ticks_per_second;
```

`Game.step` derives its sim delta from the same constant rather than from a measured elapsed time (`src/server/game/step.zig:91`), so a late tick does not hand a larger `dt` to the sim.

The `Game` fields the loop itself owns (`src/server/game.zig:442`):

```zig
    /// Load-shed valve: weak evidence + deferrable broadcasts are dropped while
    /// `tick_n < shed_until_tick`. Armed only by the real-time run() overrun branch.
    shed_until_tick: u64 = 0,
    tick_n: u64 = 0,
    running: bool = true,
```

`tick_n` is the single tick counter used by every cadence gate in the step and by plugins (`src/server/game/step.zig:42`). `running` is the loop condition; an admin shutdown clears it and `run` returns, then saves (`src/server/game.zig:4145`, `src/server/game.zig:4172`).

Cadence gates are `InitOptions`/`Game` fields sampled as tick counts, not seconds. The compile-time defaults (`src/server/game/types.zig:87`):

```zig
pub const default_world_time_send_ticks: u64 = 20;
pub const default_vehicle_pos_send_ticks: u64 = 5;
pub const default_sleeper_tick_ticks: u64 = 10;
pub const default_turret_sync_ticks: u64 = 10;
pub const default_save_interval_ticks: u64 = 100;
```

At 20 TPS those are 1 s, 0.25 s, 0.5 s, 0.5 s and 5 s, and `default_apm_report_period_ticks` is `protocol.ticks_per_second * 60`, one JSON line per minute (`src/server/game/types.zig:56`). Operator overrides arrive as `zdtd.toml [stream]` keys and are copied field by field during init (`src/server/game.zig:867`).

## Startup order

`main` parses CLI, environment, serverconfig, preset and `zdtd.toml` into `game_mod.InitOptions`, then constructs the process in one call: `game_mod.Game.createWithOptions(gpa, world_dir, port, init_opts)` (`src/main.zig:1027`). Construction is heap-allocated once (`Game` holds fixed buffers in the hundreds of KiB range) and the loop never allocates.

Inside `initWithOptions` the order is: load the persisted side stores (`containers`, sign texts, vending, workstations, claims, entities, allies, block meta - `src/server/game.zig:1099` onwards), then `game_init_assets.loadAssets` (`src/server/game.zig:1186`), then `game/init_world.zig:initWorld` (`src/server/game.zig:1191`), then trader stock (`src/server/game.zig:1196`). `initWorld` is where the sockets open, and the order there matters for what a connecting client can see: LiteNet listen on `port +% 2` first (`src/server/game/init_world.zig:98`), then the loop's clock baseline `start_mono_ns` (`src/server/game/init_world.zig:119`), then the TCP info listener (`src/server/game/init_world.zig:127`), admin console (`src/server/game/init_world.zig:188`), webui (`src/server/game/init_world.zig:205`) and MCP (`src/server/game/init_world.zig:229`).

Offline runs are the exception that keeps the loop testable: `port == 0` never binds a socket and switches the process to the seeded virtual clock and serial ranges (`src/server/game/init_world.zig:94`, `src/server/game/init_world.zig:109`). `--once` and `--ticks` parse to `max_ticks` and skip `Game.run` entirely, calling `step` in a bounded loop (`src/main.zig:1151`). Everything after construction therefore has to work with no socket, no wall clock and no run loop.

## One tick, in order

`Game.step` (`src/server/game/step.zig:32`) is a single function; the phases below are its blocks in source order. `tick_total` opens at the top and closes in a `defer` that also emits a Tracy frame mark and advances the virtual clock when one is active (`src/server/game/step.zig:33`, `src/server/game/step.zig:35`).

1. Tick open: `tick_n` increments, the `ticks` counter increments, and the plugin hosts learn the new tick (`src/server/game/step.zig:40`, `src/server/game/step.zig:41`, `src/server/game/step.zig:42`).
2. Net drain and C2S apply, inside the `net_poll` section (`src/server/game/step.zig:45`). `self.net.poll` is called in a loop capped at `max_net_polls_per_tick` (`src/server/game/step.zig:49`, `src/server/game/step.zig:26`); `.connected` routes to `onConnected` and `.data` to `onData`, which is the whole C2S apply path for the tick (`src/server/game/step.zig:67`, `src/server/game/step.zig:75`). A poll error is counted and returned, ending the tick (`src/server/game/step.zig:49`). Still in the same block: `reapStalePeers` (`src/server/game/step.zig:81`), `reapPolicyKicks` (`src/server/game/step.zig:82`), up to `max_info_polls_per_tick` TCP info polls (`src/server/game/step.zig:84`), `pollAdmin` (`src/server/game/step.zig:85`), up to `max_webui_polls_per_tick` webui polls (`src/server/game/step.zig:87`) and `mcp.poll` (`src/server/game/step.zig:88`).
3. Sim, inside the `sim_entities` section (`src/server/game/step.zig:93`). Optional terrain snapshot rebuild (`src/server/game/step.zig:95`), party game stage and blood-moon freeze (`src/server/game/step.zig:105`), ambient light from the world clock, sky and moon phases (`src/server/game/step.zig:130`), sleeper-volume wake by combat noise (`src/server/game/step.zig:145`), then the ECS schedule in one call: `systems.tickAll(&self.sim, dt)` (`src/server/game/step.zig:146`). After it: sleeper re-arm (`src/server/game/step.zig:152`), stealth-noise sleeper wake (`src/server/game/step.zig:157`), budgeted water leveling (`src/server/game/step.zig:162`), explosion and dig request drains (`src/server/game/step.zig:171`, `src/server/game/step.zig:174`), sleeper wake, look-at and attack-target broadcasts (`src/server/game/step.zig:178`, `src/server/game/step.zig:181`, `src/server/game/step.zig:185`), stealth meters (`src/server/game/step.zig:188`), map chunks (`src/server/game/step.zig:191`), player position markers (`src/server/game/step.zig:194`), client info (`src/server/game/step.zig:197`), serveradmin hot reload (`src/server/game/step.zig:199`), then the per-player survival and effects pass `tickSurvival(dt)` (`src/server/game/step.zig:200`) and `tickBots(dt)` (`src/server/game/step.zig:201`).
4. Entity-removal and loot fan-out for what the systems produced: bag distraction destroys (`src/server/game/step.zig:206`), turret kills with their XP and score bodies (`src/server/game/step.zig:283`), kill and despawn `NetPackageEntityRemove` sends scoped to the peers that knew the entity (`src/server/game/step.zig:338`, `src/server/game/step.zig:354`), plugin-despawn removals (`src/server/game/step.zig:366`), buff expiry relay (`src/server/game/step.zig:372`), and loot bag fill plus spawn broadcast (`src/server/game/step.zig:374`).
5. Periodic world work, gated on `tick_n % sleeper_tick_ticks == 0` (`src/server/game/step.zig:249`): sleeper volumes, air drop and zombie block damage (`src/server/game/step.zig:250`), then workstations, block radius effects and always-on radius effects (`src/server/game/step.zig:254`). Power resolves once per tick with real daylight outside the system schedule (`src/server/game/step.zig:266`), followed by powered doors, TE power visuals, stale lock reaping, corpse sweep with its removals, and trader areas (`src/server/game/step.zig:267`, `src/server/game/step.zig:268`, `src/server/game/step.zig:269`, `src/server/game/step.zig:273`, `src/server/game/step.zig:282`).
6. Cadence broadcasts. Every `world_time_send_ticks`, `NetPackageWorldTime` is broadcast, the weather machine ticks and weather is sent unless the loop is shedding load, and per-player blood-moon music edges are sent (`src/server/game/step.zig:383`). Then vehicle positions and turret sync on their own periods (`src/server/game/step.zig:406`, `src/server/game/step.zig:407`). The plugin hosts get `onTick`, then disabled plugins have their pending commands and applied spawns withdrawn before the command drain (`src/server/game/step.zig:408`, `src/server/game/step.zig:409`, `src/server/game/step.zig:414`).
7. Quest reward drain: the completed-quest ring is walked, each completion passes the plugin verdict, and items, coin, XP and chained quests are granted (`src/server/game/step.zig:417`). The ring count is cleared at the end of the block (`src/server/game/step.zig:519`).
8. Replication: `self.replicate()` (`src/server/game/step.zig:522`) enters the `replicate` section (`src/server/game/replicate.zig:21`). Order inside it: reliable window resend per peer (`src/server/game/replicate.zig:24`), paced spawn-area drain shared by concurrent joins (`src/server/game/replicate.zig:35`), the chunk stream on `chunk_stream_period_ticks` for entered clients (`src/server/game/replicate.zig:50`), player health, and then the interest-filtered motion pass, which returns early on ticks outside `motion_replicate_period_ticks` (`src/server/game/replicate.zig:62`, `src/server/game/replicate.zig:63`). Serialize-once plus fan-out is this phase's contract; the wire shapes live in `wire/`.
9. Save, on `tick_n % save_interval_ticks == 0` (`src/server/game/step.zig:523`), inside `save_io` with the encode part split into `save_encode` (`src/server/game/step.zig:524`, `src/server/game/step.zig:527`): world chunks, containers, sign texts, workstations, vending, claims, entities, allies, block meta, weather, clock, and players only when `players_dirty` (`src/server/game/step.zig:529` onwards). `sampleFlushCounters` runs every tick, not only on save ticks, because it converts the chunk writer's cumulative totals into per-tick deltas (`src/server/game/step.zig:546`).
10. APM report on `apm_report_period_ticks`: `harness.snapshot()` gets the live gauges filled in and one JSON line is written to stdout through a `std.Io.Threaded` handle (`src/server/game/step.zig:548`, `src/server/game/step.zig:558`, `src/server/game/step.zig:575`). This is the only per-tick stdout writer in the loop.

The three poll caps are named module constants rather than literals so a flood is bounded without reallocating (`src/server/game/step.zig:24`):

```zig
/// Cap datagram polls per tick: one chatty peer must not monopolize the
/// tick (the loop breaks on `.none` anyway; this bounds a flood).
const max_net_polls_per_tick: u32 = 64;
/// GSI info-poll cycles per tick (serverinfo_tcp is a tiny poll).
const max_info_polls_per_tick: u32 = 8;
/// Webui console-line drains per tick (the web console is operator-only).
const max_webui_polls_per_tick: u32 = 4;
```

`tick.zig` is the other half of this subsystem at file level: it holds the per-domain helpers `step` calls (`tickSurvival`, `tickAirDrop`, `tickZombieBlockDamage`, `actuatePoweredDoors`, `reapStaleLocks`, `drainDigRequests`), with their APM sections opened inside the helper, for example the `survival` scope at `src/server/game/tick.zig:833`. It is not a second scheduler; the order is only ever expressed in `step.zig`.

## Timing, overrun and catch-up policy

The only real-time pacer is `Game.run` (`src/server/game.zig:4142`):

```zig
    pub fn run(self: *Game) !void {
        const tick_ns: u64 = protocol.tick_ns;
        var next_t = clock.monoNs() + tick_ns;
        while (self.running) {
            try self.step();
            // Snapshot after step returns (step stack unwound; avoids overflow).
            self.fillWebuiSnap();
            const now = clock.monoNs();
            if (next_t > now) {
                clock.sleepNs(next_t - now);
            } else if (now > next_t) {
                // Fell behind the 50 ms budget: count for apm; rate-limit log.
                self.harness.counters.inc(.tick_overruns);
                // Availability valve: hold weak evidence + deferrable broadcasts
                // for 2 s. Chunk streaming, motion replicate, WorldTime and every
                // Hard gate keep running.
                if (self.guard.load_shed) self.shed_until_tick = self.tick_n + self.guard.shed_hold_ticks;
                const overruns = self.harness.counters.get(.tick_overruns);
                if (overruns == 1 or overruns % 100 == 0) {
                    const late_us = (now -% next_t) / 1000;
                    var ts: [19]u8 = undefined;
                    std.debug.print(
                        "zdtd: {s} tick overrun n={d} late_us={d} (budget={d}us)\n",
                        .{ clock.wallStamp(&ts), overruns, late_us, tick_ns / 1000 },
                    );
                }
            }
            next_t += tick_ns;
            if (next_t < clock.monoNs()) next_t = clock.monoNs() + tick_ns;
        }
        try self.world.saveAll();
    }
```

The policy this encodes: sleep to the absolute deadline; on overrun count the tick and rate-limit the log to the first and every hundredth; then re-anchor. Because the re-anchor sets `next_t = now + tick_ns` when the deadline is already in the past, missed ticks are dropped rather than replayed - there is no catch-up burst, and a process that stalls for a second resumes at the current time instead of running twenty ticks back to back. One loop iteration counts at most one overrun regardless of how many tick periods it lost.

The overrun branch also arms the load-shed valve: `shed_until_tick = tick_n + guard.shed_hold_ticks` (`src/server/game.zig:4158`). `loadShedding` is a single comparison against that field (`src/server/game/guard.zig:149`), so the valve costs nothing when unarmed. Defaults are `load_shed: bool = true` and `shed_hold_ticks: u64 = 40` (`src/server/guard_policy.zig:66`, `src/server/guard_policy.zig:78`), which is 2 s at 20 TPS. Only the real-time `run` path arms it: `--ticks` and `--once` call `step` directly with no pacing and no overrun accounting, and the counter is documented as "Main loop fell behind the 50 ms tick budget (run path only)." (`src/apm/metrics.zig:28`).

Time comes from one leaf module so the loop can be made deterministic without touching callers. `clock.monoNs` reads `CLOCK_MONOTONIC` in production but returns the virtual counter when one is active (`src/util/clock.zig:48`), `sleepNs` advances that counter and returns immediately instead of sleeping (`src/util/clock.zig:97`), and `enableVirtual` switches the process over (`src/util/clock.zig:25`). The offline path enables the seeded virtual clock at init (`src/server/game/init_world.zig:109`) and the local `util/sim` layer advances it one tick per completed step (`src/server/game/step.zig:38`), so a `--ticks N` run is reproducible from its seed and does not depend on host speed. `wallNs`/`wallSeconds` exist for values that cross the process boundary, such as report timestamps and ban expiry, and also follow the virtual clock (`src/util/clock.zig:62`, `src/util/clock.zig:73`).

## Instrumented sections and counters

The loop is instrumented through one process-wide handle on the `Game` (`harness: apm.Harness = .{}`, `src/server/game.zig:432`). The handle is only two fields (`src/apm/root.zig:21`):

```zig
/// Process-wide handle used by tick/net once the server loop exists.
pub const Harness = struct {
    counters: Counters = .{},
    prof: Profiler = .{},
```

`snapshot` copies both and stamps wall time for the dump (`src/apm/root.zig:26`). Private copies of either field would break the text and JSON dumps, so callers always go through `Game.harness`.

Sections are a closed enum, opened with `apm.profiler.scope(&self.harness.prof, .name)` and closed by the returned `Scope.end` (`src/apm/profiler.zig:111`). The named section list begins (`src/apm/profiler.zig:8`):

```zig
pub const Section = enum(u8) {
    tick_total,
    net_poll,
    sim_entities,
    replicate,
    chunk_stream,
    save_io,
```

and continues with `save_encode`, `save_flush_wait`, `terrain_snap`, `sleeper_scan`, `te_scan`, `chunk_gen`, `survival`, `join` and `join_drain` before a non-exhaustive `_` marker (`src/apm/profiler.zig:17` through `src/apm/profiler.zig:43`). Where each sits in the tick:

| Section | Opened in |
|---|---|
| `tick_total` | `step` entry, `src/server/game/step.zig:33` |
| `net_poll` | net drain block, `src/server/game/step.zig:45` |
| `terrain_snap` | snapshot rebuild, `src/server/game/step.zig:96` |
| `sim_entities` | sim block, `src/server/game/step.zig:93` |
| `survival` | `tickSurvival`, `src/server/game/tick.zig:833` |
| `replicate` | `replicate`, `src/server/game/replicate.zig:21` |
| `save_io` / `save_encode` | save block, `src/server/game/step.zig:524`, `src/server/game/step.zig:527` |
| `save_flush_wait` | shutdown flush, `src/server/game/lifecycle.zig:14` |

The remaining sections are opened deeper in the paths the tick reaches: `chunk_stream` and `join_drain` in the chunk stream (`src/server/game/chunk_stream.zig:261`, `src/server/game/chunk_stream.zig:221`), `chunk_gen` and `te_scan` in chunk materialization (`src/server/game/chunk_fill.zig:45`, `src/server/game/chunk_fill.zig:273`), `sleeper_scan` in the sleeper-volume pass (`src/server/game/sleeper.zig:65`), and `join` in the join handler reached from the net drain (`src/server/c2s/join.zig:39`). A `Scope` is zero-sized unless `-Dtracy=true`, so instrumentation is not a per-tick allocation (`src/apm/profiler.zig:102`).

Counters used to judge the loop itself are `ticks`, `tick_overruns`, `net_poll_errors`, `net_payload_errors`, `net_send_errors`, `stream_errors`, `encode_errors` and `persistence_errors` (`src/apm/metrics.zig:8` onwards). The `--ticks` and `--once` exits print the full text dump after the final save (`src/main.zig:1158`), and the periodic JSON line is the scraping surface for a live process (`src/server/game/step.zig:569`).

Accuracy caveat: a green `zdtd` APM dump, or a green zdtd encode/decode round trip, shows the loop and its own encoding are self-consistent. It is not evidence of stock client compatibility; that needs the loadgen smoke and a stock client with EAC off (`docs/ARCHITECTURE.md:708`).

## Persistence and shutdown

Persistence splits between the periodic tick save and process teardown. The tick save writes the list in phase 9 every `save_interval_ticks`; failures are logged and counted, not fatal, so a disk problem degrades the process instead of killing the loop (`src/server/game/step.zig:529`).

`Game.deinit` is the ordered teardown that mirrors construction in reverse (`src/server/game/lifecycle.zig:9`). It saves players first, then the world, then waits for the background chunk writer before saving the side stores (`src/server/game/lifecycle.zig:11`, `src/server/game/lifecycle.zig:12`, `src/server/game/lifecycle.zig:16`). The flush wait is instrumented so a slow shutdown disk shows up as `save_flush_wait` rather than as unexplained exit latency (`src/server/game/lifecycle.zig:14`). Plugins and Wasm modules are shut down before the stores are freed (`src/server/game/lifecycle.zig:30`), and the virtual clock is disabled on the way out when this process enabled it (`src/server/game/lifecycle.zig:10`, `src/server/game/lifecycle.zig:43`).

`main` distinguishes its two exits clearly. The `run` path is reached only when `max_ticks == 0` (`src/main.zig:1141`); it saves and returns, and only then does the process print the line naming the final tick count, which is how an operator tells a graceful stop from a killed process (`src/main.zig:1147`). The bounded path saves through `g.world.saveAll()`, dumps APM and exits without ever having opened the run loop (`src/main.zig:1157`).

## Harness handoff

Two distinct things share the word "harness" and are not interchangeable. `Game.harness` is the in-process APM handle described above. `src/server/game/harness.zig` is the test and scenario entry surface, and its header states the boundary plainly: "Production networking does not use these shortcuts." (`src/server/game/harness.zig:1`).

The test helpers drive the same tick path the wire does. `attachJoinedClientAs` fakes a peer slot, then replays the real C2S handshake through `onConnected` and `onData` - challenge frame, `NetPackagePlayerLogin`, `NetPackageRequestToEnterGame`, `NetPackageRequestToSpawnPlayer` - and only returns once `c.joined` and a positive `entity_id` prove the join machine accepted it (`src/server/game/harness.zig:55`, `src/server/game/harness.zig:59`, `src/server/game/harness.zig:85`). `injectFramed` feeds any further framed body through `onData` (`src/server/game/harness.zig:91`), `replicateNow` calls the same `replicate` phase the tick calls (`src/server/game/harness.zig:95`), and `setBlock` and `applyDamage` write through the world and sim stores (`src/server/game/harness.zig:19`, `src/server/game/harness.zig:15`). Because these go through the production entry points, a scenario that joins and replicates exercises the real phase order instead of a parallel one; what it does not exercise is pacing, overrun handling and load shedding, which live only in `run`.

`main` also exposes the loop directly to non-interactive use: `--ticks N` calls `step` and `fillWebuiSnap` per iteration and `--once` is `--ticks 1`, with `--port 0` the intended pairing for deterministic runs (`src/main.zig:1151`, `src/main.zig:1155`, `src/main.zig:412`). Note the difference from `run`: the bounded loop checks no deadline, so a hung step is not interrupted and no overrun is recorded.

## See also

- [ECS and the system schedule](ecs.md)
- [APM counters and section histograms](apm.md)
- [LiteNet transport and peers](litenet.md)
- [Interest and replication](interest.md)
- [Architecture overview](../ARCHITECTURE.md)
