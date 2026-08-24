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
    -Mroot="plugins/$mod/main.zig" \
    --dep plugin_common -Mplugin_root="plugins/$mod/$mod.zig" \
    -Mplugin_common=mods/plugin_common.zig
  mv "$mod.wasm" "plugins/$mod/$mod.wasm"
  echo "built plugins/$mod/$mod.wasm"
}

for m in core_announce core_killfeed core_damagegate core_pricegate \
         core_rewardgate core_lootgate core_tradefeed core_pvp \
         core_questgate core_craftgate core_adminverbs; do
  build "$m"
done

# Addons stay in mods/: mcp is Zig; bot stays C by design (ADR 0026);
# example_chat_filter is untouched.
for m in mcp; do
  $ZIG build-exe -OReleaseSmall -target wasm32-freestanding -rdynamic \
    --name "$m" \
    --dep plugin_common --dep plugin_root \
    -Mroot="mods/$m/main.zig" \
    --dep plugin_common -Mplugin_root="mods/$m/$m.zig" \
    -Mplugin_common=mods/plugin_common.zig
  mv "$m.wasm" "mods/$m/$m.wasm"
  echo "built mods/$m/$m.wasm"
done

echo "done"
