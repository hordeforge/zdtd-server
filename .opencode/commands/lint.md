---
description: Run wire/style lint (make lint)
agent: build
---

From the repo root run:

```bash
make lint
```

This is a ripgrep-based lint (ast-grep has no Zig AST). Fix real findings. Test-only fixtures may use fixed package ids; production send/receive paths must resolve ids via the negotiated name map.
