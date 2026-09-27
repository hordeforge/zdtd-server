#!/usr/bin/env bash
# Prepare the webui TypeScript project used by scripts/build-webui-ts.sh and
# scripts/lint-webui.sh.
#
# The repo deliberately does not track package.json/node_modules (AGENTS rule
# 12), so the JS toolchain lives in a staged cache project that mirrors the
# committed layout:
#
#   $XDG_CACHE_HOME/zdtd/webui-ts/project/
#     package.json          {"type":"module","dependencies":{"preact":"<pin>","clsx":"<pin>","tailwind-merge":"<pin>","class-variance-authority":"<pin>","tailwindcss":"<pin>","@tailwindcss/cli":"<pin>"}}
#     tsconfig.json         copy of the committed one (files resolve beside it)
#     components.json       copy of the committed one (shadcn component discovery)
#     login.ts lockout.ts shell.tsx chart.ts
#     lib/ components/      the cn() helper and the shadcn primitives
#     webui.css             theme entry importing tailwindcss (copied from src)
#     node_modules/         pinned preact + tailwind (bun add; cached after first run)
#
# The copies exist so tsc, oxlint's type-aware pass (tsgolint) and `bun build`
# all resolve `preact` and `@/...` from one place without adding node_modules to
# the tree, so oxlint's unlisted-external-imports rule sees every dep declared,
# and so oxlint's shadcn component discovery finds components.json beside the
# sources it lints.
#
# Usage (sourced):  . scripts/webui-ts-project.sh; webui_ts_prepare
# Prints the project directory on stdout (nothing else).

set -euo pipefail

webui_ts_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
webui_ts_preact_version="${PREACT_VERSION:-10.29.8}"
webui_ts_tailwind_version="${TAILWIND_VERSION:-4.3.3}"
# shadcn's class contract: cn() is clsx + tailwind-merge and the variant maps
# come from class-variance-authority. Pinned here with the rest of the JS
# toolchain, since the repo tracks no package.json.
webui_ts_clsx_version="${CLSX_VERSION:-2.1.1}"
webui_ts_tailwind_merge_version="${TAILWIND_MERGE_VERSION:-3.4.1}"
webui_ts_cva_version="${CVA_VERSION:-0.7.1}"

webui_ts_prepare() {
  local root="$webui_ts_root"
  local src="$root/src/server/webui/ts"
  local project="${XDG_CACHE_HOME:-$HOME/.cache}/zdtd/webui-ts/project"
  local version="$webui_ts_preact_version"

  mkdir -p "$project"
  rm -f "${project:?}"/*.ts "${project:?}"/*.tsx "${project:?}"/*.css "${project:?}"/*.html "${project:?}"/*.json
  rm -rf "${project:?}/lib" "${project:?}/components"
  # Declare the pins in package.json: `bun add` is skipped when the install is
  # already satisfied, and the declaration is what oxlint reads.
  printf '{"type":"module","dependencies":{"preact":"%s","clsx":"%s","tailwind-merge":"%s","class-variance-authority":"%s","tailwindcss":"%s","@tailwindcss/cli":"%s"}}\n' \
    "$version" "$webui_ts_clsx_version" "$webui_ts_tailwind_merge_version" \
    "$webui_ts_cva_version" "$webui_ts_tailwind_version" "$webui_ts_tailwind_version" > "$project/package.json"
  cp "$src"/*.ts "$src"/*.tsx "$project/" 2>/dev/null || true
  cp -R "$src/lib" "$src/components" "$project/"
  cp "$src/tsconfig.json" "$project/tsconfig.json"
  # components.json is written, not copied: the committed one points tailwind.css
  # at src/server/webui/webui.css for the shadcn CLI in the repo root, and
  # @shadcn/lint resolves that path next to the file it is reading, which here
  # is the staged project. Same aliases, same stylesheet, project-relative.
  sed 's|"css": "src/server/webui/webui.css"|"css": "webui.css"|' "$root/components.json" > "$project/components.json"
  cp "$root/src/server/webui/webui.css" "$root/src/server/webui/webui-"*.css "$project/"
  # Stage the pages too: the Tailwind CLI scans every non-ignored file beside
  # the entry, so utilities written in the static shell/login markup are
  # generated even though the markup itself is authored in src/server/webui/.
  # Harmless to tsc (files list), oxlint (explicit .ts/.tsx args), bun build.
  #
  # The generated regions are blanked on the staged copies. The Tailwind
  # scanner reads class-shaped tokens anywhere in a file, so a compiled
  # `.transition-colors{...}` rule inside the page would re-generate its own
  # utility forever, keeping a rule alive after its source stopped using it.
  # See scripts/strip-generated-regions.py.
  for page in "$root/src/server/webui/"*.html; do
    [ -e "$page" ] || continue
    python3 "$root/scripts/strip-generated-regions.py" "$page" "$project/$(basename "$page")"
  done

  if ! ( cd "$project" && bun add --silent "preact@$version" "clsx@$webui_ts_clsx_version" \
      "tailwind-merge@$webui_ts_tailwind_merge_version" \
      "class-variance-authority@$webui_ts_cva_version" \
      "tailwindcss@$webui_ts_tailwind_version" "@tailwindcss/cli@$webui_ts_tailwind_version" ) >/dev/null 2>&1; then
    if [ ! -d "$project/node_modules/preact" ] || [ ! -d "$project/node_modules/tailwindcss" ] ||
       [ ! -d "$project/node_modules/clsx" ] || [ ! -d "$project/node_modules/tailwind-merge" ] ||
       [ ! -d "$project/node_modules/class-variance-authority" ]; then
      echo "zdtd: webui-ts: could not install preact@$version + clsx@$webui_ts_clsx_version + tailwind-merge@$webui_ts_tailwind_merge_version + class-variance-authority@$webui_ts_cva_version + tailwindcss@$webui_ts_tailwind_version into $project (offline and not cached?)" >&2
      exit 1
    fi
    echo "zdtd: webui-ts: registry unreachable; using the cached preact@$version + tailwindcss@$webui_ts_tailwind_version in $project" >&2
  fi

  printf '%s\n' "$project"
}
