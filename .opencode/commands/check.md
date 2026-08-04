---
description: Full validation gate (make check)
agent: build
---

Run the project validation gate from the repo root:

```bash
make check
```

That is, in order: `scripts/check-release.sh` (version/toolchain pin), `make lint`
(`zig fmt --check` + `scripts/lint-wire.sh`), `zig build`, `zig build test`,
`zig build fuzz`. Requires Zig matching `.zigversion` and `rg` on PATH.

Fix any compile, test, lint, or pin failures. Do not skip failing tests.
Prefer the smallest correct fix over drive-by refactors.
