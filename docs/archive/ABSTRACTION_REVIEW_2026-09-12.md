# Abstraction review snapshot (2026-09-12)

Prompt: `docs/prompts/abstractions-review.md`, review-only mode.
Scope: repository root `zdtd-server`, Zig 0.16 clean-room dedi. Whole tree
inventoried; no source file was modified. `scripts/lint-architecture.sh` (grep
only, no build) ran clean; `make check` / `zig build` were deliberately not run
per session instructions.

Method: `rg` call-site counts, function-body hashing for duplicate bodies, and
manual tracing of each candidate to its callers. A search hit alone is not
treated as proof.

## Inventory and verdicts

| Abstraction | Path | Kind | Call sites | Layer | Verdict |
|---|---|---|---|---|---|
| `util/arena.newArenaHolder` | `src/util/arena.zig:6` | thin util | 28 (25 files) | util | keep (score 7) |
| `util/arena.ensureLazyArena` | `src/util/arena.zig:12` | thin util | 2 | util | keep (small, symmetric) |
| `arena` deinit block (open-coded) | 28 sites, e.g. `src/assets/items.zig:289` | repeated policy | 28 | util gap | **add** `destroyHolder`, see below |
| `util/io_fs` | `src/util/io_fs.zig` | util boundary | 65 files | util | keep |
| `util/log` | `src/util/log.zig:41-62` | thin util + policy | 18 files | util | keep (quiet + level policy) |
| `util/parallel` | `src/util/parallel.zig` | util boundary | 9 files | util | keep |
| `util/toml_bind` | `src/util/toml_bind.zig` | comptime binder | 7 files | util | keep |
| `util/sim` | `src/util/sim.zig` | deterministic seam | 9 files | util | keep |
| `ecs/query` | `src/ecs/query.zig:118-152` | domain helper | ~15 (`systems.zig`) | ecs | keep |
| `wire/binary` Reader/Writer | `src/wire/binary.zig` | boundary type | 33 files | wire | keep |
| `wire/packages` facade | `src/wire/packages.zig` | facade | 95 builders | wire | keep, prune wrappers |
| `server/phase_gate` | `src/server/phase_gate.zig:17,58` | boundary type | 2 (`c2s/dispatch.zig:27`) | server | keep |
| `game/guard.rejectIfBeyondEditRange` | `src/server/game/guard.zig:13` | repeated policy | 12 | server/game | keep (textbook) |
| `server/guard_policy` | `src/server/guard_policy.zig:167` | pure decision layer | 1 (`game/guard.zig:84`) | server | keep (boundary) |
| `Game` forwarder methods | `src/server/game.zig:347-3918` | facade god-object | 323 pub fns, 198 pure forwarders | server | keep now, cap growth |
| Native `PluginHost` | `src/plugin/host.zig:1`, `sample_hello.zig` | second plugin mechanism | 28 live hook pairs | plugin | **P1**, see below |
| `game/bans.zig` | `src/server/game/bans.zig:6` | 1-call-site file | 1 real (`game/net_handlers.zig:23`) | server/game | inline |
| `game/rescue.withinEditReach` | `src/server/game/rescue.zig:30` | duplicate policy | 2 (`game.zig:2458`, forwarder) | server/game | merge |
| `assets/unity_hash.unityStringHash` | `src/assets/unity_hash.zig:30` | alias, no policy | 2 (`entities.zig:869`) | assets | delete alias |
| `assets/blocks_nim.read7BitLen` | `src/assets/blocks_nim.zig:33` | duplicate codec | 2 local | assets | keep, hoist on 3rd |
| `wire/packages` 4 forwarding fns | `packages.zig:3009,3020,4700,5477` | wrapper, no policy | 2/3/2/3 | wire | inline to leaf |
| `replicate_te.zig` at `server/` root | `src/server/replicate_te.zig:1` | Game helper | many | server | move under `server/game/` |
| `mcp_transport.poll` vs `webui.poll` | `mcp_transport.zig:102`, `webui.zig:339` | duplicate loop | 2 | server | extract on 3rd |

## Findings, ranked

| Sev | file:line | Evidence | Recommendation |
|---|---|---|---|
| **P1** | `src/server/game/types.zig:408`, `init_world.zig:352`, `presets/default.toml:13` | `enable_sample_plugin` defaults **true**, is a shipped preset/`zdtd.toml` knob (`preset.zig:121`), and `init_world.zig:352` unconditionally `enableStaticDefaults()` registers `sample_hello` and `enableAll()`. The native vtable host is composed **before** wasm on 28 hook names across 18 files, e.g. `game.zig:227-228,239-240,274-275,1597-1598,1605-1606`, `game/world.zig:22`, `game/loot.zig:38`, `game/hooks.zig:394-395`, `c2s/misc.zig:782`, `c2s/blocks.zig:267`. ADR 0020 decision 2 (`docs/adr/0020-wasm-only-plugin-api.md:32`) says the static host is "test scaffolding, not a product surface ... not loaded from user configuration"; `docs/PLUGIN_API.md:225` repeats it. | Keep the host for tests, remove it from the product path: default `enable_sample_plugin = false` (`types.zig:408`, `preset.zig:121`, both shipped presets) and gate `self.plugins.*` dispatch behind a tests-only static host, so one plugin mechanism is live. |
| **P2** | 28 pairs, e.g. `src/server/game.zig:227`, `game/bot.zig:336`, `game/wasm_host.zig:55-60`, `game/chunk_fill.zig:429` | The composition rule "static host first, first non-zero wins, else wasm host" is open-coded at 28 sites in 18 files (script count of same-named `plugins.X` / `wasm_plugins.X`). This is repeated policy with no name. | One comptime helper at the plugin boundary, `hookVerdict(hook, args)` / `hookObserve(hook, args)`, so the ordering rule lives in one place. Cheaper than it sounds: both hosts share the hook-name set. |
| **P2** | 28 copies, e.g. `src/assets/items.zig:289`, `src/ecs/quest.zig:487`, `src/assets/block_textures.zig:59`, `src/server/preset.zig:107` | `util/arena.zig` provides `newArenaHolder` (28 callers) but no matching release, so every owner open-codes the same 5 lines: child allocator, `ap.deinit()`, `child.destroy(ap)`, null. Function-body hash finds 18+ byte-identical copies. | **Add** `arena.destroyHolder(arena_ptr: *?*std.heap.ArenaAllocator) void` beside `newArenaHolder` (plus `resetHolder` where `block_textures.zig:59` also clears maps). Removes ~130 duplicated lines. Score 6. |
| **P2** | `src/server/game/rescue.zig:30-35` vs `src/server/game/guard.zig:26-33` | Two implementations of the one edit-range policy: guard does reach + `bounds_rejects` counter + evidence; rescue recomputes `dx*dx+dy*dy+dz*dz <= max_edit_range^2` with no counter or evidence. `game.zig:2458` uses the uncounted copy. | Make `rejectIfBeyondEditRange` the only policy; expose `withinEditReach(g, ...)` from `guard.zig` (or have guard call it) and delete the rescue copy. |
| **P2** | `src/server/game/bans.zig:6` | 13-line file with one function, one real external caller (`game/net_handlers.zig:23`) plus the `game.zig:2066` forwarder; no test, no state. Contradicts the prompt's 1-call-site rule. | Delete `bans.zig`; move `isBanned` next to `banIp`/`unbanIp` in `src/server/game/net.zig:492-501` or make it private in `net_handlers.zig`. |
| **P2** | `src/server/game/step.zig:556` | Every apm report period (default 1200 ticks, `game/types.zig:56`) the tick path does `std.Io.Threaded.init(std.heap.page_allocator, .{})` + `deinit` just to write one stdout line. `docs/STD_ABSTRACTIONS.md:55-68` argues this exact init is "too heavy and globally racy" for hot paths and keeps `clock.zig` Io-free. The sibling init at `game/net.zig:462` is on the accept path with a justification comment; this one has none. | Cache one `Io.Threaded` (or use `debug.print` like the failure branch at `step.zig:553`) so the 60 s report does not construct the runtime inside `tick`. |
| **P3** | `src/wire/packages.zig:3009,3020,4700,5477` | Four `pub fn build*` whose whole body is `return stock_*.build*(...)`: `buildInventoryBodyStock` -> `stock_inv.buildFromEcs`, `buildInventoryBodyStockResolved` -> `...Resolved`, `buildWorldSpawnPoints` -> `stock_entity.buildWorldSpawnPointsBody`, `buildNpcQuestListFetch` -> `stock_quest.buildNpcQuestListFetch`. No policy, no buffer sizing, two names per stock shape. Callers already reach `packages.stock_quest.*` directly (`c2s/quest.zig:74,513`) so the facade is not a single entry point anyway. | Delete the forwarders; call the leaf builders (or `pub const buildWorldSpawnPoints = stock_entity.buildWorldSpawnPointsBody;` type re-exports). Lint only requires the facade to reference each `stock_*.zig`, which the `pub const stock_*` lines already do. |
| **P3** | `src/assets/unity_hash.zig:30` | `unityStringHash` is a second public name for `getStableHashCode`; the two callers split (`entities.zig:869` alias, `stock_te.zig:263` original). Dual name, one function. | Delete the alias, use `getStableHashCode` in `assets/entities.zig`. |
| **P3** | `src/server/replicate_te.zig:1` (454 lines) | A `*Game` domain helper for TE wire-out living at `server/` root while `game/replicate.zig` and `game/replicate_health.zig` sit in `server/game/`; its own header says it was a `Game` method split out. `persist.zig` and `admin_console.zig` are large enough to be their own domains, but `replicate_te` matches the `game/*` pattern exactly. | Move under `src/server/game/replicate_te.zig` (callers already use free-function style `replicate_te.sendVendingTe(g, ...)`), or document the split rule in `src/server/root.zig`. |
| **P3** | `src/assets/blocks_nim.zig:33` | `read7BitLen` reimplements `.NET` 7-bit length, already in `wire/binary.zig` (`read7BitEncodedInt`). Forced today by the one-way edge (`assets` may not import `wire`). Only two local uses. | Do not build now. If a third pre-wire consumer appears, hoist a `util/dotnet_varint.zig` and have both sides import it. |
| **P3** | `src/server/mcp_transport.zig:102` == `src/server/webui.zig:339` | Byte-identical single-client poll/accept/close/cap loop over `util/tcp_listen` (both even share `max_client_polls` semantics). Two sites, coupled through `tcp_listen`. | Extract a `tcp_listen.SingleClient` on the third copy (`serverinfo_tcp.zig:196` is a near-third). Do not build for two. |
| **P3** | `src/server/game.zig:347-3918` | `Game` is 3572 lines with 323 `pub fn`, 198 of which are exactly `return game_x.f(self, ...)`. Every forwarder is reached from outside `game.zig` (no dead ones), so the facade is used, but a reader jumping to `self.sendFramedReliable` lands on a one-line trampoline before the logic, which Zig Zen ("favor reading over writing") flags. Meanwhile `replicate_te` shows the alternative calling convention. | Keep the split. Stop adding forwarders with no policy: new helpers get called free-function style (`game_net.foo(self, ...)`), as `replicate_te` already does. Document that rule in `game.zig`. |

## Dual paths to eliminate

| Dual path | Where | Plan |
|---|---|---|
| Two live plugin mechanisms (native vtable + Wasm) | `src/plugin/host.zig` product path via `game/types.zig:408` | Default the static host off in product config; keep it for `scenarios.zig`/`tests.zig` only (ADR 0020). |
| Two names for one stock-body builder (4x) | `src/wire/packages.zig:3009,3020,4700,5477` | Delete the forwarding fns, keep the leaf name. |
| Two names for the Unity string hash | `src/assets/unity_hash.zig:30` | Delete `unityStringHash`. |
| Reach policy computed twice | `game/guard.zig:29` vs `game/rescue.zig:34` | One predicate in `guard.zig`. |
| Arena release open-coded 28x vs one alloc helper | `util/arena.zig` | Add `destroyHolder`. |
| 7-bit length codec in `assets/blocks_nim.zig:33` and `wire/binary.zig` | forced by layer edge | keep, hoist to `util` on third consumer. |

`linux_fs` re-check: `rg -n 'linux_fs' src` returns zero hits. The second FS
stack has not regrown. Id authority re-check: `maxdamage.idByName` is the only
runtime name -> id map (`assets/maxdamage.zig:211`); `assignids_comptime.zig`
pins are offline/test validated against the dump (`assignids_comptime.zig:77`),
and `ecs/inventory.zig:105` is a function-pointer hook, not a second table. No
second id space found.

## Abstractions worth adding (only where the score says so)

1. `util/arena.destroyHolder` / `resetHolder` (`src/util/arena.zig`) - 28 sites,
   removes duplication, symmetric with the existing alloc side. Score 6.
2. One named plugin-composition helper at the `plugin` boundary
   (`hookVerdict` / `hookObserve`) - 28 sites, names the "static first, first
   non-zero wins, else wasm" rule. Build **only after** (or instead of) the P1
   default change; if the static host leaves the product path, these collapse
   to single-host calls and the helper is unnecessary.
3. `game/guard.withinEditReach` as the single reach predicate - 3 call sites
   once `game.zig:2458` is routed through it, plus the counter/evidence path.

## Explicit do not build

- **Generic `Table(T)` / `NamedTable` for the 5 duplicated `byName` scans**
  (`blocks.zig:174`, `entities.zig:179`, `item_modifiers.zig:61`,
  `recipes.zig:75`, `vehicles.zig:54`). Different element types, different
  ownership, 3 lines each. Wait for a shared lookup policy, not a shape.
- **Generic command-list container for `BanList` / `PermissionList`**
  (`admin_cmds.zig:281` vs `:401`). `BanList` carries a second platform-keyed
  axis (`findId`, `banIp` by platform) that a generic shape would have to
  special-case; 2 types, ~40 lines. Leave it.
- **A shared `Pos`/`BlockPos` type** to dedupe `world/containers.zig:23 eql`
  and `world/vending.zig:22 eql`. Two 1-line predicates; a new domain type for
  them is more concept than the problem.
- **A second block/item id space or an enum of blocks.** Rejected by AGENTS
  rule 23 and the review prompt; `maxdamage.idByName` + AssignIds stays the one
  authority.
- **A runtime `System` trait/vtable bus for the ECS.** `ecs/systems.zig` free
  functions over `*World` with a fixed order in `game/step.zig` are clearer and
  the tick order is the contract.
- **A second FS helper** beside `util/io_fs` or a second package encoder beside
  `wire/stock_*`. Both were already deleted once; do not reintroduce.
- **Wrapping the remaining `squared-distance` scans** in one helper. They mix
  2D/3D, i32/i64 and different radii (`bot.zig:690`, `hooks.zig:112`,
  `net.zig:295`); the shared policy that does exist (edit range) is already
  named.

## Verification notes

- Passed: `scripts/lint-architecture.sh` -> `lint-architecture: clean`.
- Not run (session budget): `make check`, `zig build test`, `make lint`.
  Recommended after any of the above edits, plus a loadgen smoke for the
  plugin-default change (it alters boot-time plugin registration, not wire).
- Unverified: whether maintainers consider the default-on static host
  intentional despite ADR 0020's wording; whether any operator config relies on
  `enable_sample_plugin = true` for behavior (the sample only logs once and has
  no tick/verdict hooks, so the observable difference is the log line and the
  28 extra dispatch branches).
