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
    /// V3.2.0 requested-spawn correlation (`EntityCreationData` tail, protocol.md
    /// section 5.1): `requestedBy` (the requesting entity id) plus the client's
    /// `requestKey` Guid. Setting the key lifts the body to FileVersion 37 and
    /// appends the pair, which is what lets the client consume its pending
    /// `SpawnRequest` when the matching `NetPackageConfirmSpawnEntity` arrives.
    /// A null key keeps FileVersion 36, the shape every other spawn uses.
    requested_by: i32 = 0,
    request_key: ?[16]u8 = null,
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
    // EntityCreationData.write FileVersion: 36 normally, 37 when the
    // requested-spawn tail rides along. V3.2.0 appends a requestedBy/requestKey
    // tail that `read` consumes only at readFileVersion >= 37
    // (changelog-3.2.0 §3.3), so a 3.2.0 client reading our v36 body skips the
    // tail and stays parse-compatible; a requested spawn needs v37 so the client
    // sees the correlation pair.
    const file_version: u8 = if (opts.request_key != null) 37 else 36;
    try w.writeByte(file_version);
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
    // ECD tail (always written after junkDrone branch).
    try w.writeF32(0); // stressAmount
    // V3.2.0 requested-spawn pair: written always by the client, consumed only
    // at readFileVersion >= 37 (protocol.md section 5.1 tail).
    if (opts.request_key) |key| {
        try w.writeI64(opts.requested_by);
        try w.writeBytes(&key);
    }
    return w.written();
}

/// NetPackageWorldSpawnPoints body: SpawnPointList (RE
/// ../7dtd-engine-research/il/full-v3.2.0/_global/SpawnPointList.il.txt write IL=25
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
