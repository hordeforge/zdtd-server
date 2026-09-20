//! Per-entity custom variables (CVars): facade over `../ecs/cvars.zig`.
//!
//! The type and its `EntityBuffs` IL semantics live in ecs, because the World
//! carries the per-entity column and ecs may not import assets
//! (`scripts/lint-architecture.sh`). This re-export keeps the `assets.cvars`
//! path every assets-side CVar gate already imports.

const store = @import("../ecs/cvars.zig");

pub const max_cvars = store.max_cvars;
pub const Operation = store.Operation;
pub const CVar = store.CVar;
pub const Set = store.Set;
