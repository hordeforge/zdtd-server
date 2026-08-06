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

/// Alias used by entity catalog / spawn class resolution.
pub const unityStringHash = getStableHashCode;

/// Common EntityClass.list keys (stock names → Unity hash).
pub const class_player_male: i32 = unityStringHash("playerMale");
pub const class_player_female: i32 = unityStringHash("playerFemale");
pub const class_zombie_template_male: i32 = unityStringHash("zombieTemplateMale");
pub const class_zombie_template_short: i32 = unityStringHash("zombieShortTemplate");
pub const class_zombie_boe: i32 = unityStringHash("zombieBoe");
pub const class_zombie_joe: i32 = unityStringHash("zombieJoe");
pub const class_zombie_default: i32 = class_zombie_boe;
/// Trader NPC (EntityTrader). Stock trader POIs use npcTraderJen/Bob/Hugh/Joel/Rekt.
pub const class_npc_trader_jen: i32 = unityStringHash("npcTraderJen");
pub const class_dropped_loot_container: i32 = unityStringHash("DroppedLootContainer");
pub const class_entity_loot_container: i32 = unityStringHash("EntityLootContainer");
pub const class_item: i32 = unityStringHash("item");
pub const class_falling_tree: i32 = unityStringHash("fallingTree");
pub const class_falling_block: i32 = unityStringHash("fallingBlock");
pub const class_falling_blocks: i32 = unityStringHash("fallingBlocks");
pub const class_junk_drone: i32 = unityStringHash("entityJunkDrone");

test "stable hash goldens" {
    try std.testing.expectEqual(@as(i32, 731446478), getStableHashCode("TEFeatureStorage"));
    try std.testing.expectEqual(class_player_male, unityStringHash("playerMale"));
    try std.testing.expectEqual(class_zombie_boe, unityStringHash("zombieBoe"));
}
