# Parity tooling: keep zdtd in sync with stock 7DTD

> Purpose: how `7dtd-engine-research` parity snapshots and `parity_diff.py` keep the 190-package catalog, enums, and C2S coverage honest across game updates.

Related: [wire/PACKAGES.md](wire/PACKAGES.md) · [wire/WIRE_CHUNK.md](wire/WIRE_CHUNK.md) · [AUTHORITY.md](AUTHORITY.md) · `assets/fixtures/parity_v3x.json` · `../../7dtd-engine-research/tools/parity/` · [INDEX.md](INDEX.md)

Scripts live in the reversing project: `../../7dtd-engine-research/tools/parity/`
(reversing tooling does not live in zdtd; see AGENTS.md principle 4).

When The Fun Pimps ship a new dedicated-server build, the wire can change.
These tools surface *exactly what changed* and *what zdtd doesn't handle yet*,
so updating is mechanical instead of a re-RE from scratch.

## What it captures

`../../7dtd-engine-research/tools/parity/ParitySurface.cs` extracts a stable JSON snapshot from any
`Assembly-CSharp.dll`:

- Every `NetPackage*` with its `read`/`write` **wire call sequence** (the
  actual BinaryReader/Writer + nested `.Read`/`.Write` order = the byte
  layout) and its `PackageDirection`.
- Selected enums our wire depends on (`EnumRemoveEntityReason`,
  `TileEntityType`, `EnumGameStats`, `RespawnType`, etc.).

A wire change to any package shows up as a changed call sequence.

## Commands

```bash
# 1) snapshot the DLL you have installed
mono ParitySurface.exe \
  ".../7DaysToDieServer_Data/Managed/Assembly-CSharp.dll" > parity_new.json

# 2a) diff two versions → what TFP changed
python3 ../7dtd-engine-research/tools/parity/parity_diff.py parity_old.json parity_new.json
#   → added / removed packages, changed wire (old vs new call seq), enum drift
#   exit code 1 if anything changed (CI-friendly)

# 2b) coverage -> what zdtd handles vs stock
# NOTE (2026-08-29): the --coverage mode does NOT exist in the current
# parity_diff.py (it diffs two snapshots only). The last coverage numbers in
# wire/PACKAGES.md ("86 live dispatch arms", "80 live S2C names") were a
# manual count on 2026-08-29; reimplement the mode here before regenerating.
# python3 ../7dtd-engine-research/tools/parity/parity_diff.py --coverage parity_new.json <zdtd_repo>
#   -> stock package count, handled-in-game.zig count,
#     UNHANDLED client->server (dir=1) list with read layouts
```

## Fetch old versions to validate (steamcmd)

`../7dtd-engine-research/tools/parity/fetch_version.sh <branch|manifestid> [label]` downloads a
specific dedicated-server build (app 294420, depot 294422) via steamcmd
(installed under scratch, never the host) and writes its parity snapshot:

```bash
../7dtd-engine-research/tools/parity/fetch_version.sh public        stable
../7dtd-engine-research/tools/parity/fetch_version.sh latest_experimental exp
../7dtd-engine-research/tools/parity/fetch_version.sh 1234567890123 v3.0   # pinned depot manifest
# then diff:
python3 ../7dtd-engine-research/tools/parity/parity_diff.py parity_v3.0.json parity_stable.json
```

Anonymous login works for the dedicated server. Pinned manifest ids come from
SteamDB depot history; use them to reproduce a build zdtd was RE'd against.

## Baseline snapshot

`assets/fixtures/parity_v3x.json` is the committed snapshot of the version
zdtd currently targets (190 packages). Regenerate + diff against it after any
game update to get the change list.

## Validated

The diff correctly detected real changes on the A20.3b3 → A20.4b42 pair
already in-repo: `NetPackageVoiceChat` removed; `NetPackagePartyActions` and
`NetPackagePartyData` each gained a `String` field. That is precisely the
"go update these N packages" signal the workflow exists to produce.

## Workflow when the game updates

1. `fetch_version.sh public stable` (or snapshot the new install).
2. `parity_diff.py assets/fixtures/parity_v3x.json <scratch>/parity_stable.json`
   → the change list.
3. For each changed/added package: RE the new `read`/`write` (the call seq
   points at the exact fields), update `wire/*.zig`, add/adjust a golden test.
4. `parity_diff.py --coverage` to confirm no new unhandled dir=1 package.
5. Refresh `assets/fixtures/parity_v3x.json` to the new baseline.
6. `make -C ../7dtd-playtest playtest-core` for the live in-client gate
   (or `PLAYTEST_SUITE=smoke,core` with connect's pair launch).
