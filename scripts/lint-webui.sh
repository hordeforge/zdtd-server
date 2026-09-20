#!/usr/bin/env bash
# Lint the webui TypeScript sources and the pages compiled from them (make lint).
#
# The webui markup is @embedFile'd HTML (AGENTS rule 12); the dashboards's JS is
# authored as TypeScript/JSX in src/server/webui/ts and bundled into the
# committed pages by scripts/build-webui-ts.sh (preact, ADR 0040). This gate:
#   1. tsc --noEmit in the staged cache project (scripts/webui-ts-project.sh),
#      where `preact` resolves: the type gate (tsc --strict, pinned TSC_VERSION).
#   2. oxlint over the .ts sources with the anti-slop + strict rule set in
#      .oxlintrc.jsonc (warnings fail via --deny-warnings). The config enables
#      options.typeAware, so oxlint also runs the typescript/* type-aware rules
#      through the oxlint-tsgolint binary.
#   3. Freshness: the committed pages must equal a fresh regeneration, so a
#      .ts edit that was not compiled and committed fails the gate.
#
# tsc/oxlint run through bunx pinned by TSC_VERSION/OXLINT_VERSION/
# OXLINT_TSGOLINT_VERSION. The repo deliberately does not track
# package.json/node_modules (.gitignore: "opencode tooling only"), so the
# versions live here as the single source of truth.
# Override locally: TSC_VERSION=5.9.3 OXLINT_VERSION=1.79.0 \
#   OXLINT_TSGOLINT_VERSION=7.0.2001 ANTI_SLOP_SHA=... ANTI_SLOP_SHA256=... \
#   bash scripts/lint-webui.sh
#
# Requires: bun (bunx), python3, sha256sum (already a make check requirement).

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v sha256sum >/dev/null 2>&1; then
  echo "zdtd: lint-webui: missing required tool: sha256sum (GNU coreutils)" >&2
  exit 127
fi
oxlint_version="${OXLINT_VERSION:-1.79.0}"
oxlint_standards_version="${OXLINT_STANDARDS_VERSION:-0.8.1}"
oxlint_tsgolint_version="${OXLINT_TSGOLINT_VERSION:-7.0.2001}"
oxlint_plugins_version="${OXLINT_PLUGINS_VERSION:-1.79.0}"
anti_slop_sha="${ANTI_SLOP_SHA:-6d538555cb151d4121ed51a27db81890eacf8ae9}"
# Content hash of the GitHub archive for ANTI_SLOP_SHA (commit pin alone is not
# enough: GitHub can regenerate archive bytes for the same commit). Override
# only together with ANTI_SLOP_SHA when deliberately bumping the plugin.
anti_slop_sha256="${ANTI_SLOP_SHA256:-a720663fd2562e22e3da670769faa88dc34c9a761fdd9a7d285e20d92871848e}"
tsc_version="${TSC_VERSION:-5.9.3}"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zdtd/oxlint-standards"

# 1. Type check (tsc --strict per tsconfig.json) in the staged cache project,
#    where `preact` resolves (ADR 0040; scripts/webui-ts-project.sh).
# --bun on every bunx call: these packages ship `#!/usr/bin/env node`
# shebangs and bun honours them by default, so a missing or broken host
# node breaks the gate. bun is the declared runtime for this repo.
# shellcheck source=scripts/webui-ts-project.sh
. "$root/scripts/webui-ts-project.sh"
webui_ts_project="$(webui_ts_prepare)"
bunx --bun -p "typescript@$tsc_version" tsc -p "$webui_ts_project/tsconfig.json" --noEmit

# 2. Lint the sources with oxlint. The @rikalabs plugin, the vendored
#    dmmulroy/anti-slop plugin source (pinned by ANTI_SLOP_SHA; the project is
#    vendored source, not an npm package), and oxlint-tsgolint (the type-aware
#    backend) are fetched into the cache (no-op when the pinned versions are
#    already present) and oxlint runs next to them because jsPlugins resolve
#    relative to the config file's directory; a copy of the config is placed
#    there each run. The pinned packages are installed with one additive
#    `bun add` invocation: it merges the pins into the cache manifest and
#    never prunes what a sibling script installed. @oxlint/plugins is the
#    plugin API the anti-slop source imports; without it the plugin cannot load.
mkdir -p "$cache_dir"
if [ ! -d "$cache_dir/anti-slop-src" ]; then
  # --retry: cold CI without a warm ~/.cache/zdtd hits GitHub over the
  # network; a transient blip must not fail make lint the way bun_add below
  # already guards registry installs.
  curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors \
    "https://github.com/dmmulroy/anti-slop/archive/$anti_slop_sha.tar.gz" \
    -o "$cache_dir/anti-slop.tar.gz"
  got_sha256="$(sha256sum "$cache_dir/anti-slop.tar.gz" | cut -d' ' -f1)"
  if [ "$got_sha256" != "$anti_slop_sha256" ]; then
    rm -f "$cache_dir/anti-slop.tar.gz"
    echo "zdtd: lint-webui: anti-slop archive sha256 mismatch (got $got_sha256, want $anti_slop_sha256)" >&2
    exit 1
  fi
  mkdir -p "$cache_dir/anti-slop-src"
  tar xzf "$cache_dir/anti-slop.tar.gz" -C "$cache_dir/anti-slop-src" --strip-components=2 "anti-slop-$anti_slop_sha/src"
fi
# type module: the vendored anti-slop plugin source is ESM; without the field
# node reparses it with a MODULE_TYPELESS_PACKAGE_JSON warning.
[ -f "$cache_dir/package.json" ] || printf '{"type":"module"}\n' > "$cache_dir/package.json"
# Compile the anti-slop TypeScript plugin to JavaScript (oxlint loads plugins
# through Node.js, which does not understand TypeScript). Use bun build to
# transpile each .ts file to .js in place, rewriting .ts import extensions to
# .js and marking @oxlint imports as external (they resolve from the parent
# node_modules at runtime). Only compile if the compiled output is missing or
# older than the source.
if [ ! -f "$cache_dir/anti-slop-src/index.js" ] || \
   [ "$cache_dir/anti-slop-src/index.ts" -nt "$cache_dir/anti-slop-src/index.js" ]; then
  ( cd "$cache_dir/anti-slop-src" && \
    while IFS= read -r -d '' f; do
      # Skip test files (the plugin does not need them).
      [[ "$f" == *.test.ts ]] && continue
      out="${f%.ts}.js"
      bun build "$f" --outfile "$out" --target=node --format=esm \
        --external=@oxlint/plugins --external=oxlint/plugins-dev
      # Rewrite .ts import extensions to .js so Node.js can load them.
      sed -i 's|from "\(\..*\)\.ts"|from "\1.js"|g' "$out"
      sed -i "s|from '\(\..*\)\.ts'|from '\1.js'|g" "$out"
    done < <(find . -name '*.ts' -type f -print0 | LC_ALL=C sort -z) )
fi
# `bun add` reaches the network on every run, so a transient DNS/registry blip
# used to fail the whole gate (a failing sub-make surfaces as `make check`
# exit 2). Retry briefly, then fall back to the already-installed cache: the
# versions are pinned above, so a populated node_modules is exactly what the
# install would produce. Only a cold cache is a hard failure.
bun_add() {
  ( cd "$cache_dir" && bun add --silent \
      "@rikalabs/oxlint-standards@$oxlint_standards_version" \
      "oxlint-tsgolint@$oxlint_tsgolint_version" \
      "@oxlint/plugins@$oxlint_plugins_version" ) >/dev/null 2>&1
}
if ! bun_add; then
  sleep 2
  if ! bun_add; then
    if [ -d "$cache_dir/node_modules/@rikalabs/oxlint-standards" ] &&
      [ -d "$cache_dir/node_modules/oxlint-tsgolint" ] &&
      [ -d "$cache_dir/node_modules/@oxlint/plugins" ]; then
      echo "zdtd: lint-webui: registry unreachable; using the pinned cache in $cache_dir" >&2
    else
      echo "zdtd: lint-webui: could not install @rikalabs/oxlint-standards@$oxlint_standards_version + oxlint-tsgolint@$oxlint_tsgolint_version + @oxlint/plugins@$oxlint_plugins_version into $cache_dir (offline?)" >&2
      exit 1
    fi
  fi
fi
cp "$root/.oxlintrc.jsonc" "$cache_dir/oxlintrc.jsonc"
# Run from the staged project so the package.json that declares preact is the
# one oxlint's unlisted-external-imports rule reads, while --config points at
# the cache copy whose jsPlugins paths resolve beside it. tsgolint is not on
# the user's PATH; oxlint finds it via PATH lookup.
( cd "$webui_ts_project" && PATH="$cache_dir/node_modules/.bin:$PATH" \
    bunx --bun "oxlint@$oxlint_version" --config "$cache_dir/oxlintrc.jsonc" --deny-warnings ./*.ts ./*.tsx )

# 3. Design tokens: shared.css is the one home, spliced into the pages by the
#    build. Every page must carry the tokens marker, the sign-in pages the
#    sign-in marker, and no token may be declared that no page uses. A page that
#    hand-edits its tokens instead of the shared file fails the freshness gate.
python3 - "$root" <<'PY'
import pathlib
import re
import sys

pages_dir = pathlib.Path(sys.argv[1]) / "src/server/webui"
region_re = re.compile(r"/\* zdtd-css:([a-z0-9-]+) \*/(.*?)/\* /zdtd-css:\1 \*/", re.S)
shared = (pages_dir / "shared.css").read_text(encoding="utf-8")
regions = {m.group(1): m.group(2) for m in region_re.finditer(shared)}
if "tokens" not in regions or "signin" not in regions:
    raise SystemExit("zdtd: lint-webui: shared.css must define the tokens and signin regions")
required = {
    "shell.html": ("tokens",),
    "login.html": ("tokens", "signin"),
    "login_lockout.html": ("tokens", "signin"),
}
body = ""
for page, wanted in required.items():
    text = (pages_dir / page).read_text(encoding="utf-8")
    for name in wanted:
        if not re.search(rf"/\* zdtd-css:{name} \*/.*?/\* /zdtd-css:{name} \*/", text, re.S):
            raise SystemExit(f"zdtd: lint-webui: {page} is missing the {name} region marker")
    # Count usage everywhere except the token declarations themselves: the
    # sign-in region is where --err-ink/--err-field are consumed.
    body += re.sub(r"/\* zdtd-css:tokens \*/.*?/\* /zdtd-css:tokens \*/", "", text, flags=re.S)
tokens = re.findall(r"(--[a-z0-9-]+):", regions["tokens"])
dead = [token for token in tokens if body.count(token) == 0]
if dead:
    raise SystemExit(
        "zdtd: lint-webui: token(s) declared in shared.css but used by no page: "
        f"{', '.join(dead)}"
    )
print(f"zdtd: lint-webui: {len(tokens)} shared design tokens, all used")
PY

# 4. Freshness: regenerate into a temp copy of the pages and diff.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -r "$root/src/server/webui" "$tmp/pages"
bash "$root/scripts/build-webui-ts.sh" --dest "$tmp/pages" >/dev/null
if ! diff -rq "$root/src/server/webui" "$tmp/pages" >/dev/null; then
  echo "zdtd: lint-webui: committed webui pages are stale (a .ts source changed without regeneration). Run: make webui-ts" >&2
  exit 1
fi
echo "zdtd: lint-webui: tsc type-check, oxlint, and page freshness ok"
