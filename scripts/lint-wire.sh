#!/usr/bin/env bash
# Wire / project lint for zdtd.
# ast-grep has no Zig language support, so this uses ripgrep heuristics.
# Exit 0 = clean. Exit 1 = findings.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0
note() { printf '==> %s\n' "$*"; }
hit() { printf '  FIND %s\n' "$*"; fail=1; }
ok() { printf '  ok\n'; }

note "forbidden AI attribution in sources"
attr_hits="$(
  rg -n --glob '!research_inv/**' --glob '!.opencode/node_modules/**' --glob '!.zig-cache/**' --glob '!zig-out/**' \
    --glob '!scripts/lint-wire.sh' \
    -e 'Generated with Claude' \
    -e 'Co-Authored-By:.*(Claude|Anthropic|OpenAI|Grok|Cursor)' \
    -e 'as an AI' \
    src docs AGENTS.md Makefile README.md TODO.md opencode.json scripts 2>/dev/null || true
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
  rg -n --glob '*.zig' \
    'framePackage\([^,]+,\s*[^,]+,\s*[0-9]+' \
    src 2>/dev/null || true
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
  rg -n --glob '*.zig' \
    -e '\.id\s*==\s*[0-9]+' \
    -e 'pkg_id\s*==\s*[0-9]+' \
    -e 'pkgId\s*==\s*[0-9]+' \
    src 2>/dev/null || true
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
  rg -n --glob '*.zig' -i \
    -e 'almost stock' \
    -e 'fake terrain' \
    -e 'invent(ed)? world' \
    -e 'skip server-driven' \
    src/wire src/server 2>/dev/null || true
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
