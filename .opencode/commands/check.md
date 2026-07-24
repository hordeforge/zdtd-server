---
description: Build and run full zig test suite (make check)
agent: build
---

Run the project validation loop from the repo root:

```bash
make check
```

That is `zig build` then `zig build test`. Fix any compile or test failures. Do not skip failing tests. Prefer the smallest correct fix over drive-by refactors.
