//! GameStats bodies: live-override values struct, the persistent
//! blob builder, and the layout tests.
//!
//! Split out of the packages.zig facade (same code, same tests);
//! import via `packages.stock_gamestats` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// Live overrides for persistent GameStats.Write fields (stock defaults otherwise).
/// RE: EnumGameStats + initPropertyDecl bPersistent filter (sandbox-options §6.1).
/// There is **no** current-day field in the net blob; HUD day comes from
/// NetPackageWorldTime (`worldTime / 24000`). BloodMoonDay is the scheduled BM day.
pub const GameStatsValues = struct {
    game_difficulty: i32 = 2,
    blood_moon_enemy_count: i32 = 8,
    enemy_difficulty: i32 = 0,
    day_light_length: i32 = 18,
    day_night_length: i32 = 60,
    blood_moon_day: i32 = 0,
    blood_moon_warning: i32 = 1, // stock live value: warn one day ahead
    block_damage_player: i32 = 100,
    block_damage_ai: i32 = 100,
    block_damage_ai_bm: i32 = 100,
    xp_multiplier: i32 = 100,
    player_killing_mode: i32 = 3,
    drop_on_death: i32 = 1,
    land_claim_size: i32 = 41,
    land_claim_online_dur: i32 = 32,
    land_claim_offline_dur: i32 = 32,
    air_drop_frequency: i32 = 0,
    party_shared_kill_range: i32 = 100,
    show_friend_player_on_map: bool = true,
    /// GameStats[18]/[20] IsCreativeMenuEnabled / IsFlyingEnabled: stock seeds
    /// both from GamePrefs 58 `BuildCreate`
    /// (server-lifecycle.md GameStats table), so a server running with cheat
    /// mode on hands the client its creative menu and flight.
    build_create: bool = false,
    /// GameStats[53] AirDropMarker (sandbox option, default on).
    air_drop_marker: bool = true,
    /// GameStats[34] DropOnQuit (sandbox option `DropOnQuit`, distinct from
    /// DropOnDeath).
    drop_on_quit: i32 = 0,
    /// GameStats[66] BiomeProgression (sandbox option, default on).
    biome_progression: bool = true,
    /// GameStats[68] CameraRestrictionMode (serverconfig).
    camera_restriction_mode: i32 = 0,
    /// GameStats[29] ScorePlayerKillMultiplier: `GameModeSurvival::Init`
    /// IL_0035-0038 sets it to 0 (a player kill scores nothing), while
    /// [28] ScoreZombieKillMultiplier is 1 and [30] ScoreDiedMultiplier -5
    /// (IL_003D-0049). Mode semantics, not a tunable.
    score_player_kill_multiplier: i32 = 0,
    is_spawn_enemies: bool = true,
    enemy_spawn_mode: bool = true,
    /// GameStats[11] TimeOfDayIncPerSec = 24000 / (DayNightLength * 60) in
    /// integer arithmetic: 6 at the stock 60 real-minute day (live `getgamestat`
    /// 2026-08-12). Callers pass the WorldClock's own rate.
    time_of_day_inc_per_sec: i32 = 6,
    death_penalty: i32 = 1,
    quest_progression_daily_limit: i32 = 4,
    /// Percent, stock GamePrefs.StormFreq default 100 (asm.il 1908835). Also the
    /// source of World::StormFrequency (the 1.0 multiplier the storm scheduler divides by).
    storm_freq: i32 = 100,
    loot_abundance: i32 = 100,
    loot_respawn_days: i32 = 7,
    bedroll_expiry_time: i32 = 45,
    land_claim_count: i32 = 5,
    land_claim_dead_zone: i32 = 30,
    land_claim_expiry_time: i32 = 3,
    land_claim_decay_mode: i32 = 0,
    land_claim_offline_delay: i32 = 0,
    jar_refund: i32 = 60,
    sandbox_preset: []const u8 = "",
    sandbox_code: []const u8 = "",
};

/// Stock NetPackageGameStats body: i16 payload_len + GameStats.Write blob.
/// Write emits only bPersistent PropertyDecls in engine propertyList order with
/// no name/id prefix (RE sandbox-options §6.1, GameStats.il Write IL=60).
/// Empty payload (len=0) remains valid. Full blob uses stock defaults + overrides.
///
/// **propertyList order is not EnumGameStats order.** `initPropertyDecl`
/// (IL=702, `il/full-v3.2.0/_global/GameStats.il.txt`) fills 78 slots with
/// literal enum ids that are out of order in several places: slot 4/5 carry
/// FragLimit (enum 6/7) and slot 6/7 carry DayLimit (enum 4/5), slot 14 carries
/// IsSpawnNearOtherPlayer (enum 25) ahead of TimeOfDayIncPerSec (enum 11), and
/// nine slots are non-persistent and skipped entirely (EnemyCount and
/// AnimalCount among them). Since the blob carries no field names, the writes
/// below follow slot order; the enum index table in
/// inventories/gamestats-gameprefs.md documents the enum, not this order, and
/// reordering these lines to match it would shift every later field.
pub fn buildGameStatsBodyValues(buf: []u8, v: GameStatsValues) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    // Reserve i16 length; fill after payload.
    try w.writeI16(0);
    const payload_start = w.pos;

    // propertyList order, bPersistent only (78 decls, 9 skipped). Types: 0=i32 2=string 3=bool.
    // EnumGameState.Running. Not cosmetic: PlayerMoveController.Update runs
    // updateRespawn() only while GameStats[GameState] == 1, else it calls
    // stopMoving() and returns. Sending 0 (Loading) freezes the client's
    // respawn machine in WaitingForSpawnWindowToClose, so the loading screen
    // is never closed even though the world, player and colliders are live.
    try w.writeI32(1); // GameState
    try w.writeI32(0); // GameModeId
    try w.writeBool(false); // TimeLimitActive
    try w.writeI32(0); // TimeLimitThisRound
    try w.writeBool(false); // FragLimitActive
    try w.writeI32(0); // FragLimitThisRound
    try w.writeBool(false); // DayLimitActive
    try w.writeI32(0); // DayLimitThisRound
    try w.writeString(""); // ShowWindow
    try w.writeString(""); // LoadScene
    try w.writeI32(0); // CurrentRoundIx
    try w.writeBool(false); // ShowAllPlayersOnMap
    try w.writeBool(v.show_friend_player_on_map); // ShowFriendPlayerOnMap
    try w.writeBool(false); // ShowSpawnWindow
    try w.writeBool(false); // IsSpawnNearOtherPlayer
    try w.writeI32(v.time_of_day_inc_per_sec); // TimeOfDayIncPerSec
    try w.writeBool(v.build_create); // IsCreativeMenuEnabled (GamePrefs 58)
    try w.writeBool(false); // IsTeleportEnabled
    try w.writeBool(v.build_create); // IsFlyingEnabled (GamePrefs 58)
    try w.writeBool(true); // IsPlayerDamageEnabled
    try w.writeBool(true); // IsPlayerCollisionEnabled
    try w.writeBool(v.is_spawn_enemies); // IsSpawnEnemies
    try w.writeI32(v.player_killing_mode); // PlayerKillingMode
    try w.writeI32(v.score_player_kill_multiplier); // ScorePlayerKillMultiplier
    try w.writeI32(1); // ScoreZombieKillMultiplier
    try w.writeI32(-5); // ScoreDiedMultiplier
    try w.writeI32(v.drop_on_death); // DropOnDeath
    try w.writeI32(v.drop_on_quit); // DropOnQuit (sandbox)
    try w.writeI32(v.game_difficulty); // GameDifficulty
    try w.writeI32(v.blood_moon_enemy_count); // BloodMoonEnemyCount
    try w.writeBool(v.enemy_spawn_mode); // EnemySpawnMode
    try w.writeI32(v.enemy_difficulty); // EnemyDifficulty
    try w.writeI32(v.day_light_length); // DayLightLength
    try w.writeI32(v.land_claim_count); // LandClaimCount
    try w.writeI32(v.land_claim_size); // LandClaimSize
    try w.writeI32(v.land_claim_dead_zone); // LandClaimDeadZone
    try w.writeI32(v.land_claim_expiry_time); // LandClaimExpiryTime
    try w.writeI32(v.land_claim_decay_mode); // LandClaimDecayMode
    try w.writeI32(v.land_claim_online_dur); // LandClaimOnlineDurabilityModifier
    try w.writeI32(v.land_claim_offline_dur); // LandClaimOfflineDurabilityModifier
    try w.writeI32(v.land_claim_offline_delay); // LandClaimOfflineDelay
    try w.writeI32(v.bedroll_expiry_time); // BedrollExpiryTime
    try w.writeI32(v.air_drop_frequency); // AirDropFrequency
    try w.writeBool(v.air_drop_marker); // AirDropMarker (sandbox)
    try w.writeI32(v.party_shared_kill_range); // PartySharedKillRange
    try w.writeBool(false); // AutoParty
    try w.writeI32(0); // OptionsPOICulling
    try w.writeI32(v.blood_moon_day); // BloodMoonDay (scheduled, not HUD day)
    try w.writeI32(v.block_damage_player); // BlockDamagePlayer
    try w.writeI32(v.xp_multiplier); // XPMultiplier
    try w.writeI32(v.blood_moon_warning); // BloodMoonWarning
    try w.writeBool(true); // TwitchBloodMoonAllowed
    try w.writeI32(v.death_penalty); // DeathPenalty
    try w.writeI32(v.quest_progression_daily_limit); // QuestProgressionDailyLimit
    try w.writeBool(v.biome_progression); // BiomeProgression (sandbox)
    try w.writeI32(v.storm_freq); // StormFreq
    try w.writeI32(v.camera_restriction_mode); // CameraRestrictionMode
    try w.writeI32(v.jar_refund); // JarRefund
    try w.writeString(v.sandbox_preset); // SandboxPreset
    try w.writeString(v.sandbox_code); // SandboxCode
    try w.writeI32(v.day_night_length); // DayNightLength
    try w.writeI32(v.block_damage_ai); // BlockDamageAI
    try w.writeI32(v.block_damage_ai_bm); // BlockDamageAIBM
    try w.writeI32(v.loot_abundance); // LootAbundance
    try w.writeI32(v.loot_respawn_days); // LootRespawnDays
    try w.writeI32(100); // GlobalGSModifier
    try w.writeI32(100); // BiomeGSModifier
    try w.writeI32(100); // GlobalLSModifier
    try w.writeI32(100); // BiomeLSModifier

    const payload_len: i32 = @intCast(w.pos - payload_start);
    if (payload_len > std.math.maxInt(i16)) return error.Overflow;
    std.mem.writeInt(i16, buf[0..2], @intCast(payload_len), .little);
    return w.written();
}

test "GameStats body is i16 len + full persistent blob" {
    var buf: [512]u8 = undefined;
    const body = try buildGameStatsBodyValues(&buf, .{
        .game_difficulty = 3,
        .blood_moon_day = 14,
        .day_night_length = 90,
    });
    try std.testing.expect(body.len >= 4);
    const plen = std.mem.readInt(i16, body[0..2], .little);
    try std.testing.expectEqual(@as(usize, @intCast(plen)), body.len - 2);
    // Empty string defaults + 69 typed fields: payload is non-trivial (not empty blob).
    try std.testing.expect(plen > 100);
    const defaults = try buildGameStatsBodyValues(buf[256..], .{});
    try std.testing.expect(defaults.len > 100);

    // The blob carries no field names, so position is the only thing that
    // identifies a value. A length assertion alone cannot see a reordering,
    // which is exactly the defect this layout is prone to: pin the head
    // against the propertyList slot order in initPropertyDecl (IL=702).
    var r: binary.Reader = .{ .data = body[2..] };
    try std.testing.expectEqual(@as(i32, 1), try r.readI32()); // 0: GameState Running
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // 1: GameModeId
    try std.testing.expectEqual(false, try r.readBool()); // 2: TimeLimitActive
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // 3: TimeLimitThisRound
    // Slots 4..7 are Frag before Day (enum 6,7,4,5), not enum order.
    try std.testing.expectEqual(false, try r.readBool()); // 4: FragLimitActive
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // 5: FragLimitThisRound
    try std.testing.expectEqual(false, try r.readBool()); // 6: DayLimitActive
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // 7: DayLimitThisRound
    var s_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", try r.readString(&s_buf)); // 8: ShowWindow
    try std.testing.expectEqualStrings("", try r.readString(&s_buf)); // 9: LoadScene
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // 10: CurrentRoundIx

    // Slots 0..10 are all constant zeros and empty strings, so swapping two
    // same-typed neighbours there produces identical bytes and proves nothing.
    // Slots 11..15 are where the caller's values land, and they are the only
    // part of the head a reordering can actually be caught in: give each a
    // distinct value and read them back in slot order. Slot 14 is
    // IsSpawnNearOtherPlayer (enum 25), ahead of TimeOfDayIncPerSec (enum 11).
    var distinct: [512]u8 = undefined;
    const d = try buildGameStatsBodyValues(&distinct, .{
        .show_friend_player_on_map = true,
        .time_of_day_inc_per_sec = 37,
        // These three default to the same values as the hardcoded constants
        // written beside them: is_spawn_enemies is true next to a literal
        // true, and player_killing_mode / drop_on_death sit among the literal
        // 1 score multipliers. That made the whole slot run unobservable, so
        // pick values differing from both neighbours.
        .is_spawn_enemies = false,
        .player_killing_mode = 2,
        .drop_on_death = 3,
        // Same collision a few slots on: DropOnQuit is a literal 0 while
        // enemy_difficulty defaults to 0, and the difficulty / blood-moon /
        // daylight values have to differ from each other as well.
        .game_difficulty = 4,
        .blood_moon_enemy_count = 9,
        .enemy_difficulty = 5,
        .day_light_length = 19,
        .land_claim_count = 6,
        // The remaining caller-supplied collisions, found by walking the whole
        // write list against the fixture rather than one audit run at a time:
        // the two land-claim durability modifiers both default to 32, the
        // block-damage / XP / loot values all default to 100, and blood_moon_day
        // defaults to 0 next to the literal-0 OptionsPOICulling.
        .land_claim_online_dur = 31,
        .land_claim_offline_dur = 33,
        .blood_moon_day = 21,
        .block_damage_player = 101,
        .xp_multiplier = 102,
        .block_damage_ai = 103,
        .block_damage_ai_bm = 104,
        .loot_abundance = 105,
    });
    var dr: binary.Reader = .{ .data = d[2..] };
    dr.pos = r.pos; // same head width, already asserted field by field above
    try std.testing.expectEqual(false, try dr.readBool()); // 11: ShowAllPlayersOnMap
    try std.testing.expectEqual(true, try dr.readBool()); // 12: ShowFriendPlayerOnMap
    try std.testing.expectEqual(false, try dr.readBool()); // 13: ShowSpawnWindow
    try std.testing.expectEqual(false, try dr.readBool()); // 14: IsSpawnNearOtherPlayer
    try std.testing.expectEqual(@as(i32, 37), try dr.readI32()); // 15: TimeOfDayIncPerSec

    // Slots 16..20 are five hardcoded bools: three false then two true. A swap
    // inside either group is invisible by construction, but one across the
    // boundary turns player damage or collision off for every client, so read
    // all five and let the boundary carry the check.
    try std.testing.expectEqual(false, try dr.readBool()); // 16: IsCreativeMenuEnabled
    try std.testing.expectEqual(false, try dr.readBool()); // 17: IsTeleportEnabled
    try std.testing.expectEqual(false, try dr.readBool()); // 18: IsFlyingEnabled
    try std.testing.expectEqual(true, try dr.readBool()); // 19: IsPlayerDamageEnabled
    try std.testing.expectEqual(true, try dr.readBool()); // 20: IsPlayerCollisionEnabled
    // Slots 21..26 mix caller values with hardcoded score multipliers, which
    // is where the defaults collided: with is_spawn_enemies false and the two
    // i32 distinct from the literal 1 / -5 beside them, each position is now
    // observable.
    try std.testing.expectEqual(false, try dr.readBool()); // 21: IsSpawnEnemies
    try std.testing.expectEqual(@as(i32, 2), try dr.readI32()); // 22: PlayerKillingMode
    // 23 is 0 and 24 is 1: `GameModeSurvival::Init` IL_0035-0040 sets the
    // player-kill multiplier to nothing and the zombie one to 1, so the pair
    // is no longer two identical constants.
    try std.testing.expectEqual(@as(i32, 0), try dr.readI32()); // 23: ScorePlayerKillMultiplier
    try std.testing.expectEqual(@as(i32, 1), try dr.readI32()); // 24: ScoreZombieKillMultiplier
    try std.testing.expectEqual(@as(i32, -5), try dr.readI32()); // 25: ScoreDiedMultiplier
    try std.testing.expectEqual(@as(i32, 3), try dr.readI32()); // 26: DropOnDeath
    try std.testing.expectEqual(@as(i32, 0), try dr.readI32()); // 27: DropOnQuit
    try std.testing.expectEqual(@as(i32, 4), try dr.readI32()); // 28: GameDifficulty
    try std.testing.expectEqual(@as(i32, 9), try dr.readI32()); // 29: BloodMoonEnemyCount
    try std.testing.expectEqual(true, try dr.readBool()); // 30: EnemySpawnMode
    try std.testing.expectEqual(@as(i32, 5), try dr.readI32()); // 31: EnemyDifficulty
    try std.testing.expectEqual(@as(i32, 19), try dr.readI32()); // 32: DayLightLength
    try std.testing.expectEqual(@as(i32, 6), try dr.readI32()); // 33: LandClaimCount

    // The rest of the blob, to the end. Reading only the head left 35 slots
    // whose position nothing checked, and the blob is the one body where a
    // single misplaced field shifts every value after it.
    try std.testing.expectEqual(@as(i32, 41), try dr.readI32()); // 34: LandClaimSize
    try std.testing.expectEqual(@as(i32, 30), try dr.readI32()); // 35: LandClaimDeadZone
    try std.testing.expectEqual(@as(i32, 3), try dr.readI32()); // 36: LandClaimExpiryTime
    try std.testing.expectEqual(@as(i32, 0), try dr.readI32()); // 37: LandClaimDecayMode
    try std.testing.expectEqual(@as(i32, 31), try dr.readI32()); // 38: LandClaimOnlineDur
    try std.testing.expectEqual(@as(i32, 33), try dr.readI32()); // 39: LandClaimOfflineDur
    try std.testing.expectEqual(@as(i32, 0), try dr.readI32()); // 40: LandClaimOfflineDelay
    try std.testing.expectEqual(@as(i32, 45), try dr.readI32()); // 41: BedrollExpiryTime
    try std.testing.expectEqual(@as(i32, 0), try dr.readI32()); // 42: AirDropFrequency
    try std.testing.expectEqual(true, try dr.readBool()); // 43: AirDropMarker
    try std.testing.expectEqual(@as(i32, 100), try dr.readI32()); // 44: PartySharedKillRange
    try std.testing.expectEqual(false, try dr.readBool()); // 45: AutoParty
    try std.testing.expectEqual(@as(i32, 0), try dr.readI32()); // 46: OptionsPOICulling
    try std.testing.expectEqual(@as(i32, 21), try dr.readI32()); // 47: BloodMoonDay
    try std.testing.expectEqual(@as(i32, 101), try dr.readI32()); // 48: BlockDamagePlayer
    try std.testing.expectEqual(@as(i32, 102), try dr.readI32()); // 49: XPMultiplier
    try std.testing.expectEqual(@as(i32, 1), try dr.readI32()); // 50: BloodMoonWarning
    try std.testing.expectEqual(true, try dr.readBool()); // 51: TwitchBloodMoonAllowed
    try std.testing.expectEqual(@as(i32, 1), try dr.readI32()); // 52: DeathPenalty
    try std.testing.expectEqual(@as(i32, 4), try dr.readI32()); // 53: QuestProgressionDailyLimit
    try std.testing.expectEqual(true, try dr.readBool()); // 54: BiomeProgression
    try std.testing.expectEqual(@as(i32, 100), try dr.readI32()); // 55: StormFreq
    try std.testing.expectEqual(@as(i32, 0), try dr.readI32()); // 56: CameraRestrictionMode
    try std.testing.expectEqual(@as(i32, 60), try dr.readI32()); // 57: JarRefund
    var gs_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", try dr.readString(&gs_buf)); // 58: SandboxPreset
    try std.testing.expectEqualStrings("", try dr.readString(&gs_buf)); // 59: SandboxCode
    try std.testing.expectEqual(@as(i32, 60), try dr.readI32()); // 60: DayNightLength
    try std.testing.expectEqual(@as(i32, 103), try dr.readI32()); // 61: BlockDamageAI
    try std.testing.expectEqual(@as(i32, 104), try dr.readI32()); // 62: BlockDamageAIBM
    try std.testing.expectEqual(@as(i32, 105), try dr.readI32()); // 63: LootAbundance
    try std.testing.expectEqual(@as(i32, 7), try dr.readI32()); // 64: LootRespawnDays
    try std.testing.expectEqual(@as(i32, 100), try dr.readI32()); // 65: GlobalGSModifier
    try std.testing.expectEqual(@as(i32, 100), try dr.readI32()); // 66: BiomeGSModifier
    try std.testing.expectEqual(@as(i32, 100), try dr.readI32()); // 67: GlobalLSModifier
    try std.testing.expectEqual(@as(i32, 100), try dr.readI32()); // 68: BiomeLSModifier
    // Nothing left: the blob ends exactly here.
    try std.testing.expectEqual(@as(usize, 0), dr.remaining());

    // Pairs that remain indistinguishable because both sides are the same
    // constant, not because the fixture is weak: the empty strings at 8/9 and
    // 58/59, the false runs at 13/14 and 16..18, the true pair at 19/20, and
    // the four 100s at 65..68. No caller input can separate those;
    // initPropertyDecl holds the order, and the swap-mutation audit reports
    // them as survivors by construction.
}

test "GameStats carries the config-driven creative, marker and camera values" {
    // GameStats[18]/[20] come from GamePrefs 58 BuildCreate, [53] from the
    // sandbox AirDropMarker, [34] from DropOnQuit, [66] from BiomeProgression
    // and [68] from serverconfig CameraRestrictionMode. They used to be
    // constants in the writer, so an operator could not turn creative mode,
    // flight, the air-drop marker or the camera restriction on.
    var on_buf: [512]u8 = undefined;
    const on = try buildGameStatsBodyValues(&on_buf, .{
        .build_create = true,
        .air_drop_marker = false,
        .drop_on_quit = 2,
        .biome_progression = false,
        .camera_restriction_mode = 1,
    });
    var off_buf: [512]u8 = undefined;
    const off = try buildGameStatsBodyValues(&off_buf, .{});
    // Same field set, so only the values differ: the writer's field order is
    // the propertyList contract.
    try std.testing.expectEqual(off.len, on.len);
    try std.testing.expect(!std.mem.eql(u8, on, off));
    // ScorePlayerKillMultiplier is 0 in both (GameModeSurvival::Init IL_0035).
    const defaults = GameStatsValues{};
    try std.testing.expectEqual(@as(i32, 0), defaults.score_player_kill_multiplier);
    try std.testing.expectEqual(@as(i32, 0), defaults.drop_on_quit);
    try std.testing.expect(!defaults.build_create);
    try std.testing.expect(defaults.air_drop_marker);
    try std.testing.expect(defaults.biome_progression);
}
