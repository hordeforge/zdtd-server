//! Unity Mono / .NET stable string hash (Extensions.GetStableHashCode).
//!
//! Used for EntityClass.list keys and TE feature name hashes. Leaf helper so
//! assets catalogs do not import wire body builders for a pure RE constant.

const std = @import("std");

/// Dual djb2-style 5381 streams over even/odd chars, then
/// `hash1 + hash2 * 1566083941` (signed i32). Verified: playerMale → 2001454542.
pub fn getStableHashCode(s: []const u8) i32 {
    var num: i32 = 5381;
    var num2: i32 = 5381;
    var i: usize = 0;
    while (true) {
        if (i >= s.len) break;
        const c0: i32 = s[i];
        num = ((num << 5) +% num) ^ c0;
        if (i + 1 >= s.len) break;
        const c1: i32 = s[i + 1];
        if (c1 == 0) break;
        num2 = ((num2 << 5) +% num2) ^ c1;
        i += 2;
        if (i >= s.len) break;
        if (s[i] == 0) break;
    }
    return num +% (num2 *% 1566083941);
}

/// Common EntityClass.list keys (stock names → Unity hash).
pub const class_player_male: i32 = getStableHashCode("playerMale");
pub const class_player_female: i32 = getStableHashCode("playerFemale");
pub const class_zombie_template_male: i32 = getStableHashCode("zombieTemplateMale");
pub const class_zombie_template_short: i32 = getStableHashCode("zombieShortTemplate");
pub const class_zombie_boe: i32 = getStableHashCode("zombieBoe");
pub const class_zombie_joe: i32 = getStableHashCode("zombieJoe");
pub const class_zombie_default: i32 = class_zombie_boe;
/// Trader NPC (EntityTrader). Stock trader POIs use npcTraderJen/Bob/Hugh/Joel/Rekt.
pub const class_npc_trader_jen: i32 = getStableHashCode("npcTraderJen");
pub const class_npc_trader_bob: i32 = getStableHashCode("npcTraderBob");
pub const class_npc_trader_hugh: i32 = getStableHashCode("npcTraderHugh");
pub const class_npc_trader_joel: i32 = getStableHashCode("npcTraderJoel");
pub const class_npc_trader_rekt: i32 = getStableHashCode("npcTraderRekt");
pub const class_dropped_loot_container: i32 = getStableHashCode("DroppedLootContainer");
/// Player death backpack (entityclasses.xml "Backpack", Class EntityBackpack).
/// Stock's client creates this from EntityPlayerLocal.dropBackpack and spawns
/// it via NetPackageRequestToSpawnEntity; the generic ground bag is
/// DroppedLootContainer (EntityLootContainer). Same mesh/prefab, different
/// class, and the server broadcasts whatever class it spawned.
pub const class_backpack: i32 = getStableHashCode("Backpack");
pub const class_entity_loot_container: i32 = getStableHashCode("EntityLootContainer");
pub const class_item: i32 = getStableHashCode("item");
pub const class_falling_tree: i32 = getStableHashCode("fallingTree");
pub const class_falling_block: i32 = getStableHashCode("fallingBlock");
pub const class_falling_blocks: i32 = getStableHashCode("fallingBlocks");
pub const class_junk_drone: i32 = getStableHashCode("entityJunkDrone");

test "stable hash goldens" {
    try std.testing.expectEqual(@as(i32, 731446478), getStableHashCode("TEFeatureStorage"));
    try std.testing.expectEqual(class_player_male, getStableHashCode("playerMale"));
    try std.testing.expectEqual(class_zombie_boe, getStableHashCode("zombieBoe"));
    // Entity class ids are Mono legacy String.GetHashCode; pin the two bag
    // classes so a change to the hash helper cannot move them together.
    try std.testing.expectEqual(@as(i32, -2021142581), class_dropped_loot_container);
    try std.testing.expectEqual(@as(i32, 84004336), class_backpack);
}
