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
- `--version` reports the zdtd product version.
- Stock-like `serverconfig.xml`, config override directories, and procedural
  terrain seed options are available. Run `zdtd --help` for precedence.

### Fixed

- Package and entity layouts were updated for the V3.1.0 b14 client wire.
- Chunk persistence now retains full `BlockValue.rawData` in ZCH3.

No zdtd version has been tagged or published yet. These entries describe the
upcoming 0.1.0 development release.

