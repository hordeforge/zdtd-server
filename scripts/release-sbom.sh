#!/usr/bin/env bash
# Emit the release component inventory as deterministic CycloneDX 1.6 JSON.
# Keep the explicit component metadata below in sync with THIRD_PARTY.md. The
# manifest count gate makes a newly added direct dependency fail closed until
# its license and package identity are reviewed here.
# The `pkg:github/...` purl version is a git tag, not the release number, so it
# carries the upstream `v` prefix; `pkg:generic/...` uses the bare version.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/zig-out/bin/zdtd.cdx.json}"

product="$(sed -n 's/^pub const product = "\([^"]*\)";/\1/p' "$ROOT/src/version.zig" | head -n1)"
zwasm_version="$(sed -n 's#^[[:space:]]*\.url = ".*/v\([0-9][0-9.]*\)\.tar\.gz",#\1#p' "$ROOT/build.zig.zon" | head -n1)"
zwasm_hash="$(sed -n 's/^[[:space:]]*\.hash = "\([^"]*\)",/\1/p' "$ROOT/build.zig.zon" | head -n1)"
dependency_count="$(awk '/^[[:space:]]*\.hash = "/ { n++ } END { print n + 0 }' "$ROOT/build.zig.zon")"

if [[ -z "$product" || -z "$zwasm_version" || -z "$zwasm_hash" ]]; then
  echo "release-sbom: could not resolve product or zwasm manifest metadata" >&2
  exit 1
fi
if [[ "$dependency_count" != 1 ]]; then
  echo "release-sbom: build.zig.zon has $dependency_count direct dependencies; review and add each component before release" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
sed \
  -e "s/@PRODUCT@/$product/g" \
  -e "s/@ZWASM_VERSION@/$zwasm_version/g" \
  -e "s/@ZWASM_HASH@/$zwasm_hash/g" > "$OUT" <<'EOF'
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.6",
  "version": 1,
  "metadata": {
    "component": {
      "type": "application",
      "bom-ref": "pkg:generic/zdtd@@PRODUCT@",
      "name": "zdtd",
      "version": "@PRODUCT@",
      "purl": "pkg:generic/zdtd@@PRODUCT@",
      "licenses": [{ "license": { "id": "MIT" } }]
    }
  },
  "components": [
    {
      "type": "library",
      "bom-ref": "pkg:github/clojurewasm/zwasm@v@ZWASM_VERSION@",
      "name": "zwasm",
      "version": "@ZWASM_VERSION@",
      "scope": "required",
      "licenses": [{ "license": { "id": "Apache-2.0" } }],
      "purl": "pkg:github/clojurewasm/zwasm@v@ZWASM_VERSION@",
      "externalReferences": [
        {
          "type": "distribution",
          "url": "https://github.com/clojurewasm/zwasm/archive/refs/tags/v@ZWASM_VERSION@.tar.gz"
        }
      ],
      "properties": [
        { "name": "zig:package-hash", "value": "@ZWASM_HASH@" }
      ]
    }
  ],
  "dependencies": [
    {
      "ref": "pkg:generic/zdtd@@PRODUCT@",
      "dependsOn": ["pkg:github/clojurewasm/zwasm@v@ZWASM_VERSION@"]
    },
    {
      "ref": "pkg:github/clojurewasm/zwasm@v@ZWASM_VERSION@",
      "dependsOn": []
    }
  ]
}
EOF
