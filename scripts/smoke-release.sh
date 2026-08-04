#!/usr/bin/env bash
# Smoke-test the release artifact produced by `make release`.
# Verifies --version output, stripped binary, and sha256 sidecar.
# Invoked by CI after `make release`; runnable locally the same way.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bin=zig-out/bin/zdtd
test -f "$bin" || { echo "smoke-release: missing $bin (run make release first)" >&2; exit 1; }

product=$(sed -n 's/^pub const product = "\([^"]*\)";/\1/p' src/version.zig)
wire=$(sed -n 's/^pub const stock_wire = "\([^"]*\)";/\1/p' src/version.zig)
test -n "$product" && test -n "$wire"

# Must match src/main.zig --version format (product + stock wire).
test "$("$bin" --version 2>&1)" = "zdtd $product (stock wire $wire)"

# Operator artifact must be stripped (make release uses -Dstrip=true).
# Prefer `file`; fall back to absence of .debug_* sections via readelf.
if command -v file >/dev/null 2>&1; then
  file "$bin" | grep -q 'stripped'
else
  command -v readelf >/dev/null 2>&1 || {
    echo "smoke-release: need file or readelf to verify stripped binary" >&2
    exit 127
  }
  if readelf -S "$bin" | grep -q '[[:space:]]\.debug_'; then
    echo "smoke-release: $bin contains debug sections" >&2
    exit 1
  fi
fi

# Sidecar hash must match the binary we ship.
test -f "$bin.sha256"
(cd zig-out/bin && sha256sum -c zdtd.sha256)

echo "smoke-release: ok $bin (product $product, stock wire $wire)"
