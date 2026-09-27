#!/usr/bin/env bash
# Shared boot and teardown for the scripts that run a zdtd server in the
# background (auto_join.sh, smoke-modlet.sh, smoke-navezgane.sh). Sourced, not
# executed. Keeping one copy is the point: three near-identical cleanup traps
# had already drifted apart in their log-on-failure behaviour.

# zdtd_stop <pid> - TERM, wait up to 1s, then KILL; safe to call on a dead pid.
zdtd_stop() {
  local pid="$1"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

# zdtd_stop_on_exit <pid> - trap the teardown of one background server.
zdtd_stop_on_exit() {
  local pid="$1"
  # shellcheck disable=SC2064 # the pid is captured now, on purpose: a trap
  # string is evaluated at fire time and $SPID may already have been rebound.
  trap "zdtd_stop $pid" EXIT INT TERM
}

# zdtd_wait_ready <name> <pid> <log> <tries> <interval>
# Block until the server logs its config line, which is past the socket bind.
# Dies with the log tail when the server exits or the budget runs out, so a
# failed smoke never reports a bare timeout.
zdtd_wait_ready() {
  local name="$1" pid="$2" log="$3" tries="$4" interval="$5"
  local attempt
  for ((attempt = 0; attempt < tries; attempt++)); do
    # Log first, liveness second: a server that printed the config line and
    # then died inside the same poll interval is ready, not a failed start.
    if rg -q 'zdtd: config port=' "$log" 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "$name: zdtd exited during startup; see $log" >&2
      tail -40 "$log" >&2 || true
      return 1
    fi
    sleep "$interval"
  done
  echo "$name: zdtd did not become ready in time; see $log" >&2
  tail -40 "$log" >&2 || true
  return 1
}
