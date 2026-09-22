#!/usr/bin/env bash
# Prepare the webui TypeScript project used by scripts/build-webui-ts.sh and
# scripts/lint-webui.sh.
#
# The repo deliberately does not track package.json/node_modules (AGENTS rule
# 12), so the JS toolchain lives in a staged cache project that mirrors the
# committed layout:
#
#   $XDG_CACHE_HOME/zdtd/webui-ts/project/
#     package.json          {"type":"module","dependencies":{"preact":"<pin>","tailwindcss":"<pin>","@tailwindcss/cli":"<pin>"}}
#     tsconfig.json         copy of the committed one (files resolve beside it)
#     login.ts lockout.ts shell.tsx chart.ts
#     webui.css             theme entry importing tailwindcss (copied from src)
#     node_modules/         pinned preact + tailwind (bun add; cached after first run)
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
webui_ts_tailwind_version="${TAILWIND_VERSION:-4.3.3}"

webui_ts_prepare() {
  local root="$webui_ts_root"
  local src="$root/src/server/webui/ts"
  local project="${XDG_CACHE_HOME:-$HOME/.cache}/zdtd/webui-ts/project"
  local version="$webui_ts_preact_version"

  mkdir -p "$project"
  # Declare the pin in package.json: `bun add` is skipped when the install is
  # already satisfied, and the declaration is what oxlint reads.
  printf '{"type":"module","dependencies":{"preact":"%s","tailwindcss":"%s","@tailwindcss/cli":"%s"}}\n' "$version" "$webui_ts_tailwind_version" "$webui_ts_tailwind_version" > "$project/package.json"
  rm -f "$project"/*.ts "$project"/*.tsx "$project"/*.css "$project"/*.html
  cp "$src"/*.ts "$src"/*.tsx "$project/" 2>/dev/null || true
  cp "$src/tsconfig.json" "$project/tsconfig.json"
  cp "$root/src/server/webui/webui.css" "$root/src/server/webui/webui-"*.css "$project/"
  # Stage the pages too: the Tailwind CLI scans every non-ignored file beside
  # the entry, so utilities written in the static shell/login markup are
  # generated even though the markup itself is authored in src/server/webui/.
  # Harmless to tsc (files list), oxlint (explicit .ts/.tsx args), bun build.
  cp "$root/src/server/webui/"*.html "$project/" 2>/dev/null || true

  if ! ( cd "$project" && bun add --silent "preact@$version" "tailwindcss@$webui_ts_tailwind_version" "@tailwindcss/cli@$webui_ts_tailwind_version" ) >/dev/null 2>&1; then
    if [ ! -d "$project/node_modules/preact" ] || [ ! -d "$project/node_modules/tailwindcss" ]; then
      echo "zdtd: webui-ts: could not install preact@$version + tailwindcss@$webui_ts_tailwind_version into $project (offline and not cached?)" >&2
      exit 1
    fi
    echo "zdtd: webui-ts: registry unreachable; using the cached preact@$version + tailwindcss@$webui_ts_tailwind_version in $project" >&2
  fi

  printf '%s\n' "$project"
}
