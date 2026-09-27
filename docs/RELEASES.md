# Releases and compatibility

> **What this is:** the version and compatibility policy - what SemVer means here, what is covered by compat promises (stock client, Zig, config, saves, wire), and the gate for tagging a release.
> **Related:** [STATUS.md](STATUS.md) · [GAP_ANALYSIS.md](GAP_ANALYSIS.md) · [INDEX.md](INDEX.md) · [CHANGELOG.md](../CHANGELOG.md)

zdtd is pre-1.0 research software. `0.8.0` (src/version.zig + build.zig.zon,
drift-checked by `make check`) is the development line and `v0.8.0` the latest
release. A minor bump may land any time, with no stable API commitment.
Product tags: `v0.1.0`, `v0.1.1`, `v0.3.0`, `v0.4.0`, `v0.5.0`, `v0.6.0`,
`v0.7.0`, `v0.8.0`.

Two tags predate this policy. `v0.1.1` and `v3.1.0` point at one commit whose
`src/version.zig` declares `0.2.0`, so read that commit as the 0.2.0 tree, not
as a patch over `v0.1.0`. `v3.1.0` names a stock wire version, not a product
release. `0.2.0` was never tagged, so its CHANGELOG entries shipped in `0.3.0`.

## Version policy

zdtd uses Semantic Versioning for the operator-facing server contract:

- During `0.x`, a minor bump may contain incompatible CLI, config, wire, save or
  documented Zig API changes; patch releases stay backward compatible and carry
  fixes only.
- From `1.0.0`, incompatible consumer-facing changes require a major bump.
- Additive features require a minor bump, fixes a patch bump.
- The Zig module facades under `src/*/root.zig` are development interfaces until
  1.0, and symbols described as proposed, experimental or internal are not
  stable. The plugin host is experimental (plugins are Wasm-only per
  [ADR 0020](adr/0020-wasm-only-plugin-api.md)); there is no supported
  out-of-tree plugin packaging or stable plugin ABI yet.

The product version and stock wire version are separate. `src/version.zig`
contains both. `build.zig.zon` repeats the product version because Zig package
metadata requires a literal; `make check` rejects drift between them.

## Compatibility contract

- **Stock client:** V3.2.0 b10, Mono, EAC off is the current target (the
  bundled AssignIds dump is still 3.1.0-era; the refresh is tracked in
  GAP_ANALYSIS §1a). The 3.2.0 login gate is live-verified via loadgen. Other
  V3.x builds are unsupported until they appear in the tested matrix.
  Package ids are negotiated, but that does not make changed package bodies
  compatible.
- **Zig:** the minimum supported compiler is
  `build.zig.zon.minimum_zig_version`; raising it requires a minor bump before
  1.0, a major bump after. Release artifacts use the exact compiler in
  `.zigversion`, and the release check rejects drift between that pin, the
  package minimum, and the active compiler.
- **Configuration:** existing flags and documented `serverconfig.xml` keys stay
  compatible within a minor line. A rename needs an alias and deprecation note
  for at least one minor release unless a security issue makes that unsafe.
- **Saved worlds:** a release must read the previous released format or ship an
  explicit migration. ZCH3 reads ZCH1 and ZCH2 heights; ZCH2 block edits
  regenerate because the old format discarded required metadata. Player (ZPV17,
  reads ZPV2+), entity (ZEN2, reads ZENT) and container (ZCT3, reads ZCT1+)
  records read older versions while writing the unified slot stride. ZCH4
  (withdrawn `[wire] profile` dialects, ADR 0036 amendment) carries the column
  height in its header: a stock loader rejects it and no shipped config writes
  it. Downgrade is not promised. Back up worlds before upgrading.
- **Wire and saved data:** format changes are consumer-facing even when no Zig
  function signature changes. They must be listed under Breaking changes.

Only the newest development release is supported during 0.x. There is no
security backport branch or EOL schedule yet. Security fixes are disclosed in
the changelog without exploit detail until operators have an upgrade.
Reporting posture: [../SECURITY.md](../SECURITY.md). Attack-surface map:
[THREAT_MODEL.md](THREAT_MODEL.md).

## Release gate

Before creating an immutable `vMAJOR.MINOR.PATCH` tag:

1. Classify user-visible changes in `CHANGELOG.md`, including defaults, errors,
   CLI/config changes, stock wire changes, and saved-data migrations.
2. Update `src/version.zig` and `build.zig.zon` together. The tag must equal
   those values with a `v` prefix.
3. Run `make check`, loadgen join smoke, and the stock-client playtest against
   the stock wire version named in `src/version.zig`.
4. Move Unreleased entries to a `## [MAJOR.MINOR.PATCH] - YYYY-MM-DD` section
   and restore an empty Unreleased section.
5. Build the release from the tag and smoke-test `zdtd --version` plus startup
   against a copy of a previous-version world. Never replace an existing tag or
   artifact; publish a new patch version for a bad release.
6. Verify reproducibility: run `make repro`, which builds the source twice in
   separate source and cache trees and requires both scratch-build binaries to
   have matching sha256. Both halves go through `scripts/release-build.sh`, the
   script `make release` uses, so the gate validates the exact configuration
   that ships: `-Doptimize=ReleaseSafe -Dstrip=true -Dtarget=x86_64-linux-gnu
   -Dcpu=baseline` under a normalized locale, timezone, and source epoch. The
   pinned `.zigversion` compiler, `-Dcpu=baseline`, `strip` and the differing
   `$HOME` make the binary independent of build path, host CPU, wall-clock time
   and host environment, so a captured environment fails the gate. A mismatch
   means nondeterminism slipped in and must be fixed before tagging. CI runs
   this on every tag build.
7. After releasing, bump `src/version.zig` and `build.zig.zon` on the development
   branch before landing any further change. The release check rejects a commit
   that reuses a product version already tagged on another commit.
8. Distribute: CI uploads the tagged build as a GitHub Actions artifact with
   90-day retention. No workflow creates a GitHub Release and no artifact
   registry is configured, so download the bundle and keep `zdtd`,
   `zdtd.sha256`, `buildinfo.txt` and `zdtd.cdx.json`; nothing recreates it
   after expiry.

The release check rejects malformed SemVer, mismatched or multiple version tags,
undated release notes, tagged builds made from a dirty worktree, and reuse of a
tagged product version by a different commit.
