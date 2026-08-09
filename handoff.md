# Handoff - zdtd refactor + parity push

**Date:** 2026-08-09 (review-loop continuation, wave 2)
**Goal (paused):** `finish all open items. game.zig refactor, extraction of hardcoded logic etc; reach 100% feature parity from a gameplay point of view`
**Branch:** `main` at `9bf5713`; working tree clean
**Toolchain:** Zig 0.16, `zig build` + `bash scripts/lint-architecture.sh` (clean), `zig build test` **983/983** (consecutive runs green; flakes fixed, see below)

## What landed in this series

### game.zig shrink + modularization
- `game.zig`: 6397 → **5310** lines so far via persist delegation + `src/server/game/*.zig` shards.
- Shards now: `deco.zig` (84, species/dim cache/mirror), `loot.zig` (108, `ecsIdFromItemName`/`fillLootBagFromTable`/`broadcastLootSpawn`/`broadcastItemDropSpawn` - staged), `join.zig` (564), `tick.zig` (259, survival + block-chew policy), `world.zig`, `player.zig`, `quest.zig`, `replicate.zig`, `net.zig`, `types.zig`, `hooks.zig`, `sleeper.zig`, `trader.zig`, `stability.zig`, `social.zig`, `tests.zig` (1413).
- `src/server/c2s/*` owns 5 C2S domains (join, move, inv, quest, misc).
- `src/server/root.zig` aggregates all `game_*` modules; `lint-architecture: clean` enforced.

### Stock-data vs config vs wasm (ADR 0010/0021)
- **T16 (survival, A31) shipped as `645acc5`:** `tickSurvival` now gates on `buffs.survival()` fractions (`hungry_frac[2]`/`thirsty_frac[2]` for damage, `hungry_frac[0]`/`thirsty_frac[0]` for regen) with `Survival.ok()` floor guard; offline worlds fall back to absolute `Rules.progression` threshold. Two new `Rules.progression` knobs: `block_bite_damage` (10.0, per-bite before `BlockDamageAI/BM%`) and `block_damage_range` (3.0, pressed-against-cover gate). `bloom` wiring left `Rules.progression` base Food/Water drain as policy (no `Stat.Tick` row in V3.1.0 corpus).
- **T17 in practice:** `Rules.systems` per-phase gate + `modes/builder.toml` worked pack (`director=false` still advances clock, `ai=false`, `despawn=false`); order intentionally not reorderable (buffs before ai).
- **Wasm seams (`bfc9b4a` series):** `on_admin_command` (first >0 reply wins), `on_chat` (deny/rewrite, bad UTF-8 treated as deny), `on_player_login` (first deny wins, traps = allow). Fixtures: `plugin_admin.wasm` (1278B), `plugin_chat.wasm` (695B). Example mod: `mods/example_chat_filter/` (mod.toml + plugin.c/wasm).
- `GAME_OPTIONS.md` already updated for the two progression knobs; `STATUS` pins `game.zig 5310` and the hook set, `HARDCODE_AUDIT` marks A31 fixed, `WORK_PLAN` T16 tells the gating story.

### Docs pass (`81d13db`)
- `STATUS`, `STATE_MACHINES` (§2 + §12 owners), `ZIG_CLONE.md` (defer to source tree), `HARDCODE_AUDIT` suite size corrected from ~800 to ~960, `WORK_PLAN` T16/T17 updated. No behaviour change.

## Review loop (21 relevant ~/review-prompts reviews, in-harness passes)

All 21 have at least one pass; each pass = audit, apply <=10 small fixes,
verify build + full test binary + lint, commit. Later passes re-verify.

- code-review: 3 passes (dead dup drop 6256b1e; S3 Fetcher removal +
  parseI32Prefix 453f8fb; max_land_claims dedupe 5ee9928)
- sec-review: wasm fuel budget corrected to per-instance lifetime + [plugin]
  fuel/max_pages configurable (ec922c0)
- error-review: why-comments on best-effort send catches (cdc52af)
- config-review: parse test for plugin budget keys (0b143e0)
- functionality-review: night animal groups rotate so EnemyAnimals* spawn
  (070bc8e) - real gameplay gap closed
- test-review: on_player_login join gate covered via plugin_login.wasm (98c84db)
- slop-review: last em dash removed (e2ef9b5)
- api-review: game/craft.zig extracted (34165f6, -170), game/chunk_stream.zig
  (bb3464e, -170), game/chunk_fill.zig (e5ac2fb, -270): all three arch-apis
  shards done; game.zig 6397 -> 4666 lines
- ecs-arch pass: World.teleportTo + World.respawnPlayer funnels (3e8e04c)
- functionality wave (wire parity, all RE-grounded + scenario-covered):
  AddExpClient kill XP (35ecc77), player bodies to peers + drop EntityRemove
  (e02a41d), PlayerStats progression snapshots (1138d41), AddScoreClient kill
  counter (71bee7e), PvP playerKills (1f0df06), storm admin commands
  (d2a2506), workstation craft authority count/time from recipes.xml +
  in-place queue validation bugfix (e8ff7d2), EntitySpawnResponse drop commit
  (a864ed8)
- litenet fix: per-part WindowFull pump yield so ACKs land (9bf5713) -
  pre-existing join blocker (IdMapping ~198 fragments never drained;
  reproduced at 6256b1e); loadgen join smoke now sends the IdMapping
  (env note: rerun the smoke solo; the sibling agent's loadgen/telnet shares
  the box and its SIGKILLs contaminated later runs)
- verified clean (no fixes): build, cli, concurrency, deps, doc, dst, fuzz,
  infra, minimalism, o11y, perf, release
- earlier dedicated agents this session: arch, api, deps, ecs, hardcode,
  docs, statemachines, wasm (findings in docs/reviews/ 2026-08-08)
- concurrent sibling agent lands docs commits on main (af5ce6b, aa9ae79);
  verify git status before every commit

## Working tree right now

```
working tree clean at 9bf5713
game.zig 4666 lines (was 6397 at handoff): craft/chunk_stream/chunk_fill/
  loot/weather/vehicle shards; ecs funnels for teleport/respawn
parity landed (wave 2): night predators, wasm fuel budget config,
  on_player_login coverage, kill XP wire, multiplayer player bodies +
  progression snapshots + kill counters (PvE+PvP), storm admin commands,
  workstation recipe authority, item-drop commit, liteNet window pump
hardcode review re-run: A29/A30 fixed, Bucket B closed (join rate-limit
  gap + craft batch cap now zdtd.toml); all other reviews re-audited clean
983/983 tests, lint + fmt clean
```

All work is committed through `9bf5713`; nothing staged or untracked except
this handoff note.

## What is still open (bounded next slices)

1. **`game.zig` 5099 lines** - next clean shards (do NOT re-attempt the chunk_stream delegation that failed on `fillContainerFromLoot` visibility/self-call):
   - Candidates that are self-contained: `game/sleeper` group helpers already partly done, `game/stability` stubs, the join-rate-limit / ban helpers (`joinRateLimited`, `isBanned`) into `game/net.zig`, or carving `game/world.zig` storage helpers. Keep each shard < ~200 lines, verbatim bodies, forwarded via `game_*.` thin wrappers.
   - **Do not** delegate `chunk_stream.zig` chunk helpers until its internal `ensurePrefabStorageInChunk`/`fillContainerFromLoot` pub visibility + self-call cycle is fixed (prior attempt reverted at `git checkout -- src/server/game.zig src/server/chunk_stream.zig`).

2. **Hardcode audit residuals** (see `docs/reviews/HARDCODE_AUDIT.md`):
   - A07 biome defaults, A13 recipe unlock extras, A21 gamestage biome/quest/POI terms still zero, A33 subbiome `_perm` literal (owned by 7dtd-research). None blocks the doc refresh but each is a future `Rules`/loader slice.

3. **Parity gaps (see `docs/GAP_ANALYSIS.md` + `STATUS` residual table):** deco tree density (GAP 18 subbiome shipped, but full deco still `PARTIAL`), EAI tasks 3/5 blocked on subsystems, party gamestage/loot max, trader quality_mod, work redo.

### Done since this handoff was written

- `loot.zig` committed (67f2a88), then `weather.zig` (6db0ed9) and
  `vehicle.zig` (82b9e24) extracted; `game.zig` 5310 → 5115.
- **All 4 flakes root-caused and fixed.** Scenario worlds and
  `.zdtd_cfg_cache` dirs retained a previous run's `entities.zen`, and every
  boot re-seeded the demo minibike + turret on top of the restored ones, so
  vehicle/turret records grew ~2 per suite run until entity slots (512) or the
  8 KiB console reply sink ran out (multi-seat join failure, console listents
  truncation, blood-moon timing). Fix: `had_saved_entities` gates the
  persistable demo seeds (a real restart bug: duplicates on every boot),
  `freshScenarioDir` wipes each scenario world before its test, and the
  console test wipes its own dir (`io_fs.removeDirTreeSimple`). `zig build
  test` is now 966/966 with provably stable counts across consecutive runs.
- **Trader inventory roll** (c1c3d39, GAP "Inventory roll" closed): the
  parser keeps `count="lo,hi"`, `prob`, `unique_only`, `quality="lo,hi"` on
  refs and groups, and the fill runs the ported `TraderInfo` spawn
  (asm.il 862758-863520): top-level refs always spawn, group members pick
  prob-weighted with unique dedupe, counts roll uniform in [min,max]
  (`RandomSpawnCount`), quality rolls uniform and rides the TraderData wire
  (was hardcoded 1). Seeded per (world seed, trader, day) so restock rolls
  fresh but replays. Restock full-rebuild, TraderMaxTier clamp and
  mods/modChance stay open.
- **Party highest game stage** (01fa28d, GAP closed): `partyHighestGameStage`
  (max member stage of the largest party, or max over joined when ungrouped)
  feeds `director.party_stage` for blood-moon horde difficulty, replacing the
  weighted CalcPartyLevel approximation. Sleeper volumes keep the stock
  radius-based CalcGameStageAround.
- **Trader root attrs RE'd** (4776b80): `quality_mod` is a client-side price
  quality lerp (zdtd's trade is client-mirrored, so informational only);
  `quest_tier_mod` is quest-reward tier scaling, open with the quest economy.
- **Loot container size** (a578230): world containers size from the
  `lootcontainer` size attr (woodenChest 6x2=12, smallSafes 8x5=40, gun safe
  capped 54) and roll up to capacity; the client shows the real cell count.
- **Non-burning workstation queues** (586d59b): the craft gate mirrors stock
  (asm.il 1331687) - only fuel-module stations wait for isBurning; the fuel
  module is block-derived (blocks.xml Workstation Modules: campfire/forge/
  chemistry have fuel, workbench/cementMixer/tableSaw do not).
- **Workstation persistence** (44a4056): `workstations.zws` (ZWS1) round-trips
  fuel/input/output, the smelting queue (recipe blobs), craft-complete and
  melt across restart; a forge's progress survives a reboot (rule 21).
- **Trader window 50 entries** (fe30501): max_stock 12 → 50 (stock
  TraderInfo.MaxItems); snapshots and the TraderData wire carry the window.
- **Loot count=all / force_prob / entry cap** (8e6daa9): count="all" groups
  spawn every entry (was pick-1); force_prob gates independently; entries cap
  32 → 192 (perkBooks 133 no longer truncated).
- **Loot quality templates** (cbb3bdf): <lootqualitytemplate> level bands
  roll looted item quality by loot stage (asm.il 698080); containers carry
  quality on the wire (quality items only; stackables keep 1).
- **Lazy trader restock on open** (253787f/c75d580): the LockRequest open
  rebuilds the window with fresh rolls when the ResetInterval elapsed.
- **Bucket B closure** (2245424): join rate-limit gap and craft batch cap
  moved from bare consts to zdtd.toml ([authority] join_rate_limit_ms,
  [sim] craft_max_times).
- **Reviews re-run** (127a913): HARDCODE_AUDIT 2026-08-08 pass (A29 trader
  pricing + A30 restock marked fixed; parity landings checked A/B/OK; no P0/
  P1 open); ZIG/ZIG_0_16/SIMD/ABSTRACTION/ECS reviews re-audited clean.
- `make check` fmt gate: `zig fmt` drift from the extraction commits fixed
  (tests.zig indentation, wasm.zig/misc.zig).

## How to verify a slice

```bash
zig build
bash scripts/lint-architecture.sh   # must be: lint-architecture: clean
zig build test 2>&1 | tail -n 30   # expect ~960/963, 4 flakes
```

Architecture rule: every new `src/server/game/*.zig` shard must be imported via `src/server/root.zig` and referenced in its `test { _ = game_*; }` block, otherwise `lint-architecture.sh` fails on forbidden `@import`.

## Wiring map (quick reference)

- Tick: `src/ecs/schedule.zig` `Phase` + `Rules.systems` gate → `src/server/game/tick.zig` (`tickSurvival`, `tickZombieBlockDamage` reads `buffs.survival()` + `Rules.progression.block_*`)
- Deco: `src/server/game/deco.zig` (behind `[feature] deco_mirror`)
- Loot: `src/server/game/loot.zig` (staged) + `src/assets/loot.zig`
- Wasm: `src/plugin/{api,host,wasm}.zig` (fuel + memory budget per call, trap isolates module)
  - `admin_console.runAdminLine` → `wasm_plugins.adminCommand` before `unknown`
  - `c2s/misc.handle` (chat) → `chatFilter` after `chatMsgOk` + rate-limit
  - `c2s/join.handle` (PlayerLogin) → `playerLoginDeny` after sanitization, before identity ban
- Claims: `src/server/game/world.zig` persists as `claims.zlc`, re-maps on login
- Precedent for delegation: `replicate_te`, `chunk_stream`, `persist`, `game_net` - helpers take `*Game` as first param, called as `mod.fn(g, …)`

## Resume checklist

- [ ] Commit staged loot shard (verify `zig build` + lint after `git add`)
- [ ] Pick one more `game.zig` shard (keep <200 lines) - avoid chunk_stream until its pub cycle is fixed
- [ ] If adding a new `Rules` field, update `docs/GAME_OPTIONS.md` + `modes/*.toml` example in the same commit (coverage test `GAME_OPTIONS.md documents every Rules field`)
- [ ] Run `make check` before pushing (catches the 4 flakes as known)


## Full review + docs overhaul + harnesses (same day)

### Reviews (all four subagents, findings in docs/reviews/)
- **Wasm seam** (WASM_REVIEW_2026-08-08.md): 11 hooks inventoried; top-3
  plugin candidates (loot roll override, spawn rules, quest/craft gates);
  host findings (fuel is per-instance lifetime not per-call, budget not
  configurable, worst-case one tick > 50 ms, on_player_login untested).
- **State machines** (STATE_MACHINES_AUDIT_2026-08-08.md + f711725):
  join/quest/weather/trader/sleeper/blood-moon/power/vehicle/ally verified;
  trader + vehicle SMs added to STATE_MACHINES.md. Four code findings:
  join gate pre-login permissiveness (FIXED 09342d9), dead quest_systems.zig
  duplicate (REMOVED), RequestToSpawnPlayer revive guard (flagged),
  questOnTraderOpen open-path coupling (FIXED 2e14a9a).
- **Hardcode externalization** (HARDCODE_AUDIT_2026-08-08.md): A34 entity HP
  from entityclasses.xml passive_effect (FIXED f41849b), A36 spawn pad
  terrain id (FIXED ed2f28f); no P0/P1 open; Bucket B closed.
- **Docs audit** (DOCS_AUDIT_2026-08-08.md + e3094ab): 19 doc files fixed
  (counts, config keys, ADR status, em dashes removed repo-wide).

### Doc structure + diagrams
- **Restructure** (7196299): ZIG_CLONE.md rename; ECS+SYSTEMS merged into
  ECS_SYSTEMS.md; SCALE_ARCHITECTURE+PLANET_SCALE merged into SCALE.md;
  docs/wire/ subdir (PACKAGES, WIRE_CHUNK, WIRE_WORKSTATION, INVENTORY);
  INDEX rebuilt; 296 links verified resolving.
- **Diagrams** (799410a): STATE_MACHINES.md +6 sections (party, vending
  rental, loot respawn, guard policy, chunk stream backpressure, buff
  lifecycle); new GAMEPLAY.md with 8 behavior flows (craft, workstation
  queue, trade, trader roll, loot roll, survival/stamina, blood moon,
  movement authority).
- **Consistency + stale** (f05bca8): GAP scorecard recounted 329
  (134/142/53), STATUS/TODO counts, dedup, WORK_PLAN refresh,
  DOC_CONSISTENCY_AUDIT.md.

### Harnesses
- **loadgen** (7dtd-loadgen b8a98dd): --profile probe|join-burst|
  steady-wander|death-soak|mixed (named workload profiles, TODO item).
- **playtest**: scripts/playtest_repeat.sh + Makefile playtest-repeat
  (run a suite LAPS times, aggregate reports for flake detection). Note:
  7dtd-playtest is not a git repo.

### Ops
- **SonarQube Cloud** (f5ab3e9): .github/workflows/build.yml (gate + scan on
  main/PRs) + sonar-project.properties (maci0_zdtd). Zig has no official
  SonarQube analyzer; the CI gate is the real correctness gate.
- **Product rename** (e181b89): Zig Days To Die -> Zeven Days to Die
  (display name only; zdtd acronym unchanged).
