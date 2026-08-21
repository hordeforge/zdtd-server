//! Stock game config asset loaders (quests, blocks, items, …).
//!
//! Dependency direction: may import util and pure ecs types (QuestKind,
//! InvSlot, Kind) for catalog → sim mapping. Must not import world, server,
//! or wire. ecs must not import this package (keeps assets→ecs one-way).
//! Wire body builders belong in wire/ (SignData batch encode lives in
//! wire/stock_sign.zig).

pub const xml_util = @import("xml_util.zig");
pub const unity_hash = @import("unity_hash.zig");
pub const quests = @import("quests.zig");
pub const blocks = @import("blocks.zig");
pub const items = @import("items.zig");
pub const signs = @import("signs.zig");
pub const entities = @import("entities.zig");
pub const recipes = @import("recipes.zig");
pub const loot = @import("loot.zig");
pub const entitygroups = @import("entitygroups.zig");
pub const gamestages = @import("gamestages.zig");
pub const maxdamage = @import("maxdamage.zig");
pub const traders = @import("traders.zig");
pub const npc = @import("npc.zig");
pub const assignids_comptime = @import("assignids_comptime.zig");
pub const biome_layers = @import("biome_layers.zig");
pub const block_textures = @import("block_textures.zig");
pub const painting = @import("painting.zig");
pub const spawning = @import("spawning.zig");
pub const buffs = @import("buffs.zig");
pub const progression = @import("progression.zig");
pub const vehicles = @import("vehicles.zig");
pub const storage_pairs = @import("storage_pairs.zig");
pub const paths = @import("paths.zig");
pub const xml_patch = @import("xml_patch.zig");
pub const blocks_nim = @import("blocks_nim.zig");
pub const sandbox = @import("sandbox.zig");
pub const sandbox_data = @import("sandbox_data.zig");

test {
    _ = xml_util;
    _ = unity_hash;
    _ = quests;
    _ = blocks;
    _ = items;
    _ = signs;
    _ = entities;
    _ = recipes;
    _ = loot;
    _ = entitygroups;
    _ = gamestages;
    _ = maxdamage;
    _ = traders;
    _ = npc;
    _ = assignids_comptime;
    _ = biome_layers;
    _ = block_textures;
    _ = painting;
    _ = spawning;
    _ = buffs;
    _ = progression;
    _ = vehicles;
    _ = storage_pairs;
    _ = paths;
    _ = xml_patch;
    _ = blocks_nim;
    _ = sandbox;
    _ = sandbox_data;
}
