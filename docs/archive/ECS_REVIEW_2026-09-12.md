# ECS ownership and SoA review (zdtd), 2026-09-12

Prompt: [prompts/ecs-soa-review.md](../prompts/ecs-soa-review.md). Mode: **review only**
(no source changes). Scope: `src/ecs/*`, `src/server/c2s/*`, `src/server/game/*`,
`src/wire/*`, `src/world/*` at revision `3d408904`.

## Summary

The SoA core is in good shape: one `World` struct with dense `[max_entities]`
columns, presence via `Mask`, the only writers of `alive[]` / `kind[]` /
`kind_groups` are `spawnBase` / `destroy` / `reviveSlot`, `net_to_slot` is a
derived index over columns that stay authoritative, and the tick path is
allocation-free. The worst problems are not in the column layout but at the
edges of it: a shipped preset silently disables the whole per-player survival
and buff-lifecycle pass through an unrelated food/water gate, and one fact
(`BlockValue.rawData` of edited cells) is stored, persisted and read twice, with
the reader never falling back to the chunk plane that the code itself calls the
source of truth. Wire modules still contain sim mutators (`applyBagPackage`,
`applyEquipmentBody`, `applyParsedToContainer`), which the prompt lists as an
instant finding. Remaining costs are AoS-style copies of large component structs
for one scalar field, a strided AoS scan on the container-open path, and two
full-capacity scans that should use the existing bitsets and kind groups.

`query.groupSlice` / `copyKindInto` / `alive_bits` / `dirty_bits` are used
correctly in the systems that were touched; no `std.Thread.spawn` outside
`util/parallel` and the chunk flusher; no entity-per-block; no second `players[]`
sim array.

## Findings

| ID | Sev | Location | Issue | Correct home / shape | Suggested fix |
|---|---|---|---|---|---|
| F1 | P1 | `src/server/game/tick.zig:364` | `if (prog.food_depletion_per_hour <= 0 and prog.water_depletion_per_hour <= 0) return;` returns before drowning (`:391`), radiation (`:421`), stamina, the well-fed/starvation fold (`:439-499`) and the buff lifecycle incl. `onSelfEnteredGame` / class `Buffs=` (`:520-537`). `presets/builder.toml:27-28` sets both to `0.0`, so the shipped builder preset loses all of it while its own comment says "Survival off ... Health regen stays on" | Gate only the food/water decay, not the whole per-player pass | Compute `const decay_on = prog.food_depletion_per_hour > 0 or prog.water_depletion_per_hour > 0;`, drop the early `return`, wrap only `h.food`/`h.water` writes |
| F2 | P1 | `src/server/game/world.zig:588-594` (writer `:564`, cap `src/server/game.zig:177`) | `Game.blockRawAt` reads only the 256-entry `block_raw` mirror and returns `0` on a miss; the same fact is written to `world.setBlockRawWorld` (chunk plane) and persisted twice (`blockmeta.zig:18-45` ZBM2 and the chunk ZCH3 plane). Readers then lose rotation/meta: `c2s/blocks.zig:356-357` (SetBlock echo), `replicate_te.zig:202-203` (power visual), `c2s/blocks.zig:152`, `game/trader.zig:102` | One store: the chunk plane (`world/store.zig:1084 rawWorld`), mirror deleted | On mirror miss return `@constCast(&self.world).rawWorld(x, y, z) catch 0`; then retire `block_raw*` + `saveBlockMeta`/`loadBlockMeta` and drop the `step.zig:519` save call |
| F3 | P1 | `src/world/containers.zig:156-165` (caller `src/server/c2s/inv.zig:936`) | `getByGuid` linearly scans `self.items[i].inv_guid`, striding the 4096 x ~500 B AoS (up to ~2 MB of cache lines per lookup) even though `get()` already scans a small mirror for exactly this reason (`:92-103`). `inv_guid` is only ever `guidFromPos(pos)` (`:115`, `:134`) | Pos-keyed store, one index | Decode the guid back to `PosKey` (`x:i32 y:i32 z:i32` + `"ZTE\x01"`) and delegate to `get(pos)`; ~18 lines |
| F4 | P1 | `src/wire/stock_inv.zig:1292` (`applyBagPackage`), `:826` (`applyEquipmentBody`), `src/wire/stock_te.zig:309` (`applyParsedToContainer`) | Wire modules mutate ecs components (`*components.Inventory`, `*containers_mod.Container`); callers `c2s/inv.zig:328,354,483`, `c2s/misc.zig:499`. Prompt anti-pattern: "mutating sim inside `wire/stock_*.zig` builders"; the builders own slot indexing (`inv_bag_start`, `inv.clear()`) which is sim policy, not wire layout | Parse in `wire`, apply in `ecs/inventory.zig` / `world/containers.zig` | Move the three fns next to their target types, leave `parseBagBody`/`readItemStack` in wire; update 5 call sites |
| F5 | P2 | `src/server/game/trader.zig:19`, `src/server/game/trader_wire.zig:21` | `const m = self.sim.trader_stock[s];` / `const stock = self.sim.trader_stock[s];` copy the whole `TraderStock` (`entries: [50]StockEntry`, ~540 B) to read `.wallet` / one loop; `replicate.zig:177` calls `traderMoney` per trader per replicate pass | Column read by pointer | `const m = &self.sim.trader_stock[s];` (both sites) |
| F6 | P2 | `src/server/game/replicate_health.zig:14-16`; `src/server/game/trader.zig:48-49` | `replicatePlayerHealth` scans all 512 slots every tick (it runs before the motion-period early return at `replicate.zig:62`) though `dirty_bits`/`alive_bits` exist; `tickTraderAreas` scans `0..ecs.max_entities` while traders are a cached kind group | `dirty_bits` / `kind_groups.slice(.trader)` | Iterate `self.sim.dirty_bits` (`world.zig:365`) and `slice(.trader)`; ~10 lines |
| F7 | P2 | `src/ecs/interest.zig:44-49`, `src/ecs/world.zig:1089,1905-1907` | `Dirty.spawn` / `.inv` / `.remove` are set in 10+ places (e.g. `c2s/inv.zig:779`, `craft.zig:314`) and read nowhere; `clearAfterReplicate` clears only pos/rot/spawn/flags, so `dirty[slot].any()` stays true for the rest of the entity's life and `syncDirtyBit` keeps the slot in `dirty_bits` forever | Bits with a consumer, or no bit | Delete the three bits (and their `markDirty` arms) or clear `inv`/`remove` in `clearAfterReplicate` |
| F8 | P3 | `src/server/game.zig:547,551,561,564` | Four `[max_entities]` "last sent" edge caches (`entity_look_sent`, `attack_target_sent`, `entity_vel_sent`, `turret_sync_sent`) keyed by entity slot live in `Game` beside the ECS. Functionally safe (gen-pinned at `tick.zig:1245,1282`, `replicate.zig:280,302`), but they are a second entity index outside `ecs` | A `net_sent` component column or one combined struct | Optional consolidation; not a bug today |
| F9 | P3 | `src/server/game/step.zig:556`; `src/server/game/tick.zig:1326` | `std.Io.Threaded.init(std.heap.page_allocator, .{})` constructed inside `step` every apm report period; `admin_xml.load(self.allocator, ...)` on the tick path when serveradmin.xml mtime changes | Init-time/owned Io | Reuse one `std.Io`/writer for the report; load the XML on a non-tick path or into a scratch arena |
| F10 | P3 | `src/ecs/schedule.zig:76-78`; `src/ecs/systems.zig:2895` | `order` carries an `"animals"` entry with no `Phase` (`schedule.zig:10-28`); `snaps: [64]PlayerSnap` hardcodes 64 where `game.max_clients` (64) is the named constant; `docs/ECS_SYSTEMS.md:45` says slots `0..511` while `max_entities = 512` | Doc/naming | Note the animals toggle is inside `systemDirector`; use the named constant; fix the doc range |

## Ownership scorecard (touched areas)

| Area | ECS SoA | Resource | world/* | session | Grade |
|---|---|---|---|---|---|
| `ecs/world.zig` columns + `spawnBase`/`destroy`/`reviveSlot` | dense columns, single writer funnel | - | - | - | A |
| `ecs/query.zig` / `group.zig` / `alive_bits` | cached kind groups + bitsets, slot-ascending invariant tested | - | - | - | A |
| `ecs/systems.zig` AI/turrets/buffs/despawn | own-slot writes, atomic FP damage, serial apply | - | - | - | A- |
| `ecs/command.zig` + `schedule.run` | cap 64, drained last, `pre_drain` withdrawal (ADR 0030) | - | - | - | A |
| `server/c2s/misc.zig` attack arm | dismember/stamina/knockback/noise open-coded in the handler (`:808-870`) | - | - | - | C (P2 stranded) |
| `server/game/tick.zig` survival/buff pass | reads/writes player columns correctly | - | - | gated by `Client` loop | C (F1) |
| `wire/stock_inv.zig`, `wire/stock_te.zig` | mutates ecs types from wire | - | - | - | D (F4) |
| `world/containers.zig` | - | pos-keyed store, correct owner of TE slots | AoS items + key mirror | - | B (F3) |
| `Game.block_raw` mirror | - | - | duplicates chunk raw plane, own persistence | - | D (F2) |
| `Game.*_sent` edge caches | - | - | - | entity-slot keyed, gen-pinned | B (F8) |
| Bots (`BotManager`, `known_bots`) | not ECS by ADR 0026 | - | - | per-client bitset | A (sanctioned exception) |

## Tick / systems notes

- Order is correct and pinned by test (`schedule.zig:187`): buffs before ai, falling
  after vehicles, commands last. `systemDigUpdate` is gated with `on.ai` (`:101`),
  which is defensible (zombie dig) but worth a named toggle.
- No command-buffer drain gap: `drainCommands` runs once at the end and applies
  `pre_drain` withdrawal first.
- Interest: serialize-once pos/speeds/flags/vel/turret per entity per pass
  (`replicate.zig:227-331`), self-echo excluded for the owning player (`:218-221`),
  spawn/remove keyed on per-client `known_entities` (`:127,196-212`). Correct.
- `systemZombieAi` copies the full 512-slot transform column each tick
  (`systems.zig:2901`, ~8 KB) instead of only the AI slots plus players; low cost
  at `max_entities = 512`, noted only.
- Turret kill/loot caps `[16]` fail closed by holding fire at the cap
  (`systems.zig:3449`), so no destroyed entity can go unreported.

## Explicit non-actions

- No archetype ECS, no foreign ECS import. Keep dense Slot + columns + Mask.
- No entity-per-block / entity-per-item-stack.
- No move of bots into ECS (ADR 0026 keeps them host-side by design).
- No conversion of `Client` session state (`known_entities`, join SM, radii) into
  components.
- No rewrite of the container store to SoA: it is a pos-keyed TE store, not an
  entity table; only the guid index (F3) is touched.
- No changes to documented authority policy (client-trusting inventory per
  ADR 0007, stock-style SetBlock placement) beyond noting it.

## Optional patches

Mode is review only, so no code was changed. Candidate patch order (see chat
report for exact sketches and line counts): F1 `tick.zig` gate, F2
`blockRawAt` fallback, F3 `containers.getByGuid`, F4 wire-to-ecs move, F5
pointer reads. Gates after any of these: `zig build test`, plus a loadgen smoke
for F4 if it changes call shapes.

## Not verified

- `World`/`Game` struct sizes and real cache-miss deltas: no perf run was made,
  findings are from layout and call-site reading only.
- `blockmeta.zbm` vs chunk-plane divergence was traced in code (separate save
  calls at `step.zig:511` and `:519`), not reproduced with a failing save.
- Whether `presets/builder.toml` is exercised by CI scenarios: no scenario was run.
- `docs/STATUS.md` was not compared line by line; where it disagrees, STATUS wins.
