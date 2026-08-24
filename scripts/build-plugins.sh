#!/usr/bin/env bash
# Build every core plugin's .wasm from its Zig source (mods/BUILDING.md).
# bot stays C by design (ADR 0026); example_chat_filter is untouched.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIG=${ZIG:-zig}
OUT=/tmp/zdtd_plugin_build
mkdir -p "$OUT"

build() {
  local mod="$1"
  $ZIG build-exe -OReleaseSmall -target wasm32-freestanding -rdynamic \
    --name "$mod" \
    --dep plugin_common --dep plugin_root \
    -Mroot="mods/$mod/main.zig" \
    --dep plugin_common -Mplugin_root="mods/$mod/$mod.zig" \
    -Mplugin_common=mods/plugin_common.zig
  mv "$mod.wasm" "mods/$mod/$mod.wasm"
  echo "built mods/$mod/$mod.wasm"
}

for m in zdtd_announce zdtd_killfeed zdtd_damagegate zdtd_pricegate \
         zdtd_rewardgate zdtd_lootgate zdtd_tradefeed zdtd_pvp \
         zdtd_questgate zdtd_craftgate zdtd_adminverbs mcp; do
  build "$m"
done

echo "done"
