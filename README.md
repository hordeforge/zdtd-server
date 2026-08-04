# zdtd

**Zig Days To Die** (or just **ZDTD**): a from-scratch dedicated server in Zig,
aimed at the stock 7 Days to Die **client wire** (EAC off).

```text
7 Days to Die  →  ZDTD  →  Zig Days To Die
     7DTD             ZDTD
```

Not a Harmony mod. Not RealEarth. Not EfficientServer. Not a drop-in host for
existing mods. Sibling of this workspace only for **RE docs** and **loadgen**
wire tests.

**Profiling:** built-in harness under `src/apm/` ([docs/APM.md](docs/APM.md)).  
That is **not** sibling `7dtd-apm` (stock Mono dedi).

## Status

**Client-wire dedi:** core stock loop playable (EAC off). Join, dig/build, fight,
death/respawn, loot, craft/workstation, trade, persist; automated playtest
**pass=83 fail=0** (20260804j; soft residuals in STATUS).
See [docs/STATUS.md](docs/STATUS.md).

| Doc | Role |
|---|---|
| [docs/STATUS.md](docs/STATUS.md) | What works now |
| [docs/INDEX.md](docs/INDEX.md) | Full doc map |
| [docs/RELEASES.md](docs/RELEASES.md) | Version, compatibility, support, and release policy |
| [CHANGELOG.md](CHANGELOG.md) | Consumer-visible changes and migrations |
| [TODO.md](TODO.md) | Open backlog |
| [docs/MISSING_FEATURES.md](docs/MISSING_FEATURES.md) | Gap inventory |
| [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) | M7–M16 (post-playable) |

```bash
# Flat default world (builtin quest catalog)
zig-out/bin/zdtd --port 27002 --world worlds/zdtd_default

# Stock Navezgane / Pregen (dtm + prefabs + water + Data/Config/quests.xml)
GAME="$HOME/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server"
zig-out/bin/zdtd --port 27002 --game-dir "$GAME" --world-name Navezgane --world worlds/nav_save
# or: --map "$GAME/Data/Worlds/Pregen06k01"
# or: --quests assets/fixtures/quests.xml
# names: Navezgane, Pregen06k01, Pregen06k02, Pregen08k01, Pregen08k02

# Operator web UI (WU0; loopback + secret; docs/WEBUI.md):
#   zdtd --port 27002 --world worlds/zdtd_default \
#     --webui-port 8080 --webui-secret change-me
#   curl -H 'Authorization: Bearer change-me' http://127.0.0.1:8080/

# loadgen joins LiteNet (ServerPort+2), not the TCP info port:
#   7dtd-loadgen --join --host 127.0.0.1 --port 27004 --count 2 --actions 20
```


**Stock maps:** `--map` points at a game world folder (`map_info.xml`, `dtm.raw` /
`dtm_processed.raw`, optional `spawnpoints.xml`). Heights are u16 LE `gameY*256`,
world origin at map center (`wx + W/2`). `--world` remains the writable zdtd save
overlay; `.zch` files use the ZCH3 format for heights and full u32 block data.

Milestones / architecture: [`docs/zig-clone.md`](docs/zig-clone.md).

## Non-goals

| Not supported | Why |
|---|---|
| **Mods** (Harmony, ModAPI, XML-only mods, EfficientServer, RealEarth) | Clean-room Zig process; no managed game assembly |
| **7dtd-apm as a dependency** | Different process; use **zdtd `src/apm/`** instead |
| **EAC-on clients** | Custom server path |

Validation is **loadgen bots** + stock clients + **zdtd apm** dumps.

## Docs (read these first)

| Doc | Role |
|---|---|
| [`docs/STATUS.md`](docs/STATUS.md) | What works now (wins on conflict) |
| [`docs/INDEX.md`](docs/INDEX.md) | Full doc map |
| [`TODO.md`](TODO.md) | Open backlog |
| [`docs/MISSING_FEATURES.md`](docs/MISSING_FEATURES.md) | Gap inventory vs stock |
| [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) | M7–M16 post-playable stack |
| [`docs/ECS.md`](docs/ECS.md) / [`docs/zig-clone.md`](docs/zig-clone.md) | Sim + architecture |
| [`../7dtd-research/docs/protocol.md`](../7dtd-research/docs/protocol.md) | Envelope, join, goldens |

Golden wire in C#: sibling `7dtd-loadgen` (`PackageCodec`, `--golden-wire`).

## Build

Requires Linux and Zig **0.16.0+** (`build.zig.zon` `minimum_zig_version`). The
server's UDP, admin, WebUI, and clock paths currently use Linux APIs. Canonical
validation and release builds use the exact compiler in `.zigversion`; `make check`
enforces that pin and also requires Bash and `rg` (ripgrep). `make release`
additionally requires `sha256sum`.

No network fetch: the package has no Zig dependencies. Override the compiler with
`ZIG=/path/to/zig` if needed.

```bash
cd zdtd
make                 # Debug binary → zig-out/bin/zdtd
make test
make check           # pin + lint + build + test + fuzz (serial; safe under -j)
make release         # ReleaseSafe + strip + zig-out/bin/zdtd.sha256
# or: zig build / zig build test / zig build -Doptimize=ReleaseSafe -Dstrip=true
```

## Layout

```text
src/main.zig           entry CLI (--port/--world/--ticks/--once)
src/protocol.zig       wire constants from RE
src/litenet/           UDP + Connect/Accept + reliable channel (game LiteNet)
src/wire/              channel envelope + package bodies
src/server/game.zig    join SM, tick, interest, combat, save
src/ecs/               SoA ECS: components, systems, catalog/power/director resources
src/util/parallel.zig  multi-thread range split (AI, turrets, chunk save)
src/assets/            stock config loaders (quests.xml, …)
assets/fixtures/       offline XML fixtures for tests
src/world/store.zig    16×256×16 chunks + ZCH3 persistence in .zch files
src/world/dtm.zig      stock Navezgane/Pregen dtm.raw + map_info + spawns
src/world/prefabs.zig  prefab footprints
src/world/water.zig    water_info sources
src/apm/               metrics + section profiler + report
src/version.zig        product/wire version pins (read by scripts/check-release.sh)
src/fuzz.zig           fuzz entry (`zig build fuzz`, part of `make check`)
scripts/               release check, wire lint, auto-join helpers
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
| **ZDTD** | Zig Days To Die |
