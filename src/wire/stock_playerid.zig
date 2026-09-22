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

