# Plugin API: Wasm guests (design)

**Status:** shipped first cut (2026-08-06, WORK_PLAN T9). A plugin is a `.wasm`
module ([ADR 0020](adr/0020-wasm-only-plugin-api.md),
which supersedes [ADR 0005](adr/0005-native-plugin-api.md)); the zwasm v2
runtime loads modules named in zdtd.toml `[plugin] modules` and calls the
exported hooks under fuel and memory budgets.
**Not:** stock `IModApi`, Harmony, `Mods/` XML, or a native plugin ABI.
**Related:** [ADR 0003](adr/0003-no-stock-mod-host.md), [ADR 0004](adr/0004-server-authoritative-c2s.md),
[ADR 0010](adr/0010-data-config-zig-plugins.md) (data and config layers beneath this one).

## Why Wasm

A modder ships one `.wasm` built from whatever language targets Wasm. The host,
not the plugin, decides what memory exists and which host calls are reachable, so
"one plugin fault disables that plugin" is enforceable rather than aspirational.
A native ABI could promise neither.

## Implementation status (2026-08-06)

| Piece | State |
|---|---|
| Wasm runtime, module loading, fuel accounting | **implemented** (`src/plugin/wasm.zig`: `WasmHost`, `Plugin`, `Budget`) |
| Host function table and capability gating | **implemented**, module `zdtd`, fields `log(level, ptr, len)`, `tick() -> i64`, `queue(ptr, len) -> i32` (bare field names; see [PLUGIN_DEV.md](PLUGIN_DEV.md#host-imports)) |
| `src/plugin/api.zig` | `Host`, vtable, `LogLevel`, `PLUGIN_API_VERSION=1`: in-tree test scaffolding |
| `src/plugin/host.zig` | Fixed table (8), register / enable / setTick / onTick / playerJoin / shutdown |
| `src/plugin/sample_hello.zig` | In-tree sample used by scenarios, not a shipping plugin format |
| Game wire-up | `[plugin] modules` → `WasmHost.loadAll` at init; `step` onTick; join bundle `playerJoin`; `deinit` shutdown; kill verdict routed via `World.kill_verdict_fn`; block damage + quest payout consult the event hooks |
| Event hooks (T15) | `on_player_death`, `on_entity_killed`, `on_block_damage`, `on_quest_complete` return a verdict: `<0` deny, `0` keep, `>0` adjust as percent; first non-zero across plugins wins; a trap/fuel-exhausted plugin reports keep |
| Admin commands from plugins | Wasm `on_admin_command(ptr,len,out_ptr,out_cap)->i32` and static `on_admin_command(cmd,out)`; first handler that returns >0 bytes wins; falls through to core `unknown` if none handle it (admin TCP auth still gates `runAdminLine`) |
| Chat filter from plugins | Wasm `on_chat(sender,msg_ptr,msg_len,out_ptr,out_cap)->i32` and static `on_chat(sender,msg,out)`; <0 deny, 0 keep, >0 filtered bytes (validate again; bad rewrite = deny); first responder wins |
| Join gate from plugins | Wasm `on_player_login(peer_slot,name_ptr,name_len,out_ptr,out_cap)->i32` and static `on_player_login(peer_slot,name,out)`; non-zero deny, magnitude = reason bytes in out; first deny wins (traps treated as allow) |
| SimCommand from plugins | queue lands in the ECS `World.commands` buffer (drained once per tick) |
| Module tiers + discovery (PRD 0005 / ADR 0032) | **implemented**: `mod.toml` manifests, `mods/*/mod.toml` scan, `[mods] disabled`/`blacklist`, five exclusive core override points, `override = <name>` replacement, conflict detection at load (`src/plugin/manifest.zig`, `src/plugin/resolver.zig`, `WasmHost.loadResolved`) |

The static host stays because scenarios need to drive hooks without standing up
a Wasm runtime in the test path. It is not a way to ship a plugin and is not
loaded from user configuration.

### Core override points (ADR 0032)

A mod that claims a point (in `mod.toml` `points = "loot.roll"`) becomes the
exclusive decision maker for that verdict: the native default is skipped and
no other subscriber runs. Duplicate claims fail the boot loudly. Unclaimed
points keep the first-non-zero fan-out above.

| Point | Hook | Effect of an exclusive claim |
|---|---|---|
| `loot.roll` | `on_loot_roll` | the claimant decides the roll |
| `quest.payout` | `on_quest_complete` | the claimant decides the payout |
| `damage.player_scale` | `on_player_damage` | the claimant decides the damage verdict |
| `craft.request` | `on_craft_request` | the claimant decides the craft verdict |
| `trade.price` | `on_trade_price` | the claimant decides the price verdict |

Replacing a whole core component means claiming all of its points; replacing
a whole mod means `override = "<name>"` (the target is not instantiated).
Both are load-time resolution: a branch on a fixed slot table on the tick
path, no per-tick allocation.

## The boundary

The contract is the module's exports plus the host's imports. Nothing else
crosses.

- **Guest exports** the hooks it wants: `on_enable`, `on_tick`,
  `on_player_join`, `on_shutdown`, plus the four event hooks
  (`on_player_death`, `on_entity_killed`, `on_block_damage`,
  `on_quest_complete`). A missing export means that hook is not registered,
  which costs nothing at runtime.
- **Host imports** are capability-gated. A module declares what it needs; the
  host supplies only those functions. There is no filesystem, no socket, and no
  clock beyond the tick time passed in, unless a capability grants it.
- **Data crosses as flat bytes** in the guest's linear memory. The host copies in
  and copies out. No host pointer is ever handed to a guest, so a guest cannot
  reach the sim except through the calls it was given.
- **Authority is unchanged from ADR 0005, carried into [ADR 0020](adr/0020-wasm-only-plugin-api.md):** a plugin may deny or adjust a request
  the core already understands. It may not inject package bytes, invent wire
  types or skip the join state machine.

## Determinism and cost control

Sim hooks run on the main tick thread in documented order, so two servers with
the same plugins and the same inputs step the same way.

Every guest call runs under a fuel budget and a linear-memory cap. The fuel
is a per-instance lifetime budget: armed once at instantiate and decremented
per instruction, never re-armed per call (zwasm source; verified by the
looper fixture). Exhausting either ends the call, disables that plugin, and
logs which hook and which module, so a plugin that loops forever costs one
tick's budget, not the server. Budgets are configurable
(zdtd.toml `[plugin] fuel` / `max_pages`) with the documented defaults
(100 000 000 fuel, 1024 pages).

## Runtime: zwasm v2 (decided 2026-08-06)

zdtd embeds [zwasm](https://github.com/clojurewasm/zwasm) v2 (2.5.0), a
WebAssembly runtime written in Zig, so the server takes no C dependency and no
FFI boundary. Its `minimum_zig_version` is 0.16.0, matching this tree.

The budgets this design requires come from the runtime rather than being bolted
on:

```zig
pub const Budget = union(enum) { unmetered, limited: u64 };
pub const InstantiateOpts = struct {
    fuel:             Budget = .{ .limited = 1_000_000_000 },
    max_memory_pages: Budget = .{ .limited = 4096 },
};
```

Host imports are registered through its `Linker` (`defineFunc`, `defineFuncCtx`),
and every host function receives a `*Caller` first, from which the importing
instance's linear memory is reachable. That is exactly the bare, capability-gated
import table this design wants.

**Verified 2026-08-06** against zwasm 2.4.1 under Zig 0.16, not assumed from the
documentation: a typed export call returns the right value, `fuelRemaining()`
reports the budget, and a module compiled from `(loop br 0)` stops with
`error.OutOfFuel` rather than hanging the caller.

**WASI: not used.** The import table is deliberately small so it can be audited.
A module importing `wasi_snapshot_preview1` will fail to instantiate.

**Known constraint:** linking zwasm with Zig 0.16's self-hosted x86 backend fails
with `unhandled relocation type R_X86_64_PC64`, so any artifact linking it needs
`.use_llvm = true`. This is a backend limitation that applies to zwasm's own
build too, not a defect in zwasm.

### Still open

| Decision | Notes |
|---|---|
| Capability list | Shipped minimal: `log`, `tick`, `queue`. Event hooks (T15) deny/adjust deaths, kills, block damage and quest rewards; read-only sim views are the next candidate. Every addition is permanent, so it lands on evidence |
| Memory and fuel defaults | zdtd ships `Budget` defaults (100M fuel, 1024 pages). Re-tune from a real plugin's measured cost per tick once one exists |
| Interpreter or JIT | zwasm's interpreter is the hardened default; JIT is a later question and only with evidence that a plugin needs it |

## Goals

1. Extend zdtd **without forking** `game.zig` for every admin/event/analytics need.
2. Preserve **stock wire**, **20 TPS**, and **server authority**.
3. Keep the hot path **allocation-bounded** and **deterministic** by default.
4. Make first-party features (guard, custom commands) use the same hooks as third parties.

## Non-goals

- Compatibility with Unity / Harmony / EfficientServer mods  
- Arbitrary package injection or client-side papering  
- Hidden plugin threads mutating sim  
- Unrestricted `*Game` export as the public surface  

## Design principles

| Principle | Meaning |
|---|---|
| Capability, not god-object | Hooks get typed **views** (`Host`, `SimView`, `PeerView`) |
| Core owns wire | Plugins never `sendto` raw bytes; they request high-level ops or use builders |
| Deny > invent | Plugins can veto/adjust validated requests; they cannot invent world blobs |
| Ordered, explicit | Fixed hook order; no access-set auto-scheduler |
| Fail isolate | Hook error → disable that registration; process stays up when practical |
| Versioned | `PLUGIN_API_VERSION` names the guest contract: exported hook names plus the host import table |

## Lifecycle

```text
process start
  → load config (which .wasm modules, with their declared capabilities)
  → Game.create / world + assets init
  → plugin.on_enable(Host)        // register hooks, commands
  → listen
  loop step():
      net poll → C2S hooks → apply
      sim phases → phase hooks
      replicate → observe hooks
      tick end → onTickEnd / frame scrub
  → plugin.on_shutdown
  → Game.deinit
```

Guests: each `.wasm` is instantiated once, its exported hooks registered, and
every call runs under the fuel and memory budget described above. No raw `*Game`
crosses, and no package bytes can be injected (ADR 0010, ADR 0020).

The in-tree static host (`src/plugin/host.zig`, gated by `enable_sample_plugin`)
runs the same hook order without a runtime, so scenarios can assert hook
behaviour directly. It is test scaffolding, not a shipping format.

## Host surface (narrow)

Target surface; v1 `Host` (`src/plugin/api.zig`) ships `version`, `tick`, `log` only.

```text
Host
  version, server_name, tick, world_time
  log(level, msg)                 // no format bombs on hot path
  apmCounter(name) / apmSection   // or fixed enum ids
  registerAdminCommand(name, cb)
  registerHook(HookId, cb, prio)

SimView (read-mostly; mut only via commands)
  entityExists, getTransform, getHealth, getKind
  playerInv snapshot (copy or readonly slice rules TBD)
  queueCommand(SimCommand)        // spawn/despawn/damage/give: applied in phase

PeerView
  peer_id, entity_id, phase, name_hash
  rtt_ms?, flags (admin, quarantine bits)

WorldView
  getBlock, inLoadedChunk, heightAt
  // setBlock only via validated command path
```

No access to LiteNet peer maps, body_buf, or package id tables except through
`sendStock(name, body)` where `body` was built by **core** builders the plugin
called (e.g. `host.buildChat(buf, …)`).

## Hook catalog (target; none of these named hooks are implemented)

Shipped v1 hooks are only the four vtable fields listed under implementation
status. Priorities: lower runs first. Core reserved bands: `0..99` internal, `100..999`
first-party, `1000+` third-party default.

### Connection / join

| Hook | When | Can | Cannot |
|---|---|---|---|
| `onPeerConnect` | LiteNet accept | observe, early ban check | skip challenge |
| `onChallengeOk` | after ids map | observe | rewrite PackageIds |
| `onPlayerLogin` | login decode | **deny** join (reason) | forge identity |
| `onEnterGame` | RequestToEnter | deny / set spawn hint | skip PlayerId |
| `onSpawned` | after spawn bundle | observe | omit stock packages |
| `onPeerDisconnect` | teardown | observe, cleanup plugin state | |

### C2S apply (authority path)

Called **after** phase allow + decode, **before** or **around** sim apply.
Return: `allow` | `deny(reason)` | `modify(request)` for supported fields only.

| Hook | Request type |
|---|---|
| `onSetBlock` | pos, block id, meta |
| `onDamage` | target, amount, source |
| `onInvTx` | op, slots, counts |
| `onCraft` | recipe key |
| `onExplosion` | pos, radius class |
| `onLock` | channel, op |
| `onChat` | text (length-capped) |
| `onVehicleControl` | entity, inputs |
| `onUnhandledC2S` | name + body len only (no blind parse obligation) |

Aligns with TODO P4 guard: same seams as Hard invariants; guard can be a
first-party plugin or core module using identical hooks.

### Sim phases

| Hook | Phase |
|---|---|
| `onBeforeTick` | start of `step` |
| `onAfterDirector` | after horde/clock |
| `onAfterAi` | after zombie AI apply |
| `onAfterVehicles` | |
| `onAfterPower` | |
| `onAfterTurrets` | |
| `onBeforeReplicate` | dirty gather |
| `onAfterReplicate` | |
| `onTickEnd` | scrub locals, plugin frame arena |

### World / entities (observe + command)

| Hook | Notes |
|---|---|
| `onEntitySpawned` / `onEntityDied` | net id, kind, cause |
| `onChunkCommitted` | cx,cz after store write |
| `onLootFill` | container id, can replace roll **table choice** not raw items without catalog |
| `onQuestEvent` | accept/complete/turn-in |

### Admin / ops

| Hook | Notes |
|---|---|
| `onAdminCommand` | after parse; can handle unknown verbs |
| `onConfigReload` | optional |

## Commands (plugin → core)

Plugins never mutate SoA columns directly in v1. They enqueue:

```text
SimCommand =
  | give_item { entity, item_id, count }
  | damage { entity, amount, cause }
  | teleport { entity, x,y,z }
  | set_block { x,y,z, id }          // still goes through validation
  | kick { peer, reason_id }
  | quarantine { peer, bits }
  | broadcast_chat { text }
```

Executed in documented windows (end of C2S, or `onTickEnd`) so parallel AI
never races plugin writes.

## Concurrency

- Hook bodies run on the **main tick / net thread** unless marked `async_ok`
  (observe-only, no sim commands).
- For background work, plugins push to an MPSC queue (see mach steal); **one**
  consumer applies on tick.
- No plugin-owned threads calling `SimView` mutators.

## Packaging

### v1 Static

```zig
// src/plugin/api.zig : experimental types
// src/plugin/host.zig : fixed registry table
// src/plugin/sample_hello.zig : in-tree sample
```

Plugins are compiled in and registered at runtime via `PluginHost.register`
(`src/plugin/host.zig`); the sample is gated by the `enable_sample_plugin`
InitOption, not a build option. Public facade: `src/plugin/root.zig`.

### v2 (shipped first cut): Wasm runtime

No native plugin ABI and no `.so` loading ([ADR 0020](adr/0020-wasm-only-plugin-api.md)).
A plugin ships as a `.wasm` module; the runtime, host import table and fuel
accounting live in `src/plugin/wasm.zig` (WORK_PLAN T9, landed 2026-08-06).
Load modules with `[plugin] modules = "a.wasm, b.wasm"` in zdtd.toml.

## Safety and abuse

- Caps: max hooks per id, max commands per tick per plugin, max log rate  
- Admin commands require admin TCP auth as today  
- Evidence/PII: plugins should use host logging redaction helpers  
- Malicious plugin = same trust as operator code (ADR: cannot stop evil admin)

## Testing

- Unit: registry order, deny short-circuit, command apply  
- Scenario: plugin denies setblock; expects no world change + optional chat  
- Loadgen: plugins disabled or noop still 20 TPS budget (apm section `plugin`)

## Implementation order (TODO P4 guard seams; Wasm runtime: WORK_PLAN T9)

1. `plugin/api.zig` types + null registry  
2. Wire 3 hooks: login deny, setblock, admin command  
3. In-tree sample + scenario  
4. Migrate thin guard observes onto hooks  
5. Wasm runtime, host import table and fuel accounting (WORK_PLAN T9)  

## Open questions

- Exact `modify(request)` field allowlists per package  
- Whether loot hook can add items only from loaded `items.xml` ids  
- Frame allocator per plugin vs shared tick arena  
- Comptime registration vs runtime only  
