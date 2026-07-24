#!/usr/bin/env bash
# Autonomous loadgen join against a local zdtd instance.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GAME="${GAME_DIR:-$HOME/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server}"
LOADGEN="${LOADGEN:-$ROOT/../7dtd-loadgen/src/LoadGen/bin/Release/net8.0/7dtd-loadgen}"
PORT="${PORT:-27110}"
WORLD="${WORLD:-$ROOT/worlds/zdtd_auto_join}"
mkdir -p "$WORLD"
cd "$ROOT"
zig build
./zig-out/bin/zdtd --port "$PORT" --game-dir "$GAME" --world "$WORLD" >"$WORLD/server.log" 2>&1 &
SPID=$!
cleanup() { kill "$SPID" 2>/dev/null || true; wait "$SPID" 2>/dev/null || true; }
trap cleanup EXIT
sleep 1
if [[ ! -x "$LOADGEN" ]]; then
  echo "missing loadgen: $LOADGEN" >&2
  exit 2
fi
# LiteNet = ServerPort+2
"$LOADGEN" --join --host 127.0.0.1 --port $((PORT + 2)) --count 1 --actions 5 --timeout 30000 --no-spawn-zombies | tee "$WORLD/loadgen.log"
rg -q "PASS joined" "$WORLD/loadgen.log"
echo "auto_join OK"
