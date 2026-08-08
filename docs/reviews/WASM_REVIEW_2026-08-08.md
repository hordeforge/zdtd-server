# Wasm plugin seam audit (ADR 0020)

Date: 2026-08-08. Audit only, no code changed. HEAD `3b06680`.
Scope: `docs/adr/README.md` (ADR 0010 + 0020), `src/plugin/{api,host,wasm}.zig`,
`docs/PLUGIN_API.md`, `docs/PLUGIN_DEV.md`, `docs/STATE_MACHINES.md` (§10),
`docs/GAME_OPTIONS.md`, `docs/STATUS.md`, `docs/WORK_PLAN.md` (T9/T15),
`modes/*.toml`, `mods/example_chat_filter/`, fixtures, call sites in
`game.zig` / `game/world.zig` / `c2s/*` / `admin_console.zig` / `ecs/*`.

## 1. Current plugin hook inventory

Static host (`src/plugin/api.zig` `PluginVTable`, in-tree scaffolding only) and
Wasm host (`src/plugin/wasm.zig`) share one 11-hook contract.
`PLUGIN_API_VERSION = 1`. Ordering everywhere: static host first, then Wasm
host; within a host, plugin load order, first non-zero / first responder wins.
Verdict convention: `<0` deny, `0` keep, `>0` adjust as percent (event hooks).

| # | Hook | Static sig (api.zig) | Wasm sig (wasm.zig) | Call site | Semantics | Tests | Doc rows |
|---|---|---|---|---|---|---|---|
| 1 | `on_enable` | `fn(*const Host) void` | `() -> void` | `game.zig:1489` static, `1494` wasm, once at create | register interest; trap/fuel disables module | host.zig enable-once; wasm.zig trivial module; fixture hello; scenario wasm-plugins | PLUGIN_API "Guest exports" + status; PLUGIN_DEV lifecycle table; STATE_MACHINES §10 |
| 2 | `on_tick` | `fn(*const Host) void` | `() -> void` | `game.zig:4827` static, `4830` wasm, late in every `step`, after sim/replicate/weather/vehicles | per-tick observe + queue SimCommand; not load-shed gated | fixture hello (3 ticks, queues spawn); looper OutOfFuel; scenario wasm-plugins | PLUGIN_DEV observe table; PLUGIN_API status; STATE_MACHINES §10 |
| 3 | `on_player_join` | `fn(*const Host, peer_slot: u16, entity_id: i32) void` | `(i32, i32) -> void` | `game.zig:3359-3360`, first join only | observe first join | host.zig null-skip; fixture hello presence | PLUGIN_DEV observe table; PLUGIN_API status |
| 4 | `on_shutdown` | `fn(*const Host) void` | `() -> void` | `game.zig:1763-1764`, reverse order at deinit | flush plugin state | host.zig shutdown order; fixture hello presence | PLUGIN_DEV observe table |
| 5 | `on_player_death` | `fn(*const Host, victim: i32) i32` | `(i32) -> i32` | `game.zig` `killVerdict` (players), via `World.kill_verdict_fn` in `ecs/world.zig:769` and `ecs/systems.zig:179` | `<0` deny: victim survives at 1 hp, hit consumed, no loot/corpse | wasm.zig T15 verdict test (deny); fixture plugin_rules; scenario wasm-t15 | PLUGIN_DEV event table; PLUGIN_API T15 status row |
| 6 | `on_entity_killed` | `fn(*const Host, killed: i32, killer: i32) i32` | `(i32, i32) -> i32` | same `killVerdict`, non-player kinds; `killer=-1` on deferred AI damage | `<0` deny the kill | wasm.zig T15 test (keep); fixture plugin_trap (trap isolates); scenario wasm-t15 | PLUGIN_DEV event table |
| 7 | `on_block_damage` | `fn(*const Host, x: i32, y: i32, z: i32, dmg: i32) i32` | `(i32,i32,i32,i32) -> i32` | `game/world.zig` `addBlockDamage:162` (single choke point: player dig, zombie chew, admin edits) | `<0` no damage; `>0` percent (200 doubles); clamp 65535 | wasm.zig T15 test (200); scenario wasm-t15 (100->200 applied) | PLUGIN_DEV event table |
| 8 | `on_quest_complete` | `fn(*const Host, player: i32, quest_def: i32) i32` | `(i32, i32) -> i32` | `game.zig:4850-4851`, tick-end payout drain | `<0` withhold, `>0` scale the item/exp half; wallet coins already credited in sim | wasm.zig T15 test (200); scenario wasm-t15 (xp doubled) | PLUGIN_DEV event table |
| 9 | `on_admin_command` | `fn(*const Host, cmd: []const u8, out: []u8) ?[]const u8` | `(ptr,len,out_ptr,out_cap) -> i32` | `admin_console.zig:781/785` `tryDispatchPluginAdmin`, only on parse result `.unknown` | first handler with reply wins; null falls to core unknown reply; admin TCP auth already gated | host.zig first-handler test; wasm.zig admin fixture test | PLUGIN_API admin row; PLUGIN_DEV shape; STATE_MACHINES §10 note |
| 10 | `on_chat` | `fn(*const Host, sender: i32, msg, out) ?[]const u8` | `(sender,msg_ptr,msg_len,out_ptr,out_cap) -> i32` | `c2s/misc.zig:41` (NetPackageChat) and `:85` (SimpleChat), after `chatMsgOk` + rate limit, before broadcast | `<0` deny, `0` keep, `>0` rewrite; bad rewrite treated as deny; first responder wins | host.zig chat tests; wasm.zig chat fixture test | PLUGIN_API chat row; PLUGIN_DEV shape; STATE_MACHINES §10 note |
| 11 | `on_player_login` | `fn(*const Host, peer_slot: u16, name, out) ?[]const u8` | `(peer_slot,name_ptr,name_len,out_ptr,out_cap) -> i32` | `c2s/join.zig:72/78`, after name sanitize, before identity ban and spawn | first deny wins, reason in `out`; trap -> allow | **none** (no unit, no fixture, no scenario) | PLUGIN_API join row; PLUGIN_DEV shape; STATE_MACHINES §10 note |

Host imports (capability-gated, `zdtd` namespace): `zdtd_log(level,ptr,len)`,
`zdtd_tick() -> i64`, `zdtd_queue(ptr,len) -> i32`. SimCommand text grammar
`spawn x y z hp` / `despawn id` / `damage id amount` (128-byte cap,
`parsePluginCommand`, fixed 64-slot `ecs/command.zig` buffer drained once per
tick by the schedule).

### Doc staleness and gaps

| Doc | Problem |
|---|---|
| PLUGIN_API "The boundary > Guest exports" bullet | Lists only 8 exports; missing `on_admin_command`, `on_chat`, `on_player_login` |
| PLUGIN_API "Hook catalog (target; none of these named hooks are implemented)" | Stale note "Shipped v1 hooks are only the four vtable fields"; 11 hooks now ship |
| PLUGIN_API / PLUGIN_DEV / handoff.md "fuel budget per call" / "Budgets are per hook and configurable" | Code arms fuel once at instantiation; it is a per-instance **lifetime** budget, never re-armed, and there is no config knob (`[plugin]` exposes only `modules`) |
| PLUGIN_DEV `on_quest_complete` "<0 withhold the payout" | Imprecise: wallet coins are already credited in the sim; the hook gates only the item/exp half (game.zig comment says this, PLUGIN_DEV does not) |
| STATUS.md | Ships T9 runtime + T15 event hooks but never documents the three ops hooks (9/10/11); handoff.md does, STATUS does not |
| PLUGIN_API "Testing: apm section `plugin`" and ADR 0010 step 5 "apm section `plugin_wasm`" | No plugin apm section or counters exist (`src/apm/` has no plugin entry; plugin calls sit inside `sim_entities`) |
| PLUGIN_API admin row "falls through to core `unknown` if none handle it" | Order is inverted in code: core parse runs first and plugins only see `.unknown` verbs; a plugin cannot shadow a core verb |

Test coverage summary: hooks 1-8 have unit or scenario coverage; 9-10 have
WasmHost-level unit tests but no end-to-end scenario through the real
`runAdminLine` / C2S chat path; 11 (`on_player_login`) has zero coverage.

## 2. Game logic that fits the Wasm plugin model but is Zig-only today

Per ADR 0010 layer 3 and ADR 0021 decision 4 (behaviour that is not a number
belongs in a plugin; numbers belong in config/`Rules`). All candidates below
are already event-driven (no per-tick cost if the hook is missing), so the
verdict convention slots in without touching the 50 ms budget.

| Candidate | Why it fits (ADR 0010) | Zig home today | Hook API needed | Effort |
|---|---|---|---|---|
| **Loot table override** | loot is the #1 server-identity lever; stock tables stay data (layer 1), the override is policy | `assets/loot.zig` `rollContainer:196`; `game.zig` `fillContainerFromLoot:4210`; `game/loot.zig` `fillLootBagFromTable` | `on_loot_roll(loot_name, stage, seed, out_override)` -> i32 (<0 deny roll, >0 scale count, or table-name override in out) | Low (roll is one choke point; copy-in/out of one name + counts) |
| **Spawn rules** | horde/wander population tuning is the second most-tuned surface; director is already config+data driven, only the decision is Zig | `ecs/aidirector.zig` spawn branches; `ecs/world.zig` `spawnZombie*` | `on_director_spawn(cx, cz, group_id, count, player_slots)` -> i32 (deny wave, scale count) | Medium (thread verdict through director spawn sites; define group id + player context in the view) |
| **Quest/craft gates** | progression control for modes (deny a quest, gate a recipe) without forking systems | `ecs/quest_systems.zig` `questAccept:133` / `questAcceptStarter:178`; `c2s/inv.zig` InvTx craft op; `tickWorkstations` | `on_quest_accept(player, def_id) -> i32`; `on_craft_request(player, recipe_id, times) -> i32` (deny or scale) | Low (both choke points are single functions; recipe_id needs a stable catalog key) |
| Trader policy | pricing/window policy is pure policy, stock prices stay XML data | `server/trade.zig` `fillTraderFromXml` (markup math), `handleTrade:78`, `traderIsOpen:186` | `on_trader_price(trader_id, item_type, base_buy, base_sell) -> i32` (percent adjust) or `on_trade(player, trader, item, buy/sell) -> i32` (deny) | Low (two localized computations; needs item_type stable id) |
| Guard policy | quarantine decision ladder is behaviour; thresholds are already config | `server/guard_policy.zig` (pure decision layer; `bitsFor`, ladder) | `on_guard_trip(peer_slot, detector, surface) -> i32` (override quarantine bits or kick) | Low-Medium (decision layer is pure and testable; security surface, operator-trusted) |
| Weather policy | storm policy is cosmetic but a classic mode lever; weather state is already data+config | `server/game/weather.zig` `buildWeatherBodyFromBiomes`; `world/weather.zig` `Manager` | `on_weather_policy(biome_id, params) -> i32` (override params / force storm) | Low (params are 5 f32; call at build/broadcast) |

### Top 3 by value

1. **Loot table override (`on_loot_roll`)**. Highest server-identity value,
   one central choke point, event-driven, low effort, and PLUGIN_API already
   lists `onLootFill` as target (no read-only views needed; name + counts
   cross as flat bytes).
2. **Spawn rules (`on_director_spawn`)**. Controls the survival feel (horde
   size, no-spawn zones, night-only spawns); director is already parameterized
   so the seam is small; medium effort.
3. **Quest/craft gates (`on_quest_accept` / `on_craft_request`)**. Modes need
   progression control (hardcore, PvP, builder); both choke points are single
   functions; low effort.

## 3. Plugin host itself

### Fuel / memory budget enforcement

| Aspect | Finding |
|---|---|
| Enforcement | Real: zwasm v2.4.1 `InstantiateOpts.fuel` + `max_memory_pages`; a `(loop br 0)` module is cut with `error.OutOfFuel` and disabled (test + looper fixture). Memory cap is per-instance at instantiate (1024 pages = 64 MiB default). |
| Budget is lifetime, not per-call | Fuel is armed once at instantiate and never re-armed (`Plugin.load`), so it is a per-instance **lifetime** budget shared by all hooks. Docs say "per call". A plugin that spends meaningful fuel every tick will silently disable after `budget / per_tick_cost` ticks (100M fuel at 20 Hz is ~8 min at 10k fuel/tick). PLUGIN_DEV acknowledges the disablement but not the lifetime semantics. |
| Not configurable | `[plugin]` in zdtd.toml exposes only `modules`; `Budget` (100M fuel, 1024 pages) is a compile-time default, overridable only in code/tests (`InitOptions.plugin_budget`). PLUGIN_API "Budgets are per hook and configurable, with a documented default" is not implemented. |
| Hot-path ceiling | Worst case one tick can burn 8 modules x 100M interpreter instructions (~800M) before disablement; at interpreter speed that is far past 50 ms on the offending tick. Bounded to one tick per module, but the bound is not the tick budget. This is the headline finding. |

### Trap isolation

| Aspect | Finding |
|---|---|
| Isolation | A trap or OutOfFuel disables only that module (`disabled = true`); every later call is skipped and verdict hooks report keep / null. Proven by plugin_trap fixture (module disabled, kill proceeds, server keeps ticking). |
| No host pointer to guest | Flat bytes only; imports copy in/out with bounds checks. `wasi_snapshot_preview1` import fails instantiation. HostCtx `data` is never dereferenced by the plugin layer. |
| Guest cannot touch sim | Only `zdtd_log` / `zdtd_tick` / `zdtd_queue`; queue lands in the fixed 64-slot buffer drained by the schedule, so a guest cannot reenter or race the tick. |
| Gaps | `callChat` / `callAdminCommand` / `callPlayerLogin` may `mem.grow` the guest memory (heap alloc inside the runtime) on a C2S/admin packet path; today's fixtures are 1-page modules so it never triggers, but the path violates the no-alloc-on-packet rule if a guest declares small memory. The 1024-offset scratch layout is a heuristic, not a documented ABI (guest data below/around 1024+len can be clobbered; benign because it is the guest's own memory). |

### Determinism

Hooks run on the main tick thread in load order (static then wasm); verdicts
are first non-zero in that fixed order; fuel accounting and disablement are
deterministic given the same inputs; no wall clock is exposed (only
`zdtd_tick`). Matches ADR 0020 rule 5 and ADR 0012. No guest threads exist.
Two caveats: `disabled` state is process-lifetime (no re-enable path, no
hot reload), and `on_tick` runs even under load shedding (unlike weather and
vehicle broadcasts), so a heavy plugin taxes the tick when the server is
already over budget.

### Hot-path cost

- `on_tick` (per tick, 20 Hz) is the only per-tick hook; alloc-free
  (`callHook` is a plain interpreter call) but not apm-instrumented (sits
  inside `sim_entities` scope; no `plugin`/`plugin_wasm` section, contrary to
  PLUGIN_API and ADR 0010 step 5).
- Verdict hooks fire on events (death, kill, block damage, quest payout),
  not per tick. `on_block_damage` is per damage event through the single
  `addBlockDamage` choke point; fine.
- Chat/admin/login hooks are per event and copy in/out plus a possible
  `mem.grow`; they are C2S/admin paths where the no-alloc rule nominally
  applies.

### Other host findings

- Dead duplicate `blockDamageVerdict` at `game.zig:273`; the live one is
  `game/world.zig:20`. Compiles because unused private fn is discarded, but
  it is a trap for future edits.
- `sample_hello` static plugin is enabled by default
  (`InitOptions.enable_sample_plugin` defaults true; `PluginHost.sample_enabled`
  defaults true; `modes/default.toml` and `horde_lite.toml` set it true), so a
  stock `--mode default` server runs the sample. ADR 0020 calls the static host
  test scaffolding only; the default-on sample muddies that.
- Module cap 8, module size cap 16 MiB, command length cap 128 bytes, command
  buffer 64 slots: all named consts and enforced.

## 4. mods/ packaging

| Aspect | Finding |
|---|---|
| Layout | `mods/example_chat_filter/` ships `mod.toml` + `plugin.c` + `plugin.wasm` (695 B). |
| mod.toml | `name`, `version`, `wasm`, `description`. Nothing in the repo reads it: no loader, no validator, no manifest check, no doc row (grep finds it only in handoff.md). The real enable path is `[plugin] modules = "mods/example_chat_filter/plugin.wasm"` in zdtd.toml (GAME_OPTIONS.md:106). |
| Build flow | No Makefile/script builds `plugin.c -> plugin.wasm`; the .wasm is committed. PLUGIN_DEV documents ad-hoc clang/rust/zig/tinygo commands. The example is byte-identical to `assets/fixtures/plugin_chat.{c,wasm}` (duplication with no shared source). |
| Fixtures | 6 C sources + prebuilt wasm under `assets/fixtures/`; build commands are comments in the .c files, not a script; wasm binaries are committed (695 B - 1.3 KiB each, small enough to be acceptable artifacts). |
| Docs | PLUGIN_API "Packaging > v2" covers `[plugin] modules`; PLUGIN_DEV covers authoring; neither documents mod.toml or a mod directory convention. |

## Recommendations (audit only, not implemented)

1. Document the 11-hook contract in one place and fix the stale PLUGIN_API
   bullets (guest exports list, "four vtable fields", "per call" budget).
2. Decide the fuel model: re-arm per call (per-call budget as documented) or
   document lifetime semantics; add a `[plugin] budget` toml surface and a
   sane per-tick ceiling that cannot blow 50 ms on one tick.
3. Add an apm section for plugin calls (`plugin_wasm`) as ADR 0010 promised,
   and gate `on_tick` behind load shedding like other deferrable work.
4. Add tests: `on_player_login` (none today), plus end-to-end scenarios for
   admin/chat/login through the real Game paths.
5. Delete the dead `blockDamageVerdict` in `game.zig`; default
   `enable_sample_plugin` off; either wire mod.toml into the loader or drop it
   and document `[plugin] modules` as the only packaging.
6. Land the top-3 candidates (`on_loot_roll`, `on_director_spawn`,
   `on_quest_accept` / `on_craft_request`) behind the existing verdict
   convention and budget machinery.
