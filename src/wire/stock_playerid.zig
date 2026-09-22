//! PlayerId + spawn bodies: join PlayerId variants with PDF/journal
//! writes, the spawned-in-world confirm, and their layout tests.
//!
//! Split out of the packages.zig facade (same builders, same tests);
//! import via `packages.stock_playerid` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");
const stock_quest = @import("stock_quest.zig");
const stock_inv = @import("stock_inv.zig");
const stock_entity = @import("stock_entity.zig");
const parsePlayerDataEcdHead = @import("stock_motion.zig").parsePlayerDataEcdHead;

pub const PlayerIdOpts = struct {
    quests: []const stock_quest.StockQuestWrite = &.{},
    unlocked_recipes: []const []const u8 = &.{},
    toolbelt: []const stock_inv.StockSlot = &.{},
    bag: []const stock_inv.StockSlot = &.{},
    b_loaded: bool = true,
    game_stage_born_at: u64 = game_stage_born_unset,
    /// Character-sheet counters (`PlayerDataFile.playerKills/zombieKills/
    /// deaths/score`). Stock carries these in the save, so a join that writes
    /// 0 resets a returning player's sheet even though its own PlayerDataFile
    /// held the totals; the restored values ride here.
    player_kills: i32 = 0,
    zombie_kills: i32 = 0,
    deaths: i32 = 0,
    score: i32 = 0,
    /// The client's own character profile, as sent in
    /// `NetPackageRequestToSpawnPlayer` (stock stores it on the ECD:
    /// `GameManager::RequestToSpawnPlayer` `GameManager.il.txt:4614-4617`).
    /// Null keeps the offline default appearance.
    profile: ?stock_entity.PlayerProfile = null,
    /// The player's display name for the ECD (`ClientInfo.playerName` in
    /// stock). Bounded by the caller's own name buffer.
    player_name: []const u8 = "Player",
};

/// NetPackagePlayerId with default options (see buildPlayerIdBodyWithOpts for
/// the RE field order, write IL=21).
pub fn buildPlayerIdBody(buf: []u8, entity_id: i32, team: i16, chunk_view_dim: i32, sx: i32, sy: i32, sz: i32) ![]u8 {
    return buildPlayerIdBodyWithOpts(buf, entity_id, team, chunk_view_dim, sx, sy, sz, .{});
}

/// NetPackagePlayerId carrying the join inventory (see buildPlayerIdBodyWithOpts
/// for the RE field order, write IL=21).
pub fn buildPlayerIdBodyInv(
    buf: []u8,
    entity_id: i32,
    team: i16,
    chunk_view_dim: i32,
    sx: i32,
    sy: i32,
    sz: i32,
    quests: []const stock_quest.StockQuestWrite,
    unlocked_recipes: []const []const u8,
    toolbelt: []const stock_inv.StockSlot,
    bag: []const stock_inv.StockSlot,
) ![]u8 {
    return buildPlayerIdBodyWithOpts(buf, entity_id, team, chunk_view_dim, sx, sy, sz, .{
        .quests = quests,
        .unlocked_recipes = unlocked_recipes,
        .toolbelt = toolbelt,
        .bag = bag,
    });
}

/// EntityPlayer::Init seeds gameStageBornAtWorldTime to -1 (asm.il ~503740);
/// PlayerDataFile::CopyTo then clamps anything above the current world time
/// down to it (asm.il ~1975949), so the sentinel reads as zero days survived.
pub const game_stage_born_unset: u64 = std.math.maxInt(u64);

/// NetPackagePlayerId (RE inventories/netpackage-bodies.md, write IL=21):
/// `id` i32 | `teamNumber` i16 | `playerDataFile` (PlayerDataFile.WriteNetwork)
/// | `chunkViewDim` i32. The PDF body is written by
/// writeEmptyPlayerDataFileNetwork.
pub fn buildPlayerIdBodyWithOpts(
    buf: []u8,
    entity_id: i32,
    team: i16,
    chunk_view_dim: i32,
    sx: i32,
    sy: i32,
    sz: i32,
    opts: PlayerIdOpts,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeI16(team);
    try writeEmptyPlayerDataFileNetwork(&w, entity_id, sx, sy, sz, opts);
    try w.writeI32(chunk_view_dim);
    return w.written();
}

/// NetPackagePlayerId (RE write IL=21; field order in buildPlayerIdBodyWithOpts).
/// Like buildPlayerIdBodyInv; b_loaded=false for death-respawn re-bundle (avoids
/// GameManager.PlayerId CreateEntity+ToPlayer on an already-spawned local player).
/// `game_stage_born_at` is the server's survival-streak origin in world ticks,
/// so the client's own `gamestage` console command agrees with the server.
pub fn buildPlayerIdBodyInvLoaded(
    buf: []u8,
    entity_id: i32,
    team: i16,
    chunk_view_dim: i32,
    sx: i32,
    sy: i32,
    sz: i32,
    quests: []const stock_quest.StockQuestWrite,
    unlocked_recipes: []const []const u8,
    toolbelt: []const stock_inv.StockSlot,
    bag: []const stock_inv.StockSlot,
    b_loaded: bool,
    game_stage_born_at: u64,
) ![]u8 {
    return buildPlayerIdBodyWithOpts(buf, entity_id, team, chunk_view_dim, sx, sy, sz, .{
        .quests = quests,
        .unlocked_recipes = unlocked_recipes,
        .toolbelt = toolbelt,
        .bag = bag,
        .b_loaded = b_loaded,
        .game_stage_born_at = game_stage_born_at,
    });
}

/// Minimal empty PlayerDataFile.WriteNetwork (Write + PlayerMetaInfo.Write).
pub fn writeEmptyPlayerDataFileNetwork(
    w: *binary.Writer,
    entity_id: i32,
    sx: i32,
    sy: i32,
    sz: i32,
    opts: PlayerIdOpts,
) !void {
    const quests = opts.quests;
    const unlocked_recipes = opts.unlocked_recipes;
    const toolbelt = opts.toolbelt;
    const bag = opts.bag;
    const b_loaded = opts.b_loaded;
    const game_stage_born_at = opts.game_stage_born_at;
    const px: f32 = @floatFromInt(sx);
    const py: f32 = @floatFromInt(sy);
    const pz: f32 = @floatFromInt(sz);
    const profile = opts.profile;
    const player_name = opts.player_name;
    // --- EntityCreationData.write(bw, networkWrite=false) ---
    // V3.1.0 ECD FileVersion=36. Use the player class matching the client's own
    // profile so GameManager.PlayerId with bLoaded=true can CreateEntity +
    // ToPlayer (applies bag/toolbelt) and the client adopts its real
    // appearance; the offline default stays playerMale.
    const player_class: i32 = if (profile) |p|
        (if (p.is_male) stock_entity.class_player_male else stock_entity.class_player_female)
    else
        stock_entity.class_player_male;
    try w.writeByte(36); // FileVersion
    try w.writeI32(player_class);
    try w.writeI32(entity_id); // id (match PlayerId entity)
    try w.writeF32(std.math.floatMax(f32)); // lifetime
    try w.writeF32(px);
    try w.writeF32(py);
    try w.writeF32(pz); // pos
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0); // rot
    try w.writeBool(true); // onGround
    // BodyDamage.Write: cBinaryVersion=4, damageType=0, Flags=0
    try w.writeI32(4);
    try w.writeI32(0);
    try w.writeU32(0);
    try w.writeBool(false); // no EntityStats
    try w.writeI16(0); // deathTime
    try w.writeBool(false); // no bag
    try w.writeI32(sx);
    try w.writeI32(sy);
    try w.writeI32(sz); // homePosition
    try w.writeI16(-1); // homeRange
    try w.writeByte(0); // spawnerSource
    // player branch: holdingItem, team, name, skin, profile
    try stock_inv.writeEmptyItemValue(w);
    try w.writeByte(0); // teamNumber
    try w.writeString(player_name);
    try w.writeString(""); // skinTexture
    try w.writeBool(true); // has PlayerProfile
    try stock_entity.writePlayerProfile(w, profile orelse .{
        .archetype = "BaseMale",
        .is_male = true,
        .race_name = "White",
        .variant_number = 1,
        .eye_color = "Blue01",
    });
    try w.writeU16(0); // entityData length
    try w.writeBool(false); // no traderData
    // networkWrite=false: skip sleeper/spawnBy/head/override fields
    try w.writeF32(0); // stressAmount (ECD v36 tail)

    // --- PlayerDataFile.Write remainder ---
    // inventory (toolbelt) ItemStack list: pad to stock PUBLIC_SLOTS (10)
    var tb_pad: [stock_inv.toolbelt_slots]stock_inv.StockSlot = [_]stock_inv.StockSlot{.{}} ** stock_inv.toolbelt_slots;
    {
        const n = @min(toolbelt.len, tb_pad.len);
        @memcpy(tb_pad[0..n], toolbelt[0..n]);
    }
    try stock_inv.writeItemStackList(w, tb_pad[0..]);
    try w.writeByte(0); // selectedInventorySlot
    // Bag: pad to stock CarryCapacity base (45). Mismatched counts resize the
    // client bag via Bag.ReadInto and leave every slot occupied (AddItem fails).
    var bag_pad: [stock_inv.bag_slots]stock_inv.StockSlot = [_]stock_inv.StockSlot{.{}} ** stock_inv.bag_slots;
    {
        const n = @min(bag.len, bag_pad.len);
        @memcpy(bag_pad[0..n], bag[0..n]);
    }
    try stock_inv.writeBag(w, bag_pad[0..], true);
    // dragAndDropItem as 1-element empty stack list
    try w.writeU16(1);
    try w.writeU16(0); // ItemStack.count == 0 (no ItemValue)
    try w.writeU16(0); // alreadyCraftedList
    try w.writeByte(0); // spawnPoints count (stock always writes 0 here)
    try w.writeI64(0); // selectedSpawnPointKey
    try w.writeBool(true); // stock hardcodes true
    try w.writeI16(0); // stock hardcodes 0
    // bLoaded=true → first join: ToPlayer applies toolbelt/bag. false on death
    // re-bundle so PlayerId does not re-CreateEntity the local player (NRE).
    try w.writeBool(b_loaded);
    // lastSpawnPosition: world spawn + heading
    try w.writeI32(sx);
    try w.writeI32(sy);
    try w.writeI32(sz);
    try w.writeF32(0);
    try w.writeI32(-1); // pdf id
    try w.writeI32(opts.player_kills);
    try w.writeI32(opts.zombie_kills);
    try w.writeI32(opts.deaths);
    try w.writeI32(opts.score);
    // Equipment.Write: version 4, 12 empty ItemValues, 12 cosmetic i32 zeros, unlocked 0
    try w.writeByte(4);
    var i: usize = 0;
    while (i < 12) : (i += 1) try w.writeByte(0); // null/empty ItemValue
    i = 0;
    while (i < 12) : (i += 1) try w.writeI32(0); // cosmetic slot ids
    try w.writeI32(0); // unlocked cosmetics count
    // unlockedRecipeList: u16 count + 7DTD strings (always_unlocked craft names)
    const unlock_n: u16 = @intCast(@min(unlocked_recipes.len, 512));
    try w.writeU16(unlock_n);
    var ui: usize = 0;
    while (ui < unlock_n) : (ui += 1) {
        try w.writeString(unlocked_recipes[ui]);
    }
    try w.writeU16(1); // stock hardcodes 1 before marker
    try w.writeI32(0);
    try w.writeI32(0);
    try w.writeI32(0); // markerPosition Vector3i
    try w.writeBool(false); // markerHidden
    try w.writeBool(false); // bCrouchedLocked
    // CraftingData.Write: version u16=2, recipe queue len byte=0
    try w.writeU16(2);
    try w.writeByte(0);
    try w.writeU16(0); // favoriteRecipeList
    try w.writeU32(0); // totalItemsCrafted
    try w.writeF32(0); // distanceWalked
    try w.writeF32(0); // longestLife
    try w.writeU64(game_stage_born_at); // gameStageBornAtWorldTime
    // WaypointCollection.Write: version 7, count 0
    try w.writeByte(7);
    try w.writeU16(0);
    // QuestJournal.Write: v5 (empty or stock quests with known client IDs)
    try stock_quest.writeQuestJournal(w, quests);
    try w.writeI32(0); // deathUpdateTime
    try w.writeF32(0); // currentLife
    try w.writeBool(false); // bDead
    try w.writeByte(88); // stock format marker
    try w.writeBool(false); // bModdedSaveGame
    // ChallengeJournal: v1 early-return path. Empty v2 Read() touches
    // GameManager.World while deserializing PlayerId (World still null) and NREs.
    try w.writeByte(1);
    // rentedVMPosition Vector3i
    try w.writeI32(0);
    try w.writeI32(0);
    try w.writeI32(0);
    try w.writeI32(0); // rentalEndDay
    // progressionData / buffData / stealthData: length 0 (empty streams).
    // buffData would carry an EntityBuffs blob (asm.il 1977295); nothing to put
    // there until buffs survive a session, and live buff sync rides
    // AddRemoveBuff / EntityStatsBuff instead.
    try w.writeI32(0);
    try w.writeI32(0);
    try w.writeI32(0);
    try w.writeU16(0); // favoriteCreativeStacks
    try w.writeU16(0); // favoriteShapes
    try w.writeU16(0); // ownedEntities
    try w.writeF32(0); // totalTimePlayed
    // PlayerMetaInfo.Write: no native, no name, level 0, distance 0
    try w.writeBool(false);
    try w.writeBool(false);
    try w.writeI32(0);
    try w.writeF32(0);
}

test "player id body layout: header fields and non-empty pdf" {
    // PDF bag pads to CarryCapacity (45); keep headroom for quests/unlocks.
    var buf: [4096]u8 = undefined;
    const body = try buildPlayerIdBody(&buf, 171, 0, 4, -273, 61, 449);
    // Must be larger than the old 4-byte stub (id only).
    try std.testing.expect(body.len > 64);
    try std.testing.expectEqual(@as(i32, 171), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, body[4..6], .little));
    // ECD FileVersion byte immediately after team
    try std.testing.expectEqual(@as(u8, 36), body[6]);
    // chunkViewDim is the trailing i32
    const dim = std.mem.readInt(i32, body[body.len - 4 ..][0..4], .little);
    try std.testing.expectEqual(@as(i32, 4), dim);
    var r: binary.Reader = .{ .data = body };
    try std.testing.expectEqual(@as(i32, 171), try r.readI32());
    try std.testing.expectEqual(@as(i16, 0), try r.readI16());
    try std.testing.expectEqual(@as(u8, 36), try r.readByte()); // ECD FileVersion
    try std.testing.expectEqual(stock_entity.class_player_male, try r.readI32()); // entityClass
    try std.testing.expectEqual(@as(i32, 171), try r.readI32()); // ecd id
    _ = try r.readF32(); // lifetime
    try std.testing.expectEqual(@as(f32, -273), try r.readF32());
    try std.testing.expectEqual(@as(f32, 61), try r.readF32());
    try std.testing.expectEqual(@as(f32, 449), try r.readF32());

    // Anchor on the coordinate triple itself: -273 | 61 | 449 as i32 is a
    // distinct bit pattern from the same numbers written as f32 in the ECD
    // head above. Finding it proves the three words are adjacent and in order,
    // which is what a swap would break; the fields after it follow at a fixed
    // offset. This must run before body2 reuses `buf` underneath `body`.
    var want: [12]u8 = undefined;
    std.mem.writeInt(i32, want[0..4], -273, .little);
    std.mem.writeInt(i32, want[4..8], 61, .little);
    std.mem.writeInt(i32, want[8..12], 449, .little);
    // The triple appears twice: homePosition in the ECD, then
    // lastSpawnPosition in the PDF. Both are worth pinning, so take each.
    const home_at = std.mem.find(u8, body, &want) orelse return error.HomePosNotFound;
    const lsp = home_at + 12 +
        (std.mem.find(u8, body[home_at + 12 ..], &want) orelse return error.LastSpawnPosNotFound);
    try std.testing.expectEqual(@as(f32, 0), @as(f32, @bitCast(std.mem.readInt(u32, body[lsp + 12 ..][0..4], .little))));
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, body[lsp + 16 ..][0..4], .little)); // pdf id

    const body2 = try buildPlayerIdBody(&buf, 999, 3, 8, 0, 70, 0);
    try std.testing.expectEqual(@as(i32, 999), std.mem.readInt(i32, body2[0..4], .little));
    try std.testing.expectEqual(@as(i16, 3), std.mem.readInt(i16, body2[4..6], .little));
    try std.testing.expectEqual(@as(i32, 8), std.mem.readInt(i32, body2[body2.len - 4 ..][0..4], .little));
    try std.testing.expectEqual(body.len, body2.len);

    // lastSpawnPosition sits deep in the PDF, past a bag whose length depends
    // on CarryCapacity, so anchor on the bytes rather than count offsets:
    // `selectedSpawnPointKey` is the only i64 zero in the body and is followed
    // by a fixed run (bool true, i16 0, bool bLoaded) before the position.
    // Nothing read this triple back, and a swap would tell a joining client
    // its last spawn was somewhere it never stood.
}

test "player id PDF pins the drag-drop list, the score counters and the save marker" {
    // Wire-order audit 2026-09-11: three adjacent same-width pairs in the join
    // PDF survived every test in the suite. Swapping any of them changes what a
    // joining client reads - different kill/death counters, a zero-length
    // dragAndDropItem list, or a bDead of 88 - and the whole suite stayed
    // green, so nothing was pinning the PDF's field order at those offsets.
    var buf: [16384]u8 = undefined;
    const body = try buildPlayerIdBodyWithOpts(&buf, 171, 0, 4, -273, 61, 449, .{
        .player_kills = 11,
        .zombie_kills = 22,
        .deaths = 33,
        .score = 44,
    });

    // pdf id (-1) then the four counters, in stock PlayerDataFile.Write order.
    // Distinct values keep the run unique in the body.
    var counters: [20]u8 = undefined;
    std.mem.writeInt(i32, counters[0..4], -1, .little);
    std.mem.writeInt(i32, counters[4..8], 11, .little); // playerKills
    std.mem.writeInt(i32, counters[8..12], 22, .little); // zombieKills
    std.mem.writeInt(i32, counters[12..16], 33, .little); // deaths
    std.mem.writeInt(i32, counters[16..20], 44, .little); // score
    try std.testing.expect(std.mem.find(u8, body, &counters) != null);

    // dragAndDropItem is a one-element list whose single stack is empty, then
    // alreadyCraftedList, the spawnPoints count, selectedSpawnPointKey, the two
    // hardcoded fields and b_loaded. The long zero run followed by `01 00 01`
    // is what makes this window unique enough to search for.
    const drag_drop = [_]u8{
        1, 0, // dragAndDropItem list count 1
        0, 0, // its ItemStack.count 0 (no ItemValue)
        0, 0, // alreadyCraftedList
        0, // spawnPoints count
        0, 0, 0, 0, 0, 0, 0, 0, // selectedSpawnPointKey
        1, // stock hardcodes true
        0, 0, // stock hardcodes 0
        1, // b_loaded
    };
    try std.testing.expect(std.mem.find(u8, body, &drag_drop) != null);

    // deathUpdateTime(0) + currentLife(0) then bDead false and the 88 stock
    // format marker. The 88 byte is unique in the PDF, so this window pins the
    // pair directly.
    const dead_marker = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 88, 0, 1 };
    try std.testing.expect(std.mem.find(u8, body, &dead_marker) != null);
}

test "gameStageBornAtWorldTime rides the same offset as the -1 sentinel" {
    var a: [16384]u8 = undefined;
    var b: [16384]u8 = undefined;
    const dflt = try buildPlayerIdBodyInv(&a, 171, 0, 4, -273, 61, 449, &.{}, &.{}, &.{}, &.{});
    const born: u64 = 7 * 24000 + 12000;
    const set = try buildPlayerIdBodyInvLoaded(&b, 171, 0, 4, -273, 61, 449, &.{}, &.{}, &.{}, &.{}, true, born);
    // Only the eight bytes of the field change; the body must not resize.
    try std.testing.expectEqual(dflt.len, set.len);
    const off = std.mem.find(u8, dflt, &@as([8]u8, @bitCast(game_stage_born_unset))) orelse
        return error.SentinelNotFound;
    try std.testing.expectEqual(born, std.mem.readInt(u64, set[off..][0..8], .little));
    var i: usize = 0;
    while (i < dflt.len) : (i += 1) {
        if (i >= off and i < off + 8) continue;
        try std.testing.expectEqual(dflt[i], set[i]);
    }
}

/// Stock RespawnType (byte stored as i32 on wire).
pub const RespawnType = enum(i32) {
    new_game = 0,
    loaded_game = 1,
    died = 2,
    teleport = 3,
    enter_multiplayer = 4,
    join_multiplayer = 5,
    unknown = 6,
};

/// NetPackagePlayerSpawnedInWorld body: reason:i32 | pos Vector3i | entityId:i32.
/// Prefer `enter_multiplayer` / `join_multiplayer` for dedi joins (not NewGame).
pub fn buildSpawnedBody(buf: []u8, reason: i32, x: i32, y: i32, z: i32, entity_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(reason);
    try w.writeI32(x);
    try w.writeI32(y);
    try w.writeI32(z);
    try w.writeI32(entity_id);
    return w.written();
}

/// Parse side of the same layout (read IL=14, GetLength 16): the client sends
/// this back after it finishes spawning locally, and stock's server
/// `ProcessPackage` (IL=47) validates the claimed entity against the sender
/// (`ValidEntityIdForSender`) before running `GameManager.PlayerSpawnedInWorld`
/// and rebroadcasting the confirm to every other peer on channel 192.
pub fn parseSpawnedBody(body: []const u8) !struct { reason: i32, x: i32, y: i32, z: i32, entity_id: i32 } {
    if (body.len < 20) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    return .{
        .reason = try r.readI32(),
        .x = try r.readI32(),
        .y = try r.readI32(),
        .z = try r.readI32(),
        .entity_id = try r.readI32(),
    };
}

test "spawned-in-world body is reason, position and entity id in that order" {
    // Five i32 in a row with nothing reading them back: the join path has four
    // call sites (game.zig, c2s/join.zig) and no wire test covered any of
    // them, so a swapped pair here would tell the client it spawned at a
    // coordinate built from the reason code.
    var buf: [32]u8 = undefined;
    const body = try buildSpawnedBody(
        &buf,
        @intFromEnum(RespawnType.enter_multiplayer),
        -273,
        61,
        449,
        106,
    );
    try std.testing.expectEqual(@as(usize, 20), body.len);
    try std.testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(i32, -273), std.mem.readInt(i32, body[4..8], .little));
    try std.testing.expectEqual(@as(i32, 61), std.mem.readInt(i32, body[8..12], .little));
    try std.testing.expectEqual(@as(i32, 449), std.mem.readInt(i32, body[12..16], .little));
    try std.testing.expectEqual(@as(i32, 106), std.mem.readInt(i32, body[16..20], .little));
    // ...and the parser reads those same five positions back. The parse side
    // had no test at all: only `entity_id` was exercised (the spawn-confirm
    // scenario), so the mutant audit found reason/x/y/z interchangeable. Every
    // value here is distinct, which is what pins the order.
    const p = try parseSpawnedBody(body);
    try std.testing.expectEqual(@as(i32, 4), p.reason);
    try std.testing.expectEqual(@as(i32, -273), p.x);
    try std.testing.expectEqual(@as(i32, 61), p.y);
    try std.testing.expectEqual(@as(i32, 449), p.z);
    try std.testing.expectEqual(@as(i32, 106), p.entity_id);
}

test "player data ecd head from empty pdf write" {
    var buf: [4096]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try writeEmptyPlayerDataFileNetwork(&w, 106, -273, 61, 449, .{});
    const body = w.written();
    const h = try parsePlayerDataEcdHead(body);
    try std.testing.expectEqual(@as(i32, 106), h.entity_id);
    // The parser no longer returns the position (origin-relative, unusable
    // server-side), but the bytes must still sit where the ECD head puts them,
    // or the length validation above would be checking the wrong layout:
    // FileVersion u8 | entityClass i32 | id i32 | lifetime f32 | pos f32 x3.
    const pos_off = 1 + 4 + 4 + 4;
    const px: f32 = @bitCast(std.mem.readInt(u32, body[pos_off..][0..4], .little));
    const py: f32 = @bitCast(std.mem.readInt(u32, body[pos_off + 4 ..][0..4], .little));
    const pz: f32 = @bitCast(std.mem.readInt(u32, body[pos_off + 8 ..][0..4], .little));
    try std.testing.expectApproxEqAbs(@as(f32, -273), px, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 61), py, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 449), pz, 0.01);
}
test "player id body wraps the PDF with entityId, team and chunkViewDim" {
    // NetPackagePlayerId (RE write IL=21) is entityId i32 | team i16 |
    // PlayerDataFile.WriteNetwork | chunkViewDim i32. The join path builds it
    // (game.zig) and no wire test covered the frame around the PDF, only the
    // ECD head inside it, so the three outer fields and this body's own copy
    // of the ECD position run had nothing reading them back.
    var buf: [8192]u8 = undefined;
    const body = try buildPlayerIdBodyInvLoaded(
        &buf,
        106, // entity id
        7, // team: distinct from every neighbouring constant
        5, // chunkViewDim
        -273,
        61,
        449,
        &.{},
        &.{},
        &.{},
        &.{},
        true,
        game_stage_born_unset,
    );
    try std.testing.expectEqual(@as(i32, 106), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(i16, 7), std.mem.readInt(i16, body[4..6], .little));
    // chunkViewDim closes the body.
    try std.testing.expectEqual(@as(i32, 5), std.mem.readInt(i32, body[body.len - 4 ..][0..4], .little));

    // The PDF's ECD head starts at byte 6: FileVersion u8 | entityClass i32 |
    // id i32 | lifetime f32 | pos f32 x3.
    const ecd = 6;
    try std.testing.expectEqual(@as(u8, 36), body[ecd]);
    try std.testing.expectEqual(stock_entity.class_player_male, std.mem.readInt(i32, body[ecd + 1 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 106), std.mem.readInt(i32, body[ecd + 5 ..][0..4], .little));
    const f32At = struct {
        fn get(b: []const u8, off: usize) f32 {
            return @bitCast(std.mem.readInt(u32, b[off..][0..4], .little));
        }
    }.get;
    try std.testing.expectEqual(std.math.floatMax(f32), f32At(body, ecd + 9)); // lifetime
    try std.testing.expectApproxEqAbs(@as(f32, -273), f32At(body, ecd + 13), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 61), f32At(body, ecd + 17), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 449), f32At(body, ecd + 21), 0.01);

    // Then rot f32 x3 | onGround bool | BodyDamage (cBinaryVersion 4, type 0,
    // flags 0) | hasStats bool | deathTime i16 | hasBag bool | homePosition
    // i32 x3 | homeRange i16 | spawnerSource u8. None of that was read back,
    // so the version 4 could swap with the zero beside it and homePosition's
    // three words could rotate.
    const after_rot = ecd + 25 + 12; // past pos, rot
    try std.testing.expectEqual(@as(u8, 1), body[after_rot]); // onGround
    const bd = after_rot + 1;
    try std.testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, body[bd..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, body[bd + 4 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, body[bd + 8 ..][0..4], .little));
    const home = bd + 12 + 1 + 2 + 1; // past hasStats, deathTime, hasBag
    try std.testing.expectEqual(@as(i32, -273), std.mem.readInt(i32, body[home..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 61), std.mem.readInt(i32, body[home + 4 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 449), std.mem.readInt(i32, body[home + 8 ..][0..4], .little));
    try std.testing.expectEqual(@as(i16, -1), std.mem.readInt(i16, body[home + 12 ..][0..2], .little));
}
test "player id PDF bag is CarryCapacity empties" {
    var buf: [8192]u8 = undefined;
    // Non-empty starter-like stacks in bag[0..3]; rest must pad empty.
    var bag: [4]stock_inv.StockSlot = .{
        .{ .type_id = stock_inv.items_start_here + 8, .count = 1 },
        .{ .type_id = stock_inv.items_start_here + 2, .count = 5 },
        .{ .type_id = stock_inv.items_start_here + 7, .count = 20 },
        .{ .type_id = stock_inv.items_start_here + 6, .count = 50 },
    };
    const body = try buildPlayerIdBodyInv(&buf, 171, 0, 4, -273, 61, 449, &.{}, &.{}, &.{}, bag[0..]);
    var r: binary.Reader = .{ .data = body };
    _ = try r.readI32(); // entity
    _ = try r.readI16(); // team
    // Skip ECD via stock_inv helper (player branch + v36 stress).
    _ = try stock_inv.skipEcdNetworkWriteFalse(&r);
    const tb_n = try r.readU16();
    try std.testing.expectEqual(@as(u16, @intCast(stock_inv.toolbelt_slots)), tb_n);
    var i: usize = 0;
    while (i < tb_n) : (i += 1) {
        const c = try r.readU16();
        try std.testing.expectEqual(@as(u16, 0), c);
    }
    _ = try r.readByte(); // selected
    try std.testing.expectEqual(@as(u8, 1), try r.readByte()); // bag ver
    const bag_n = try r.readU16();
    try std.testing.expectEqual(@as(u16, @intCast(stock_inv.bag_slots)), bag_n);
    var nonempty: usize = 0;
    i = 0;
    while (i < bag_n) : (i += 1) {
        const c = try r.readU16();
        if (c != 0) {
            nonempty += 1;
            // skip ItemValue v9 minimal
            try std.testing.expectEqual(@as(u8, 9), try r.readByte());
            _ = try r.readByte(); // flags
            _ = try r.readU16(); // type
            _ = try r.readF32();
            _ = try r.readU16();
            _ = try r.readU16();
            _ = try r.readByte(); // meta count
            _ = try r.readByte();
            _ = try r.readByte(); // mods
            _ = try r.readByte();
            _ = try r.readByte();
            _ = try r.readU16();
            _ = try r.readBool();
        }
    }
    try std.testing.expectEqual(@as(usize, 4), nonempty);
}

test "ConfirmSpawnEntity golden layout: i64 id + 16-byte request key (V3.2.0)" {
    const key = [16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    var buf: [32]u8 = undefined;
    const body = try buildConfirmSpawnEntityBody(&buf, -5, &key);
    try std.testing.expectEqual(@as(usize, 24), body.len);
    try std.testing.expectEqual(@as(i64, -5), std.mem.readInt(i64, body[0..8], .little));
    try std.testing.expectEqualSlices(u8, &key, body[8..24]);
}

/// NetPackageConfirmSpawnEntity body (V3.2.0, changelog-3.2.0 §3.3):
/// createdEntityId:i64 (an Int32 field widened on write) + requestKey
/// Guid.ToByteArray bytes[16]. Sent only for client-requested entity spawns
/// (EntityCreationData.requestedBy/requestKey). zdtd drops generic spawn
/// requests (c2s/misc.zig RequestToSpawnEntity), so no live flow emits this;
/// the builder pins the shape for that path and for goldens.
pub fn buildConfirmSpawnEntityBody(buf: []u8, created_entity_id: i64, key: *const [16]u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI64(created_entity_id);
    try w.writeBytes(key);
    return w.written();
}

/// NetPackageRequestToSpawnPlayer (RE inventories/netpackage-bodies.md write
/// IL=17, protocol.md §5): `chunkViewDim` i16 | `playerProfile`
/// (PlayerProfile.Write) | `nearEntityId` i32.
///
/// Only `chunkViewDim` is read. The profile is the client's display copy and
/// the server owns the real one, so parsing it would buy nothing; `nearEntityId`
/// sits behind that variable-length blob and is unused server-side. It used to
/// be grabbed from the last four bytes without parsing the profile, which is a
/// guess rather than a read: on a short body those four bytes overlap
/// chunkViewDim itself. Reading a field we do not use, from an offset we did
/// not derive, is strictly worse than not reading it.
pub fn parseRequestToSpawnPlayer(body: []const u8) !struct { chunk_view_dim: i32 } {
    if (body.len < 2) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    return .{ .chunk_view_dim = try r.readI16() };
}

/// The client's `PlayerProfile` out of a `NetPackageRequestToSpawnPlayer` body
/// (stock read IL=14: `chunkViewDim:i16`, then `PlayerProfile::Read`). Separate
/// from parseRequestToSpawnPlayer so a body without the profile still yields
/// the dim, and a malformed profile leaves the caller on its default
/// appearance instead of dropping the spawn.
pub fn parseRequestToSpawnProfile(body: []const u8) !stock_entity.OwnedProfile {
    if (body.len < 2 + 4) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    _ = try r.readI16();
    return stock_entity.readOwnedProfile(&r);
}

test "RequestToSpawnPlayer reads only the leading chunkViewDim" {
    // A bare two-byte body is legal: everything after chunkViewDim is the
    // client's profile blob plus a field the server does not use.
    var two: [2]u8 = undefined;
    std.mem.writeInt(i16, &two, 4, .little);
    try std.testing.expectEqual(@as(i32, 4), (try parseRequestToSpawnPlayer(&two)).chunk_view_dim);

    // A trailing blob must not change what is read. The old code took the last
    // four bytes as nearEntityId, so a body this shape used to reinterpret its
    // own header bytes; asserting the dim is stable pins that it no longer
    // depends on the body's length.
    var long: [24]u8 = @splat(0xAB);
    std.mem.writeInt(i16, long[0..2], 4, .little);
    try std.testing.expectEqual(@as(i32, 4), (try parseRequestToSpawnPlayer(&long)).chunk_view_dim);

    // Shorter than the one field it does read is an error, not a zero.
    var one: [1]u8 = .{0};
    try std.testing.expectError(error.EndOfStream, parseRequestToSpawnPlayer(&one));
}

test "the client's profile round-trips out of RequestToSpawnPlayer" {
    // Body shape from NetPackageRequestToSpawnPlayer (read IL=14):
    // chunkViewDim:i16 | PlayerProfile (v5) | nearEntityId:i32.
    var buf: [256]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try w.writeI16(4);
    try stock_entity.writePlayerProfile(&w, .{
        .archetype = "BaseFemale",
        .is_male = false,
        .race_name = "Black",
        .variant_number = 3,
        .hair_name = "hairFemaleShort",
        .hair_color = "0,0,0",
        .mustache_name = "",
        .chops_name = "",
        .beard_name = "",
        .eye_color = "Green01",
    });
    try w.writeI32(-1);
    const body = w.written();

    const p = try parseRequestToSpawnProfile(body);
    try std.testing.expectEqualStrings("BaseFemale", p.view().archetype);
    try std.testing.expect(!p.view().is_male);
    try std.testing.expectEqualStrings("Black", p.view().race_name);
    try std.testing.expectEqual(@as(u8, 3), p.view().variant_number);
    try std.testing.expectEqualStrings("hairFemaleShort", p.view().hair_name);
    try std.testing.expectEqualStrings("Green01", p.view().eye_color);
    // The dim still parses from the same body.
    try std.testing.expectEqual(@as(i32, 4), (try parseRequestToSpawnPlayer(body)).chunk_view_dim);
    // A body without the profile blob yields the dim and no profile.
    var dim_only: [2]u8 = undefined;
    std.mem.writeInt(i16, &dim_only, 6, .little);
    try std.testing.expectError(error.EndOfStream, parseRequestToSpawnProfile(&dim_only));
    try std.testing.expectEqual(@as(i32, 6), (try parseRequestToSpawnPlayer(&dim_only)).chunk_view_dim);
}

test "a received profile drives the PDF player class and appearance" {
    var pbuf: [256]u8 = undefined;
    var pw: binary.Writer = .{ .buf = &pbuf };
    try pw.writeI16(4);
    try stock_entity.writePlayerProfile(&pw, .{
        .archetype = "BaseFemale",
        .is_male = false,
        .race_name = "Black",
        .variant_number = 3,
        .eye_color = "Green01",
    });
    try pw.writeI32(0);
    const prof = try parseRequestToSpawnProfile(pw.written());

    var buf: [4096]u8 = undefined;
    const body = try buildPlayerIdBodyWithOpts(&buf, 7, 0, 4, 1, 2, 3, .{
        .profile = prof.view(),
        .player_name = "Ann",
    });
    // id i32 + team i16, then the ECD FileVersion byte and the entityClass:
    // the female player class.
    try std.testing.expectEqual(@as(u8, 36), body[6]);
    try std.testing.expectEqual(@as(i32, stock_entity.class_player_female), std.mem.readInt(i32, body[7..11], .little));
    try std.testing.expect(std.mem.find(u8, body, "BaseFemale") != null);
    try std.testing.expect(std.mem.find(u8, body, "Green01") != null);
    try std.testing.expect(std.mem.find(u8, body, "Ann") != null);
    // Without a profile the body keeps the offline default (male class).
    const dflt = try buildPlayerIdBodyWithOpts(&buf, 7, 0, 4, 1, 2, 3, .{});
    try std.testing.expectEqual(@as(i32, stock_entity.class_player_male), std.mem.readInt(i32, dflt[7..11], .little));
    try std.testing.expect(std.mem.find(u8, dflt, "BaseMale") != null);
}
