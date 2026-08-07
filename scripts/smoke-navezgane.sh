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
PORT="${PORT:-27120}"
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

rm -rf "$WORLD"
mkdir -p "$WORLD"
cd "$ROOT"
"$ZIG" build
: >"$WORLD/server.log"
./zig-out/bin/zdtd --port "$PORT" --game-dir "$GAME" --world-name Navezgane --world "$WORLD" >"$WORLD/server.log" 2>&1 &
SPID=$!
cleanup() {
  if [[ -n "${SPID:-}" ]] && kill -0 "$SPID" 2>/dev/null; then
    kill -TERM "$SPID" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$SPID" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$SPID" 2>/dev/null || true
  fi
  wait "$SPID" 2>/dev/null || true
}
trap cleanup EXIT

# Navezgane load (DTM + prefabs) takes longer than a flat world: wait for the
# map line, then for the listen line, or die with the server log.
ready=0
for _ in $(seq 1 120); do
  if ! kill -0 "$SPID" 2>/dev/null; then
    echo "smoke-navezgane: zdtd exited during startup; see $WORLD/server.log" >&2
    exit 1
  fi
  if grep -q 'zdtd: config port=' "$WORLD/server.log" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.5
done
if [[ "$ready" -ne 1 ]]; then
  echo "smoke-navezgane: zdtd did not become ready in time; see $WORLD/server.log" >&2
  exit 1
fi

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

# LiteNet = ServerPort+2; expect every bot to PASS its join.
"$LOADGEN" --join --host 127.0.0.1 --port $((10#$PORT + 2)) --count "$COUNT" --actions "$ACTIONS" | tee "$WORLD/loadgen.log"
passes=$(rg -c "PASS joined" "$WORLD/loadgen.log" || true)
if ((passes < COUNT)); then
  echo "smoke-navezgane: only $passes/$COUNT joins passed; see $WORLD/loadgen.log" >&2
  exit 1
fi
echo "smoke-navezgane OK: Navezgane loaded, $passes/$COUNT joins passed"
