# Work plan: handoff-ready tasks

**Date pin:** 2026-08-06. **Head:** `2768e30` (gap analysis rescored at this head). **Gates at pin:** `make check`
exit 0, 758 unit tests, live stock-client gate 23/23.

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
   [GAP_ANALYSIS.md](GAP_ANALYSIS.md) priority row, and
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

**Status: spawn + open paths landed 2026-08-06** (759 tests). `.trader` is
unfiltered from both spawn paths, `class_table[3]` carries the real
`npcTraderJen` hash, `EntityCreationData.hasTraderData` is written on trader
spawns, and the LockResponse trader branch (`buildLockResponseTrader`) delivers
server stock on open. **Per-trader stock landed 2026-08-06:** npc.xml is parsed
(`src/assets/npc.zig`) so each trader class resolves its own traders.xml
`<trader_info>` id and quest_list at spawn; `fillTraderFromXml` fills the
window from that trader's own `<trader_items>` list (traderAlways fallback),
the lock-open path denies outside the trader's open hours (vending always
open), and `allow_sell=false` blocks selling to that trader. Remaining for full
"done when": POI placement, restock rolls, and the live stock-client visual
check.

**Why first:** the gap analysis scores traders 3 WORKS / 9 PARTIAL / 14 MISSING,
and the headline is "no trader NPC exists on the client". Most of the trader
area and a large part of quests sit downstream of this one change.

**Change**
1. ~~Stop filtering `.trader` out of entity replication~~ **DONE**
   (`sendStockEntitySpawns`, replicate spawn-on-approach).
2. ~~Give `class_table[3]` a real `npcTraderJen` class hash~~ **DONE** (from
   entityclasses at load, builtin fallback for offline).
3. ~~Write the `TraderData` flag on `EntityCreationData`~~ **DONE**
   (`writeTraderDataBody` behind a `trader_data` spawn option).
4. ~~Deliver the trader payload on the channel-1 `LockResponse` context~~
   **DONE** (`buildLockResponseTrader`; request type name + Command echoed,
   hasTraderData=true, server stock).

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

**Status: landed 2026-08-06** (761 tests). All three linked fixes are in:
per-block `LootList` (Extends-resolved) drives the container fill, the
death-bag chain resolves to `zPackReg` at load, and `LootDropProb` gates the
bag. Verified against the stock XML (per-block `lootListFor` test, zPackReg
chain, drop-prob gate) plus a Navezgane loadgen smoke. Remaining from "done
when": container slot counts still ignore the size attribute (separate gap).

**Why:** every chest in the world currently rolls the wrong list, and every
zombie drops the same bag.

**Change (three linked fixes)**
1. ~~Carry the `blocks.xml` `LootList` value through `maxdamage.zig` instead of
   only recording that one exists, and use it at the container fill~~ **DONE**
   (`lootListFor`, both fill sites).
2. ~~Resolve the death-bag chain~~ **DONE** (`LootDropEntityClass` → the bag
   class's `LootList=zPackReg`, comma form takes the first candidate).
3. ~~Parse and honour `LootDropProb`~~ **DONE** (class_table/ClassId
   `drop_prob`, deterministic per-entity roll in `World.damage`).

**Done when:** opening a gun safe and a wooden chest give visibly different
loot, and most zombie kills drop nothing.

**Proof:** unit tests over the real `loot.xml` and `entityclasses.xml` asserting
that a named container resolves to its own list, that the bag chain resolves one
hop, and that `LootDropProb` is respected across a seeded sample.

---

## T3. Items: default Stacknumber to 500 and resolve Extends

**Status: landed 2026-08-06** (762 tests). Absent `Stacknumber` defaults to
stock's 0x1f4 = 500 and resolves through the `Extends` chain (two-pass, up to
24 hops). Tested against the stock items.xml: leaf (500), one-hop
(`ammoArrowExploding` 75), two-hop (`meleeHandZombieFeral` 1), and the builtin
stone axe. The "bag slot waste" residual is closed. DamageEntity/FuelValue/eat
cvars remain direct-only (follow-up if a templated item misbehaves).

**Why:** 1159 of 1413 items lack a direct `Stacknumber`, so almost every item in
the game stacks to 1.

**Change:** ~~default an absent `Stacknumber` to 0x1f4 = 500 and resolve the
`Extends` chain when reading item properties~~ **DONE**.

**Grounding:** `ItemClass` default (asm.il:749089) and the stock `Extends`
resolution order.

**Done when:** a stack of stone tools or ammo behaves like stock in the client
inventory.

**Proof:** a test over the shipped `items.xml` asserting a sample of inherited
values, including one item that inherits through two levels.

---

## T4. World: put water in the world

**Status: landed 2026-08-06 (prefab planes 2026-08-07)** (950 tests). Lake/river
water writes from the `water_info.xml` sources at chunk generation
(`Chunk.applyWaterSources`: water blocks from the lake bed up to the source
surface) and the chunk water channel carries the full static mass (19500) per
water cell. Tested: the lake-column fill and the water-channel encode against
the stock layout. A Navezgane loadgen smoke passes with the water channel live.
Prefab `.tts` water planes landed 2026-08-07: the v>=17 sparse water channel is
decoded into `TtsBlocks.water` and `paintDecoration` paints the resolved water
block at mass>0 cells, so POI pools and flooded basements render wet. Still
open for full "done when": the flowing-water sim and the stock client visual
check (water renders, swimming) queued in the visual round.

**Why:** no water block is ever written, so lakes and rivers are dry holes.

**Change:** ~~write water blocks from the world's water sources during chunk
generation, and carry the water channel in the chunk package~~ **DONE**.

**Grounding:** the water plane in the stock chunk payload (see
[WIRE_CHUNK.md](WIRE_CHUNK.md)) and `water_info.xml` in the world directory.

**Done when:** the client renders water where Navezgane has it, and a player can
swim.

**Proof:** a test that a known Navezgane lake column contains water server side,
plus a live screenshot.

---

## T5. Progression: save what a player is

**Status: landed 2026-08-06 (server side)** (765 tests). `players.zsv` v3
extends each record with a progression tail: level + XP (the server-side
`awardXp` ledger), food/water survival stats and the active buffs (full
BuffInstance state), restored on rejoin; ZPV2 files still read and the admin
wipeplayer rewrite handles both. Round-trip test runs two full save/restart
cycles. Honest scope: perk/skill-point spending is client-owned with no server
model (the ledger saves level+XP, which define the budget), the client's
`NetPackagePlayerStats` blob is still dropped, and identity stays login-name
keyed per ADR 0017 rather than platform user id.

**Why:** progression, buffs and survival state do not survive a restart, so a
session is disposable.

**Change:** ~~extend the player save with level, XP, skill points, buffs and the
survival stats, keyed by platform user id rather than login name~~ **DONE**
(level/XP/buffs/survival; login-name key per ADR 0017).

**Grounding:** `Progression::Write` blob layout and the XP curve exponent
recorded in `../7dtd-research/docs/progression.md`.

**Done when:** a player reconnects after a server restart with the same level,
perks, buffs and survival state.

**Proof:** a persistence scenario that stops and restarts the server and asserts
each field round-trips; run it twice to prove it is not order dependent.

---

## T6. Quests: template inheritance and the accept path

**Status: landed 2026-08-06** (769 tests). `template=` inheritance resolves in
a two-pass (67 derived quests parse non-empty); per-objective Write kinds flow
into `StockQuestWrite` (TreasureChest 8 bytes, POIStayWithin/StayWithin
zero-byte, else Base), so the join PDF no longer trips `ValidateSizeMarker`;
and the stock accept marker is wired: `NPCQuestList eventType=RemoveQuest(1)`
with tier + index accepts the matching offer into the journal, and the offer
list excludes active quests. Remaining: the `<variable>` display-param
substitution (cosmetic name/subtitle/description keys).

**Why:** 53 client-known quest defs parse empty because `template=` is not
resolved, and the accept path is missing, so quests cannot start.

**Change**
1. ~~Resolve `template=` inheritance when parsing `quests.xml`~~ **DONE**.
2. ~~Implement the accept signal~~ **DONE** (`NPCQuestList RemoveQuest` marker).
3. ~~Implement the four objective `Write` shapes~~ **DONE** (TreasureChest,
   POIStayWithin/StayWithin, Base; ObjectiveTime unmapped).

**Grounding:** reflection-only `ParseObjective`, the four objective Write shapes,
fail-soft `Quest::Read`, `NPCQuestList` `RemoveQuest` as the accept signal, and
QuestEvent 9/12/13/14/16, all recorded in
`../7dtd-research/docs/quests-challenges.md` (2026-08-06).

**Done when:** a player can take a quest from a trader, see it in the journal,
and complete it.

**Depends on:** T1 (a trader must exist to give the quest) - landed.

**Proof:** a test that every def in the shipped `quests.xml` parses non-empty,
plus a scenario driving accept through to completion.

---

## T7. Blood moon: fix the night window and the day encoding

**Status: landed 2026-08-06** (772 tests). `isBloodMoonNight` mirrors stock
`IsBloodMoonTime` (dusk on the scheduled day through dawn of the next, crossing
the midnight rollover), `worldTimeBits` encodes `(day-1)*24000` so the client
HUD day / BloodMoonDay / red moon align, `setDayLightLength` implements
`CalcDuskDawnHours`, and the CalcNextDay jitter is non-negative like stock.
Unit tests cover the window (dusk, rollover, dawn) and the wire day. Remaining
for full "done when": the live stock-client observation of the red moon night
(visual round) and the BloodMoonDay re-send on day roll.

**Why:** the blood moon fires but ends at midnight and the red moon shows on the
wrong night, so the signature event of the game reads as broken.

**Change:** ~~use the stock `IsBloodMoonTime` window and the
`WorldTimeToDays` / `CalcDuskDawnHours` / `CalcNextDay` maths for the schedule
and the client-visible day encoding~~ **DONE**.

**Grounding:** all four helpers are recorded with IL line numbers in
`../7dtd-research/docs/aidirector.md` (2026-08-06).

**Done when:** the horde runs from dusk to dawn on day 7 and the client shows a
red moon on that night and no other.

**Proof:** unit tests over the schedule maths at several world times, including
the wrap at day boundaries, plus a live observation note.

---

## T8. World: land claims, block repair, stability

**Status: parts 1-2 landed 2026-08-06** (verified against the code; the
parallel worktree commits landed them together with the world-integrity work).
Land claims disappear with their keystone (`removeClaimAt`) and offline claims
expire past `LandClaimExpiryDays` on the day roll (0 disables);
`markClaimsForEntity` tracks owner online state so the offline durability
modifier is live; block repair takes the lower wire damage as the new absolute
(repair heals instead of weakening). Tests cover the claim lifecycle.
Part 3 (stability plane + falling blocks) remains open: it is a large
subsystem (StabilityCalculator flood-fill, fallingBlock entities), and the
stock client already runs its own stability, so a partial server-side plane
would desync rather than help.

Three independent world-integrity fixes, smallest first.

1. ~~**Land claims** have no `removeClaim`~~ **DONE** (removal + expiry).
2. ~~**Block repair** currently damages the block~~ **DONE** (lower absolute).
3. **Stability plane and falling blocks** `OPEN`: unsupported structures never
   collapse server-side. Note that stock keeps `ChunkStabilityEnabled`
   non-persistent and runs stability on clients too.

**Done when:** a claim disappears with its block, repairing raises block health,
and cutting a support drops the structure.

**Proof:** one test per fix; the repair test must fail on the current code.

---


## T9. Plugins: stand up the Wasm runtime

**Status: landed 2026-08-06** (779 tests). zwasm v2 runtime in
`src/plugin/wasm.zig` (`WasmHost`): `[plugin] modules` in zdtd.toml loads
`.wasm` files once at init; the host import table is `zdtd_log(level, ptr, len)`,
`zdtd_tick() -> i64`, `zdtd_queue(ptr, len)`; every call runs under fuel +
max-memory budgets; exhaustion or a trap disables that module only. `on_tick`
runs late in Game.step after the sim settles, `on_player_join` on first join,
`on_shutdown` at deinit. Queued commands use the text grammar `spawn x y z hp` /
`despawn id` / `damage id amount` and land in the fixed 64-slot sim command
buffer (drained once per tick by the ecs schedule). Fixtures are C-built
(`assets/fixtures/plugin_hello.c` / `plugin_looper.c`).

**Why:** [ADR 0020](adr/0020-wasm-only-plugin-api.md) makes plugins Wasm-only so a
modder can ship one `.wasm` from any language and the host can bound what it
does. Until a runtime is wired up there is no plugin story at all: the in-tree
static host is test scaffolding and loads nothing user-supplied.

**Change** (all shipped)
1. ~~Pick the runtime.~~ **Done 2026-08-06: zwasm v2 (2.4.1).** Zig-native, so no
   C dependency and no FFI boundary; `minimum_zig_version` 0.16.0. Verified under
   Zig 0.16 that a typed export call returns, `fuelRemaining()` reports the
   budget, and `(loop br 0)` stops with `error.OutOfFuel`. Anything linking it
   needs `.use_llvm = true`: Zig 0.16's self-hosted x86 backend fails on
   `R_X86_64_PC64`. WASI is not used; the import table stays bare.
2. ~~Load `.wasm` modules named in config, instantiate once, register whichever of
   `on_enable`, `on_tick`, `on_player_join`, `on_shutdown` the module exports.~~
   `[plugin] modules` (zdtd.toml) → `InitOptions.plugin_modules` → `WasmHost`.
3. ~~Implement the host import table behind capability gates.~~ Start minimal:
   `zdtd_log`, `zdtd_tick`, `zdtd_queue`. No filesystem, no sockets, no clock
   beyond the tick time the host passes in.
4. ~~Enforce a fuel or instruction budget and a linear-memory cap per call.~~
   Exhausting either ends the call, disables that plugin and logs the hook and
   module (verified: `OutOfFuel` on the looper fixture).
5. ~~Copy data across as flat bytes both ways.~~ Flat bytes in the guest linear
   memory; no host pointer reaches a guest.

**Done when:** a `.wasm` built from a language other than Zig registers a hook,
observes a tick, queues a `SimCommand` that the sim applies, and a deliberately
looping module is disabled within one tick without stalling the server.
**DONE.**

**Proof:** a scenario with two fixture modules, one well-behaved and one that
loops, asserting the command lands, the loop is cut off by fuel, only the bad
module is disabled, and the tick budget holds.
**DONE** (`scenario wasm plugins`): hello queued three `spawn` commands that
landed (zombies 3→7), looper disabled by `OutOfFuel`, server kept ticking, and
the live server logs `zdtd wasm: info: tick N` at 20 Hz with only the looper
disabled.

**Out of scope:** WASI, hot reload, a plugin marketplace, and any hook not
already in `src/plugin/api.zig`.

## T10. C2S: handle NetPackagePlayerDisconnect explicitly

**Status: landed 2026-08-06** (775 tests). The `NetPackagePlayerDisconnect`
handler in `game.zig` onData validates the body's entity id is the sender's
own, saves the player immediately, and takes the same slot-teardown path as the
transport peer-death poll (dropClientSlot: rider unseat, lock clear, claims
offline, slot clear). Parity `--coverage` now reports **0 unhandled dir=1**
(70 handled), so the C2S surface is fully covered.

**Why:** the parity coverage lists one unhandled dir=1 package:
`NetPackagePlayerDisconnect` (PACKAGES.md). The client sends it when quitting;
zdtd lets the LiteNet peer-death poll (game.zig:3437) clean the player up
instead, which works but leaves the C2S surface one package short and delays
cleanup until the transport notices.

**Change:** ~~add a `NetPackagePlayerDisconnect` case in `game.zig` onData that
takes the same removal path as the transport poll (slot teardown, player save,
`EntityRemove` broadcast). Accept it only for the sender's own peer; drop it for
any other id. Then update the PACKAGES.md header via the parity tooling~~
**DONE**.

**Grounding:** stock handler sits on the client quit path
(`../7dtd-research/docs/inventories/netpackages.md`,
`../7dtd-research/docs/protocol-packages.md`); the transport poll it would
replace is game.zig:3437.

**Done when:** parity `--coverage` reports 0 unhandled dir=1, and a client quit
removes the player immediately rather than at the next peer-death poll.

**Proof:** parity coverage run; a scenario that sends the package for the
sender's own id and asserts the player slot is freed before the transport
timeout.

## T11. Config: bind TOML by comptime reflection, not by hand

**Status: landed 2026-08-07** (891 tests). `src/util/toml_bind.zig` walks
`std.meta.fields(T)` (struct field = `[section]`, dotted paths recurse, `?T` =
unset); both `zdtd_config.parse` and `mode.zig` bind through it and the
hand-written key chains are deleted. Per-key behaviours are declarative
(`aliases`, `ranges`, `enum_by_name` on the struct); unknown keys still abort
with the same error names. Fuzz target over `bind` added.

**Why:** `src/server/zdtd_config.zig` (985 lines) and `src/server/mode.zig` (432)
are mostly `else if (std.mem.eql(u8, key, "..."))` chains. Every new tunable
costs a parse arm, a validation arm, a docs row and a test, and every key name
is a string no compiler checks. That per-key cost, not any design objection, is
why the mode pack stopped at 28 keys and why sim rules were never exposed at
all. This task is the enabler for T12 and T13 ([ADR
0021](adr/0021-config-driven-game-modes.md) decision 1).

**Change**

- Add `src/util/toml_bind.zig` with one entry point:
  `pub fn bind(comptime T: type, dst: *T, src: []const u8, a: std.mem.Allocator) !void`.
- Walk `std.meta.fields(T)`: a field whose type is a struct is a `[section]`;
  that struct's fields are the keys. Field name is the key name verbatim.
- Drive parsing from the field type: `bool`, integer types (range-checked
  against the destination type), floats, `[]const u8` (duped through the
  allocator), and enums by name. An `?T` field means "unset", which is what the
  precedence merge already keys on.
- Keep the existing line splitter and `stripComment`; replace only `applyKV`.
- Preserve the behaviour the current chains have: unknown section or key prints
  the existing message and returns `error.UnknownTomlKey`, and a key outside any
  section is rejected.
- Carry the two per-key behaviours the chains encode today as optional
  declarations on the destination struct, so they stay declarative:
  `pub const aliases` for accepted spellings (`mode.zig` accepts both
  `blood_moon_frequency` and `bloodmoon_frequency`) and `pub const ranges` for
  the clamp bounds now written inline as `clampU8Named("ViewRadius", v, 1, 16, …)`.
- Point both `zdtd_config.parse` and `mode.zig` at the binder and delete the
  chains.

**Files:** `src/util/toml_bind.zig` (new), `src/server/zdtd_config.zig`,
`src/server/mode.zig`, `src/fuzz.zig`.

**Grounding:** none needed. This is zdtd policy plumbing with no stock
behaviour, so no IL anchor applies. The contract to preserve is the existing
zdtd.toml tests and the precedence order printed at the top of
`zdtd.toml.example`.

**Done when:** both config surfaces parse through the binder, the existing
zdtd.toml and mode tests pass **unchanged**, and adding a new tunable requires
editing only the destination struct.

**Proof:** a table-driven test over a scratch struct covering every supported
field type, plus the empty file, an unknown section, an unknown key, a key with
no section, a malformed assignment, an out-of-range integer, and a value that
overflows the destination type. Add a fuzz target over `bind` for a
representative struct: this is a parser of operator-supplied input, so the
house rule applies.

**Out of scope:** widening the TOML subset (still no arrays and no
tables-in-tables), and any change to precedence. Behaviour-preserving refactor
only, so a reviewer can diff the deleted chains against the field lists.

---

## T12. Sim: move rule constants into a `Rules` struct

**Status: landed 2026-08-07** (891 tests). `src/ecs/rules.zig` groups the
constants (`combat`, `ai`, `bloodmoon`, `progression`, `world`); every read
goes through `w.rules.<group>.<field>` and the file-scope constants are gone.
Defaults pinned by a test; combat/blood-moon scenarios unchanged (no
behavioural diff).

**Why:** the sim's rule parameters are file-scope constants
(`src/ecs/systems.zig:17-27` and `:1855`, and the blood-moon party constants in
`src/ecs/aidirector.zig`), so no config surface can reach them. A game mode is
mostly these numbers ([ADR 0021](adr/0021-config-driven-game-modes.md)
decision 2).

**Change**

- Add `src/ecs/rules.zig` with a nested struct grouped by the system that reads
  each value:
  - `combat`: `attack_damage`, `attack_range_sq`, `attack_cooldown_s`
  - `ai`: `full_dist_sq`, `mid_dist_sq`, `sense_dist_sq`, `despawn_dist_sq`,
    `chase_speed`, `wander_speed`
  - `bloodmoon`: `party_join_dist`, `party_teleport_dist`, `party_spawn_dist`,
    `party_enemy_max`, `max_parties`
  - `progression`, `world`: added as constants move; leave empty rather than
    inventing fields.
- **Every default equals the current constant value.** This task changes no
  behaviour.
- Carry `rules: Rules = .{}` on `World`. The precedent and the access path
  already exist: `World` holds `trader_restock_cap`, `trader_restock_refill` and
  `zombie_speed_scale` today.
- Update the read sites to `w.rules.<group>.<field>` and delete the file-scope
  constants. The widest of them has 9 references, so this is small.
- Preserve the resolve order at each site exactly. `systems.zig:1344` reads
  `if (ct.attack_damage > 0) ct.attack_damage else attack_damage`: the `Rules`
  value stays the **else** branch. See T14.

**Files:** `src/ecs/rules.zig` (new), `src/ecs/systems.zig`,
`src/ecs/aidirector.zig`, `src/ecs/world.zig`, `src/server/game.zig`.

**Grounding:** the blood-moon party constants are `AIDirectorBloodMoonParty`,
asm.il 413090-413140 (already cited in `aidirector.zig`). The AI speed and
damage constants are documented in place as offline floors preferring
`entityclasses.xml`; that comment is the contract this task must not break.

**Done when:** no rule constant remains at file scope in `systems.zig` or
`aidirector.zig`, every read goes through `w.rules`, and `make check` is green
with no behavioural diff.

**Proof:** a test that pins each `Rules` default to its pre-move literal value,
so a later accidental default change fails loudly rather than silently
retuning the game. Run the existing combat and blood-moon scenarios unchanged:
they are the behavioural regression check.

**Out of scope:** adding any new rule, changing any default, and wiring `Rules`
to config. T13 does the wiring.

---

## T13. Modes: make a mode pack a full `Rules` overlay

**Status: landed 2026-08-07** (891 tests). Mode packs bind `[rules.*]` through
the T11 binder; precedence stays operator-wins (zdtd.toml beats the pack; CLI >
env > world/CWD zdtd.toml > pack > serverconfig > defaults). Example packs
`modes/horde_lite.toml` + `modes/survival_crunch.toml` exercise the rules
surface and double as fixtures; GAME_OPTIONS.md carries the generated
reference with a coverage test pinning every `Rules` field to it. Scenario
`mode-rules` shows a pack's attack_damage changing sim melee.

**Why:** `modes/<name>.toml` and `--mode` ship, but a pack understands only 28
stock serverconfig scalars and cannot touch a sim rule, so a custom game mode is
still a fork ([ADR 0021](adr/0021-config-driven-game-modes.md) decision 3).

**Change**

- Bind the mode pack into `Rules` through T11's binder, alongside the stock keys
  it already accepts.
- Keep precedence exactly as documented at the top of `zdtd.toml.example`:
  `CLI > env > world/zdtd.toml > CWD zdtd.toml > mode pack > serverconfig >
  defaults`. A pack ships coherent defaults; the operator still wins.
- Ship two example packs that exercise the new surface, not just the old keys.
  They double as the test fixtures.
- Document the format in [GAME_OPTIONS.md](GAME_OPTIONS.md), generated from the
  `Rules` field list rather than written by hand.

**Files:** `src/server/mode.zig`, `modes/*.toml`, `src/main.zig`,
`docs/GAME_OPTIONS.md`, `zdtd.toml.example`.

**Grounding:** none needed; zdtd policy.

**Done when:** `--mode <name>` measurably changes sim behaviour in a scenario,
and a value set in both the pack and `zdtd.toml` resolves to the `zdtd.toml`
one.

**Proof:** three tests. A scenario that loads a pack and asserts the rule took
effect. A precedence test asserting `zdtd.toml` beats the pack and CLI beats
both. A documentation-coverage test asserting every `Rules` field appears in
GAME_OPTIONS.md, so the reference cannot drift from the struct.

**Out of scope:** hot reload of packs, and per-world mode switching at runtime.

---

## T14. Rules: audit the stock-data precedence of every moved value

**Status: landed 2026-08-07** (891 tests). `attack_damage`, `chase_speed` and
`wander_speed` are classified **floors** (entityclasses/items XML wins when
non-zero; one test per floor sets a conflicting `Rules` value and asserts the
class wins); the other moved values are **policy**. HARDCODE_AUDIT A32 records
the split and the multiplier-after-resolve rule (`zombie_speed_scale` shape).

**Why:** [ADR 0021](adr/0021-config-driven-game-modes.md) decision 5: a `Rules`
field must stay a floor, never a replacement for stock per-entity data. The
speed and damage constants already resolve `entityclasses.xml` first, and
making them configurable is exactly the moment that ordering gets inverted by
accident. This is the failure mode
[HARDCODE_AUDIT.md](reviews/HARDCODE_AUDIT.md) exists to catch.

**Change**

- Classify every value moved in T12 as **floor** (stock data wins when present)
  or **policy** (no stock equivalent; the config value is authoritative).
- For floors, add a Bucket A row to reviews/HARDCODE_AUDIT.md naming the stock file and
  field that outranks it.
- Where a mode genuinely wants to scale a stock-derived value, add an explicit
  multiplier applied **after** the per-entity resolve, rather than a global that
  discards the XML. `zombie_speed_scale` on `World` is the existing shape to
  follow.

**Files:** `src/ecs/rules.zig`, `src/ecs/systems.zig`, `reviews/HARDCODE_AUDIT.md`.

**Grounding:** `entityclasses.xml` `MoveSpeed` / `MoveSpeedAggro` and the
`HandItem` to `items.xml` `DamageEntity` path, as already resolved in
`src/assets/entities.zig`.

**Done when:** every moved value is classified, and each floor has a test
proving the loaded `entityclasses.xml` value wins over the configured floor.

**Proof:** a test per floor that sets a `Rules` value and a conflicting
`entityclasses` value and asserts the XML one is used.

**Out of scope:** writing new stock loaders. If a value has no loader yet, file
it as a Bucket A row and leave it a floor.

---

## T15. Plugins: hooks a game mode can actually be written against

**Status: landed 2026-08-07** (891 tests). `on_player_death`,
`on_entity_killed`, `on_block_damage`, `on_quest_complete` fire at their game
events under the existing per-call budgets; a trap or OutOfFuel disables only
that module. Verdict return: <0 deny, 0 keep, >0 percent. Kill verdict routed
from the sim via `World.kill_verdict_fn`; block damage and the quest payout
consult the hooks. C fixtures `plugin_rules.c` / `plugin_trap.c` prove the
deny/adjust/trap-isolate paths (scenario `wasm-t15`).

**Why:** the Wasm host exposes four observe-only hooks (`on_enable`, `on_tick`,
`on_player_join`, `on_shutdown`). Behaviour that is not a number belongs in a
plugin ([ADR 0021](adr/0021-config-driven-game-modes.md) decision 4), but a
plugin that can only watch cannot implement a win condition, a scoring system or
a custom event chain.

**Change**

- Add the event hooks a mode needs: `on_player_death`, `on_entity_killed`,
  `on_block_damage`, `on_quest_complete`.
- Define a return convention that lets a hook **deny or adjust** rather than
  only observe: an ignored return keeps today's behaviour, so a plugin that does
  not export the hook costs nothing and existing modules keep working.
- Each new hook runs under the existing per-call fuel and memory budget, and a
  trap or `OutOfFuel` disables the plugin and logs the hook and module, as the
  current hooks already do.
- Hooks stay on the tick thread in documented order, per
  [ADR 0020](adr/0020-wasm-only-plugin-api.md) rule 5.

**Files:** `src/plugin/wasm.zig`, `src/plugin/api.zig`, `docs/PLUGIN_DEV.md`,
`docs/PLUGIN_API.md`, `docs/STATE_MACHINES.md` (plugin lifecycle diagram).

**Grounding:** none needed; this is the zdtd plugin boundary, not stock
behaviour. The authority rule in [AUTHORITY.md](AUTHORITY.md) constrains it: a
plugin may deny or adjust a high-level operation, never emit package bytes or
skip the join state machine.

**Done when:** a sample `.wasm` implements a visible mode rule end to end (for
example, denying a death or doubling a quest reward) and the server behaves
accordingly.

**Proof:** a scenario driving a test module through each new hook, including a
deny path, a hook that traps, and a hook that exhausts its fuel. Update the hook
table in PLUGIN_DEV.md in the same change.

**Out of scope:** read-only sim views for guests, hot reload, and any new host
import beyond what a listed hook needs. Keep the import table small and
auditable.

---

## T16. Survival: read the rates from buffs.xml instead of inventing them

**Status: landed 2026-08-08 (T16 wiring).** `assets/buffs.zig` parses
`triggered_effect action="ModifyStats"` rows and `StatComparePercCurrentToMax`
requirements, and `buffs.survival()` resolves the stage thresholds (.5 / .25 /
.02 of max), the starvation and dehydration HP loss per real second, and the
starving stamina penalty (proven against the shipped buffs.xml, not a fixture).
`src/server/game/tick.zig:tickSurvival` now drives the tick from that table
— fraction-of-max well-fed and stage-3 gates (`hungry_frac[2]` /
`thirsty_frac[2]`), per-second `ModifyStats Health subtract .25` damage
divided by the buff's `update_rate`, and the `StaminaChangeOT perc_subtract`
penalty — with `Survival.ok()` as the floor guard. Two new `Rules.progression`
knobs cover the remaining z-level policy: `block_bite_damage` (per-bite before
`BlockDamageAI/BM` scaling) and `block_damage_range` (pressed-against-cover gate).

**Note on the base depletion:** the food and water drain rates are **not** in
buffs.xml. Stock decays those engine-side through `Stat.Tick`, scaled by
activity, and no XML row states the rate. That one stays a documented policy
tunable in `Rules.progression`; it is not a hardcode to close.

**Why:** `Rules.progression` invents food, water, health and stamina rates. Stock
ships them as data, so this is a Bucket A hardcode in a system that just landed.
The loader already exists, so this is wiring rather than research.

**Grounding** (stock `Data/Config`, V3.1.0 b14):

- `buffs.xml` `buffStatusHungry01/02/03` and `buffStatusThirsty01/02/03` carry
  `<damage_type value="Starvation"/>` / `Dehydration` and gate on
  `<requirement name="StatComparePercCurrentToMax" stat="Food" operation="GT"
  value="0.52"/>`. The thresholds are per stage, and they compare a **fraction of
  max**, not an absolute 0..100 value as `well_fed_threshold` does.
- `FoodChangeOT`, `WaterChangeOT` and `HealthChangeOT` passive effects carry the
  rates (for example `operation="base_subtract" value="10"`).
- Stamina: `StaminaChangeOT` passive effects, plus the `items.xml` `StaminaLoss`
  stat rows, plus the progression perks that modify it
  (`progression.xml` `StaminaLoss` `perc_add` by level).

**Change:** resolve each rate from the loaded buffs table at load, keeping the
`Rules` value as the floor for a missing effect (ADR 0021 decision 5). Replace
`well_fed_threshold` with stock's fraction-of-max comparison; an absolute
threshold is a different model and will not match at any max other than 100.

**Files:** `src/ecs/rules.zig`, `src/server/game.zig` (`tickSurvival`),
`src/assets/buffs.zig` (extend only if a needed row is not parsed).

**Done when:** no survival rate is a literal in `rules.zig` when
`entityclasses.xml` and `buffs.xml` are loaded, and the stage thresholds come
from the buff requirements.

**Proof:** a test over the shipped `buffs.xml` asserting the parsed rate and
threshold for each stage, and a test that an absent effect falls back to the
`Rules` floor rather than to zero.

**Out of scope:** the triggered_effect VM. Only the passive rows and the
threshold requirements are needed here.

---

## T17. Systems: make the tick pipeline a table a mode can edit

**Status: landed 2026-08-08 (direct turns).** `src/ecs/schedule.zig` exposes the
`Rules.systems` gate and the `Phase` order that `game.zig` documents; each system
is gated in the fixed `run(w,dt)` order (no heap chase table on the 50 ms path,
no reorder by mode — the order encodes a real dependency: buffs before ai so
movement reads this tick's buff state).

**Why:** [ADR 0021](adr/0021-config-driven-game-modes.md) made the sim's
*numbers* configurable, but not its *behaviour*. `ecs/schedule.zig` `run()` is a
fixed call sequence, so a mode cannot drop the blood-moon director, skip the
despawn pass, or insert a phase. Today that means forking `run()`, which is the
thing mode packs exist to avoid.

**Change (done):** each phase is now gated on `w.rules.systems.<name>` (the mode
pack toggles per phase in `modes/*.toml`; the direct turns use
`--mode turns_off` with the real sim instead, covering `buffs|director|ai`).
`builder.toml` is the worked example: `director = false` (clock still advances),
`ai = false`, `despawn = false`. The documented order stays out of mod hands.

**Done when:** a mode pack disables one system and the scenario for that system
observes it not running, with every other system unaffected.

**Proof:** a test asserting the default table reproduces the current phase order
exactly (name and order pinned, like the `Rules` default pin), plus a scenario
running with one system disabled.

**Out of scope:** plugin-provided systems. A Wasm guest gets the T15 hooks, not
a slot in the sim pipeline: a guest system would run inside the tick budget and
break the determinism rule in ADR 0020.

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
- **Independent, whenever a modding story is wanted:** T9 (Wasm runtime).
- **Tiny, any time:** T10 (C2S disconnect), alongside the harness work.
- **Custom game modes ([ADR 0021](adr/0021-config-driven-game-modes.md)):**
  strictly ordered. T11 (binder), then T12 (`Rules`), then T13 (mode overlay),
  then T14 (precedence audit). T15 (plugin hooks) is independent of all four and
  can run in parallel from the start. T16 (survival rates from buffs.xml) needs
  T12 landed; T17 (system table) needs T11 for its config surface.
- **Harness, any time and cheap:** W1, W2, W3. Do W3 first if `make check`
  flakiness is costing you time.

Each task is independent enough for one agent per task, except T6 which needs T1
landed first and the T11 to T14 chain, which must land in order: each one edits
the surface the next one binds to, so running them in parallel guarantees a
conflict. If several agents run in parallel, keep each on its own branch and
follow the rebase rule under Known traps.

**Why T11 and T12 come first:** both are behaviour-preserving refactors with a
mechanical review (T11 is a net deletion diffed against a field list; T12 pins
every default to its old literal). Landing them separately means the risky part
of the feature, the new config surface in T13, arrives on top of a base that is
already proven not to have changed the game.
