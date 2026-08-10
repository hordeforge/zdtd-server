#!/usr/bin/env bash
# Smoke-test the release artifact produced by `make release`.
# Verifies --version, --help, stripped binary, sha256 sidecar, and one-tick start.
# Invoked by CI after `make release`; runnable locally via `make smoke`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bin=zig-out/bin/zdtd
test -f "$bin" || { echo "smoke-release: missing $bin (run make release first)" >&2; exit 1; }
test -x "$bin" || { echo "smoke-release: $bin is not executable" >&2; exit 1; }
command -v timeout >/dev/null 2>&1 || {
  echo "smoke-release: missing required tool: timeout" >&2
  exit 127
}

product=$(sed -n 's/^pub const product = "\([^"]*\)";/\1/p' src/version.zig | head -n1)
wire=$(sed -n 's/^pub const stock_wire = "\([^"]*\)";/\1/p' src/version.zig | head -n1)
if [[ -z "$product" || -z "$wire" ]]; then
  echo "smoke-release: could not read product/wire from src/version.zig" >&2
  exit 1
fi

# Must match src/main.zig --version format (product + stock wire).
ver_out="$("$bin" --version 2>&1)"
if [[ "$ver_out" != "zdtd $product (stock wire $wire)" ]]; then
  echo "smoke-release: --version mismatch:" >&2
  echo "  got:  $ver_out" >&2
  echo "  want: zdtd $product (stock wire $wire)" >&2
  exit 1
fi

# Help is the operator onboarding surface; empty or truncated is a ship-blocker.
help_out="$("$bin" --help 2>&1)"
if [[ -z "$help_out" ]]; then
  echo "smoke-release: --help produced no output" >&2
  exit 1
fi
if ! printf '%s\n' "$help_out" | grep -q '^Usage: zdtd'; then
  echo "smoke-release: --help missing 'Usage: zdtd' header" >&2
  exit 1
fi

# Operator artifact must be stripped (make release uses -Dstrip=true).
# Prefer `file`; fall back to absence of .debug_* sections via readelf.
if command -v file >/dev/null 2>&1; then
  # ", stripped" (never bare "stripped"): file reports unstripped binaries
  # as ", not stripped", which a bare 'stripped' grep would also match.
  if ! file "$bin" | grep -q ', stripped'; then
    echo "smoke-release: $bin is not stripped" >&2
    exit 1
  fi
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

# Provenance record must exist and name the same hash (make release writes both).
test -f zig-out/bin/buildinfo.txt
sidecar_hash="$(cut -d' ' -f1 zig-out/bin/zdtd.sha256)"
if ! grep -q "binary_sha256=$sidecar_hash" zig-out/bin/buildinfo.txt; then
  echo "smoke-release: buildinfo.txt does not record binary_sha256=$sidecar_hash" >&2
  exit 1
fi
if ! grep -qx 'target=x86_64-linux-gnu' zig-out/bin/buildinfo.txt; then
  echo "smoke-release: buildinfo.txt does not identify target=x86_64-linux-gnu" >&2
  exit 1
fi

# Attribution: the binary statically links Apache-2.0 zwasm, so the shipped
# artifact must carry the license texts (make release copies them).
for lic in LICENSE THIRD_PARTY.md; do
  test -s "zig-out/bin/$lic" || {
    echo "smoke-release: missing zig-out/bin/$lic beside the binary" >&2
    exit 1
  }
done

# Operator files: mode packs resolve as modes/<name>.toml from the server's CWD,
# the example configs are the documented starting point, and the AssignIds dump
# must sit flat beside the binary (maxdamage.zig tryMergeBundledAssignIds) or a
# --game-dir run without .blocks.nim silently loses the block id map.
for operator_file in zdtd.toml.example serverconfig.example.xml assignids_v314.embed.txt modes/default.toml; do
  test -s "zig-out/bin/$operator_file" || {
    echo "smoke-release: missing zig-out/bin/$operator_file in the release artifact" >&2
    exit 1
  }
done

# Dependency bill of materials: buildinfo.txt must name every pinned dependency
# hash from build.zig.zon so the artifact traces to its sources.
dep_bom="$(bash scripts/dep-bom.sh)"
while IFS= read -r dep; do
  if ! grep -qx "$dep" zig-out/bin/buildinfo.txt; then
    echo "smoke-release: buildinfo.txt does not record $dep" >&2
    exit 1
  fi
done <<< "$dep_bom"

# Standard SBOM: scanners need a machine-readable inventory, not only the
# human-oriented buildinfo lines. Verify that it names the pinned runtime and
# its Zig content hash before publishing the artifact.
sbom=zig-out/bin/zdtd.cdx.json
test -s "$sbom" || {
  echo "smoke-release: missing $sbom" >&2
  exit 1
}
grep -q '"bomFormat": "CycloneDX"' "$sbom"
grep -q '"name": "zwasm"' "$sbom"
zwasm_hash="${dep_bom#dep_zwasm=}"
grep -Fq "\"value\": \"$zwasm_hash\"" "$sbom"

# Startup smoke: bind sockets, run one tick, save, exit.
# Use zig-out (gitignored, disk-backed) rather than /tmp (tmpfs on some hosts).
smoke_world=zig-out/smoke-world
rm -rf "$smoke_world"
mkdir -p "$smoke_world"
trap 'rm -rf "$smoke_world"' EXIT
# High fixed port: avoids clashing with stock dedi 26902 and common local 27002.
smoke_port=27111
if ! timeout 15s "$bin" --port "$smoke_port" --world "$smoke_world" --once >"$smoke_world/once.log" 2>&1; then
  echo "smoke-release: --once failed; log:" >&2
  cat "$smoke_world/once.log" >&2 || true
  exit 1
fi
if ! grep -q 'zdtd --once complete' "$smoke_world/once.log"; then
  echo "smoke-release: --once did not print completion marker; log:" >&2
  cat "$smoke_world/once.log" >&2 || true
  exit 1
fi

echo "smoke-release: ok $bin (product $product, stock wire $wire)"
