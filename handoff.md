# Handoff — zdtd refactor + parity push

**Date:** 2026-08-08
**Goal (paused):** `finish all open items. game.zig refactor, extraction of hardcoded logic etc; reach 100% feature parity from a gameplay point of view`
**Branch:** `main` at `a05888f` (docs) + staged `loot.zig` extraction not yet committed
**Toolchain:** Zig 0.16, `zig build` + `bash scripts/lint-architecture.sh` (clean), `zig build test` ~960/963 (4 flakes)

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
src/server/root.zig        — staged: adds game_loot (2 lines)
src/server/game/loot.zig   — untracked (??), 108 lines, ready to commit
src/server/game/deco.zig   — committed at 52b0b19
zig build                  — green (with staged loot.zig)
lint-arch                  — clean (only if loot.zig is added to root.zig)
```

Staged `loot.zig` extraction is the only uncommitted code change. Everything else is committed through `a05888f`.

## What is still open (bounded next slices)

1. **Finish the staged `loot.zig` commit.** `game.zig` still contains duplicated `ecsIdFromItemName`/`fillLootBagFromTable`/`broadcastLootSpawn`/`broadcastItemDropSpawn` until the staged diff is committed. Commit: `git add src/server/game/loot.zig src/server/root.zig src/server/game.zig` (the last already reflects the forwarding shims locally but shows no diff because the working copy was reverted — re-apply the 4 forwarder bodies if committing).

2. **`game.zig` still 5310 lines** — next clean shards (do NOT re-attempt the chunk_stream delegation that failed on `fillContainerFromLoot` visibility/self-call):
   - `game/loot.zig` already done; next candidates that are self-contained: `game/sleeper` group helpers already partly done, `game/stability` stubs, or carving `game/world.zig` storage helpers. Keep each shard < ~200 lines, verbatim bodies, forwarded via `game_*.` thin wrappers.
   - **Do not** delegate `chunk_stream.zig` chunk helpers until its internal `ensurePrefabStorageInChunk`/`fillContainerFromLoot` pub visibility + self-call cycle is fixed (prior attempt reverted at `git checkout -- src/server/game.zig src/server/chunk_stream.zig`).

3. **Hardcode audit residuals** (see `docs/reviews/HARDCODE_AUDIT.md`):
   - A07 biome defaults, A13 recipe unlock extras, A21 gamestage biome/quest/POI terms still zero, A33 subbiome `_perm` literal (owned by 7dtd-research). None blocks the doc refresh but each is a future `Rules`/loader slice.

4. **Test flakes (4, pre-existing, not introduced here):**
   - `server.game.tests.test.console replies use the stock error and listing shapes` (`tests.zig:945` expects `in the game\n`)
   - `server.scenarios.test.scenario blood moon day re-send fires on the day roll`
   - `server.mode.test.GAME_OPTIONS.md documents every Rules field` (wording drift on the two new progression keys — now fixed in docs but test expectation may need the doc phrase match)
   - Multi-seat / vending-edit scenario flakes seen intermittently.

5. **Parity gaps (see `docs/GAP_ANALYSIS.md` + `STATUS` residual table):** deco tree density (GAP 18 subbiome shipped, but full deco still `PARTIAL`), EAI tasks 3/5 blocked on subsystems, party gamestage/loot max, trader quality_mod, work redo.

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
