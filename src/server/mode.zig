//! Gamemode = config pack (+ optional static plugin flag). ADR 0010 step 3.
//! Data-only TOML under modes/<name>.toml. No script VM.
//! Apply onto InitOptions after serverconfig, before/with zdtd.toml stream keys.
//! Parsing is the comptime binder (src/util/toml_bind.zig); the pack may set
//! stock serverconfig keys (root / [gameplay] / [plugin]) plus any `Rules`
//! field via `[rules.*]` sections (ADR 0021 decision 3).

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const toml_bind = @import("../util/toml_bind.zig");
const rules_mod = @import("../ecs/rules.zig");

/// Max size for a mode pack file.
const max_mode_bytes: usize = 64 * 1024;

/// Optional InitOptions overrides from a mode pack.
pub const Pack = struct {
    pub const toml_label = "mode pack";
    /// Flat keys are gameplay settings (root scope). [gameplay] and [plugin]
    /// are accepted spellings for the same flat keys, as before the binder.
    pub const allow_root = true;
    pub const root_sections = [_][]const u8{ "gameplay", "plugin" };
    pub const aliases = .{
        .root = [_][2][]const u8{.{ "bloodmoon_frequency", "blood_moon_frequency" }},
    };
    /// Clamp bounds that serverconfig applies at merge (docs/GAME_OPTIONS.md);
    /// now applied at parse so the stored pack value is already in range.
    pub const ranges = .{
        // 0 is a valid ceiling (Director.tick returns before every spawn
        // branch), which is what modes/builder.toml asks for.
        .max_spawned_zombies = .{ 0, 2048 },
        .game_difficulty = .{ 0, 5 },
        .blood_moon_enemy_count = .{ 0, 60 },
        .blood_moon_range = .{ 0, 15 },
        .player_killing_mode = .{ 0, 3 },
        .day_night_length = .{ 10, 1200 },
        .day_light_length = .{ 1, 23 },
        .zombie_move = .{ 0, 4 },
        .zombie_move_night = .{ 0, 4 },
        .zombie_feral_move = .{ 0, 4 },
        .zombie_bm_move = .{ 0, 4 },
        .enemy_difficulty = .{ 0, 1 },
        .loot_abundance = .{ 1, 1000 },
        .xp_multiplier = .{ 1, 1000 },
        .block_damage_player = .{ 1, 1000 },
        .block_damage_ai = .{ 0, 1000 },
        .block_damage_ai_bm = .{ 0, 1000 },
        .max_spawned_animals = .{ 0, 2048 },
        .air_drop_frequency = .{ 0, 8760 },
        .drop_on_death = .{ 0, 4 },
        // 255 max and even sizes forced odd: zdtd_config.sanitizeInitOptions
        // normalizes the merged value (a keystone area is centered on a block).
        .land_claim_size = .{ 1, 255 },
        .land_claim_online_durability_modifier = .{ 0, 64 },
        .land_claim_offline_durability_modifier = .{ 0, 64 },
        .land_claim_expiry_days = .{ 0, 365 },
        .loot_respawn_days = .{ 0, 365 },
    };

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
    /// Sim rule overlay (ADR 0021 decision 3): `[rules.combat]` etc. merged
    /// into World.rules by main.zig before the zdtd.toml overlay.
    rules: rules_mod.RulesOverlay = .{},
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
    const data = try io_fs.readFileInto(path, read_buf);
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
    toml_bind.bind(Pack, &p, src, a) catch |err| switch (err) {
        // The binder reports unknown keys as UnknownTomlKey; the mode pack
        // surface kept its own error name, which tests rely on.
        error.UnknownTomlKey => return error.UnknownModeKey,
        else => return err,
    };
    return p;
}

/// Merge Pack into InitOptions-like fields. Only non-null keys override.
/// Values are already range-clamped at parse (Pack.ranges), so this is a plain
/// copy; rules are merged by main.zig, not here (they target World.rules).
pub fn applyToInitOptions(p: *const Pack, opts: anytype) void {
    if (p.max_spawned_zombies) |v| opts.max_spawned_zombies = v;
    if (p.blood_moon_frequency) |v| opts.blood_moon_frequency = v;
    if (p.game_difficulty) |v| opts.game_difficulty = v;
    if (p.blood_moon_enemy_count) |v| opts.blood_moon_enemy_count = v;
    if (p.blood_moon_range) |v| opts.blood_moon_range = v;
    if (p.player_killing_mode) |v| opts.player_killing_mode = v;
    if (p.day_night_length) |v| opts.day_night_length = v;
    if (p.day_light_length) |v| opts.day_light_length = v;
    if (p.zombie_move) |v| opts.zombie_move = v;
    if (p.zombie_move_night) |v| opts.zombie_move_night = v;
    if (p.zombie_feral_move) |v| opts.zombie_feral_move = v;
    if (p.zombie_bm_move) |v| opts.zombie_bm_move = v;
    if (p.enemy_difficulty) |v| opts.enemy_difficulty = v;
    if (p.loot_abundance) |v| opts.loot_abundance = v;
    if (p.xp_multiplier) |v| opts.xp_multiplier = v;
    if (p.block_damage_player) |v| opts.block_damage_player = v;
    if (p.block_damage_ai) |v| opts.block_damage_ai = v;
    if (p.block_damage_ai_bm) |v| opts.block_damage_ai_bm = v;
    if (p.max_spawned_animals) |v| opts.max_spawned_animals = v;
    if (p.air_drop_frequency) |v| opts.air_drop_frequency = v;
    if (p.drop_on_death) |v| opts.drop_on_death = v;
    if (p.land_claim_size) |v| opts.land_claim_size = v;
    if (p.land_claim_online_durability_modifier) |v| opts.land_claim_online_durability_modifier = v;
    if (p.land_claim_offline_durability_modifier) |v| opts.land_claim_offline_durability_modifier = v;
    if (p.land_claim_expiry_days) |v| opts.land_claim_expiry_days = v;
    if (p.loot_respawn_days) |v| opts.loot_respawn_days = v;
    if (p.enable_sample_plugin) |v| opts.enable_sample_plugin = v;
}

test "parse default pack" {
    var p = try parse(std.testing.allocator, default_pack_toml);
    defer p.deinit();
    try std.testing.expectEqualStrings("default", p.name);
    try std.testing.expectEqual(@as(u16, 64), p.max_spawned_zombies.?);
    try std.testing.expectEqual(@as(u8, 7), p.blood_moon_frequency.?);
    try std.testing.expectEqual(true, p.enable_sample_plugin.?);
}

/// Mirror of the server init-options shape applyToInitOptions writes into.
const TestOpts = struct {
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

test "applyToInitOptions overrides only set fields" {
    var o: TestOpts = .{};
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
    var o: TestOpts = .{ .max_spawned_zombies = 64, .blood_moon_frequency = 7 };
    var p = try parse(std.testing.allocator,
        \\max_spawned_zombies = 9000
    );
    defer p.deinit();
    // The clamp now happens at parse (Pack.ranges [1..2048]) instead of apply;
    // the observable result through applyToInitOptions is unchanged.
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
    if (!io_fs.fileExists("modes/default.toml")) return;
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

test "mode pack binds [rules.*] overlay sections" {
    var p = try parse(std.testing.allocator,
        \\name = "hard"
        \\max_spawned_zombies = 32
        \\[rules.combat]
        \\attack_damage = 14.0
        \\attack_cooldown_s = 0.9
        \\[rules.ai]
        \\chase_speed = 2.8
        \\[rules.bloodmoon]
        \\party_enemy_max = 40
    );
    defer p.deinit();
    try std.testing.expectEqualStrings("hard", p.name);
    try std.testing.expectEqual(@as(?f32, 14.0), p.rules.combat.attack_damage);
    try std.testing.expectEqual(@as(?f32, 0.9), p.rules.combat.attack_cooldown_s);
    try std.testing.expectEqual(@as(?f32, null), p.rules.combat.attack_range_sq);
    try std.testing.expectEqual(@as(?f32, 2.8), p.rules.ai.chase_speed);
    try std.testing.expectEqual(@as(?u32, 40), p.rules.bloodmoon.party_enemy_max);
}

test "shipped example packs parse and exercise the rules surface" {
    // T13 fixtures: modes/horde_lite.toml and modes/survival_crunch.toml must
    // parse and carry [rules.*] overlays (skip when absent, e.g. dist runs).
    if (!io_fs.fileExists("modes/horde_lite.toml")) return;
    var hl = try loadFromPath(std.testing.allocator, "modes/horde_lite.toml");
    defer hl.deinit();
    try std.testing.expectEqualStrings("horde_lite", hl.name);
    try std.testing.expectEqual(@as(?f32, 5.0), hl.rules.combat.attack_damage);
    try std.testing.expectEqual(@as(?f32, 1.6), hl.rules.ai.chase_speed);
    try std.testing.expectEqual(@as(?u32, 20), hl.rules.bloodmoon.party_enemy_max);
    var r: rules_mod.Rules = .{};
    rules_mod.mergeOverlay(&r, &hl.rules);
    try std.testing.expectEqual(@as(f32, 5.0), r.combat.attack_damage);

    if (!io_fs.fileExists("modes/survival_crunch.toml")) return;
    var sc = try loadFromPath(std.testing.allocator, "modes/survival_crunch.toml");
    defer sc.deinit();
    try std.testing.expectEqualStrings("survival_crunch", sc.name);
    try std.testing.expectEqual(@as(?f32, 12.0), sc.rules.combat.attack_damage);
    try std.testing.expectEqual(@as(?f32, 3600.0), sc.rules.ai.sense_dist_sq);
    try std.testing.expectEqual(@as(?f32, 120.0), sc.rules.bloodmoon.party_join_dist);
}

test "GAME_OPTIONS.md documents every Rules field" {
    // ADR 0021: the mode-pack reference is generated from the Rules struct, so
    // it cannot drift from the parser. Every leaf field must appear in
    // docs/GAME_OPTIONS.md (skip when the doc is absent, e.g. dist runs).
    if (!io_fs.fileExists("docs/GAME_OPTIONS.md")) return;
    const buf = try std.testing.allocator.alloc(u8, 512 * 1024);
    defer std.testing.allocator.free(buf);
    const doc = try io_fs.readFileInto("docs/GAME_OPTIONS.md", buf);
    inline for (std.meta.fields(rules_mod.Rules)) |group| {
        inline for (std.meta.fields(group.type)) |f| {
            try std.testing.expect(
                std.mem.find(u8, doc, f.name) != null,
            );
        }
    }
}

test "mode pack rules overlay merges into Rules in precedence order" {
    var r: rules_mod.Rules = .{};
    var p = try parse(std.testing.allocator,
        \\name = "hard"
        \\[rules.combat]
        \\attack_damage = 14.0
    );
    defer p.deinit();
    rules_mod.mergeOverlay(&r, &p.rules);
    try std.testing.expectEqual(@as(f32, 14.0), r.combat.attack_damage);
    // An operator zdtd.toml wins over the pack for the same key.
    var f = try @import("zdtd_config.zig").parse(std.testing.allocator,
        \\[rules.combat]
        \\attack_damage = 20.0
    );
    defer f.deinit();
    rules_mod.mergeOverlay(&r, &f.rules);
    try std.testing.expectEqual(@as(f32, 20.0), r.combat.attack_damage);
}
