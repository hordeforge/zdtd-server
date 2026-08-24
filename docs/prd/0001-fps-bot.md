# FPS Bot Addon — Product Requirements (PRD)

> **Purpose:** product requirements for the FPS bot addon — what the bot addon must do, for whom, and how it is accepted.

**Number:** PRD 0001
**Status:** shipped (bot module + host surface live: `mods/fps_bot/`,
`src/server/game/bot.zig`; see the ADR 0026 amendment and
[IMPLEMENTATION_PLAN_BOTS.md](../IMPLEMENTATION_PLAN_BOTS.md)).
**Owner:** server operators / dev staging (the addon is not a stock feature).
**Ships as:** an **official mod** (PRD 0005 tier model: shipped in-tree under
`mods/fps_bot/`, auto-discovered via `mod.toml`, disable-able via
`[mods] disabled`, overridable by user mods via `override = "fps_bot"`). The
module is Wasm (ADR 0020 / ADR 0026) + a small host sense/act surface.
**Behavioural reference:** `../../../7dtd-fps-bots` (the stock-server FPS bot C# mod),
Q3 / Doom 3 bot AI distilled there.
**Related:** [RFC 0001](../rfc/0001-fps-bot-spec.md) (technical contract) · [ADR 0026](../adr/0026-fps-bot-wasm-module.md) (decision) · [PLUGIN_API.md](../PLUGIN_API.md) · [PLUGIN_DEV.md](../PLUGIN_DEV.md)

---

## 1. Background and problem

zdtd is a clean-room dedicated server for 7 Days to Die. A stand-alone server
is empty until humans join; there is tension, zombie pressure to hold back, and
no one to populate a map for testing or for low-population periods. The stock
ecosystem has a bot mod (`../../../7dtd-fps-bots`), but it is a **C# stock-host mod** —
which, per ADR 0003, zdtd does not host.

We want the same end result — *a server populated with credible, shootable,
killable FPS bots* — delivered the way zdtd extends itself: as a **Wasm
plugin addon**. This gives operators bots that:

- fill empty or low-population periods with hostile NPCs;
- give developers/QA live targets without manually spawning zombies;
- demonstrate the Wasm plugin ecosystem with a non-trivial, gameplay-relevant
  module.

## 2. Personas

- **Operator** — runs a zdtd server, wants a populated-but-fair world,
  spawns/removes/counts bots, tunes difficulty.
- **Developer/QA** — needs stable, scriptable targets for loadgen / client
  playtest; wants to observe bot behaviour deterministically.
- **Player** — on a vanilla client, wants to meet and fight believable enemy
  NPCs that move, dodge, and shoot back, using normal game mechanics.

## 3. Goals

1. Enable bots as a drop-in addon (one `.wasm` in `[plugin] modules`), no host
   fork, no client mod.
2. Bots are **believable enemy NPCs**: they hunt players, lead-fire, strafe,
   dodge when hit, and respect difficulty, health, and death — like the
   Q3/Doom 3 skill model the reference implements.
3. **Authority is preserved**: bots obey the same move caps, collision, line of
   sight and damage/verdict rules as clients (server authoritative).
4. Operators have simple, documented commands to **add, remove, count, and
   tune** bots.
5. Physics/collision "no godmode" promise from the reference carries over: a
   bot is as killable and as bound by the world as a player.

## 4. Scope

### In scope (MVP)

- A `.wasm` bot module with the Q3/Doom 3-inspired brain: target selection,
  reaction gate, aim jitter + leading, burst fire, strafe/backpedal, dodge on
  hit, difficulty (skill 0–4) scaling.
- Host `sense` view + extended SimCommands (spawn/remove/move/look/shoot/
  count/cfg) to make the brain possible within the plugin boundary.
- A `bot` kind entity that replicates to vanilla clients and obeys move/LOS
  caps.
- Admin console commands: `bot help`, `bot status`, `bot list`, `bot spawn`,
  `bot remove`, `bot count`, `bot skill`.
- Population floor: `bot count <n>` keeps n bots alive (auto-respawn), mirroring
  the reference's `TargetBotCount`.
- Documentation (this PRD, the SPEC, ADR, and an implementation plan).

### Out of scope (later, only with demand)

- Pathfinding/A* (v1 uses direct-steer + strafe; a real pathfinder is a
  follow-up).
- Bot-vs-bot teaming / BotVs filtering / FFA scoreboard.
- Persistent bot roster across restarts (only a configured target count).
- Weapon-specific exotic loadouts, campers, quest-aware bots.
- No gamemode/connect integration.

## 5. User stories

- As an **operator**, I can add `mods/fps_bot/bot.wasm` to `[plugin] modules` and
  restart to see 6 bots alive immediately (default `bot count 6`).
- As an **operator**, I can run `bot count 12`, `bot remove 3`, `bot remove
  all`, `bot skill 3` from the admin console and see the world reflect it.
- As an **operator**, I can run `bot list` to see each bot's id, name, state,
  position, current target and health, so I can debug or target individual bots.
- As a **developer**, I can script `bot spawn Grunt_42 100 64 300` to place a
  named bot at a harness point for a loadgen/playtest scenario.
- As a **player**, a bot I can see hunts me, leads its shots, ducks/strafe, and
  can be killed with normal weapons; I do not need a client mod.
- As a **QA engineer**, I can watch a bot fail to shoot through a wall (LOS) or
  fail to move beyond its speed cap, because the host enforces it regardless of
  what the bot thinks.

## 6. Functional requirements

- **FR-1 (spawn/despawn):** `bot spawn [name] [x z]`, `bot remove <id|all>`;
  spawn picks a sane point (explicit, else default/farthest-from-players).
- **FR-2 (population floor):** `bot count <n>` keeps n alive; clamped to
  `MaxBots`; auto-respawn toward the floor.
- **FR-3 (move):** bots move under the player move envelope; no godmode/no-clip.
- **FR-4 (shoot):** bots deal damage only when target is in range and host-LOS
  clear, through the normal damage/verdict path.
- **FR-5 (sense):** a bot can read a bounded world view (positions, health,
  kinds, self id) to make decisions.
- **FR-6 (commands):** `bot help/status/list` are informative and clean when
  the module is absent (`unknown`).
- **FR-7 (skill):** `bot skill <0-4>` and per-bot `bot cfg` tune aim/reaction/
  vision like the reference difficulty presets.
- **FR-8 (death):** bots can die (killed by players/zombies); death uses the
  normal kill/verdict path; corpses sweep normally; killed bots re-respawn per
  the floor.

## 7. Non-functional requirements

- **NFR-1 (performance):** no hot-path allocation in host; bots fit the 20 TPS
  budget; a guest that burns its fuel is disabled, not fatal. Sense crosses once
  per tick in a bounded view.
- **NFR-2 (correctness/authority):** bots obey stock move caps, LOS and verdict
  rules; illegal requests are clamped/dropped, never applied blindly.
- **NFR-3 (clean-room):** the bot is a new `.wasm` module + a documented host
  extension; the brain is re-inspiration of Q3/Doom 3 as the reference does, not
  TFP code (ADR 0002/0014).
- **NFR-4 (isolation):** a broken bot module disables only itself; the server
  and other plugins are unaffected (ADR 0020).
- **NFR-5 (validation):** loadgen smoke + stock client (EAC off) + apm, not
  unit tests alone (ADR 0019).
- **NFR-6 (fidelity):** same "no godmode" physics/collision promise as the
  reference: only the spawn loadout differs.

## 8. Acceptance criteria (product)

- AC-1. With the module enabled, the world contains the configured number of
  bots within a short startup window; `bot list` enumerates them.
- AC-2. A real player (stock client, EAC off) sees the bot as a normal hostile
  entity, can be damaged by it in range/LOS, and can kill it; the corpse behaves
  like a normal entity.
- AC-3. A bot does **not** shoot through a wall or shoot beyond its effective
  range; a bot does **not** teleport or exceed the move envelope.
- AC-4. `bot remove all` empties the world; `bot count <n>` restores to `n`.
- AC-5. Disabling/removing the module makes `bot` commands report clearly as
  unknown — the server is not coupled to the addon.
- AC-6. A bot that traps/exhausts fuel disables itself without taking the
  server or other plugins down.

## 9. Risks and mitigations

- **New host surface is permanent (sense + commands):** gate it (ADR 0020),
  version the snapshot, test with a real compiled fixture before relying on it.
- **Adding a `Kind` touches every `switch(kind)`:** audit and cover each site;
  leaks into other kinds are caught by tests (NFR-2).
- **Brain quality vs engine effort:** v1 uses the proven direct-steer + strafe
  model from the reference, not an over-engineered pathfinder; A* is an explicit
  follow-up, not a v1 blocker.
- **Fuel budget on the brain loop:** the reference brain is per-bot simple
  math; keep per-tick work small, document budget guidance (PLUGIN_DEV.fuel).

## 10. Milestones (see IMPLEMENTATION_PLAN_BOTS.md)

- **M0** — host surface: `bot` kind + `BotDef` + command ops + `sense` import.
- **M1** — guest: Q3/Doom 3 brain module + admin commands (spawn/remove/list/
  count/skill).
- **M2** — movement + LOS + shoot integration (the triad validation).
- **M3** — polishing: skill presets, per-bot cfg, docs final pass, `make check`
  green, loadgen smoke + stock-client evidence.

## 11. Out-of-scope signpost

Pathfinding/A*, BotVs teaming/scoreboards, persistent rosters, quest-aware
bots, client-side integration — deliberately deferred; revisit only with real
demand, not speculative scope.
