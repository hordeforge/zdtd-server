#!/usr/bin/env bash
# Run the release `zig build` in the current directory with the exact
# configuration that defines the shipped artifact. Extra arguments (e.g.
# --cache-dir / --prefix) are appended.
#
# Single source of truth for the release build: `make release` produces the
# operator binary with this script and scripts/repro-release.sh rebuilds with
# it, so the reproducibility gate can never validate a configuration that
# differs from the one that actually ships.
#
# Deliberately does NOT cd to the repository root: repro-release.sh invokes it
# from scratch source trees outside the checkout.
#
# LC_ALL/TZ/SOURCE_DATE_EPOCH pin locale, timezone and source epoch so the build
# host's environment cannot leak sort order, formatted dates or wall-clock time
# into the artifact (reproducible-builds.org practice).
# -Dcpu=baseline: without it Zig targets the build host's CPU features, so the
# artifact's bytes vary per build machine and can SIGILL on older operator CPUs.
set -euo pipefail

ZIG="${ZIG:-zig}"
# The published artifact is named linux-x86_64 in CI, so do not let the machine
# running the build silently choose a different target ABI.
RELEASE_TARGET="${RELEASE_TARGET:-x86_64-linux-gnu}"

exec env LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=0 "$ZIG" build \
  -Doptimize=ReleaseSafe \
  -Dstrip=true \
  -Dtarget="$RELEASE_TARGET" \
  -Dcpu=baseline \
  "$@"
