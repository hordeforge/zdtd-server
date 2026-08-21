//! Minimal serverconfig.xml subset (port, max players, world name, password).

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const io_fs = @import("../util/io_fs.zig");
const xml = @import("../assets/xml_util.zig");
const sandbox = @import("../assets/sandbox.zig");

/// Stock serverconfig files are small. Bound operator input before parsing so a
/// mistaken path cannot consume unbounded memory during startup.
const max_serverconfig_bytes: usize = 1024 * 1024;

/// C2S validation strictness. Default correct hard-rejects illegal claims.
pub const AuthorityMode = enum {
    /// Counters / log only; still server-owned state (phase gates stay hard).
    observe,
    /// Hard reject illegal C2S (default).
    correct,

    pub fn parse(s: []const u8) ?AuthorityMode {
        if (std.ascii.eqlIgnoreCase(s, "observe")) return .observe;
        // Documented alias of observe (docs/AUTHORITY.md).
        if (std.ascii.eqlIgnoreCase(s, "permissive")) return .observe;
        if (std.ascii.eqlIgnoreCase(s, "correct")) return .correct;
        return null;
    }
};

pub const Config = struct {
    port: u16 = 26902,
    max_players: u16 = 8,
    world_name: []const u8 = "zdtd",
    game_world: []const u8 = "",
    /// Stock sandbox code (EnumGamePrefs.SandboxCode 296): one string encoding
    /// all 165 sandbox options, echoed verbatim into GameStats(71) so a joining
    /// client decodes the server's gates (TemperatureSurvival, StormFreq,
    /// blood-moon settings) instead of its own defaults (RE sandbox-options
    /// §8). Decoded here too: `applySandboxCode` overlays the operator's
    /// gameplay tuning (XP, block damage, blood moon, day length) on the sim.
    /// Malformed codes leave client defaults, exactly like stock.
    sandbox_code: []const u8 = "",
    /// SandboxPreset (295): the preset NAME for server-browser display and the
    /// stock-settings check; not used to load values.
    sandbox_preset: []const u8 = "",
    password: []const u8 = "",
    admin_port: u16 = 0,
    /// Stock telnet console (EnumGamePrefs TelnetEnabled 0x44 / TelnetPort 0x45 /
    /// TelnetPassword 0x59, asm.il:1903853-1903951). TelnetPort wins over the zdtd
    /// AdminPort alias when TelnetEnabled is true; see docs/GAME_OPTIONS.md.
    telnet_enabled: bool = false,
    telnet_port: u16 = 0,
    /// Empty = no auth. Stock TelnetConsole::.ctor (asm.il ~270735) binds loopback
    /// when the password is empty and INADDR_ANY only when one is set.
    telnet_password: []const u8 = "",
    /// TelnetFailedLoginLimit 0xA5: failed logins before the session is dropped.
    telnet_failed_login_limit: u8 = 10,
    /// TelnetFailedLoginsBlocktime 0xA6, minutes a source address stays blocked.
    telnet_failed_logins_blocktime: u16 = 10,
    /// Align with Game/InitOptions default and chunk_stream_radius_min (7).
    view_radius: i32 = 7,
    authority_mode: AuthorityMode = .correct,

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
    land_claim_expiry_days: u16 = 3, // LandClaimExpiryDays (0 = never)
    loot_respawn_days: u16 = 7, // LootRespawnDays (0 = never respawn)

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

fn prop(hay: []const u8, name: []const u8) ?[]const u8 {
    // <property name="ServerPort" value="26900"/>
    var i: usize = 0;
    while (i < hay.len) {
        const pi = std.mem.findPos(u8, hay, i, "<property") orelse break;
        const after_name = pi + "<property".len;
        if (after_name < hay.len and !std.ascii.isWhitespace(hay[after_name]) and
            hay[after_name] != '/' and hay[after_name] != '>')
        {
            i = after_name;
            continue;
        }
        const n = xml.attr(hay, pi, "name") orelse {
            i = pi + 9;
            continue;
        };
        if (std.mem.eql(u8, n, name)) return xml.attr(hay, pi, "value");
        i = pi + 9;
    }
    return null;
}

/// Decode an XML attribute value into arena-owned storage. `xml.attr` returns
/// the source spelling, but credentials and display names must use the value
/// an XML reader exposes (for example, `a&amp;b` means `a&b`).
fn decodeAttr(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.findScalar(u8, raw, '&') == null) return try arena.dupe(u8, raw);

    const out = try arena.alloc(u8, raw.len);
    var src_i: usize = 0;
    var out_i: usize = 0;
    while (src_i < raw.len) {
        if (raw[src_i] != '&') {
            out[out_i] = raw[src_i];
            src_i += 1;
            out_i += 1;
            continue;
        }
        const semi = std.mem.findScalarPos(u8, raw, src_i + 1, ';') orelse
            return error.BadServerConfig;
        const entity = raw[src_i + 1 .. semi];
        const named: ?u21 = if (std.mem.eql(u8, entity, "amp")) '&' else if (std.mem.eql(u8, entity, "lt")) '<' else if (std.mem.eql(u8, entity, "gt")) '>' else if (std.mem.eql(u8, entity, "quot")) '"' else if (std.mem.eql(u8, entity, "apos")) '\'' else null;
        const codepoint: u21 = named orelse blk: {
            if (entity.len < 2 or entity[0] != '#') return error.BadServerConfig;
            const hex = entity.len >= 3 and (entity[1] == 'x' or entity[1] == 'X');
            const digits = entity[if (hex) 2 else 1..];
            if (digits.len == 0) return error.BadServerConfig;
            const value = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch
                return error.BadServerConfig;
            break :blk value;
        };
        const encoded_n = std.unicode.utf8Encode(codepoint, out[out_i..]) catch
            return error.BadServerConfig;
        out_i += encoded_n;
        src_i = semi + 1;
    }
    return out[0..out_i];
}

/// Property names zdtd applies (subset of stock ServerSettings). Stock extras are
/// ignored without warning; near-miss typos of these names get a stderr hint.
const known_serverconfig_names = [_][]const u8{
    "ServerPort",
    "ServerMaxPlayerCount",
    "GameName",
    "GameWorld",
    "ServerPassword",
    "AdminPort",
    "TelnetEnabled",
    "TelnetPort",
    "TelnetPassword",
    "TelnetFailedLoginLimit",
    "TelnetFailedLoginsBlocktime",
    "ViewRadius",
    "GameDifficulty",
    "BloodMoonFrequency",
    "BloodMoonEnemyCount",
    "PlayerKillingMode",
    "DayNightLength",
    "DayLightLength",
    "MaxSpawnedZombies",
    "BloodMoonRange",
    "ZombieMove",
    "ZombieMoveNight",
    "ZombieFeralMove",
    "ZombieBMMove",
    "EnemyDifficulty",
    "LootAbundance",
    "XPMultiplier",
    "BlockDamagePlayer",
    "BlockDamageAI",
    "BlockDamageAIBM",
    "MaxSpawnedAnimals",
    "AirDropFrequency",
    "DropOnDeath",
    "LandClaimSize",
    "LandClaimOnlineDurabilityModifier",
    "LandClaimOfflineDurabilityModifier",
    "LandClaimExpiryDays",
    "LootRespawnDays",
    "SandboxPreset",
    "SandboxCode",
    "ZdtdAuthorityMode",
};

fn editDistanceCap(a: []const u8, b: []const u8, cap: usize) usize {
    // Small names only; return cap+1 when either side is long.
    if (a.len > 48 or b.len > 48) return cap + 1;
    var prev: [49]usize = undefined;
    var cur: [49]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (0..a.len) |i| {
        cur[0] = i + 1;
        for (0..b.len) |j| {
            const cost: usize = if (a[i] == b[j]) 0 else 1;
            cur[j + 1] = @min(prev[j] + cost, @min(cur[j] + 1, prev[j + 1] + 1));
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// Warn when a property name looks like a typo of a key we actually apply.
/// Full stock serverconfig has many unused keys; those stay silent.
fn warnNearMissPropertyNames(hay: []const u8) void {
    var i: usize = 0;
    while (i < hay.len) {
        const pi = std.mem.findPos(u8, hay, i, "<property") orelse break;
        const after_name = pi + "<property".len;
        if (after_name < hay.len and !std.ascii.isWhitespace(hay[after_name]) and
            hay[after_name] != '/' and hay[after_name] != '>')
        {
            i = after_name;
            continue;
        }
        const n = xml.attr(hay, pi, "name") orelse {
            i = pi + 9;
            continue;
        };
        var known = false;
        for (known_serverconfig_names) |kn| {
            if (std.mem.eql(u8, n, kn)) {
                known = true;
                break;
            }
        }
        if (!known) {
            var best: ?[]const u8 = null;
            var best_d: usize = 3;
            for (known_serverconfig_names) |kn| {
                const d = editDistanceCap(n, kn, 2);
                if (d > 0 and d < best_d) {
                    best_d = d;
                    best = kn;
                }
            }
            if (best) |sug| {
                std.debug.print(
                    "zdtd: serverconfig property '{s}' is not applied (did you mean '{s}'?)\n",
                    .{ n, sug },
                );
            }
        }
        i = pi + 9;
    }
}

/// Decode `SandboxCode` (EnumGamePrefs 296) and overlay the gameplay tuning it
/// carries. Stock V3.1.0 moved the difficulty knobs (XP, block damage, blood
/// moon, day length, zombie speeds, drops, ...) out of individual
/// serverconfig.xml properties into this one string: `StartAsServer` decodes
/// it and `UpdateInGameValuesWithSandboxOptions` pushes the values into the
/// consuming systems (RE sandbox-options §5). zdtd applies the same overlay
/// here, after the legacy property reads, so a real stock serverconfig.xml
/// tunes the sim instead of silently keeping defaults. Options with no zdtd
/// consumer yet are skipped; unknown ids are skipped and invalid indices fall
/// back to the option default, exactly like stock (§1.2 membership semantics).
fn applySandboxCode(cfg: *Config) void {
    if (cfg.sandbox_code.len == 0) return;
    var groups: [sandbox.max_groups]sandbox.Group = undefined;
    const n = sandbox.decode(cfg.sandbox_code, &groups);
    if (n == 0) return;
    for (groups[0..n]) |g| {
        const o = sandbox.findOption(g.option_id) orelse {
            std.debug.print("zdtd: sandbox code option id {d} unknown; skipped\n", .{g.option_id});
            continue;
        };
        const set = sandbox.findSet(o.set_name) orelse continue;
        // Runtime string dispatch (Zig cannot switch on slices).
        if (std.mem.eql(u8, o.name, "XPMultiplier")) {
            cfg.xp_multiplier = sandboxPct(sandbox.valueF(o, set, g.index));
        } else if (std.mem.eql(u8, o.name, "BlockDamage")) {
            cfg.block_damage_player = sandboxPct(sandbox.valueF(o, set, g.index));
        } else if (std.mem.eql(u8, o.name, "BlockDamageAI")) {
            cfg.block_damage_ai = sandboxPct(sandbox.valueF(o, set, g.index));
        } else if (std.mem.eql(u8, o.name, "BlockDamageAIBM")) {
            cfg.block_damage_ai_bm = sandboxPct(sandbox.valueF(o, set, g.index));
        } else if (std.mem.eql(u8, o.name, "GlobalLootCount")) {
            cfg.loot_abundance = sandboxPct(sandbox.valueF(o, set, g.index));
        } else if (std.mem.eql(u8, o.name, "BloodMoonFrequency")) {
            cfg.blood_moon_frequency = sandboxIntU8(sandbox.valueI(o, set, g.index));
        } else if (std.mem.eql(u8, o.name, "BloodMoonRange")) {
            cfg.blood_moon_range = sandboxIntU8(sandbox.valueI(o, set, g.index));
        } else if (std.mem.eql(u8, o.name, "BloodMoonEnemyCount")) {
            cfg.blood_moon_enemy_count = sandboxIntU8(sandbox.valueI(o, set, g.index));
        } else if (std.mem.eql(u8, o.name, "DayNightLength")) {
            cfg.day_night_length = sandboxIntU16(sandbox.valueI(o, set, g.index));
        } else if (std.mem.eql(u8, o.name, "DayLightLength")) {
            cfg.day_light_length = sandboxIntU8(sandbox.valueI(o, set, g.index));
        } else if (std.mem.eql(u8, o.name, "LootRespawnDays")) {
            cfg.loot_respawn_days = sandboxIntU16(sandbox.valueI(o, set, g.index));
        } else if (std.mem.eql(u8, o.name, "AirDropFrequency")) {
            cfg.air_drop_frequency = sandboxIntU16(sandbox.valueI(o, set, g.index));
        } else if (std.mem.eql(u8, o.name, "DropOnDeath")) {
            cfg.drop_on_death = sandboxIntU8(sandbox.valueI(o, set, g.index));
        } else if (std.mem.eql(u8, o.name, "ZombieMove")) {
            cfg.zombie_move = sandboxIntU8(sandbox.valueI(o, set, g.index));
        } else if (std.mem.eql(u8, o.name, "ZombieMoveNight")) {
            cfg.zombie_move_night = sandboxIntU8(sandbox.valueI(o, set, g.index));
        } else if (std.mem.eql(u8, o.name, "ZombieFeralMove")) {
            cfg.zombie_feral_move = sandboxIntU8(sandbox.valueI(o, set, g.index));
        } else if (std.mem.eql(u8, o.name, "ZombieBMMove")) {
            cfg.zombie_bm_move = sandboxIntU8(sandbox.valueI(o, set, g.index));
        }
        // Accepted but with no zdtd consumer yet: skip silently (the code
        // still rides verbatim in GameStats(71) for the client's decode).
    }
}

fn sandboxPct(v: f32) u16 {
    const p = @round(v * 100.0);
    if (p < 0.0) return 0;
    if (p > 65535.0) return 65535;
    return @intFromFloat(p);
}

fn sandboxIntU8(v: i32) u8 {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return @intCast(v);
}

fn sandboxIntU16(v: i32) u16 {
    if (v < 0) return 0;
    if (v > 65535) return 65535;
    return @intCast(v);
}

/// Parse serverconfig.xml bytes (subset of stock ServerSettings).
pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !Config {
    if (std.mem.find(u8, raw, "<ServerSettings") == null or
        std.mem.find(u8, raw, "</ServerSettings>") == null)
    {
        return error.BadServerConfig;
    }
    const arena_holder = try arena_util.newArenaHolder(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();
    var cfg: Config = .{ .arena_ptr = arena_holder };
    if (prop(raw, "ServerPort")) |v| {
        cfg.port = xml.parseU16(v) orelse blk: {
            std.debug.print("zdtd: serverconfig ServerPort '{s}' invalid; keeping {d}\n", .{ v, cfg.port });
            break :blk cfg.port;
        };
    }
    if (prop(raw, "ServerMaxPlayerCount")) |v| {
        // Cap at LiteNet peer slots (64). 0 is treated as default.
        const n = xml.parseU16(v) orelse blk: {
            std.debug.print("zdtd: serverconfig ServerMaxPlayerCount '{s}' invalid; keeping {d}\n", .{ v, cfg.max_players });
            break :blk cfg.max_players;
        };
        cfg.max_players = if (n == 0) cfg.max_players else @min(n, 64);
    }
    if (prop(raw, "GameName")) |v| cfg.world_name = try decodeAttr(arena, v);
    if (prop(raw, "GameWorld")) |v| cfg.game_world = try decodeAttr(arena, v);
    if (prop(raw, "SandboxCode")) |v| cfg.sandbox_code = try decodeAttr(arena, v);
    if (prop(raw, "SandboxPreset")) |v| cfg.sandbox_preset = try decodeAttr(arena, v);
    if (prop(raw, "ServerPassword")) |v| cfg.password = try decodeAttr(arena, v);
    if (prop(raw, "AdminPort")) |v| {
        cfg.admin_port = xml.parseU16(v) orelse blk: {
            std.debug.print("zdtd: serverconfig AdminPort '{s}' invalid; keeping {d}\n", .{ v, cfg.admin_port });
            break :blk cfg.admin_port;
        };
    }
    if (prop(raw, "TelnetEnabled")) |v| cfg.telnet_enabled = parseXmlBool(v) orelse blk: {
        std.debug.print("zdtd: serverconfig TelnetEnabled '{s}' invalid; keeping {}\n", .{ v, cfg.telnet_enabled });
        break :blk cfg.telnet_enabled;
    };
    if (prop(raw, "TelnetPort")) |v| {
        cfg.telnet_port = xml.parseU16(v) orelse blk: {
            std.debug.print("zdtd: serverconfig TelnetPort '{s}' invalid; keeping {d}\n", .{ v, cfg.telnet_port });
            break :blk cfg.telnet_port;
        };
    }
    // Never trimmed and never logged: the value is the console credential.
    if (prop(raw, "TelnetPassword")) |v| cfg.telnet_password = try decodeAttr(arena, v);
    if (prop(raw, "TelnetFailedLoginLimit")) |v|
        cfg.telnet_failed_login_limit = clampU8Named("TelnetFailedLoginLimit", v, 1, 255, cfg.telnet_failed_login_limit);
    if (prop(raw, "TelnetFailedLoginsBlocktime")) |v|
        cfg.telnet_failed_logins_blocktime = clampRangeNamed("TelnetFailedLoginsBlocktime", v, 0, 1440, cfg.telnet_failed_logins_blocktime);
    if (prop(raw, "ViewRadius")) |v| cfg.view_radius = @intCast(clampRangeNamed("ViewRadius", v, 1, 16, @intCast(cfg.view_radius)));
    if (prop(raw, "GameDifficulty")) |v| cfg.game_difficulty = clampU8Named("GameDifficulty", v, 0, 5, cfg.game_difficulty);
    if (prop(raw, "BloodMoonFrequency")) |v| cfg.blood_moon_frequency = clampU8Named("BloodMoonFrequency", v, 0, 255, cfg.blood_moon_frequency);
    if (prop(raw, "BloodMoonEnemyCount")) |v| cfg.blood_moon_enemy_count = clampU8Named("BloodMoonEnemyCount", v, 0, 60, cfg.blood_moon_enemy_count);
    if (prop(raw, "PlayerKillingMode")) |v| cfg.player_killing_mode = clampU8Named("PlayerKillingMode", v, 0, 3, cfg.player_killing_mode);
    if (prop(raw, "DayNightLength")) |v| cfg.day_night_length = clampRangeNamed("DayNightLength", v, 10, 1200, cfg.day_night_length);
    if (prop(raw, "DayLightLength")) |v| cfg.day_light_length = clampU8Named("DayLightLength", v, 1, 23, cfg.day_light_length);
    // 0 = no zombie spawns (Director.tick bails at the alive gate), same shape
    // as MaxSpawnedAnimals; the mode-pack range agrees (src/server/mode.zig).
    if (prop(raw, "MaxSpawnedZombies")) |v| cfg.max_spawned_zombies = clampRangeNamed("MaxSpawnedZombies", v, 0, 2048, cfg.max_spawned_zombies);
    if (prop(raw, "BloodMoonRange")) |v| cfg.blood_moon_range = clampU8Named("BloodMoonRange", v, 0, 15, cfg.blood_moon_range);
    if (prop(raw, "ZombieMove")) |v| cfg.zombie_move = clampU8Named("ZombieMove", v, 0, 4, cfg.zombie_move);
    if (prop(raw, "ZombieMoveNight")) |v| cfg.zombie_move_night = clampU8Named("ZombieMoveNight", v, 0, 4, cfg.zombie_move_night);
    if (prop(raw, "ZombieFeralMove")) |v| cfg.zombie_feral_move = clampU8Named("ZombieFeralMove", v, 0, 4, cfg.zombie_feral_move);
    if (prop(raw, "ZombieBMMove")) |v| cfg.zombie_bm_move = clampU8Named("ZombieBMMove", v, 0, 4, cfg.zombie_bm_move);
    if (prop(raw, "EnemyDifficulty")) |v| cfg.enemy_difficulty = clampU8Named("EnemyDifficulty", v, 0, 1, cfg.enemy_difficulty);
    if (prop(raw, "LootAbundance")) |v| cfg.loot_abundance = clampRangeNamed("LootAbundance", v, 1, 1000, cfg.loot_abundance);
    if (prop(raw, "XPMultiplier")) |v| cfg.xp_multiplier = clampRangeNamed("XPMultiplier", v, 1, 1000, cfg.xp_multiplier);
    if (prop(raw, "BlockDamagePlayer")) |v| cfg.block_damage_player = clampRangeNamed("BlockDamagePlayer", v, 1, 1000, cfg.block_damage_player);
    if (prop(raw, "BlockDamageAI")) |v| cfg.block_damage_ai = clampRangeNamed("BlockDamageAI", v, 0, 1000, cfg.block_damage_ai);
    if (prop(raw, "BlockDamageAIBM")) |v| cfg.block_damage_ai_bm = clampRangeNamed("BlockDamageAIBM", v, 0, 1000, cfg.block_damage_ai_bm);
    if (prop(raw, "MaxSpawnedAnimals")) |v| cfg.max_spawned_animals = clampRangeNamed("MaxSpawnedAnimals", v, 0, 2048, cfg.max_spawned_animals);
    if (prop(raw, "AirDropFrequency")) |v| cfg.air_drop_frequency = clampRangeNamed("AirDropFrequency", v, 0, 8760, cfg.air_drop_frequency);
    if (prop(raw, "DropOnDeath")) |v| cfg.drop_on_death = clampU8Named("DropOnDeath", v, 0, 4, cfg.drop_on_death);
    if (prop(raw, "LandClaimSize")) |v| {
        // Stock keystone area is odd (centered on block); force odd after clamp.
        var sz = clampRangeNamed("LandClaimSize", v, 1, 255, cfg.land_claim_size);
        if (sz % 2 == 0) sz -= 1;
        cfg.land_claim_size = if (sz == 0) 1 else sz;
    }
    if (prop(raw, "LandClaimOnlineDurabilityModifier")) |v|
        cfg.land_claim_online_durability_modifier = clampRangeNamed("LandClaimOnlineDurabilityModifier", v, 0, 64, cfg.land_claim_online_durability_modifier);
    if (prop(raw, "LandClaimOfflineDurabilityModifier")) |v|
        cfg.land_claim_offline_durability_modifier = clampRangeNamed("LandClaimOfflineDurabilityModifier", v, 0, 64, cfg.land_claim_offline_durability_modifier);
    if (prop(raw, "LandClaimExpiryDays")) |v|
        cfg.land_claim_expiry_days = clampRangeNamed("LandClaimExpiryDays", v, 0, 365, cfg.land_claim_expiry_days);
    if (prop(raw, "LootRespawnDays")) |v|
        cfg.loot_respawn_days = clampRangeNamed("LootRespawnDays", v, 0, 365, cfg.loot_respawn_days);
    if (prop(raw, "ZdtdAuthorityMode")) |v| {
        if (AuthorityMode.parse(v)) |m| {
            cfg.authority_mode = m;
        } else {
            std.debug.print("zdtd: serverconfig ZdtdAuthorityMode '{s}' unknown (use observe|permissive|correct); keeping correct\n", .{v});
        }
    }
    warnNearMissPropertyNames(raw);
    applySandboxCode(&cfg);
    return cfg;
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Config {
    const read_buf = try allocator.alloc(u8, max_serverconfig_bytes + 1);
    defer allocator.free(read_buf);
    const raw = try io_fs.readFileInto(path, read_buf);
    if (raw.len > max_serverconfig_bytes) return error.ServerConfigTooLarge;
    return parse(allocator, raw);
}

/// Stock serverconfig booleans are written "true"/"false" (case-insensitive);
/// the XML writer also emits 0/1 for some properties. Anything else is a typo,
/// and a typo must not silently read as "enabled".
fn parseXmlBool(s: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1")) return true;
    if (std.ascii.eqlIgnoreCase(s, "false") or std.mem.eql(u8, s, "0")) return false;
    return null;
}

/// Parse a serverconfig integer property: warn on non-numeric input (keep default)
/// and on out-of-range values (clamp). Silent keep on typos is a misconfig footgun.
fn clampU8Named(name: []const u8, raw: []const u8, lo: u16, hi: u16, dflt: u8) u8 {
    return @intCast(clampRangeNamed(name, raw, lo, hi, dflt));
}

fn clampRangeNamed(name: []const u8, raw: []const u8, lo: u16, hi: u16, dflt: u16) u16 {
    const x = xml.parseU16(raw) orelse {
        std.debug.print("zdtd: serverconfig {s} '{s}' invalid; keeping {d}\n", .{ name, raw, dflt });
        return dflt;
    };
    if (x < lo or x > hi) {
        const c = std.math.clamp(x, lo, hi);
        std.debug.print("zdtd: serverconfig {s}={d} out of range [{d}..{d}]; using {d}\n", .{ name, x, lo, hi, c });
        return c;
    }
    return x;
}

test "parse config fixture" {
    const xml_src =
        \\<ServerSettings>
        \\  <property name="ServerPort" value="27002"/>
        \\  <property name="GameName" value="TestWorld"/>
        \\  <property name="ServerMaxPlayerCount" value="16"/>
        \\  <property name="SandboxPreset" value="Adventurer"/>
        \\  <property name="SandboxCode" value="AAAJABJACJADJARFBNC"/>
        \\</ServerSettings>
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/serverconfig.xml", .{dir});
    try io_fs.writeFile(path, xml_src);
    var cfg = try loadFromPath(std.testing.allocator, path);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u16, 27002), cfg.port);
    try std.testing.expectEqualStrings("TestWorld", cfg.world_name);
    // Sandbox code + preset ride through verbatim (the client decodes the
    // server's weather-survival / blood-moon gates from the code; RE
    // sandbox-options §8).
    try std.testing.expectEqualStrings("AAAJABJACJADJARFBNC", cfg.sandbox_code);
    try std.testing.expectEqualStrings("Adventurer", cfg.sandbox_preset);
    // The Adventurer code decodes to RangedDamage/MeleeDamage/BlockDamage/
    // TerrainDamage 1.5, IncomingDamage 0.75, ZombieFeralSense 2 (RE
    // sandbox-options §3); the mapped fields apply (BlockDamage -> player).
    try std.testing.expectEqual(@as(u16, 150), cfg.block_damage_player);
    // Unset gameplay options keep stock defaults.
    try std.testing.expectEqual(@as(u8, 2), cfg.game_difficulty);
    try std.testing.expectEqual(@as(u8, 7), cfg.blood_moon_frequency);
    try std.testing.expectEqual(@as(u8, 3), cfg.player_killing_mode);
}

test "sandbox code applies gameplay tuning (RE sandbox-options §5)" {
    // Synthetic code: XPMultiplier(18)=ASJ idx9=3, BloodMoonFrequency(48)=BWK
    // idx10=10, DayNightLength(66)=COD idx3=40, ZombieMove(34)=BIC idx2=2.
    const xml_src =
        \\<ServerSettings>
        \\  <property name="SandboxCode" value="AASJBWKCODBIC"/>
        \\</ServerSettings>
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/serverconfig.xml", .{dir});
    try io_fs.writeFile(path, xml_src);
    var cfg = try loadFromPath(std.testing.allocator, path);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u16, 300), cfg.xp_multiplier);
    try std.testing.expectEqual(@as(u8, 10), cfg.blood_moon_frequency);
    try std.testing.expectEqual(@as(u16, 40), cfg.day_night_length);
    try std.testing.expectEqual(@as(u8, 2), cfg.zombie_move);
    // Untouched knobs keep stock defaults.
    try std.testing.expectEqual(@as(u8, 3), cfg.zombie_move_night);
    try std.testing.expectEqual(@as(u16, 100), cfg.block_damage_player);
}

test "sandbox code invalid index falls back to option default" {
    // XPMultiplier(18)=ASU idx20 is out of XPGain's 11-entry set -> default 1.0.
    const xml_src =
        \\<ServerSettings>
        \\  <property name="SandboxCode" value="AASU"/>
        \\</ServerSettings>
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/serverconfig.xml", .{dir});
    try io_fs.writeFile(path, xml_src);
    var cfg = try loadFromPath(std.testing.allocator, path);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u16, 100), cfg.xp_multiplier);
}

test "malformed sandbox code leaves defaults (stock: version char reject)" {
    const xml_src =
        \\<ServerSettings>
        \\  <property name="SandboxCode" value="ZZZ"/>
        \\</ServerSettings>
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/serverconfig.xml", .{dir});
    try io_fs.writeFile(path, xml_src);
    var cfg = try loadFromPath(std.testing.allocator, path);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u16, 100), cfg.xp_multiplier);
    try std.testing.expectEqual(@as(u8, 7), cfg.blood_moon_frequency);
    try std.testing.expectEqualStrings("ZZZ", cfg.sandbox_code); // still echoed
}

test "string properties decode XML attribute entities" {
    const xml_src =
        \\<ServerSettings>
        \\  <property name="GameName" value="Rock &amp; Roll &#x1F3B8;"/>
        \\  <property name="ServerPassword" value="a&amp;b&lt;c&gt;d&quot;e&apos;f"/>
        \\  <property name="TelnetPassword" value="pin&#35;42"/>
        \\</ServerSettings>
    ;
    var cfg = try parse(std.testing.allocator, xml_src);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("Rock & Roll 🎸", cfg.world_name);
    try std.testing.expectEqualStrings("a&b<c>d\"e'f", cfg.password);
    try std.testing.expectEqualStrings("pin#42", cfg.telnet_password);
}

test "property-prefixed elements do not override server settings" {
    const xml_src =
        \\<ServerSettings>
        \\  <propertyOverride name="ServerPort" value="12345"/>
        \\  <property name="ServerMaxPlayerCount" value="12"/>
        \\</ServerSettings>
    ;
    var cfg = try parse(std.testing.allocator, xml_src);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u16, 26902), cfg.port);
    try std.testing.expectEqual(@as(u16, 12), cfg.max_players);
}

test "parse gameplay options with clamping" {
    const xml_src =
        \\<ServerSettings>
        \\  <property name="ViewRadius" value="999"/>
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/serverconfig.xml", .{dir});
    try io_fs.writeFile(path, xml_src);
    var cfg = try loadFromPath(std.testing.allocator, path);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u8, 5), cfg.game_difficulty); // 99 clamped to max 5
    try std.testing.expectEqual(@as(i32, 16), cfg.view_radius); // 999 clamped to max 16
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
    try std.testing.expectEqual(AuthorityMode.correct, cfg.authority_mode);
}

test "parse land claim expiry and loot respawn days" {
    // These keys must parse into Config so main can wire them onto InitOptions
    // (a silent parse+drop left operators stuck on code defaults).
    const xml_src =
        \\<ServerSettings>
        \\  <property name="LandClaimExpiryDays" value="14"/>
        \\  <property name="LootRespawnDays" value="21"/>
        \\  <property name="ViewRadius" value="not-a-number"/>
        \\</ServerSettings>
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/serverconfig.xml", .{dir});
    try io_fs.writeFile(path, xml_src);
    var cfg = try loadFromPath(std.testing.allocator, path);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u16, 14), cfg.land_claim_expiry_days);
    try std.testing.expectEqual(@as(u16, 21), cfg.loot_respawn_days);
    // Non-numeric ViewRadius keeps the default (and prints a stderr warning).
    try std.testing.expectEqual(@as(i32, 7), cfg.view_radius);
}

test "parse authority mode observe" {
    const xml_src =
        \\<ServerSettings>
        \\  <property name="ZdtdAuthorityMode" value="observe"/>
        \\</ServerSettings>
    ;
    const dir = "worlds/zdtd_cfg_auth";
    io_fs.mkdirPath("worlds");
    io_fs.mkdirPath(dir);
    const path = dir ++ "/serverconfig.xml";
    try io_fs.writeFile(path, xml_src);
    var cfg = try loadFromPath(std.testing.allocator, path);
    defer cfg.deinit();
    try std.testing.expectEqual(AuthorityMode.observe, cfg.authority_mode);
}

test "parse authority mode permissive alias and land claim odd" {
    const xml_src =
        \\<ServerSettings>
        \\  <property name="ZdtdAuthorityMode" value="permissive"/>
        \\  <property name="LandClaimSize" value="40"/>
        \\  <property name="ServerMaxPlayerCount" value="12"/>
        \\</ServerSettings>
    ;
    const dir = "worlds/zdtd_cfg_auth2";
    io_fs.mkdirPath("worlds");
    io_fs.mkdirPath(dir);
    const path = dir ++ "/serverconfig.xml";
    try io_fs.writeFile(path, xml_src);
    var cfg = try loadFromPath(std.testing.allocator, path);
    defer cfg.deinit();
    try std.testing.expectEqual(AuthorityMode.observe, cfg.authority_mode);
    try std.testing.expectEqual(@as(u16, 39), cfg.land_claim_size);
    try std.testing.expectEqual(@as(u16, 12), cfg.max_players);
}

test "near-miss property names still load known keys" {
    // Typo ServerPasssword is ignored for values; ServerPort still applies.
    const xml_src =
        \\<ServerSettings>
        \\  <property name="ServerPort" value="27099"/>
        \\  <property name="ServerPasssword" value="nope"/>
        \\  <property name="SomeStockOnlyKey" value="1"/>
        \\</ServerSettings>
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/serverconfig.xml", .{dir});
    try io_fs.writeFile(path, xml_src);
    var cfg = try loadFromPath(std.testing.allocator, path);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u16, 27099), cfg.port);
    try std.testing.expectEqual(@as(usize, 0), cfg.password.len);
}

test "parse rejects missing ServerSettings root" {
    try std.testing.expectError(error.BadServerConfig, parse(std.testing.allocator, ""));
    try std.testing.expectError(
        error.BadServerConfig,
        parse(std.testing.allocator, "<property name=\"ServerPort\" value=\"27002\"/>"),
    );
}

test "parse telnet properties" {
    const xml_src =
        \\<ServerSettings>
        \\  <property name="TelnetEnabled" value="true"/>
        \\  <property name="TelnetPort" value="8081"/>
        \\  <property name="TelnetPassword" value="hunter2"/>
        \\  <property name="TelnetFailedLoginLimit" value="3"/>
        \\  <property name="TelnetFailedLoginsBlocktime" value="45"/>
        \\</ServerSettings>
    ;
    var cfg = try parse(std.testing.allocator, xml_src);
    defer cfg.deinit();
    try std.testing.expect(cfg.telnet_enabled);
    try std.testing.expectEqual(@as(u16, 8081), cfg.telnet_port);
    try std.testing.expectEqualStrings("hunter2", cfg.telnet_password);
    try std.testing.expectEqual(@as(u8, 3), cfg.telnet_failed_login_limit);
    try std.testing.expectEqual(@as(u16, 45), cfg.telnet_failed_logins_blocktime);
}

test "telnet defaults stay closed when properties are absent or malformed" {
    const xml_src =
        \\<ServerSettings>
        \\  <property name="TelnetEnabled" value="yes please"/>
        \\  <property name="TelnetPort" value="notaport"/>
        \\  <property name="TelnetPassword" value=""/>
        \\</ServerSettings>
    ;
    var cfg = try parse(std.testing.allocator, xml_src);
    defer cfg.deinit();
    // A malformed boolean must not read as enabled.
    try std.testing.expect(!cfg.telnet_enabled);
    try std.testing.expectEqual(@as(u16, 0), cfg.telnet_port);
    // Empty password is "no auth", never "auth with the empty string".
    try std.testing.expectEqual(@as(usize, 0), cfg.telnet_password.len);
    try std.testing.expectEqual(@as(u8, 10), cfg.telnet_failed_login_limit);

    var bare = try parse(std.testing.allocator, "<ServerSettings></ServerSettings>");
    defer bare.deinit();
    try std.testing.expect(!bare.telnet_enabled);
    try std.testing.expectEqual(@as(u16, 0), bare.telnet_port);
    try std.testing.expectEqual(@as(usize, 0), bare.telnet_password.len);
}

test "parseXmlBool accepts stock spellings only" {
    try std.testing.expectEqual(@as(?bool, true), parseXmlBool("true"));
    try std.testing.expectEqual(@as(?bool, true), parseXmlBool("TRUE"));
    try std.testing.expectEqual(@as(?bool, true), parseXmlBool("1"));
    try std.testing.expectEqual(@as(?bool, false), parseXmlBool("False"));
    try std.testing.expectEqual(@as(?bool, false), parseXmlBool("0"));
    try std.testing.expectEqual(@as(?bool, null), parseXmlBool(""));
    try std.testing.expectEqual(@as(?bool, null), parseXmlBool("on"));
}
