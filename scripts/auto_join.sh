#!/usr/bin/env bash
# Autonomous loadgen join against a local zdtd instance.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIG="${ZIG:-zig}"
GAME="${GAME_DIR:-$HOME/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server}"
LOADGEN="${LOADGEN:-$ROOT/../7dtd-loadgen/src/LoadGen/bin/Release/net8.0/7dtd-loadgen}"
PORT="${PORT:-27110}"
WORLD="${WORLD:-$ROOT/worlds/zdtd_auto_join}"

if ! command -v "$ZIG" >/dev/null 2>&1; then
  echo "auto_join: missing Zig compiler '$ZIG'" >&2
  exit 127
fi
if ! command -v rg >/dev/null 2>&1; then
  echo "auto_join: missing required tool: rg (ripgrep)" >&2
  exit 127
fi
if [[ ! -x "$LOADGEN" ]]; then
  echo "auto_join: missing loadgen (build sibling 7dtd-loadgen first): $LOADGEN" >&2
  exit 2
fi
if [[ ! -d "$GAME" ]]; then
  echo "auto_join: game install not found (set GAME_DIR): $GAME" >&2
  exit 2
fi
# ServerPort 0..65533 (LiteNet uses port+2); reject non-integers early.
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((10#$PORT > 65533)); then
  echo "auto_join: PORT must be an integer 0..65533 (got '$PORT')" >&2
  exit 2
fi

mkdir -p "$WORLD"
cd "$ROOT"
"$ZIG" build
: >"$WORLD/server.log"
./zig-out/bin/zdtd --port "$PORT" --game-dir "$GAME" --world "$WORLD" >"$WORLD/server.log" 2>&1 &
SPID=$!
# shellcheck disable=SC1091 # the path is built at runtime, so shellcheck cannot follow it; server_boot.sh is in scripts/*.sh and is linted on its own
source "$(dirname "$0")/server_boot.sh"
zdtd_stop_on_exit "$SPID"
# Wait until config line is printed (socket bind is past that point), or die early.
zdtd_wait_ready auto_join "$SPID" "$WORLD/server.log" 40 0.25
# LiteNet = ServerPort+2
"$LOADGEN" --join --host 127.0.0.1 --port $((10#$PORT + 2)) --count 1 --actions 5 --timeout 30000 --no-spawn-zombies | tee "$WORLD/loadgen.log"
rg -q "PASS joined" "$WORLD/loadgen.log"
echo "auto_join OK"
