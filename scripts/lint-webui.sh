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
# Override locally: TSC_VERSION=5.9.3 OXLINT_VERSION=1.86.0 \
#   OXLINT_TSGOLINT_VERSION=7.0.2003 OXLINT_STANDARDS_VERSION=0.8.1 \
#   SHADCN_LINT_VERSION=0.2.0 ANTI_SLOP_SHA=... ANTI_SLOP_SHA256=... \
#   bash scripts/lint-webui.sh
#
# Requires: bun (bunx), python3, sha256sum (already a make check requirement).

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v sha256sum >/dev/null 2>&1; then
  echo "zdtd: lint-webui: missing required tool: sha256sum (GNU coreutils)" >&2
  exit 127
fi
oxlint_version="${OXLINT_VERSION:-1.86.0}"
oxlint_standards_version="${OXLINT_STANDARDS_VERSION:-0.8.1}"
oxlint_tsgolint_version="${OXLINT_TSGOLINT_VERSION:-7.0.2003}"
shadcn_lint_version="${SHADCN_LINT_VERSION:-0.2.0}"
anti_slop_sha="${ANTI_SLOP_SHA:-c44ef22ca116d0ba62a3ff663a0bd13a3f3fa40b}"
# Content hash of the GitHub archive for ANTI_SLOP_SHA (commit pin alone is not
# enough: GitHub can regenerate archive bytes for the same commit). Override
# only together with ANTI_SLOP_SHA when deliberately bumping the plugin.
anti_slop_sha256="${ANTI_SLOP_SHA256:-afc6aaeb4561561835c51e0a919ac86a1ebd1474667a3bd311e5a0a775f3d3d9}"
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
#    plugin API the anti-slop source imports; without it the plugin cannot load,
#    and upstream requires it at exactly the oxlint version, so one pin covers
#    both. The source unpacks into a directory keyed by ANTI_SLOP_SHA, so a pin
#    bump fetches fresh source instead of reusing the previous one;
#    anti-slop-src is a symlink to the pinned directory.
mkdir -p "$cache_dir"
anti_slop_dir="$cache_dir/anti-slop-$anti_slop_sha"
if [ ! -d "$anti_slop_dir" ]; then
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
  mkdir -p "$anti_slop_dir.part"
  tar xzf "$cache_dir/anti-slop.tar.gz" -C "$anti_slop_dir.part" --strip-components=2 "anti-slop-$anti_slop_sha/src"
  mv "$anti_slop_dir.part" "$anti_slop_dir"
fi
rm -rf "$cache_dir/anti-slop-src"
ln -sfn "$anti_slop_dir" "$cache_dir/anti-slop-src"
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
      "@oxlint/plugins@$oxlint_version" \
      "@shadcn/lint@$shadcn_lint_version" ) >/dev/null 2>&1
}
if ! bun_add; then
  sleep 2
  if ! bun_add; then
    if [ -d "$cache_dir/node_modules/@rikalabs/oxlint-standards" ] &&
      [ -d "$cache_dir/node_modules/oxlint-tsgolint" ] &&
      [ -d "$cache_dir/node_modules/@oxlint/plugins" ] &&
      [ -d "$cache_dir/node_modules/@shadcn/lint" ]; then
      echo "zdtd: lint-webui: registry unreachable; using the pinned cache in $cache_dir" >&2
    else
      echo "zdtd: lint-webui: could not install @rikalabs/oxlint-standards@$oxlint_standards_version + oxlint-tsgolint@$oxlint_tsgolint_version + @oxlint/plugins@$oxlint_version + @shadcn/lint@$shadcn_lint_version into $cache_dir (offline?)" >&2
      exit 1
    fi
  fi
fi
# The strict preset chain, flattened: the upstream presets name a few builtin
# rules this oxlint does not implement, and oxlint refuses to load a config
# whose extends chain names an unknown rule. The flattener drops those (listed
# on stderr) and keeps everything else; .oxlintrc.jsonc extends the result.
presets="$cache_dir/node_modules/@rikalabs/oxlint-standards/presets"
( cd "$cache_dir" && bunx --bun "oxlint@$oxlint_version" --rules -f json ) > "$cache_dir/oxlint-rules.json"
python3 "$root/scripts/oxlint-flatten-presets.py" "$cache_dir/oxlint-rules.json" \
  "$cache_dir/strict-resolved.json" \
  "$presets/strict.json" "$presets/strict-web.json"
cp "$root/.oxlintrc.jsonc" "$cache_dir/oxlintrc.jsonc"
# Run from the staged project so the package.json that declares preact is the
# one oxlint's unlisted-external-imports rule reads, while --config points at
# the cache copy whose jsPlugins paths resolve beside it. tsgolint is not on
# the user's PATH; oxlint finds it via PATH lookup.
# Every source under ts/ is listed explicitly: oxlint takes files, not
# directories, so a new tree (lib/, components/ui/) has to be named here or it
# silently escapes the gate. Step 3 fails if a source is not in that set.
( cd "$webui_ts_project" && PATH="$cache_dir/node_modules/.bin:$PATH" \
    bunx --bun "oxlint@$oxlint_version" --config "$cache_dir/oxlintrc.jsonc" --deny-warnings \
        ./*.ts ./*.tsx ./lib/*.ts ./components/ui/*.tsx )

# 3. Design tokens: webui.css is the one home, built by the Tailwind CLI and
#    spliced into the pages by the build. Every page must carry its region
#    marker, or a hand-edited page stylesheet would slip past the freshness
#    gate. The shadcn contract (components.json + the @theme inline block) and
#    the source coverage of tsc/oxlint are checked here too.
python3 - "$root" <<'PY'
import json
import pathlib
import re
import sys

pages_dir = pathlib.Path(sys.argv[1]) / "src/server/webui"
theme = (pages_dir / "webui.css").read_text(encoding="utf-8")
theme_block = re.search(r"@theme \{(.*?)\}", theme, re.S)
if theme_block is None:
    raise SystemExit("zdtd: lint-webui: webui.css must define an @theme block")
required = {
    "shell.html": ("tokens",),
    "login.html": ("tokens",),
    "login_lockout.html": ("tokens",),
}
for page, wanted in required.items():
    text = (pages_dir / page).read_text(encoding="utf-8")
    for name in wanted:
        if not re.search(rf"/\* zdtd-css:{name} \*/.*?/\* /zdtd-css:{name} \*/", text, re.S):
            raise SystemExit(f"zdtd: lint-webui: {page} is missing the {name} region marker")
TOKEN = r"(--color-[a-z0-9-]+|--font-[a-z0-9-]+|--radius-[a-z0-9-]+|--shadow-[a-z0-9-]+|--spacing-[a-z0-9_]+|--text-[a-z0-9-]+|--tracking-[a-z0-9-]+|--leading-[a-z0-9-]+):"
tokens = re.findall(TOKEN, theme_block.group(1))
# The @theme inline block publishes the shadcn contract; count it too, so the
# number is the whole token surface and not just the palette.
contract_block = re.search(r"@theme inline \{(.*?)\n\}", theme, re.S)
tokens += re.findall(TOKEN, contract_block.group(1)) if contract_block else []
print(f"zdtd: lint-webui: {len(tokens)} theme tokens declared")

# The shadcn contract the primitives are written against: @shadcn/lint reads
# these to check a page against the design system, and a page whose
# components.json is missing would fall back to its bundled grammar silently.
contract = pathlib.Path(sys.argv[1]) / "components.json"
shadcn = json.loads(contract.read_text(encoding="utf-8")) if contract.is_file() else None
if shadcn is None:
    raise SystemExit("zdtd: lint-webui: components.json is missing (the shadcn alias contract)")
for key in ("ui", "utils", "components"):
    if not isinstance(shadcn.get("aliases", {}).get(key), str):
        raise SystemExit(f"zdtd: lint-webui: components.json aliases.{key} must name the import path")
css = shadcn.get("tailwind", {}).get("css")
if not isinstance(css, str) or not (pathlib.Path(sys.argv[1]) / css).is_file():
    raise SystemExit(f"zdtd: lint-webui: components.json tailwind.css must point at an existing stylesheet, got {css!r}")
root = pathlib.Path(sys.argv[1])
inline = re.search(r"@theme inline \{(.*?)\n\}", theme, re.S)
if inline is None or "--color-card:" not in inline.group(1):
    raise SystemExit("zdtd: lint-webui: webui.css must publish the shadcn contract in an @theme inline block")

# Coverage: every authored source is in the tsc program AND in the oxlint file
# set, so a new file cannot escape either gate by being unlisted.
# tsconfig.json carries // comments, so read the files array rather than parse it.
tsc_text = (pathlib.Path(sys.argv[1]) / "src/server/webui/ts/tsconfig.json").read_text(encoding="utf-8")
files_block = re.search(r'"files"\s*:\s*\[(.*?)\]', tsc_text, re.S)
if files_block is None:
    raise SystemExit("zdtd: lint-webui: tsconfig.json must declare an explicit files list")
listed = set(re.findall(r'"([^"]+)"', files_block.group(1)))
authored = {
    str(p.relative_to(pathlib.Path(sys.argv[1]) / "src/server/webui/ts"))
    for p in (pathlib.Path(sys.argv[1]) / "src/server/webui/ts").rglob("*.ts")
} | {
    str(p.relative_to(pathlib.Path(sys.argv[1]) / "src/server/webui/ts"))
    for p in (pathlib.Path(sys.argv[1]) / "src/server/webui/ts").rglob("*.tsx")
}
unlisted = sorted(a for a in authored if a not in listed)
if unlisted:
    raise SystemExit(
        "zdtd: lint-webui: sources missing from tsconfig files (so tsc and oxlint both skip them): "
        + ", ".join(unlisted)
    )
print(f"zdtd: lint-webui: {len(authored)} sources covered by tsc and oxlint")
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
