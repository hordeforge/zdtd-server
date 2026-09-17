//! Stock EntityCreationData + NetPackageEntitySpawn (networkWrite=true).
//!
//! ECD is header + entityClass switch + networkWrite tail (see
//! ../../../7dtd-engine-research/docs/network/protocol-packages.md 5.1). Implemented branches:
//! zombie/NPC/animal (empty middle), itemClass, fallingBlock, fallingBlocks,
//! fallingTree, and player (male/female), plus the junk-drone tail. A class whose
//! branch needs data the caller did not supply returns an error rather than a
//! short, corrupt body.

const std = @import("std");
const binary = @import("binary.zig");
const stock_inv = @import("stock_inv.zig");

/// EntityClass hashes: single source `assets/unity_hash.zig` (Unity Mono GetHashCode).
const unity_hash = @import("../assets/unity_hash.zig");

pub const class_player_male = unity_hash.class_player_male;
pub const class_player_female = unity_hash.class_player_female;
/// Template-only (Mesh empty, UserSpawnType=None). Do not spawn on wire.
pub const class_zombie_template_male = unity_hash.class_zombie_template_male;
pub const class_zombie_template_short = unity_hash.class_zombie_template_short;
/// Spawnable walkers (Mesh + UserSpawnType=Menu).
pub const class_zombie_boe = unity_hash.class_zombie_boe;
pub const class_zombie_joe = unity_hash.class_zombie_joe;
/// Default ECD class for seed zombies (real mesh, not template).
pub const class_zombie_default = unity_hash.class_zombie_default;
/// Dropped ground loot bag (EntityLootContainer subclass).
pub const class_dropped_loot_container = unity_hash.class_dropped_loot_container;
/// Player death backpack (EntityBackpack). Same mesh as the ground bag but the
/// class stock's client spawns for `EntityPlayerLocal.dropBackpack`.
pub const class_backpack = unity_hash.class_backpack;
/// Named loot container entity class (prefab / TE-style loot).
pub const class_entity_loot_container = unity_hash.class_entity_loot_container;
/// Dropped-item entity (EntityItem). EntityClass.itemClass = hash("item"); the
/// EntityCreationData.write itemClass branch carries the item stack + owner ids.
pub const class_item = unity_hash.class_item;

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
    /// Trader NPC payload (EntityTrader). Emits bool hasTraderData + TraderData::Write
    /// after the entityData blob; the client clones it onto EntityTrader.TraderData.
    trader_data: ?TraderDataInfo = null,
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
    /// Stock's null substitute for this one field is "Blue01", not the empty
    /// string every other name falls back to (PlayerProfile.Write IL_00AC).
    eye_color: []const u8 = "Blue01",
};

/// Stock PlayerProfile v5 (RE: protocol.md §5 profile body).
pub const player_profile_version: i32 = 5;

/// Capacity of one profile name field. The stock archetype/race/hair/colour
/// names are asset identifiers well under this (the longest shipped is 18);
/// a longer string is treated as a malformed profile rather than truncated, so
/// a fabricated appearance never reaches the wire.
pub const profile_name_cap = 32;

/// A `PlayerProfile` copied out of a packet buffer. The client sends its own
/// profile in `NetPackageRequestToSpawnPlayer` (stock `PlayerProfile::Read`
/// IL=59 behind `chunkViewDim:i16`, `NetPackageRequestToSpawnPlayer.il.txt`
/// read IL=14), and stock stores it on the `EntityCreationData` it later writes
/// back to that player (`GameManager::RequestToSpawnPlayer`,
/// `GameManager.il.txt:4614-4617`) and to everyone who can see them. zdtd read
/// only the dim and replaced the profile with a fabricated BaseMale, so every
/// player appeared as the same default character. The receive buffers are
/// transient, so the parsed names are copied into fixed storage here.
pub const OwnedProfile = struct {
    archetype: [profile_name_cap]u8 = [_]u8{0} ** profile_name_cap,
    archetype_len: u8 = 0,
    is_male: bool = true,
    race_name: [profile_name_cap]u8 = [_]u8{0} ** profile_name_cap,
    race_name_len: u8 = 0,
    variant_number: u8 = 0,
    hair_name: [profile_name_cap]u8 = [_]u8{0} ** profile_name_cap,
    hair_name_len: u8 = 0,
    hair_color: [profile_name_cap]u8 = [_]u8{0} ** profile_name_cap,
    hair_color_len: u8 = 0,
    mustache_name: [profile_name_cap]u8 = [_]u8{0} ** profile_name_cap,
    mustache_name_len: u8 = 0,
    chops_name: [profile_name_cap]u8 = [_]u8{0} ** profile_name_cap,
    chops_name_len: u8 = 0,
    beard_name: [profile_name_cap]u8 = [_]u8{0} ** profile_name_cap,
    beard_name_len: u8 = 0,
    eye_color: [profile_name_cap]u8 = [_]u8{0} ** profile_name_cap,
    eye_color_len: u8 = 0,

    /// Borrowed view of the owned names, for the writers that take slices.
    /// The result points into `self`, so it must not outlive it.
    pub fn view(self: *const OwnedProfile) PlayerProfile {
        return .{
            .archetype = self.archetype[0..self.archetype_len],
            .is_male = self.is_male,
            .race_name = self.race_name[0..self.race_name_len],
            .variant_number = self.variant_number,
            .hair_name = self.hair_name[0..self.hair_name_len],
            .hair_color = self.hair_color[0..self.hair_color_len],
            .mustache_name = self.mustache_name[0..self.mustache_name_len],
            .chops_name = self.chops_name[0..self.chops_name_len],
            .beard_name = self.beard_name[0..self.beard_name_len],
            .eye_color = self.eye_color[0..self.eye_color_len],
        };
    }
};

fn copyName(dst: *[profile_name_cap]u8, src: []const u8) !u8 {
    if (src.len > profile_name_cap) return error.ProfileNameTooLong;
    @memcpy(dst[0..src.len], src);
    return @intCast(src.len);
}

/// `PlayerProfile::Read` (IL=59) into owned storage. The version gates the
/// optional tails: >1 hairName, >2 hairColor, >3 mustache/chops/beard, >4
/// eyeColor; a version above the one this build writes is read with the v5
/// shape and anything below 1 is rejected (stock's ctor defaults stand).
pub fn readOwnedProfile(r: *binary.Reader) !OwnedProfile {
    const version = try r.readI32();
    if (version < 1) return error.UnsupportedProfileVersion;
    var p: OwnedProfile = .{};
    var buf: [profile_name_cap]u8 = undefined;
    p.archetype_len = try copyName(&p.archetype, try r.readString(&buf));
    p.is_male = try r.readBool();
    p.race_name_len = try copyName(&p.race_name, try r.readString(&buf));
    p.variant_number = try r.readByte();
    if (version > 1) p.hair_name_len = try copyName(&p.hair_name, try r.readString(&buf));
    if (version > 2) p.hair_color_len = try copyName(&p.hair_color, try r.readString(&buf));
    if (version > 3) {
        p.mustache_name_len = try copyName(&p.mustache_name, try r.readString(&buf));
        p.chops_name_len = try copyName(&p.chops_name, try r.readString(&buf));
        p.beard_name_len = try copyName(&p.beard_name, try r.readString(&buf));
    }
    if (version > 4) p.eye_color_len = try copyName(&p.eye_color, try r.readString(&buf));
    return p;
}

/// Stock TraderData primary-inventory entry: ItemStack + runtime markup delta
/// (i8; stock Increase +100 / Decrease -4) + AddedByPlayer. We have no per-item
/// markup source, so callers pass 0: the client shows the base econ price.
pub const TraderStockEntry = struct {
    item: stock_inv.StockSlot,
    markup: i8 = 0,
};

/// Server-side trader payload. Both real S2C trader paths embed the same
/// TraderData::Write block: EntityCreationData.hasTraderData (spawn) and the
/// channel-1 LockResponse EntityTraderLockContext. NetPackageTraderData itself
/// is ToServer-only, so a server-sent one is not a delivery path.
/// One read TraderData stock entry: the ItemStack (count rides it) plus the
/// Markup sbyte. AddedByPlayer is read and dropped (the client's post-trade
/// copy always mirrors server-authored entries).
pub const TraderDataReadEntry = struct {
    item: stock_inv.StockSlot = .{},
    markup: i8 = 0,
};

/// Cap on the declared trader-stock entry count. Stock's TraderData::Read takes
/// a plain i32 with no documented limit (IL 472732), so this bounds the work one
/// body can demand rather than enforcing a stock rule; entries past the caller's
/// storage are read and dropped either way. Set far above any real trader
/// inventory so a legitimate body is never rejected.
const max_trader_entries_declared: i32 = 4096;

/// TraderData::Read (the mirror of writeTraderDataBody, stock IL 472732):
/// trader id, last restock world time, FileVersion, primary inventory entries,
/// tier groups (read + skipped), available money. `entries` is the caller's
/// storage; the returned count is capped at `entries.len`.
pub fn readTraderDataBody(
    r: *binary.Reader,
    entries: []TraderDataReadEntry,
) binary.ReadError!struct { trader_id: i32, money: i32, n: usize } {
    const trader_id = try r.readI32();
    _ = try r.readU64(); // lastInventoryUpdate
    _ = try r.readByte(); // FileVersion
    const count = try r.readI32();
    if (count < 0 or count > max_trader_entries_declared) return error.EndOfStream;
    var n: usize = 0;
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        if (n < entries.len) {
            entries[n] = .{
                .item = try stock_inv.readItemStack(r),
                .markup = @bitCast(try r.readByte()),
            };
            n += 1;
        } else {
            _ = try stock_inv.readItemStack(r);
            _ = try r.readByte();
        }
        _ = try r.readBool(); // AddedByPlayer
    }
    // TierItemGroups: u8 group count, then each group is a bare ItemStack
    // array via GameUtils::ReadItemStack (u16 count + ItemStack per entry,
    // GameUtils.il.txt:2131), not a named block. Stock traders.xml ships no
    // <tier_items>, so a stock client always sends 0 here; the loop still has
    // to consume a modded non-zero count in the right shape or the trailing
    // AvailableMoney reads garbage.
    // Read mirror of WriteInventoryData (TraderData.il.txt:436-458, :477).
    const tier_groups = try r.readByte();
    var tg: u8 = 0;
    while (tg < tier_groups) : (tg += 1) {
        const item_count = try r.readU16();
        var k: u16 = 0;
        while (k < item_count) : (k += 1) _ = try stock_inv.readItemStack(r);
    }
    const money = try r.readI32();
    return .{ .trader_id = trader_id, .money = money, .n = n };
}
pub const TraderDataInfo = struct {
    trader_id: i32,
    available_money: i32,
    entries: []const TraderStockEntry,
};

/// TraderData::Write (stock IL 472732-472745): trader id, last restock world
/// time, FileVersion, primary inventory entries, tier groups, available money.
pub fn writeTraderDataBody(w: *binary.Writer, td: TraderDataInfo) !void {
    try w.writeI32(td.trader_id);
    try w.writeU64(0); // lastInventoryUpdate
    try w.writeByte(2); // FileVersion
    try w.writeI32(@intCast(td.entries.len));
    for (td.entries) |e| {
        try stock_inv.writeItemStack(w, e.item);
        try w.writeByte(@bitCast(e.markup)); // i8 as byte
        try w.writeBool(false); // AddedByPlayer
    }
    try w.writeByte(0); // TierItemGroups count
    try w.writeI32(td.available_money);
}

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
pub const class_falling_tree = unity_hash.class_falling_tree;
/// Single/multi falling-block classes. Their ECD branches (BlockValue + texture
/// for single, count + three arrays for multi) require payload in the spawn
/// request; absent payload is an explicit error.
pub const class_falling_block = unity_hash.class_falling_block;
pub const class_falling_blocks = unity_hash.class_falling_blocks;
/// Junk drone (EntityClass.junkDroneClass): adds belongsPlayerId + orderState to
/// the ECD tail, outside the networkWrite guard.
pub const class_junk_drone = unity_hash.class_junk_drone;
/// Trader NPC class (EntityTrader): stock trader POIs spawn npcTraderJen.
pub const class_npc_trader_jen = unity_hash.class_npc_trader_jen;
pub const class_npc_trader_bob = unity_hash.class_npc_trader_bob;
pub const class_npc_trader_hugh = unity_hash.class_npc_trader_hugh;
pub const class_npc_trader_joel = unity_hash.class_npc_trader_joel;
pub const class_npc_trader_rekt = unity_hash.class_npc_trader_rekt;

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

/// PlayerProfile.Write (`il/full-v3.2.0/_global/PlayerProfile.il.txt`, IL=69):
/// version i32 (literal 5) | `archetype` string | `isMale` bool | `raceName`
/// string | `variantNumber` (an i32 field written as a byte) | `hairName` |
/// `hairColor` | `mustacheName` | `chopsName` | `beardName` | `eyeColor`.
///
/// Stock substitutes a literal for a null string on the last six: empty for
/// five of them and **"Blue01"** for `eyeColor` (IL_00AC). Zig has no null
/// string, so an empty slice here is written as empty rather than substituted;
/// the one caller that sends a profile sets `eye_color` explicitly
/// (packages.zig), so the stock default is not silently dropped.
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
    // EntityCreationData.write FileVersion 36. V3.2.0 appends a
    // requestedBy/requestKey tail that `read` consumes only at
    // readFileVersion >= 37 (changelog-3.2.0 §3.3): a 3.2.0 client reading
    // our v36 body skips the tail, so keeping v36 stays parse-compatible.
    // The tail is only meaningful for client-requested spawns, which zdtd
    // drops (c2s/misc.zig RequestToSpawnEntity), so it is not emitted.
    try w.writeByte(36);
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
    // lossyCast: client-fed transforms may be NaN/inf/huge; @trunc traps.
    try w.writeI32(std.math.lossyCast(i32, opts.x));
    try w.writeI32(std.math.lossyCast(i32, opts.y));
    try w.writeI32(std.math.lossyCast(i32, opts.z)); // homePosition
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
    if (opts.trader_data) |td| {
        // EntityCreationData.write: bool traderData != null, then TraderData::Write.
        try w.writeBool(true);
        try writeTraderDataBody(&w, td);
    } else {
        try w.writeBool(false); // no traderData
    }
    // networkWrite tail
    try w.writeByte(255); // sleeperPose
    try w.writeBool(opts.is_sleeper);
    try w.writeI32(-1); // spawnById
    try w.writeString(""); // spawnByName
    // These two are one byte each and both zero, so no test can pin their
    // order: the swap-mutation audit reports the pair as a survivor by
    // construction. EntityCreationData.write holds the order, not a test.
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
    // ECD v36 tail (always written after junkDrone branch).
    try w.writeF32(0); // stressAmount
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

/// NetPackageWorldSpawnPoints body: SpawnPointList (RE
/// ../7dtd-engine-research/il/full-v3.1.0/_global/SpawnPointList.il.txt write IL=25
/// + SpawnPoint/SpawnPosition). Sent on death so the client's respawn screen
/// lists the available spawn points. Layout: version u8 (2) + count i32 +
/// per point: SpawnPosition (version u16 0 + position xyz f32 + heading f32)
/// + team i32 + activeInGameMode i32.
pub const SpawnPointEntry = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    heading: f32 = 0,
    team: i32 = 0,
    /// -1 = all game modes (stock default for world spawns).
    active_in_game_mode: i32 = -1,
};

/// NetPackageWorldSpawnPoints (RE inventories/netpackage-bodies.md, write
/// IL=8): one `spawnPoints` blob = SpawnPointList.Write (save version byte,
/// count i32, then per point a SpawnPosition).
pub fn buildWorldSpawnPointsBody(buf: []u8, points: []const SpawnPointEntry) ![]u8 {
    var w = binary.Writer{ .buf = buf };
    try w.writeByte(2); // SpawnPointList.CurrentSaveVersion (.cctor ldc.i4.2)
    try w.writeI32(@intCast(points.len));
    for (points) |p| {
        try w.writeU16(0); // SpawnPosition version
        try w.writeF32(p.x);
        try w.writeF32(p.y);
        try w.writeF32(p.z);
        try w.writeF32(p.heading);
        try w.writeI32(p.team);
        try w.writeI32(p.active_in_game_mode);
    }
    return w.written();
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
