# Client playtest suite: stock-client gameplay automation

**Status:** Phase A implemented (2026-07-24): `7dtd-playtest` mod + orchestrator;
connect is join-only again.  
**Audience:** agents and humans extending acceptance beyond unit tests and loadgen  
**Related:** [STATUS.md](STATUS.md), [PARITY_TOOLING.md](PARITY_TOOLING.md), sibling
[`../../7dtd-fastconnect/`](../../7dtd-fastconnect/), [`../../7dtd-loadgen/`](../../7dtd-loadgen/)

This doc specs how we grow **programmatic, real-client** gameplay testing for
**zdtd** (and optionally stock dedi later). It builds on the existing 11-step
`PlayTestDriver` inside `7dtd-fastconnect`, then replaces that with a proper suite.

---

## 1. Why this exists

| Layer | What it proves | What it cannot prove |
|---|---|---|
| `zig build test` | Wire goldens, sim units, no layout regressions | Client `Read` survival, mesh, UI, XUi, ECD |
| loadgen bots | Join volume, walk, some C2S under load | Full stock client parse, CGO, journals, TE UI |
| Manual play | Reality | Repeatability, coverage, CI-ish exit codes |
| **Stock client suite (this)** | Client stayed alive, state matches, paths round-trip | Pure CPU scale (use loadgen + apm) |

The stock Unity client is the **oracle for wire fidelity**. A package that unit
tests encode correctly can still fail client `Read`, leave CGO at 0, or wedge
"Starting game…". Automated client play is the acceptance layer for playability.

**Policy (workspace AGENTS #10):** the suite **drives** real client APIs and
**asserts** observable state. It must **not** invent missing S2C (no fake chunks,
signs, journals, or swallowed NREs). Failures mean **fix the server**, not
the client.

---

## 2. Baseline before the split

### 2.1 Pieces

| Piece | Location | Role |
|---|---|---|
| Connect + auto-join | `7dtd-fastconnect` | IP join, skip intro/news/Discord/EULA, boot uncap |
| Spawn heartbeat | `SpawnStateHeartbeat.cs` | Overlay gates (CGO, fixedSize, xuiReady) |
| Hardcoded play driver | `PlayTestDriver.cs` | 11 steps when `PLAYTEST=1` |
| Pair launch | `restart_pair.sh` | Kill Proton/wineserver, start zdtd + client |
| One-shot join | `one_shot_join.sh` | Join cycle + log scrape + kill client |
| Server admin TCP | zdtd `--admin-port` | `give`, `tele`, `kill`, `inv`, `spawnentity`, … |
| Unit / loadgen | zdtd + `7dtd-loadgen` | Fast gates |

### 2.2 Former 11 steps (pw38 PASS, removed with the split)

```text
spawned → look → move → inventory → ground → dig → stats → place
→ craft_open → quests → buffs → SUMMARY/DONE
```

Log lines: `[7dtd-playtest] PASS|FAIL <name> …` then `SUMMARY` / `DONE`.

### 2.3 Limits (why improve)

1. **Weak oracles.** Several steps record PASS without waiting for server
   echo (dig/place fire `SetBlocksRPC` and pass immediately). Move uses
   `SetPosition` (local teleport), not player motor / PosAndRot authority path.
2. **Single linear script.** No suites, tags, skip, or focus one scenario.
3. **No combat / death / loot / trade / TE / vehicle / rejoin / multiplayer.**
4. **No server coordination.** Admin TCP is unused by the driver; cannot spawn
   a zombie at a known offset or `give` a recipe item and assert bag.
5. **Lives in connect.** Conflicts with `7dtd-fastconnect` AGENTS ("join plumbing
   only; no gameplay"). Playtest will grow; connect must stay tiny.
6. **Harness is fire-and-forget.** `restart_pair.sh` does not wait for DONE,
   score PASS/FAIL, or exit non-zero. Humans/scripts scrape logs by hand.
7. **Flake opacity.** No retries, no JUnit JSON, no flake ledger, no wall-clock
   budgets per step.
8. **Client-only view.** No dual-check against admin `inv` / block store /
   entity list after actions.

---

## 3. Goals and non-goals

### Goals

1. **Programmatic coverage of play surfaces** that matter for "stock client
   playable on zdtd," using the **real client** under Proton, EAC off.
2. **Structured, machine-scorable results** (exit code + JSON/JSONL report).
3. **Dual oracle:** client runtime + server admin (when target is zdtd).
4. **Composable scenarios** (smoke vs deep vs soak), not one mega-switch.
5. **Clean project split:** connect = join; playtest = drive + assert.
6. **Honest failures:** suite never patches around missing server wire.

### Non-goals

- Replacing unit tests or loadgen (different layers).
- Full visual regression / screenshot AI (optional later; not the spine).
- EAC-on or Steam browser join.
- Running as always-on free GitHub CI without a game-bearing runner.
- Inventing client-side world content to keep the suite green.
- Becoming a second game: no custom net protocol for the suite.

---

## 4. Recommended architecture

```text
┌──────────────────────────────────────────────────────────────────┐
│ Orchestrator (host, Python via uv or bash wrapper)               │
│  start zdtd (admin-port) → install mods → launch client          │
│  tail client log → optional admin script → score → teardown      │
└───────────────┬─────────────────────────────┬────────────────────┘
                │ env / argv                   │ TCP
                ▼                              ▼
┌───────────────────────────┐     ┌──────────────────────────────┐
│ Stock client (Proton)     │     │ zdtd --admin-port            │
│  Mods/7dtd-fastconnect        │     │  fixtures world / map        │
│  Mods/7dtd-playtest  ◄────┼─────┤  give/tele/kill/spawn/inv    │
│   scenario runner         │     │  optional playtest probes    │
│   client oracles          │     └──────────────────────────────┘
│  real GameManager/World   │
└───────────────────────────┘
         │ structured logs
         ▼
  [7dtd-playtest] JSONL events + SUMMARY
```

### 4.1 Project split

| Project | Path (proposed) | Owns |
|---|---|---|
| **7dtd-fastconnect** | existing | Join only: auto-join, F1 connect, skip intro/news/Discord/EULA, spawn heartbeat, launch scripts **without** gameplay |
| **7dtd-playtest** | **new** sibling | Scenario runner mod, client oracles, suite manifests, orchestrator, report scoring |
| **zdtd** | existing | Server under test; admin TCP fixtures; unit tests; STATUS gates |
| **7dtd-loadgen** | existing | Multi-bot demand (orthogonal; can co-run soak scenarios) |

**Migration:** move `PlayTestDriver.cs` out of connect into playtest (or delete
and reimplement on the runner). Connect AGENTS stays honest: no gameplay.

Install both mods under the client `Mods/`:

```text
$GAME/Mods/7dtd-fastconnect/     # join
$GAME/Mods/7dtd-playtest/    # scenarios when env armed
```

Playtest **requires** connect for auto-join (or human F1 connect). It does not
reimplement IP connect.

### 4.2 Why a second mod (not grow connect)

- Connect is load-bearing for every manual join; keep its blast radius small.
- Playtest will depend on more Harmony surface (input, UI, combat hooks).
- Operators can run client with connect only; CI installs both.
- Matches workspace rule: connect is "join/automation plumbing"; suite is a
  **test product**, not a join helper.

### 4.3 Orchestrator vs in-game runner

| Concern | Where |
|---|---|
| Process lifecycle, Proton kill, exit codes | Host orchestrator |
| Scenario selection, timeouts, report path | Env → playtest mod + orchestrator |
| Frame-timed actions (move for 2s, open UI) | In-game runner on `gmUpdate` |
| Spawn zombie at player, give item, force kill | Server admin TCP from orchestrator **or** from client via localhost admin if allowed |
| Assert block on server after dig | Admin probe command (new) or client wait for `GetBlock` change |

**Default pattern:** orchestrator starts server + client; **in-game runner**
owns the scenario timeline; **orchestrator** only scores logs and runs a
**side channel** admin script for setup/teardown steps tagged `admin:`.

Client calling admin TCP is optional (loopback only). Prefer orchestrator-side
admin for clearer process ownership and no extra client network surface.

---

## 5. In-game runner design

### 5.1 Arming

```bash
# Suite selection (examples)
PLAYTEST=1                         # legacy: demo suite
PLAYTEST_SUITE=smoke               # explicit
PLAYTEST_SUITE=core,combat,craft   # multi
PLAYTEST_TAGS=dig,place            # filter by tag
PLAYTEST_TIMEOUT_SEC=600
PLAYTEST_SEED=42
PLAYTEST_REPORT=/tmp/playtest.jsonl  # if file write available under Proton: use log only by default
```

Prefer **log-only** results (always available under Proton). Optional host-side
file is built by the orchestrator scraping the client log.

### 5.2 Lifecycle states

```text
Disarmed → Armed (env)
  → WaitWorld (World + game started)
  → WaitPlayer (primary spawned, overlay gates OK)
  → WaitReady (optional: CGO ≥ gate, xuiReady, terrainReady)
  → RunScenario (steps)
  → BetweenScenarios (reset player pose / inv if needed)
  → Finished (SUMMARY + DONE)
```

Reuse the same gates as `SpawnStateHeartbeat` (do not force-start the game).

### 5.3 Step model

Each step is a small state machine, not a single fire-and-forget call:

```text
Enter → Act → Wait(predicate, timeout) → Assert → Record → Next
```

**Predicates (client):**

- `player_spawned`, `cgo_min(n)`, `xui_ready`, `overlay_closed`
- `block_at(x,y,z) == type` / `!= type` / `solid`
- `player_moved_min(dist)`, `player_hp_in(min,max)`
- `entity_count_kind(zombie|animal|loot) >= n` in radius
- `holding_type`, `bag_contains(item_type|name)`
- `quest_count >= n`, `window_open(name)`
- `no_new_nre` (log tail hook is host-side; in-game can check known error flags if any)

**Actions (client, stock APIs only):**

| Action | Prefer | Avoid |
|---|---|---|
| Look | set look / camera yaw via player rotation APIs used by stock | arbitrary camera hacks |
| Walk | movement input / velocity path that emits PosAndRot | only `SetPosition` (ok for **setup**, not for "move works") |
| Dig / place | `SetBlocksRPC` / item action that matches stock dig | silent local `SetBlock` without RPC |
| Open UI | `windowManager.Open` known window names | reflection spam |
| Attack | stock melee/gun action if available | faking DamageEntity from client without held item |
| Loot | open TE / bag interact APIs | inventing loot UI |

Document each action as **setup** vs **under test**. Setup may teleport
(`admin tele` or `SetPosition`); under-test move must use locomotion.

### 5.4 Result event schema (JSONL in client log)

One line per event, prefix `[7dtd-playtest] ` then JSON:

```json
{"v":1,"t":"result","suite":"core","case":"dig_confirm","status":"pass","ms":1820,"detail":"was=12 now=0"}
{"v":1,"t":"result","suite":"core","case":"place_confirm","status":"fail","ms":5000,"detail":"timeout waiting block type"}
{"v":1,"t":"log","level":"info","msg":"armed suite=core"}
{"v":1,"t":"summary","pass":14,"fail":1,"skip":0,"suites":["core"]}
{"v":1,"t":"done","exit_hint":1}
```

Legacy human lines can remain as dual output for grepping:

```text
[7dtd-playtest] PASS dig_confirm was=12 now=0
[7dtd-playtest] SUMMARY pass=14 fail=1 total=15
[7dtd-playtest] DONE
```

Orchestrator exit code: **0** iff `fail==0` and `DONE` seen before timeout;
**1** failures; **2** harness error (no client, no DONE, crash).

### 5.5 Suite manifests

**v1 implementation:** C# static suite registry (typed, refactor-friendly).

**v1.5 optional:** JSON manifests under `7dtd-playtest/suites/*.json` loaded at
runtime for data-only tweaks (coordinates, timeouts) without rebuild.

Example conceptual case:

```json
{
  "id": "dig_confirm",
  "tags": ["world", "c2s", "setblock"],
  "timeout_ms": 8000,
  "steps": [
    { "act": "look_yaw", "deg": 90 },
    { "act": "note_block", "offset": [0, 0, 1], "as": "target" },
    { "act": "dig_rpc", "ref": "target" },
    { "wait": "block_type", "ref": "target", "eq": 0, "timeout_ms": 5000 },
    { "assert": "block_type", "ref": "target", "eq": 0 }
  ]
}
```

Admin-assisted case (orchestrator injects between client steps via a simple
**barrier protocol** in the log):

```text
client:  {"t":"barrier","name":"need_zombie"}
host:    admin: spawnentity 0 zombieBoe
host:    {"t":"barrier_ack","name":"need_zombie"}  # written to a side file the client polls, OR client waits wall time after admin-only setup phase
```

**Simpler v1 barrier:** scenarios that need admin run as **two-phase** suites:

1. Host pre-setup (tele, give, spawnentity) **before** client scenario starts,
   using known spawn coordinates from the fixture world.
2. Client-only steps with fixed world assumptions.

Add interactive barriers only when pre-setup is insufficient (e.g. mid-scenario
kill after damage).

---

## 6. Suite catalog (coverage target)

**Canonical live list:** sibling
[`../../7dtd-playtest/SCENARIOS.md`](../../7dtd-playtest/SCENARIOS.md)
(demo / benchmark / full catalog, ~100 live cases). Code:
`7dtd-playtest/Source/PlayTestMod/Catalog.cs`.

Prioritize by playability value and current STATUS/TODO gaps.

### Tier 0: Smoke (`smoke`)  ~1–2 min after in-game

| Case | Assert |
|---|---|
| join_ready | game started, player spawned, xuiReady, CGO gate ok / fixedSize |
| no_nre_window | host: 0 new NRE/WRN/underrun since join (log window) |
| ground | block under feet solid |
| stats | hp/stamina sane |

Replaces minimal join confidence; runs on every local "did I break join?" loop.

### Tier 1: Core loop (`core`)  ~3–8 min

| Case | Assert |
|---|---|
| look | rotation applied |
| walk_motor | position change via **locomotion** over N seconds; optional server pos agreement |
| dig_confirm | RPC dig + **wait** until `GetBlock` air (or damage progress) |
| place_confirm | place + wait solid |
| inv_toolbelt | inventory non-null; holding type readable |
| craft_window | crafting window opens without exception |
| journal | QuestJournal present; starter quest if expected |
| buffs | Buffs manager live |
| holding_echo | change held slot if possible; no client error flood |

### Tier 2: Combat / entities (`combat`)

| Case | Assert |
|---|---|
| entity_visible | after admin `spawnentity`, client sees entity id/class nearby |
| damage_out | attack reduces target HP or entity dies (client view) |
| death_loot | kill → loot bag entity or Items; bag ECD readable |
| player_death | admin damage/kill player → death UI / hp 0 → respawn path |
| spawn_on_approach | move toward sleeper/director spawn; ECD appears once |

### Tier 3: Economy / TE (`economy`)

| Case | Assert |
|---|---|
| chest_open | admin-seeded chest / prefab TE; lock + InvData path; slots non-empty or empty correct |
| craft_consume | give ingredients → InvTx/craft → output present (client + admin `inv`) |
| workstation | open forge/campfire TE; recipe queue / burn tick if wired |
| trader | tele to trader; TraderData UI / stock list non-empty; no Read underrun |
| quest_progress | trigger objective; journal phase/value changes |

### Tier 4: Persistence (`persist`)

| Case | Assert |
|---|---|
| dig_survives_rejoin | dig block → save → restart pair → block still air |
| inv_survives_rejoin | obtain item (loot/give+pickup) → save → rejoin → present |
| player_pos_rejoin | move → save → rejoin near last pos (y-clamp aware) |

Orchestrator owns mid-suite **server restart**; client may reconnect via
connect auto-join if env still set, or full pair restart between cases.

### Tier 5: World fidelity (`world`)

| Case | Assert |
|---|---|
| poi_textures | at known POI tele: non-terrain block id ≥ 256 present client-side |
| chunk_stream | walk ring; CGO increases / stays ≥ gate; 0 WindowFull critical drops (server log) |
| weather_optional | biome weather array if implemented (xfail until STATUS green) |
| deco_optional | deco trees (xfail while suppressed) |

### Tier 6: Multiplayer / load (`mp`)

| Case | Assert |
|---|---|
| two_clients_see | optional second client or loadgen bot; other entity PosAndRot visible |
| concurrent_bots | loadgen N bots + playtest smoke still DONE with 0 NRE |

### Tier 7: Soak (`soak`)

Longer walk, random yaw, periodic dig, 15–60 min; fail on first NRE/underrun
or tick budget breach (server apm dump).

**xfail / skip policy:** cases for known MISSING features are tagged `xfail`
with a GAP_ANALYSIS section id. Suite stays green while documenting the
gap; flipping xfail→pass is the STATUS update.

---

## 7. Server-side support (zdtd)

Minimal admin/fixture work so the client suite is deterministic.

### 7.1 Already usable

`give`, `tele`, `kill`, `inv`, `spawnentity`, `listents`, `save`/`saveworld`,
`settime`, `status`, `shutdown`.

### 7.2 Add when needed (small, named honestly)

| Command / feature | Purpose |
|---|---|
| `blockget x y z` | Server block type for dual oracle |
| `blockset x y z type` | Fixture setup (lab only; document as admin authority) |
| `playerpos <slot>` | Server authority position |
| `damage <entityId> <amount>` | Controlled combat without relying on AI |
| `wipeinv <slot>` | Deterministic inventory before give |
| Fixture world dir | Known trader coords, flat pad, chest POI, workbench |

Prefer a **committed fixture world** under `zdtd-server/worlds/playtest_*` (or
generated by script from Navezgane tele list) over random RWG.

### 7.3 Playtest mode flag (optional)

`--playtest` or serverconfig: slightly more deterministic director (seeded),
disable air drops that desync tele assumptions, fixed day time. Must not change
wire shapes; only ops knobs.

---

## 8. Host orchestrator

### 8.1 CLI sketch

```bash
# From 7dtd-playtest/
uv run playtest run --suite smoke --world ../zdtd-server-server/worlds/playtest_nav
uv run playtest run --suite core,combat --port 27025 --admin-port 8081
uv run playtest run --suite persist     # multi-phase restart
uv run playtest report path/to/client.log
```

### 8.2 Pipeline

```text
1. preflight: GAME dir, mods installed, zdtd binary, free ports
2. clean: kill zdtd + 7DaysToDie + wineserver/pressure-vessel (reuse restart_pair lessons)
3. start zdtd: --admin-port, fixture world, map Navezgane, log path
4. wait: server "tick=20Hz" or listen ready
5. admin setup: settime day; optional tele pad prep
6. launch client: 7DTD_CONNECT + PLAYTEST_SUITE=… via launch_client.sh
7. watch: tail client log for JSONL / DONE; enforce suite timeout
8. score: parse results; optional server log NRE/WRN scan; admin post-checks
9. teardown: shutdown admin or kill; kill Proton stack; write report.json
10. exit: 0/1/2
```

### 8.3 Reports

- `report.json`: suites, cases, status, ms, detail, client log path, server log path, git/zdtd version if known
- Optional JUnit XML for tooling that expects it
- Copy last SUMMARY into STATUS evidence notes when gating a release

### 8.4 Flakes

- Default **no auto-retry** (hides server bugs).
- Optional `--retries 1` only for harness failures (client never booted), never for assertion fails.
- Record wall times; flag cases > 2× median as slow (non-fail).

---

## 9. How this relates to other test layers

```text
                    ┌─────────────────────┐
                    │ stock client suite  │  ← fidelity (this doc)
                    └──────────┬──────────┘
                               │
         ┌─────────────────────┼─────────────────────┐
         ▼                     ▼                     ▼
   loadgen bots          zig unit tests         parity tooling
   (volume / C2S)        (goldens / sim)        (package catalog)
         │                     │                     │
         └─────────────────────┴─────────────────────┘
                               │
                        STATUS.md gates
```

| Change type | Minimum gates |
|---|---|
| Wire package body | unit golden + affected client case |
| Join / WorldInfo / chunk | smoke + core |
| Combat / ECD | combat suite |
| Inv / TE / craft | economy suite |
| Save format | persist suite |
| Interest / scale | loadgen + apm (+ optional mp suite) |

Do **not** require the full client suite for every pure-Zig refactor that does
not touch wire or sim behavior; keep unit tests as the fast loop.

---

## 10. Implementation plan (phased)

### Phase A: Split and harden (**DONE**, code landed)

1. ~~Create `7dtd-playtest` repo/mod skeleton~~ → `../7dtd-playtest/`
2. ~~Move play driver out of connect~~ → `PlayTestDriver.cs` removed
3. ~~Act → Wait → Assert for dig/place/ground~~ → `Suites.cs` + `Runner.cs`
4. ~~JSONL + legacy log lines; `DONE` + exit_hint~~ → `Report.cs`
5. ~~Orchestrator with log wait + exit code~~ → `scripts/playtest_run.py`
6. ~~One-command~~ → `make playtest-smoke` / `playtest-core`

**Exit gate:** `make -C 7dtd-playtest playtest-core` on a game-bearing machine
with built zdtd; dig/place must **confirm** via `GetBlock` wait.

### Phase B: Admin dual oracle (2–4 days)

1. Admin `blockget` / `playerpos` (and wipeinv if cheap).
2. Suites: combat (spawnentity + observe), give+inv dual check.
3. Pre-setup phase in orchestrator for tele/give/spawn.
4. Fixture world notes (trader coords, safe dig pad).

**Exit:** combat + at least one economy case green or honest xfail.

### Phase C: Catalog depth (ongoing)

1. Add cases from section 6 mapped to TODO/MISSING rows.
2. persist suite with controlled restart.
3. xfail markers tied to MISSING section ids.
4. STATUS table: replace "11/11" with `playtest core N/N` + suite matrix.

### Phase D: MP / soak (after core stable)

1. Optional second client or loadgen co-run.
2. Soak profile + apm dump attach.
3. Nightly script on the game-bearing machine (not free CI).

---

## 11. Acceptance criteria for the suite itself

The playtest **system** is done for Phase A when:

1. `7dtd-fastconnect` contains **no** gameplay driver.
2. `PLAYTEST_SUITE=core make -C 7dtd-playtest playtest` (or uv CLI) returns exit 0 on a
   known-good zdtd, and exit 1 if dig echo is broken (mutation test: break
   SetBlock S2C temporarily and confirm fail).
3. Every core case either waits on a real predicate or is labeled setup-only.
4. Client log has parseable SUMMARY/DONE; orchestrator does not require a human.
5. No Harmony that swallows NRE or invents chunks/inventory/world packages.
6. Docs: this file + playtest README + STATUS gate line.

---

## 12. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Proton/wine process leaks | Reuse aggressive kill list from `restart_pair.sh` |
| Game update breaks Harmony | Pin game version in suite README; parity tooling for wire; soft-skip unknown UI names |
| Flaky timing | Wait predicates + timeouts, not fixed sleep-only steps |
| Suite becomes client "fix" for server gaps | Code review against AGENTS #10; ban list in playtest AGENTS |
| Slow feedback | Tier0 smoke < 2 min in-game; deep suites on demand |
| SetPosition false confidence | Split setup tele vs locomotion case |
| Admin desync | Dual oracle; prefer client wait for S2C-visible state |

---

## 13. AGENTS rules for `7dtd-playtest` (proposed)

1. Client-only mod; EAC off; net48 + stock Harmony.
2. **Drive and assert only.** No local world generation, no fake S2C, no error swallow.
3. Prefer public game APIs used by stock gameplay over private field hacks.
4. Scenarios name the real behavior under test; setup steps labeled setup.
5. Do not depend on 7dtd-server-apm Mono bridge.
6. Orchestrator uses `uv` for Python; secrets via env.
7. No em dashes; no AI attribution.
8. Server gaps → open zdtd work / MISSING row, not a client patch.

---

## 14. Open decisions (resolve in Phase A)

| Decision | Options | Recommendation |
|---|---|---|
| Repo location | new `7dtd-playtest/` vs under connect | **new sibling** (clean AGENTS) |
| Scenario language | C# only vs JSON | **C# v1**, JSON data for coords later |
| Mid-scenario admin | barriers vs pre-setup only | **pre-setup v1**, barriers Phase B if needed |
| Locomotion drive | synthetic input vs `SetPosition` | both: tele setup, input for walk case |
| Report sink | log scrape only vs Proton-visible file | **log scrape** (reliable) |
| Stock dedi target | zdtd only vs also Unity dedi | **zdtd first**; keep admin calls behind interface |

---

## 15. One-page command cheat sheet (target UX)

```bash
# Install mods
make -C 7dtd-fastconnect install
make -C 7dtd-playtest install

# Fast fidelity gate (real client)
make -C 7dtd-playtest playtest-smoke

# Core loop (dig/place confirmed, UI, journal)
make -C 7dtd-playtest playtest-core

# Deeper
make -C 7dtd-playtest playtest SUITE=core,combat,economy

# Legacy-compatible
PLAYTEST=1 7dtd-fastconnect/scripts/restart_pair.sh /path/to/world
# (after split: still works; playtest maps PLAYTEST=1 → suite demo)
```

---

## 16. Summary

We already proved **one** automated stock-client loop (11/11). The next step is
not more ad-hoc steps in connect; it is a **dedicated playtest product**:

- **connect** = get into the game  
- **playtest mod** = scripted play + client oracles  
- **orchestrator** = process lifecycle + scoring + admin fixtures  
- **zdtd admin / fixture worlds** = deterministic setup  
- **STATUS** = suite matrix as the playability gate  

That stack can grow to cover combat, craft, trade, persist, and soak without
violating "server owns the wire" and without pretending loadgen is a full client.

## Fresh world per run

The harness defaults to `FRESH=1`, which removes the save before each run. The
suites dig and place blocks, so reusing one world accumulates holes under the
test area until dig and place fail on the previous run's terrain rather than on
anything the server did. Pass `FRESH=0` only to inspect an existing save.

Known limitation: with a fresh world the `full` suite currently registers 23
cases instead of 85, because the extra cases depend on a prepared world and stop
registering rather than failing. That is tracked as W1 and W2 in
[WORK_PLAN.md](WORK_PLAN.md).

## Loadgen parity run vs the stock dedicated server (2026-08-06)

The same loadgen workload ran against the stock V3.1.0 dedicated server and
against zdtd, to compare the join/walk path on the real protocol.

**Re-verified 2026-08-07 at HEAD** (trader per-info stock, quest-POI data and
the per-trader wallet landed since): the same workload
(`--join --count 2 --actions 20 --seed 4242`) joins both bots on zdtd
(walks=23 each, 0 deaths, 0 respawns). The `NetPackageIdMapping` send still
logs the known `WindowFull` under the bot reconnect flood and is non-fatal:
the client falls back to its local blocks.xml ids and the join completes
(GAP-tracked; retry pacing in `sendFramedReliable`).

Workload: `7dtd-loadgen --join --count 2 --actions 20 --seed 4242`
(`--mode wander`, 150 s timeout). Stock leg: stock dedi, Navezgane, EAC off,
LiteNet port 26902. zdtd leg: flat default world, LiteNet port 27004.

| Metric | Stock dedi | zdtd |
|---|---|---|
| Bots joined | 2, rc=0 | 2, rc=0 |
| Walks | 1058 (713 + 345) | 667 (322 + 345) |
| Jumps | 15 | 15 |
| Deaths / respawns | 0 / 0 | 0 / 0 |
| Protocol errors (loadgen side) | none | none |
| Server-side join/phase/decodes | n/a (no counters) | join_ok=26, join_fail=0, phase_rejects=0, decode_rejects=0, c2s_rejects=0 |

Walk totals differ because the worlds differ (Navezgane vs flat); both bots
walked until the run ended and neither server dropped or killed them. The zdtd
apm dump shows the known reliable-window send pressure under the bot reconnect
flood (`net_send_errors` / `reliable_window_drops`), which is the IdMapping
WindowFull item tracked in GAP (mitigated by the retry pacing in game.zig), and
a few startup/worldgen tick overruns; none of it failed a join.

Conclusion: for the loadgen surface (challenge, ids, login, enter, spawn,
movement, teleport), zdtd behaves like the stock dedicated server on the same
workload. The full stock-client suite remains the visual oracle and is covered
by the automated demo runs recorded in STATUS.
