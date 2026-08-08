# Doc consistency audit 2026-08-08

Pass: structure, redundancy, naming, stale counts and cross-doc claims after
the doc restructure (7196299) and the diagrams pass (799410a). Scope per the
consistency brief: title consistency, redundancy, stale numbers, filename
consistency, section structure, link consistency.

## Fixed (committed as part of this pass)

| File | Change |
|---|---|
| docs/GAP_ANALYSIS.md | Scorecard recounted from the per-feature markers: **329** canonical WORKS/PARTIAL/MISSING tags (134/142/53, area rows sum to the total). Fifteen bullets use ad-hoc status labels (BLOCKED, ROLLED, SIZED, FIXED, PERSISTED, 50-ENTRY, DONE, CLOSED, N/A (parity), PARTIAL -> ...) and are intentionally not counted. The old 338 claim was the count including those ad-hoc labels |
| docs/STATUS.md | game.zig line count 5153 -> 5155; removed the duplicated "Quest / EAI / power depth" residual row; GAP score claim 338 -> 329; EAI task table count 2 -> 9 |
| TODO.md | Gates line 975; GAP row 338 -> 329; flake-note test count 963 -> 975 |
| docs/WORK_PLAN.md | T1 trader "done when" updated (restock rolls shipped 2026-08-08); T2 loot status refreshed |
| docs/GAME_OPTIONS.md | [rules.systems] animals row added (wildlife split, 5f6d15f) |
| docs/AUTHORITY.md | Join phase matrix note: pre-login (connecting) peers may only send PlayerLogin / PlayerDisconnect since the 2026-08-08 gate (09342d9) |

## Checks run

| Check | Result |
|---|---|
| H1 vs filename | All 23 docs use descriptive H1 titles (not filename echoes); consistent style. No action |
| Filename naming | ZIG_CLONE.md now PascalCase (7196299); docs/wire/ holds the four wire docs. No remaining lowercase or missing-from-INDEX docs |
| Redundancy | STATUS residual row dedup done. ECS/SYSTEMS and the two scale docs merged in 7196299. No other claim duplicated across docs that is not cross-referenced by design (STATUS is the hub; GAP/TODO/WORK_PLAN reference it) |
| Link consistency | All 296 markdown links across docs resolve (verified in 7196299); docs/wire/* use ../ depth; 7dtd-research links at ../../../ depth in wire/ verified |
| Section structure | No egregious cross-doc inconsistency (all docs put status/scope near the top) |

## Flagged (deferred, need a decision)

| Finding | Severity | Note |
|---|---|---|
| GAP_ANALYSIS src anchors point past EOF for game.zig | P2 | Many anchors cite game.zig lines from before the 08-06..08-08 extractions (game.zig is 5155 lines; anchors > 5155 are stale). Re-anchoring the whole GAP is a large pass; the per-area rows cite what they cite |
| PLUGIN_API budget wording ("per call" vs per-instance lifetime) | P2 | Wasm review finding: fuel is a per-instance lifetime budget, docs say per call. Needs a doc fix + a config surface decision ([plugin] budget is not configurable) |
| on_player_login hook undocumented in PLUGIN_API + zero test coverage | P2 | Wasm review: hook exists in code and PLUGIN_DEV, but PLUGIN_API 'Guest exports' is stale and there is no unit/scenario test |

## Method

Claims cross-checked against src/ with rg/wc; test count measured by running
the suite at the pass head (975/975, run twice).
