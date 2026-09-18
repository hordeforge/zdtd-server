#!/usr/bin/env bash
# Prepare the webui TypeScript project used by scripts/build-webui-ts.sh and
# scripts/lint-webui.sh.
#
# The repo deliberately does not track package.json/node_modules (AGENTS rule
# 12), so the JS toolchain lives in a staged cache project that mirrors the
# committed layout:
#
#   $XDG_CACHE_HOME/zdtd/webui-ts/project/
#     package.json          {"type":"module","dependencies":{"preact":"<pin>"}}
#     tsconfig.json         copy of the committed one (files resolve beside it)
#     login.ts lockout.ts shell.tsx chart.ts
#     node_modules/         pinned preact (bun add; cached after the first run)
#
# The copies exist so tsc, oxlint's type-aware pass (tsgolint) and `bun build`
# all resolve `preact` from one place without adding node_modules to the tree,
# and so oxlint's unlisted-external-imports rule sees preact declared.
#
# Usage (sourced):  . scripts/webui-ts-project.sh; webui_ts_prepare
# Prints the project directory on stdout (nothing else).

set -euo pipefail

webui_ts_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
webui_ts_preact_version="${PREACT_VERSION:-10.29.8}"

webui_ts_prepare() {
  local root="$webui_ts_root"
  local src="$root/src/server/webui/ts"
  local project="${XDG_CACHE_HOME:-$HOME/.cache}/zdtd/webui-ts/project"
  local version="$webui_ts_preact_version"

  mkdir -p "$project"
  # Declare the pin in package.json: `bun add` is skipped when the install is
  # already satisfied, and the declaration is what oxlint reads.
  printf '{"type":"module","dependencies":{"preact":"%s"}}\n' "$version" > "$project/package.json"
  rm -f "$project"/*.ts "$project"/*.tsx
  cp "$src"/*.ts "$src"/*.tsx "$project/" 2>/dev/null || true
  cp "$src/tsconfig.json" "$project/tsconfig.json"

  if ! ( cd "$project" && bun add --silent "preact@$version" ) >/dev/null 2>&1; then
    if [ ! -d "$project/node_modules/preact" ]; then
      echo "zdtd: webui-ts: could not install preact@$version into $project (offline and not cached?)" >&2
      exit 1
    fi
    echo "zdtd: webui-ts: registry unreachable; using the cached preact@$version in $project" >&2
  fi

  printf '%s\n' "$project"
}
