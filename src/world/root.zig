//! World store layer: chunks, map data (DTM/prefabs/TTS), containers, TE state.
//!
//! Dependency direction: world may import util and assets. It may use pure
//! ecs component types (InvSlot) for inventory-shaped storage. It must not
//! import wire, server, or litenet (wire imports world for TE domain types).
//! Prefab `.blocks.nim` tables live in assets (catalog data); re-exported here
//! for stable `world.blocks_nim` import paths.

pub const store = @import("store.zig");
pub const containers = @import("containers.zig");
pub const workstations = @import("workstations.zig");
pub const dtm = @import("dtm.zig");
pub const dem = @import("dem.zig");
pub const prefabs = @import("prefabs.zig");
pub const sleepers = @import("sleepers.zig");
pub const tts = @import("tts.zig");
pub const water = @import("water.zig");
pub const biomes = @import("biomes.zig");
pub const worldgen = @import("worldgen.zig");
pub const noise = @import("noise.zig");
/// Prefab name map loader (owned by assets; re-export for stable path).
pub const blocks_nim = @import("../assets/blocks_nim.zig");

test {
    _ = store;
    _ = containers;
    _ = workstations;
    _ = dtm;
    _ = dem;
    _ = prefabs;
    _ = sleepers;
    _ = tts;
    _ = water;
    _ = biomes;
    _ = worldgen;
    _ = noise;
    _ = blocks_nim;
}
