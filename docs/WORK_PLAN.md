# Work plan: handoff-ready tasks

**Date pin:** 2026-08-06. **Head:** `76d8032`. **Gates at pin:** `make check`
exit 0, 537 unit tests, live stock-client gate 23/23.

This file exists to be handed to an agent or a programmer who has no other
context. Every task below is self-contained: what to change, which files, the
stock grounding, how to prove it, and when to stop. Ranking follows
[GAP_ANALYSIS.md](GAP_ANALYSIS.md) section 3, which carries the evidence for
each gap.

## How to work a task

1. Read the task's **Grounding** first. Any claim about stock behaviour must be
   checked against the IL dump at `/home/maci/.cache/zdtd-scratch/asm.il`
   (V3.1.0 b14) or the stock XML under
   `.../7 Days to Die Dedicated Server/Data/`. Never guess a wire layout.
2. Implement the smallest change that satisfies **Done when**. Prefer leaving a
   gap open over shipping a fake: an honest "not implemented" beats invented
   content.
3. Write the tests in **Proof** alongside the code, in the same file's test
   block. Fuzz any new parser of wire input.
4. Run `zig build`, `zig build test`, then `make check`. `make check` must exit
   0. Some scenarios keep state under `worlds/`; delete the scenario's world dir
   if a second consecutive run fails (see Known traps).
5. Update the rows this work makes stale: the matching
   [GAP_ANALYSIS.md](GAP_ANALYSIS.md) entry, the
   [MISSING_FEATURES.md](MISSING_FEATURES.md) priority row, and
   [STATUS.md](STATUS.md) if a gate changes.
6. Commit on `feat/<slug>` with a plain human message: subject line, then body
   explaining what and why, citing the IL anchors.

**House rules:** no AI attribution anywhere, no em dashes, static types, handle
the empty/zero/max/malformed case, validate at trust boundaries, comments
explain why. Match the surrounding style.

## Known traps

- **Round-trip tests are not wire evidence.** zdtd encodes and decodes with the
  same code, so a green test proves self-consistency, not stock compatibility.
  Only IL grounding or an observation from the real client counts.
- **Scenario worlds persist.** Several scenarios reuse a directory under
  `worlds/`; a second `make check` in a row can fail on state the first run
  left. `worlds/zdtd_sc_inv` is the known offender (task W3 below).
- **Parallel branches collide on appended tests.** If you branch, rebase onto
  main before merging: `git rebase --onto main $(git merge-base main <branch>)
  <branch>`. A union merge of an appended-test tail splices independent tests
  into each other and silently eats closing braces.
- **The playtest harness now starts each run from a fresh world** (`FRESH=1` in
  the playtest Makefile). Pass `FRESH=0` only when you deliberately want to
  inspect an existing save.

---

## T1. Traders: replicate the trader entity, then deliver TraderData

**Why first:** the gap analysis scores traders 3 WORKS / 9 PARTIAL / 14 MISSING,
and the headline is "no trader NPC exists on the client". Most of the trader
area and a large part of quests sit downstream of this one change.

**Change**
1. Stop filtering `.trader` out of entity replication:
   `src/server/game.zig:6477` (`sendStockEntitySpawns`) and `:7830` (tick spawn).
2. Give `class_table[3]` a real `npcTraderJen` class hash instead of the
   placeholder.
3. Write the `TraderData` flag on `EntityCreationData`:
   `src/wire/stock_entity.zig:250` currently writes `false` unconditionally.
4. Deliver the trader payload on the channel-1 `LockResponse` context.

**Grounding:** `EntityTrader` creation and the `TraderData` block in
`EntityCreationData::write`; `NetPackageTraderData` is ToServer-only, so the two
real S2C paths are the creation data and the lock response (see
`../7dtd-research/docs/loot-economy.md`, updated 2026-08-06).

**Done when:** a stock client sees a trader NPC standing in a trader POI, can
open it, and the trade window is populated from server data.

**Proof:** a scenario that joins a client, spawns the trader, and asserts the
creation-data bytes carry the trader block; plus a live playtest note recording
what the client showed.

**Out of scope:** restock timers, haggling, quest offering. File follow-ups.

---

## T2. Loot: make containers and bags roll the right table

**Why:** every chest in the world currently rolls the wrong list, and every
zombie drops the same bag.

**Change (three linked fixes)**
1. Carry the `blocks.xml` `LootList` value through `src/assets/maxdamage.zig:393`
   instead of only recording that one exists, and use it at
   `src/server/game.zig:7407`, so a gun safe stops rolling `woodenChest`.
2. Resolve the death-bag chain: `LootDropEntityClass` names a bag **entity
   class** (`EntityLootContainerRegular`) whose own `LootList="zPackReg"` is the
   container. Today the class name is passed straight to `rollContainer`, finds
   nothing, and falls back to 5 scrap iron every time
   (`src/assets/entities.zig:245`, `src/assets/loot.zig:119`).
3. Parse and honour `LootDropProb` (0.04 for a regular zombie) instead of
   dropping a bag on every kill (`src/ecs/world.zig:683`).

**Done when:** opening a gun safe and a wooden chest give visibly different
loot, and most zombie kills drop nothing.

**Proof:** unit tests over the real `loot.xml` and `entityclasses.xml` asserting
that a named container resolves to its own list, that the bag chain resolves one
hop, and that `LootDropProb` is respected across a seeded sample.

---

## T3. Items: default Stacknumber to 500 and resolve Extends

**Why:** 1159 of 1413 items lack a direct `Stacknumber`, so almost every item in
the game stacks to 1.

**Change:** default an absent `Stacknumber` to 0x1f4 = 500 and resolve the
`Extends` chain when reading item properties (`src/assets/items.zig:424`).

**Grounding:** `ItemClass` default (asm.il:749089) and the stock `Extends`
resolution order.

**Done when:** a stack of stone tools or ammo behaves like stock in the client
inventory.

**Proof:** a test over the shipped `items.xml` asserting a sample of inherited
values, including one item that inherits through two levels.

---

## T4. World: put water in the world

**Why:** no water block is ever written, so lakes and rivers are dry holes.

**Change:** write water blocks from the world's water sources during chunk
generation, and carry the water channel in the chunk package.

**Grounding:** the water plane in the stock chunk payload (see
[WIRE_CHUNK.md](WIRE_CHUNK.md)) and `water_info.xml` in the world directory.

**Done when:** the client renders water where Navezgane has it, and a player can
swim.

**Proof:** a test that a known Navezgane lake column contains water server side,
plus a live screenshot.

---

## T5. Progression: save what a player is

**Why:** progression, buffs and survival state do not survive a restart, so a
session is disposable.

**Change:** extend the player save with level, XP, skill points, buffs and the
survival stats, keyed by platform user id rather than login name.

**Grounding:** `Progression::Write` blob layout and the XP curve exponent
recorded in `../7dtd-research/docs/progression.md`.

**Done when:** a player reconnects after a server restart with the same level,
perks, buffs and survival state.

**Proof:** a persistence scenario that stops and restarts the server and asserts
each field round-trips; run it twice to prove it is not order dependent.

---

## T6. Quests: template inheritance and the accept path

**Why:** 53 client-known quest defs parse empty because `template=` is not
resolved, and the accept path is missing, so quests cannot start.

**Change**
1. Resolve `template=` inheritance when parsing `quests.xml`
   (`src/assets/quests.zig`).
2. Implement the accept signal: stock removes the quest from `NPCQuestList` as
   the acceptance marker rather than sending a dedicated accept package.
3. Implement the four objective `Write` shapes so the client renders the tracker.

**Grounding:** reflection-only `ParseObjective`, the four objective Write shapes,
fail-soft `Quest::Read`, `NPCQuestList` `RemoveQuest` as the accept signal, and
QuestEvent 9/12/13/14/16, all recorded in
`../7dtd-research/docs/quests-challenges.md` (2026-08-06).

**Done when:** a player can take a quest from a trader, see it in the journal,
and complete it.

**Depends on:** T1 (a trader must exist to give the quest).

**Proof:** a test that every def in the shipped `quests.xml` parses non-empty,
plus a scenario driving accept through to completion.

---

## T7. Blood moon: fix the night window and the day encoding

**Why:** the blood moon fires but ends at midnight and the red moon shows on the
wrong night, so the signature event of the game reads as broken.

**Change:** use the stock `IsBloodMoonTime` window and the
`WorldTimeToDays` / `CalcDuskDawnHours` / `CalcNextDay` maths for the schedule
and the client-visible day encoding.

**Grounding:** all four helpers are recorded with IL line numbers in
`../7dtd-research/docs/aidirector.md` (2026-08-06).

**Done when:** the horde runs from dusk to dawn on day 7 and the client shows a
red moon on that night and no other.

**Proof:** unit tests over the schedule maths at several world times, including
the wrap at day boundaries, plus a live observation note.

---

## T8. World: land claims, block repair, stability

Three independent world-integrity fixes, smallest first.

1. **Land claims** have no `removeClaim`, so a destroyed claim block keeps
   protecting its area forever. Add removal and expiry.
2. **Block repair** currently damages the block: stock repair calls
   `Block::DamageBlock` with a negated amount, which zdtd does not negate
   (`ItemActionRepair`, recorded in `../7dtd-research/docs/world-chunks.md`).
3. **Stability plane and falling blocks**: unsupported structures never collapse.
   Note that stock keeps `ChunkStabilityEnabled` non-persistent and runs
   stability on clients too.

**Done when:** a claim disappears with its block, repairing raises block health,
and cutting a support drops the structure.

**Proof:** one test per fix; the repair test must fail on the current code.

---

## W1. Harness: rebuild suite fixtures on a fresh world

**Why:** the playtest harness now starts every run from a fresh world, which is
correct, but the `full` suite drops from 85 cases to 23 because the extra cases
depend on a prepared world and silently stop registering rather than failing.

**Change:** build the zombie and world fixtures each run after the fresh save,
in `7dtd-playtest/scripts/playtest_run.py`, so `FRESH=1` and full coverage hold
at the same time.

**Done when:** `make playtest-full SERVER=zdtd` runs the full case count on a
fresh world, and a case that cannot register fails loudly instead of vanishing.

---

## W2. Harness: fail loudly on missing cases

**Why:** silent case loss is how W1 went unnoticed. A suite that expects N cases
should say so.

**Change:** record the expected case count per suite and report a hard failure
when fewer register.

---

## W3. Repo: give each scenario its own fresh world

**Why:** `scenario inventory move drop place equip` fails on a second
consecutive `make check` because `worlds/zdtd_sc_inv` persists player state
between runs. Any scenario that keeps state has the same latent bug.

**Change:** give each scenario a world directory it removes on entry, or a
unique per-run directory.

**Done when:** `make check` twice in a row is green from a dirty tree.

---

## Sequencing

- **Wave 1 (unblocks the most):** T1, then T2 and T3 in parallel.
- **Wave 2 (session has meaning):** T5, T6 (needs T1), T7.
- **Wave 3 (world integrity):** T4, T8.
- **Harness, any time and cheap:** W1, W2, W3. Do W3 first if `make check`
  flakiness is costing you time.

Each task is independent enough for one agent per task, except T6 which needs T1
landed first. If several agents run in parallel, keep each on its own branch and
follow the rebase rule under Known traps.
