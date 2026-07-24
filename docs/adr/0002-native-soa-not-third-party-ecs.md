# ADR 0002: Native SoA ECS, not a third-party ECS core

- **Status:** accepted
- **Date:** 2026-07-22

## Context

Zig ECS options (mr_ecs, knoedel, ecez, zig-ecs/Entt, zflecs) offer archetypes,
auto-parallel schedules, command buffers, and Bevy-like APIs. zdtd already has
dense SoA, fixed entity slots, stable net ids, explicit `tickAll` order, and
wire/join ownership outside the ECS crate.

## Decision

- **Sim storage stays in-tree** (`src/ecs/`): dense SoA + mask bits + resources.
- **Do not** depend on knoedel, Flecs/zflecs, mr_ecs, ecez, or zig-ecs as the
  entity store or system scheduler.
- **May steal patterns** (command buffer, Res helpers, dirty bits, pool jobs)
  implemented locally; see TODO P3 and ECS survey.

## Consequences

- Deterministic phase order and net-id stability stay under our control.
- No archetype migration cost on spawn/despawn hot paths.
- We own bugs and Zig 0.16 breakage; we also own all ECS features.
- Scale work is partition + serialize-once, not “switch ECS.”

## Alternatives considered

| Option | Rejected because |
|---|---|
| mr_ecs / knoedel as core | Archetype + scheduler vs seed-stable explicit phases |
| zflecs | C runtime, query language, product surface mismatch |
| MultiArrayList only | Already SoA-shaped; need net map, systems, resources |
