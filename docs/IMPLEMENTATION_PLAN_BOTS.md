# FPS Bot Addon — Implementation Plan

**Status:** execution plan for ADR 0026 / RFC 0001 / PRD 0001.
**Anchored in the current tree** with exact `file:line` references confirmed by
an explore pass (2026-08-12). Milestones M0–M3. Nothing here delegates the
brain to core; the guest owns decisions, the host owns the body and the wire.

---

## Grounding facts that shape the plan (confirmed)

- **Command buffer bound is a single host const.** The 128-byte text bound is
  enforced only at `src/server/game/wasm_host.zig:48` (`max_plugin_cmd_len`);
  the `zdtd.queue` import layer (`src/plugin/wasm.zig:507`) has no length cap.
  Bot commands fit in 128 bytes; raise to a named 256 const only as a margin.
- **Adding `bot` to `components.Kind` forces one exhausting switch arm**:
  `ecs/world.zig:639` maps Kind → class_table index and has **no `else`**
  (compile error until an arm exists). All other Kind-conditional code uses
  `==` or `else`, so it is safe by default.
- **Replication: `.bot` must be added to `is_mob`** at
  `src/server/game/replicate.zig:85-87` or bots never get spawn fan-out to
  clients. Positional replication (`replicate.zig:164-176`) is kind-independent
  (gated on `mask.transform` + `mask.network_id`), so no work there. The wire
  builder `stock_entity.zig:291-340` switches on an entity_class **hash**, not
  `Kind`; bots can ride the existing default class (or a player-class hash)
  with **no builder branch** in v1.
- **`Mask` has 13 free `_pad` bits** (`components.zig:804`); a `bot` mask flag
  needs no layout change. `kind_groups` / `countKind` / `query` are keyed by
  enum value, so `.bot` works automatically.
- **Plugin `onTick` ordering:** `wasm_plugins.onTick()` runs at
  `step.zig:239-240`, **after** `systems.tickAll` (which drained the command
  buffer at `schedule.zig:85`, returned at `step.zig:94`). Therefore commands
  the guest enqueues during `onTick` are drained at the **start of the next
  tick** — an inherent **one-tick latency** between a plugin command and its
  replicated-visible effect. This is accepted for v1 and documented in the
  spec/ADR (FPS bots do not need sub-tick response).
- **No LOS primitive exists.** There is `World.isSolidWorld(x,y,z)`
  (`store.zig:782`), a per-block solidity probe (only consumer today is
  `tick.zig:230`). A voxel ray-march against `isSolidWorld` must be written
  (host-side, in `world` or `ecs`), and used by `bot shoot` validity. This is
  core work, not guest math (ADR 0026).

---

## M0 — Host surface: bot entity + sense/act (core, tested)

1. `src/ecs/components.zig`
   - Add `bot` to `Kind` (line 5-13).
   - Add `BotDef` component (per-bot skill params: `skill: u8`, `reaction_s`,
     `vision_range`, `vision_angle`, `fire_throttle_s`, `strafe_chance`,
     `dodge_chance`, `aggression`, `self_preservation`) — Q3/BotCharacter
     inspired fields.
   - Add `mask.bot` flag (use a free `_pad` bit at `components.zig:804`).
2. `src/ecs/world.zig`
   - Add the **mandatory** Kind→class_table arm at `639` (`bot` → a
     player-mesh class index; reuse the `player` row or a dedicated one in
     `assets/entities.zig`).
   - Add `bot: [max_entities]BotDef` SoA column (mirror `zombie_ai`).
   - Add `pub fn spawnBot(allocator?)` calling `spawnBase(.bot,...)`, set
     `mask.bot`, seed `BotDef` from a `Rules` floor, `notifySpawn`, return
     NetId.
3. `src/ecs/command.zig`
   - Extend `Op` (13-17) with `bot_spawn {name, x, y, z, hp}`,
     `bot_move {net_id, x, y, z, speed}`, `bot_look {net_id, yaw}`,
     `bot_shoot {net_id, target_id}`, `bot_count {n}`, `bot_remove {net_id}`,
     `bot_cfg {net_id, key, value}` (or a compact subset for v1).
   - Add drain arms (72-94): spawn/destroy via `w.spawnBot` / `w.destroy`;
     move/look mutate transform through the client-move envelope already used
     for players; shoot → LOS check + `w.damage`.
4. **New LOS primitive** — a `rayHasClearLineOfSight(w, x0,y0,z0, x1,y1,z1)`
   voxel march against `isSolidWorld`, placed in `src/world` or `src/ecs`
   (host-owned). Unit-test solid/air blockage.
5. `src/server/game/wasm_host.zig`
   - Raise `max_plugin_cmd_len` to 256 (const at :48).
   - Extend `parsePluginCommand` (:67-97) with the bot verbs.
   - Raise the `zdtd.sense` import wiring (see M1): add the snapshot builder
     callback + a `sense_fn` in `HostCtx`.
6. `src/plugin/wasm.zig`
   - Register `zdtd.sense(ptr,len,token)->i32` in `defineImports` (:494-519);
     add the `sense_fn` dispatch to `HostCtx` (:56-63).
7. `src/server/game/replicate.zig` — add `.bot` to `is_mob` (:85-87) so bots
   replicate to observers.
8. `src/ecs/schedule.zig` — no phase reorder needed (commands drain last as
   today); a bot-intent reflect step can live in the `ai` phase rename or stay
   command-driven. Keep the pinned-order test (:123-135) untouched unless a
   phase genuinely moves.

**M0 done when:** `zig build` compiles with `.bot` added (the `world.zig:639`
arm satisfies the exhaustive switch), `bot spawn`/`bot remove`/`bot shoot`
round-trip through the drain, the LOS march has a unit test, and bots appear
in replication output (scenario test).

---

## M1 — Sense view (host -> guest) + first guest module skeleton

- `sense` snapshot layout (locked in RFC 0001 §3): a versioned header + fixed-
  stride records (net_id, kind, is_self, alive, x/y/z, hp, yaw, target_id),
  capped at a named count (e.g. 64). Host builds it in the `onTick` path from
  current sim state, in stable order; writes into the guest scratch region.
- Guest imports go through the existing reserveScratch pattern
  (`wasm.zig:225-243`); never overlaps the guest's 1024 static region.
- A `assets/fixtures/plugin_bot.c` (+ `.wasm`) proving sense round-trips and
  the new verbs parse; unit test in `wasm.zig`/`scenarios.zig`. Per ADR 0020,
  a new permanent host import lands only with evidence (fixture + test).

**M1 done when:** a unit test loads the C fixture, calls the sense host fn,
and asserts the returned snapshot fields; the fixture can enqueue every bot
verb and the host drains them.

---

## M2 — Guest brain module (Q3/Doom 3) + admin commands

- `mods/zdtd_bot/zdtd_bot.c` → `zdtd_bot.wasm` (same clang→wasm32 build path
  as `assets/fixtures/*.c`, no WASI, no libc deps).
- Brain (ported from `../7dtd-fps-bots`/Q3/Doom 3, re-expressed):
  - **Target selection**: nearest hostile within vision range/angle (players,
    zombies), weighted by `aggression`/`self_preservation`.
  - **Aim**: reaction gate; aim jitter scaled by `skill`; **leading** = target
    velocity prediction × skill; clamp to weapon accuracy.
  - **Attack**: fire throttle flip-flop; burst; abort on friend LOS/range.
  - **Move**: strafe/backpedal circling in attack, dodge on hit, "unstuck"
    jump. Direct-steer toward target, under host move caps.
  - **skill 0–4** scaling of jitter/reaction/vision/headshot, per reference.
- Backend `bot` INFO via `zdtd.log` (already sanitised).
- **Admin commands** via exported `on_admin_command`:
  `bot help|status|list|spawn|remove all|<id>|count <n>|skill <0-4>|weapon`.
  Unknown verbs still route via `tryDispatchPluginAdmin`
  (`admin_console.zig:876-889`); no core command table changes.

**M2 done when:** `bot list` enumerates spawned bots; `bot spawn/remove/count/
skill` take effect; a bot hunts a target (moves + faces + fires) against a
scripted scenario.

---

## M3 — Dynamics + validation + docs finalise

- Response to being hit (dodge), death/re-respawn via the floor, corpse sweep.
- Per-bot `bot cfg` overrides applied to `BotDef`.
- `make check` green (provenance rows for every new `src/` file per
  `tools/provenance_scan.py`, AGENTS rule 15).
- Triad validation: loadgen smoke + stock client (EAC off) + zdtd apm dumps
  (ADR 0019) — bots visible to a real client, killable, obeying move caps.
- Final pass on RFC 0001 / PRD 0001 / ADR 0026 against what was actually built;
  update INDEX.md.

---

## Delivery order (recommended sequence of PRs/commits)

1. ADR 0026 + SPEC + PRD + this plan (+ INDEX row) — the documentation slice.
2. M0 host: `bot` kind, `Mask.bot`, `BotDef`, command ops + drain, LOS march,
   `is_mob` replication, `parsePluginCommand` extension.
3. M1: `sense` import + snapshot builder + C fixture + test.
4. M2: `zdtd_bot.wasm` brain + admin commands.
5. M3: dynamics, `bot cfg`, `make check`, loadgen + stock-client evidence.

Each slice leaves `zig build test` green and is independently reviewable.
