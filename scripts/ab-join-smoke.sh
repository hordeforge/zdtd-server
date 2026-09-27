#!/usr/bin/env bash
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
set -euo pipefail

WS=${HORDEFORGE_ROOT:-${WS:-$(cd "$(dirname "$0")/../.." && pwd)}}
ZD=$WS/zdtd-server
INSTANCE=${1:-ab-mods}
LEG=${3:-both}
INST=$WS/7dtd-sandbox/instances/$INSTANCE
# Scratch stays on disk inside the checkout (gitignored, disk-backed), not in
# $TMPDIR: the loadgen logs and the zdtd world are real artifacts to read after
# the run, and /tmp is RAM-backed on some hosts.
OUT=${2:-$ZD/zig-out/ab-join-smoke}
LG=$WS/7dtd-loadgen/src/LoadGen/bin/Release/net8.0/7dtd-loadgen.dll
SB=$WS/7dtd-sandbox/scripts/sb

for tool in ss dotnet; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ab-join-smoke: missing required tool: $tool" >&2
    exit 127
  fi
done

# A leg whose port never came up proves nothing, so it has to fail the script:
# the old `if wait_port; then run_loadgen ...; fi` swallowed the timeout and the
# run still exited 0, which read as a passing A/B.
failed=0

port=$(sed -n 's/.*name="ServerPort".*value="\([0-9]*\)".*/\1/p' "$INST/serverconfig.xml" | head -1)
port=${port:-27160}
litenet=$((port + 2))
mkdir -p "$OUT"

run_loadgen() {
  local name=$1 status=0
  # Loadgen may time out; always record the exit and continue to teardown.
  dotnet "$LG" --join --host 127.0.0.1 --port "$litenet" --count 1 \
    --actions 3 --no-spawn-zombies --timeout 60000 --name "AB$name" \
    --log "$OUT/$name-loadgen.log" \
    >"$OUT/$name.out" 2>&1 || status=$?
  echo "$name loadgen exit=$status"
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
  if wait_port; then run_loadgen stock; else failed=1; fi
  "$SB" stop "$INSTANCE" >/dev/null 2>&1 || true
  wait "$sb_pid" 2>/dev/null || true
fi

if [ "$LEG" = "stock" ]; then
  echo; echo "== stages (stock)"
  grep -aoE "(PackageIdsReceived|LoginAnswered|WorldInfo|WorldSpawnPoints|GameStats|PlayerId|Joined|Spawned)[^\"]*" \
    "$OUT/stock.out" | LC_ALL=C sort -u | head -12 || true
  exit "$failed"
fi

echo "== zdtd leg"
"$ZD/zig-out/bin/zdtd" --port "$port" --game-dir "$INST/game" \
  --mods-dir "$INST/game/Mods" --serverconfig "$INST/serverconfig.xml" \
  --world "$OUT/zdtd_world" --world-name Navezgane \
  >"$OUT/zdtd-server.log" 2>&1 &
zd_pid=$!
if wait_port; then run_loadgen zdtd; else failed=1; fi
kill "$zd_pid" 2>/dev/null || true
wait "$zd_pid" 2>/dev/null || true

echo
echo "== stages"
for leg in stock zdtd; do
  echo "-- $leg"
  grep -aoE "(PackageIdsReceived|LoginAnswered|AuthState|WorldInfo|WorldSpawnPoints|GameStats|PlayerId|Joined|Spawned)[^\"]*" \
    "$OUT/$leg-loadgen.log" 2>/dev/null | LC_ALL=C sort -u | head -12 || true
done

if [ "$failed" -ne 0 ]; then
  echo "ab-join-smoke: at least one leg never opened port $port; see the logs in $OUT" >&2
  exit 1
fi
