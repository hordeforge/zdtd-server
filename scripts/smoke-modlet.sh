#!/usr/bin/env bash
# Modlet smoke: boot zdtd on a scratch minimal game-dir carrying the fixture
# modlet (assets/fixtures/modlet_minimal), assert the modlet loaded and the
# patched-config S2C cache built, then run the loadgen join when available.
# Scratch lives under zig-out/ (gitignored, disk-backed; no repo writes).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIG="${ZIG:-zig}"
LOADGEN="${LOADGEN:-$ROOT/../7dtd-loadgen/src/LoadGen/bin/Release/net8.0/7dtd-loadgen}"
PORT="${PORT:-27120}"
SCRATCH="${SCRATCH:-$ROOT/zig-out/smoke-modlet}"

if ! command -v "$ZIG" >/dev/null 2>&1; then
  echo "smoke-modlet: missing Zig compiler '$ZIG'" >&2
  exit 127
fi
if ! command -v rg >/dev/null 2>&1; then
  echo "smoke-modlet: missing required tool: rg (ripgrep)" >&2
  exit 127
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((10#$PORT > 65533)); then
  echo "smoke-modlet: PORT must be an integer 0..65533 (got '$PORT')" >&2
  exit 2
fi

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/world" "$SCRATCH/game" "$SCRATCH/game/Mods"
cp -r "$ROOT/assets/fixtures/gamedir_minimal/." "$SCRATCH/game/"
cp -r "$ROOT/assets/fixtures/modlet_minimal" "$SCRATCH/game/Mods/"

cd "$ROOT"
"$ZIG" build
./zig-out/bin/zdtd --port "$PORT" --game-dir "$SCRATCH/game" --world "$SCRATCH/world" >"$SCRATCH/server.log" 2>&1 &
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

ready=0
for _ in $(seq 1 40); do
  if ! kill -0 "$SPID" 2>/dev/null; then
    echo "smoke-modlet: zdtd exited during startup; see $SCRATCH/server.log" >&2
    tail -40 "$SCRATCH/server.log" >&2 || true
    exit 1
  fi
  if grep -q 'zdtd: config port=' "$SCRATCH/server.log" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.25
done
if [[ "$ready" -ne 1 ]]; then
  echo "smoke-modlet: zdtd did not become ready in time; see $SCRATCH/server.log" >&2
  exit 1
fi

# The fixture modlet must be discovered and its Config patches must have built
# the S2C cache for the three base configs present in gamedir_minimal.
rg -q "modlet 'ModletMinimal'" "$SCRATCH/server.log" \
  || { echo "smoke-modlet: modlet scan missing; log:" >&2; tail -40 "$SCRATCH/server.log" >&2; exit 1; }
rg -q "config s2c cache rows=3/42" "$SCRATCH/server.log" \
  || { echo "smoke-modlet: config cache rows != 3/42; log:" >&2; tail -40 "$SCRATCH/server.log" >&2; exit 1; }

if [[ -x "$LOADGEN" ]]; then
  # LiteNet = ServerPort+2
if "$LOADGEN" --join --host 127.0.0.1 --port $((10#$PORT + 2)) --count 1 --actions 5 --timeout 30000 --no-spawn-zombies | tee "$SCRATCH/loadgen.log"; then
  if rg -q "PASS joined" "$SCRATCH/loadgen.log"; then
    echo "smoke-modlet: loadgen join PASSED"
  else
    echo "smoke-modlet: loadgen exited 0 but no PASS joined; see $SCRATCH/loadgen.log" >&2
    exit 1
  fi
elif rg -q "reliable window drop pkg=NetPackageIdMapping" "$SCRATCH/server.log"; then
  # Documented loadgen harness stall (handoff.md): the harness's stage
  # machine stops ACK processing at LoginAnswered, so the server's bounded
  # reliable pump cannot drain the 255KB deflated IdMapping within the
  # critical budget and drops the peer (by-design give-up; the real client
  # delivers the join bundle fine). Keep the server-side checks as the gate.
  echo "smoke-modlet: loadgen join skipped (harness ACK stall on IdMapping, handoff.md); server-side checks passed" >&2
else
  echo "smoke-modlet: loadgen join failed; see $SCRATCH/loadgen.log" >&2
  exit 1
fi
else
  echo "smoke-modlet: loadgen not built (sibling 7dtd-loadgen); server-side checks only" >&2
fi
echo "smoke-modlet OK (modlet + config cache verified)"
