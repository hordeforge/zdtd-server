//! Gamemode = config pack (+ optional static plugin flag). ADR 0010 step 3.
//! Data-only TOML under modes/<name>.toml. No script VM.
//! Apply onto InitOptions after serverconfig, before/with zdtd.toml stream keys.

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");

/// Max size for a mode pack file.
const max_mode_bytes: usize = 64 * 1024;

/// Optional InitOptions overrides from a mode pack.
pub const Pack = struct {
    name: []const u8 = "default",
    // Gameplay keys (snake_case; same names as InitOptions / serverconfig).
    // A mode is a complete behavior pack: set any subset, the rest fall
    // through to serverconfig / zdtd.toml / code defaults.
    max_spawned_zombies: ?u16 = null,
    blood_moon_frequency: ?u8 = null,
    game_difficulty: ?u8 = null,
    blood_moon_enemy_count: ?u8 = null,
    blood_moon_range: ?u8 = null,
    player_killing_mode: ?u8 = null,
    day_night_length: ?u16 = null,
    day_light_length: ?u8 = null,
    zombie_move: ?u8 = null,
    zombie_move_night: ?u8 = null,
    zombie_feral_move: ?u8 = null,
    zombie_bm_move: ?u8 = null,
    enemy_difficulty: ?u8 = null,
    loot_abundance: ?u16 = null,
    xp_multiplier: ?u16 = null,
    block_damage_player: ?u16 = null,
    block_damage_ai: ?u16 = null,
    block_damage_ai_bm: ?u16 = null,
    max_spawned_animals: ?u16 = null,
    air_drop_frequency: ?u16 = null,
    drop_on_death: ?u8 = null,
    land_claim_size: ?u16 = null,
    land_claim_online_durability_modifier: ?u16 = null,
    land_claim_offline_durability_modifier: ?u16 = null,
    land_claim_expiry_days: ?u16 = null,
    loot_respawn_days: ?u16 = null,
    enable_sample_plugin: ?bool = null,
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Pack) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
    }
};

/// Builtin default pack source (matches modes/default.toml). Tests use this.
pub const default_pack_toml =
    \\name = "default"
    \\max_spawned_zombies = 64
    \\blood_moon_frequency = 7
    \\enable_sample_plugin = true
;

/// True when name is a single path segment: [A-Za-z0-9_]{1,64}, no dots/slashes.
pub fn isValidModeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
        if (!ok) return false;
    }
    return true;
}

/// Write `modes/<name>.toml` into buf. Caller ensures name is valid.
pub fn pathForName(name: []const u8, buf: []u8) ![]const u8 {
    return try std.fmt.bufPrint(buf, "modes/{s}.toml", .{name});
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Pack {
    const read_buf = try allocator.alloc(u8, max_mode_bytes + 1);
    defer allocator.free(read_buf);
    const data = try io_fs.readFileInto(allocator, path, read_buf);
    if (data.len > max_mode_bytes) return error.ModeTooLarge;
    return try parse(allocator, data);
}

/// Load modes/<name>.toml from CWD (or relative path). Invalid name → error.BadModeName.
pub fn loadByName(allocator: std.mem.Allocator, name: []const u8) !Pack {
    if (!isValidModeName(name)) return error.BadModeName;
    var path_buf: [96]u8 = undefined;
    const path = try pathForName(name, &path_buf);
    return try loadFromPath(allocator, path);
}

pub fn parse(allocator: std.mem.Allocator, src: []const u8) !Pack {
    var arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var p: Pack = .{ .arena_ptr = arena };
    var section: []const u8 = "";

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, try stripComment(raw), " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse return error.BadToml;
            if (std.mem.trim(u8, line[end + 1 ..], " \t").len != 0) return error.BadToml;
            section = try a.dupe(u8, std.mem.trim(u8, line[1..end], " \t"));
            if (section.len == 0) return error.BadToml;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.BadToml;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) return error.BadToml;
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (val.len == 0) return error.BadToml;
        try applyKV(&p, a, section, key, val);
    }
    return p;
}

fn applyKV(p: *Pack, a: std.mem.Allocator, section: []const u8, key: []const u8, val: []const u8) !void {
    // Flat root keys and optional [gameplay] / [plugin] sections.
    const root = section.len == 0 or
        std.mem.eql(u8, section, "gameplay") or
        std.mem.eql(u8, section, "plugin");
    if (!root) {
        return unknownKey(section, key);
    }
    if (std.mem.eql(u8, key, "name")) {
        p.name = try a.dupe(u8, stripQuotes(val));
    } else if (std.mem.eql(u8, key, "max_spawned_zombies")) {
        p.max_spawned_zombies = try parseU16(val);
    } else if (std.mem.eql(u8, key, "blood_moon_frequency") or std.mem.eql(u8, key, "bloodmoon_frequency")) {
        p.blood_moon_frequency = try parseU8(val);
    } else if (std.mem.eql(u8, key, "game_difficulty")) {
        p.game_difficulty = try parseU8(val);
    } else if (std.mem.eql(u8, key, "blood_moon_enemy_count")) {
        p.blood_moon_enemy_count = try parseU8(val);
    } else if (std.mem.eql(u8, key, "blood_moon_range")) {
        p.blood_moon_range = try parseU8(val);
    } else if (std.mem.eql(u8, key, "player_killing_mode")) {
        p.player_killing_mode = try parseU8(val);
    } else if (std.mem.eql(u8, key, "day_night_length")) {
        p.day_night_length = try parseU16(val);
    } else if (std.mem.eql(u8, key, "day_light_length")) {
        p.day_light_length = try parseU8(val);
    } else if (std.mem.eql(u8, key, "zombie_move")) {
        p.zombie_move = try parseU8(val);
    } else if (std.mem.eql(u8, key, "zombie_move_night")) {
        p.zombie_move_night = try parseU8(val);
    } else if (std.mem.eql(u8, key, "zombie_feral_move")) {
        p.zombie_feral_move = try parseU8(val);
    } else if (std.mem.eql(u8, key, "zombie_bm_move")) {
        p.zombie_bm_move = try parseU8(val);
    } else if (std.mem.eql(u8, key, "enemy_difficulty")) {
        p.enemy_difficulty = try parseU8(val);
    } else if (std.mem.eql(u8, key, "loot_abundance")) {
        p.loot_abundance = try parseU16(val);
    } else if (std.mem.eql(u8, key, "xp_multiplier")) {
        p.xp_multiplier = try parseU16(val);
    } else if (std.mem.eql(u8, key, "block_damage_player")) {
        p.block_damage_player = try parseU16(val);
    } else if (std.mem.eql(u8, key, "block_damage_ai")) {
        p.block_damage_ai = try parseU16(val);
    } else if (std.mem.eql(u8, key, "block_damage_ai_bm")) {
        p.block_damage_ai_bm = try parseU16(val);
    } else if (std.mem.eql(u8, key, "max_spawned_animals")) {
        p.max_spawned_animals = try parseU16(val);
    } else if (std.mem.eql(u8, key, "air_drop_frequency")) {
        p.air_drop_frequency = try parseU16(val);
    } else if (std.mem.eql(u8, key, "drop_on_death")) {
        p.drop_on_death = try parseU8(val);
    } else if (std.mem.eql(u8, key, "land_claim_size")) {
        p.land_claim_size = try parseU16(val);
    } else if (std.mem.eql(u8, key, "land_claim_online_durability_modifier")) {
        p.land_claim_online_durability_modifier = try parseU16(val);
    } else if (std.mem.eql(u8, key, "land_claim_offline_durability_modifier")) {
        p.land_claim_offline_durability_modifier = try parseU16(val);
    } else if (std.mem.eql(u8, key, "land_claim_expiry_days")) {
        p.land_claim_expiry_days = try parseU16(val);
    } else if (std.mem.eql(u8, key, "loot_respawn_days")) {
        p.loot_respawn_days = try parseU16(val);
    } else if (std.mem.eql(u8, key, "enable_sample_plugin")) {
        p.enable_sample_plugin = try parseBool(val);
    } else {
        return unknownKey(if (section.len == 0) "(root)" else section, key);
    }
}

fn unknownKey(section: []const u8, key: []const u8) error{UnknownModeKey} {
    std.debug.print("zdtd: mode pack unknown key [{s}].{s}\n", .{ section, key });
    return error.UnknownModeKey;
}

fn stripComment(line: []const u8) ![]const u8 {
    var quote: ?u8 = null;
    for (line, 0..) |c, i| {
        if (quote) |q| {
            if (c == q) quote = null;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '#') {
            return line[0..i];
        }
    }
    if (quote != null) return error.BadToml;
    return line;
}

fn stripQuotes(v: []const u8) []const u8 {
    if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or (v[0] == '\'' and v[v.len - 1] == '\''))) {
        return v[1 .. v.len - 1];
    }
    return v;
}

fn parseU16(v: []const u8) !u16 {
    return std.fmt.parseInt(u16, stripQuotes(v), 10);
}
fn parseU8(v: []const u8) !u8 {
    return std.fmt.parseInt(u8, stripQuotes(v), 10);
}
fn parseBool(v: []const u8) !bool {
    const s = stripQuotes(v);
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "yes")) return true;
    if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "no")) return false;
    return error.BadTomlBool;
}

/// Merge Pack into InitOptions-like fields. Only non-null keys override.
/// Clamps gameplay numbers to the same ranges as serverconfig (docs/GAME_OPTIONS.md).
pub fn applyToInitOptions(p: *const Pack, opts: anytype) void {
    if (p.max_spawned_zombies) |v| {
        // Match config.zig MaxSpawnedZombies: 1..2048 (0 treated as 1).
        const c: u16 = if (v == 0) 1 else @min(v, 2048);
        if (c != v) {
            std.debug.print(
                "zdtd: mode pack max_spawned_zombies={d} out of range [1..2048]; using {d}\n",
                .{ v, c },
            );
        }
        opts.max_spawned_zombies = c;
    }
    if (p.blood_moon_frequency) |v| opts.blood_moon_frequency = v;
    if (p.game_difficulty) |v| opts.game_difficulty = clampU8(v, 0, 5, "game_difficulty");
    if (p.blood_moon_enemy_count) |v| opts.blood_moon_enemy_count = clampU8(v, 0, 60, "blood_moon_enemy_count");
    if (p.blood_moon_range) |v| opts.blood_moon_range = clampU8(v, 0, 15, "blood_moon_range");
    if (p.player_killing_mode) |v| opts.player_killing_mode = clampU8(v, 0, 3, "player_killing_mode");
    if (p.day_night_length) |v| opts.day_night_length = clampU16(v, 10, 1200, "day_night_length");
    if (p.day_light_length) |v| opts.day_light_length = clampU8(v, 1, 23, "day_light_length");
    if (p.zombie_move) |v| opts.zombie_move = clampU8(v, 0, 4, "zombie_move");
    if (p.zombie_move_night) |v| opts.zombie_move_night = clampU8(v, 0, 4, "zombie_move_night");
    if (p.zombie_feral_move) |v| opts.zombie_feral_move = clampU8(v, 0, 4, "zombie_feral_move");
    if (p.zombie_bm_move) |v| opts.zombie_bm_move = clampU8(v, 0, 4, "zombie_bm_move");
    if (p.enemy_difficulty) |v| opts.enemy_difficulty = clampU8(v, 0, 1, "enemy_difficulty");
    if (p.loot_abundance) |v| opts.loot_abundance = clampU16(v, 1, 1000, "loot_abundance");
    if (p.xp_multiplier) |v| opts.xp_multiplier = clampU16(v, 1, 1000, "xp_multiplier");
    if (p.block_damage_player) |v| opts.block_damage_player = clampU16(v, 1, 1000, "block_damage_player");
    if (p.block_damage_ai) |v| opts.block_damage_ai = clampU16(v, 1, 1000, "block_damage_ai");
    if (p.block_damage_ai_bm) |v| opts.block_damage_ai_bm = clampU16(v, 1, 1000, "block_damage_ai_bm");
    if (p.max_spawned_animals) |v| opts.max_spawned_animals = clampU16(v, 0, 2048, "max_spawned_animals");
    if (p.air_drop_frequency) |v| opts.air_drop_frequency = clampU16(v, 0, 168, "air_drop_frequency");
    if (p.drop_on_death) |v| opts.drop_on_death = clampU8(v, 0, 4, "drop_on_death");
    if (p.land_claim_size) |v| opts.land_claim_size = clampU16(v, 1, 256, "land_claim_size");
    if (p.land_claim_online_durability_modifier) |v| opts.land_claim_online_durability_modifier = clampU16(v, 1, 1000, "land_claim_online_durability_modifier");
    if (p.land_claim_offline_durability_modifier) |v| opts.land_claim_offline_durability_modifier = clampU16(v, 1, 1000, "land_claim_offline_durability_modifier");
    if (p.land_claim_expiry_days) |v| opts.land_claim_expiry_days = clampU16(v, 0, 3650, "land_claim_expiry_days");
    if (p.loot_respawn_days) |v| opts.loot_respawn_days = clampU16(v, 0, 365, "loot_respawn_days");
    if (p.enable_sample_plugin) |v| opts.enable_sample_plugin = v;
}

fn clampU8(v: u8, lo: u8, hi: u8, key: []const u8) u8 {
    const c = @min(@max(v, lo), hi);
    if (c != v) {
        std.debug.print("zdtd: mode pack {s}={d} out of range [{d}..{d}]; using {d}\n", .{ key, v, lo, hi, c });
    }
    return c;
}

fn clampU16(v: u16, lo: u16, hi: u16, key: []const u8) u16 {
    const c = @min(@max(v, lo), hi);
    if (c != v) {
        std.debug.print("zdtd: mode pack {s}={d} out of range [{d}..{d}]; using {d}\n", .{ key, v, lo, hi, c });
    }
    return c;
}

test "parse default pack" {
    var p = try parse(std.testing.allocator, default_pack_toml);
    defer p.deinit();
    try std.testing.expectEqualStrings("default", p.name);
    try std.testing.expectEqual(@as(u16, 64), p.max_spawned_zombies.?);
    try std.testing.expectEqual(@as(u8, 7), p.blood_moon_frequency.?);
    try std.testing.expectEqual(true, p.enable_sample_plugin.?);
}

test "applyToInitOptions overrides only set fields" {
    const Opts = struct {
        max_spawned_zombies: u16 = 100,
        blood_moon_frequency: u8 = 3,
        game_difficulty: u8 = 2,
        blood_moon_enemy_count: u8 = 8,
        blood_moon_range: u8 = 0,
        player_killing_mode: u8 = 3,
        day_night_length: u16 = 60,
        day_light_length: u8 = 18,
        zombie_move: u8 = 0,
        zombie_move_night: u8 = 3,
        zombie_feral_move: u8 = 3,
        zombie_bm_move: u8 = 3,
        enemy_difficulty: u8 = 0,
        loot_abundance: u16 = 100,
        xp_multiplier: u16 = 100,
        block_damage_player: u16 = 100,
        block_damage_ai: u16 = 100,
        block_damage_ai_bm: u16 = 100,
        max_spawned_animals: u16 = 50,
        air_drop_frequency: u16 = 72,
        drop_on_death: u8 = 1,
        land_claim_size: u16 = 41,
        land_claim_online_durability_modifier: u16 = 4,
        land_claim_offline_durability_modifier: u16 = 4,
        land_claim_expiry_days: u16 = 3,
        loot_respawn_days: u16 = 7,
        enable_sample_plugin: bool = false,
        wire_chunks: bool = true,
    };
    var o: Opts = .{};
    var p = try parse(std.testing.allocator,
        \\max_spawned_zombies = 32
        \\enable_sample_plugin = true
    );
    defer p.deinit();
    applyToInitOptions(&p, &o);
    try std.testing.expectEqual(@as(u16, 32), o.max_spawned_zombies);
    try std.testing.expectEqual(@as(u8, 3), o.blood_moon_frequency);
    try std.testing.expectEqual(true, o.enable_sample_plugin);
    try std.testing.expectEqual(true, o.wire_chunks);
}

test "applyToInitOptions clamps max_spawned_zombies" {
    const Opts = struct {
        max_spawned_zombies: u16 = 64,
        blood_moon_frequency: u8 = 7,
        game_difficulty: u8 = 2,
        blood_moon_enemy_count: u8 = 8,
        blood_moon_range: u8 = 0,
        player_killing_mode: u8 = 3,
        day_night_length: u16 = 60,
        day_light_length: u8 = 18,
        zombie_move: u8 = 0,
        zombie_move_night: u8 = 3,
        zombie_feral_move: u8 = 3,
        zombie_bm_move: u8 = 3,
        enemy_difficulty: u8 = 0,
        loot_abundance: u16 = 100,
        xp_multiplier: u16 = 100,
        block_damage_player: u16 = 100,
        block_damage_ai: u16 = 100,
        block_damage_ai_bm: u16 = 100,
        max_spawned_animals: u16 = 50,
        air_drop_frequency: u16 = 72,
        drop_on_death: u8 = 1,
        land_claim_size: u16 = 41,
        land_claim_online_durability_modifier: u16 = 4,
        land_claim_offline_durability_modifier: u16 = 4,
        land_claim_expiry_days: u16 = 3,
        loot_respawn_days: u16 = 7,
        enable_sample_plugin: bool = false,
    };
    var o: Opts = .{};
    var p = try parse(std.testing.allocator,
        \\max_spawned_zombies = 9000
    );
    defer p.deinit();
    applyToInitOptions(&p, &o);
    try std.testing.expectEqual(@as(u16, 2048), o.max_spawned_zombies);
}

test "isValidModeName rejects path traversal" {
    try std.testing.expect(isValidModeName("default"));
    try std.testing.expect(isValidModeName("pve_hard"));
    try std.testing.expect(!isValidModeName(""));
    try std.testing.expect(!isValidModeName("../etc"));
    try std.testing.expect(!isValidModeName("a/b"));
    try std.testing.expect(!isValidModeName("a.b"));
}

test "loadByName default file when present" {
    if (!io_fs.fileExistsSimple("modes/default.toml")) return;
    var p = try loadByName(std.testing.allocator, "default");
    defer p.deinit();
    try std.testing.expectEqualStrings("default", p.name);
    try std.testing.expect(p.max_spawned_zombies != null);
}

test "loadByName rejects bad name" {
    try std.testing.expectError(error.BadModeName, loadByName(std.testing.allocator, "../x"));
}

test "parse bloodmoon_frequency alias and sections" {
    var p = try parse(std.testing.allocator,
        \\[gameplay]
        \\bloodmoon_frequency = 5
        \\[plugin]
        \\enable_sample_plugin = false
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(u8, 5), p.blood_moon_frequency.?);
    try std.testing.expectEqual(false, p.enable_sample_plugin.?);
}

test "parse rejects unknown and malformed mode settings" {
    try std.testing.expectError(error.UnknownModeKey, parse(std.testing.allocator, "max_spawned_zombis = 10\n"));
    try std.testing.expectError(error.UnknownModeKey, parse(std.testing.allocator, "[unknown]\nname = \"default\"\n"));
    try std.testing.expectError(error.BadToml, parse(std.testing.allocator, "max_spawned_zombies 10\n"));
    try std.testing.expectError(error.BadToml, parse(std.testing.allocator, "[gameplay] trailing\n"));
}

test "parse preserves hashes inside quoted mode names" {
    var p = try parse(std.testing.allocator, "name = \"pve#night\" # comment\n");
    defer p.deinit();
    try std.testing.expectEqualStrings("pve#night", p.name);
}
