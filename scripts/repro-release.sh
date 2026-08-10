#!/usr/bin/env bash
# Reproducibility gate: build the release configuration from two independent
# source and project-cache trees and require byte-identical binaries.
# Automates docs/RELEASES.md step 6 (previously a manual release-gate step).
# Invoked by `make repro` (release-check enforces the pinned toolchain first).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ZIG="${ZIG:-zig}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "repro-release: missing required tool: $1" >&2
    exit 127
  fi
}

need_cmd "$ZIG"
need_cmd sha256sum
need_cmd rm
need_cmd mkdir
need_cmd cmp
need_cmd mktemp
need_cmd tar

# Separate source paths catch absolute-path leakage that two output prefixes
# below one checkout cannot detect. Exclude build products and VCS metadata so
# ambient incremental state cannot contaminate either input tree.
# The global cache (~/.cache/zig) is intentionally shared: it holds only
# immutable, content-addressed fetched packages (e.g. the pinned zwasm tarball),
# so sharing it does not weaken the test.
# Scratch lives under zig-out (gitignored, disk-backed) rather than $TMPDIR:
# /tmp is tmpfs on many hosts, and two ReleaseSafe trees plus their project
# caches are gigabytes that must not land in RAM. The two paths still differ in
# length, which is what makes absolute-path leakage detectable.
mkdir -p "$ROOT/zig-out"
scratch="$(mktemp -d "$ROOT/zig-out/zdtd-repro.XXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT
A="$scratch/a"
B="$scratch/longer-build-path-b"
mkdir -p "$A/src" "$B/src"
for tree in "$A/src" "$B/src"; do
  tar -cf - build.zig build.zig.zon .zigversion src assets | tar -xf - -C "$tree"
done

# Both halves go through the same script `make release` uses, so this gate
# cannot pass on a configuration (flags, locale, timezone, source epoch) that
# differs from the one the shipped artifact is built with. RELEASE_TARGET is
# inherited from the caller's environment; the script owns the default.
build_release() {
  local tree="$1"
  (
    cd "$tree/src"
    ZIG="$ZIG" bash "$ROOT/scripts/release-build.sh" \
      --cache-dir "$tree/cache" \
      --prefix "$tree/install"
  )
}

build_release "$A"
build_release "$B"

ba="$A/install/bin/zdtd"
bb="$B/install/bin/zdtd"
test -f "$ba" || { echo "repro-release: $ba missing after build" >&2; exit 1; }
test -f "$bb" || { echo "repro-release: $bb missing after build" >&2; exit 1; }

if cmp -s "$ba" "$bb"; then
  echo "repro-release: ok binary_sha256=$(sha256sum "$ba" | cut -d' ' -f1)"
else
  echo "repro-release: FAILED: two clean builds produced different bytes" >&2
  echo "  sha256 $ba = $(sha256sum "$ba" | cut -d' ' -f1)" >&2
  echo "  sha256 $bb = $(sha256sum "$bb" | cut -d' ' -f1)" >&2
  echo "  a nondeterminism slipped in; fix before tagging (docs/RELEASES.md step 6)" >&2
  exit 1
fi
