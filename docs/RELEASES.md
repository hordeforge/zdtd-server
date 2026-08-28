# Releases and compatibility

> **What this is:** the version and compatibility policy — what SemVer means here, what is covered by compat promises (stock client, Zig, config, saves, wire), and the gate for tagging a release.
> **Related:** [STATUS.md](STATUS.md) · [GAP_ANALYSIS.md](GAP_ANALYSIS.md) · [INDEX.md](INDEX.md) · [CHANGELOG.md](../CHANGELOG.md)

zdtd is pre-1.0 research software. There are currently no tagged or published
releases. `0.1.0` identifies the upcoming development release, not a stable API
commitment.

## Version policy

zdtd uses Semantic Versioning for the operator-facing server contract:

- During `0.x`, a minor bump may contain incompatible CLI, config, wire, save,
  or documented Zig API changes. Patch releases remain backward compatible and
  contain fixes only.
- From `1.0.0`, incompatible consumer-facing changes require a major bump.
- Additive features require a minor bump. Backward-compatible fixes require a
  patch bump.
- The Zig module facades under `src/*/root.zig` are development interfaces until
  1.0. Symbols described as proposed, experimental, or internal are not stable.
  The static plugin host skeleton is shipped but experimental (plugins are
  Wasm-only per [ADR 0020](adr/0020-wasm-only-plugin-api.md)). There is no
  supported out-of-tree plugin packaging or stable plugin ABI yet.

The product version and stock wire version are separate. `src/version.zig`
contains both. `build.zig.zon` repeats the product version because Zig package
metadata requires a literal; `make check` rejects drift between them.

## Compatibility contract

- **Stock client:** V3.2.0 b9, Mono, EAC off is the current target (the
  bundled AssignIds dump is still 3.1.0-era; the refresh is tracked in
  GAP_ANALYSIS §1a). The 3.2.0 login gate is live-verified via loadgen. Other
  V3.x builds are unsupported until they appear in the tested matrix.
  Package ids are negotiated, but that does not make changed package bodies
  compatible.
- **Zig:** the minimum supported compiler is the
  `build.zig.zon.minimum_zig_version` value. Raising it requires a minor bump
  before 1.0 and a major bump after 1.0. Canonical validation and release
  artifacts use the exact compiler in `.zigversion`; the release check rejects
  drift between that pin, the package minimum, and the active compiler.
- **Configuration:** existing flags and documented `serverconfig.xml` keys stay
  compatible within a minor line. A rename needs an alias and deprecation note
  for at least one minor release unless a security issue makes that unsafe.
- **Saved worlds:** a release must read the previous released format or provide
  an explicit migration. ZCH3 reads ZCH1 heights and ZCH2 heights. ZCH2 block
  edits are regenerated because the old format discarded required metadata.
  ZCH4 (added with `[wire] profile` dialects, ADR 0036) carries the column
  height in the header: a stock loader rejects it, and a mismatched non-stock
  loader fails closed. Downgrade compatibility is not promised. Back up
  worlds before upgrading.
- **Wire and saved data:** format changes are consumer-facing even when no Zig
  function signature changes. They must be listed under Breaking changes.

Only the newest development release is supported during 0.x. There is no
security backport branch or EOL schedule yet. Security fixes will be disclosed
in the changelog without exploit detail until operators have an upgrade.

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
6. Verify reproducibility: run `make repro` (or
   `bash scripts/repro-release.sh`), which builds the source twice in separate
   source and cache trees, then requires both scratch-build binaries to have
   matching sha256. Scratch trees are deleted on exit. Both halves go through
   `scripts/release-build.sh`, the same script `make release` uses, so the gate
   validates the exact configuration that ships: `-Doptimize=ReleaseSafe
   -Dstrip=true -Dtarget=x86_64-linux-gnu -Dcpu=baseline` under a normalized
   locale, timezone, and source epoch.
   The pinned `.zigversion` compiler, `-Dcpu=baseline`, and `strip` make the
   binary independent of build path, host CPU, and wall-clock time; a mismatch
   means a nondeterminism slipped in and must be fixed before tagging. CI runs
   this automatically on every tag build.
7. After releasing, bump `src/version.zig` and `build.zig.zon` on the development
   branch before landing any further change. The release check rejects a commit
   that reuses a product version already tagged on another commit.

The release check rejects malformed SemVer, mismatched or multiple version tags,
undated release notes, tagged builds made from a dirty worktree, and reuse of a
tagged product version by a different commit.
