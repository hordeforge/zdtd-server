# ADR 0006: Steal patterns from Mach (not the engine)

- **Status:** accepted
- **Date:** 2026-07-22

## Context

[Mach](https://code.hexops.org/hexops/mach) ([machengine.org](https://machengine.org))
is a Zig game engine / graphics toolkit: modules, objects, GPU, audio, windowing.
zdtd is a headless dedicated server with stock 7DTD wire. Pulling Mach as a
dependency would drag sysgpu/core UI and fight our tick model. Mach still has
**library-quality patterns** worth copying in-tree.

Surveyed surfaces (Mach `main` / 0.4 line):

| Mach piece | Role |
|---|---|
| `module.zig` `Mod` / `Modules` / `schedule` | Comptime module fn tables; ordered schedules |
| `Objects` + `ObjectID` | Gen-ish packed ids; field `updated()` tracking |
| `mpsc.zig` | Lock-free MPSC queue + chunked node pool |
| `graph.zig` | Parent/child ops via MPSC; single consumer thread |
| `std.Io` async/concurrent on `Mod` | `async` / `concurrent` / group variants |
| `dynLibOpen` | Friendly multi-name `.so` open errors |
| `time.Frequency` / `Timer` | Tick pacing helpers |
| `testing.zig` expect float helpers | Nice-to-have for math tests |
| gfx / sysgpu / Core window | **Irrelevant** to dedi |

## Decision

1. **Do not** add Mach (or mach-core/sysgpu) as a zdtd dependency.
2. **Do** steal and reimplement small pieces under `src/util/` or `src/plugin/`
   as needed (see Consequences / TODO).
3. Prefer Mach’s **explicit schedules** and **MPSC + single consumer** over
   Bevy-style auto access-set parallelism (consistent with ADR 0002).

## What to steal (priority)

### High (fits current scale / plugin / net plans)

| Pattern | Use in zdtd |
|---|---|
| **MPSC + pooled nodes** | C2S parsed messages from poll thread → tick apply; S2C job results; plugin async results; guard evidence flush |
| **Op queue / single consumer** (graph idea) | World or interest mutations from workers: enqueue op, main tick drains |
| **`schedule` as ordered fn list** | Document `tickAll` + plugin phase hooks as data; optional comptime validate list |
| **Field/object dirty (`updated`)** | Per-entity or per-field dirty for serialize-once interest (manual mark API) |
| **`dynLibOpen` style** | Future plugin `.so` load with clear “tried these names” errors |
| **Friendly module boundary** | `src/plugin` and `src/guard` as modules with explicit exported systems list |

### Medium

| Pattern | Use in zdtd |
|---|---|
| Packed **ObjectID** (index+gen+type) | Internal handles if slot reuse becomes unsafe; **net id stays i32 wire** |
| **sliceDeleted** / deferred free | Entity despawn: mark dead mid-tick, free at tick end |
| **Measured prealloc** (queue sizes) | Named caps already required; init-time size from config |
| **Frequency** helper | Main loop sleep / catch-up accounting next to 50 ms tick |
| **RW lock on cold structures** | Read-mostly catalogs; not on SoA hot columns |

### Low / skip

| Pattern | Why skip |
|---|---|
| Full `Mod.call` / object ECS | We keep SoA + net map (ADR 0002) |
| GPU, audio, window Core | Headless dedi |
| Parent/child scene graph | Stock entities are flat net ids |
| Mach editor / libmach | Out of scope |

## Consequences

- Small in-tree `util/mpsc.zig` (or equivalent) unblocks multi-thread edges without Mach.
- Plugin API (ADR 0005) can use MPSC for `async_ok` hooks.
- No engine lock-in; copy code we understand under our license/tree.
- Must not paste huge Mach modules blindly; port minimal subsets with tests.

## Alternatives

| Option | Notes |
|---|---|
| Depend on mach as package | Wrong product shape; Zig version coupling; binary bloat |
| Depend only on a future mach-mpsc split | Does not exist as stable tiny crate; copy is fine |
| std only | Fine for pool; MPSC still worth a focused file |
