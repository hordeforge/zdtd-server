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

# The scratch reset below is an rm -rf on an env-overridable path, so only
# accept a directory under the repo's own scratch root.
case "$SCRATCH" in
"$ROOT"/zig-out/*) ;;
*)
  echo "smoke-modlet: refusing to reset '$SCRATCH': SCRATCH must be under $ROOT/zig-out/" >&2
  exit 2
  ;;
esac

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/world" "$SCRATCH/game" "$SCRATCH/game/Mods"
cp -r "$ROOT/assets/fixtures/gamedir_minimal/." "$SCRATCH/game/"
cp -r "$ROOT/assets/fixtures/modlet_minimal" "$SCRATCH/game/Mods/"

cd "$ROOT"
"$ZIG" build
./zig-out/bin/zdtd --port "$PORT" --game-dir "$SCRATCH/game" --world "$SCRATCH/world" >"$SCRATCH/server.log" 2>&1 &
SPID=$!
# shellcheck disable=SC1091 # the path is built at runtime, so shellcheck cannot follow it; server_boot.sh is in scripts/*.sh and is linted on its own
source "$(dirname "$0")/server_boot.sh"
zdtd_stop_on_exit "$SPID"

zdtd_wait_ready smoke-modlet "$SPID" "$SCRATCH/server.log" 40 0.25

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
