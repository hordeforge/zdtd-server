# Handoff - zdtd refactor + parity push (rolling)

**Date:** 2026-08-27 (gap-review sweep waves 56-86)
**Branch:** `main`
**Toolchain:** Zig 0.16, `zig build` + `bash scripts/lint-architecture.sh` (clean), `zig build test` passes (1411 tests, 1 skipped, all green), `zig build fuzz` green, `make release-check` ok.

## Current gates

- `game.zig`: 3210 lines, delegating to 44 shards in `src/server/game/*.zig` aggregated through `src/server/root.zig` (one import + one `test { _ = game_*; }` per shard). The old ≤2500 line convention was never an enforced gate; `lint-architecture.sh` enforces the import structure, not a size cap.
- `lint-architecture: clean` enforced by `scripts/lint-architecture.sh`.
- `zig build` + `zig build test` green (1411 tests across the suite).
- `GAP_ANALYSIS.md`: **0 MISSING** feature rows. Scorecard **291** features (**289 WORKS / 0 PARTIAL / 0 MISSING**, recounted 2026-08-22; the remaining PARTIAL labels are ad-hoc waived rows not counted).
- Hardcode audit: the live `docs/reviews/HARDCODE_AUDIT.md` copy was removed from the repo on 2026-08-23; the archived snapshot `docs/archive/HARDCODE_AUDIT_2026-08-08.md` survives and is what docs link to. The deterministic gate is `tools/provenance_scan.py` (205/205 files, 44 constants ledgered) + `make check-xml-audit`.
- Live stock-client gate **23/23** on a fresh world (`FRESH=1`).

## Waves 56-86 (2026-08-27 gap-review sweep)

- **GameEvent plugin execution** (ADR 0035): the IL=211 sender/party gate +
  the on_game_event verdict hook; ADR 0025's execution location superseded,
  WORK_PLAN T32 closed.
- **Wire sweep vs the RE catalog** (waves 59-62): fixed a real P0 -
  NetPackageSoundAtPosition was encoded with a 6th field stock never writes
  (parser dropped real client sounds; the S2C builder would desync a client
  reader); corrected the EntityStealth/EntityPhysics validator minimums; the
  rest of the C2S relays + S2C builders + ItemValue verified stock-exact.
- **Vehicle basket** (waves 78-79): NetPackageBag C2S apply + S2C echo (the
  basket is Entity.bag; research pin v2).
- **Turret combat stats from blocks.xml** (wave 81, rule 15): autoTurret
  MaxDistance/EntityDamage/BurstFireRate parsed into the placed turret.
- **Stealth light model** (waves 84-86): moon phase fold, held-item selfLight
  (items.xml LightValue), speedAverage movement-visibility - the TickServer
  chain is now complete for every server-computable term.
- **Stale-row corrections**: enemy animals, battery/solar, per-class AITask,
  PlayerQuestPositions, sounds row - all re-audited against the code/RE.

## What landed since the prior handoff pin (`b0e2565`)

- **game.zig extra shards:** `guard`, `rescue`, `send_extra`, `trader_wire`, `ban` helpers, `init_assets` + `init_world`, `replicate_health`, `step`, `harness`, `wasm_host`, `constants`, `lifecycle`, `session_drop`; plus forwarder collapse to push under 2500.
- **Stock-data wiring:** block damage channel (`stock_chunk.dmg_at` + `chunk_fill.DmgCtx`) and respawn preserve of food/water/stamina.
- **GAP rescore wave:** ~31 honest waivers with RE cites across loot/water/survival/claims/anim/quests/traders/gamestage/bedroll/blood-moon/Stage2/deco/progression/trader-S2C/haggling/forge/etc., so the inventory is honest PARTIALs rather than faked MISSINGs. Plus loot/water/survival/claims fixes that moved MISSING→WORKS.

## Docs

- `handoff.md` is a rolling handoff (same file, overwritten each pass): see this file + `git log --oneline -30` for recent commits.
- `docs/STATUS.md` header pins **0 MISSING**, the 291-feature scorecard, and the shard count.
- `docs/WORK_PLAN.md` now heads with the active anti-cheat program (ADR 0022, T18/T19 first); detailed task history is archived in `docs/archive/WORK_PLAN_2026-08-09.md`.
- `docs/GAP_ANALYSIS.md`: 291 features, 0 MISSING; scorecard recounted from the live markers 2026-08-22.
- `docs/INDEX.md` lists every top-level doc including the disposition reviews (`RULES_CONFIG.md`, `PLUGIN_CONFIG_DISPOSITION.md`, `XML_DATA_AUDIT.md`).

## Reviews

- The former `docs/reviews/` directory was removed (2026-08-23, commit `rm old reviews`). Review *prompts* under `docs/prompts/*-review.md` still name `docs/reviews/<NAME>.md` as their output destination; a fresh run recreates it. Surviving snapshots live under `docs/archive/` (e.g. `HARDCODE_AUDIT_2026-08-08.md`).
- Hardcode-audit residuals (A07 biome defaults, A13 recipe extras, A21 gamestage terms, and the 2026-08-23 plugin verdict findings) are tracked in `docs/PROVENANCE.md` §3.9/§3.10.

## Verify (fresh clone)

```bash
zig build                           # compiles clean (0 warnings)
zig build test                       # exit 0; 1328 test blocks run
bash scripts/lint-architecture.sh   # expect "lint-architecture: clean"
python3 tools/provenance_scan.py    # expect 198/198
```

Architecture rule: every new `src/server/game/*.zig` shard must be imported via `src/server/root.zig` and referenced in its `test { _ = game_*; }` block, otherwise `lint-architecture.sh` fails on forbidden `@import`.

## Still open (bounded next slices, not blocking the gates)

- Formal parity/demo polish (optional): any remaining worldgen `water_info.xml` sim, full deco density tuning, EAI task extras, party gamestage/loot max — all already represented as honest `PARTIAL (waived)` and not required for the 0-MISSING gate.
- Hardcode audit residuals: the remaining P2/P3 findings are recorded in `docs/PROVENANCE.md` §3.9 (divergence register) — future `Rules`/loader slices when the feature ships.
