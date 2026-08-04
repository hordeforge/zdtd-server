# ADR 0010: Stock data, config, Zig systems (no VM in core)

- **Status:** accepted
- **Date:** 2026-08-04

## Context

Operators and implementers hit three different kinds of "hardcoding" and often
reach for one hammer (Lua/script VM, or more Zig consts). They are not the same
problem. Diagnosis of what "hardcoded" usually means in zdtd:

| # | What it is | Wrong fix | Right fix |
|---|---|---|---|
| 1 | **Stock content** (block HP, MaxFuel, recipes, biome weather, item stacks, AssignIds) | Lua tables; hand-copied Zig catalogs | Load XML/AssignIds (`--game-dir`); names + `idByName` |
| 2 | **zdtd policy** (stream radius, interest range, tick throttles, wallets, feature flags) | More `const` in `game.zig`; Lua config DSL | `serverconfig.xml` + CLI + **`zdtd.toml`** (`src/server/zdtd_config.zig`) |
| 3 | **Sim rules** (combat, AI phases, join SM, package builders) | Rewrite systems in a VM | Keep **Zig systems**; **data-driven parameters** (ranges, rates, tables); expose hooks via **native plugin API** |

A scripting VM (e.g. LuaJIT) as the core game logic would fight the 20 TPS
budget, hot-path no-alloc rule, stock wire fidelity, deterministic tests, and
ADR 0003 (not a stock mod host). Native plugins (ADR 0005) already define the
extension direction.

Related: [HARDCODE_AUDIT.md](../HARDCODE_AUDIT.md),
[PROMPTS/audit-hardcoded-data.md](../PROMPTS/audit-hardcoded-data.md),
[PLUGIN_API.md](../PLUGIN_API.md), [ASSETS.md](../ASSETS.md),
[GAME_OPTIONS.md](../GAME_OPTIONS.md).

## Decision

Use **three layers**. Do not collapse them into a general-purpose script VM in
the dedi process.

### Layer 1. Stock content → game data (not Lua, not Zig consts)

| Load from | Examples |
|---|---|
| `$game/Data/Config/*.xml` via `--game-dir` / `--config-dir` | MaxFuel, MaxDamage, recipes, biomes weather, traders, quests |
| AssignIds dump / `idByName` | Block and item **wire** ids |
| World install assets | DTM, prefabs, TTS, biomemap |

- **Names** are the stable key; numeric ids are resolved at load/runtime.
- Fail closed on missing names (omit / not placeable), never invent parallel id
  spaces.
- Tiny `builtin_*` tables are offline / no-game-dir tests only.
- Optional xpath overrides: `--config-overrides` (see ASSETS.md).
- In progress: power, biomes, recipes, and other loaders; finish via hardcode
  audit P0/P1 (names + XML + AssignIds).

### Layer 2. Server policy → config (not Lua, not bare tick consts)

| Surface | Examples |
|---|---|
| Stock-shaped `serverconfig.xml` | ViewRadius, MaxSpawnedZombies, ServerPassword, … |
| CLI | `--port`, `--webui-*`, `--worldgen-seed`, … |
| Future **`zdtd.toml`** (or equivalent) | stream caps, interest range, peer stale, craft batch, AI bands, feature flags |

- Hot path reads **struct fields** filled at init; no file I/O on the 50 ms tick.
- Precedence: CLI > world/CWD zdtd config > serverconfig > code defaults.
- Defaults must match pre-extraction behavior when migrating consts.
- Do not put MaxFuel-style stock props into zdtd.toml (that is layer 1).
- Many tunables already live on `Game` / `InitOptions`; file surface still open.

### Layer 3. Systems and wire → Zig (parameterized; hooks via native plugins)

| Stays in Zig | How it stays flexible |
|---|---|
| Join SM, C2S validate/apply, package builders | One stock shape → one builder; RE-backed |
| ECS systems (AI, combat, power tick, quests) | Tunables from config / loaded tables; no magic numbers on hot path |
| LiteNet, chunk stream, interest fan-out | Named caps; apm |
| Gamemodes / admin extras / analytics | **Native plugin API** (ADR 0005), not a core VM |

- Plugins get **views** and may deny/adjust understood requests; they do not
  inject arbitrary wire bytes or skip authority (ADR 0004).
- **Gamemode** = config pack + optional static plugin (e.g. `modes/pve.toml` +
  `plugins/pve_rules.zig` linked in; dynlib only after static is proven).
- **Sandboxed guest code (preferred shape: Wasm)** may be added **later**, only
  as a **guest behind the native plugin host** (see "Wasm modding API" below).
  It is not a substitute for layers 1–3 and not on the raw tick/wire path.

### Wasm modding API (future, accepted direction)

**Goal:** operators ship small mods/gamemode rules without rebuilding zdtd and
without stock C#/Harmony. **Sandbox** + **capability hooks** only.

| Rule | Meaning |
|---|---|
| Host is Zig | Core still owns wire, join SM, chunk encode, authority apply |
| Guest is Wasm (or similar) | No native `dlopen` of untrusted code in v1 guest path |
| Caps only | Fuel/instruction budget per tick; max memory; no raw sockets/FS unless host grants |
| Hooks not god-object | Same event set as PLUGIN_API (`onSetBlockRequest`, `onTickEnd`, admin cmds, …) |
| Mutate via queue | Guest returns deny/adjust or enqueues `SimCommand`; never holds `*Game` |
| No invent wire | Guest cannot `sendto` or build arbitrary package bytes; host builders only |
| Load path | `plugins/*.wasm` + manifest (hooks used, abi version, memory limit) |
| Determinism default | Guest runs on main tick in documented order; no guest threads touching sim |

**Not Wasm's job:** stock content tables (layer 1), stream caps (layer 2), or
replacing ECS systems. Guest reads **views** (block at pos, player count, time)
and votes on **already-understood** requests.

**Order:** static Zig plugins (ADR 0005) first → prove hooks and budgets → then
Wasm guest loader implementing the same hook ABI. Do not land Wasm before the
native host exists.

**Explicit rejects:** in-process LuaJIT with FFI into `Game`; unrestricted WASI
filesystem/network; guest-authored NetPackage bodies; stock `Mods/` folder
compatibility.

### Explicit non-decisions

- **No** stock Harmony / IModApi / `Mods/` host (ADR 0003). **Do not promise**
  stock `Mods/` compatibility.
- **No** requirement that custom gamemodes load stock C# mods.
- **No** guest VM (Wasm/Lua/…) in the tick path **until** native plugin host +
  budgets ship; then guest is optional and sandboxed only.

## Implementation roadmap (ordered)

Do not skip ahead to scripting or dynlib gamemodes.

| Step | Work | Done when |
|---|---|---|
| **1** | Finish data-driven **stock content** (hardcode audit P0/P1): names + XML + AssignIds on production paths; loud warn if game-dir set and source still builtin | HARDCODE_AUDIT P0/P1 closed or explicitly waived |
| **2** | **`zdtd.toml`** (or equivalent) for tunables: stream, AI bands, wallets, feature flags; wire `InitOptions` / `Game` fields; document in GAME_OPTIONS | Operator changes caps without rebuild |
| **3** | **Gamemode** = config pack + optional **static** Zig plugin (`modes/*.toml` + `plugins/*.zig`) | One sample mode ships without forking join/wire |
| **4** | **Never** promise stock `Mods/` / Harmony compatibility | ADR 0003 stands |
| **5** | **Wasm guest loader** (optional): same hooks as PLUGIN_API, fuel/memory caps, command queue only | Mods load as `.wasm` + manifest; apm section `plugin_wasm`; abuse cannot break wire/tick invariants |
| **6** | Dynlib native plugins only if still needed after static + Wasm | PLUGIN_API P5.2 |

## Consequences

### Positive

- Clear fix target when something is "hardcoded": data loader vs config field vs
  Zig system + parameter + hook.
- Stock client fidelity stays in loaders + wire builders.
- Operators tune policy without rebuild once config surface lands.
- Extension path (plugins) does not fork `game.zig` forever.

### Negative / cost

- Content work is loader + RE effort, not a quick script paste.
- Gamemodes need Zig (or later dynlib) until plugin host ships.
- Dual discipline: every new const must be classified (stock / policy / system).

### Enforcement

- Code review and `audit-hardcoded-data` prompt (Bucket A vs B vs OK).
- AGENTS.md rules 13 (assets), 15 (authority), 24 (stdlib I/O), hot-path no-alloc.
- PLUGIN_API.md for any extension surface.
- This ADR's roadmap is the backlog order for data/config/plugin work.

## References

- ADR 0003 no stock mod host  
- ADR 0004 server-authoritative C2S  
- ADR 0005 native plugin API  
- ADR 0009 dynamic package ids  
- docs/ASSETS.md, docs/GAME_OPTIONS.md, docs/HARDCODE_AUDIT.md, docs/PLUGIN_API.md  

