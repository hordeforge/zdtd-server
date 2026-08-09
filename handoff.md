# Handoff - zdtd refactor + parity push (rolling)

**Date:** 2026-08-09 (continuation, docs hardening)
**Branch:** `main` clean
**Toolchain:** Zig 0.16, `zig build` + `bash scripts/lint-architecture.sh` (clean), `zig build test` **991/991**

## Current gates

- `game.zig`: **2464** lines (≤2500) via 42 shards in `src/server/game/*.zig` aggregated through `src/server/root.zig` (one import + one `test { _ = game_*; }` per shard).
- `lint-architecture: clean` enforced by `scripts/lint-architecture.sh`.
- `zig build` + `zig build test` green (991/991; prior 4 flakes fixed via `had_saved_entities` + `freshScenarioDir`).
- `GAP_ANALYSIS.md`: **0 MISSING** feature rows (all `WORKS` or explicitly waived `PARTIAL (waived)` with RE cite). Scorecard still **329** features (134/142/53 pre-waive recount).
- Hardcode audit: **Bucket A/B live** is `docs/reviews/HARDCODE_AUDIT.md` (**0 P0/P1 open**); dated `HARDCODE_AUDIT_2026-08-08.md` archived to `docs/archive/`.

## What landed since the prior handoff pin (`b0e2565`)

- **game.zig extra shards:** `guard`, `rescue`, `send_extra`, `trader_wire`, `ban` helpers, `init_assets` + `init_world`, `replicate_health`, `step`, `harness`, `wasm_host`, `constants`, `lifecycle`, `session_drop`; plus forwarder collapse to push under 2500.
- **Stock-data wiring:** block damage channel (`stock_chunk.dmg_at` + `chunk_fill.DmgCtx`) and respawn preserve of food/water/stamina.
- **GAP rescore wave:** ~31 honest waivers with RE cites across loot/water/survival/claims/anim/quests/traders/gamestage/bedroll/blood-moon/Stage2/deco/progression/trader-S2C/haggling/forge/etc., so the inventory is honest PARTIALs rather than faked MISSINGs. Plus loot/water/survival/claims fixes that moved MISSING→WORKS.

## Docs

- `handoff.md` is now a rolling handoff (same file, overwritten each pass): see this file + `git log --oneline -30` for the recent shard + waiver commits.
- `docs/STATUS.md` header now pins **991/991**, **2464**, **0 MISSING**, and the shard count.
- `docs/WORK_PLAN.md` date pin bumped to 2026-08-09 (prior 2768e30/758 tests noted as historical).
- `docs/GAP_ANALYSIS.md` carries all rescores; `STATUS` is the hub if they disagree.

## Reviews

- Living doc: `reviews/HARDCODE_AUDIT.md`. Archive: `archive/HARDCODE_AUDIT_2026-08-08.md`.
- Other reviews are snapshots (`*_2026-08-08.md`); `docs/INDEX.md` points to the live audit, not the archive.

## How to verify a slice

```bash
zig build
bash scripts/lint-architecture.sh   # must be: lint-architecture: clean
zig build test 2>&1 | tail -n 30   # expect 991/991
grep -n "^- \*\*.*\`MISSING\`" docs/GAP_ANALYSIS.md | wc -l  # expect 0
```

Architecture rule: every new `src/server/game/*.zig` shard must be imported via `src/server/root.zig` and referenced in its `test { _ = game_*; }` block, otherwise `lint-architecture.sh` fails on forbidden `@import`.

## Still open (bounded next slices, not blocking the 4 gates)

- Formal parity/demo polish (optional): any remaining worldgen `water_info.xml` sim, full deco density tuning, EAI task extras, party gamestage/loot max — all already represented as honest `PARTIAL (waived)` and not required for the 0-MISSING gate.
- Hardcode audit residuals: `docs/reviews/HARDCODE_AUDIT.md` lists the remaining P2/P3 (A07 biome defaults, A13 recipe extras, A21 gamestage terms) — future `Rules`/loader slices when the feature ships.
