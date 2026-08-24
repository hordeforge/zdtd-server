# zdtd FPS Bot Addon — Technical Specification

**Number:** RFC 0001
**Status:** decided and shipped (the host integration facts landed: `sense`/
`query` imports, bot verbs, host-side `BotManager`; see the ADR 0026 amendment).
This document records the contract as built; build order history is in
[IMPLEMENTATION_PLAN_BOTS.md](../IMPLEMENTATION_PLAN_BOTS.md).
**Owner:** Wasm plugin (ADR 0020) + a small, fixed host sense/act surface
(ADR 0026).
**Reference implementation for behaviour:** `../../../7dtd-fps-bots` C# mod and its
`../q3-inspiration-notes.md` (Q3 / Doom 3 `BotAimAtEnemy`, `BotCheckAttack`,
`BotChangeViewAngles`, `BotCharacter` skill blocks).

This document is the **technical contract**: what crosses the plugin boundary,
in what shape, and what responsibility the host keeps. The product intent,
scope and acceptance criteria are in [PRD 0001](../prd/0001-fps-bot.md). The
architecture decision is [ADR 0026](../adr/0026-fps-bot-wasm-module.md).

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
| `zdtd.query` | `(req_ptr, req_len, out_ptr, out_cap) -> i32` | **new**; reverse-direction point query — the guest writes a text request, the host writes a text response, returns bytes written (0 = no answer) |

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
  u32 magic;          // 'ZBS3' - versioned; a mismatch means "ignore this tick"
  u32 count;          // number of entity records that follow
  u32 tick;           // host tick (mirrors zdtd.tick)
  i32 self_net_id;    // the calling bot's own net id, or -1
  u32 world_time;     // world ticks, low 32 (day = /24000, hour = (%24000)/1000)
  u32 blood_moon;     // 1 while a blood moon is active, else 0
  // entity records follow at a fixed stride (header is 24 bytes)
}
bot_sense_record {
  i32 net_id;         // -1 for a bot-specific stat row
  u8  kind;           // 0 player, 1 zombie, 2 bot
  u8  is_self;        // 1 if this is the requesting bot
  u8  alive;          // 1
  u8  pad;
  f32 x, y, z;        // position
  f32 hp;             // current health
  f32 yaw;            // facing (bot) or facing (player/zombie where known)
  i32 target_id;      // bot's current host-authorised target (-1 none)
}
```

v3 (magic `ZBS3`) grew the header by 8 bytes (world_time + blood_moon at
offsets 16/20) so announcement/clock modules can schedule from the snapshot
without a separate query; the entity-record and event-trailer bases move with
it. Guests that only read v2 fields stop parsing at the record stride as
before.

After the entity records the host MAY append an **event trailer** (v2, magic
`ZBS2`): zero or more fixed 16-byte event records. The guest derives the event
count from the snapshot length (`(len - 16 - count*32) / 16`); a guest that
does not understand events simply stops parsing at the record stride. Two
kinds exist:

```
sense_event {
  u8  kind;           // 3 = damage event, 4 = bot-info record
  u8  pad[3];         // for kind 4, byte 1 = weapon_id (loadout-pool index)
  i32 field_a;        // damage: attacker net id | bot-info: bot net id
  i32 field_b;        // damage: victim net id | bot-info: 0
  f32 amount;         // damage: damage applied | bot-info: 0
}
```

- **Kind 3 (damage):** someone attributed a hit on a live bot. The host writes
  one per attributed hit (`BotManager.damageFrom`, from both the C2S player
  damage path and `bot shoot`) and drains the buffer on the next sense call.
  The guest uses them for retaliation (§5.1), never for authority — the host
  already applied the damage.
- **Kind 4 (bot info):** the host writes one per live bot each sense pass,
  before the damage events, carrying the bot's host-assigned `weapon_id`
  (index into `bot_loadout_pool` in `src/server/game/bot.zig`). The guest
  builds its per-bot weapon map from these so the brain can adapt engagement
  range, burst size and lead to the weapon (§5.1).

The host caps `count` at a named limit so the record set plus the event
trailer fit the guest's fixed scratch buffer (the plugin host reserves room for
`max_sense_events` before counting records). The host decides *which* entities
are visible (view distance from the bot; a named cap). Do **not** retain the
offset past the call — copy what you need (ADR 0020).

The `token` argument is reserved for future reverse-direction reads (e.g. ask
for a specific entity or a point query); v1 callers pass `0`. Reverse-direction
*queries* ship as the separate `zdtd.query` import: the guest writes a small
text request into its own memory and the host answers in a response buffer.
Requests are host-budgeted (bounded text, no sim mutation). Queries:

| Request | Response | Meaning |
|---|---|---|
| `cover <x> <z> <tx> <tz>` | `<cx> <cz>` (or empty) | a point near (x,z) that is NOT visible from (tx,tz), or nothing when no cover exists (Doom 3 idAASFindCover / clanker `BotBrain.FindCover` port; used by the cover retreat, §5.1) |

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
| `bot shoot <id> <target_id> [head]` | fire request | if the target is alive, in range and host-LOS-clear, apply weapon damage to it (existing damage/verdict path); the optional `head` token applies the 2x headshot multiplier (cross-pollinated from clanker `TryShootBurst`) | id/target known but LOS blocked or out of range |
| `bot count <n>` | population floor | keep `n` alive; auto-respawn to floor (clamped to MaxBots) | n>MaxBots (clamped) |
| `bot cfg <id> <key> <val>` | per-bot override | `vision` / `reaction` overrides on that bot (0 resets to the skill-derived default); personality keys `agg` / `selfpres` / `venge` / `camp` / `alert` (0..1, negative resets to the deterministic skill/net default) | unknown key (rejected) |

The host treats a bot move exactly like a client move for authority (ADR 0004):
clamp, reject, apply the **resulting** state, and let interest replication
broadcast it — no self-echo, no redundant blobs.

---

## 5. Bot entity model (host ownership)

- **Not ECS:** bots are deliberately **not** ECS entities. The ECS owns
  players, zombies, traders, vehicles, turrets, loot bags and animals only;
  bots live in a host-side `BotManager` (`src/server/game/bot.zig`) with a
  fixed 16-slot table. The only boundary between a bot and the sim is the Wasm
  sense/command surface (`zdtd.sense` / `zdtd.queue`).
- **Ids:** bots allocate net ids from the shared sim counter
  (`Game.allocBotNetId` → `World.next_net_id`), so they never collide with ECS
  entity ids.
- **Config:** `BotDef` / `BotDefDefault` / `applySkillFloor` (Q3/Doom 3 skill
  preset: aim skill, reaction time, vision range/angle, fire throttle,
  strafe/dodge chance, aggression / self-preservation) are shared config in
  `src/ecs/components.zig`, used by the BotManager. A `Rules` value is the
  floor; per-bot data overrides it (stock-fidelity principle, ADR 0010).
- **Lifecycle:** spawn via `bot spawn` / `bot count` (population floor),
  destroyed via `bot remove <id|all>` or death. **Players can kill bots:** the
  C2S `NetPackageDamageEntity` handler resolves a non-ECS target through
  `BotManager.damageFrom` with the same trust gates as ECS targets (actor
  validated, claimed strength capped, interest-range gated); the hit is
  attributed to the player so the guest can retaliate. **Zombies fight bots
  too:** the zombie AI reaches bots through the World's `bot_snap_fn` /
  `bot_damage_fn` hooks (wired by Game) — with no player sensed, a zombie
  acquires the nearest live bot within its sight range (proximity aggro), and
  a bot's shot sets the zombie's revenge target so it hunts the shooter even
  at range; in melee the zombie applies its normal attack damage through
  `BotManager.damageFrom`, so the bot records the zombie attacker and the
  guest dodges/retaliates. Bots stay **out of the ECS** throughout: the hooks
  are the only boundary. A bot killed by `bot shoot`, player damage or zombie
  melee dies in place. Dead/removed bots are unspawned from every viewer's
  `known_bots` bitset by the bot replication path.
- **Terrain:** bots are grounded onto the terrain surface on spawn and every
  move tick (`Game.groundHeight`, chunk heightAt + 1), so they follow hills
  instead of floating at a fixed spawn height on real maps.
- **Replication:** bots replicate to clients through a **separate non-ECS
  path** in `src/server/game/replicate.zig` (spawn-on-approach / range-remove /
  PosAndRot fan-out against the same interest grid as ECS entities). Spawns use
  the player-mesh class (hash 2001454542, the same class_table[0] default),
  never leaking into zombie/trader/vehicle paths.
- **Aim is a host concern for validity but a guest concern for choice:**
  the host rejects an out-of-range / LOS-blocked shot; the guest decides when
  to shoot.

The `7dtd-fps-bots` behaviour model (weapon profiles, `LeadAimPoint` = velocity
prediction, reaction gate, burst fire, strafe/backpedal circling, dodge on
hit, DM spawnpoints, `Difficulty`/`skill` scaling) is the behavioural reference
and is re-expressed **inside the guest module**, exactly as the reference
distils Q3/Doom 3.

### 5.1 Brain behaviours implemented (module v1.2)

All inference is deterministic: no wall-clock noise, only a per-slot LCG seeded
from the net id and slot index (AZ 22). Improvements are cross-pollinated with
`7dtd-fps-bots` in both directions.

- **Skill-scaled aim error.** Each engagement a bot rolls a fixed angular
  error from the per-slot LCG (`skill_aimerr`: ~0.28 rad at skill 0 down to
  ~0.06 rad at skill 4), held for the engagement so aim settles rather than
  jitters. Low-skill bots spray; high-skill bots are near-deadly.
- **Target selection.** Nearest alive non-self candidate within vision wins, but
  players are preferred over zombies/other bots at equal distance (player score
  `* 0.82`, other bot `* 0.9`, squared for the d2 comparison — cross-pollinated
  from clanker `BotBrain.FindTarget`). Candidates beyond a skill-scaled FOV cone
  (`skill_fov`, ~90 deg at skill 0 to ~170 deg at skill 4) are not acquired
  unless they are within `CLOSE_SPOT_RANGE` blocks, mirroring clanker's
  `VisionAngle`.
- **Lead-fire.** The guest estimates target velocity from its own sense
  history and aims at a predicted position a time-of-flight ahead
  (`BULLET_SPEED`); a stationary target yields lead 0 and degrades to direct
  fire. No host/spec change required.
- **Lost-sight combat memory.** A target behind LOS vanishes from the snapshot;
  the bot retains `BOT_MEMORY_TICKS` (5 s) of the last-known position and
  pursues it, then flushes and reverts to patrol.
- **Dodge-on-hit.** The guest watches its own hp in the sense record; when it
  drops, the bot enters a short evasive dodge (`DODGE_TICKS`: backpedal then a
  hard strafe on a randomized direction) whose moves bypass command gating so
  the host always sees the burst (cross-pollinated from clanker `Bot.OnDamaged`).
- **Retaliation (grudge).** The host attributes every hit on a live bot as a
  damage event in the sense trailer; the victim bot sets a grudge on the
  attacker (decaying after `GRUDGE_TICKS` = 15 s at mid-point vengefulness)
  and the grudged net id out-scores equally-distant threats during target
  selection, so the bot turns on whoever shot it. Being hit also halves any
  pending reaction gate ("quicker when shot") and a heavy hit (>25 damage)
  staggers the dodge longer. Cross-pollinated from clanker `Bot.OnDamaged`
  (aggro swap `Rng01() < 0.65f`, `ReactionTime * 0.5`).
- **Wounded preference.** A hurt candidate out-scores a healthy one at the
  same range (`score += hp * 0.02`, clanker `BotBrain.FindTarget` parity), so
  bots finish off the wounded instead of flitting to a fresh target.
- **Per-bot personalities (Q3 `BotCharacter` subset).** Each bot rolls
  aggression, self-preservation, vengefulness, camper and alertness
  deterministically from (skill, net id) at spawn (stable per bot, no
  wall-clock noise) and they are overridable via `bot cfg`:
  - *Aggression* gates how far a bot will chase (`26 + agg*30` blocks; a
    grudged target is always chased) and whether it fights on while hurt
    (retreat threshold `0.20 + selfpres*0.25` only applies when `agg < 0.7`).
  - *Self-preservation* raises the retreat threshold (clanker
    `WantsToRetreat`: `hp < 0.35 + SelfPreservation*0.18`).
  - *Vengefulness* scales grudge duration (`GRUDGE_TICKS * (0.5 + venge)`) and
    the grudge score bias (`0.85 - 0.35*venge`).
  - *Camper* periodically holds position and sweeps the facing (~5 s) when
    healthy instead of roaming (clanker `WantsToCamp`).
  - *Alertness* scales vision range (`0.8 + 0.4*alert`) and reaction time
    (`1.2 - 0.4*alert`).
- **Cover-seeking retreat (Doom 3 `idAASFindCover` / clanker
  `BotBrain.FindCover` port).** A retreating bot (low hp + careful personality,
  or fleeing) asks `zdtd.query` `cover` for a point near it that is NOT visible
  from its current threat, heads there (re-querying every ~0.4 s) and holds,
  breaking LOS instead of backpedaling in the open. With no cover available it
  falls back to the plain backpedal/circle.
- **Ammo pacing (Q3 bots managed ammo).** Each weapon has a magazine and a
  reload time (`weapon_mag`/`weapon_reload`, matching clanker
  `WeaponProfile.MagSize/ReloadSec`): every trigger pull consumes a round
  whether it hits or misses, and an empty magazine starts a reload during
  which the bot holds fire (and keeps strafing / seeking cover). Purely
  guest-side pacing — the host applies damage per accepted `bot shoot` and
  never sees a magazine.
- **Weapon-aware tactics (clanker `WeaponProfile` parity).** The host picks
  each bot's loadout at spawn and exposes it via the kind-4 bot-info sense
  record; the brain adapts: *engagement range* follows the weapon
  (`weapon_range * (0.85 + 0.05*skill)`, always under the host's enforced
  range so ordered shots are not rejected), *burst size* follows the weapon
  (sniper/shotgun 1, pistol 2, ak 3, smg/auto 4), *lead scale* follows the
  weapon (precision weapons lead fully, spread weapons barely), and
  *long-range weapons keep their distance* (backpedal below half the weapon
  range). Sniper bots hang back and one-shot; shotgun bots close and blast.
- **Reaction gate + fire throttle.** A fresh target is not engaged until a
  skill-scaled reaction delay elapses; shots are gated by a burst cadence.
- **Burst volley.** Each fire window queues a 2-shot (skill < 3) or 3-shot
  (skill >= 3) burst, every shot with its own hit and headshot roll
  (cross-pollinated from clanker `Weapon.BurstMin/BurstMax`).
- **Skill/distance hit accuracy.** A shot only lands when a deterministic roll
  beats `skill_hit_chance(skill, dist)` (cross-pollinated from clanker
  `TryShootBurst` spread/difficulty), so low-skill bots miss. A second
  skill-scaled roll flags a headshot (`skill_headshot`, ~5% at skill 0 to ~25%
  at skill 4), and the host applies the 2x `bot_headshot_multiplier`.
- **Backpedal + low-hp retreat.** Bots back away when an enemy is inside
  `BACKPEDAL_RANGE`; low-health, low-skill bots retreat and hold fire
  (`HP_RETREAT_FRAC`, cross-pollinated from clanker `BotBrain.Backpedal` /
  `BotCharacter.WantsToRetreat`). Nearly-dead bots of ANY skill flee
  (`HP_FLEE_FRAC` 0.20), matching clanker's skill-independent survival.
- **Strafe-orbit vs chase** with skill>=3 bots flipping strafe direction on a
  deterministic cadence.
- **Command gating.** `bot move`/`bot look` only re-emit on change (or first
  contact), cooperating with the host's stream/move caps (AD 20, AZ 20).
- **Stuck detection.** A patrol bot that makes no progress for `STUCK_TICKS`
  (1 s) re-picks its wander point, and a memory-pursue bot jukes its
  destination perpendicularly to go around the obstacle (cross-pollinated from
  clanker `_stuckSince` + `JumpOrStrafe`).

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
| `bot skill <0-4> [id]` | set default difficulty for future spawns, or (with an id) override that bot's skill |
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
  scratch region; bot commands dispatch straight to the host `BotManager`
  (fixed 16-slot table, no command-buffer ops); nothing allocates on the tick
  path.
- **Stable order:** plugin `on_tick` runs late in the tick
  (`src/server/game/step.zig`); commands enqueued by the guest drain on a later
  tick (command semantics: applied after the snapshot it saw). The module must
  not assume its commands apply within the same tick they were enqueued.

---

## 8. Files (expected shape; exact edits per implementation plan)

- `src/server/game/bot.zig` — the host-side `BotManager`: fixed 16-slot bot
  table, `bot move/look/shoot/spawn/remove/count` parsing + dispatch, move
  integration, and the sense `fillSense` record writer. No wire imports.
- `src/server/game.zig` — owns a `BotManager` field, `allocBotNetId` (shared
  sim id counter), and the `tickBots` delegate.
- `src/server/game/wasm_host.zig` — `wasmQueue` routes `bot ...` commands to
  the BotManager; `wasmSense` merges ECS actor records with the BotManager's
  bots (kind 2) and the damage-event trailer (kind 3) in one snapshot;
  `parsePluginCommand` keeps only the ECS verbs
  (`spawn`/`despawn`/`damage`).
- `src/server/game/replicate.zig` — the non-ECS bot replication path
  (spawn-on-approach / range-remove / PosAndRot) plus per-client
  `Client.known_bots` tracking.
- `src/plugin/wasm.zig` — add the `zdtd.sense` import to `defineImports`;
  add a `sense` host-fn dispatch.
- `mods/fps_bot/bot.c` (+ `.wasm` output) — the guest brain (Q3/Doom 3
  model), unchanged: it only talks through `zdtd.sense` / `zdtd.queue`. Build
  via the same clang→wasm32 path as `assets/fixtures/*.c`.
- `assets/fixtures/plugin_bot.c` / `.wasm` — a minimal bot host-surface
  fixture used by unit/scenario tests (sense round-trip, command parse).
- `docs/rfc/0001-fps-bot-spec.md` (RFC 0001), `docs/prd/0001-fps-bot.md` (PRD 0001),
  `docs/adr/0026-*.md`, `docs/IMPLEMENTATION_PLAN_BOTS.md` — this contract and its plan.

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

## 10. Parity with clanker (reference implementation)

The guest is behaviorally cross-pollinated from the clanker C# mod. The parity
ledger, what is in sync, tunable divergences, weapon-mag discrepancies vs game
data, and the open alignment decisions, is
`../../../7dtd-fps-bots/docs/research/REPORT-2026-08-21-R13-static-bot-parity.md`
(clanker `docs/research/INDEX.md` maps the full R-series). This spec describes
the intended contract; R13 records where the guest and the reference actually
diverge today. Any alignment change to the guest updates
`mods/fps_bot/bot.c` + the `.wasm` rebuild, keeps `make check` green, and
updates this spec and R13 in step.
