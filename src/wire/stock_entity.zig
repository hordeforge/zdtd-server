//! Stock EntityCreationData + NetPackageEntitySpawn (networkWrite=true).
//!
//! ECD is header + entityClass switch + networkWrite tail (see
//! ../../7dtd-research/docs/protocol-packages.md 5.1). Implemented branches:
//! zombie/NPC/animal (empty middle), itemClass, fallingBlock, fallingBlocks,
//! fallingTree, and player (male/female), plus the junk-drone tail. A class whose
//! branch needs data the caller did not supply returns an error rather than a
//! short, corrupt body.

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
    /// Player identity, required when entity_class is class_player_male/female
    /// (EntityCreationData.write player branch). Omitting it on a player class is
    /// an error, not a silently short body.
    player: ?PlayerSpawnInfo = null,
    /// Falling-tree data, required when entity_class == class_falling_tree.
    falling_tree: ?FallingTreeInfo = null,
    /// Junk-drone order state (junkDrone tail only; paired with belongs_player_id).
    drone_order_state: i32 = 0,
    /// Required when entity_class == class_falling_block.
    falling_block: ?FallingBlockInfo = null,
    /// Required when entity_class == class_falling_blocks.
    falling_blocks: ?FallingBlocksInfo = null,
};

/// EntityCreationData player branch: holdingItem, teamNumber, entityName,
/// skinTexture, then an optional PlayerProfile.
pub const PlayerSpawnInfo = struct {
    entity_name: []const u8,
    skin_texture: []const u8 = "",
    team_number: u8 = 0,
    /// Held item; null writes the empty ItemValue sentinel (single 0 byte),
    /// matching the static `ItemValue.Write(ItemValue, BinaryWriter)` null path.
    holding_item: ?stock_inv.StockSlot = null,
    profile: ?PlayerProfile = null,
};

/// PlayerProfile.Write, save version 5 (verified against IL: i32 version, then
/// archetype, isMale, raceName, variantNumber:byte, and the appearance strings).
pub const PlayerProfile = struct {
    archetype: []const u8 = "",
    is_male: bool = true,
    race_name: []const u8 = "",
    variant_number: u8 = 0,
    hair_name: []const u8 = "",
    hair_color: []const u8 = "",
    mustache_name: []const u8 = "",
    chops_name: []const u8 = "",
    beard_name: []const u8 = "",
    eye_color: []const u8 = "",
};

pub const player_profile_version: i32 = 5;

/// EntityCreationData fallingTree branch: blockPos then fallTreeDir, both via
/// StreamUtils.Write (Vector3i = 3x i32, Vector3 = 3x f32).
pub const FallingTreeInfo = struct {
    block_x: i32,
    block_y: i32,
    block_z: i32,
    dir_x: f32 = 0,
    dir_y: f32 = 0,
    dir_z: f32 = 0,
};

/// Class-name strings verified against EntityClass.Init ldstr literals.
/// Falling-tree entity class (EntityClass.fallingTreeClass).
pub const class_falling_tree: i32 = unityStringHash("fallingTree");
/// Single/multi falling-block classes. Their ECD branches (BlockValue arrays +
/// TextureFullArray) are not implemented; spawning them is an explicit error.
pub const class_falling_block: i32 = unityStringHash("fallingBlock");
pub const class_falling_blocks: i32 = unityStringHash("fallingBlocks");
/// Junk drone (EntityClass.junkDroneClass): adds belongsPlayerId + orderState to
/// the ECD tail, outside the networkWrite guard.
pub const class_junk_drone: i32 = unityStringHash("entityJunkDrone");

/// One falling block: packed BlockValue plus its texture word.
/// `TextureFullArray.Write` emits exactly one i64 (loop bound 1 in the IL).
pub const FallingBlock = struct {
    raw_data: u32,
    texture: i64 = 0,
    /// Only used by the multi-block (fallingBlocks) branch.
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
};

/// fallingBlock (single) branch payload.
pub const FallingBlockInfo = struct { block: FallingBlock };

/// fallingBlocks (multi) branch payload.
///
/// Wire shape is `count:i32`, then `count x rawData:u32`, then `count x
/// Vector3i`, then `count x i64`. Only ONE count is written even though three
/// arrays follow: the reader sizes `blockPositions` and `textureFullArrays` from
/// the same value (`EntityCreationData.read` allocates all three with it and never
/// reads a second length). The three arrays are therefore required to be the same
/// length, which this API enforces by construction.
pub const FallingBlocksInfo = struct { blocks: []const FallingBlock };

pub fn writePlayerProfile(w: *binary.Writer, p: PlayerProfile) !void {
    try w.writeI32(player_profile_version);
    try w.writeString(p.archetype);
    try w.writeBool(p.is_male);
    try w.writeString(p.race_name);
    try w.writeByte(p.variant_number);
    try w.writeString(p.hair_name);
    try w.writeString(p.hair_color);
    try w.writeString(p.mustache_name);
    try w.writeString(p.chops_name);
    try w.writeString(p.beard_name);
    try w.writeString(p.eye_color);
}

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
    // entityClass switch (EntityCreationData.write). The branches are mutually
    // exclusive and a plain zombie/NPC/animal writes nothing here. Anything that
    // needs a branch we cannot emit is an explicit error: a short body would be
    // silently corrupt on the wire, which is worse than a failed send.
    if (opts.entity_class == class_item) {
        // itemClass branch: belongsPlayerId, clientEntityId, itemStack, sbyte(0).
        const slot = opts.item_drop orelse return error.MissingItemDropData;
        try w.writeI32(opts.belongs_player_id);
        try w.writeI32(opts.client_entity_id);
        try stock_inv.writeItemStack(&w, slot);
        try w.writeByte(0); // trailing sbyte(0), then jumps to entityData
    } else if (opts.entity_class == class_falling_tree) {
        // fallingTree branch: blockPos (Vector3i), fallTreeDir (Vector3).
        const t = opts.falling_tree orelse return error.MissingFallingTreeData;
        try w.writeI32(t.block_x);
        try w.writeI32(t.block_y);
        try w.writeI32(t.block_z);
        try w.writeF32(t.dir_x);
        try w.writeF32(t.dir_y);
        try w.writeF32(t.dir_z);
    } else if (opts.entity_class == class_player_male or opts.entity_class == class_player_female) {
        // player branch: holdingItem, teamNumber, entityName, skinTexture, profile.
        const p = opts.player orelse return error.MissingPlayerSpawnInfo;
        if (p.holding_item) |hi| try stock_inv.writeItemValue(&w, hi) else try stock_inv.writeEmptyItemValue(&w);
        try w.writeByte(p.team_number);
        try w.writeString(p.entity_name);
        try w.writeString(p.skin_texture);
        if (p.profile) |prof| {
            try w.writeBool(true);
            try writePlayerProfile(&w, prof);
        } else {
            try w.writeBool(false);
        }
    } else if (opts.entity_class == class_falling_block) {
        // fallingBlock branch: blockValues[0].rawData, then textureFullArrays[0].
        const fb = opts.falling_block orelse return error.MissingFallingBlockData;
        try w.writeU32(fb.block.raw_data);
        try w.writeI64(fb.block.texture);
    } else if (opts.entity_class == class_falling_blocks) {
        // fallingBlocks branch: one count, then three same-length arrays.
        const fbs = opts.falling_blocks orelse return error.MissingFallingBlocksData;
        const n: i32 = @intCast(fbs.blocks.len);
        try w.writeI32(n);
        for (fbs.blocks) |b| try w.writeU32(b.raw_data);
        for (fbs.blocks) |b| {
            try w.writeI32(b.x);
            try w.writeI32(b.y);
            try w.writeI32(b.z);
        }
        for (fbs.blocks) |b| try w.writeI64(b.texture);
    } else if (opts.item_drop != null) {
        // guard: item payload supplied but the class will not emit the branch
        return error.ItemDropRequiresItemClass;
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
    // junkDrone extras sit AFTER the networkWrite block, not inside it: the
    // networkWrite guard jumps to this same test (ECD.write IL_033F -> IL_03C5).
    if (opts.entity_class == class_junk_drone) {
        try w.writeI32(opts.belongs_player_id);
        try w.writeI32(opts.drone_order_state);
    }
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

test "stock player spawn emits player branch (holdingItem, team, names, profile)" {
    var buf: [512]u8 = undefined;
    const body = try buildEntitySpawnStock(&buf, .{
        .entity_id = 500,
        .entity_class = class_player_male,
        .x = 1,
        .y = 64,
        .z = 2,
        .player = .{
            .entity_name = "Bob",
            .skin_texture = "",
            .team_number = 3,
            .profile = .{ .archetype = "arch", .is_male = true, .race_name = "race", .variant_number = 2 },
        },
    });
    try std.testing.expectEqual(class_player_male, std.mem.readInt(i32, body[5..9], .little));
    // header ends at spawnerSource (offset 72); player branch starts at 73.
    try std.testing.expectEqual(@as(u8, 0), body[72]); // spawnerSource
    try std.testing.expectEqual(@as(u8, 0), body[73]); // holdingItem = empty ItemValue sentinel
    try std.testing.expectEqual(@as(u8, 3), body[74]); // teamNumber
    // entityName: 7-bit length prefix (3) + "Bob"
    try std.testing.expectEqual(@as(u8, 3), body[75]);
    try std.testing.expectEqualSlices(u8, "Bob", body[76..79]);
    try std.testing.expectEqual(@as(u8, 0), body[79]); // skinTexture: empty string
    try std.testing.expectEqual(@as(u8, 1), body[80]); // playerProfile present
    // PlayerProfile.Write: i32 version = 5
    try std.testing.expectEqual(@as(i32, player_profile_version), std.mem.readInt(i32, body[81..85], .little));
}

test "stock falling-tree spawn emits blockPos + fallTreeDir" {
    var buf: [512]u8 = undefined;
    const body = try buildEntitySpawnStock(&buf, .{
        .entity_id = 600,
        .entity_class = class_falling_tree,
        .x = 3,
        .y = 65,
        .z = 4,
        .falling_tree = .{ .block_x = 10, .block_y = 20, .block_z = 30, .dir_x = 1 },
    });
    try std.testing.expectEqual(class_falling_tree, std.mem.readInt(i32, body[5..9], .little));
    // fallingTree branch starts right after spawnerSource at 73: Vector3i then Vector3
    try std.testing.expectEqual(@as(i32, 10), std.mem.readInt(i32, body[73..77], .little));
    try std.testing.expectEqual(@as(i32, 20), std.mem.readInt(i32, body[77..81], .little));
    try std.testing.expectEqual(@as(i32, 30), std.mem.readInt(i32, body[81..85], .little));
    try std.testing.expectEqual(@as(f32, 1), @as(f32, @bitCast(std.mem.readInt(u32, body[85..89], .little))));
}

test "class branches that need payload fail loudly instead of emitting a short body" {
    var buf: [512]u8 = undefined;
    try std.testing.expectError(error.MissingPlayerSpawnInfo, buildEntitySpawnStock(&buf, .{
        .entity_id = 1, .entity_class = class_player_male, .x = 0, .y = 0, .z = 0,
    }));
    try std.testing.expectError(error.MissingFallingTreeData, buildEntitySpawnStock(&buf, .{
        .entity_id = 2, .entity_class = class_falling_tree, .x = 0, .y = 0, .z = 0,
    }));
    try std.testing.expectError(error.MissingItemDropData, buildEntitySpawnStock(&buf, .{
        .entity_id = 3, .entity_class = class_item, .x = 0, .y = 0, .z = 0,
    }));
    // a zombie is unaffected by the guards
    _ = try buildEntitySpawnStock(&buf, .{ .entity_id = 4, .x = 0, .y = 0, .z = 0 });
}

test "junk drone appends belongsPlayerId + orderState after the networkWrite tail" {
    var buf: [512]u8 = undefined;
    const drone = try buildEntitySpawnStock(&buf, .{
        .entity_id = 700,
        .entity_class = class_junk_drone,
        .x = 0, .y = 64, .z = 0,
        .belongs_player_id = 171,
        .drone_order_state = 2,
    });
    const zombie = try buildEntitySpawnStock(buf[drone.len..], .{
        .entity_id = 701, .x = 0, .y = 64, .z = 0,
    });
    // the drone body is exactly 8 bytes longer than an otherwise identical zombie
    try std.testing.expectEqual(zombie.len + 8, drone.len);
    try std.testing.expectEqual(@as(i32, 171), std.mem.readInt(i32, drone[drone.len - 8 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, drone[drone.len - 4 ..][0..4], .little));
}

test "fallingBlock branch emits rawData + one texture i64" {
    var buf: [512]u8 = undefined;
    const body = try buildEntitySpawnStock(&buf, .{
        .entity_id = 800,
        .entity_class = class_falling_block,
        .x = 0, .y = 64, .z = 0,
        .falling_block = .{ .block = .{ .raw_data = 0xDEADBEEF, .texture = 0x1122334455667788 } },
    });
    // branch starts right after spawnerSource (offset 72)
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), std.mem.readInt(u32, body[73..77], .little));
    try std.testing.expectEqual(@as(i64, 0x1122334455667788), std.mem.readInt(i64, body[77..85], .little));
}

test "fallingBlocks branch writes one count for all three arrays" {
    var buf: [512]u8 = undefined;
    const blocks = [_]FallingBlock{
        .{ .raw_data = 1, .texture = 10, .x = 1, .y = 2, .z = 3 },
        .{ .raw_data = 2, .texture = 20, .x = 4, .y = 5, .z = 6 },
    };
    const body = try buildEntitySpawnStock(&buf, .{
        .entity_id = 801,
        .entity_class = class_falling_blocks,
        .x = 0, .y = 64, .z = 0,
        .falling_blocks = .{ .blocks = blocks[0..] },
    });
    var o: usize = 73;
    try std.testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, body[o..][0..4], .little)); // single count
    o += 4;
    // rawData x2
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, body[o..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, body[o + 4 ..][0..4], .little));
    o += 8;
    // positions x2 (3x i32 each), no second count in between
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, body[o..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 6), std.mem.readInt(i32, body[o + 20 ..][0..4], .little));
    o += 24;
    // textures x2
    try std.testing.expectEqual(@as(i64, 10), std.mem.readInt(i64, body[o..][0..8], .little));
    try std.testing.expectEqual(@as(i64, 20), std.mem.readInt(i64, body[o + 8 ..][0..8], .little));
}

test "falling-block classes without payload error instead of writing a short body" {
    var buf: [512]u8 = undefined;
    try std.testing.expectError(error.MissingFallingBlockData, buildEntitySpawnStock(&buf, .{
        .entity_id = 1, .entity_class = class_falling_block, .x = 0, .y = 0, .z = 0,
    }));
    try std.testing.expectError(error.MissingFallingBlocksData, buildEntitySpawnStock(&buf, .{
        .entity_id = 2, .entity_class = class_falling_blocks, .x = 0, .y = 0, .z = 0,
    }));
}
