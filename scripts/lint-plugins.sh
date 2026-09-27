#!/usr/bin/env bash
# Freshness gate for the committed plugin .wasm binaries (make lint).
#
# Core plugins are Zig (AGENTS rule 31) and the addons/fixtures are Zig or C;
# in every case the committed .wasm is a build output of a source in the repo,
# and mods/BUILDING.md tells contributors to rebuild and commit both. That was
# a convention with no enforcement: a source edit that changes behavior without
# tripping one of the wasm host tests would ship a stale binary silently.
#
# This rebuilds every artifact into a scratch mirror and compares it to what is
# committed, in both directions: the mirror catches a stale or uncommitted
# artifact, and the committed set catches a .wasm whose source was deleted or
# renamed, which produces no build output and would otherwise pass unnoticed.
# Same pattern as the webui page-freshness check in lint-webui.sh and the
# docs/provenance.html staleness check in the Makefile.
#
# The toolchain is deterministic (Zig pinned by .zigversion, and the C
# artifacts pinned to clang's major by CLANG_MAJOR in build-plugins.sh), so a
# byte compare is the right check: same source in, same bytes out. On a host
# without that clang major the C artifacts are skipped rather than compared
# against a different compiler's output, which would report staleness no source
# change caused. A deliberate toolchain bump means CLANG_MAJOR=<major>, rebuild,
# wasm host tests, and commit the new .wasm bytes with the bump.
#
# Requires: the pinned Zig. The pinned clang major is optional (the C fixtures
# and addons are skipped without it, exactly as scripts/build-plugins.sh skips
# them); the message says so on stderr.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# Scratch lives under zig-out (gitignored, disk-backed) rather than $TMPDIR:
# /tmp is RAM-backed here and these are real build outputs.
mkdir -p zig-out
mirror="$(mktemp -d "$root/zig-out/zdtd-plugins.XXXXXXXX")"
trap 'rm -rf "$mirror"' EXIT

bash "$root/scripts/build-plugins.sh" --dest "$mirror" >/dev/null

stale=0
missing=0
while read -r built; do
  rel="${built#"$mirror"/}"
  if [ ! -f "$root/$rel" ]; then
    echo "zdtd: lint-plugins: $rel is built but not committed" >&2
    missing=1
    continue
  fi
  if ! cmp -s "$built" "$root/$rel"; then
    echo "zdtd: lint-plugins: $rel is stale (its source changed without a rebuild)" >&2
    stale=1
  fi
done < <(find "$mirror" -name '*.wasm' | LC_ALL=C sort)

# Walk the committed set too, not just the mirror: a .wasm whose source was
# deleted or renamed produces no build output, so the mirror-only loop above
# would report green with the orphan still shipped. A C artifact is exempt from
# the hard failure when the pinned clang major is absent (build-plugins.sh skips
# it by design); it is listed as unverified instead, so the green line below can
# no longer claim coverage it does not have.
unverified=0
while read -r rel; do
  [ -f "$mirror/$rel" ] && continue
  if [ -f "$root/${rel%.wasm}.c" ]; then
    echo "zdtd: lint-plugins: $rel unverified (pinned clang absent; see build-plugins.sh)" >&2
    unverified=$((unverified + 1))
    continue
  fi
  echo "zdtd: lint-plugins: $rel is committed but was not rebuilt (its source is missing or renamed)" >&2
  missing=1
done < <(git -C "$root" ls-files -z 'plugins/*.wasm' 'mods/*.wasm' 'assets/fixtures/*.wasm' | tr '\0' '\n')

if [ "$stale" -ne 0 ] || [ "$missing" -ne 0 ]; then
  echo "zdtd: lint-plugins: run 'make plugins' and commit the rebuilt .wasm" >&2
  exit 1
fi

if [ "$unverified" -ne 0 ]; then
  echo "zdtd: lint-plugins: $unverified committed .wasm binaries unverified (no pinned clang); the rest match their sources"
else
  echo "zdtd: lint-plugins: committed .wasm binaries match their sources"
fi
