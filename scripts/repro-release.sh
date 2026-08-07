#!/usr/bin/env bash
# Reproducibility gate: build the release configuration twice in independent
# project-cache trees and require the resulting binaries to match byte-for-byte.
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

# Two scratch trees under zig-out (gitignored): each build gets its own project
# cache and install prefix so the second build cannot reuse the first's outputs.
# The global cache (~/.cache/zig) is intentionally shared: it holds only
# immutable, content-addressed fetched packages (e.g. the pinned zwasm tarball),
# so sharing it does not weaken the test.
A=zig-out/repro-a
B=zig-out/repro-b
rm -rf "$A" "$B"
mkdir -p "$A" "$B"
trap 'rm -rf "$A" "$B"' EXIT

build_release() {
  "$ZIG" build \
    -Doptimize=ReleaseSafe -Dstrip=true -Dcpu=baseline \
    --cache-dir "$1/cache" \
    --prefix-exe-dir "$1/out"
}

build_release "$A"
build_release "$B"

ba="$A/out/zdtd"
bb="$B/out/zdtd"
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
