# zdtd build glue. Canonical validation: `make check`.
# Override toolchain: `make ZIG=/path/to/zig build`
# Release binary: `make release` (ReleaseSafe + strip).

.PHONY: all build test fuzz run check lint release-check release clean

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:

ZIG ?= zig
# Debug for day-to-day; ReleaseSafe for operator-facing binaries.
OPTIMIZE ?= Debug

all: build

build:
	@command -v "$(ZIG)" >/dev/null || { echo "zdtd: missing Zig compiler '$(ZIG)' (need >= build.zig.zon minimum_zig_version)" >&2; exit 127; }
	$(ZIG) build -Doptimize=$(OPTIMIZE)

test:
	@command -v "$(ZIG)" >/dev/null || { echo "zdtd: missing Zig compiler '$(ZIG)'" >&2; exit 127; }
	$(ZIG) build test -Doptimize=$(OPTIMIZE)

fuzz:
	@command -v "$(ZIG)" >/dev/null || { echo "zdtd: missing Zig compiler '$(ZIG)'" >&2; exit 127; }
	$(ZIG) build fuzz -Doptimize=$(OPTIMIZE)

run:
	@command -v "$(ZIG)" >/dev/null || { echo "zdtd: missing Zig compiler '$(ZIG)'" >&2; exit 127; }
	$(ZIG) build run -Doptimize=$(OPTIMIZE) -- $(ARGS)

# Operator-facing binary: safety checks on, debug symbols stripped.
# Depends on release-check so a version-drifted tree cannot produce a release binary.
release: release-check
	@command -v "$(ZIG)" >/dev/null || { echo "zdtd: missing Zig compiler '$(ZIG)'" >&2; exit 127; }
	$(ZIG) build -Doptimize=ReleaseSafe -Dstrip=true

lint:
	bash scripts/lint-wire.sh

release-check:
	bash scripts/check-release.sh

# Full local gate (same intent as a clean CI job): version pin, wire lint, build, tests, fuzz.
# Lint first so missing tools / style findings fail before a multi-minute Zig build.
check: release-check lint build test fuzz

clean:
	rm -rf zig-out .zig-cache .zdtd_cfg_cache
