//! Stock EntityCreationData + NetPackageEntitySpawn (networkWrite=true).
//! Minimal zombie/NPC path (not item/falling/player specials).

const std = @import("std");
const binary = @import("binary.zig");
const stock_inv = @import("stock_inv.zig");

/// EntityClass.list keys are `name.GetHashCode()` (Unity Mono / .NET string hash),
/// not XML order and not modern randomized .NET hashes.
/// Algorithm: dual djb2-style 5381 streams over even/odd chars, then
/// `hash1 + hash2 * 1566083941` (signed i32). Verified client-side:
/// playerMale → 2001454542 (EntityClass.list after Init).
pub fn unityStringHash(s: []const u8) i32 {
    // Same as Extensions.GetStableHashCode / Mono string.GetHashCode for ASCII.
    return @import("stock_te.zig").getStableHashCode(s);
}

pub const class_player_male: i32 = unityStringHash("playerMale");
pub const class_player_female: i32 = unityStringHash("playerFemale");
/// Template-only (Mesh empty, UserSpawnType=None). Do not spawn on wire.
pub const class_zombie_template_male: i32 = unityStringHash("zombieTemplateMale");
pub const class_zombie_template_short: i32 = unityStringHash("zombieShortTemplate");
/// Spawnable walkers (Mesh + UserSpawnType=Menu).
pub const class_zombie_boe: i32 = unityStringHash("zombieBoe");
pub const class_zombie_joe: i32 = unityStringHash("zombieJoe");
/// Default ECD class for seed zombies (real mesh, not template).
pub const class_zombie_default: i32 = class_zombie_boe;
/// Dropped ground loot bag (EntityLootContainer subclass).
pub const class_dropped_loot_container: i32 = unityStringHash("DroppedLootContainer");
/// Named loot container entity class (prefab / TE-style loot).
pub const class_entity_loot_container: i32 = unityStringHash("EntityLootContainer");
/// Dropped-item entity (EntityItem). EntityClass.itemClass = hash("item"); the
/// EntityCreationData.write itemClass branch carries the item stack + owner ids.
pub const class_item: i32 = unityStringHash("item");

pub const SpawnOpts = struct {
    entity_id: i32,
    entity_class: i32 = class_zombie_default,
    x: f32,
    y: f32,
    z: f32,
    yaw: f32 = 0,
    on_ground: bool = true,
    is_sleeper: bool = false,
    is_sleeper_passive: bool = false,
    /// ECD bag contents (loot containers). NetPackageBag is ToServer-only;
    /// S2C loot travels inside EntityCreationData.bag.
    bag: ?[]const stock_inv.StockSlot = null,
    /// Dropped-item stack. Set for entity_class == class_item to emit the
    /// EntityCreationData itemClass branch (belongsPlayerId, clientEntityId,
    /// itemStack, trailing sbyte). Verified against EntityCreationData.write IL.
    item_drop: ?stock_inv.StockSlot = null,
    /// Item-drop owner ids (itemClass branch only).
    belongs_player_id: i32 = -1,
    client_entity_id: i32 = -1,
};

/// Body of NetPackageEntitySpawn after channel pkgId:
/// entityId (EntityTargeted) + EntityCreationData.write(networkWrite=true).
pub fn buildEntitySpawnStock(buf: []u8, opts: SpawnOpts) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    // NetPackageEntityTargeted
    try w.writeI32(opts.entity_id);
    // EntityCreationData.write FileVersion 35
    try w.writeByte(35);
    try w.writeI32(opts.entity_class);
    try w.writeI32(opts.entity_id);
    try w.writeF32(std.math.floatMax(f32)); // lifetime
    try w.writeF32(opts.x);
    try w.writeF32(opts.y);
    try w.writeF32(opts.z);
    try w.writeF32(0); // rot.x pitch
    try w.writeF32(opts.yaw); // rot.y yaw
    try w.writeF32(0); // rot.z
    try w.writeBool(opts.on_ground);
    // BodyDamage.Write
    try w.writeI32(4);
    try w.writeI32(0);
    try w.writeU32(0);
    try w.writeBool(false); // no EntityStats
    try w.writeI16(0); // deathTime
    if (opts.bag) |slots| {
        try w.writeBool(true);
        try stock_inv.writeBag(&w, slots, true);
    } else {
        try w.writeBool(false); // no bag
    }
    try w.writeI32(@intFromFloat(opts.x));
    try w.writeI32(@intFromFloat(opts.y));
    try w.writeI32(@intFromFloat(opts.z)); // homePosition
    try w.writeI16(-1); // homeRange
    try w.writeByte(0); // spawnerSource Dynamic
    // entityClass switch (EntityCreationData.write). Only the itemClass branch is
    // emitted here; falling-block/tree/player branches are separate. A plain
    // zombie/NPC/animal writes nothing between spawnerSource and entityData.
    if (opts.item_drop) |slot| {
        // itemClass branch: belongsPlayerId, clientEntityId, itemStack, sbyte(0).
        try w.writeI32(opts.belongs_player_id);
        try w.writeI32(opts.client_entity_id);
        try stock_inv.writeItemStack(&w, slot);
        try w.writeByte(0); // trailing sbyte(0), then jumps to entityData
    }
    try w.writeU16(0); // entityData length
    try w.writeBool(false); // no traderData
    // networkWrite tail
    try w.writeByte(255); // sleeperPose
    try w.writeBool(opts.is_sleeper);
    try w.writeI32(-1); // spawnById
    try w.writeString(""); // spawnByName
    try w.writeBool(false); // spawnByAllowShare
    try w.writeByte(0); // headState
    try w.writeF32(1); // overrideSize
    try w.writeF32(1); // overrideHeadSize
    try w.writeBool(false); // isDancing
    if (opts.is_sleeper) {
        try w.writeBool(opts.is_sleeper_passive);
    }
    // junkDroneClass branch skipped for zombie class ids
    return w.written();
}

test "stock zombie spawn body non-empty" {
    var buf: [512]u8 = undefined;
    const body = try buildEntitySpawnStock(&buf, .{
        .entity_id = 200,
        .entity_class = class_zombie_default,
        .x = -273,
        .y = 61,
        .z = 449,
        .yaw = 90,
    });
    // Pin comptime hashes to client-verified values (EntityClass.list after Init).
    try std.testing.expectEqual(@as(i32, 2001454542), class_player_male);
    try std.testing.expectEqual(@as(i32, 2129337093), class_player_female);
    try std.testing.expectEqual(@as(i32, 948863590), class_zombie_boe);
    try std.testing.expectEqual(@as(i32, -2021142581), class_dropped_loot_container);
    try std.testing.expectEqual(@as(i32, -1846908538), class_entity_loot_container);
    try std.testing.expect(body.len > 40);
    try std.testing.expectEqual(@as(i32, 200), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(u8, 35), body[4]);
    try std.testing.expectEqual(class_zombie_default, std.mem.readInt(i32, body[5..9], .little));
    try std.testing.expectEqual(class_zombie_boe, class_zombie_default);
}

test "stock loot spawn embeds ECD bag" {
    var buf: [1024]u8 = undefined;
    const slots = [_]stock_inv.StockSlot{
        .{ .type_id = stock_inv.items_start_here + 5, .count = 3, .quality = 1 },
    };
    const body = try buildEntitySpawnStock(&buf, .{
        .entity_id = 302,
        .entity_class = class_dropped_loot_container,
        .x = 1,
        .y = 70,
        .z = 2,
        .bag = slots[0..],
    });
    // bag flag after fixed 57-byte prefix (id+ver+class+id+lifetime+pos+rot+ground+BodyDamage+stats+deathTime)
    try std.testing.expectEqual(@as(u8, 1), body[57]);
    // Bag.Write: version byte 1, slot count u16 = 1
    try std.testing.expectEqual(@as(u8, 1), body[58]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, body[59..61], .little));
}

test "stock dropped loot container class in spawn body" {
    var buf: [512]u8 = undefined;
    const body = try buildEntitySpawnStock(&buf, .{
        .entity_id = 301,
        .entity_class = class_dropped_loot_container,
        .x = 1,
        .y = 70,
        .z = 2,
    });
    try std.testing.expectEqual(class_dropped_loot_container, std.mem.readInt(i32, body[5..9], .little));
}

test "stock item-drop spawn emits itemClass branch (belongsPlayerId, clientEntityId, itemStack)" {
    var buf: [512]u8 = undefined;
    const body = try buildEntitySpawnStock(&buf, .{
        .entity_id = 400,
        .entity_class = class_item,
        .x = 5,
        .y = 65,
        .z = 9,
        .belongs_player_id = 171,
        .client_entity_id = 400,
        .item_drop = .{ .type_id = stock_inv.items_start_here + 7, .count = 2, .quality = 3 },
    });
    // header: entity_class at [5..9) is the item class.
    try std.testing.expectEqual(class_item, std.mem.readInt(i32, body[5..9], .little));
    // no bag for an item entity: bag flag at fixed offset 57 is 0.
    try std.testing.expectEqual(@as(u8, 0), body[57]);
    // header continues: homePos i32x3 [58..70), homeRange i16 [70..72),
    // spawnerSource byte [72]. itemClass branch starts at [73].
    try std.testing.expectEqual(@as(u8, 0), body[72]); // spawnerSource Dynamic
    try std.testing.expectEqual(@as(i32, 171), std.mem.readInt(i32, body[73..77], .little)); // belongsPlayerId
    try std.testing.expectEqual(@as(i32, 400), std.mem.readInt(i32, body[77..81], .little)); // clientEntityId
    // itemStack.Write: count u16 = 2, then ItemValue (marker byte 9).
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, body[81..83], .little));
    try std.testing.expectEqual(@as(u8, stock_inv.item_value_save_version), body[83]);
    // trailing sbyte(0) + entityData u16(0) close the branch/tail; body parses whole.
    try std.testing.expect(body.len > 90);
}
