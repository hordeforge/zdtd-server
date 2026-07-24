//! Stock game config asset loaders (quests, blocks, items, …).

pub const xml_util = @import("xml_util.zig");
pub const quests = @import("quests.zig");
pub const blocks = @import("blocks.zig");
pub const items = @import("items.zig");
pub const signs = @import("signs.zig");
pub const entities = @import("entities.zig");
pub const recipes = @import("recipes.zig");
pub const loot = @import("loot.zig");
pub const entitygroups = @import("entitygroups.zig");
pub const maxdamage = @import("maxdamage.zig");
pub const traders = @import("traders.zig");

test {
    _ = xml_util;
    _ = quests;
    _ = blocks;
    _ = items;
    _ = signs;
    _ = entities;
    _ = recipes;
    _ = loot;
    _ = entitygroups;
    _ = maxdamage;
}
