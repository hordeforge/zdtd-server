#!/usr/bin/env bash
# Wire / project lint for zdtd.
# ast-grep has no Zig language support, so this uses ripgrep heuristics.
# Exit 0 = clean. Exit 1 = findings. Exit 2 = a check could not run. Exit 127 = missing tool.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v rg >/dev/null 2>&1; then
  echo "lint-wire: missing required tool: rg (ripgrep)" >&2
  echo "lint-wire: install: apt install ripgrep  |  brew install ripgrep  |  cargo install ripgrep" >&2
  exit 127
fi

fail=0
note() { printf '==> %s\n' "$*"; }
hit() { printf '  FIND %s\n' "$*"; fail=1; }
ok() { printf '  ok\n'; }

# rg exits 1 for "no matches" (the clean case) and 2 for a real failure: a path
# that does not exist, an unreadable file, a rejected pattern. Swallowing both
# as "no hits" turns a broken check into a silent pass, so only exit 1 is
# treated as clean.
rg_hits() {
  local out status=0
  out="$(rg "$@")" || status=$?
  if ((status > 1)); then
    echo "lint-wire: rg failed (exit $status) for check: $*" >&2
    exit 2
  fi
  printf '%s\n' "$out"
}

note "forbidden AI attribution in sources"
attr_hits="$(
  rg_hits -n --glob '!research_inv/**' --glob '!.opencode/node_modules/**' --glob '!.zig-cache/**' --glob '!zig-out/**' \
    --glob '!scripts/lint-wire.sh' \
    -e 'Generated with Claude' \
    -e 'Co-Authored-By:.*(Claude|Anthropic|OpenAI|Grok|Cursor)' \
    -e 'as an AI' \
    src docs AGENTS.md Makefile README.md TODO.md scripts
)"
if [[ -n "$attr_hits" ]]; then
  printf '%s\n' "$attr_hits"
  hit "remove AI attribution (AGENTS.md)"
else
  ok
fi

note "numeric package id as framePackage 3rd arg (prefer name map / variable)"
# Bare decimal package id in production framing. Allow the frame.zig unit test (99).
frame_hits="$(
  rg_hits -n --glob '*.zig' \
    'framePackage\([^,]+,\s*[^,]+,\s*[0-9]+' \
    src
)"
found_frame=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  # Allowed fixture in frame.zig unit test
  if [[ "$line" == *'frame.zig:'* && "$line" == *', 99,'* ]]; then
    continue
  fi
  hit "$line"
  found_frame=1
done <<< "$frame_hits"
if [[ $found_frame -eq 0 ]]; then
  ok
fi

note "package id equality against bare decimals (non-test assertions)"
eq_hits="$(
  rg_hits -n --glob '*.zig' \
    -e '\.id\s*==\s*[0-9]+' \
    -e 'pkg_id\s*==\s*[0-9]+' \
    -e 'pkgId\s*==\s*[0-9]+' \
    src
)"
found_eq=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  # Test assertions are fine (fixtures pin maps)
  if [[ "$line" == *'expectEqual'* || "$line" == *'expect('* || "$line" == *'testing.'* ]]; then
    continue
  fi
  if [[ "$line" == *'/tests/'* ]]; then
    continue
  fi
  hit "$line"
  found_eq=1
done <<< "$eq_hits"
if [[ $found_eq -eq 0 ]]; then
  ok
fi

note "fidelity smell phrases in wire/server"
smell_hits="$(
  rg_hits -n --glob '*.zig' -i \
    -e 'almost stock' \
    -e 'fake terrain' \
    -e 'invent(ed)? world' \
    -e 'skip server-driven' \
    src/wire src/server
)"
if [[ -n "$smell_hits" ]]; then
  printf '%s\n' "$smell_hits"
  hit "review: AGENTS requires stock fidelity, no invented world data"
else
  ok
fi

if [[ $fail -ne 0 ]]; then
  printf '\nlint-wire: findings above (see AGENTS.md package-id / fidelity rules)\n' >&2
  exit 1
fi
printf '\nlint-wire: clean\n'
