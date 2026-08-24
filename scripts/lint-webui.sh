#!/usr/bin/env bash
# Lint the webui TypeScript sources and the pages compiled from them (make lint).
#
# The webui markup is @embedFile'd HTML (AGENTS rule 12); the JS is authored as
# TypeScript in src/server/webui/ts and compiled into the committed pages by
# scripts/build-webui-ts.sh. This gate:
#   1. tsc --noEmit: the type gate (tsc --strict, pinned TSC_VERSION).
#   2. oxlint over the .ts sources with the anti-slop + strict rule set in
#      .oxlintrc.jsonc (warnings fail via --deny-warnings). The config enables
#      options.typeAware, so oxlint also runs the typescript/* type-aware rules
#      through the oxlint-tsgolint binary.
#   3. Freshness: the committed pages must equal a fresh regeneration, so a
#      .ts edit that was not compiled and committed fails the gate.
#
# tsc/oxlint run through npx pinned by TSC_VERSION/OXLINT_VERSION/
# OXLINT_TSGOLINT_VERSION. The repo deliberately does not track
# package.json/node_modules (.gitignore: "opencode tooling only"), so the
# versions live here as the single source of truth.
# Override locally: TSC_VERSION=5.9.3 OXLINT_VERSION=1.79.0 \
#   OXLINT_TSGOLINT_VERSION=7.0.2001 bash scripts/lint-webui.sh
#
# Requires: node/npm (npx), python3 (already a make check requirement).

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
oxlint_version="${OXLINT_VERSION:-1.79.0}"
oxlint_standards_version="${OXLINT_STANDARDS_VERSION:-0.8.1}"
oxlint_tsgolint_version="${OXLINT_TSGOLINT_VERSION:-7.0.2001}"
oxlint_plugins_version="${OXLINT_PLUGINS_VERSION:-1.79.0}"
anti_slop_sha="${ANTI_SLOP_SHA:-6d538555cb151d4121ed51a27db81890eacf8ae9}"
tsc_version="${TSC_VERSION:-5.9.3}"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zdtd/oxlint-standards"
ts_dir="$root/src/server/webui/ts"

# 1. Type check (tsc --strict per tsconfig.json).
npx --yes -p "typescript@$tsc_version" tsc -p "$ts_dir/tsconfig.json" --noEmit

# 2. Lint the sources with oxlint. The @rikalabs plugin, the vendored
#    dmmulroy/anti-slop plugin source (pinned by ANTI_SLOP_SHA; the project is
#    vendored source, not an npm package), and oxlint-tsgolint (the type-aware
#    backend) are fetched into the cache (no-op when the pinned versions are
#    already present) and oxlint runs next to them because jsPlugins resolve
#    relative to the config file's directory; a copy of the config is placed
#    there each run. All npm packages are installed in one invocation: a later
#    separate --no-save install would prune the others. @oxlint/plugins is the
#    plugin API the anti-slop source imports; without it the plugin cannot load.
mkdir -p "$cache_dir"
if [ ! -d "$cache_dir/anti-slop-src" ]; then
  curl -fsSL "https://github.com/dmmulroy/anti-slop/archive/$anti_slop_sha.tar.gz" -o "$cache_dir/anti-slop.tar.gz"
  mkdir -p "$cache_dir/anti-slop-src"
  tar xzf "$cache_dir/anti-slop.tar.gz" -C "$cache_dir/anti-slop-src" --strip-components=2 "anti-slop-$anti_slop_sha/src"
fi
npm install --prefix "$cache_dir" --no-audit --no-fund --no-save --no-package-lock \
  "@rikalabs/oxlint-standards@$oxlint_standards_version" \
  "oxlint-tsgolint@$oxlint_tsgolint_version" \
  "@oxlint/plugins@$oxlint_plugins_version" >/dev/null 2>&1 || {
  echo "zdtd: lint-webui: could not install @rikalabs/oxlint-standards@$oxlint_standards_version + oxlint-tsgolint@$oxlint_tsgolint_version + @oxlint/plugins@$oxlint_plugins_version into $cache_dir (offline?)" >&2
  exit 1
}
cp "$root/.oxlintrc.jsonc" "$cache_dir/oxlintrc.jsonc"
cd "$cache_dir"
# tsgolint is not on the user's PATH; oxlint finds it via PATH lookup.
PATH="$cache_dir/node_modules/.bin:$PATH" \
  npx --yes "oxlint@$oxlint_version" --config oxlintrc.jsonc --deny-warnings "$ts_dir"

# 3. Freshness: regenerate into a temp copy of the pages and diff.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -r "$root/src/server/webui" "$tmp/pages"
bash "$root/scripts/build-webui-ts.sh" --dest "$tmp/pages" >/dev/null
if ! diff -rq "$root/src/server/webui" "$tmp/pages" >/dev/null; then
  echo "zdtd: lint-webui: committed webui pages are stale (a .ts source changed without regeneration). Run: make webui-ts" >&2
  exit 1
fi
echo "zdtd: lint-webui: tsc type-check, oxlint, and page freshness ok"
