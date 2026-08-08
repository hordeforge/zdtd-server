# Doc consistency and redundancy audit (zdtd)

**Date:** 2026-08-08 · **Head:** `7196299` (docs tree restructure) · **Scope:** all
`docs/` except `docs/GAMEPLAY.md`, `docs/STATE_MACHINES.md`, `docs/INDEX.md`
(owned by a sibling agent, flagged not edited). Audit-only for P1/P2; P3 items
fixed directly and committed under `Docs:`.

**Method:** every check below was run against the working tree and, where a
number is claimed, against the code (`src/`) or a live build. `zig build test`
was run for the test count: **975/975 pass**. `game.zig` is **5155** lines.
The GAP per-feature markers were recounted with exact section boundaries.

---

## 1. Title / casing consistency (H1 vs filename)

Convention in use: descriptive H1, mostly `Topic: description` or
`Topic (subtitle)`; the filename term is echoed in the H1. ADRs use
`ADR NNNN: Title`.

| Finding | doc:line | Severity | Fix shape | State |
|---|---|---|---|---|
| H1 leaks the filename itself | reviews/ZIG_0_16_REVIEW.md:1 (`ZIG_0_16_REVIEW.md - Zig 0.16 ...`) | P3 | `Zig 0.16 changelog conformance review findings (zdtd)` | **fixed** |
| ADR heading style drift (no `ADR ` prefix, dot not colon) | adr/0020:1, adr/0021:1 (`0020. ...`, `0021. ...`) | P3 | `ADR 0020: ...`, `ADR 0021: ...` | **fixed** |
| H1 does not echo the filename term (descriptive only) | APM.md:1, PLUGIN_DEV.md:1 | P3 | Accept as convention; no change recommended (a bare `APM` H1 is worse) | note |
| H1 echo is loose but acceptable | SCALE.md, STATUS.md, GAP_ANALYSIS.md, WORK_PLAN.md, WEBUI.md, STD_ABSTRACTIONS.md, ZIG_CLONE.md, WORLDGEN.md | P3 | Convention confirmed; no change | ok |

## 2. Redundancy (same claim in 2+ docs)

| Finding | doc:line | Severity | Owner / fix shape | State |
|---|---|---|---|---|
| GAP feature count `338` repeated in GAP, STATUS, TODO, INDEX | GAP 1a/scorecard, STATUS:109, TODO:11, INDEX:27 | P2 | Count is wrong (329, see check 3). STATUS owns the number; INDEX row needs the sibling | fixed in GAP/STATUS/TODO; **INDEX flagged** |
| Sim tick pipeline phase order listed twice | ECS_SYSTEMS.md (`Tick order`), STATE_MACHINES.md §2 (`Sim tick pipeline`) | P2 | ECS_SYSTEMS owns architecture; STATE_MACHINES should keep the diagram and reference ECS_SYSTEMS for the phase list | flag (STATE_MACHINES sibling-owned) |
| Join SM phases described in 3 places | AUTHORITY.md:35 (`Join phase matrix` + Pipeline), STATE_MACHINES.md §1, GAP join sections | P2 | STATE_MACHINES owns the transition diagram; AUTHORITY keeps the gate table and should link, not re-describe | flag |
| Package totals repeated (190/33/72/46/189) | wire/PACKAGES.md:6-7, STATUS.md gates `C2S package coverage` | P3 | Consistent today and STATUS links PACKAGES; keep STATUS as a pointer only | ok |
| STATUS residual table internal duplicate | STATUS.md:585 + 588 (two `Quest / EAI / power depth` rows) | P2 | Exact duplicate removed; keep one row | **fixed** (removed the row with the `workstation RecipeQueue C2S optional` tail) |
| STATUS residual near-duplicate workstation rows | STATUS.md:586 (`Workstation recipe validation`) vs :588 (`Workstation RecipeQueue C2S depth`) | P2 | Merge into one row or cross-reference; decide which residual owns the C2S-depth gap | flag |
| STATUS residual `P3 Party membership + ally persistence` says `Both SHIPPED` while the table header says `Open work only`, and row :587 (`PlatformUserIdentifierAbs party`) lists the same surface as open | STATUS.md:587, :589 | P2 | Party/ally wire shipped (entity-id keyed, no PUID); drop :587 or reword to the PUID-only residual; move :589 to HAVE | flag |
| STATUS residual `Weather storm SM` row marked `Shipped` in an open-work table | STATUS.md:583 | P2 | Move to HAVE (already there: `weather.zwt`) | flag |
| TODO `Shipped this wave (2026-08-06)` duplicates STATUS Wave 2026-08-06 prose | TODO.md shipped log | P3 | By design (shipped log); keep, it is the commit list | ok |
| NetPackageHordeEvent feature row listed in two GAP sections | GAP_ANALYSIS.md:1250 (§6 Blood moon) and :2054 (§8 Entities and AI) | P2 | Keep §6, make §8 a cross-reference (the §8 row already says `Duplicate of the §6 row above`) | flag |

## 3. Stale numbers

| Finding | doc:line | Verified value | Severity | State |
|---|---|---|---|---|
| GAP `338 features scored` | GAP_ANALYSIS.md (1a ~:133, scorecard :143-157) | **329** canonical markers (134 WORKS / 142 PARTIAL / 53 MISSING), recounted per section 4-12; 9 was the drift (all in PARTIAL except 1 MISSING) | P3 | **fixed**: scorecard rows and totals corrected to the marker counts |
| Same count in STATUS and TODO | STATUS.md:109, TODO.md:11 | 329 | P3 | **fixed** |
| Same count in INDEX read-first | INDEX.md:27 | 329 | P2 | **flagged** (sibling owns INDEX.md) |
| STATUS test count | STATUS.md:4 (`975/975`) | `zig build test` → **975/975** | P3 | ok (verified by running) |
| TODO Gates line test count | TODO.md:11 | 975 | P3 | ok |
| STATUS `game.zig 5153` | STATUS.md:5 | 5155 (`wc -l src/server/game.zig`) | P3 | **fixed** |
| STATUS gates: interest 160 | STATUS.md `Interest fan-out` | `default_interest_range = 160` (game/types.zig:48) | P3 | ok |
| STATUS gates: join gap 500 | STATUS.md `Rate / lock` / GAME_OPTIONS `[authority]` | `default_join_rate_limit_ms = 500` (game/types.zig:77) | P3 | ok |
| STATUS gates: max alive 24 | STATUS.md `Zombie population bound` | `default_max_alive_zombies = 24` (aidirector.zig:258) | P3 | ok |
| STATUS gates: edit reach 96 | STATUS.md `C2S hardening` | `default_max_edit_range = 96` (game/types.zig:47) | P3 | ok |
| STATUS gates: claimed damage 200 | STATUS.md `C2S hardening` | `default_max_claimed_damage = 200` (game/types.zig:46) | P3 | ok |
| STATUS HAVE `EAI task table (2 tasks)` | STATUS.md:599 | `zombie_tasks` table has **9** tasks (systems.zig:804) | P3 | **fixed** |
| GAP Gamestage row: `gamestages.xml is not parsed anywhere` | GAP_ANALYSIS.md:1847 | `src/assets/gamestages.zig` parses it; drives sleeper groups, blood-moon spawner, scout tiers, admin `gamestage` | P3 | **fixed** (refreshed row + anchors) |
| GAP Item quality tier: `nothing ever produces a quality other than 1` | GAP_ANALYSIS.md:2220 | Looted items roll `loot_quality_template` by loot stage since 2026-08-08 (loot.zig `resolveQuality`) | P3 | **fixed** |
| GAP deep-dive: `lootqualitytemplates ... Stack carries no quality` | GAP_ANALYSIS.md (gamestage subsection) | SHIPPED 2026-08-08 (`Stack.quality` on the fill + wire) | P3 | **fixed** |
| GAP_ANALYSIS src anchors past end of game.zig | GAP_ANALYSIS.md (77 anchors, all `game.zig:NNNN > 5155`) | game.zig is 5155 lines; the 2026-08-08 extraction moved code into `game/*` and `c2s/*` | **P1** | **flag** (needs re-anchoring against the extraction commits; mechanical but large) |
| ECS_SYSTEMS / wire/* src anchors | all docs scanned | all resolve; none past EOF | P3 | ok |

## 4. Filename / naming consistency + INDEX

| Finding | doc:line | Severity | Fix shape | State |
|---|---|---|---|---|
| All INDEX.md rows resolve | INDEX.md (full file) | P3 | none | ok |
| Every indexed row points to an existing file | INDEX.md | P3 | none | ok |
| `prompts/net-send-review.md` exists (added 2026-08-08) but is missing from the INDEX prompt/findings table | INDEX.md prompt table | P2 | add row (`not yet run` or link its findings) | **flagged** (sibling owns INDEX.md) |
| Dated review snapshots (`reviews/*_2026-08-08.md`, `reviews/DOCS_AUDIT_2026-08-08.md`) are not in INDEX | INDEX.md | P3 | by design (snapshots); ok | ok |
| `docs/archive/*` not in INDEX | INDEX.md | P3 | by design | ok |
| Filenames: all snake/SCREAMING_CASE, no lowercase stragglers | docs tree | P3 | none | ok |

## 5. Section structure (egregious only)

| Finding | doc:line | Severity | Fix shape | State |
|---|---|---|---|---|
| Two `## Wave 2026-08-07` headings in STATUS (parenthesized disambiguators) | STATUS.md:56, :112 | P3 | Rename second to include the theme in the heading itself (already differs by parenthesis); no action needed | note |
| No `Wave 2026-08-08` section while the date pin and top summary are 08-08 | STATUS.md | P2 | Add a short 08-08 wave (T16, trader/loot/workstation wave, extraction refactor) or fold into the top pin | flag |
| GAME_OPTIONS ends with `Missing world folder`, no related-docs pointer | GAME_OPTIONS.md | P3 | Add a one-line related pointer; optional | note |
| ZIG_CLONE ends at `13. What not to copy`, no sources/related section | ZIG_CLONE.md | P3 | optional | note |

## 6. Link consistency

| Finding | doc:line | Severity | Fix shape | State |
|---|---|---|---|---|
| 307 markdown links scanned; 0 broken | all docs | P3 | none | ok |
| `../7dtd-research` depth from `docs/wire/*` | wire/PACKAGES.md:9, wire/WIRE_CHUNK.md | P3 | `../../../7dtd-research/...` resolves correctly | ok |
| Bare `../7dtd-research/...` prose paths in top-level docs are repo-root-relative (convention stated in RE_GAP_CLOSURE) | GAP, WORK_PLAN, IMPLEMENTATION_PLAN, PARITY_TOOLING, RE_GAP_CLOSURE | P3 | fine under the stated convention; a reader resolving doc-relative would fail | note |
| Subdir docs (`adr/`, `prompts/`, `reviews/`) reuse the same repo-root-relative bare paths; ambiguous under doc-relative reading | adr/0016:5 (link, correct depth), prompts/hardcoded-data-review.md:60,599, prompts/net-send-review.md:34, reviews/HARDCODE_AUDIT.md:6, reviews/HARDCODE_AUDIT_2026-08-08.md:7 | P3 | Convert to markdown links with doc-relative depth or add the repo-root note; low value, left as-is | note |
| adr/ links and `../wire/*` links resolve | adr/*.md | P3 | none | ok |

## 7. Stale-info sweep (extra scope)

Fixed directly (before -> after):

| File:line | Before | After |
|---|---|---|
| STATUS.md:109 | `scores 338 features with anchors` | `scores 329 features with anchors` |
| STATUS.md:5 | `game.zig 5153, down from 6397` | `game.zig 5155, down from 6397` |
| STATUS.md:599 | `EAI task table (2 tasks)` | `EAI task table (9 tasks)` |
| STATUS.md:588 | duplicate `Quest / EAI / power depth` row | removed (one row kept) |
| GAP_ANALYSIS.md scorecard | `338 features ...` + rows 17/17/1 35, 12/10/3 25, 16/15/0 31, 11/16/8 35, 16/28/9 53, Total 134/150/54 338 | `329 features ...` + rows 17/14/1 32, 12/8/3 23, 16/14/0 30, 11/15/7 33, 16/27/9 52, Total 134/142/53 329; 08-08 recount note added |
| GAP_ANALYSIS.md:1847 | Gamestage row: `gamestages.xml is not parsed anywhere ... fixed class` | refreshed: gamestages.zig parses + resolves sleeper/spawner/scout/admin; residual list + anchor to the subsection |
| GAP_ANALYSIS.md:2220 | Item quality tier: `nothing ever produces a quality other than 1` | refresh: loot_quality_template by loot stage (2026-08-08); residuals named |
| GAP_ANALYSIS.md (gamestage subsection) | `lootqualitytemplates ... Stack carries no quality ... needs a container/wire change first` | `SHIPPED 2026-08-08`; remaining gap is qualityinfo.xml display data |
| GAME_OPTIONS.md:128 | `[rules.systems]` table missing `animals` | row added (off stops daytime wildlife; independent of `director`) |
| WORK_PLAN.md:67 (T1) | remaining: `POI placement, restock rolls, and the live stock-client visual check` | remaining: POI placement + visual check (restock rolls shipped 2026-08-08) |
| WORK_PLAN.md (T2) | remaining: `container slot counts still ignore the size attribute` | remaining: none (sized from `lootcontainer` attr 2026-08-08) |
| WORK_PLAN.md:226 (T6) | remaining: `<variable>` display-param substitution | remaining: none (landed 2026-08-07) |
| WORK_PLAN.md:262 (T7) | remaining: visual round + BloodMoonDay re-send | remaining: visual round only (re-send shipped 2026-08-06) |
| AUTHORITY.md:35 | join gate: `Pre-play: join-SM allowlist only` | + `a pre-login (connecting) peer may only send PlayerLogin / PlayerDisconnect ... enter/spawn unreachable without an identity` |
| TODO.md:11 | `338 features scored` | `329 features scored` |
| adr/0020:1, adr/0021:1 | `0020. ...`, `0021. ...` | `ADR 0020: ...`, `ADR 0021: ...` |
| reviews/ZIG_0_16_REVIEW.md:1 | `ZIG_0_16_REVIEW.md - Zig 0.16 ...` | `Zig 0.16 changelog conformance review findings (zdtd)` |

Verified current (no change needed):

- STATUS.md:4 test count 975/975 (live `zig build test`).
- STATUS gates: interest 160, join gap 500, max alive 24, edit reach 96, claimed damage 200 (game/types.zig + aidirector.zig).
- wire/PACKAGES.md totals: 190 catalog rows (parity_v3x.json), 33 ToServer all handled, 72 handled arms (c2s/* eql matches), 46 sent, 189 default_mappings names.
- GAME_OPTIONS vs code: every `[stream]`/`[authority]`/`[feature]`/`[perf]`/`[sim]`/`[mode]`/`[plugin]` key exists in `zdtd_config.zig` and vice versa; every serverconfig table key exists in `config.zig` `known_serverconfig_names` (+ SandboxCode/Preset); `[rules.*]` tables match `rules.zig` field for field after the `animals` fix; defaults spot-checked (attack_damage 8, sense_dist 2304, path_max_expand 96, party_* , progression rates, trader_wallet_dukes 5000, storm_frequency 100).
- ECS_SYSTEMS and wire/* src anchors: all resolve; none past EOF.
- RE_GAP_CLOSURE: spec map only, no open/closed claims to go stale.
- Commits since the STATUS pin checked against GAP rows: trader roll (ROLLED), party highest game stage (SHIPPED), loot container size (SIZED), count=all/force_prob/quality (loot.xml parse refresh), non-burning workstation queues (FIXED), workstation persistence ZWS1 (PERSISTED), trader window 50 (50-ENTRY), lazy restock (restock rows), entity HP from entityclasses (no doc row contradicted), join SM login gate (AUTHORITY now documents), wildlife split (row still accurate: 1/60 s, slot 7, stag-only) - all already reflected except the items fixed above.

Flagged, needs a decision (P1/P2):

| # | Finding | Why it needs a decision | Suggested fix |
|---|---|---|---|
| P1-1 | GAP_ANALYSIS.md: 77 stale `game.zig:NNNN` anchors (all > 5155) | The 2026-08-08 extraction moved the code into `game/*` and `c2s/*`; every anchor is now into removed lines | Re-anchor against the extraction commit map (e.g. join paths -> `game/join.zig`, net -> `game/net.zig`, c2s -> `c2s/*`) or add a blanket note that pre-2026-08-08 game.zig line numbers are stale; a script can do the bulk |
| P2-1 | INDEX.md:27 `338 features scored` | INDEX is sibling-owned; the number is wrong | Change to `329 features scored` |
| P2-2 | INDEX.md prompt table missing `prompts/net-send-review.md` | INDEX is sibling-owned | Add the row |
| P2-3 | STATUS.md:147 `Known open ... trader depth (POI placement, restock ...)` | Restock shipped 2026-08-08 (inventory roll + lazy restock); the known-open list and the missing Wave 08-08 section disagree with the top pin | Add a short Wave 2026-08-08 or update the known-open line to drop restock |
| P2-4 | STATUS.md residual table rows :583, :586/:588, :587, :589 (Shipped rows in an `Open work only` table + workstation near-duplicate + PUID-vs-party contradiction) | Cleaning them is a decision on which residual stays | Move Shipped rows to HAVE, merge the two workstation rows, reword the PUID row to the actual residual (no PUID identity) |
| P2-5 | GAP_ANALYSIS.md: 16 feature bullets use ad-hoc status labels (`BLOCKED`, `ROLLED`, `SIZED`, `FIXED`, `PERSISTED`, `50-ENTRY`, `DONE`, `CLOSED`, `N/A (parity)`, `PARTIAL -> ...`) outside the canonical WORKS/PARTIAL/MISSING vocabulary | The doc defines 3 tags; these are 4th+ states. The old 338 count came from mixing them | Either extend the tag table (BLOCKED, N/A (parity), DONE) or normalize to canonical tags (BLOCKED -> MISSING, DONE/ROLLED/SIZED/FIXED/PERSISTED/50-ENTRY/CLOSED -> WORKS, PARTIAL -> ... -> PARTIAL) and recount |
| P2-6 | GAME_OPTIONS.md:216 `air_drop_frequency ... (0..168)` (mode pack) vs :162 `AirDropFrequency ... 0..8760` (serverconfig) | Both mirror their code surfaces (mode.zig:0..168, config.zig:0..8760); the code ranges disagree for one key | Align the mode-pack range with serverconfig (0..8760) in mode.zig or document the intentional difference |

---

## P3 items fixed (this pass)

Committed as `Docs:` with this audit: all rows marked **fixed** above. No code
changed; all edits are doc-only and factual (defaults preserved). `make check`
does not cover docs; the doc tree still renders (links re-verified after edits).
