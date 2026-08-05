# Changelog

Consumer-visible changes are recorded here. The project follows the release
and compatibility rules in [docs/RELEASES.md](docs/RELEASES.md).

## [Unreleased]

### Breaking changes

- The writable chunk format is now ZCH3. ZCH1 heights remain readable. ZCH2
  heights remain readable, but its type-only block edits are intentionally
  regenerated because ZCH2 cannot preserve rotation and metadata. Back up a
  world before upgrading.
- The supported stock client wire is pinned to V3.1.0 b14. Earlier stock clients
  can be rejected or fail to decode changed package layouts.

### Added

- Core stock-client play now covers join, terrain streaming, inventory, combat,
  death and respawn, loot, crafting, trading, and persistence with EAC off.
- `--version` reports the zdtd product version and the supported stock client
  wire version.
- Procedural worlds (`--worldgen-seed`) now generate terrain from a 3D density
  field instead of a heightmap, so cliffs and overhangs appear naturally.
  Chunks are still generated on demand at stream time from the seed and chunk
  coordinates alone, so the same seed always yields the same world and chunk
  borders never seam. Water, biomes, caves, and points of interest are not
  generated yet.
- Stock-like `serverconfig.xml`, config override directories, and procedural
  terrain seed options are available. Run `zdtd --help` for precedence.
- Operator tunables can be set in `zdtd.toml` (world directory or CWD; see
  `zdtd.toml.example`). Run `zdtd --help` for the full precedence order.
- An operator web UI is available via `--webui-port`, `--webui-bind`, and
  `--webui-secret` (or env `ZDTD_WEBUI_SECRET`). It is off by default, binds
  to loopback, and refuses to start without a secret. It exposes the same
  command surface as the `--admin-port` TCP console. See `docs/WEBUI.md`.
- Server-side guard policy for detector evidence. It is log-only by default: a
  tripped gate records `guard would kick` and a counter, and nothing is denied
  or dropped. Operators can opt in to per-surface quarantine (no damage, no
  container use, no block edits) and, separately, to kicking, via zdtd.toml
  `[authority] guard_*`. Both enforcement rungs also require authority mode
  `correct`. Weak signals can never trigger either rung. The admin `guardstats`
  command reports the policy state, and `guardclear <slot>` releases a peer.
  See `docs/AUTHORITY.md`.
- An experimental, statically linked native plugin host skeleton is included.
  The in-tree `sample_hello` plugin is enabled by default and can be disabled
  with the gamemode `enable_sample_plugin` setting. Out-of-tree packaging and
  a stable dynamic ABI are not supported yet. See `docs/PLUGIN_API.md`.
- An optional Tracy profiling build emits one zone per apm profiler section plus
  one frame mark per server tick. It is off by default with no overhead and no
  dependency; the Tracy client stays operator-supplied via
  `-Dtracy=true -Dtracy-src=PATH`. See `docs/APM.md`.

- Optional performance switches in `zdtd.toml` under a new `[perf]` section, all
  off by default: `async_chunk_flush` (chunk saves are written by a background
  thread instead of on the tick), `terrain_snapshot` (pathfinding reads a
  per-tick terrain snapshot instead of taking the world lock for every probe),
  and `job_batches` (the sleeper-volume proximity test runs in parallel; spawns
  still happen in the same order). Each switch ships with always-on metrics
  (`save_encode`, `save_flush_wait`, `terrain_snap`, `sleeper_scan`, `te_scan`
  sections and the matching counters) so operators can see whether it is worth
  turning on. See `zdtd.toml.example` and `docs/SCALE_ARCHITECTURE.md`.

### Fixed

- Package and entity layouts were updated for the V3.1.0 b14 client wire.
- Chunk persistence now retains full `BlockValue.rawData` in ZCH3.

No zdtd version has been tagged or published yet. These entries describe the
upcoming 0.1.0 development release.
