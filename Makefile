# zdtd build glue. Canonical validation: `make check`.
# Override toolchain: `make ZIG=/path/to/zig build`
# Release binary: `make release` (ReleaseSafe + strip + sha256 sidecar).

.PHONY: all build test fuzz run check check-clean-build lint lint-webui lint-html webui-ts fmt release-check release repro smoke smoke-modlet clean need-zig need-release-tools need-python3 need-oxlint need-java check-xml-audit

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:

ZIG ?= zig
# Debug for day-to-day; ReleaseSafe for operator-facing binaries.
OPTIMIZE ?= Debug
# The published artifact is named linux-x86_64 in CI, so do not let the
# machine running `make release` silently choose a different target ABI.
RELEASE_TARGET ?= x86_64-linux-gnu

# Shared missing-compiler check (used by every target that invokes Zig).
need-zig:
	@command -v "$(ZIG)" >/dev/null || { \
	  echo "zdtd: missing Zig compiler '$(ZIG)' (need exact pin from .zigversion; see build.zig.zon minimum_zig_version)" >&2; \
	  exit 127; \
	}

# Fail before compiling if the release integrity sidecar cannot be produced.
need-release-tools:
	@command -v sha256sum >/dev/null || { \
	  echo "zdtd: missing required release tool: sha256sum (GNU coreutils)" >&2; \
	  exit 127; \
	}

# Required by `make check` for tools/provenance_scan.py (stdlib-only, no pip deps).
need-python3:
	@command -v python3 >/dev/null || { \
	  echo "zdtd: missing required tool: python3 (for tools/provenance_scan.py)" >&2; \
	  exit 127; \
	}

# Webui JS gate: tsc type-check + oxlint over src/server/webui/ts, then page
# freshness (scripts/lint-webui.sh). tsc/oxlint run through bunx (version pins:
# scripts/lint-webui.sh, scripts/build-webui-ts.sh).
need-oxlint:
	@command -v bunx >/dev/null || { \
	  echo "zdtd: missing required tool: bunx (bun; for the webui TS/JS lint)" >&2; \
	  exit 127; \
	}

lint-webui: need-oxlint need-python3
	bash scripts/lint-webui.sh

# Rebuild every committed plugin .wasm from its source (mods/BUILDING.md).
# After changing a plugin, run this and commit both source and binary.
plugins: need-zig
	bash scripts/build-plugins.sh

# Regenerate the committed webui pages from the TS sources (tsc + marker
# splice); `make lint` fails when the committed pages are stale.
webui-ts: need-oxlint need-python3
	bash scripts/build-webui-ts.sh

# vnu (Nu HTML Checker) over all repo HTML + embedded CSS (version pin: scripts/lint-html.sh).
need-java:
	@command -v java >/dev/null || { \
	  echo "zdtd: missing required tool: java (JRE; for the vnu HTML checker)" >&2; \
	  exit 127; \
	}

lint-html: need-oxlint need-java
	bash scripts/lint-html.sh

all: build

build: need-zig
	$(ZIG) build -Doptimize=$(OPTIMIZE)

# Clean-cache exe build gate. `zig build` with a warm cache can reuse stale
# objects for untouched files, and `zig build test` does not analyze every
# lazy path the exe graph does, so a latent exe compile error (e.g. a stale
# field path after a struct refactor) can pass both. A fresh cache dir forces
# the whole graph to recompile. Run before trusting a `make check` green with
# a long-lived cache. Note: this is intentionally NOT in `check` - a WIP that
# is mid-refactor goes red here, which is the point.
check-clean-build: need-zig
	rm -rf .zig-cache-check
	$(ZIG) build -Doptimize=$(OPTIMIZE) --cache-dir .zig-cache-check
	rm -rf .zig-cache-check

test: need-zig
	$(ZIG) build test -Doptimize=$(OPTIMIZE)

fuzz: need-zig
	$(ZIG) build fuzz -Doptimize=$(OPTIMIZE)

run: need-zig
	$(ZIG) build run -Doptimize=$(OPTIMIZE) -- $(ARGS)

# Operator-facing binary: safety checks on, debug symbols stripped.
# Depends on release-check so a version-drifted tree cannot produce a release binary.
# The build configuration (optimize/strip/target/cpu plus the normalized locale,
# timezone and source epoch) lives in scripts/release-build.sh, which
# scripts/repro-release.sh also uses, so the reproducibility gate always
# validates exactly what ships.
# Writes zig-out/bin/zdtd.sha256 (hash of the binary only) and
# zig-out/bin/buildinfo.txt (toolchain + version + dependency pin + binary
# hash, timestamp-free so a same-source rebuild reproduces it byte-for-byte)
# for artifact integrity and a minimal dependency bill of materials.
# Copies LICENSE + THIRD_PARTY.md beside the binary: zwasm is Apache-2.0 and
# statically linked, and section 4(a) requires recipients of the binary to get
# the license text (THIRD_PARTY.md carries it). The example configs and the
# preset packs ride along too: the server resolves presets/<name>.toml relative
# to its CWD, so an artifact without them cannot honour [preset] name.
# assignids_v314.embed.txt rides along flat beside the binary: without it a
# --game-dir run with no .blocks.nim has no AssignIds map and silently falls
# back to band defaults (src/assets/maxdamage.zig tryMergeBundledAssignIds).
release: release-check need-zig need-release-tools
	ZIG="$(ZIG)" RELEASE_TARGET="$(RELEASE_TARGET)" bash scripts/release-build.sh
	@bin=zig-out/bin/zdtd; \
	  test -f "$$bin" || { echo "zdtd: release build did not produce $$bin" >&2; exit 1; }; \
	  (cd zig-out/bin && sha256sum zdtd > zdtd.sha256); \
	  product="$$(sed -n 's/^pub const product = "\([^"]*\)";/\1/p' src/version.zig | head -n1)"; \
	  wire="$$(sed -n 's/^pub const stock_wire = "\([^"]*\)";/\1/p' src/version.zig | head -n1)"; \
	  dep_bom="$$(bash scripts/dep-bom.sh)" || exit 1; \
	  { \
	    echo "product=$$product"; \
	    echo "stock_wire=$$wire"; \
	    echo "zig=$$("$(ZIG)" version)"; \
	    echo "optimize=ReleaseSafe"; \
	    echo "strip=true"; \
	    echo "target=$(RELEASE_TARGET)"; \
	    echo "cpu=baseline"; \
	    echo "binary_sha256=$$(cut -d' ' -f1 zig-out/bin/zdtd.sha256)"; \
	    echo "$$dep_bom"; \
	  } > zig-out/bin/buildinfo.txt; \
	  bash scripts/release-sbom.sh zig-out/bin/zdtd.cdx.json; \
	  cp -f LICENSE THIRD_PARTY.md zdtd.toml.example serverconfig.example.xml zig-out/bin/; \
	  cp -f src/assets/assignids_v314.embed.txt zig-out/bin/; \
	  rm -rf zig-out/bin/presets && cp -r presets zig-out/bin/presets; \
	  echo "zdtd: release ok $$(cut -d' ' -f1 zig-out/bin/zdtd.sha256)  $$bin"

lint: need-zig lint-webui lint-html
	@command -v rg >/dev/null || { \
	  echo "zdtd: missing required tool: rg (ripgrep); apt/brew/cargo install ripgrep" >&2; \
	  exit 127; \
	}
	@command -v shellcheck >/dev/null || { \
	  echo "zdtd: missing required tool: shellcheck; apt/brew install shellcheck" >&2; \
	  exit 127; \
	}
	bash -n scripts/*.sh
	shellcheck scripts/*.sh
	$(ZIG) fmt --check build.zig build.zig.zon src
	bash scripts/lint-architecture.sh
	bash scripts/lint-cycles.sh
	bash scripts/lint-wire.sh

fmt: need-zig
	$(ZIG) fmt build.zig build.zig.zon src

# Pass ZIG explicitly: make variables are not exported to recipe environments,
# so `make ZIG=/path/zig release` must validate the same compiler it builds with.
release-check:
	ZIG="$(ZIG)" bash scripts/check-release.sh

# Full local gate (same intent as a clean CI job): version pin, wire lint, build, tests, fuzz.
# Recipe form (not a multi-prereq list) so `make -j check` cannot race concurrent
# `zig build` / `zig build test` / `zig build fuzz` against the same cache.
# Order: release-check → lint → build → test → fuzz. Lint before multi-minute Zig work.
check:
	$(MAKE) release-check
	$(MAKE) lint
	$(MAKE) need-python3
	# Syntax-compile every repo Python source (stdlib ast gate): provenance_scan
	# and check_xml_audit are executed below anyway, but gen_provenance.py never
	# runs in check, so a syntax error there would otherwise land unseen.
	python3 -m py_compile tools/*.py scripts/gen_provenance.py
	python3 tools/provenance_scan.py
	# Dashboard freshness gate: gen_provenance.py regenerates docs/provenance.html
	# from the live GAP_ANALYSIS markers; fail when the committed page is stale
	# (regenerate and commit it with the doc change). Same pattern as the webui
	# page-freshness gate in lint-webui.sh.
	python3 scripts/gen_provenance.py >/dev/null
	if git rev-parse --git-dir >/dev/null 2>&1; then \
	  git diff --quiet -- docs/provenance.html || { \
	    echo "make check: docs/provenance.html is stale (run python3 scripts/gen_provenance.py and commit the regenerated page)" >&2; \
	    exit 1; \
	  }; \
	fi
	$(MAKE) check-xml-audit
	$(MAKE) build
	$(MAKE) test
	$(MAKE) fuzz

# Deterministic XML-data hardcode audit (docs/XML_DATA_AUDIT.md): every
# Data/Config/*.xml must be covered by the audit doc, and no stock-name literal
# may appear in non-loader/non-wire/non-test code outside the script allowlist.
# Skips with a notice when the operator's game dir is absent (CI without a
# 7DTD install).
check-xml-audit: need-python3
	python3 tools/check_xml_audit.py

# Operator-binary smoke (CI after `make release`; also local release verification).
smoke: release
	bash scripts/smoke-release.sh

# Modlet smoke: boot on a scratch game-dir with the fixture modlet, verify the
# modlet scan + patched-config S2C cache, then the loadgen join when available.
smoke-modlet: build
	bash scripts/smoke-modlet.sh

# Reproducibility gate (docs/RELEASES.md step 6): build the release config
# twice in independent cache trees and require byte-identical binaries.
# Depends on release-check so the pinned toolchain builds both halves.
# Deliberately NOT part of `make check`: it costs two full ReleaseSafe builds.
repro: release-check need-zig
	RELEASE_TARGET="$(RELEASE_TARGET)" bash scripts/repro-release.sh

clean:
	rm -rf zig-out .zig-cache .zdtd_cfg_cache
