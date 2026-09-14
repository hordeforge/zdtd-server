#!/bin/bash
# Join/spawn A/B smoke: the stock sandbox dedicated server vs the zdtd binary,
# same game dir, same Mods/, same serverconfig, one loadgen client each.
#
# Sequential on one port block (the sandbox instance's ServerPort):
#   1. stock leg  - `sb launch-server ab-mods` (blocking) in the background
#   2. zdtd leg   - zig-out/bin/zdtd on the same game dir/Mods/serverconfig
# Both are driven by the same 7dtd-loadgen invocation (LiteNet = server port+2).
#
# Usage: scripts/ab-join-smoke.sh [instance] [out-dir] [both|stock|zdtd]
# Prints the join-stage lines of both legs and leaves the full logs in out-dir.
set -u

WS=/home/maci/Desktop/hordeforge
ZD=$WS/zdtd-server
INSTANCE=${1:-ab-mods}
LEG=${3:-both}
INST=$WS/7dtd-sandbox/instances/$INSTANCE
OUT=${2:-/tmp/ab-join-smoke}
LG=$WS/7dtd-loadgen/src/LoadGen/bin/Release/net8.0/7dtd-loadgen.dll
SB=$WS/7dtd-sandbox/scripts/sb

port=$(sed -n 's/.*name="ServerPort".*value="\([0-9]*\)".*/\1/p' "$INST/serverconfig.xml" | head -1)
port=${port:-27160}
litenet=$((port + 2))
mkdir -p "$OUT"

run_loadgen() {
  local name=$1
  dotnet "$LG" --join --host 127.0.0.1 --port "$litenet" --count 1 \
    --actions 3 --no-spawn-zombies --timeout 60000 --name "AB$name" \
    --log "$OUT/$name-loadgen.log" \
    >"$OUT/$name.out" 2>&1
  echo "$name loadgen exit=$?"
}

# The stock dedi binds the game port as UDP; zdtd puts its TCP info listener on
# that port and the LiteNet socket on port+2, so either protocol counts.
wait_port() {
  for _ in $(seq 1 90); do
    if ss -lunt 2>/dev/null | grep -q ":$port "; then return 0; fi
    sleep 2
  done
  echo "port $port never listened" >&2
  return 1
}

if [ "$LEG" != "zdtd" ]; then
  echo "== stock leg (port $port, litenet $litenet)"
  "$SB" launch-server "$INSTANCE" >"$OUT/stock-server.log" 2>&1 &
  sb_pid=$!
  wait_port && run_loadgen stock
  "$SB" stop "$INSTANCE" >/dev/null 2>&1
  wait "$sb_pid" 2>/dev/null
fi

if [ "$LEG" = "stock" ]; then
  echo; echo "== stages (stock)"
  grep -aoE "(PackageIdsReceived|LoginAnswered|WorldInfo|WorldSpawnPoints|GameStats|PlayerId|Joined|Spawned)[^\"]*" \
    "$OUT/stock.out" | sort -u | head -12
  exit 0
fi

echo "== zdtd leg"
"$ZD/zig-out/bin/zdtd" --port "$port" --game-dir "$INST/game" \
  --mods-dir "$INST/game/Mods" --serverconfig "$INST/serverconfig.xml" \
  --world "$OUT/zdtd_world" --world-name Navezgane \
  >"$OUT/zdtd-server.log" 2>&1 &
zd_pid=$!
wait_port && run_loadgen zdtd
kill "$zd_pid" 2>/dev/null
wait "$zd_pid" 2>/dev/null

echo
echo "== stages"
for leg in stock zdtd; do
  echo "-- $leg"
  grep -aoE "(PackageIdsReceived|LoginAnswered|AuthState|WorldInfo|WorldSpawnPoints|GameStats|PlayerId|Joined|Spawned)[^\"]*" \
    "$OUT/$leg-loadgen.log" 2>/dev/null | sort -u | head -12
done
