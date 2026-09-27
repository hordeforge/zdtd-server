#!/usr/bin/env bash
# Navezgane smoke: boot the stock map (DTM + prefabs + stock quests.xml),
# join with loadgen bots, and assert the map loaded and the join passed.
# Mirrors auto_join.sh's structure but pins --world-name Navezgane, which
# exercises the full map path (prefab sleeper volumes, deco burst, quests).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIG="${ZIG:-zig}"
GAME="${GAME_DIR:-$HOME/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server}"
LOADGEN="${LOADGEN:-$ROOT/../7dtd-loadgen/src/LoadGen/bin/Release/net8.0/7dtd-loadgen}"
PORT="${PORT:-27130}"
COUNT="${COUNT:-2}"
ACTIONS="${ACTIONS:-8}"
WORLD="${WORLD:-$ROOT/worlds/zdtd_nav_smoke}"

if ! command -v "$ZIG" >/dev/null 2>&1; then
  echo "smoke-navezgane: missing Zig compiler '$ZIG'" >&2
  exit 127
fi
if ! command -v rg >/dev/null 2>&1; then
  echo "smoke-navezgane: missing required tool: rg (ripgrep)" >&2
  exit 127
fi
if [[ ! -x "$LOADGEN" ]]; then
  echo "smoke-navezgane: missing loadgen (build sibling 7dtd-loadgen first): $LOADGEN" >&2
  exit 2
fi
if [[ ! -d "$GAME/Data/Worlds/Navezgane" ]]; then
  echo "smoke-navezgane: Navezgane not found in game install (set GAME_DIR): $GAME" >&2
  exit 2
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((10#$PORT > 65533)); then
  echo "smoke-navezgane: PORT must be an integer 0..65533 (got '$PORT')" >&2
  exit 2
fi

# The clean-boot reset below is an rm -rf on an env-overridable path, so only
# accept a world dir under the repo's own overlay/scratch roots.
case "$WORLD" in
"$ROOT"/worlds/*|"$ROOT"/zig-out/*) ;;
*)
  echo "smoke-navezgane: refusing to reset '$WORLD': WORLD must be under $ROOT/worlds/ or $ROOT/zig-out/" >&2
  exit 2
  ;;
esac

rm -rf "$WORLD"
mkdir -p "$WORLD"
cd "$ROOT"
"$ZIG" build
: >"$WORLD/server.log"
./zig-out/bin/zdtd --port "$PORT" --game-dir "$GAME" --world-name Navezgane --world "$WORLD" >"$WORLD/server.log" 2>&1 &
SPID=$!
# shellcheck disable=SC1091 # the path is built at runtime, so shellcheck cannot follow it; server_boot.sh is in scripts/*.sh and is linted on its own
source "$(dirname "$0")/server_boot.sh"
zdtd_stop_on_exit "$SPID"

# Navezgane load (DTM + prefabs) takes longer than a flat world: wait for the
# map line, then for the listen line, or die with the server log.
zdtd_wait_ready smoke-navezgane "$SPID" "$WORLD/server.log" 120 0.5

# Assert the stock map actually loaded (not the flat fallback).
if ! rg -q 'dtm=6144x6144' "$WORLD/server.log"; then
  echo "smoke-navezgane: Navezgane DTM did not load; see $WORLD/server.log" >&2
  exit 1
fi
# Stock quests.xml should be in play (not the builtin 3-quest catalog).
if ! rg -q 'quests=.*defs=[0-9]{2,}' "$WORLD/server.log"; then
  echo "smoke-navezgane: stock quests.xml did not load; see $WORLD/server.log" >&2
  exit 1
fi

# LiteNet = ServerPort+2; expect every bot to PASS its join. The timeout caps
# loadgen's rejoin loop so the script exits after the smoke window.
"$LOADGEN" --join --host 127.0.0.1 --port $((10#$PORT + 2)) --count "$COUNT" --actions "$ACTIONS" --timeout 30000 --no-spawn-zombies | tee "$WORLD/loadgen.log"
passes=$(rg -c "PASS joined" "$WORLD/loadgen.log" || true)
if ((passes < COUNT)); then
  echo "smoke-navezgane: only $passes/$COUNT joins passed; see $WORLD/loadgen.log" >&2
  exit 1
fi
echo "smoke-navezgane OK: Navezgane loaded, $passes join passes (rejoins included, expected >= $COUNT)"
