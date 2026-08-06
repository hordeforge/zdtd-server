//! World store layer: chunks, map data (DTM/prefabs/TTS), containers, TE state.
//!
//! Dependency direction: world may import util and assets. It may use pure
//! ecs component types (InvSlot) for inventory-shaped storage. It must not
//! import wire, server, or litenet (wire imports world for TE domain types).
//! Prefab `.blocks.nim` lives in `assets/blocks_nim.zig` (import assets, not here).

pub const store = @import("store.zig");
pub const chunk_flush = @import("chunk_flush.zig");
pub const terrain_snapshot = @import("terrain_snapshot.zig");
pub const containers = @import("containers.zig");
pub const workstations = @import("workstations.zig");
pub const dtm = @import("dtm.zig");
pub const dem = @import("dem.zig");
pub const prefabs = @import("prefabs.zig");
pub const sleepers = @import("sleepers.zig");
pub const tts = @import("tts.zig");
pub const water = @import("water.zig");
pub const biomes = @import("biomes.zig");
pub const weather = @import("weather.zig");
pub const worldgen = @import("worldgen.zig");
pub const noise = @import("noise.zig");
pub const deco_mirror = @import("deco_mirror.zig");

test {
    _ = store;
    _ = chunk_flush;
    _ = terrain_snapshot;
    _ = containers;
    _ = workstations;
    _ = dtm;
    _ = dem;
    _ = prefabs;
    _ = sleepers;
    _ = tts;
    _ = water;
    _ = biomes;
    _ = weather;
    _ = worldgen;
    _ = noise;
    _ = deco_mirror;
}
