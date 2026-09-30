//! Save/restore for zdtd-owned persistence: players.zsv (ZPV17), entities.zen
//! (ZEN2; ZENT still loads), claims.zlc (ZCLC), clock.zcl, weather.zwt (ZWTH1) and the chunk
//! blockmeta/raw planes.
//!
//! Extracted from game.zig following the replicate_te precedent: these take
//! `*Game` as the first parameter and are called as `persist.savePlayers(g, …)`.
//! game.zig keeps one-line delegating methods so existing callers (tick,
//! deinit, tests) are unchanged.

const std = @import("std");
const test_tmp = @import("../util/test_tmp.zig");
const game_mod = @import("game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const io_fs = @import("../util/io_fs.zig");
const ecs = @import("../ecs/root.zig");
const clock = @import("../util/clock.zig");
const assets_progression = @import("../assets/progression.zig");
const util_sim = @import("../util/sim.zig");
const utf8_util = @import("../util/utf8.zig");
const game_types = @import("game/types.zig");
const platform_user = @import("../wire/platform_user.zig");
const log = @import("../util/log.zig");
const max_land_claims = game_mod.max_land_claims;

pub fn logPersistErr(self: *Game, what: []const u8, err: anyerror) void {
    self.harness.counters.inc(.persistence_errors);
    const n = self.harness.counters.get(.persistence_errors);
    if (log.throttled(n)) {
        // Under sim this is where injected write/read faults surface (async
        // chunk flush is force-disabled under DST); name the replay key so a
        // failing seeded run is reproducible from its own failure line
        // (same pattern as the net poll error path in game/step.zig).
        var seed_buf: [32]u8 = undefined;
        if (util_sim.isEnabled()) {
            log.warn("{s} failed: {s} n={d} ({s})\n", .{ what, @errorName(err), n, util_sim.formatSeed(&seed_buf) });
        } else {
            log.warn("{s} failed: {s} n={d}\n", .{ what, @errorName(err), n });
        }
    }
}

/// One canonical ladder over every zdtd-owned store. Admin `.save` /
/// `.saveworld` and the periodic autosave tick (Game.step) and graceful
/// shutdown (lifecycle.deinit) all write the same set: chunks, TE stores,
/// traders, sleeper markers, allies, block meta, weather, clock, and players.
/// Each store is attempted even when an earlier one failed; returns false if
/// any failed (already logged), so callers never report success over a disk
/// error. The tick path still skips `savePlayers` when `players_dirty` is
/// false; this ladder always flushes players.
pub fn saveAllStores(self: *Game) bool {
    var ok = true;
    const note = struct {
        fn f(o: *bool, g: *Game, what: []const u8, err: anyerror) void {
            o.* = false;
            logPersistErr(g, what, err);
        }
    }.f;
    self.world.saveAll() catch |e| note(&ok, self, "save world", e);
    self.containers.save(self.world.world_dir, self.allocator) catch |e| note(&ok, self, "save containers", e);
    self.sign_texts.save(self.world.world_dir, self.allocator) catch |e| note(&ok, self, "save sign texts", e);
    self.workstations.save(self.world.world_dir, self.allocator) catch |e| note(&ok, self, "save workstations", e);
    self.vending.save(self.world.world_dir) catch |e| note(&ok, self, "save vending", e);
    self.saveClaims() catch |e| note(&ok, self, "save claims", e);
    self.saveEntities() catch |e| note(&ok, self, "save entities", e);
    persist_traders.saveTraders(self) catch |e| note(&ok, self, "save traders", e);
    self.sleepers.saveCleared(self.allocator, self.world.world_dir) catch |e| note(&ok, self, "save sleepers-cleared", e);
    self.sleepers.saveTriggered(self.allocator, self.world.world_dir) catch |e| note(&ok, self, "save sleepers-triggered", e);
    self.profiles.save(self.world.world_dir, self.allocator) catch |e| note(&ok, self, "save profiles", e);
    self.allies.save(self.world.world_dir, self.allocator) catch |e| note(&ok, self, "save allies", e);
    self.saveBlockMeta() catch |e| note(&ok, self, "save block meta", e);
    self.saveWeather() catch |e| note(&ok, self, "save weather", e);
    self.saveClock() catch |e| note(&ok, self, "save clock", e);
    self.savePlayers() catch |e| note(&ok, self, "save players", e);
    return ok;
}

pub const Zpv2Drop = struct {
    blob: ?[]u8 = null,
    removed: u32 = 0,
};

/// `version`: 2 (ZPV2, no progression tail), 3 (ZPV3, tail but no bedroll
/// field), 4 (ZPV4, tail's buff list followed unconditionally by a
/// bedroll presence byte), or 5 (ZPV5, journal entries additionally carry
/// the quest name + POI rect). 7 (ZPV7) widens the inventory slot record
/// from 7 to 11 bytes by appending `use_times` (f32, tool durability);
/// 8 (ZPV8) adds `hp` (normalized f32) to the progression tail so a relog
/// keeps the player's wounds; 9 (ZPV9) adds `born_world_time` (u64) so
/// days-alive (and the gamestage) survives a restart. 10 (ZPV10) appends
/// `seed` (u16) to each inventory slot record so a plantable's seed
/// survives a restart (magic byte 'A' after "ZPV"); 11 (ZPV11, magic byte
/// 'B') appends the skill tail (`skill_points:u32 | skill_n:u8 |
/// skill_n×(name_len:u8, name, level:u8)`) after the bedroll so purchased
/// attribute/perk levels survive a restart. 12 (ZPV12, magic byte 'C')
/// appends the attached mod ids (4 x u16) to each inventory slot record so a
/// modded weapon survives a restart (the mods' stat effects are client-side;
/// the ids re-render the attachments). 13 (ZPV13, magic byte 'D') appends the
/// dropped-bag marker list (`n:u8 | n x (x,y,z i32)`) after the skill tail, so
/// a bag restored from entities.zen still shows on its owner's map instead of
/// lying there unmarked. 14 (ZPV14, magic byte 'E') appends the character-sheet
/// kill/death counters (`deaths:i32 | zombieKills:u32 | playerKills:u32`) after
/// the bag list, so a restart or relog keeps the sheet stock keeps in
/// PlayerDataFile instead of re-deriving it from a session that is gone.
/// 15 (ZPV15, magic byte 'F') appends the platform identity
/// (`id_present:u8`, then the primary and native `puid_primary`/`puid_native`
/// pairs as `present:u8 | plat_len:u8 | id_len:u8 | strings`), so restore and
/// merge-write match on the account, not on the login display name: stock keys
/// PlayerDataFile on `PrimaryId.CombinedString` (asm.il 1884842), and a name
/// key let any client load another player's save by typing their name
/// (DIVERGENCES 1.6). A record that carries an identity is owned by that
/// account whatever the name; a legacy record with no identity is matched by
/// name once and gains one on the next save. The bedroll field is
/// **not** detected by "more
/// bytes remain in the file": that is ambiguous whenever another record
/// follows this one, since the next record's own name_len byte would be
/// misread as this record's bed_present. Only the file's own magic decides
/// whether a bedroll field is present, the same way `prog` already gates the
/// rest of the v3 tail. 16 (ZPV16, magic byte 'G') widens every inventory slot
/// record to `stats_n:u8 | stats_n x (effect:u8, slot_a:i16, slot_b:i16)` -
/// stock `ItemValue`'s `Stats` (wire blob flag bit 2), so a rolled or
/// client-sent stat entry survives a restart instead of being dropped on save.
/// 17 (ZPV17, magic byte 'H') appends `flags:u8 | mod_n:u8 | mod_qualities:[4]u8`
/// after the stats block so activated items and per-mod quality tiers survive
/// a relog the same way the wire already round-trips them. Inventory
/// slot-record stride in bytes: 7 through v6 (item:u16, count:u16, quality:u8,
/// meta:u16), 11 from v7 (those plus use_times: f32), 13 from v10 (plus
/// seed:u16 - the stock ItemValue.Seed, so a plantable's per-item seed
/// survives a restart).
/// Version this build writes (ZPV17). Older files stay readable.
pub const persist_version: u8 = 17;

pub fn zpvSlotStride(version: u8) usize {
    if (version >= 17) return ecs.components.inv_slot_persist_stride; // 52 + flags + mod_n + 4 qualities
    if (version >= 16) return 52; // 21 + stats_n u8 + 6 x (effect u8, two i16) (ZPV16)
    if (version >= 12) return 21; // 13 + 4 mod ids (ZPV12)
    if (version >= 10) return 13;
    return if (version >= 7) 11 else 7;
}

/// Decode the ZPV magic's fourth byte to a numeric version, or null when the
/// file is not a known players.zsv generation.
pub fn zpvVersionFromMagic(b: u8) ?u8 {
    return switch (b) {
        '2'...'9' => b - '0',
        'A' => 10,
        'B' => 11,
        'C' => 12,
        'D' => 13,
        'E' => 14,
        'F' => 15,
        'G' => 16,
        'H' => 17,
        else => null,
    };
}

pub fn zpvMagicByte(version: u8) u8 {
    if (version >= 10) return 'A' + (version - 10);
    return '0' + version;
}

/// Widen a slot block of `src_stride` bytes to the current v12 21-byte shape,
/// zero-filling whatever the older record lacked (use_times, seed, mod ids).
/// Carried records have no known value for those fields.
pub fn emitZpv12SlotsFrom(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    old: []const u8,
    inv_n_pos: usize,
    inv_n: usize,
    src_stride: usize,
) !void {
    const dst_stride = zpvSlotStride(persist_version);
    std.debug.assert(src_stride <= dst_stride);
    try out.append(allocator, old[inv_n_pos]); // inv_n byte
    var p = inv_n_pos + 1;
    var k: usize = 0;
    while (k < inv_n) : (k += 1) {
        try out.appendSlice(allocator, old[p .. p + src_stride]);
        try out.appendNTimes(allocator, 0, dst_stride - src_stride);
        p += src_stride;
    }
}

/// Widen a v10/v11 (13-byte) slot block to the v12 21-byte shape.
pub fn emitZpv12Slots(out: *std.ArrayList(u8), allocator: std.mem.Allocator, old: []const u8, inv_n_pos: usize, inv_n: usize) !void {
    return emitZpv12SlotsFrom(out, allocator, old, inv_n_pos, inv_n, 13);
}

/// Position of a v3+ record's progression-tail prog byte (journal end).
/// v2 records have no tail; returns the record end.
///
/// The slot stride is `zpvSlotStride(version)`, not a fixed width: this is
/// called for v6, v7 and v8, and v7 widened slots from 7 to 11 bytes when they
/// gained `use_times`. It used to hard-code 7, which walked a v7/v8 record 4
/// bytes short per slot.
pub fn tailStartOf(old: []const u8, rec_start: usize, nl: usize, version: u8) error{CorruptPlayersFile}!usize {
    const inv_pos = rec_start + 1 + nl + 16;
    const inv_n: usize = old[inv_pos];
    const jn_pos = inv_pos + 1 + inv_n * zpvSlotStride(version);
    const jn: usize = old[jn_pos];
    return journalSectionEnd(old, jn_pos + 1, jn, version);
}

/// v3-7 tails are `prog | level | xp | stats(16) | buff...`; v8 inserts
/// hp:f32 after the stats block. A carried record has no known hp, so the
/// migrated tail inserts a -1 sentinel: the restore skips negative hp and
/// the spawn path's full health stands, exactly the pre-ZPV8 relog behavior.
/// v3-7 tails are `prog | level | xp | stats(16) | buff...`; v8 adds hp:f32
/// after the stats block; v9 adds born_world_time:u64 after hp. A carried
/// record has no known hp / born time, so the migrated tail inserts a -1 hp
/// sentinel (the restore keeps the spawn path's full health, the pre-ZPV8
/// relog behavior) and a zero born time (the pre-ZPV9 days-alive behavior).
/// v8 records already carry hp, so only the born field is inserted for them.
pub fn emitZpv9Tail(out: *std.ArrayList(u8), allocator: std.mem.Allocator, old: []const u8, tail_start: usize, tail_end: usize, version: u8) !void {
    if (version < 3 or tail_start >= tail_end) {
        try out.appendSlice(allocator, old[tail_start..tail_end]);
        return;
    }
    try out.append(allocator, old[tail_start]); // prog byte
    const p = tail_start + 1;
    if (old[tail_start] != 1) {
        try out.appendSlice(allocator, old[p..tail_end]);
        return;
    }
    const fixed = 2 + 8 + 16;
    if (p + fixed > tail_end) {
        // Truncated tail (defense in depth; zpvRecordLen bounds it already).
        try out.appendSlice(allocator, old[p..tail_end]);
        return;
    }
    try out.appendSlice(allocator, old[p .. p + fixed]);
    var rest = p + fixed;
    if (version >= 8) {
        // v8 tails already carry hp: copy it, then insert the born field.
        if (rest + 4 > tail_end) {
            try out.appendSlice(allocator, old[rest..tail_end]);
            return;
        }
        try out.appendSlice(allocator, old[rest .. rest + 4]);
        rest += 4;
    } else {
        var hp_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &hp_bytes, @bitCast(@as(f32, -1.0)), .little);
        try out.appendSlice(allocator, &hp_bytes);
    }
    var born_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &born_bytes, 0, .little);
    try out.appendSlice(allocator, &born_bytes);
    try out.appendSlice(allocator, old[rest..tail_end]);
}

/// ZPV11 skill tail: `skill_points:u32 | skill_n:u8 | skill_n×(name_len:u8,
/// name, level:u8)`. Purchased attribute/perk levels survive a restart so
/// the spend ledger and the level-scaled VM effects restore. Carried records
/// (null client) emit the empty tail: they predate purchase persistence.
pub fn emitZpv11Skills(out: *std.ArrayList(u8), allocator: std.mem.Allocator, cl: ?*const Client) !void {
    var sp: u32 = 0;
    var levels: []const assets_progression.SkillLevel = &.{};
    if (cl) |c| {
        sp = c.skill_points;
        levels = c.skill_levels[0..c.skill_level_n];
    }
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, sp, .little);
    try out.appendSlice(allocator, &tmp);
    try out.append(allocator, @intCast(@min(levels.len, std.math.maxInt(u8))));
    for (levels[0..@min(levels.len, std.math.maxInt(u8))]) |sl| {
        const nl = utf8_util.truncLen(sl.name, 63);
        try out.append(allocator, @intCast(nl));
        try out.appendSlice(allocator, sl.name[0..nl]);
        try out.append(allocator, sl.level);
    }
}

/// ZPV13 tail: the player's dropped-bag markers. Written for every record so
/// the version alone decides the shape; a carried record from an older file
/// emits a zero count, which is what it knew.
pub fn emitZpv13Backpacks(out: *std.ArrayList(u8), allocator: std.mem.Allocator, cl: ?*const Client) !void {
    var n: u8 = 0;
    if (cl) |c| n = @min(c.backpack_n, game_types.max_tracked_backpacks);
    try out.append(allocator, n);
    if (cl) |c| {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            for (c.backpacks[i]) |v| {
                var tmp: [4]u8 = undefined;
                std.mem.writeInt(i32, &tmp, v, .little);
                try out.appendSlice(allocator, &tmp);
            }
        }
    }
}

/// ZPV14 stats tail: the kill/death counters the client's character sheet
/// shows (`EntityNetworkStats` / `EntityAlive.AddScore`), which are otherwise
/// session-only on zdtd. Stock keeps them in PlayerDataFile, so a restart or
/// relog must carry them through players.zsv instead of re-deriving them from
/// a live session that no longer exists. Layout: `deaths:i32 | zombieKills:u32
/// | playerKills:u32`, size `zpv_stats_tail_len`.
pub const zpv_stats_tail_len: usize = 12;

pub fn emitZpv14Stats(out: *std.ArrayList(u8), allocator: std.mem.Allocator, cl: ?*const Client) !void {
    const deaths: i32 = if (cl) |c| c.deaths else 0;
    const zk: u32 = if (cl) |c| c.zombie_kills else 0;
    const pk: u32 = if (cl) |c| c.player_kills else 0;
    var buf: [zpv_stats_tail_len]u8 = undefined;
    std.mem.writeInt(i32, buf[0..4], deaths, .little);
    std.mem.writeInt(u32, buf[4..8], zk, .little);
    std.mem.writeInt(u32, buf[8..12], pk, .little);
    try out.appendSlice(allocator, &buf);
}

/// Where a record's optional ZPV15 identity section starts. `off` is 0 when the
/// file version predates the section (a carried record keeps the version it was
/// written under, so the offset has to come from the same walk that computed the
/// record length, not from re-deriving the layout).
pub const RecordSpan = struct {
    len: usize,
    identity_off: usize = 0,
};

pub fn zpvRecordLen(data: []const u8, off: usize, version: u8) error{CorruptPlayersFile}!usize {
    return (try zpvRecordSpan(data, off, version)).len;
}

pub fn zpvRecordSpan(data: []const u8, off: usize, version: u8) error{CorruptPlayersFile}!RecordSpan {
    if (off >= data.len) return error.CorruptPlayersFile;
    const nl: usize = data[off];
    if (nl > 32 or off + 1 + nl + 16 + 1 > data.len) return error.CorruptPlayersFile;
    var p = off + 1 + nl + 16;
    const inv_n: usize = data[p];
    p += 1 + inv_n * zpvSlotStride(version);
    if (p >= data.len) return error.CorruptPlayersFile;
    const jn: usize = data[p];
    p = try journalSectionEnd(data, p + 1, jn, version);
    if (p > data.len) return error.CorruptPlayersFile;
    if (version >= 3) {
        if (p >= data.len) return error.CorruptPlayersFile;
        const prog = data[p];
        p += 1;
        if (prog == 1) {
            // ZPV8 adds hp:f32 after the four survival-stat floats; ZPV9 adds
            // born_world_time:u64 after that.
            const tail_stats: usize = if (version >= 9)
                2 + 8 + 16 + 4 + 8
            else if (version >= 8)
                2 + 8 + 16 + 4
            else
                2 + 8 + 16;
            if (p + tail_stats + 1 > data.len) return error.CorruptPlayersFile;
            p += tail_stats;
            const buff_n: usize = data[p];
            p += 1;
            if (p + buff_n * 19 > data.len) return error.CorruptPlayersFile;
            p += buff_n * 19;
            if (version >= 4) {
                if (p >= data.len) return error.CorruptPlayersFile;
                const bed_present = data[p];
                p += 1;
                if (bed_present == 1) {
                    if (p + 12 > data.len) return error.CorruptPlayersFile;
                    p += 12;
                }
            }
            if (version >= 11) {
                if (p + 5 > data.len) return error.CorruptPlayersFile;
                p += 4; // skill_points
                const skill_n: usize = data[p];
                p += 1;
                var si: usize = 0;
                while (si < skill_n) : (si += 1) {
                    if (p >= data.len) return error.CorruptPlayersFile;
                    const snl: usize = data[p];
                    if (snl > 63 or p + 1 + snl + 1 > data.len) return error.CorruptPlayersFile;
                    p += 1 + snl + 1;
                }
            }
            if (version >= 13) {
                if (p >= data.len) return error.CorruptPlayersFile;
                const bp_n: usize = data[p];
                p += 1;
                if (bp_n > game_types.max_tracked_backpacks) return error.CorruptPlayersFile;
                if (p + bp_n * 12 > data.len) return error.CorruptPlayersFile;
                p += bp_n * 12;
            }
            if (version >= 14) {
                if (p + zpv_stats_tail_len > data.len) return error.CorruptPlayersFile;
                p += zpv_stats_tail_len;
            }
            if (version >= 15) {
                const identity_off = p;
                const end = try zpvIdentitySectionEnd(data, p);
                return .{ .len = end - off, .identity_off = identity_off };
            }
        }
    }
    return .{ .len = p - off };
}

/// Advance past one identity (`present:u8 | plat_len:u8 | plat | id_len:u8 |
/// id`); a zero present byte is the whole field, so an absent identity costs
/// one byte.
fn zpvSkipIdentity(data: []const u8, p_in: usize) error{CorruptPlayersFile}!usize {
    var p = p_in;
    if (p >= data.len) return error.CorruptPlayersFile;
    const present = data[p];
    p += 1;
    if (present == 0) return p;
    if (p + 2 > data.len) return error.CorruptPlayersFile;
    const plat_len: usize = data[p];
    const id_len: usize = data[p + 1];
    p += 2;
    if (plat_len > platform_user.max_platform_len or id_len > platform_user.max_id_len) return error.CorruptPlayersFile;
    if (p + plat_len + id_len > data.len) return error.CorruptPlayersFile;
    return p + plat_len + id_len;
}

/// End offset of the ZPV15 identity section: `id_present:u8`, then the primary
/// and native identities when present. The marker distinguishes "this record
/// carries identity" from "the file has no room for it" without a magic that a
/// v14 reader would have to guess at, the same reason the ZPV11 skill tail and
/// ZPV13 bag list have their own bytes.
fn zpvIdentitySectionEnd(data: []const u8, p_in: usize) error{CorruptPlayersFile}!usize {
    var p = p_in;
    if (p >= data.len) return error.CorruptPlayersFile;
    const id_present = data[p];
    p += 1;
    if (id_present == 0) return p;
    p = try zpvSkipIdentity(data, p);
    return try zpvSkipIdentity(data, p);
}

/// Identity section of one record (v15+) for the merge and restore matchers.
/// Copies the strings into caller buffers so the returned `Id` does not alias a
/// file buffer the caller is about to drop.
pub const ZpvIdentity = struct {
    present: bool = false,
    primary: platform_user.Stored = .{},
    native: platform_user.Stored = .{},

    /// True when this record should restore into `cl`. An identity-bearing row
    /// belongs to that account and nothing else: a matching name is not enough
    /// once the row has an identity, and an absent or different identity never
    /// inherits it (fail closed). A legacy row with no identity is still
    /// matched by name so an existing world upgrades in place on the next save.
    pub fn matchesClient(self: ZpvIdentity, cl: *const Client, name_matches: bool) bool {
        if (!self.present) return name_matches;
        const theirs = self.primary.get() orelse return false;
        const mine = cl.puid_primary.get() orelse return false;
        return platform_user.Id.eql(mine, theirs);
    }
};

/// Read the v15 identity section into `out`. `p` must be the section offset as
/// `zpvRecordLen` computed it; the bounds were checked there, so this re-checks
/// only the copy.
pub fn zpvIdentityFrom(data: []const u8, p: usize, out: *ZpvIdentity) void {
    out.* = .{};
    var q = p;
    const id_present = data[q];
    q += 1;
    if (id_present == 0) return;
    out.present = true;
    const slots: [2]*platform_user.Stored = .{ &out.primary, &out.native };
    for (slots) |slot| {
        const present = data[q];
        q += 1;
        if (present == 0) continue;
        const plat_len: usize = data[q];
        const id_len: usize = data[q + 1];
        q += 2;
        const platform = data[q..][0..plat_len];
        q += plat_len;
        const id = data[q..][0..id_len];
        q += id_len;
        slot.set(.{ .platform = platform, .id = id }) catch {
            // Over-cap identity: cannot be represented, so it matches nothing
            // (fail closed). `zpvRecordLen` already bounded the lengths, so this
            // is reachable only if the caps shrink between writer and reader.
            out.present = false;
            return;
        };
    }
}

/// Identity bytes a record writes: `1 | primary | native` with each identity a
/// present byte plus its two length-prefixed strings. `cl` null writes the
/// absent marker (a carried record whose owner is offline), which is one byte.
pub fn emitZpv15Identity(out: *std.ArrayList(u8), allocator: std.mem.Allocator, cl: ?*const Client) !void {
    const has = if (cl) |c| c.puid_primary.get() != null else false;
    if (!has) {
        try out.append(allocator, 0);
        return;
    }
    try out.append(allocator, 1);
    try emitZpvIdentity(out, allocator, cl.?.puid_primary.get());
    try emitZpvIdentity(out, allocator, cl.?.puid_native.get());
}

fn emitZpvIdentity(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: ?platform_user.Id) !void {
    const u = v orelse {
        try out.append(allocator, 0);
        return;
    };
    try out.append(allocator, 1);
    try out.append(allocator, @intCast(u.platform.len));
    try out.append(allocator, @intCast(u.id.len));
    try out.appendSlice(allocator, u.platform);
    try out.appendSlice(allocator, u.id);
}

/// Max quest id length persisted in a ZPV5 journal entry (stock ids stay well
/// under this; longer names are dropped fail-closed on write).
pub const max_quest_name_len: usize = 64;

/// End offset of the journal section, version-aware. v<=4 entries are the
/// fixed 10-byte shape (`def_id:u16 code:i32 flags:u8 progress:u16 phase:u8`);
/// v5 entries append `name_len:u8 | name | poi_valid:u8 | rect:24` (10 + 1 +
/// name_len + 25). The v5 shape is what makes a restored quest resolve by
/// name (a quests.xml edit no longer reshuffles it) and keep its POI rect;
/// v6 adds per-objective progress (`obj_n:u8 | obj_n×u16`), the stock
/// BaseObjective.Write per-objective CurrentValue.
fn journalSectionEnd(data: []const u8, p_in: usize, jn: usize, version: u8) error{CorruptPlayersFile}!usize {
    var p = p_in;
    var qi: usize = 0;
    while (qi < jn) : (qi += 1) {
        if (version >= 5) {
            if (p + 11 > data.len) return error.CorruptPlayersFile;
            const qnl: usize = data[p + 10];
            if (qnl > max_quest_name_len or p + 11 + qnl + 25 > data.len) return error.CorruptPlayersFile;
            p += 11 + qnl + 25;
            if (version >= 6) {
                if (p >= data.len) return error.CorruptPlayersFile;
                const obj_n: usize = data[p];
                p += 1;
                if (obj_n > ecs.quest.max_quest_objectives or p + obj_n * 2 > data.len) return error.CorruptPlayersFile;
                p += obj_n * 2;
            }
        } else {
            if (p + 10 > data.len) return error.CorruptPlayersFile;
            p += 10;
        }
    }
    return p;
}

/// True when `zpvRecordLen` would find `prog == 1` for this record, i.e. it
/// has a progression tail (and therefore needs a bed_present byte appended to
/// become v4-shaped). Callers must have already validated the record with
/// `zpvRecordLen`, so no bound is re-checked here.
pub fn zpvRecordHasProgTail(data: []const u8, off: usize, version: u8) bool {
    if (version < 3) return false;
    const nl: usize = data[off];
    var p = off + 1 + nl + 16;
    const inv_n: usize = data[p];
    p += 1 + inv_n * zpvSlotStride(version);
    const jn: usize = data[p];
    p = journalSectionEnd(data, p + 1, jn, version) catch return false;
    return data[p] == 1;
}

pub fn playersPath(self: *const Game, buf: []u8) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{s}/players.zsv", .{self.world.world_dir});
}

/// Remove all players.zsv records whose login name equals `name`.
/// Returns how many records were dropped. FileNotFound → 0 (no-op).
/// Does not log the name (operator reply only). Right-to-erasure: any
/// leftover `players.zsv.bak` beside the primary is deleted so a wiped login
/// does not linger in a side file. Operators who need undo keep their own
/// world-dir backups before wiping.
pub fn wipePlayerRecordsByName(self: *Game, name: []const u8) !u32 {
    if (name.len == 0 or name.len > 32) return 0;
    var path_buf: [512]u8 = undefined;
    const path = try self.playersPath(&path_buf);
    const data = io_fs.readFileAll(self.allocator, path) catch |e| {
        if (e == error.FileNotFound) return 0;
        return e;
    };
    defer self.allocator.free(data);
    const filtered = try zpv2DropName(self.allocator, data, name);
    defer if (filtered.blob) |b| self.allocator.free(b);
    if (filtered.removed == 0) return 0;
    var bak_buf: [520]u8 = undefined;
    const bak = try std.fmt.bufPrint(&bak_buf, "{s}.bak", .{path});
    // Drop any prior bak that still held this login (or other leftover PII from
    // an older wipe that wrote a full-file copy). Fail closed on the primary
    // rewrite only; bak cleanup is best-effort.
    io_fs.deleteFile(bak);
    try io_fs.writeFile(path, filtered.blob.?);
    return filtered.removed;
}

const persist_entities = @import("persist_entities.zig");
pub const saveEntities = persist_entities.saveEntities;
pub const loadEntities = persist_entities.loadEntities;
const persist_players = @import("persist_players.zig");
pub const savePlayers = persist_players.savePlayers;
pub const tryRestorePlayer = persist_players.tryRestorePlayer;

const persist_claims = @import("persist_claims.zig");
pub const saveClaims = persist_claims.saveClaims;
pub const loadClaims = persist_claims.loadClaims;
const persist_traders = @import("persist_traders.zig");
pub const ztrScanLen = persist_traders.ztrScanLen;
pub const saveTraders = persist_traders.saveTraders;
pub const loadTraders = persist_traders.loadTraders;

pub fn zpv2DropName(allocator: std.mem.Allocator, data: []const u8, name: []const u8) !Zpv2Drop {
    if (name.len == 0 or name.len > 32) return .{};
    if (data.len < 8 or !std.mem.eql(u8, data[0..3], "ZPV"))
        return error.CorruptPlayersFile;
    const version = zpvVersionFromMagic(data[3]) orelse return error.CorruptPlayersFile;
    const n = std.mem.readInt(u32, data[4..8], .little);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, data[0..4]); // keep the file's magic
    try out.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });
    var written: u32 = 0;
    var removed: u32 = 0;
    var off: usize = 8;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const rec_start = off;
        const rec_len = try zpvRecordLen(data, off, version);
        const nl: usize = data[off];
        const rec_name = data[off + 1 ..][0..nl];
        off += rec_len;
        if (nl == name.len and std.mem.eql(u8, rec_name, name)) {
            removed += 1;
            continue;
        }
        try out.appendSlice(allocator, data[rec_start..off]);
        written += 1;
    }
    if (removed == 0) {
        out.deinit(allocator);
        return .{};
    }
    std.mem.writeInt(u32, out.items[4..][0..4], written, .little);
    return .{ .blob = try out.toOwnedSlice(allocator), .removed = removed };
}

test "player save upgrades offline v15 inventory slots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    const g = try Game.create(std.testing.allocator, dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var path_buf: [512]u8 = undefined;
    const path = try playersPath(g, &path_buf);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, "ZPVF\x01\x00\x00\x00");
    try data.appendSlice(std.testing.allocator, "\x01a");
    try data.appendNTimes(std.testing.allocator, 0, 16);
    try data.append(std.testing.allocator, 1);
    try data.appendSlice(std.testing.allocator, "\x01\x00\x02\x00");
    try data.appendNTimes(std.testing.allocator, 0, 17);
    try data.appendSlice(std.testing.allocator, "\x00\x00");
    try std.testing.expectEqual(data.items.len - 8, try zpvRecordLen(data.items, 8, 15));
    try io_fs.writeFile(path, data.items);
    try savePlayers(g);
    const saved = try io_fs.readFileAll(std.testing.allocator, path);
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqual(saved.len - 8, try zpvRecordLen(saved, 8, persist_version));
    const inv_pos = 8 + 2 + 16;
    try std.testing.expectEqualSlices(u8, data.items[inv_pos..][0..22], saved[inv_pos..][0..22]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 31), saved[inv_pos + 22 ..][0..31]);
    try savePlayers(g);
    const again = try io_fs.readFileAll(std.testing.allocator, path);
    defer std.testing.allocator.free(again);
    try std.testing.expectEqualSlices(u8, saved, again);
}

test "wipePlayerRecordsByName erases without leaving players.zsv.bak" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    const g = try Game.create(std.testing.allocator, dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var path_buf: [512]u8 = undefined;
    const path = try playersPath(g, &path_buf);
    // Minimal ZPV2 single-record file (name "a", zeros for the rest of the
    // fixed prefix) so wipe has something to remove without a live client.
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, "ZPV2\x01\x00\x00\x00");
    try data.appendSlice(std.testing.allocator, "\x01a");
    try data.appendNTimes(std.testing.allocator, 0, 16); // pos + coins
    try data.append(std.testing.allocator, 0); // inv_n
    try data.append(std.testing.allocator, 0); // jn
    try io_fs.writeFile(path, data.items);
    // A stale bak from an older build must not keep the wiped login either.
    var bak_buf: [520]u8 = undefined;
    const bak = try std.fmt.bufPrint(&bak_buf, "{s}.bak", .{path});
    try io_fs.writeFile(bak, data.items);
    const removed = try wipePlayerRecordsByName(g, "a");
    try std.testing.expectEqual(@as(u32, 1), removed);
    try std.testing.expectError(error.FileNotFound, io_fs.readFileAll(std.testing.allocator, bak));
    const after = try io_fs.readFileAll(std.testing.allocator, path);
    defer std.testing.allocator.free(after);
    try std.testing.expect(after.len >= 8);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, after[4..8], .little));
}

test "player save preserves full inventory journal and buffs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    const g = try Game.create(std.testing.allocator, dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var capture: @import("../litenet/peer.zig").Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const objectives = [_]ecs.quest.FlatObjective{.{}} ** ecs.quest.max_quest_objectives;
    const defs = [_]ecs.quest.QuestDef{.{
        .id = 42,
        .kind = .kill_zombies,
        .name = "q" ** max_quest_name_len,
        .title = "capacity",
        .objectives = &objectives,
    }};
    const old_catalog = g.sim.catalog;
    defer g.sim.catalog = old_catalog;
    g.sim.catalog = .{ .defs = &defs };
    for (&g.sim.inventory[ps].slots) |*slot| slot.* = .{ .item_id = 1, .count = 1 };
    for (&g.sim.journal[ps].slots, 0..) |*q, i| q.* = .{
        .active = true,
        .def_id = 42,
        .quest_code = @intCast(i + 1),
        .obj_progress = [_]u16{7} ** ecs.quest.max_quest_objectives,
    };
    for (&g.sim.buffsMut(ps).slots, 0..) |*b, i| b.* = .{
        .active = true,
        .def_id = @intCast(i + 1),
        .duration_ticks = 400,
    };
    cl.level = 7;
    cl.has_bed = true;
    cl.bed_x = 12;
    cl.bed_y = 70;
    cl.bed_z = 34;
    try savePlayers(g);
    var path_buf: [512]u8 = undefined;
    const path = try playersPath(g, &path_buf);
    const data = try io_fs.readFileAll(std.testing.allocator, path);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(data.len - 8, try zpvRecordLen(data, 8, persist_version));
    const inventory = g.sim.inventory[ps];
    const journal = g.sim.journal[ps];
    const buffs = g.sim.buffs[ps];
    g.sim.inventory[ps] = .{};
    g.sim.journal[ps] = .{};
    g.sim.buffs[ps] = .{};
    cl.level = 1;
    cl.has_bed = false;
    tryRestorePlayer(g, cl);
    try std.testing.expectEqualDeep(inventory, g.sim.inventory[ps]);
    try std.testing.expectEqualDeep(journal, g.sim.journal[ps]);
    try std.testing.expectEqualDeep(buffs, g.sim.buffs[ps]);
    try std.testing.expectEqual(@as(u16, 7), cl.level);
    try std.testing.expect(cl.has_bed);
    try std.testing.expectEqual(@as(i32, 34), cl.bed_z);
    var oversized_defs = defs;
    oversized_defs[0].name = "q" ** (max_quest_name_len + 1);
    g.sim.catalog = .{ .defs = &oversized_defs };
    try std.testing.expectError(error.QuestNameTooLong, savePlayers(g));
    const unchanged = try io_fs.readFileAll(std.testing.allocator, path);
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualSlices(u8, data, unchanged);
}
