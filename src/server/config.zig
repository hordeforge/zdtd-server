//! Minimal serverconfig.xml subset (port, max players, world name, password).

const std = @import("std");
const linux = std.os.linux;
const xml = @import("../assets/xml_util.zig");

pub const Config = struct {
    port: u16 = 26902,
    max_players: u16 = 8,
    world_name: []const u8 = "zdtd",
    game_world: []const u8 = "",
    password: []const u8 = "",
    admin_port: u16 = 0,
    view_radius: i32 = 4,

    // Gameplay options (stock serverconfig.xml defaults). Applied to the sim in
    // game.initWithOptions; see docs/GAME_OPTIONS.md for which are wired.
    game_difficulty: u8 = 2, // GameDifficulty 0..5 (Adventurer)
    blood_moon_frequency: u8 = 7, // BloodMoonFrequency (0 = off)
    blood_moon_enemy_count: u8 = 8, // BloodMoonEnemyCount per player
    player_killing_mode: u8 = 3, // PlayerKillingMode 0..3 (0 = no PvP)
    day_night_length: u16 = 60, // DayNightLength, real minutes per full day
    day_light_length: u8 = 18, // DayLightLength, daylight hours in a day
    max_spawned_zombies: u16 = 64, // MaxSpawnedZombies (server-wide alive cap)
    blood_moon_range: u8 = 0, // BloodMoonRange, ±day jitter
    zombie_move: u8 = 0, // ZombieMove 0..4 (day)
    zombie_move_night: u8 = 3, // ZombieMoveNight 0..4
    zombie_feral_move: u8 = 3, // ZombieFeralMove 0..4
    zombie_bm_move: u8 = 3, // ZombieBMMove 0..4 (blood moon)
    enemy_difficulty: u8 = 0, // EnemyDifficulty 0=normal, 1=feral
    loot_abundance: u16 = 100, // LootAbundance percent
    xp_multiplier: u16 = 100, // XPMultiplier percent
    block_damage_player: u16 = 100, // BlockDamagePlayer percent
    block_damage_ai: u16 = 100, // BlockDamageAI percent
    block_damage_ai_bm: u16 = 100, // BlockDamageAIBM percent (blood moon)
    max_spawned_animals: u16 = 50, // MaxSpawnedAnimals server-wide cap
    air_drop_frequency: u16 = 72, // AirDropFrequency in game hours (0 = off)
    drop_on_death: u8 = 1, // DropOnDeath 0=nothing 1=all 2=toolbelt 3=backpack 4=delete
    land_claim_size: u16 = 41, // LandClaimSize (blocks per side, must be odd)
    land_claim_online_durability_modifier: u16 = 4, // LandClaimOnlineDurabilityModifier
    land_claim_offline_durability_modifier: u16 = 4, // LandClaimOfflineDurabilityModifier

    /// Owned storage when loaded from file.
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Config) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
    }
};

fn readFileAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_z: [1024]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const rc = linux.open(path_z[0..path.len :0].ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const end = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(end) != .SUCCESS) return error.SeekFailed;
    const size: usize = @intCast(end);
    _ = linux.lseek(fd, 0, linux.SEEK.SET);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    var off: usize = 0;
    while (off < size) {
        const n = linux.read(fd, buf[off..].ptr, size - off);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        off += @intCast(n);
    }
    return buf[0..off];
}

fn prop(hay: []const u8, name: []const u8) ?[]const u8 {
    // <property name="ServerPort" value="26900"/>
    var i: usize = 0;
    while (i < hay.len) {
        const pi = std.mem.indexOfPos(u8, hay, i, "<property") orelse break;
        const n = xml.attr(hay, pi, "name") orelse {
            i = pi + 9;
            continue;
        };
        if (std.mem.eql(u8, n, name)) return xml.attr(hay, pi, "value");
        i = pi + 9;
    }
    return null;
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Config {
    const raw = try readFileAll(allocator, path);
    defer allocator.free(raw);
    var arena_holder = try allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();
    var cfg: Config = .{ .arena_ptr = arena_holder };
    if (prop(raw, "ServerPort")) |v| cfg.port = xml.parseU16(v) orelse cfg.port;
    if (prop(raw, "ServerMaxPlayerCount")) |v| cfg.max_players = xml.parseU16(v) orelse cfg.max_players;
    if (prop(raw, "GameName")) |v| cfg.world_name = try arena.dupe(u8, v);
    if (prop(raw, "GameWorld")) |v| cfg.game_world = try arena.dupe(u8, v);
    if (prop(raw, "ServerPassword")) |v| cfg.password = try arena.dupe(u8, v);
    if (prop(raw, "AdminPort")) |v| cfg.admin_port = xml.parseU16(v) orelse 0;
    if (prop(raw, "ViewRadius")) |v| cfg.view_radius = @intCast(xml.parseU16(v) orelse 4);
    if (prop(raw, "GameDifficulty")) |v| cfg.game_difficulty = clampU8(xml.parseU16(v), 0, 5, cfg.game_difficulty);
    if (prop(raw, "BloodMoonFrequency")) |v| cfg.blood_moon_frequency = clampU8(xml.parseU16(v), 0, 255, cfg.blood_moon_frequency);
    if (prop(raw, "BloodMoonEnemyCount")) |v| cfg.blood_moon_enemy_count = clampU8(xml.parseU16(v), 0, 60, cfg.blood_moon_enemy_count);
    if (prop(raw, "PlayerKillingMode")) |v| cfg.player_killing_mode = clampU8(xml.parseU16(v), 0, 3, cfg.player_killing_mode);
    if (prop(raw, "DayNightLength")) |v| cfg.day_night_length = clampRange(xml.parseU16(v), 10, 1200, cfg.day_night_length);
    if (prop(raw, "DayLightLength")) |v| cfg.day_light_length = clampU8(xml.parseU16(v), 1, 23, cfg.day_light_length);
    if (prop(raw, "MaxSpawnedZombies")) |v| cfg.max_spawned_zombies = clampRange(xml.parseU16(v), 1, 2048, cfg.max_spawned_zombies);
    if (prop(raw, "BloodMoonRange")) |v| cfg.blood_moon_range = clampU8(xml.parseU16(v), 0, 15, cfg.blood_moon_range);
    if (prop(raw, "ZombieMove")) |v| cfg.zombie_move = clampU8(xml.parseU16(v), 0, 4, cfg.zombie_move);
    if (prop(raw, "ZombieMoveNight")) |v| cfg.zombie_move_night = clampU8(xml.parseU16(v), 0, 4, cfg.zombie_move_night);
    if (prop(raw, "ZombieFeralMove")) |v| cfg.zombie_feral_move = clampU8(xml.parseU16(v), 0, 4, cfg.zombie_feral_move);
    if (prop(raw, "ZombieBMMove")) |v| cfg.zombie_bm_move = clampU8(xml.parseU16(v), 0, 4, cfg.zombie_bm_move);
    if (prop(raw, "EnemyDifficulty")) |v| cfg.enemy_difficulty = clampU8(xml.parseU16(v), 0, 1, cfg.enemy_difficulty);
    if (prop(raw, "LootAbundance")) |v| cfg.loot_abundance = clampRange(xml.parseU16(v), 1, 1000, cfg.loot_abundance);
    if (prop(raw, "XPMultiplier")) |v| cfg.xp_multiplier = clampRange(xml.parseU16(v), 1, 1000, cfg.xp_multiplier);
    if (prop(raw, "BlockDamagePlayer")) |v| cfg.block_damage_player = clampRange(xml.parseU16(v), 1, 1000, cfg.block_damage_player);
    if (prop(raw, "BlockDamageAI")) |v| cfg.block_damage_ai = clampRange(xml.parseU16(v), 0, 1000, cfg.block_damage_ai);
    if (prop(raw, "BlockDamageAIBM")) |v| cfg.block_damage_ai_bm = clampRange(xml.parseU16(v), 0, 1000, cfg.block_damage_ai_bm);
    if (prop(raw, "MaxSpawnedAnimals")) |v| cfg.max_spawned_animals = clampRange(xml.parseU16(v), 0, 2048, cfg.max_spawned_animals);
    if (prop(raw, "AirDropFrequency")) |v| cfg.air_drop_frequency = clampRange(xml.parseU16(v), 0, 8760, cfg.air_drop_frequency);
    if (prop(raw, "DropOnDeath")) |v| cfg.drop_on_death = clampU8(xml.parseU16(v), 0, 4, cfg.drop_on_death);
    if (prop(raw, "LandClaimSize")) |v| cfg.land_claim_size = clampRange(xml.parseU16(v), 1, 255, cfg.land_claim_size);
    if (prop(raw, "LandClaimOnlineDurabilityModifier")) |v| cfg.land_claim_online_durability_modifier = clampRange(xml.parseU16(v), 0, 64, cfg.land_claim_online_durability_modifier);
    if (prop(raw, "LandClaimOfflineDurabilityModifier")) |v| cfg.land_claim_offline_durability_modifier = clampRange(xml.parseU16(v), 0, 64, cfg.land_claim_offline_durability_modifier);
    return cfg;
}

fn clampU8(v: ?u16, lo: u16, hi: u16, dflt: u8) u8 {
    const x = v orelse return dflt;
    return @intCast(std.math.clamp(x, lo, hi));
}

fn clampRange(v: ?u16, lo: u16, hi: u16, dflt: u16) u16 {
    const x = v orelse return dflt;
    return std.math.clamp(x, lo, hi);
}

test "parse config fixture" {
    const xml_src =
        \\<ServerSettings>
        \\  <property name="ServerPort" value="27002"/>
        \\  <property name="GameName" value="TestWorld"/>
        \\  <property name="ServerMaxPlayerCount" value="16"/>
        \\</ServerSettings>
    ;
    const dir = "worlds/zdtd_cfg_test";
    _ = linux.mkdir("worlds", 0o755);
    _ = linux.mkdir(dir, 0o755);
    const path = dir ++ "/serverconfig.xml";
    var pz: [64]u8 = undefined;
    @memcpy(pz[0..path.len], path);
    pz[path.len] = 0;
    const fd: i32 = @intCast(linux.open(pz[0..path.len :0].ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644));
    _ = linux.write(fd, xml_src.ptr, xml_src.len);
    _ = linux.close(fd);
    var cfg = try loadFromPath(std.testing.allocator, path);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u16, 27002), cfg.port);
    try std.testing.expectEqualStrings("TestWorld", cfg.world_name);
    // Unset gameplay options keep stock defaults.
    try std.testing.expectEqual(@as(u8, 2), cfg.game_difficulty);
    try std.testing.expectEqual(@as(u8, 7), cfg.blood_moon_frequency);
    try std.testing.expectEqual(@as(u8, 3), cfg.player_killing_mode);
}

test "parse gameplay options with clamping" {
    const xml_src =
        \\<ServerSettings>
        \\  <property name="GameDifficulty" value="99"/>
        \\  <property name="BloodMoonFrequency" value="10"/>
        \\  <property name="PlayerKillingMode" value="0"/>
        \\  <property name="DayNightLength" value="90"/>
        \\  <property name="DayLightLength" value="16"/>
        \\  <property name="MaxSpawnedZombies" value="120"/>
        \\  <property name="ZombieMove" value="1"/>
        \\  <property name="ZombieBMMove" value="4"/>
        \\  <property name="EnemyDifficulty" value="1"/>
        \\  <property name="LootAbundance" value="150"/>
        \\  <property name="BloodMoonRange" value="3"/>
        \\  <property name="XPMultiplier" value="200"/>
        \\  <property name="BlockDamagePlayer" value="150"/>
        \\  <property name="BlockDamageAI" value="50"/>
        \\  <property name="MaxSpawnedAnimals" value="20"/>
        \\  <property name="AirDropFrequency" value="24"/>
        \\  <property name="DropOnDeath" value="2"/>
        \\  <property name="LandClaimSize" value="31"/>
        \\  <property name="LandClaimOnlineDurabilityModifier" value="8"/>
        \\</ServerSettings>
    ;
    const dir = "worlds/zdtd_cfg_test2";
    _ = linux.mkdir("worlds", 0o755);
    _ = linux.mkdir(dir, 0o755);
    const path = dir ++ "/serverconfig.xml";
    var pz: [64]u8 = undefined;
    @memcpy(pz[0..path.len], path);
    pz[path.len] = 0;
    const fd: i32 = @intCast(linux.open(pz[0..path.len :0].ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644));
    _ = linux.write(fd, xml_src.ptr, xml_src.len);
    _ = linux.close(fd);
    var cfg = try loadFromPath(std.testing.allocator, path);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u8, 5), cfg.game_difficulty); // 99 clamped to max 5
    try std.testing.expectEqual(@as(u8, 10), cfg.blood_moon_frequency);
    try std.testing.expectEqual(@as(u8, 0), cfg.player_killing_mode);
    try std.testing.expectEqual(@as(u16, 90), cfg.day_night_length);
    try std.testing.expectEqual(@as(u8, 16), cfg.day_light_length);
    try std.testing.expectEqual(@as(u16, 120), cfg.max_spawned_zombies);
    try std.testing.expectEqual(@as(u8, 1), cfg.zombie_move);
    try std.testing.expectEqual(@as(u8, 4), cfg.zombie_bm_move);
    try std.testing.expectEqual(@as(u8, 1), cfg.enemy_difficulty);
    try std.testing.expectEqual(@as(u16, 150), cfg.loot_abundance);
    try std.testing.expectEqual(@as(u8, 3), cfg.blood_moon_range);
    try std.testing.expectEqual(@as(u16, 200), cfg.xp_multiplier);
    try std.testing.expectEqual(@as(u16, 150), cfg.block_damage_player);
    try std.testing.expectEqual(@as(u16, 50), cfg.block_damage_ai);
    try std.testing.expectEqual(@as(u16, 20), cfg.max_spawned_animals);
    try std.testing.expectEqual(@as(u16, 24), cfg.air_drop_frequency);
    try std.testing.expectEqual(@as(u8, 2), cfg.drop_on_death);
    try std.testing.expectEqual(@as(u16, 31), cfg.land_claim_size);
    try std.testing.expectEqual(@as(u16, 8), cfg.land_claim_online_durability_modifier);
}
