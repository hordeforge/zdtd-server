#!/usr/bin/env bash
# Build every core plugin's .wasm from its Zig source (mods/BUILDING.md).
# bot stays C by design (ADR 0026); example_chat_filter is untouched.
#
# Usage: scripts/build-plugins.sh [--dest DIR]   (default: in place)
# --dest writes every artifact under DIR at the same relative path, so the
# freshness gate (scripts/lint-plugins.sh) can rebuild and diff without
# touching the working tree.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIG=${ZIG:-zig}

dest=""
if [ "${1:-}" = "--dest" ]; then
  dest="$2"
  shift 2
fi

# Final path for an artifact: in place, or mirrored under --dest.
out_path() {
  local rel="$1"
  if [ -n "$dest" ]; then
    mkdir -p "$dest/$(dirname "$rel")"
    printf '%s\n' "$dest/$rel"
  else
    printf '%s\n' "$rel"
  fi
}

build() {
  local mod="$1"
  $ZIG build-exe -OReleaseSmall -target wasm32-freestanding -rdynamic \
    --name "$mod" \
    --dep plugin_common --dep plugin_root \
    -Mroot="plugins/core_main.zig" \
    --dep plugin_common -Mplugin_root="plugins/$mod/$mod.zig" \
    -Mplugin_common=mods/plugin_common.zig
  local out
  out="$(out_path "plugins/$mod/$mod.wasm")"
  mv "$mod.wasm" "$out"
  echo "built $out"
}

for m in core_announce core_killfeed core_damagegate core_pricegate \
         core_rewardgate core_lootgate core_tradefeed core_pvp \
         core_questgate core_craftgate core_adminverbs core_perkgate; do
  build "$m"
done

# Addons stay in mods/: mcp + parachute are Zig; bot stays C by design
# (ADR 0026); example_chat_filter is untouched.
for m in mcp parachute; do
  $ZIG build-exe -OReleaseSmall -target wasm32-freestanding -rdynamic \
    --name "$m" \
    --dep plugin_common --dep plugin_root \
    -Mroot="mods/$m/main.zig" \
    --dep plugin_common -Mplugin_root="mods/$m/$m.zig" \
    -Mplugin_common=mods/plugin_common.zig
  out="$(out_path "mods/$m/$m.wasm")"
  mv "$m.wasm" "$out"
  echo "built $out"
done

echo "done"

# C fixtures (assets/fixtures/plugin_*.c) and C addons (mods/*.c): rebuild so
# the committed .wasm always matches its source (a stale fixture fails the
# wasm host tests loudly, but drift should never reach that point). clang is
# the fixture compiler per the comment in plugin_hello.c; the C addons
# (fps_bot, example_chat_filter) use the same recipe.
#
# The committed C artifacts are the pinned clang major's output, so a different
# clang produces different bytes and would make lint-plugins.sh report a stale
# binary that no source change caused. The pin is therefore explicit: build
# with clang-<CLANG_MAJOR> (default 18, the compiler that produced the
# committed fixtures) and skip the C artifacts, loudly, on a host that does not
# have it. A deliberate toolchain bump means setting CLANG_MAJOR to the new
# major, rebuilding, and committing the new .wasm bytes with the bump.
clang_major="${CLANG_MAJOR:-18}"
clang_bin=""
for candidate in ${CLANG:-} "clang-$clang_major" clang; do
  [ -n "$candidate" ] || continue
  command -v "$candidate" >/dev/null 2>&1 || continue
  found_major="$("$candidate" --version 2>/dev/null | head -1 | sed -n 's/.*clang version \([0-9][0-9]*\).*/\1/p')"
  if [ "$found_major" = "$clang_major" ]; then
    clang_bin="$candidate"
    break
  fi
done

if [ -n "$clang_bin" ]; then
  for c in assets/fixtures/plugin_*.c mods/fps_bot/fps_bot.c mods/example_chat_filter/example_chat_filter.c; do
    [ -f "$c" ] || continue
    w="$(out_path "${c%.c}.wasm")"
    # In place: skip an artifact already newer than its source. Under --dest
    # the mirror starts empty, so every artifact is built.
    if [ ! -f "$w" ] || [ "$w" -ot "$c" ]; then
      "$clang_bin" --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
        -o "$w" "$c"
      echo "built $w"
    fi
  done
else
  echo "zdtd: build-plugins: skipping the C plugin artifacts: no clang $clang_major on PATH" \
       "(the committed bytes are that major's output; set CLANG_MAJOR=<major> to bump deliberately," \
       "then rebuild, run the wasm host tests, and commit the new .wasm files)" >&2
fi
