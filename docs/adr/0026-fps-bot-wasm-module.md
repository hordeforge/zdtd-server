# 0026. FPS bots as a Wasm module: a host sense/act boundary, not a core bot brain

- **Status:** accepted
- **Date:** 2026-08-12
- **Related:** [ADR 0020](0020-wasm-only-plugin-api.md) (Wasm is the only
  plugin format), [ADR 0004](0004-server-authoritative-c2s.md) (server is
  authoritative), [ADR 0010](0010-data-config-zig-plugins.md) (no script VM in
  the tick-path core), [ADR 0003](0003-no-stock-mod-host.md) (zdtd is not a
  stock mod host), [ADR 0019](0019-validation-triad.md) (loadgen + stock
  client + apm).

## Context

People who operate a zdtd server want populated worlds without real players.
The reference behaviour is the `../7dtd-clanker` C# mod (a stock-server mode that
spawns player-mesh FPS bots that hunt, shoot and strafe, driven by a
Quake 3 / Doom 3-inspired brain — see `../7dtd-clanker/docs/q3-inspiration-notes.md`
and the ported `BotCharacter` / `BotAimAtEnemy` / `BotCheckAttack` /
`BotChangeViewAngles` model). We want the same gameplay as an **addon**, not a
fork, and `src/plugin/` already exposes a Wasm plugin host.

The problem is that the current plugin boundary is too thin to drive an FPS
bot. What a guest can do today (PLUGIN_DEV.md):

- **See:** nothing. The only data a guest can read back is `zdtd.tick() -> i64`.
  A bot cannot learn a target's position, health, or its own state.
- **Act:** `zdtd.queue` accepts three text verbs — `spawn`, `despawn`,
  `damage`. There is no way to move an entity, face it, or make it fire.
- **Exist:** there is no bot entity. Spawning a zombie is not a named,
  player-mesh shooter that hunts *real players*.

So "bots as a Wasm module" is not currently expressible. Someone would have to
either (a) shove the entire brain into Zig core, or (b) grow the plugin
surface. This ADR chooses (b) and fixes exactly how much to grow, so the
authority model and the hot path stay intact.

### Who owns what (the boundary we must not violate)

ADR 0020 is strict: a plugin requests **high-level operations** the core
already understands, may deny/adjust a request, and never injects package
bytes, invents wire types, or touches sim memory directly. That model is a
feature and must survive. Therefore:

- The **guest** owns the *brain*: target selection, aim/leading, reaction
  timing, strafe/dodge decisions — the Q3/Doom 3 skill model.
- The **host** owns the *body*: the bot entity's lifecycle, replication to
  clients, collision/move caps, LOS validity, and damage application.

The guest never talks to the wire. It asks the host "what am I looking at and
where," decides, and asks the host "move this bot here, face it there, fire at
that target." If the request is illegal (bot out of bounds, target gone), the
host drops or clamps it like any client move. Same authority as ADR 0004.

### Why a new entity kind, not "bot = zombie"

zdtd zombies already chase, wander and melee (`ZombieAi`), but they have no
name, no ranged fire, and their AI is host-side. Reusing the zombie kind would
mean bolting a named shooter onto `ZombieAi`, which fights the per-kind column
layout and gives the guest nothing to command. A dedicated `.bot` kind keeps
the plugin-commanded responsibilities explicit and off the zombie path.

## Decision

### 1. bots are a first-class sim entity kind, host-managed

Add `bot` to `components.Kind`. A bot is a player-mesh entity (name, position,
health) that the host spawns, ticks, replicates and destroys exactly like other
entities. It carries a `BotDef` column (per-bot skill parameters ported from
the Q3/BotCharacter model: aim skill, reaction time, vision range/angle, fire
throttle, strafe/dodge chance, aggression/self-preservation). The host applies
the bot's *commanded intent* (position/velocity, facing, fire-request) each
tick and broadcasts resulting state to clients — a bot never bypasses the move
caps or the kill/verdict path. The client needs no mod: it sees a normal
entity (same principle as the 7dtd-clanker's vanilla-client stance).

### 2. a single read-only "sense" host import is added

Add one capability-gated host import, `zdtd.sense(ptr, len, token) -> i32`,
which the guest calls to pull a compact, fixed-layout world snapshot into its
own linear memory. The snapshot is **flat bytes, enumerated by net id** and
authored by core builders, so the guest cannot fabricate positions or health.
The host fills the buffer as a view (entity kind tags, net ids, x/y/z, hp) for
the entities the guest is allowed to see, plus the bot's own state. This is the
mirror image of the existing request/reply hooks (same scratch-region
technique) and stays within ADR 0020: data crosses as flat bytes, capability-
gated, budgeted.

### 3. the SimCommand text set is extended (and the length bound raised)

Extend `src/server/game/wasm_host.zig`'s `parsePluginCommand` and
`src/ecs/command.zig` `Op` with bot verbs:

| Verb | Shape | Effect (applied by host on drain) |
|---|---|---|
| `bot spawn <name> [x z]` | spawn a named bot | allocate slot, pick spawn point, replicate entity |
| `bot remove <id\|all>` | despawn | destroy entity (kill verdict path, corpse/cleanup) |
| `bot move <id> <x> <y> <z> <speed>` | commanded intent | clamp to move caps, set position/velocity for the tick |
| `bot look <id> <yaw>` | face | set facing (aim direction for fire) |
| `bot shoot <id> <target_id>` | fire request | apply damage to target if LOS and in range |
| `bot count <n>` | population floor | keep n bots alive (auto-respawn), like 7dtd-clanker TargetBotCount |
| `bot cfg <id> <key> <val>` | per-bot skill override | mutate the BotDef column |

The 128-byte queue bound is raised to a named cap that fits these commands and
a small margin; the drain path remains allocation-free (fixed ops array).

Spawn-point selection, move blocking, LOS and damage are **core, stock-legal
operations** — never guest-side guesses.

### 4. commands (add/remove/list) live behind the existing plugin admin hook

The `bot <verb>` console/admin commands are handled by the guest's exported
`on_admin_command` (already supported by ADR 0020 / PLUGIN_DEV.md), which falls
through to core `unknown` when the plugin is absent. `bot help`, `bot list`,
`bot status`, `bot spawn`, `bot remove`, `bot count`, `bot skill` all ship in
the module; the host routes unknown admin verbs to plugins exactly as today.
If the module is not loaded, `bot ...` reports as unknown — no host-side bot
command parser is added.

## Consequences

### Positive

- The brain is a drop-in `.wasm`; operators enable bots by listing one module,
  with no host fork and no client mod.
- The hot path stays allocation-bounded: the guest runs under the existing
  fuel/memory budget; sense crosses once per tick as a fixed-size view; bot
  commands go through the fixed 64-slot command buffer.
- The Q3/Doom 3 skill model lives where it is a trade secret of the modder, not
  a permanent host API. Per-bot params in `BotDef` stay data (ADR 0010) and a
  `Rules` floor.
- Authority is preserved: bots obey move caps, kill verdicts and LOS exactly
  like clients; a runaway plugin cannot spoof positions or bypass damage.

### Negative / costs

- Adding a `Kind` member touches every `switch (kind)` in the codebase; the
  replication/verdict paths need a case (must not leak into other kinds).
- The `sense` snapshot is a new permanent host import; per ADR 0020 everything
  permanent lands only with evidence, so it must ship with a fixture + test
  proving the fields round-trip.
- Real collision/LOS handling lives in core, so a naive guest can still ask for
  illegal movement; the host must clamp, which is core work, not plugin math.

### Alternatives considered

| Option | Why not |
|---|---|
| Bots as zombies reusing `ZombieAi` | No name/fire/guest-command seam; mixes melee-wander AI with a ranged shooter |
| Bot brain entirely in Zig core | Not the requested "addon"; forks the server for every bot tweak; ADR 0020 says extend without forking |
| Guest emits wire bytes (give plugins `sendStock`) | Violates ADR 0020's "never inject package bytes"; the correct builders are the host's to own |
| No-mode client bot (connect mod) | Gamemode/connect tooling stays join-only per AGENTS rule 9; bots are server-side sim |

## Follow-up

Delivery tracked in [IMPLEMENTATION_PLAN_BOTS.md](../IMPLEMENTATION_PLAN_BOTS.md);
spec and product requirements in [BOTS_SPEC.md](../BOTS_SPEC.md) and
[BOTS_PRD.md](../BOTS_PRD.md). Validation is the loadgen smoke + stock client
(EAC off) + apm triad (ADR 0019), not unit tests alone.
