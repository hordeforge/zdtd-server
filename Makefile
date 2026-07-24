.PHONY: all build test run check lint clean

all: build

build:
	zig build

test:
	zig build test

run:
	zig build run

lint:
	bash scripts/lint-wire.sh

check: build test lint

clean:
	rm -rf zig-out .zig-cache
