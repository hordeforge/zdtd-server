# zdtd FPS Bot Addon — Technical Specification

**Status:** draft for review (awaiting the host integration facts; see
[IMPLEMENTATION_PLAN_BOTS.md](IMPLEMENTATION_PLAN_BOTS.md) for the build order).
**Owner:** Wasm plugin (ADR 0020) + a small, fixed host sense/act surface
(ADR 0026).
**Reference implementation for behaviour:** `../7dtd-clanker` C# mod and its
`docs/q3-inspiration-notes.md` (Q3 / Doom 3 `BotAimAtEnemy`, `BotCheckAttack`,
`BotChangeViewAngles`, `BotCharacter` skill blocks).

This document is the **technical contract**: what crosses the plugin boundary,
in what shape, and what responsibility the host keeps. The product intent,
scope and acceptance criteria are in [BOTS_PRD.md](BOTS_PRD.md). The
architecture decision is [adr/0026](adr/0026-fps-bot-wasm-module.md).

---

## 1. Goal and non-goals

**Goal.** An operator can add an FPS bot addon to zdtd by enabling one `.wasm`
module in `[plugin] modules`. The module spawns named, player-mesh bots that
hunt, lead-fire at and shoot real players, zombies and each other using a
Q3/Doom 3-inspired brain, obeying the same physics/collision/move caps as a
player. Bots persist (target count) and are manageable with `bot` admin
commands. Vanilla clients need no mod.

**Non-goals (explicit).**

- No client mod, no gamemode, no wire invention. The stock client sees a
  normal entity.
- No pathfinding synthesis in the host beyond what exists (bots may use the
  simple direct-steer + strafe model first; A* is a later enhancement, not v1).
- No "bot ethics" / team AI v1 (friendly-fire avoidance is host-side LOS only;
  BotVs filtering may come later).
- No persistent bot roster across restarts beyond a configured target count.
- No new host command verb parser: `bot <verb>` ships *in the plugin*, not in
  core (falls through to `unknown` when the module is absent).

---

## 2. Boundary contract (ADR 0020 / ADR 0026)

Data crosses as flat bytes in the guest's linear memory. The guest imports
host functions; the host calls guest exports. The guest never receives a host
pointer, never touches sim memory, and never injects wire bytes. Authority is
unchanged: the host owns spawn/tick/replicate/kill/LOS/move-caps; the guest
owns decisions.

### 2.1 Guest exports (what the module provides)

| Export | Signature | Purpose |
|---|---|---|
| `on_enable` | `() -> ()` | read config, allocate, log identity/version |
| `on_tick` | `() -> ()` | the brain loop: sense -> decide -> command (20 Hz) |
| `on_shutdown` | `() -> ()` | flush / final log |
| `on_admin_command` | `(cmd_ptr, cmd_len, out_ptr, out_cap) -> i32` | `bot help/list/status/spawn/remove/count/skill/...` |

`on_player_join` and the four verdict hooks are **not** required by bots v1
(pure additive addon), but a bot module *may* export them — e.g. an
`on_entity_killed` observer for kill feeds. Missing exports cost nothing.

### 2.2 Host imports the module may use

| Import | Signature | Notes |
|---|---|---|
| `zdtd.log` | `(level, ptr, len) -> ()` | existing |
| `zdtd.tick` | `() -> i64` | existing; gives the guest tick number |
| `zdtd.queue` | `(ptr, len) -> i32` | existing; raises its length bound (see §4) |
| `zdtd.sense` | `(ptr, len, token) -> i32` | **new**; host fills a world view into guest memory, returns bytes written |

`sense` is capability-gated: a module that does not import it cannot read the
sim, and a module that does is still read-only (it cannot mutate anything
directly).

---

## 3. The `sense` view (host -> guest)

The guest calls `zdtd.sense(scratch_ptr, scratch_len, token)` and the host
writes a **compact, fixed-layout snapshot** into the guest's linear memory at
`scratch_ptr` (bounded by `scratch_len`), then returns the number of bytes
written (`<=0` if the buffer is too small or the guest has no memory).

Layout is **authoritative and documented**; the guest never parses stock
package formats, it reads this view. v1 fields (all little-endian, packed with
no padding unless noted; fixed record stride so the guest can index without
parsing):

```
snapshot_header {
  u32 magic;          // 'ZBS1' - versioned; a mismatch means "ignore this tick"
  u32 count;          // number of sense records that follow
  u32 tick;           // host tick (mirrors zdtd.tick)
  i32 self_net_id;    // the calling bot's own net id, or -1
  i32 pad;
  // records follow at a fixed stride
}
bot_sense_record {
  i32 net_id;         // -1 for a bot-specific stat row
  u8  kind;           // 0 player, 1 zombie, 2 bot, ...
  u8  is_self;        // 1 if this is the requesting bot
  u8  alive;          // 1
  u8  pad;
  f32 x, y, z;        // position
  f32 hp;             // current health
  f32 yaw;            // facing (bot) or facing (player/zombie where known)
  i32 target_id;      // bot's current host-authorised target (-1 none)
}
```

The host caps `count` at a named limit (e.g. 64) so the buffer size is bounded
and the guest cannot demand unbounded world dumps. The host decides *which*
entities are visible (view distance from the bot; a named cap). Do **not**
retain the offset past the call — copy what you need (ADR 0020).

The `token` argument is reserved for future reverse-direction reads (e.g. ask
for a specific entity or a point query); v1 callers pass `0`.

**Determinism:** the snapshot is built each `on_tick` from the current sim
state, in stable order. The guest must not assume a stable ordering across
ticks for anything but `is_self`.

---

## 4. SimCommands (guest -> host, via `zdtd.queue`)

The guest enqueues text commands; the host parses, validates, and applies them
on the tick's drain (the fixed 64-slot command buffer; a full buffer drops new
commands — same as today). The 128-byte bound in
`src/server/game/wasm_host.zig` is raised to a named const (e.g. 256) so these
fit; the drain stays allocation-free.

Existing verbs are unchanged (`spawn`, `despawn`, `damage`). New bot verbs:

| Verb | Parsed as | Host applies | Illegal / dropped when |
|---|---|---|---|
| `bot spawn <name> [x z]` | spawn a named bot | pick spawn point: explicit x/z, else a configured default / farthest-from-players; allocate slot; replicate a player-mesh entity | name empty, no free slot |
| `bot remove <id\|all>` | despawn | destroy via the normal kill/cleanup path | id unknown |
| `bot move <id> <x> <y> <z> <speed>` | intent | clamp to the player move caps (same envelope as client C2S), set the bot's position/velocity for this tick; reject out-of-bounds coords | id unknown, coords NaN/out-of-bounds, speed<=0 |
| `bot look <id> <yaw>` | intent | set facing (drives which way the bot "aims") | id unknown |
| `bot shoot <id> <target_id>` | fire request | if the target is alive, in range and host-LOS-clear, apply weapon damage to it (existing damage/verdict path); else no-op | id/target known but LOS blocked or out of range |
| `bot count <n>` | population floor | keep `n` alive; auto-respawn to floor (clamped to MaxBots) | n>MaxBots (clamped) |
| `bot cfg <id> <key> <val>` | per-bot override | mutate the `BotDef` column (e.g. `skill 3`, `vision 40`, `reaction 0.35`) | unknown key (logged, ignored) |

The host treats a bot move exactly like a client move for authority (ADR 0004):
clamp, reject, apply the **resulting** state, and let interest replication
broadcast it — no self-echo, no redundant blobs.

---

## 5. Bot entity model (host ownership)

- **Kind:** add `bot` to `components.Kind`.
- **Columns:** the bot shares the base entity columns (transform, health,
  network id, alive mask) and gains a `BotDef` column: per-bot skill params
  (aim skill, reaction time, vision range/angle, fire throttle, strafe/dodge
  chance, aggression / self-preservation, rally point). A `Rules` value in
  `ecs/rules.zig` is the floor; per-bot data overrides it (stock-fidelity
  principle, ADR 0010).
- **Lifecycle:** spawn via `bot spawn`, destroyed via `bot remove` or death
  (kill verdict path; bots can die to players/zombies). Dead bot corpses follow
  the normal corpse sweep.
- **Replication:** bots replicate as ordinary entities to clients; the
  wire builder already handles the kinds it knows — the new kind needs a case
  so it is emitted as a player-mesh / SD entity the client can render, never
  leaking into zombie/trader/vehicle paths.
- **Aim is a host concern for validity but a guest concern for choice:**
  the host rejects an out-of-range / LOS-blocked shot; the guest decides when
  to shoot.

The `7dtd-clanker` behaviour model (weapon profiles, `LeadAimPoint` = velocity
prediction, reaction gate, burst fire, strafe/backpedal circling, dodge on
hit, DM spawnpoints, `Difficulty`/`skill` scaling) is the behavioural reference
and is re-expressed **inside the guest module**, exactly as the reference
distils Q3/Doom 3.

---

## 6. Admin commands (in the plugin, not core)

The module exports `on_admin_command`. Unknown admin verbs already route to
plugins (`tryDispatchPluginAdmin` in `src/server/admin_console.zig`), so no
core command table changes.

| Command | Behaviour |
|---|---|
| `bot help` | usage text |
| `bot status` | config + alive count / class / difficulty / vision / attack |
| `bot list` | per-bot: id, name, state, pos, target, hp |
| `bot spawn [name] [x z]` | spawn one bot (defaults to configured name/point) |
| `bot remove <id\|all>` | despawn |
| `bot count <n>` | keep n alive |
| `bot skill <0-4>` | set default difficulty for future spawns |
| `bot weapon <id\|mixed>` | loadout selection (if the guest carries weapon profiles) |

When the module is not loaded, `bot ...` reports as unknown (falls through),
which is honest: no bot addon, no bot commands.

---

## 7. Determinism and budgets

- **Fuel/memory:** the guest runs under the existing per-instance budget
  (default 100 M fuel, 1024 pages). `on_tick` work must be small; a guest that
  burns its budget every tick is disabled by the runtime — the system working,
  not a bug (PLUGIN_DEV.md).
- **No heap in host hot path:** the sense view is written into a fixed guest
  scratch region; bot commands go through the fixed 64-slot command buffer;
  `BotDef` is a fixed-size SoA column. Nothing allocates on the tick path.
- **Stable order:** plugin `on_tick` runs late in the tick
  (`src/server/game/step.zig`); commands enqueued by the guest drain on a later
  tick (command semantics: applied after the snapshot it saw). The module must
  not assume its commands apply within the same tick they were enqueued.

---

## 8. Files (expected shape; exact edits per implementation plan)

- `src/ecs/components.zig` — add `bot` to `Kind`; add `BotDef` component.
- `src/ecs/world.zig` — add `BotDef` column + `spawnBot` / bot awareness in
  spawn/despawn; the bot-in-tick code path.
- `src/ecs/command.zig` — add bot ops to `Op`; drain cases.
- `src/server/game/wasm_host.zig` — extend `parsePluginCommand`; raise the
  length bound; wire `sense` back to a host snapshot builder.
- `src/plugin/wasm.zig` — add the `zdtd.sense` import to `defineImports`;
  add a `sense` host-fn dispatch.
- `src/server/game/replicate.zig` + `src/wire/stock_entity.zig` — a case for
  the `bot` kind so it replicates as a client-visible entity.
- `src/server/game/tick.zig` / movement path — apply bot commanded intent with
  the player move envelope.
- `mods/zdtd_bot/zdtd_bot.c` (+ `.wasm` output) — the guest brain (Q3/Doom 3
  model). Build via the same clang→wasm32 path as `assets/fixtures/*.c`.
- `assets/fixtures/plugin_bot.c` / `.wasm` — a minimal bot host-surface
  fixture used by unit/scenario tests (sense round-trip, command parse).
- `docs/BOTS_SPEC.md`, `docs/BOTS_PRD.md`, `docs/adr/0026-*.md`,
  `docs/IMPLEMENTATION_PLAN_BOTS.md` — this contract and its plan.

## 9. Acceptance criteria (technical)

1. A `.wasm` bot module in `[plugin] modules` spawns bots; `bot list` shows
   them with ids/positions; `bot remove all` empties the world.
2. A bot hunts a real player: it moves toward the player (move commands
   applied under move caps) and, when in range + LOS, damages the player
   (`bot shoot` applies through the existing verdict path). Verified with
   loadgen smoke + stock client (EAC off) + apm (ADR 0019).
3. `zdtd.sense` returns a correct, versioned snapshot (magic, count, self id,
   positions/hp) — proven by a unit test with a real compiled fixture, not
   assumed.
4. A bot obeys move caps and LOS: a far/out-of-LOS shot is rejected as a
   no-op; a move beyond the envelope is clamped (ADR 0004).
5. Enable/disable round-trip: disabled module -> `bot` falls through to
   `unknown`; enabled module -> commands route to the plugin.
6. `make check` stays green; no hot-path allocation added (audit the drain and
   sense paths).
