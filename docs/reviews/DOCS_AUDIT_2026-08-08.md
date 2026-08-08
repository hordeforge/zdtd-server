# Docs audit 2026-08-08 (zdtd)

**Scope:** every doc that claims behavior must match the code at the pinned
branch. Claims checked: STATUS counts and feature list, GAME_OPTIONS keys,
PACKAGES catalog, STATE_MACHINES diagrams, ASSETS loaders, ADRs 0010/0015/0017/
0020/0021, and the em-dash house rule (U+2014).

**Method:** claims cross-checked against the source with `rg`/`wc`/tests; the
unit-test count was measured by running `zig build test` twice in a pristine
detached worktree (the working tree was being edited by concurrent review work
during this audit, so a clean measurement needed a clean checkout).

**Branch caveat:** main advanced during the audit from `3b06680` to `ed2f28f`.
Commits that landed in between: `f711725` (state machine audit; trader and
vehicle SMs added to STATE_MACHINES.md, stale anchors fixed, sleeper wake
transition corrected), `5f6d15f` (wildlife split from the director gate),
`5e0576c` + `99c0298` (wasm seam and hardcode externalization reviews),
`f41849b` (entityclasses HP), `ed2f28f` (spawn surface terrain id). Code
evidence below is anchored to main at `f41849b`/`ed2f28f`; the one measured
test count is at `f41849b`.

**Outcome:** 975/975 tests pass at `f41849b` (two consecutive runs, rc=0).
Small stale items were fixed directly (doc-only edits, committed as `Docs:`).
Diagrams: no mismatching mermaid diagram remains after the state-machine audit
commit `f711725` (verified below).

---

## docs/STATUS.md (hub)

| Claim | Code evidence | Status |
|---|---|---|
| Unit tests `zig build test` -> 963/963 | Measured at HEAD `f41849b` in a pristine worktree: **All 975 tests passed** (rc=0, run twice) | STALE, fixed to 975/975 |
| `game.zig` 5111 lines | `wc -l src/server/game.zig` = **5153** at `f41849b` and `ed2f28f` | STALE, fixed to 5153 |
| game.zig shard list `game/deco\|join\|loot\|weather\|vehicle\|tick\|world\|player\|quest\|social\|trader\|stability\|replicate\|net\|types\|hooks\|sleeper` + `c2s/*` 5 domains | All 17 shard files exist in `src/server/game/`; `c2s/` has join, move, inv, quest, misc | CURRENT |
| C2S coverage: 0 unhandled dir=1, handled cases in game.zig | All 33 catalog ToServer packages have a dispatch arm in `c2s/*`; total dispatch arms = 72 (3 more than the 69 the table marked: PlayerDisconnect, PartyQuestChange, PlayerVendingMachine). Handlers live in `c2s/*`, not game.zig | STALE count, fixed: 72 handled across `c2s/*` |
| Weather storm SM + persistence (`weather.zwt`) | `world/weather.zig` tick/forceBloodMoon/encode/decode; `game.zig` saveWeather/restoreWeather (`weather.zwt`, ZWTH1) | CURRENT |
| Party state machine + PartyData snapshots | `src/ecs/party.zig`; `wire/stock_party.zig`; `c2s` PartyActions dispatch | CURRENT |
| Survival + stamina (GAP 22) | `game/tick.zig` `tickSurvival`; `Rules.progression` rates; EntityStatChanged sync | CURRENT |
| Vending rent SM | `c2s/quest.zig` `NetPackagePlayerVendingMachine` handler; `world/vending.zig` | CURRENT |
| Chat recipient routing | `c2s/misc.zig` `parseStockChat` + recipient fan-out | CURRENT |
| Subbiome deco lists (GAP 18) | `world/subbiome_noise.zig` + `decoSpeciesAt` | CURRENT |
| Chunk compression (GAP 20) | `wire/frame.zig` `DeflateFramer` on NetPackageChunk + SignDataResponse | CURRENT |
| Gates table rows (interest 160, alive-cap 24, reach 96, damage cap 200, join gap 500 ms) | `interest_range=160`, `default_max_alive_zombies=24`, `default_max_edit_range=96` (sanitize), `default_max_claimed_damage=200`, `default_join_rate_limit_ms=500` | CURRENT |
| Em dashes (U+2014) at lines 82, 83, 158, 166, 216, 231, 238, 276, 282, 331, 360, 368 | House rule (AGENTS) | FIXED (replaced with hyphens) |

## docs/GAME_OPTIONS.md

| Claim | Code evidence | Status |
|---|---|---|
| Every serverconfig property in the applied table | All listed names parse in `src/server/config.zig` (`known_serverconfig_names` + `parse`); defaults match the `Config` struct | CURRENT |
| `SandboxCode` / `SandboxPreset` | Parsed in `config.zig`, ride GameStats(71) blob + GSI GameInfoString (`serverinfo_tcp.zig` 0x12/0x13) | STALE (parsed and applied but undocumented), fixed: rows added |
| `[stream]` keys | All 12 keys exist in `zdtd_config.zig` `Stream` | CURRENT |
| `[authority]` keys | `interest_range_blocks`, `max_edit_range_blocks`, `max_claimed_damage`, `peer_stale_ms`, `join_rate_limit_ms`, `mode` documented; **`lock_stale_ms` and the 7 `guard_*` keys were undocumented** (they exist in `Authority`, enforced in `guard_policy.zig`) | STALE, fixed: keys added |
| `[feature]` keys | `wire_chunks`, `deco_trees`, `deco_mirror`, `block_id_mapping` documented; **`deco_objects_per_join` was undocumented** (exists in `Feature`, default 8192) | STALE, fixed: key added |
| `[perf]` / `[sim]` / `[plugin]` / `[mode]` keys | All match `zdtd_config.zig` structs | CURRENT |
| `[rules.*]` table | Coverage test `mode.zig` "GAME_OPTIONS.md documents every Rules field" pins every `Rules` leaf to the doc; defaults match `rules.zig` pin test | CURRENT |
| `TelnetFailedLoginsBlocktime` "parsed; enforcement pending" | Enforcement exists: `admin.zig` `authenticate` locks the source out for `fail_block_minutes` after `fail_limit` failures | STALE, fixed |
| Em dashes at lines 186, 222, 224 | House rule | FIXED |

## docs/PACKAGES.md

| Claim | Code evidence | Status |
|---|---|---|
| 190 stock catalog rows | `assets/fixtures/parity_v3x.json` `packages` has 190 entries | CURRENT |
| 33 ToServer, all handled | Catalog dir=1 count = 33; all 33 have a dispatch arm in `c2s/*` | CURRENT |
| Handled cases 70 | Actual dispatch arms = 72 (`NetPackagePlayerDisconnect`, `NetPackagePartyQuestChange`, `NetPackagePlayerVendingMachine` are handled in code but were not marked in the table) | STALE, fixed: header 72, 3 rows marked handled |
| S2C emitted 46 | 46 rows marked `sent`; every one of those package names appears in `src/` | CURRENT |
| `default_mappings` 189 names | `src/wire/packages.zig` `default_mappings` has 189 entries | CURRENT |
| Read-wire head column notes | Spot-checked NetPackageAllyRequest / PlayerLogin notes match `src/wire/platform_user.zig` | CURRENT |

## docs/STATE_MACHINES.md (diagrams)

| Claim | Code evidence | Status |
|---|---|---|
| Join SM diagram + owners | `c2s/join.zig` (7-package SM), `game.zig:2600` phase gate, `:3338` sendJoinBundle, `phase_gate.zig:7`; re-login and death-respawn transitions match `c2s/join.zig` | CURRENT (anchors fixed by `f711725`; spot-checked) |
| Tick pipeline diagram + owners | `ecs/schedule.zig` `run` order buffs/director/ai/vehicles/turrets/despawn/commands; `game.zig:4596` `step` | CURRENT |
| AI task diagram | `components.zig:66` AiState, `:79` TaskId; systems.zig task table; sleeper wake is proximity-based (one-way) | CURRENT (wake transition corrected by `f711725`; verified at `systems.zig:987`) |
| Quest lifecycle + POI lockout submachine | `ecs/quest.zig`, `components.zig:319` QuestProgress, `systems.zig:198/390/314`, `game.zig:4832` payout drain, `ecs/poi_lock.zig` (2000-tick grace) | CURRENT |
| Weather SM | `world/weather.zig:36` storm_state, `:106` tick, `:125` forceBloodMoon, `:302` encode; persistence restored at init | CURRENT |
| Blood moon window | `aidirector.zig:61` isBloodMoonNight, `:68` isBloodMoonDay; dusk-to-dawn across rollover | CURRENT |
| Power grid SM | `ecs/electric.zig` PowerGrid resolveDay/tick/activateTriggerAt/setSwitchAt/resetTriggerAt/armTimer; `ecs/powerblocks.zig` registry. The pre-audit owner pointed at powerblocks.zig only | CURRENT (owner corrected by `f711725`; verified) |
| Sleeper volumes | `world/sleepers.zig:38` triggered; `game/sleeper.zig` tickSleeperVolumes | CURRENT |
| Trader SM (open/restock/wallet) | `game/trader.zig:34/46/204/127`, `systems.zig:751`, `c2s/misc.zig:411`, `trade.zig` | CURRENT (section added by `f711725`; anchors verified) |
| Vehicle multi-seat | `systems.zig:1890/1934/1862/1872`, `c2s/misc.zig:520/504` | CURRENT (section added by `f711725`) |
| Ally / plugin / peer / claims | `ally.zig:31/39`, `plugin/host.zig:10`, `plugin/wasm.zig:49`, `peer.zig:129`, `game/world.zig` registerClaim/expireClaims/removeClaimAt | CURRENT |
| Em dash at line 240 | House rule | FIXED (by `f711725`; verified no U+2014 remains) |
| **Mismatching diagrams** | None found. Pre-audit defects (sleeper "alert wakes" edge, power-grid owner file, stale game.zig/systems.zig line anchors) were corrected by the state-machine audit commit `f711725` and re-verified here | CURRENT |

## docs/ASSETS.md

| Claim | Code evidence | Status |
|---|---|---|
| Loader table | Every documented module exists in `src/assets/` | CURRENT |
| Undocumented loaders | `blocks_nim.zig` (prefab `.blocks.nim` remap) and `npc.zig` (npc.xml -> trader_info) exist but had no row; `xml_patch.zig` (the `--config-overrides` patcher) existed but was not named | STALE, fixed: rows added |
| Id spaces + fail-closed rules | Match `maxdamage.idByName` usage and skip-on-miss behavior in loaders | CURRENT |

## docs/ECS.md

| Claim | Code evidence | Status |
|---|---|---|
| File list | `party.zig`, `quest_systems.zig`, `rules.zig` exist but were not listed | STALE, fixed |
| Tick order (beginTick, buffs, director, ai, vehicles, turrets, despawn, drain) | `schedule.zig` `run` matches exactly | CURRENT |
| Query/group/command/threading claims | `query.zig`, `group.zig`, `command.zig`, `util/parallel.zig` present as described | CURRENT |

## docs/SYSTEMS.md

| Claim | Code evidence | Status |
|---|---|---|
| Weather "Open: storm state does not persist across a restart" | Persistence shipped: `weather.zwt` save/restore in `game.zig` | STALE, fixed |
| "no ForceWeather / SetStorm admin commands" | No such verbs in `admin.zig` | CURRENT |
| Buffs 8-slot BuffSet | `components.zig:672` `max_buffs_per_entity = 8` | CURRENT |
| Quest builtin defs (kill x3, goto (50,70,50), visit trader) | `ecs/quest.zig` `builtin_defs` matches | CURRENT |
| Electricity owner `ecs/electric.zig` PowerGrid | Matches | CURRENT |

## docs/AUTHORITY.md

| Claim | Code evidence | Status |
|---|---|---|
| Movement envelope 20 m/s, damage cap 200, reach 96 | `movement.zig:7` 20.0; `types.zig:46` 200; `types.zig` max_edit_range 96 | CURRENT |
| Guard policy rungs and zdtd.toml switches | `guard_policy.zig` + `zdtd_config.zig` `[authority] guard_*` | CURRENT |

## docs/APM.md

| Claim | Code evidence | Status |
|---|---|---|
| Section list | `apm/profiler.zig` `Section` enum matches the table exactly (tick_total..chunk_gen) | CURRENT |
| Admin `apm` / `metrics`, `status`, `guardstats` verbs | `admin.zig` parseCommand/usageFor | CURRENT |
| `src/apm/` module set | metrics/profiler/report/root/tracy all present | CURRENT |

## docs/zig-clone.md

| Claim | Code evidence | Status |
|---|---|---|
| Founding architecture, V3.0.1-derived with a version note deferring to wire docs | Header note present; §2 deferral to source tree present | CURRENT (historical by design) |
| PackageIds map count note (~194 types, 189 mapped) | `default_mappings` = 189 | CURRENT |

## docs/adr/README.md + ADRs 0010/0015/0017/0020/0021

| ADR | Claim | Status |
|---|---|---|
| 0010 | Three-layer split; plugin/dynlib rows superseded by 0020; extended by 0021 | CURRENT (status notes accurate; layers 1-2 and no-VM rule stand) |
| 0015 | ECS `item_id` local handle vs stock absolute type; reverse map on C2S; persist stores ECS ids | CURRENT (`ecs/inventory.zig` u16 item_id; `resolveItemType`/`reverseItemType` in game.zig; ZPV3/ZCT store slots) |
| 0017 | Player persist identity = login name; ZPV3 magic; ZPV2 still read and upgraded | CURRENT (`persist.zig` ZPV3 records, ZPV2 read + merge-write upgrade) |
| 0020 | Wasm-only plugin API; static host is test scaffolding | CURRENT. **Follow-up section stale**: "Still open... T9: host function list, capability set, fuel/memory defaults, loader" all shipped 2026-08-06/07 (`plugin/wasm.zig` loadAll + fuel/memory budgets + zdtd_log/tick/queue imports; T15 hooks). FIXED |
| 0021 | Reflected binder, Rules struct, mode overlay, floor audit, event hooks; implemented 2026-08-07 | CURRENT (header states implemented; code matches) |

## docs/WORK_PLAN.md

| Claim | Code evidence | Status |
|---|---|---|
| T1-T15 landed markers | STATUS waves + code (traders, loot, quests, wasm, binder, Rules, modes) | CURRENT |
| T16/T17 landed 2026-08-08 | `buffs.survival()` thresholds in `game/tick.zig`; `Rules.systems` gate in `schedule.zig` | CURRENT |
| Header pin (2026-08-06, 758 tests) | Point-in-time pin for the ranking; STATUS wins on gates | CURRENT (historical pin; flagged, not changed) |
| Em dashes at lines 665, 668, 720 | House rule | FIXED |

## docs/TODO.md

| Claim | Code evidence | Status |
|---|---|---|
| Doc map "345 features scored" | GAP_ANALYSIS scorecard sums 338 | STALE, fixed to 338 |
| Gates line (2026-08-06, 758 tests) | Measured 975 at `f41849b` | STALE, fixed to 2026-08-08 / 975 |
| Em dashes at lines 172, 173, 181, 301, 548 | House rule | FIXED |

## docs/INDEX.md

| Claim | Code evidence | Status |
|---|---|---|
| Milestone snapshot "99 WORKS / 150 PARTIAL / 96 MISSING" | GAP_ANALYSIS scorecard totals 134 / 150 / 54 (338) | STALE, fixed |
| M11 "spatial cell hash and the bot gate remain" | Cell-based range interest shipped (`ecs/interest.zig`); a bucketed spatial hash index and the bot gate remain open per GAP P2 band | CURRENT |

## docs/GAP_ANALYSIS.md

| Claim | Code evidence | Status |
|---|---|---|
| 338 features, scorecard 134/150/54 | Area header rows sum to 338; scorecard row sums match | CURRENT |
| "the per-area headers and the scorecard rows both match the markers" (section 1a) | Only 329 inline status markers are present (134 WORKS / 142 PARTIAL / 53 MISSING); 9 bullets carry no marker, so the marker-match claim is off by 9 | FLAG (recount of 338 bullets is beyond a doc-only pass; STATUS wins on conflicts) |
| `src/server/game.zig:NNNN` anchors (e.g. :6466, :7841, :7885, :8076, :8131) | game.zig is 5153 lines; those anchors point past EOF (pre-extraction line numbers) | FLAG (class: pre-extraction anchors; a full anchor refresh is a separate pass) |
| Date pin 2026-08-06 + rescore notes | Consistent with the doc's own pin policy | CURRENT (point-in-time) |
| Em dashes (23) | House rule | FIXED |

## Secondary docs (spot-checked)

| Doc | Claim | Status |
|---|---|---|
| WEBUI.md | /healthz, /readyz, /api/cmd, /api/apm.json, --webui-port/bind/secret, ZDTD_WEBUI_SECRET | CURRENT (`webui.zig` routes match) |
| PLUGIN_API.md / PLUGIN_DEV.md | Hook set incl. T15 + on_admin_command/on_chat; PLUGIN_DEV missed `on_player_login` | PLUGIN_DEV STALE, fixed (on_player_login added) |
| INVENTORY.md | Slot layout, authority interim, stack limits | CURRENT |
| MAPS.md | DTM/prefabs/water loading | CURRENT |
| WIRE_CHUNK.md / WIRE_WORKSTATION.md | Encoders, TE type 12 v50 body | CURRENT |
| RELEASES.md | Version policy, V3.1.0 b14 only | CURRENT |
| PARITY_TOOLING.md | Tooling lives in 7dtd-research | CURRENT |
| STD_ABSTRACTIONS.md | std.Io map | CURRENT |
| CLIENT_PLAYTEST.md | Design/suite | CURRENT |
| IMPLEMENTATION_PLAN.md | M11.2/.3/.4 shipped markers; M11.1 open | CURRENT |
| SCALE_ARCHITECTURE.md / PLANET_SCALE.md | Parked M11 | CURRENT (parked by design) |

## Em-dash sweep (U+2014, house rule)

All occurrences in tracked workspace text were replaced with hyphens
(doc-only): docs/GAP_ANALYSIS.md (23), docs/STATUS.md (12), docs/WORK_PLAN.md
(3), docs/GAME_OPTIONS.md (3), docs/prompts/net-send-review.md (9),
docs/prompts/hardcoded-data-review.md (6), docs/reviews/HARDCODE_AUDIT.md (5),
TODO.md (7), AGENTS.md (4), handoff.md (6), zdtd.toml.example (1). Verified:
zero U+2014 remain in `docs/`. Vendored `zig-pkg/zwasm-*` and `.claude/worktrees`
were excluded (third-party / scratch). En dashes (U+2013) in ranges like
"B14-B21" are not em dashes and were left alone.

## Not fixed (larger passes)

1. GAP_ANALYSIS inline-marker count (329 vs 338 claimed) and its pre-extraction
   `game.zig` anchors: needs a per-row re-audit, not a doc edit.
2. WORK_PLAN / TODO date-pinned gate lines other than the top ones: kept as
   historical pins (STATUS wins on conflict).
3. handoff.md is a point-in-time working note; its game.zig line counts (5310,
   5115, 5099) predate the last extraction commits and disagree with each other
   and with `wc -l` (5153). STATUS pins the live number; the handoff is not a
   live inventory.
