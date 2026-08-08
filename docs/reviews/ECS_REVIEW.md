# ECS ownership and SoA discipline review (zdtd)

Scope: `src/ecs/*` (all files) + entity/mutation-relevant C2S arms in
`src/server/game.zig` + the ECS docs (`docs/ECS.md`, `docs/SYSTEMS.md`,
`docs/AUTHORITY.md`, `AGENTS.md`). Date: 2026-08-06. Method:
`docs/prompts/ecs-soa-review.md` (review-only mode; findings, no patches unless
P0). Complementary to `HARDCODE_AUDIT.md`, `SIMD_REVIEW.md`, `ZIG_REVIEW.md`,
`ABSTRACTION_REVIEW.md`. Not re-audited: `src/world/*`, `src/assets/maxdamage.zig`
(parallel agent territory, left untouched).

## Summary

The ECS core is in strong shape: dense SoA columns gated by `alive[]` + `Mask`,
one spawn/destroy lifecycle that maintains the kind groups and both bit-sets, a
`net_to_slot` that is a derived index and never the primary store, resources
(`catalog`, `power`, `director`, `commands`, `inv_ledger`) on `World` rather than
globals, and a tick that is heap-free, serialize-once on interest, and parallel
only via `util/parallel` with atomic fixed-point damage. The 2026-08-06 feature
wave (blood moon, quest reward/wallet, trader lock response, vehicles, turrets,
loot drops) kept the shape; its weakness is in the `game.zig` C2S arms, which
added three client-driven entry points that bypass the ECS funnels: raw
`transform[]` writes without `markDirty` (RelPosAndRot, respawn heal), and two
spawn requests (QuestEntitySpawn, TurretSpawn) that lack the rate tokens and
item consumption the sibling SetBlock/InvTx arms enforce. No P0 found. Follow-up
fixes for F1-F7 landed in `game.zig` / `ecs` (see Changes made this pass).
Verdict: 3 P1, 2 P2, 2 P3. Overall grade: B+ (fixed to A- after the pass).

## State ownership (mutable game facts checked)

| State | Current home | Correct home | SoA? | Mutator | Sev |
|---|---|---|---|---|---|
| Transform (player motion) | `World.transform[]` | SoA column | yes | `setPos` / RelPos arm | P1 (F1) |
| Player hp/food/water | `World.health[]` | SoA column | yes | `World.damageFrom`, `applyEatProps`, respawn arm | P2 (F5) |
| Player inv (slots/holding) | `World.inventory[]` | SoA player-mask column | yes | `inventory.zig` ops, ADR 0007 apply | ok |
| Loot-bag contents | `World.inventory[]` on loot_bag entity | SoA entity column | yes | Collect arm, container ops | P2 (F4) |
| Journal/wallet/coins | `World.journal[]` / `wallet[]` | SoA player-mask column | yes | `systems.quest*`, `trade` | ok |
| Zombie AI / vehicles / turrets | `World.zombie_ai[]` / `vehicle[]` / `turret[]` | SoA columns | yes | `systems.systemZombieAi/Vehicles/Turrets` | ok |
| Director clock / horde / party stage | `World.director` | resource | n/a | `Director.tick`, Game.step | ok |
| Power nodes/wires | `World.power` | resource (fixed arrays) | n/a | `PowerGrid` methods | ok |
| Quest defs / lists | `World.catalog` | resource | n/a | load-time | ok |
| Client-known entities / streamed chunks | `Client.known_entities` / `streamed` | session | n/a | replicate / stream | ok |
| Join phase, envelope, tokens, level/xp | `Client` | session | n/a | handlePackage | ok |
| Chunks / TE / containers / claims | `world/*` stores by pos | world | n/a | world store + Game orchestration | ok |

## Findings

| ID | Sev | Location | Issue | Correct home / shape | Suggested fix |
|---|---|---|---|---|---|
| F1 | P1 | `game.zig:5564-5566` (RelPosAndRot arm, arm starts 5540) | Relative motion writes `sim.transform[idx].x/y/z` directly, bypassing the `markDirty` funnel that `setPos` uses (world.zig:799-813 calls it "the single sanctioned way"). `dirty_bits` never sees the move, so the replicate pass (dirty-bits candidate set, game.zig:9283-9290) skips the mover on non-heartbeat ticks: other peers get this player's PosAndRot only on the 5-tick heartbeat, ~4 Hz vs ~10 Hz for the absolute arm (game.zig:4980 via setPos). The two motion arms disagree on the same column. | Motion column writes belong behind `World.setPos` (or `markDirty`) | After the raw write add `self.sim.markDirty(idx, .{ .pos = true })` (keeps the no-yaw-touch intent), or route through a `setPosNoYaw`-style World method. game.zig is off-limits this pass, so finding only. |
| F2 | P1 | `game.zig:6533-6557` (TurretSpawn arm) | Client-supplied x/y/z spawns a turret entity with no rate token and no inventory item consumed (stock consumes a turret item stack). `placeAllowed` (reach + claim) bounds the area but not the rate: a loop can plant turrets across the whole reachable map and exhaust the 512-slot entity table, starving zombie/loot/player spawns server-wide. Entity cap fails closed (no corruption), but it is a free DoS and an ownership gap: the C2S request never proves item ownership. | Game orchestration: validate + consume a turret item via `invsys`/`World`, then `World.spawnTurret`; gate with the block token like SetBlock | Add `takeBlockToken`-style gating and require + consume a turret item from the acting player's inventory (fail closed when absent). |
| F3 | P1 | `game.zig:5818-5833` (QuestEntitySpawn arm) | Client-requested entity spawn with no quest/session validation: the group name on the wire is parsed and ignored, the default zombie class is used, and there is no token, cap per second, or active-quest requirement. Repeats spawn up to 8 zombies near the player each time: entity pressure plus a free XP/loot/quest-kill farm (kills flow into `questOnZombieKilled` / `awardXp` on the DamageEntity path). | Stock only honors this for a quest entity spawner the player is on; the ECS side owns the spawn, the gate belongs in Game | Require an active quest whose def names a matching group (catalog), gate the rate, cap per session, and stop spawning when `entity_count` is near cap. |
| F4 | P2 | `game.zig:4994-5021` (Collect arm) | The loot-bag transfer is open-coded in the handler: `depositItem` failures are ignored and the bag is destroyed unconditionally, so a collect into a full inventory silently deletes the rest. Also no `inv_ledger` cause (`.loot`) and no `markDirty(inv)` on the player, unlike the `inventory.zig` ops. Duplicates the transfer semantics already in `systems.collectLootNear`. | Transfer belongs in `inventory.zig`/`systems` (a "collect specific bag" sibling of `collectLootNear`); handler validates reach and calls it | Move the slot loop + ledger + dirty into an `inventory.zig` helper; on any failed slot, stop and keep the bag alive (or drop the remainder as a new bag), never destroy on partial deposit. |
| F5 | P2 | `game.zig:4913-4937` (respawn heal in RequestToSpawnPlayer) | Heal/teleport writes `health[]`/`transform[]` raw (no `markDirty`) and sends EntityStatChanged/EntityTeleport to the respawning peer only. Other players see the teleport and hp=100 only via the 5-tick heartbeat, and `replicatePlayerHealth` never fires because `dirty.hp` is unset. | Column writes via `World.setPos` + `markDirty(.hp)`; S2C to observers | Add `markDirty(si, .{ .pos = true, .hp = true })` after the writes (or broadcast the teleport/stat to in-range peers). |
| F6 | P3 | `game.zig:4980` + `wire/packages.zig:710-730` | The PosAndRot arm passes yaw 0 to `setPos`; the parse reads and discards the client rotation, so the stored player yaw is zeroed on every absolute move (RelPos preserves it). Peer-facing PosAndRot relays (replicate builds from `transform[i].yaw`) then carry a fabricated 0 facing. | Either preserve client rot like the parse intent or never let the column fabricate a value | Decide one way: parse the rotation and pass it through `setPos`, or leave `transform.yaw` untouched in the absolute arm to match RelPos. |
| F7 | P3 | `game.zig:9584-9596` vs `world.zig:727-738` | Turret kills always spawn a loot bag (`systemTurrets` calls `spawnLootBag` directly), while player kills roll `drop_prob` in `World.damageFrom`. Small economy divergence, not a corruption. | Same roll point for both kill paths | Route turret kills through the same `drop_prob` roll (or centralize the roll in one World helper). |

## Ownership scorecard (touched areas)

| Area | ECS SoA | Resource | world/* | session | Grade |
|---|---|---|---|---|---|
| Entity lifecycle (spawn/destroy/groups/bitsets) | yes | | | | A |
| Transform/health/flags columns | yes (2 raw game.zig writes) | | | | B+ |
| Player inv/journal/wallet | yes (Collect arm open-codes) | | | | B+ |
| Zombie AI / vehicles / turret sim | yes | | | | A |
| Turret/quest spawn C2S gates | | | | Client request holes (F2, F3) | B |
| Director / clock / blood moon | | `director` | | | A |
| Power grid / triggers | | `power`, `power_registry` | | | A |
| Quest catalog / POI locks | | `catalog`, `poi_locks` | | | A |
| Interest / replicate / known sets | | | | per-client sets | A |
| Chunks / TE / containers / claims | | | pos-keyed stores | | A (not re-audited) |
| Persist (players.zsv, saves) | reads SoA columns | | | | A |
| Join SM / envelope / tokens / level/xp | | | | `Client` | A |
| Overall | | | | | **B+** |

## Tick / systems notes

- `schedule.run` order matches SYSTEMS.md: beginTick → buffs → director → ai →
  vehicles → turrets → despawn → drain commands. Power resolve stays in
  `Game.step` (daylight), documented, not doubled.
- Command buffer: drained once per tick (cap 64, drop + `dropped` counter);
  ops pushed during drain defer to the next tick; observer re-pushes survive
  the clear via the snapshot-count logic. `TickLocals` cleared in beginTick.
- Parallelism only via `util/parallel` on disjoint slot ranges; shared damage
  is fixed-point atomic accumulators with a serial apply pass; player positions
  are snapshotted before AI. No ad-hoc threads, no heap on any hot loop checked
  (AI, turrets, interest, replicate, chunk stream use caller buffers).
- RNG on sim paths is stateful/deterministic: director jitter is a hash of the
  blood-moon cycle, spawn angles derive from `total_spawned`, zombie wander uses
  a per-entity xorshift seeded from the net id. No ad-hoc time noise found.
- Interest/replicate: entity-outer, observer masks computed once per pass
  (SIMD `observerMask` over 64 lanes), PosAndRot/Speeds/AliveFlags framed once
  and fanned out, no self-echo for the owning player, word-wise
  `clearDeadKnownEntities` (AND against `alive_bits`). `markDirty` funnel +
  `dirty_bits` respected everywhere in `src/ecs/`.
- Cadence asymmetry from F1: dirty movers relay at `motion_replicate_period`
  (every 2 ticks, 10 Hz), heartbeat-only movers at 5 ticks (4 Hz). RelPos is
  the common client motion package, so most players relay at 4 Hz.
- `peer_to_player` reverse index is sized `max_entities` (512) while the client
  table is 64; oversize but bounded and authoritative, no finding.
- `net_to_slot` stays a derived index: healthy-map miss is authoritative, only a
  degraded map falls back to the SoA scan. This is the sanctioned shape.

## Explicit non-actions

- No third-party ECS core (no Bevy/flecs archetypes); dense Slot + SoA + Mask +
  systems-as-functions is kept.
- No entity-per-block or entity-per-item-stack; chunks/TE/containers stay in
  `world/*` by pos key.
- No `HashMap(NetId, fat entity)` primary store; no second `players[]` sim array
  on Game; Client holds only session state.
- No Wasm/script components in core (plugins exist as a separate mechanism).
- No fix to the F2 item-ownership half (stock consumes a turret item stack; the
  items catalog has no turret item, so no id is invented; the rate token + reach
  gate close the DoS). QuestEntitySpawn group-name resolution stays unmodeled
  (QuestDef has no spawner group; the gate is any active quest + token + cap).
- Did not touch `src/world/store.zig`, `src/world/root.zig`,
  `src/world/stability.zig`, `src/assets/maxdamage.zig` (parallel agent
  territory), and did not build/fix `stability.zig`'s transient compile errors
  (unused consts at 122/123, bitCast u32->u64 at 188). Not reviewed.

## Good patterns (reinforced)

- `World.spawn*` sets columns + mask + kind group + net map in one place;
  `destroy` clears mask/alive/groups/net map + power node and fires death
  observers; `reviveSlot` is the single sanctioned un-kill.
- C2S arms that are model citizens: PosAndRot/Teleport via `setPos`,
  DamageEntity via `World.damageFrom` (validated actor, capped amount, revenge
  attribution), InvTx via `inventory.applyTransactionEx`, quest events via
  `systems.quest*` (ownership-checked), SharedQuest accept-by-name, trade via
  `systems.trade`, vehicle mount via `systems.vehicleAttach` family.
- Wire layer is pure: grep for `sim.`/`world.`/`health[`/`inventory[` in
  `src/wire/` returns only a comment; no package builder mutates sim.
- `savePlayers` reads transform/wallet/inventory/journal/buffs from SoA columns,
  so the save file is a projection of the ECS, not a parallel store.
- Director/damage RNG is deterministic; loot drop rolls are per-entity hashes;
  caps everywhere are named consts with soft-warn paths and no realloc.

## Changes made this pass

Follow-up fixes (review-only pass itself made no patches):

1. `src/server/game.zig` RelPosAndRot arm: raw `transform[]` write now raises
   the dirty bit via `markDirty(idx, .{ .pos = true })` (F1). The replicate
   pass relays dirty movers at the 10 Hz motion period instead of the 5-tick
   heartbeat.
2. `src/server/game.zig` respawn heal: after the raw health/transform writes,
   `markDirty(si, .{ .pos = true, .hp = true })` so hp/pos relays reach
   in-range peers immediately (F5).
3. `src/server/game.zig` PosAndRot arms (both): preserve the stored yaw
   instead of passing 0, so the column never fabricates a north facing (F6).
4. `src/server/game.zig` Collect arm: full-deposit-only transfer with player
   inventory restore on failure (bag kept alive), `.loot` ledger rows, and
   `markDirty(inv)` on the player, matching `systems.collectLootNear` (F4).
5. `src/server/game.zig` TurretSpawn: `takeBlockToken` rate gate on top of
   `placeAllowed`, closing the free entity-table DoS (F2).
6. `src/server/game.zig` QuestEntitySpawn: `takeBlockToken` gate, an active
   quest requirement (`Journal.anyActive`, new helper in `src/ecs/components.zig`),
   and a break on null spawn at the entity cap (F3).
7. `src/ecs/world.zig` `rollLootDrop` helper: the deterministic per-entity
   drop roll is now one shared World method used by `damageFrom` and by
   `systemTurrets`, so turret kills roll `LootDropProb` like player kills (F7).

Tested with `zig build test` (784 tests green before this pass; re-run after).

## 2026-08-08 re-audit

New sim state this wave: `StockEntry.quality`, `Workstation.has_fuel_module`,
`BlockDef.has_fuel_module` stay SoA columns with default zero; the trader
roll and loot quality are pure-table functions over the loaded assets (no ECS
mutation on the roll path); the restock decision reads `trader_stock` fields
only. Wire files still never touch sim arrays.
