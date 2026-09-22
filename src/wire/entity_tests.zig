//! Entity wire tests: spawn, stats, anim.
//!
//! Split out of wire/stock_entity.zig (same tests, moved verbatim).

const std = @import("std");
const stock_entity = @import("stock_entity.zig");
const binary = @import("binary.zig");
const stock_inv = @import("stock_inv.zig");
const FallingBlock = stock_entity.FallingBlock;
const PlayerProfile = stock_entity.PlayerProfile;
const SpawnPointEntry = stock_entity.SpawnPointEntry;
const TraderDataReadEntry = stock_entity.TraderDataReadEntry;
const TraderStockEntry = stock_entity.TraderStockEntry;
const buildEntitySpawnStock = stock_entity.buildEntitySpawnStock;
const buildWorldSpawnPointsBody = stock_entity.buildWorldSpawnPointsBody;
const class_dropped_loot_container = stock_entity.class_dropped_loot_container;
const class_entity_loot_container = stock_entity.class_entity_loot_container;
const class_falling_block = stock_entity.class_falling_block;
const class_falling_blocks = stock_entity.class_falling_blocks;
const class_falling_tree = stock_entity.class_falling_tree;
const class_item = stock_entity.class_item;
const class_junk_drone = stock_entity.class_junk_drone;
const class_player_female = stock_entity.class_player_female;
const class_player_male = stock_entity.class_player_male;
const class_zombie_boe = stock_entity.class_zombie_boe;
const class_zombie_default = stock_entity.class_zombie_default;
const player_profile_version = stock_entity.player_profile_version;
const readTraderDataBody = stock_entity.readTraderDataBody;

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
    try std.testing.expectEqual(@as(u8, 36), body[4]);
    try std.testing.expectEqual(class_zombie_default, std.mem.readInt(i32, body[5..9], .little));
    try std.testing.expectEqual(class_zombie_boe, class_zombie_default);

    // ECD continues: id i32 | lifetime f32 | pos x,y,z | rot pitch,yaw,roll |
    // onGround. Nothing read past the class, so every pair in that run of
    // eight floats could swap unnoticed - and this is the body a client reads
    // to place the entity, so a swap there spawns it somewhere else. lifetime
    // is floatMax and the two unused rotation axes are 0, which the position
    // and yaw values are chosen to differ from.
    const f32At = struct {
        fn get(b: []const u8, off: usize) f32 {
            return @bitCast(std.mem.readInt(u32, b[off..][0..4], .little));
        }
    }.get;
    try std.testing.expectEqual(@as(i32, 200), std.mem.readInt(i32, body[9..13], .little));
    try std.testing.expectEqual(std.math.floatMax(f32), f32At(body, 13)); // lifetime
    try std.testing.expectEqual(@as(f32, -273), f32At(body, 17)); // x
    try std.testing.expectEqual(@as(f32, 61), f32At(body, 21)); // y
    try std.testing.expectEqual(@as(f32, 449), f32At(body, 25)); // z
    try std.testing.expectEqual(@as(f32, 0), f32At(body, 29)); // rot pitch
    try std.testing.expectEqual(@as(f32, 90), f32At(body, 33)); // rot yaw
    try std.testing.expectEqual(@as(f32, 0), f32At(body, 37)); // rot roll
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
    try std.testing.expect(body.len > 40);
    try std.testing.expectEqual(@as(i32, 301), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(u8, 36), body[4]); // ECD FileVersion
    try std.testing.expectEqual(class_dropped_loot_container, std.mem.readInt(i32, body[5..9], .little));
    // ECD entity id repeats after class
    try std.testing.expectEqual(@as(i32, 301), std.mem.readInt(i32, body[9..13], .little));
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
            // Every string distinct: the profile carries no field names, so
            // four empty strings in a row would let a reordering emit
            // identical bytes and pass.
            .profile = .{
                .archetype = "arch",
                .is_male = true,
                .race_name = "race",
                .variant_number = 2,
                .hair_name = "hair",
                .hair_color = "haircol",
                .mustache_name = "must",
                .chops_name = "chops",
                .beard_name = "beard",
                .eye_color = "Green02",
            },
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

    // The profile is ten positional fields with no names on the wire, so read
    // them back in order against PlayerProfile.Write (IL=69). Each test value
    // is distinct, which a length or version assertion alone could not tell
    // apart from a reordering.
    var pr: binary.Reader = .{ .data = body[85..] };
    var s_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("arch", try pr.readString(&s_buf)); // archetype
    try std.testing.expectEqual(true, try pr.readBool()); // isMale
    try std.testing.expectEqualStrings("race", try pr.readString(&s_buf)); // raceName
    try std.testing.expectEqual(@as(u8, 2), try pr.readByte()); // variantNumber
    try std.testing.expectEqualStrings("hair", try pr.readString(&s_buf)); // hairName
    try std.testing.expectEqualStrings("haircol", try pr.readString(&s_buf)); // hairColor
    try std.testing.expectEqualStrings("must", try pr.readString(&s_buf)); // mustacheName
    try std.testing.expectEqualStrings("chops", try pr.readString(&s_buf)); // chopsName
    try std.testing.expectEqualStrings("beard", try pr.readString(&s_buf)); // beardName
    try std.testing.expectEqualStrings("Green02", try pr.readString(&s_buf)); // eyeColor

    // The struct default for eyeColor is stock's null substitute "Blue01"
    // (PlayerProfile.Write IL_00AC), not the empty string the other five names
    // fall back to.
    const default_profile: PlayerProfile = .{};
    try std.testing.expectEqualStrings("Blue01", default_profile.eye_color);
    try std.testing.expectEqualStrings("", default_profile.beard_name);
}

test "stock falling-tree spawn emits blockPos + fallTreeDir" {
    var buf: [512]u8 = undefined;
    const body = try buildEntitySpawnStock(&buf, .{
        .entity_id = 600,
        .entity_class = class_falling_tree,
        .x = 3,
        .y = 65,
        .z = 4,
        // dir_y and dir_z used to sit at their 0 default, which left them
        // interchangeable with each other on the wire.
        .falling_tree = .{ .block_x = 10, .block_y = 20, .block_z = 30, .dir_x = 1, .dir_y = 2, .dir_z = 3 },
    });
    try std.testing.expectEqual(class_falling_tree, std.mem.readInt(i32, body[5..9], .little));
    // fallingTree branch starts right after spawnerSource at 73: Vector3i then Vector3
    try std.testing.expectEqual(@as(i32, 10), std.mem.readInt(i32, body[73..77], .little));
    try std.testing.expectEqual(@as(i32, 20), std.mem.readInt(i32, body[77..81], .little));
    try std.testing.expectEqual(@as(i32, 30), std.mem.readInt(i32, body[81..85], .little));
    const dirAt = struct {
        fn get(b: []const u8, off: usize) f32 {
            return @bitCast(std.mem.readInt(u32, b[off..][0..4], .little));
        }
    }.get;
    try std.testing.expectEqual(@as(f32, 1), dirAt(body, 85));
    try std.testing.expectEqual(@as(f32, 2), dirAt(body, 89));
    try std.testing.expectEqual(@as(f32, 3), dirAt(body, 93));

    // homePosition is the spawn x/y/z lossily cast to i32, and nothing read it
    // back, so its three words could rotate among themselves. It sits just
    // before homeRange (i16) and spawnerSource (u8), which end at the branch
    // offset 73 the assertions above are anchored on: 73 - 1 - 2 - 12 = 58.
    try std.testing.expectEqual(@as(i32, 3), std.mem.readInt(i32, body[58..62], .little));
    try std.testing.expectEqual(@as(i32, 65), std.mem.readInt(i32, body[62..66], .little));
    try std.testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, body[66..70], .little));
    try std.testing.expectEqual(@as(i16, -1), std.mem.readInt(i16, body[70..72], .little)); // homeRange
    try std.testing.expectEqual(@as(u8, 0), body[72]); // spawnerSource Dynamic
}

test "class branches that need payload fail loudly instead of emitting a short body" {
    var buf: [512]u8 = undefined;
    try std.testing.expectError(error.MissingPlayerSpawnInfo, buildEntitySpawnStock(&buf, .{
        .entity_id = 1,
        .entity_class = class_player_male,
        .x = 0,
        .y = 0,
        .z = 0,
    }));
    try std.testing.expectError(error.MissingFallingTreeData, buildEntitySpawnStock(&buf, .{
        .entity_id = 2,
        .entity_class = class_falling_tree,
        .x = 0,
        .y = 0,
        .z = 0,
    }));
    try std.testing.expectError(error.MissingItemDropData, buildEntitySpawnStock(&buf, .{
        .entity_id = 3,
        .entity_class = class_item,
        .x = 0,
        .y = 0,
        .z = 0,
    }));
    // a zombie is unaffected by the guards
    _ = try buildEntitySpawnStock(&buf, .{ .entity_id = 4, .x = 0, .y = 0, .z = 0 });
}

test "junk drone appends belongsPlayerId + orderState after the networkWrite tail" {
    var buf: [512]u8 = undefined;
    const drone = try buildEntitySpawnStock(&buf, .{
        .entity_id = 700,
        .entity_class = class_junk_drone,
        .x = 0,
        .y = 64,
        .z = 0,
        .belongs_player_id = 171,
        .drone_order_state = 2,
    });
    const zombie = try buildEntitySpawnStock(buf[drone.len..], .{
        .entity_id = 701,
        .x = 0,
        .y = 64,
        .z = 0,
    });
    // drone adds belongsPlayerId+orderState (8 B) before shared stressAmount tail
    try std.testing.expectEqual(zombie.len + 8, drone.len);
    try std.testing.expectEqual(@as(i32, 171), std.mem.readInt(i32, drone[drone.len - 12 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, drone[drone.len - 8 ..][0..4], .little));
    // trailing stressAmount f32 == 0 on both
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, drone[drone.len - 4 ..][0..4], .little));
}

test "fallingBlock branch emits rawData + one texture i64" {
    var buf: [512]u8 = undefined;
    const body = try buildEntitySpawnStock(&buf, .{
        .entity_id = 800,
        .entity_class = class_falling_block,
        .x = 0,
        .y = 64,
        .z = 0,
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
        .x = 0,
        .y = 64,
        .z = 0,
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
        .entity_id = 1,
        .entity_class = class_falling_block,
        .x = 0,
        .y = 0,
        .z = 0,
    }));
    try std.testing.expectError(error.MissingFallingBlocksData, buildEntitySpawnStock(&buf, .{
        .entity_id = 2,
        .entity_class = class_falling_blocks,
        .x = 0,
        .y = 0,
        .z = 0,
    }));
}

test "trader ECD emits hasTraderData + TraderData::Write" {
    var buf: [1024]u8 = undefined;
    const entries = [_]TraderStockEntry{
        .{ .item = .{ .type_id = 700, .count = 5, .quality = 1 } },
        .{ .item = .{ .type_id = 701, .count = 1, .quality = 1 }, .markup = -4 },
    };
    const body = try buildEntitySpawnStock(&buf, .{
        .entity_id = 42,
        .entity_class = 12345678,
        .x = 10,
        .y = 20,
        .z = 30,
        .trader_data = .{ .trader_id = 42, .available_money = 5000, .entries = entries[0..] },
    });
    // Forward parse of the whole ECD; a plain NPC class writes no class branch.
    var r: binary.Reader = .{ .data = body };
    try std.testing.expectEqual(@as(i32, 42), try r.readI32()); // entityId (targeted)
    try std.testing.expectEqual(@as(u8, 36), try r.readByte()); // FileVersion
    try std.testing.expectEqual(@as(i32, 12345678), try r.readI32()); // entity_class
    try std.testing.expectEqual(@as(i32, 42), try r.readI32()); // entityId copy
    _ = try r.readF32(); // lifetime
    _ = try r.readF32(); // x
    _ = try r.readF32(); // y
    _ = try r.readF32(); // z
    _ = try r.readF32(); // rot.x
    _ = try r.readF32(); // rot.y yaw
    _ = try r.readF32(); // rot.z
    try std.testing.expectEqual(true, try r.readBool()); // on_ground
    try std.testing.expectEqual(@as(i32, 4), try r.readI32()); // BodyDamage parts
    try std.testing.expectEqual(@as(i32, 0), try r.readI32());
    try std.testing.expectEqual(@as(u32, 0), try r.readU32());
    try std.testing.expectEqual(false, try r.readBool()); // no EntityStats
    try std.testing.expectEqual(@as(i16, 0), try r.readI16()); // deathTime
    try std.testing.expectEqual(false, try r.readBool()); // no bag
    _ = try r.readI32(); // homePosition x
    _ = try r.readI32(); // homePosition y
    _ = try r.readI32(); // homePosition z
    try std.testing.expectEqual(@as(i16, -1), try r.readI16()); // homeRange
    try std.testing.expectEqual(@as(u8, 0), try r.readByte()); // spawnerSource
    try std.testing.expectEqual(@as(u16, 0), try r.readU16()); // entityData length
    try std.testing.expectEqual(true, try r.readBool()); // hasTraderData
    // TraderData::Write
    const trader_data_start = r.pos;
    try std.testing.expectEqual(@as(i32, 42), try r.readI32()); // trader id
    try std.testing.expectEqual(@as(u64, 0), try r.readU64()); // lastInventoryUpdate
    try std.testing.expectEqual(@as(u8, 2), try r.readByte()); // FileVersion
    try std.testing.expectEqual(@as(i32, 2), try r.readI32()); // primary count
    for (entries) |e| {
        const item = try stock_inv.readItemStack(&r);
        try std.testing.expectEqual(e.item.type_id, item.type_id);
        try std.testing.expectEqual(e.item.count, item.count);
        try std.testing.expectEqual(e.markup, @as(i8, @bitCast(try r.readByte())));
        try std.testing.expectEqual(false, try r.readBool()); // AddedByPlayer
    }
    try std.testing.expectEqual(@as(u8, 0), try r.readByte()); // TierItemGroups
    try std.testing.expectEqual(@as(i32, 5000), try r.readI32()); // available money
    // networkWrite tail
    try std.testing.expectEqual(@as(u8, 255), try r.readByte()); // sleeperPose
    try std.testing.expectEqual(false, try r.readBool()); // is_sleeper
    try std.testing.expectEqual(@as(i32, -1), try r.readI32()); // spawnById
    var name_buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", try r.readString(&name_buf));
    try std.testing.expectEqual(false, try r.readBool()); // spawnByAllowShare
    try std.testing.expectEqual(@as(u8, 0), try r.readByte()); // headState
    _ = try r.readF32(); // overrideSize
    _ = try r.readF32(); // overrideHeadSize
    try std.testing.expectEqual(false, try r.readBool()); // isDancing
    try std.testing.expectEqual(@as(f32, 0), try r.readF32()); // stressAmount (v36 tail)
    try std.testing.expect(r.pos == body.len);

    // The same bytes back through the reader. The walk above proves only the
    // builder; nothing exercised readTraderDataBody, so swapping its TraderID
    // with lastInventoryUpdate left the whole suite green while the parser
    // disagreed with `TraderData::Write` (IL=15: Write(Int32) TraderID,
    // Write(UInt64) lastInventoryUpdate, Write(Byte) FileVersion).
    var tr: binary.Reader = .{ .data = body, .pos = trader_data_start };
    var read_entries: [4]TraderDataReadEntry = undefined;
    const td = try readTraderDataBody(&tr, read_entries[0..]);
    try std.testing.expectEqual(@as(i32, 42), td.trader_id);
    try std.testing.expectEqual(@as(i32, 5000), td.money);
    try std.testing.expectEqual(@as(usize, 2), td.n);
    try std.testing.expectEqual(entries[0].item.type_id, read_entries[0].item.type_id);
    try std.testing.expectEqual(entries[1].markup, read_entries[1].markup);
}

test "world spawn points body is the stock SpawnPointList shape" {
    var buf: [64]u8 = undefined;
    const body = try buildWorldSpawnPointsBody(&buf, &.{
        .{ .x = 10, .y = 70, .z = 20, .heading = 90 },
    });
    try std.testing.expectEqual(@as(usize, 5 + 26), body.len);
    var r = binary.Reader{ .data = body };
    try std.testing.expectEqual(@as(u8, 2), try r.readByte()); // version
    try std.testing.expectEqual(@as(i32, 1), try r.readI32()); // count
    try std.testing.expectEqual(@as(u16, 0), try r.readU16()); // SpawnPosition version
    try std.testing.expectEqual(@as(f32, 10), try r.readF32());
    try std.testing.expectEqual(@as(f32, 70), try r.readF32());
    try std.testing.expectEqual(@as(f32, 20), try r.readF32());
    try std.testing.expectEqual(@as(f32, 90), try r.readF32()); // heading
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // team
    try std.testing.expectEqual(@as(i32, -1), try r.readI32()); // activeInGameMode
}

test "world spawn points stock wire" {
    var buf: [128]u8 = undefined;
    const body = try buildWorldSpawnPointsBody(&buf, &[_]SpawnPointEntry{
        .{ .x = -273, .y = 61, .z = 449, .heading = 51 },
        .{ .x = 0, .y = 70, .z = 0 },
    });
    // 1 + 4 + 2*26
    try std.testing.expectEqual(@as(usize, 57), body.len);
    try std.testing.expectEqual(@as(u8, 2), body[0]);
    try std.testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, body[1..5], .little));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, body[5..7], .little));
    try std.testing.expectEqual(@as(f32, -273), @as(f32, @bitCast(std.mem.readInt(u32, body[7..11], .little))));
    try std.testing.expectEqual(@as(f32, 61), @as(f32, @bitCast(std.mem.readInt(u32, body[11..15], .little))));
    try std.testing.expectEqual(@as(f32, 449), @as(f32, @bitCast(std.mem.readInt(u32, body[15..19], .little))));
    try std.testing.expectEqual(@as(f32, 51), @as(f32, @bitCast(std.mem.readInt(u32, body[19..23], .little))));
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, body[23..27], .little));
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, body[27..31], .little));
}
test "world spawn points: 32 entries exceed the old 512-byte join buffer" {
    // Regression (2026-08-29 Pregen soak): sendWorldSpawnPoints built into a
    // 512-byte slice, but 32 entries need 837 bytes (26/entry + 5 header), so
    // maps with >= 20 spawn points overflowed on every enter. The join
    // handler now uses a 1024-byte slice; pin that the full cap fits.
    var pts: [32]SpawnPointEntry = undefined;
    for (&pts, 0..) |*p, i| p.* = .{ .x = @floatFromInt(i), .y = 60, .z = @floatFromInt(i) };
    var buf: [1024]u8 = undefined;
    const body = try buildWorldSpawnPointsBody(&buf, &pts);
    try std.testing.expect(body.len > 512); // the old slice could not hold it
    try std.testing.expect(body.len < buf.len);
}
