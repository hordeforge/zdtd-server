# Handoff — zdtd refactor + parity push

**Date:** 2026-08-08 (updated after flake root-cause fix)
**Goal (paused):** `finish all open items. game.zig refactor, extraction of hardcoded logic etc; reach 100% feature parity from a gameplay point of view`
**Branch:** `main` at `afdbb59`; working tree clean
**Toolchain:** Zig 0.16, `zig build` + `bash scripts/lint-architecture.sh` (clean), `zig build test` **963/963** (three consecutive runs; the 4 flakes are fixed, see below)

## What landed in this series

### game.zig shrink + modularization
- `game.zig`: 6397 → **5310** lines so far via persist delegation + `src/server/game/*.zig` shards.
- Shards now: `deco.zig` (84, species/dim cache/mirror), `loot.zig` (108, `ecsIdFromItemName`/`fillLootBagFromTable`/`broadcastLootSpawn`/`broadcastItemDropSpawn` — staged), `join.zig` (564), `tick.zig` (259, survival + block-chew policy), `world.zig`, `player.zig`, `quest.zig`, `replicate.zig`, `net.zig`, `types.zig`, `hooks.zig`, `sleeper.zig`, `trader.zig`, `stability.zig`, `social.zig`, `tests.zig` (1413).
- `src/server/c2s/*` owns 5 C2S domains (join, move, inv, quest, misc).
- `src/server/root.zig` aggregates all `game_*` modules; `lint-architecture: clean` enforced.

### Stock-data vs config vs wasm (ADR 0010/0021)
- **T16 (survival, A31) shipped as `645acc5`:** `tickSurvival` now gates on `buffs.survival()` fractions (`hungry_frac[2]`/`thirsty_frac[2]` for damage, `hungry_frac[0]`/`thirsty_frac[0]` for regen) with `Survival.ok()` floor guard; offline worlds fall back to absolute `Rules.progression` threshold. Two new `Rules.progression` knobs: `block_bite_damage` (10.0, per-bite before `BlockDamageAI/BM%`) and `block_damage_range` (3.0, pressed-against-cover gate). `bloom` wiring left `Rules.progression` base Food/Water drain as policy (no `Stat.Tick` row in V3.1.0 corpus).
- **T17 in practice:** `Rules.systems` per-phase gate + `modes/builder.toml` worked pack (`director=false` still advances clock, `ai=false`, `despawn=false`); order intentionally not reorderable (buffs before ai).
- **Wasm seams (`bfc9b4a` series):** `on_admin_command` (first >0 reply wins), `on_chat` (deny/rewrite, bad UTF-8 treated as deny), `on_player_login` (first deny wins, traps = allow). Fixtures: `plugin_admin.wasm` (1278B), `plugin_chat.wasm` (695B). Example mod: `mods/example_chat_filter/` (mod.toml + plugin.c/wasm).
- `GAME_OPTIONS.md` already updated for the two progression knobs; `STATUS` pins `game.zig 5310` and the hook set, `HARDCODE_AUDIT` marks A31 fixed, `WORK_PLAN` T16 tells the gating story.

### Docs pass (`81d13db`)
- `STATUS`, `STATE_MACHINES` (§2 + §12 owners), `zig-clone.md` (defer to source tree), `HARDCODE_AUDIT` suite size corrected from ~800 to ~960, `WORK_PLAN` T16/T17 updated. No behaviour change.

## Working tree right now

```
working tree clean at afdbb59
game.zig 5099 lines (was 5310 at handoff): loot, weather and vehicle shards
  committed (67f2a88, 6db0ed9, 82b9e24) with thin forwarders
flakes fixed: had_saved_entities demo-seed gate + freshScenarioDir wipe
  (87a54bb, fc9f69e, afdbb59)
```

All work is committed through `afdbb59`; nothing staged, nothing untracked
except this handoff note.

## What is still open (bounded next slices)

1. **`game.zig` 5099 lines** — next clean shards (do NOT re-attempt the chunk_stream delegation that failed on `fillContainerFromLoot` visibility/self-call):
   - Candidates that are self-contained: `game/sleeper` group helpers already partly done, `game/stability` stubs, the join-rate-limit / ban helpers (`joinRateLimited`, `isBanned`) into `game/net.zig`, or carving `game/world.zig` storage helpers. Keep each shard < ~200 lines, verbatim bodies, forwarded via `game_*.` thin wrappers.
   - **Do not** delegate `chunk_stream.zig` chunk helpers until its internal `ensurePrefabStorageInChunk`/`fillContainerFromLoot` pub visibility + self-call cycle is fixed (prior attempt reverted at `git checkout -- src/server/game.zig src/server/chunk_stream.zig`).

2. **Hardcode audit residuals** (see `docs/reviews/HARDCODE_AUDIT.md`):
   - A07 biome defaults, A13 recipe unlock extras, A21 gamestage biome/quest/POI terms still zero, A33 subbiome `_perm` literal (owned by 7dtd-research). None blocks the doc refresh but each is a future `Rules`/loader slice.

3. **Parity gaps (see `docs/GAP_ANALYSIS.md` + `STATUS` residual table):** deco tree density (GAP 18 subbiome shipped, but full deco still `PARTIAL`), EAI tasks 3/5 blocked on subsystems, party gamestage/loot max, trader quality_mod, work redo.

### Done since this handoff was written

- `loot.zig` committed (67f2a88), then `weather.zig` (6db0ed9) and
  `vehicle.zig` (82b9e24) extracted; `game.zig` 5310 → 5099.
- **All 4 flakes root-caused and fixed.** Scenario worlds and
  `.zdtd_cfg_cache` dirs retained a previous run's `entities.zen`, and every
  boot re-seeded the demo minibike + turret on top of the restored ones, so
  vehicle/turret records grew ~2 per suite run until entity slots (512) or the
  8 KiB console reply sink ran out (multi-seat join failure, console listents
  truncation, blood-moon timing). Fix: `had_saved_entities` gates the
  persistable demo seeds (real restart bug), `freshScenarioDir` wipes each
  scenario world before its test, and the console test wipes its own dir
  (`io_fs.removeDirTreeSimple`). `zig build test` → **963/963** across three
  consecutive runs; counts provably stable.
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
- Precedent for delegation: `replicate_te`, `chunk_stream`, `persist`, `game_net` — helpers take `*Game` as first param, called as `mod.fn(g, …)`

## Resume checklist

- [ ] Commit staged loot shard (verify `zig build` + lint after `git add`)
- [ ] Pick one more `game.zig` shard (keep <200 lines) — avoid chunk_stream until its pub cycle is fixed
- [ ] If adding a new `Rules` field, update `docs/GAME_OPTIONS.md` + `modes/*.toml` example in the same commit (coverage test `GAME_OPTIONS.md documents every Rules field`)
- [ ] Run `make check` before pushing (catches the 4 flakes as known)
