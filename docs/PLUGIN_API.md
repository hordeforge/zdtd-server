# Native plugin API (design)

**Status:** skeleton shipped (static host only; see [ADR 0005](adr/0005-native-plugin-api.md))  
**Not:** stock `IModApi`, Harmony, or `Mods/` XML.  
**Related:** [ADR 0003](adr/0003-no-stock-mod-host.md), [ADR 0004](adr/0004-server-authoritative-c2s.md),
[ADR 0010](adr/0010-data-config-zig-plugins.md) (data/config/Zig layers; **Wasm guest**
as future sandboxed mod API behind this host), TODO P4 (authority),
mach notes in [ADR 0006](adr/0006-steal-from-mach.md).

## Implementation status (2026-08-04)

| Piece | State |
|---|---|
| `src/plugin/api.zig` | `Host`, `PluginVTable`, `PLUGIN_API_VERSION=1` |
| `src/plugin/host.zig` | Fixed table (8), register / enable / onTick / playerJoin / shutdown |
| `src/plugin/sample_hello.zig` | In-tree sample: logs once on enable; null tick/join |
| Game wire-up | `createWithOptions` → `enableStaticDefaults`; `step` onTick; join bundle `playerJoin`; `deinit` shutdown |
| InitOptions | `enable_sample_plugin` (default true; mode pack / future flags may set) |
| Gamemode pack | `modes/*.toml` data-only + `enable_sample_plugin` (ADR 0010 step 3 first cut) |
| Dynlib / Wasm | **not** implemented |
| C2S deny hooks / SimCommand from plugins | deferred (ECS `World.commands` is the drain seam) |

Hot path: null hooks are a null check only; sample has no `on_tick`.

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
| Versioned | `PLUGIN_API_VERSION`; static link v1; dynlib only with stable C-ish ABI later |

## Lifecycle

```text
process start
  → load config (which static plugins / dynlib paths)
  → Game.create / world + assets init
  → plugin.onInit(Host)           // register hooks, commands
  → listen
  loop step():
      net poll → C2S hooks → apply
      sim phases → phase hooks
      replicate → observe hooks
      tick end → onTickEnd / frame scrub
  → plugin.onShutdown
  → Game.deinit
```

Static plugins: comptime or link-time table in `build.zig` / `src/plugin/registry.zig`.  
Dynamic native: optional `zdtd_plugin_v1` entry points (only after static is proven).  
**Wasm guests (later):** same hooks and `SimCommand` queue; engine runs modules with
fuel + memory limits; no raw `*Game`, no package byte injection (ADR 0010).
Implement Wasm **after** the native hook table works with at least one in-tree
Zig plugin.

## Host surface (narrow)

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

## Hook catalog

Priorities: lower runs first. Core reserved bands: `0..99` internal, `100..999`
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
// src/plugin/api.zig : stable types
// src/plugin/registry.zig
// plugins/example_chatfilter.zig : in-tree sample
```

`build.zig` option: `-Dplugins=example,guard` or always link empty registry.

### v2 Dynamic (optional)

```text
extern fn zdtd_plugin_abi_version() u32;
extern fn zdtd_plugin_init(host: *const HostVTable) callconv(.c) i32;
extern fn zdtd_plugin_shutdown() void;
```

- HostVTable function pointers only; no Zig type layout across boundary  
- Load from `plugins/*.so` path in config  
- Disable on ABI mismatch  

## Safety and abuse

- Caps: max hooks per id, max commands per tick per plugin, max log rate  
- Admin commands require admin TCP auth as today  
- Evidence/PII: plugins should use host logging redaction helpers  
- Malicious plugin = same trust as operator code (ADR: cannot stop evil admin)

## Testing

- Unit: registry order, deny short-circuit, command apply  
- Scenario: plugin denies setblock; expects no world change + optional chat  
- Loadgen: plugins disabled or noop still 20 TPS budget (apm section `plugin`)

## Implementation order (TODO P5)

1. `plugin/api.zig` types + null registry  
2. Wire 3 hooks: login deny, setblock, admin command  
3. In-tree sample + scenario  
4. Migrate thin guard observes onto hooks  
5. Dynlib only if operators need out-of-tree binaries  

## Open questions

- Exact `modify(request)` field allowlists per package  
- Whether loot hook can add items only from loaded `items.xml` ids  
- Frame allocator per plugin vs shared tick arena  
- Comptime registration vs runtime only  
