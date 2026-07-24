---
description: Build and run zdtd with default flat world
agent: build
---

Build and start the server for local smoke testing:

```bash
zig build
zig-out/bin/zdtd --port 27002 --world worlds/zdtd_default
```

If the user asked for a stock map, use `--game-dir` and `--world-name` / `--map` per AGENTS.md. Do not leave a long-running process hanging without saying how to stop it.
