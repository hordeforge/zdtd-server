#!/usr/bin/env bash
# Fail closed on version drift and missing toolchain before `zig build`.
# Invoked by `make release-check` / `make check`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ZIG="${ZIG:-zig}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "release-check: missing required tool: $1" >&2
    exit 127
  fi
}

need_cmd "$ZIG"
need_cmd sed
need_cmd grep
need_cmd head
need_cmd tr

manifest_version=$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)",/\1/p' build.zig.zon | head -n1)
source_version=$(sed -n 's/^pub const product = "\([^"]*\)";/\1/p' src/version.zig | head -n1)
min_zig=$(sed -n 's/^[[:space:]]*\.minimum_zig_version = "\([^"]*\)",/\1/p' build.zig.zon | head -n1)
toolchain_zig=$(tr -d '[:space:]' < .zigversion)
stock_wire=$(sed -n 's/^pub const stock_wire = "\([^"]*\)";/\1/p' src/version.zig | head -n1)

if [[ -z "$manifest_version" || -z "$source_version" ]]; then
  echo "release-check: could not read product version" >&2
  exit 1
fi

# Product versions are SemVer 2.0.0. Keep this stricter than Zig's package
# parser so malformed versions cannot reach tags, changelog headings, or
# operator-visible --version output.
semver_re='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+\.)*[0-9A-Za-z-]+)?(\+([0-9A-Za-z-]+\.)*[0-9A-Za-z-]+)?$'
if [[ ! "$source_version" =~ $semver_re ]]; then
  echo "release-check: src/version.zig product '$source_version' is not SemVer 2.0.0" >&2
  exit 1
fi
if [[ "$source_version" == *-* ]]; then
  prerelease="${source_version#*-}"
  prerelease="${prerelease%%+*}"
  IFS=. read -r -a prerelease_ids <<< "$prerelease"
  for prerelease_id in "${prerelease_ids[@]}"; do
    if [[ "$prerelease_id" =~ ^[0-9]+$ && "$prerelease_id" == 0[0-9]* ]]; then
      echo "release-check: numeric prerelease identifier '$prerelease_id' has a leading zero" >&2
      exit 1
    fi
  done
fi

if [[ "$manifest_version" != "$source_version" ]]; then
  echo "release-check: build.zig.zon ($manifest_version) != src/version.zig ($source_version)" >&2
  exit 1
fi

if [[ -z "$min_zig" ]]; then
  echo "release-check: could not read minimum_zig_version from build.zig.zon" >&2
  exit 1
fi

if [[ -z "$toolchain_zig" ]]; then
  echo "release-check: could not read pinned Zig version from .zigversion" >&2
  exit 1
fi

if [[ "$toolchain_zig" != "$min_zig" ]]; then
  echo "release-check: .zigversion ($toolchain_zig) != build.zig.zon minimum_zig_version ($min_zig)" >&2
  exit 1
fi

if [[ -z "$stock_wire" ]]; then
  echo "release-check: stock_wire missing in src/version.zig" >&2
  exit 1
fi

# Compare host Zig to minimum (numeric major.minor.patch only; ignore pre-release suffix).
host_zig="$("$ZIG" version 2>/dev/null || true)"
if [[ -z "$host_zig" ]]; then
  echo "release-check: '$ZIG version' produced no output" >&2
  exit 1
fi

# Strip anything after first non-semver char (e.g. 0.16.0-dev.123+hash -> 0.16.0).
host_base="${host_zig%%[^0-9.]*}"
min_base="${min_zig%%[^0-9.]*}"

version_ge() {
  # Return 0 if $1 >= $2 (dot-separated integers).
  local a="$1" b="$2"
  local IFS=.
  # shellcheck disable=SC2206
  local -a aa=($a) bb=($b)
  local i ai bi
  local n=${#aa[@]}
  if (( ${#bb[@]} > n )); then n=${#bb[@]}; fi
  for ((i = 0; i < n; i++)); do
    ai=${aa[i]:-0}
    bi=${bb[i]:-0}
    if ((10#$ai > 10#$bi)); then return 0; fi
    if ((10#$ai < 10#$bi)); then return 1; fi
  done
  return 0
}

if ! version_ge "$host_base" "$min_base"; then
  echo "release-check: Zig $host_zig is older than minimum $min_zig (from build.zig.zon)" >&2
  exit 1
fi

# Canonical validation and release artifacts use the exact CI compiler. Raw
# `zig build` remains available with any compiler satisfying the package minimum.
if [[ "$host_zig" != "$toolchain_zig" ]]; then
  echo "release-check: Zig $host_zig != pinned release toolchain $toolchain_zig (from .zigversion)" >&2
  exit 1
fi

if ! grep -Fqx '## [Unreleased]' CHANGELOG.md; then
  echo "release-check: CHANGELOG.md must contain an Unreleased section" >&2
  exit 1
fi

# Release gate (docs/RELEASES.md): a v* tag on HEAD must equal the product
# version, and the changelog must already contain that version's section.
# Explicit -l + pattern so we never enter create-tag mode on odd git versions.
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  # Prefer annotated/lightweight tags that point exactly at HEAD.
  mapfile -t head_tags < <(git tag -l 'v*' --points-at HEAD 2>/dev/null || true)
  if ((${#head_tags[@]} > 1)); then
    echo "release-check: multiple v* tags point at HEAD: ${head_tags[*]}" >&2
    exit 1
  fi
  if ((${#head_tags[@]} == 1)); then
    head_tag="${head_tags[0]}"
    if [[ "$head_tag" != "v$source_version" ]]; then
      echo "release-check: HEAD tag $head_tag != v$source_version (src/version.zig)" >&2
      exit 1
    fi
    if ! grep -Eq "^## \[$source_version\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" CHANGELOG.md; then
      echo "release-check: CHANGELOG.md missing dated '## [$source_version] - YYYY-MM-DD' section for tag $head_tag" >&2
      exit 1
    fi
    # A dirty tree can build bytes that never existed at the immutable tag
    # while still reporting the tag's product version.
    if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
      echo "release-check: tagged release $head_tag must be built from a clean worktree" >&2
      exit 1
    fi
  fi
fi

echo "release-check: ok product=$source_version stock_wire=$stock_wire zig=$host_zig (min $min_zig)"
