# Contributing

Runnable path from a clean clone to a change you can open as a PR. Standing
rules live in [AGENTS.md](AGENTS.md); status in [docs/STATUS.md](docs/STATUS.md).

## Setup

1. Linux, GNU Make, Bash, and the exact Zig version in [`.zigversion`](.zigversion)
   (`build.zig.zon` `minimum_zig_version` must match).
2. For `make check` (what CI validate runs), also install the tools listed under
   **Build** in [README.md](README.md): Python 3.10+, `rg`, ShellCheck, Bun from
   [`.bun-version`](.bun-version), Node.js, Java, curl, tar/gzip, and `sha256sum`
   for `make release`.
3. From the repo root, list the day-to-day targets:

```bash
make help
```

First `zig build` needs network once to fetch the pinned `zwasm` dependency
(`build.zig.zon`).

## Edit-test loop

```bash
make                          # Debug binary → zig-out/bin/zdtd
make test-one FILTER='name'   # substring filter; still runs CLI + plugin-helper tests
make test                     # full unit + scenario suite
make check && make smoke      # CI validate + release smoke
```

How-tos for common edits (C2S handler, stock package body, scenario, plugin,
tunable, doc page): [docs/cookbook/](docs/cookbook/README.md).

## Pull requests

Run `make check && make smoke` before opening a PR. Tag releases also run
`make repro` ([docs/RELEASES.md](docs/RELEASES.md)). Prefer a focused filter
while editing; do not skip the unfiltered suite before you push.
