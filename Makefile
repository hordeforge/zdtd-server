# zdtd build glue. Canonical validation: `make check`.
# Override toolchain: `make ZIG=/path/to/zig build`
# Release binary: `make release` (ReleaseSafe + strip + sha256 sidecar).

.PHONY: all build test fuzz run check lint fmt release-check release clean need-zig

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
# Writes zig-out/bin/zdtd.sha256 (hash of the binary only) for artifact integrity.
release: release-check need-zig
	$(ZIG) build -Doptimize=ReleaseSafe -Dstrip=true
	@bin=zig-out/bin/zdtd; \
	  test -f "$$bin" || { echo "zdtd: release build did not produce $$bin" >&2; exit 1; }; \
	  (cd zig-out/bin && sha256sum zdtd > zdtd.sha256); \
	  echo "zdtd: release ok $$(cut -d' ' -f1 zig-out/bin/zdtd.sha256)  $$bin"

lint: need-zig
	@command -v rg >/dev/null || { \
	  echo "zdtd: missing required tool: rg (ripgrep); apt/brew/cargo install ripgrep" >&2; \
	  exit 127; \
	}
	$(ZIG) fmt --check build.zig src
	bash scripts/lint-architecture.sh
	bash scripts/lint-wire.sh

fmt: need-zig
	$(ZIG) fmt build.zig src

release-check:
	bash scripts/check-release.sh

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

clean:
	rm -rf zig-out .zig-cache .zdtd_cfg_cache
