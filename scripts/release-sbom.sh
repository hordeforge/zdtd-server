#!/usr/bin/env bash
# Emit the release component inventory as deterministic CycloneDX 1.6 JSON.
# Keep the explicit component metadata below in sync with THIRD_PARTY.md. The
# manifest count gate makes a newly added direct dependency fail closed until
# its license and package identity are reviewed here; the webui pin gate does
# the same for every pin in scripts/webui-ts-project.sh, whose code is bundled
# into the pages embedded in the binary.
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

# The webui JS toolchain ships inside the binary: preact, clsx, tailwind-merge
# and class-variance-authority are bundled into the embedded pages, and
# tailwindcss compiles the CSS spliced into them. Versions come from the pins in
# scripts/webui-ts-project.sh, the single source of truth.
# shellcheck source=scripts/webui-ts-project.sh
. "$ROOT/scripts/webui-ts-project.sh"

# Every pin in the webui project must be inventoried below, so a new package
# fails closed until its license and identity are reviewed here.
while read -r pin; do
  grep -qF "$pin" "$0" || {
    echo "release-sbom: webui pin $pin has no component entry; add it with its license" >&2
    exit 1
  }
done < <(sed -n 's/^webui_ts_\([a-z_0-9]*\)_version=.*/webui_ts_\1_version/p' "$ROOT/scripts/webui-ts-project.sh")

webui_components() {
  cat <<JSON
    {
      "type": "library",
      "bom-ref": "pkg:npm/preact@$webui_ts_preact_version",
      "name": "preact",
      "version": "$webui_ts_preact_version",
      "scope": "required",
      "licenses": [{ "license": { "id": "MIT" } }],
      "purl": "pkg:npm/preact@$webui_ts_preact_version"
    },
    {
      "type": "library",
      "bom-ref": "pkg:npm/clsx@$webui_ts_clsx_version",
      "name": "clsx",
      "version": "$webui_ts_clsx_version",
      "scope": "required",
      "licenses": [{ "license": { "id": "MIT" } }],
      "purl": "pkg:npm/clsx@$webui_ts_clsx_version"
    },
    {
      "type": "library",
      "bom-ref": "pkg:npm/tailwind-merge@$webui_ts_tailwind_merge_version",
      "name": "tailwind-merge",
      "version": "$webui_ts_tailwind_merge_version",
      "scope": "required",
      "licenses": [{ "license": { "id": "MIT" } }],
      "purl": "pkg:npm/tailwind-merge@$webui_ts_tailwind_merge_version"
    },
    {
      "type": "library",
      "bom-ref": "pkg:npm/class-variance-authority@$webui_ts_cva_version",
      "name": "class-variance-authority",
      "version": "$webui_ts_cva_version",
      "scope": "required",
      "licenses": [{ "license": { "id": "Apache-2.0" } }],
      "purl": "pkg:npm/class-variance-authority@$webui_ts_cva_version"
    },
    {
      "type": "library",
      "bom-ref": "pkg:npm/tailwindcss@$webui_ts_tailwind_version",
      "name": "tailwindcss",
      "version": "$webui_ts_tailwind_version",
      "scope": "required",
      "licenses": [{ "license": { "id": "MIT" } }],
      "purl": "pkg:npm/tailwindcss@$webui_ts_tailwind_version",
      "properties": [{ "name": "zdtd:linkage", "value": "compiled CSS embedded in the webui pages" }]
    },
    {
      "type": "library",
      "bom-ref": "pkg:npm/%40tailwindcss/cli@$webui_ts_tailwind_version",
      "name": "@tailwindcss/cli",
      "version": "$webui_ts_tailwind_version",
      "scope": "optional",
      "licenses": [{ "license": { "id": "MIT" } }],
      "purl": "pkg:npm/%40tailwindcss/cli@$webui_ts_tailwind_version",
      "properties": [{ "name": "zdtd:linkage", "value": "build-time only; drives the pinned tailwindcss" }]
    }
JSON
}

webui_depends_on() {
  printf '"pkg:npm/preact@%s",\n        "pkg:npm/clsx@%s",\n        "pkg:npm/tailwind-merge@%s",\n        "pkg:npm/class-variance-authority@%s",\n        "pkg:npm/tailwindcss@%s",\n        "pkg:npm/%%40tailwindcss/cli@%s"' \
    "$webui_ts_preact_version" "$webui_ts_clsx_version" "$webui_ts_tailwind_merge_version" \
    "$webui_ts_cva_version" "$webui_ts_tailwind_version" "$webui_ts_tailwind_version"
}

webui_leaves() {
  for ref in \
    "pkg:npm/preact@$webui_ts_preact_version" \
    "pkg:npm/clsx@$webui_ts_clsx_version" \
    "pkg:npm/tailwind-merge@$webui_ts_tailwind_merge_version" \
    "pkg:npm/class-variance-authority@$webui_ts_cva_version" \
    "pkg:npm/tailwindcss@$webui_ts_tailwind_version" \
    "pkg:npm/%40tailwindcss/cli@$webui_ts_tailwind_version"; do
    printf '    { "ref": "%s", "dependsOn": [] },\n' "$ref"
  done
}

mkdir -p "$(dirname "$OUT")"
{
  cat <<EOF
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.6",
  "version": 1,
  "metadata": {
    "component": {
      "type": "application",
      "bom-ref": "pkg:generic/zdtd@$product",
      "name": "zdtd",
      "version": "$product",
      "purl": "pkg:generic/zdtd@$product",
      "licenses": [{ "license": { "id": "MIT" } }]
    }
  },
  "components": [
    {
      "type": "library",
      "bom-ref": "pkg:github/clojurewasm/zwasm@v$zwasm_version",
      "name": "zwasm",
      "version": "$zwasm_version",
      "scope": "required",
      "licenses": [{ "license": { "id": "Apache-2.0" } }],
      "purl": "pkg:github/clojurewasm/zwasm@v$zwasm_version",
      "externalReferences": [
        {
          "type": "distribution",
          "url": "https://github.com/clojurewasm/zwasm/archive/refs/tags/v$zwasm_version.tar.gz"
        }
      ],
      "properties": [
        { "name": "zig:package-hash", "value": "$zwasm_hash" }
      ]
    },
$(webui_components)
  ],
  "dependencies": [
    {
      "ref": "pkg:generic/zdtd@$product",
      "dependsOn": [
        "pkg:github/clojurewasm/zwasm@v$zwasm_version",
        $(webui_depends_on)
      ]
    },
    {
      "ref": "pkg:github/clojurewasm/zwasm@v$zwasm_version",
      "dependsOn": []
    },
$(webui_leaves | sed '$ s/,$//')
  ]
}
EOF
} > "$OUT"
