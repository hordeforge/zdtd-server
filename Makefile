# zdtd build glue. Canonical validation: `make check`.
# Override toolchain: `make ZIG=/path/to/zig build`
# Release binary: `make release` (ReleaseSafe + strip + sha256 sidecar).

.PHONY: all build test fuzz run check lint fmt release-check release repro smoke clean need-zig need-release-tools

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:

ZIG ?= zig
# Debug for day-to-day; ReleaseSafe for operator-facing binaries.
OPTIMIZE ?= Debug

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

all: build

build: need-zig
	$(ZIG) build -Doptimize=$(OPTIMIZE)

test: need-zig
	$(ZIG) build test -Doptimize=$(OPTIMIZE)

fuzz: need-zig
	$(ZIG) build fuzz -Doptimize=$(OPTIMIZE)

run: need-zig
	$(ZIG) build run -Doptimize=$(OPTIMIZE) -- $(ARGS)

# Operator-facing binary: safety checks on, debug symbols stripped.
# Depends on release-check so a version-drifted tree cannot produce a release binary.
# -Dcpu=baseline: without it Zig targets the build host's CPU features, so the
# artifact's bytes vary per build machine and can SIGILL on older operator CPUs.
# Writes zig-out/bin/zdtd.sha256 (hash of the binary only) and
# zig-out/bin/buildinfo.txt (toolchain + version + dependency pin + binary
# hash, timestamp-free so a same-source rebuild reproduces it byte-for-byte)
# for artifact integrity and a minimal dependency bill of materials.
release: release-check need-zig need-release-tools
	$(ZIG) build -Doptimize=ReleaseSafe -Dstrip=true -Dcpu=baseline
	@bin=zig-out/bin/zdtd; \
	  test -f "$$bin" || { echo "zdtd: release build did not produce $$bin" >&2; exit 1; }; \
	  (cd zig-out/bin && sha256sum zdtd > zdtd.sha256); \
	  product="$$(sed -n 's/^pub const product = "\([^"]*\)";/\1/p' src/version.zig | head -n1)"; \
	  wire="$$(sed -n 's/^pub const stock_wire = "\([^"]*\)";/\1/p' src/version.zig | head -n1)"; \
	  dep_zwasm="$$(sed -n 's/^[[:space:]]*\.hash = "\([^"]*\)",/\1/p' build.zig.zon | head -n1)"; \
	  { \
	    echo "product=$$product"; \
	    echo "stock_wire=$$wire"; \
	    echo "zig=$$("$(ZIG)" version)"; \
	    echo "optimize=ReleaseSafe"; \
	    echo "strip=true"; \
	    echo "cpu=baseline"; \
	    echo "binary_sha256=$$(cut -d' ' -f1 zig-out/bin/zdtd.sha256)"; \
	    echo "dep_zwasm=$$dep_zwasm"; \
	  } > zig-out/bin/buildinfo.txt; \
	  echo "zdtd: release ok $$(cut -d' ' -f1 zig-out/bin/zdtd.sha256)  $$bin"

lint: need-zig
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
	$(ZIG) fmt --check build.zig src
	bash scripts/lint-architecture.sh
	bash scripts/lint-wire.sh

fmt: need-zig
	$(ZIG) fmt build.zig src

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
	$(MAKE) build
	$(MAKE) test
	$(MAKE) fuzz

# Operator-binary smoke (CI after `make release`; also local release verification).
smoke: release
	bash scripts/smoke-release.sh

# Reproducibility gate (docs/RELEASES.md step 6): build the release config
# twice in independent cache trees and require byte-identical binaries.
# Depends on release-check so the pinned toolchain builds both halves.
# Deliberately NOT part of `make check`: it costs two full ReleaseSafe builds.
repro: release-check need-zig
	bash scripts/repro-release.sh

clean:
	rm -rf zig-out .zig-cache .zdtd_cfg_cache
