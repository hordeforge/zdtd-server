# ⚡ BloodWire (ZDTD Server)

> **Part of [HordeForge](https://github.com/hordeforge)**: High-Performance Systems Engineering for 7 Days to Die.

![CI](https://github.com/hordeforge/zdtd-server/actions/workflows/ci.yml/badge.svg)
![quality gate](https://sonarcloud.io/api/project_badges/quality_gate?project=maci0_zdtd)
![license](https://img.shields.io/github/license/hordeforge/zdtd-server)
![last commit](https://img.shields.io/github/last-commit/hordeforge/zdtd-server)
![languages](https://img.shields.io/github/languages/count/hordeforge/zdtd-server)
![top language](https://img.shields.io/github/languages/top/hordeforge/zdtd-server)

**Zeven Days to Die** (or **ZDTD**): a zero-allocation, high-throughput dedicated server written from scratch in Zig, targeting the stock 7 Days to Die **client wire** (EAC off).

```text
7 Days to Die  →  ZDTD  →  Zeven Days to Die
     7DTD             ZDTD
```

Not a Harmony mod. Not RealEarth. Not EfficientServer. Not a drop-in host for
existing mods. Sibling of this workspace only for **RE docs** and **loadgen**
wire tests.

**Profiling:** built-in harness under `src/apm/` ([docs/APM.md](docs/APM.md)).

## 📚 Modding Best Practices

See the canonical **[HordeForge 7DTD Modding Best Practices Guide](https://github.com/hordeforge/.github/blob/main/MODDING_BEST_PRACTICES.md)** for engine load order rules, EAC-off requirements, `ModInfo.xml` specifications, and V3.1.0 compatibility notes.  
That is **not** sibling `7dtd-server-apm` (stock Mono dedi).

## Status

**Client-wire dedi:** core stock loop playable (EAC off). Join, dig/build, fight,
death/respawn, loot, craft/workstation, trade, persist; live stock-client gate
**23/23** on a fresh world each run (`FRESH=1`), demo residuals closed
(2026-08-09, see STATUS).
See [docs/STATUS.md](docs/STATUS.md).

```bash
# Flat default world (builtin quest catalog)
zig-out/bin/zdtd --port 27002 --world worlds/zdtd_default

# Stock Navezgane / Pregen (dtm + prefabs + water + Data/Config/quests.xml)
GAME="$HOME/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server"
zig-out/bin/zdtd --port 27002 --game-dir "$GAME" --world-name Navezgane --world worlds/nav_save
# or: --map "$GAME/Data/Worlds/Pregen06k01"
# or: --quests assets/fixtures/quests.xml
# names: Navezgane, Pregen06k01, Pregen06k02, Pregen08k01, Pregen08k02

# Operator web UI (WU0–WU2; loopback + secret min 8 chars; docs/WEBUI.md):
#   ZDTD_WEBUI_SECRET=change-me zdtd --port 27002 --world worlds/zdtd_default \
#     --webui-port 8080
#   curl -H 'Authorization: Bearer change-me' http://127.0.0.1:8080/

# loadgen joins LiteNet (ServerPort+2), not the TCP info port:
#   7dtd-loadgen --join --host 127.0.0.1 --port 27004 --count 2 --actions 20
# Navezgane boot + join smoke: scripts/smoke-navezgane.sh (map load assertions)
```


**Stock maps:** `--map` points at a game world folder (`map_info.xml`, `dtm.raw` /
`dtm_processed.raw`, optional `spawnpoints.xml`). Heights are u16 LE `gameY*256`,
world origin at map center (`wx + W/2`). `--world` remains the writable zdtd save
overlay; `.zch` files use the ZCH3 format for heights and full u32 block data.

Milestones / architecture: [`docs/ZIG_CLONE.md`](docs/ZIG_CLONE.md).

## Non-goals

| Not supported | Why |
|---|---|
| **Mods** (Harmony, ModAPI, XML-only mods, EfficientServer, RealEarth) | Clean-room Zig process; no managed game assembly |
| **7dtd-server-apm as a dependency** | Different process; use **zdtd `src/apm/`** instead |
| **EAC-on clients** | Custom server path |

Validation is **loadgen bots** + stock clients + **zdtd apm** dumps.

## Docs (read these first)

| Doc | Role |
|---|---|
| [`docs/STATUS.md`](docs/STATUS.md) | What works now (wins on conflict) |
| [`docs/INDEX.md`](docs/INDEX.md) | Full doc map |
| [`docs/RELEASES.md`](docs/RELEASES.md) | Version, compatibility, support, and release policy |
| [`CHANGELOG.md`](CHANGELOG.md) | Consumer-visible changes and migrations |
| [`TODO.md`](TODO.md) | Open backlog |
| [`docs/GAP_ANALYSIS.md`](docs/GAP_ANALYSIS.md) | Gap inventory vs stock |
| [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) | M7–M16 post-playable stack |
| [`docs/ECS_SYSTEMS.md`](docs/ECS_SYSTEMS.md) / [`docs/ZIG_CLONE.md`](docs/ZIG_CLONE.md) | Sim + architecture |
| [`../7dtd-engine-research/docs/protocol.md`](../7dtd-engine-research/docs/protocol.md) | Envelope, join, goldens |

Golden wire in C#: sibling `7dtd-loadgen` (`PackageCodec`, `--golden-wire`).

## Build

Requires Linux and Zig **0.16.0+** (`build.zig.zon` `minimum_zig_version`). UDP
and TCP setup use Zig 0.16 `std.Io.net`; non-blocking TCP I/O and clocks use
thin POSIX calls contained in `src/util/` (see
[`docs/STD_ABSTRACTIONS.md`](docs/STD_ABSTRACTIONS.md)). Canonical validation
and release builds use the exact compiler in `.zigversion`; `make check`
enforces that pin and also requires Bash, `rg` (ripgrep), and ShellCheck.
`make release` additionally requires `sha256sum`.

One pinned dependency: the Wasm plugin runtime `zwasm` v2.5.0 (`build.zig.zon`,
URL + hash). `zig build` fetches it into Zig's global cache on first use, so a
clean checkout needs network for that one fetch; later builds are offline and
the hash pins the exact content. Override the compiler with
`ZIG=/path/to/zig` if needed. The optional `-Dtracy` profiling build links an
operator-supplied Tracy checkout (`-Dtracy-src=PATH`); it is opt-in, never
fetched, and outside `make check` ([`docs/APM.md`](docs/APM.md)).

```bash
cd zdtd-server
make                 # Debug binary → zig-out/bin/zdtd
make test
make check           # pin + lint + provenance/XML audits + build + test + fuzz (serial; safe under -j)
make release         # stripped linux-x86_64 ReleaseSafe binary + sha256 + licenses, examples, modes/
# or: zig build / zig build test (dev builds use the native host target)
```

## Layout

```text
src/main.zig           entry CLI (--port/--world/--ticks/--once)
src/protocol.zig       wire constants from RE
src/litenet/           UDP + Connect/Accept + reliable channel (game LiteNet)
src/wire/              channel envelope + package bodies
src/server/game.zig    Game state and delegating facade
src/server/game/       per-domain tick, join, world, player, and net helpers
src/server/c2s/        phase-gated client-package handlers by domain
src/ecs/               SoA ECS: components, systems, catalog/power/director resources
src/util/parallel.zig  multi-thread range split (AI, turrets, chunk save)
src/assets/            stock config loaders (quests.xml, …)
assets/fixtures/       offline XML fixtures for tests
src/world/             chunks, ZCH3 persistence, maps, prefabs, water, and worldgen
src/apm/               metrics + section profiler + report
src/version.zig        product/wire version pins (read by scripts/check-release.sh)
src/fuzz.zig           fuzz entry (`zig build fuzz`, part of `make check`)
scripts/               release check, wire lint, auto-join + Navezgane smoke
docs/STATUS.md         living hub
docs/INDEX.md          doc map
docs/                 gaps, plan, wire, scale, APM
build.zig
AGENTS.md
TODO.md
```

## Policy

- Do **not** ship TFP `Assembly-CSharp.dll`, bulk IL, or game assets.
- Validate with loadgen (`--golden-wire`, `--join`) and stock clients (EAC off).
- Stock dedi often binds 26902; pick a free port for local zdtd.

## Name

| Reading | Meaning |
|---|---|
| **zdtd** | Zig + 7DTD |
| **ZDTD** | Zeven Days to Die |
