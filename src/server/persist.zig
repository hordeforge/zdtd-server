//! Save/restore for zdtd-owned persistence: players.zsv (ZPV8), entities.zen
//! (ZENT1), claims.zlc (ZCL1), clock.zcl, weather.zwt (ZWTH1) and the chunk
//! blockmeta/raw planes.
//!
//! Extracted from game.zig following the replicate_te precedent: these take
//! `*Game` as the first parameter and are called as `persist.savePlayers(g, …)`.
//! game.zig keeps one-line delegating methods so existing callers (tick,
//! deinit, tests) are unchanged.

const std = @import("std");
const game_mod = @import("game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const io_fs = @import("../util/io_fs.zig");
const wire_binary = @import("../wire/binary.zig");
const ecs = @import("../ecs/root.zig");
const clock = @import("../util/clock.zig");
const max_land_claims = game_mod.max_land_claims;

pub fn logPersistErr(self: *Game, what: []const u8, err: anyerror) void {
    self.harness.counters.inc(.persistence_errors);
    const n = self.harness.counters.get(.persistence_errors);
    if (n == 1 or n % 100 == 0) {
        var ts: [19]u8 = undefined;
        std.debug.print("zdtd: {s} {s} failed: {s} n={d}\n", .{ clock.wallStamp(&ts), what, @errorName(err), n });
    }
}

/// One canonical ladder over every zdtd-owned store, so an operator-triggered
/// save covers exactly what the autosave tick covers. Each store is attempted
/// even when an earlier one failed; returns false if any failed (already
/// logged), so callers never report success over a disk error.
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
    self.workstations.save(self.world.world_dir, self.allocator) catch |e| note(&ok, self, "save workstations", e);
    self.vending.save(self.world.world_dir) catch |e| note(&ok, self, "save vending", e);
    self.saveClaims() catch |e| note(&ok, self, "save claims", e);
    self.saveEntities() catch |e| note(&ok, self, "save entities", e);
    saveTraders(self) catch |e| note(&ok, self, "save traders", e);
    self.sleepers.saveCleared(self.allocator, self.world.world_dir) catch |e| note(&ok, self, "save sleepers-cleared", e);
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
/// keeps the player's wounds. The bedroll field is **not** detected by "more
/// bytes remain in the file": that is ambiguous whenever another record
/// follows this one, since the next record's own name_len byte would be
/// misread as this record's bed_present. Only the file's own magic decides
/// whether a bedroll field is present, the same way `prog` already gates the
/// rest of the v3 tail.

/// Inventory slot-record stride in bytes: 7 through v6
/// (item:u16, count:u16, quality:u8, meta:u16), 11 from v7 (those plus
/// use_times: f32).
pub fn zpvSlotStride(version: u8) usize {
    return if (version >= 7) 11 else 7;
}

/// Convert a legacy 7-byte inventory slot block to the v7 11-byte shape:
/// each slot keeps (item, count, quality, meta) and appends a zero
/// `use_times` (f32) - carried old records have no known durability.
fn emitZpv7Slots(out: *std.ArrayList(u8), allocator: std.mem.Allocator, old: []const u8, inv_n_pos: usize, inv_n: usize) !void {
    try out.append(allocator, old[inv_n_pos]); // inv_n byte
    var p = inv_n_pos + 1;
    var k: usize = 0;
    while (k < inv_n) : (k += 1) {
        try out.appendSlice(allocator, old[p .. p + 7]);
        try out.appendNTimes(allocator, 0, 4);
        p += 7;
    }
}

/// Position of a v3+ record's progression-tail prog byte (journal end).
/// v2 records have no tail; returns the record end.
fn tailStartOf(old: []const u8, rec_start: usize, nl: usize, version: u8) error{CorruptPlayersFile}!usize {
    const inv_pos = rec_start + 1 + nl + 16;
    const inv_n: usize = old[inv_pos];
    const jn_pos = inv_pos + 1 + inv_n * 7;
    const jn: usize = old[jn_pos];
    return journalSectionEnd(old, jn_pos + 1, jn, version);
}

/// v3-7 tails are `prog | level | xp | stats(16) | buff...`; v8 inserts
/// hp:f32 after the stats block. A carried record has no known hp, so the
/// migrated tail inserts a -1 sentinel: the restore skips negative hp and
/// the spawn path's full health stands, exactly the pre-ZPV8 relog behavior.
fn emitZpv8TailHp(out: *std.ArrayList(u8), allocator: std.mem.Allocator, old: []const u8, tail_start: usize, tail_end: usize, version: u8) !void {
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
    var hp_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &hp_bytes, @bitCast(@as(f32, -1.0)), .little);
    try out.appendSlice(allocator, &hp_bytes);
    try out.appendSlice(allocator, old[p + fixed .. tail_end]);
}

pub fn zpvRecordLen(data: []const u8, off: usize, version: u8) error{CorruptPlayersFile}!usize {
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
            // ZPV8 adds hp:f32 after the four survival-stat floats.
            const tail_stats: usize = if (version >= 8) 2 + 8 + 16 + 4 else 2 + 8 + 16;
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
        }
    }
    return p - off;
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
fn zpvRecordHasProgTail(data: []const u8, off: usize, version: u8) bool {
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

/// Record layout (v5+): magic ZPVN | n:u32 | records…
/// each: name_len:u8 | name | x,y,z:f32 | coins:u32 |
///   inv_n:u8 | inv_n×(item:u16, count:u16, quality:u8, meta:u16[, use_times:f32 from v7]) |
///   jn:u8 | jn×(def_id:u16, quest_code:i32, flags:u8, progress:u16, phase:u8,
///     name_len:u8, name, poi_valid:u8, poi rect:f32×6)
///   prog:u8 (1 = present) | level:u16 | xp:u64 | food/max/water/max:f32×4 |
///   hp:f32 (v8+) |
///   buff_n:u8 | buff_n×(def_id:u16, stack:u8, flags:u8, dur_ticks:u32,
///   upd_ticks:u16, upd_rate:i32, dur_max:f32, remove_on_death:u8) |
///   bed_present:u8 (1 = present) | bed_present×(bed_x,bed_y,bed_z:i32)
/// v5 journal entries add the quest **name** (the stock Quest.Write identity,
/// so a quests.xml edit no longer reshuffles a saved quest into a different
/// one) and the POI rect (stock PositionData[2/3], so a restored quest keeps
/// the prefab it was handed, not the nearest re-resolved one).
/// bed_present is v4+-only; it is not written or read at all under an older
/// magic, since "more bytes remain in the file" cannot distinguish "one more
/// field of this record" from "the next record has begun" (zpvRecordLen).
/// ZPV2 (no progression tail), ZPV3 (tail, no bedroll) and ZPV4 (no name/rect
/// in the journal) files are still read and upgraded in place on the next
/// save: v<5 records are re-encoded (the journal grows), not carried
/// byte-for-byte. Merge-write: offline players' existing records are carried
/// over, not erased.
/// ADR 0011 sibling stores; item_id = ECS handle (ADR 0015).
pub fn savePlayers(self: *Game) !void {
    var path_buf: [512]u8 = undefined;
    const path = try self.playersPath(&path_buf);

    // Carry the on-disk records by slice: a fixed scratch buffer silently
    // dropped every offline player past its size on each autosave.
    var old_file: []u8 = &.{};
    defer self.allocator.free(old_file);
    var old_recs: []const u8 = &.{};
    var old_count: u32 = 0;
    var old_version: u8 = 8;
    if (io_fs.readFileAll(self.allocator, path)) |old_data| {
        old_file = old_data;
        if (old_data.len < 8 or !std.mem.eql(u8, old_data[0..3], "ZPV") or
            (old_data[3] != '2' and old_data[3] != '3' and old_data[3] != '4' and old_data[3] != '5' and old_data[3] != '6' and old_data[3] != '7' and old_data[3] != '8'))
            return error.CorruptPlayersFile;
        old_version = old_data[3] - '0';
        old_count = std.mem.readInt(u32, old_data[4..8], .little);
        old_recs = old_data[8..];
        // Unreadable existing file: abort save so offline player records in
        // the on-disk file are not clobbered by a save missing them.
    } else |e| if (e != error.FileNotFound) return e;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);

    // Header count is patched in last, from records actually appended. A
    // count predicted up front drifts whenever a joined client has no ECS
    // player slot, and the loader then walks past the last record.
    try out.appendSlice(self.allocator, &[_]u8{ 'Z', 'P', 'V', '8', 0, 0, 0, 0 });
    var written: u32 = 0;
    {
        var ri: u32 = 0;
        var off: usize = 0;
        while (ri < old_count) : (ri += 1) {
            const rec_start = off;
            const rec_len = zpvRecordLen(old_recs, off, old_version) catch return error.CorruptPlayersFile;
            const nl: usize = old_recs[off];
            const rec_name = old_recs[off + 1 ..][0..nl];
            const had_prog_tail = zpvRecordHasProgTail(old_recs, off, old_version);
            off += rec_len;
            // Drop an old on-disk record only when this save will re-write the
            // client's state fresh. A joined client with no live sim slot yet
            // (entity_id 0, or playerByPeer pending) must not lose its persisted
            // record: matching "joined + name" alone used to classify such a
            // client as online and silently erased the record, since the fresh
            // loop below skips it. Match the write predicate exactly to avoid a
            // lost-update window on a connected-but-not-spawned player.
            var rewritten = false;
            for (&self.clients) |*cl| {
                if (!cl.joined or cl.entity_id <= 0 or cl.name_len == 0) continue;
                if (cl.name_len != nl or !std.mem.eql(u8, cl.name[0..nl], rec_name)) continue;
                if (self.sim.playerByPeer(cl.slot) == null) continue;
                rewritten = true;
                break;
            }
            if (rewritten) continue;
            if (old_version == 8) {
                // v8 records are already the current shape: carry verbatim.
                try out.appendSlice(self.allocator, old_recs[rec_start..off]);
                written += 1;
                continue;
            }
            if (old_version == 7) {
                // v7 records are v8-shaped except the tail hp: insert full
                // health into every carried tail (the pre-ZPV8 relog behavior
                // was fresh full HP).
                const tail_start = tailStartOf(old_recs, rec_start, nl, 7) catch return error.CorruptPlayersFile;
                try out.appendSlice(self.allocator, old_recs[rec_start..tail_start]);
                try emitZpv8TailHp(&out, self.allocator, old_recs, tail_start, off, 7);
                written += 1;
                continue;
            }
            if (old_version == 6) {
                // v6 records are v8-shaped except the 7-byte inventory slots
                // and the tail hp: widen the slots to 11 (appending a zero
                // use_times), carry the journal byte-for-byte so it keeps its
                // per-objective progress verbatim, and insert the tail hp.
                const inv_pos: usize = rec_start + 1 + nl + 16;
                const inv_n: usize = old_recs[inv_pos];
                const slots_end = inv_pos + 1 + inv_n * 7;
                const tail_start = tailStartOf(old_recs, rec_start, nl, 6) catch return error.CorruptPlayersFile;
                try out.appendSlice(self.allocator, old_recs[rec_start..inv_pos]);
                try emitZpv7Slots(&out, self.allocator, old_recs, inv_pos, inv_n);
                try out.appendSlice(self.allocator, old_recs[slots_end..tail_start]);
                try emitZpv8TailHp(&out, self.allocator, old_recs, tail_start, off, 6);
                written += 1;
                continue;
            }
            // v<6 records are re-encoded into the v7 layout: the inventory
            // slot block widens 7 -> 11 bytes (use_times f32 appended) and the
            // journal section grows per quest (v5 added name + POI rect; v6
            // adds per-objective progress), so the record cannot be carried
            // byte-for-byte. Header copies verbatim; slots are widened with a
            // zero use_times; the journal is rewritten (names resolved from
            // the stored name when present, else from the catalog by the
            // stored def_id; legacy entries carry no rect → poi_valid=0;
            // per-objective progress unknown → zeros); the tail copies
            // verbatim, still with the v2->v3 / v3->v4 upgrade bytes so the
            // progression/bedroll fields parse under v7.
            var jp: usize = rec_start + 1 + nl + 16; // inv_n byte
            const inv_n: usize = old_recs[jp];
            const inv_pos = jp;
            jp += 1 + inv_n * 7;
            const jn: usize = old_recs[jp];
            try out.appendSlice(self.allocator, old_recs[rec_start..inv_pos]);
            try emitZpv7Slots(&out, self.allocator, old_recs, inv_pos, inv_n);
            try out.appendSlice(self.allocator, old_recs[jp .. jp + 1]); // jn byte
            var qp: usize = jp + 1;
            {
                var qi: usize = 0;
                while (qi < jn) : (qi += 1) {
                    // Legacy entry core: def_id, code, flags, progress, phase.
                    if (qp + 10 > off) break;
                    const qb = old_recs[qp..][0..10];
                    qp += 10;
                    var qname: []const u8 = "";
                    var qpoi_valid: u8 = 0;
                    var qrect: [24]u8 = [_]u8{0} ** 24;
                    var qobj_n: usize = 0;
                    if (old_version >= 5) {
                        if (qp >= off) break;
                        const qnl: usize = old_recs[qp];
                        qp += 1;
                        if (qnl > max_quest_name_len or qp + qnl + 25 > off) break;
                        qname = old_recs[qp..][0..qnl];
                        qp += qnl;
                        qpoi_valid = old_recs[qp];
                        qp += 1;
                        @memcpy(&qrect, old_recs[qp..][0..24]);
                        qp += 24;
                        if (old_version >= 6) {
                            if (qp >= off) break;
                            qobj_n = old_recs[qp];
                            qp += 1 + qobj_n * 2;
                        }
                    }
                    if (qname.len == 0) {
                        const qdef = std.mem.readInt(u16, qb[0..2], .little);
                        qname = if (self.sim.catalog.byId(qdef)) |qd| qd.name else "";
                    }
                    if (qname.len > max_quest_name_len) {
                        // Fail closed: an unrepresentable name drops the quest
                        // from the carried record rather than corrupting the walk.
                        continue;
                    }
                    // Emit the v6 entry: core + name + poi_valid + rect +
                    // obj_n + obj_n×u16 zeros (legacy saves have no per-objective
                    // progress; the count rides the resolved def).
                    try out.appendSlice(self.allocator, qb);
                    try out.append(self.allocator, @intCast(qname.len));
                    try out.appendSlice(self.allocator, qname);
                    try out.append(self.allocator, qpoi_valid);
                    try out.appendSlice(self.allocator, &qrect);
                    if (qobj_n == 0) {
                        const qdef = std.mem.readInt(u16, qb[0..2], .little);
                        if (self.sim.catalog.byId(qdef)) |qd| qobj_n = @min(qd.objectives.len, ecs.quest.max_quest_objectives);
                    }
                    try out.append(self.allocator, @intCast(@min(qobj_n, ecs.quest.max_quest_objectives)));
                    try out.appendNTimes(self.allocator, 0, @min(qobj_n, ecs.quest.max_quest_objectives) * 2);
                }
            }
            try emitZpv8TailHp(&out, self.allocator, old_recs, qp, off, old_version);
            // Legacy upgrade bytes, as before: v2 -> v3 needs an empty prog
            // byte (0, no tail at all); v3 (or an upgraded v2) needs a
            // bed_present byte (0) appended only when it actually has a
            // progression tail, since a tail-less record has nowhere for a
            // bedroll field to attach.
            if (old_version < 3) {
                try out.append(self.allocator, 0);
            } else if (old_version < 4 and had_prog_tail) {
                try out.append(self.allocator, 0);
            }
            written += 1;
        }
    }
    for (&self.clients) |*cl| {
        if (!cl.joined or cl.entity_id <= 0 or cl.name_len == 0) continue;
        const ps = self.sim.playerByPeer(cl.slot) orelse continue;
        var rec: [2048]u8 = undefined;
        var o: usize = 0;
        rec[o] = @intCast(cl.name_len);
        o += 1;
        @memcpy(rec[o..][0..cl.name_len], cl.name[0..cl.name_len]);
        o += cl.name_len;
        const save_y: f32 = if (self.sim.transform[ps].y < 2)
            @floatFromInt(self.world.primarySpawn().y)
        else
            self.sim.transform[ps].y;
        inline for (.{ self.sim.transform[ps].x, save_y, self.sim.transform[ps].z }) |f| {
            std.mem.writeInt(u32, rec[o..][0..4], @as(u32, @bitCast(f)), .little);
            o += 4;
        }
        std.mem.writeInt(u32, rec[o..][0..4], if (self.sim.mask[ps].wallet) self.sim.wallet[ps].coins else 0, .little);
        o += 4;
        const inv_start = o;
        o += 1;
        var inv_n: u8 = 0;
        if (self.sim.mask[ps].inventory) {
            for (self.sim.inventory[ps].slots) |s| {
                // ZPV7 slot record: item:u16, count:u16, quality:u8, meta:u16,
                // use_times:f32 (stock ItemValue.UseTimes, tool durability).
                if (o + 11 > rec.len) break;
                std.mem.writeInt(u16, rec[o..][0..2], s.item_id, .little);
                std.mem.writeInt(u16, rec[o + 2 ..][0..2], s.count, .little);
                rec[o + 4] = s.quality;
                std.mem.writeInt(u16, rec[o + 5 ..][0..2], s.meta, .little);
                std.mem.writeInt(u32, rec[o + 7 ..][0..4], @as(u32, @bitCast(s.use_times)), .little);
                o += 11;
                inv_n += 1;
            }
        }
        rec[inv_start] = inv_n;
        const j_start = o;
        o += 1;
        var jn: u8 = 0;
        if (self.sim.mask[ps].journal) {
            for (self.sim.journal[ps].slots) |q| {
                if (!q.active and !q.completed and !q.failed) continue;
                // v6 entry: fixed core + name + poi_valid + rect + obj_n +
                // obj_n×u16 per-objective progress (stock BaseObjective.Write
                // per-objective CurrentValue). The name is the stock
                // Quest.Write identity; the rect is stock PositionData[2/3].
                const qd = self.sim.catalog.byId(q.def_id);
                const qname = if (qd) |d| d.name else "";
                const obj_n: usize = if (qd) |d| @min(d.objectives.len, ecs.quest.max_quest_objectives) else 0;
                if (qname.len > max_quest_name_len or o + 10 + 1 + qname.len + 25 + 1 + obj_n * 2 > rec.len) break;
                std.mem.writeInt(u16, rec[o..][0..2], q.def_id, .little);
                std.mem.writeInt(i32, rec[o + 2 ..][0..4], q.quest_code, .little);
                rec[o + 6] = (@as(u8, @intFromBool(q.active))) | (@as(u8, @intFromBool(q.completed)) << 1) | (@as(u8, @intFromBool(q.ready_turn_in)) << 2) | (@as(u8, @intFromBool(q.rally_activated)) << 3) | (@as(u8, @intFromBool(q.failed)) << 4);
                std.mem.writeInt(u16, rec[o + 7 ..][0..2], q.progress, .little);
                rec[o + 9] = q.phase;
                rec[o + 10] = @intCast(qname.len);
                @memcpy(rec[o + 11 ..][0..qname.len], qname);
                var p = o + 11 + qname.len;
                const poi_valid = q.poi.valid();
                rec[p] = @intFromBool(poi_valid);
                p += 1;
                if (poi_valid) {
                    inline for (.{ q.poi.x, q.poi.y, q.poi.z, q.poi.size_x, q.poi.size_y, q.poi.size_z }) |f| {
                        std.mem.writeInt(u32, rec[p..][0..4], @as(u32, @bitCast(f)), .little);
                        p += 4;
                    }
                } else {
                    @memset(rec[p..][0..24], 0);
                    p += 24;
                }
                rec[p] = @intCast(obj_n);
                p += 1;
                var oi: usize = 0;
                while (oi < obj_n) : (oi += 1) {
                    std.mem.writeInt(u16, rec[p..][0..2], if (oi < q.obj_progress.len) q.obj_progress[oi] else 0, .little);
                    p += 2;
                }
                o = p;
                jn += 1;
            }
        }
        rec[j_start] = jn;
        // ZPV3 progression tail: level/xp/survival stats + active buffs.
        // Best-effort like inv/journal: a full record simply truncates.
        if (o + 2 + 8 + 16 + 1 <= rec.len) {
            rec[o] = 1;
            o += 1;
            std.mem.writeInt(u16, rec[o..][0..2], cl.level, .little);
            o += 2;
            std.mem.writeInt(u64, rec[o..][0..8], cl.xp, .little);
            o += 8;
            const h = &self.sim.health[ps];
            inline for (.{ h.food, h.food_max, h.water, h.water_max }) |f| {
                if (o + 4 > rec.len) break;
                std.mem.writeInt(u32, rec[o..][0..4], @as(u32, @bitCast(f)), .little);
                o += 4;
            }
            // ZPV8: current hp (normalized 0..1, stock EntityStats health
            // fraction). Restored after spawn, so a relog keeps the player's
            // wounds instead of granting a free full heal.
            if (o + 4 <= rec.len) {
                std.mem.writeInt(u32, rec[o..][0..4], @as(u32, @bitCast(h.hp)), .little);
                o += 4;
            }
            const buff_n_pos = o;
            rec[o] = 0;
            o += 1;
            var buff_n: u8 = 0;
            if (self.sim.mask[ps].buffs) {
                for (self.sim.buffs[ps].slots) |b| {
                    if (!b.active) continue;
                    if (o + 19 > rec.len) break;
                    std.mem.writeInt(u16, rec[o..][0..2], b.def_id, .little);
                    rec[o + 2] = b.stack_mult;
                    rec[o + 3] = @bitCast(b.flags);
                    std.mem.writeInt(u32, rec[o + 4 ..][0..4], b.duration_ticks, .little);
                    std.mem.writeInt(u16, rec[o + 8 ..][0..2], b.update_ticks, .little);
                    std.mem.writeInt(i32, rec[o + 10 ..][0..4], b.update_rate_ticks, .little);
                    std.mem.writeInt(u32, rec[o + 14 ..][0..4], @as(u32, @bitCast(b.duration_max)), .little);
                    rec[o + 18] = @intFromBool(b.remove_on_death);
                    o += 19;
                    buff_n += 1;
                }
            }
            rec[buff_n_pos] = buff_n;
            // Bedroll (server-lifecycle.md section 6.1: PersistentPlayerData.Write
            // carries the bedroll position as a first-class field). Presence byte
            // matches the progression-tail convention above: cl.has_bed off ->
            // 0 and no payload, so an unset bedroll costs one byte, not twelve.
            if (o + 1 <= rec.len) {
                if (cl.has_bed and o + 1 + 12 <= rec.len) {
                    rec[o] = 1;
                    o += 1;
                    inline for (.{ cl.bed_x, cl.bed_y, cl.bed_z }) |v| {
                        std.mem.writeInt(i32, rec[o..][0..4], v, .little);
                        o += 4;
                    }
                } else {
                    rec[o] = 0;
                    o += 1;
                }
            }
        } else {
            rec[o] = 0; // truncated: mark no progression tail
            o += 1;
        }
        try out.appendSlice(self.allocator, rec[0..o]);
        written += 1;
    }
    std.mem.writeInt(u32, out.items[4..][0..4], written, .little);
    try io_fs.writeFile(path, out.items);
}

/// Remove all players.zsv records whose login name equals `name`.
/// Returns how many records were dropped. FileNotFound → 0 (no-op).
/// Does not log the name (operator reply only).
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
    try io_fs.writeFile(path, filtered.blob.?);
    return filtered.removed;
}

pub fn tryRestorePlayer(self: *Game, c: *Client) void {
    if (c.name_len == 0) return;
    var path_buf: [512]u8 = undefined;
    const path = self.playersPath(&path_buf) catch |err| {
        std.debug.print("zdtd: restore player: path failed: {s}\n", .{@errorName(err)});
        return;
    };
    const data = io_fs.readFileAll(self.allocator, path) catch |e| {
        if (e != error.FileNotFound) logPersistErr(self, "restore player", e);
        return;
    };
    defer self.allocator.free(data);
    if (data.len < 8 or data[0] != 'Z' or data[1] != 'P' or
        (data[3] != '2' and data[3] != '3' and data[3] != '4' and data[3] != '5' and data[3] != '6' and data[3] != '7' and data[3] != '8'))
    {
        std.debug.print("zdtd: restore player: bad players file header\n", .{});
        return;
    }
    const version: u8 = data[3] - '0';
    const v3 = version >= 3;
    const slot_stride: usize = zpvSlotStride(version);
    const n = std.mem.readInt(u32, data[4..8], .little);
    var off: usize = 8;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (off >= data.len) {
            std.debug.print("zdtd: restore player: truncated at record {d}/{d}\n", .{ i, n });
            return;
        }
        const rec_start = off;
        const nl: usize = data[off];
        off += 1;
        if (nl > 32 or off + nl + 16 + 1 > data.len) {
            std.debug.print("zdtd: restore player: corrupt record {d}/{d} (name_len={d})\n", .{ i, n, nl });
            return;
        }
        const name_slice = data[off..][0..nl];
        off += nl;
        const rest = data[off..][0..16];
        off += 16;
        const inv_n: usize = data[off];
        off += 1;
        if (off + inv_n * slot_stride + 1 > data.len) {
            std.debug.print("zdtd: restore player: truncated inventory at record {d}/{d}\n", .{ i, n });
            return;
        }
        var inv: [ecs.components.max_inv_slots]ecs.components.InvSlot = undefined;
        var k: usize = 0;
        while (k < inv_n) : (k += 1) {
            const ib = data[off..][0..slot_stride];
            off += slot_stride;
            if (k < inv.len) inv[k] = .{
                .item_id = std.mem.readInt(u16, ib[0..2], .little),
                .count = std.mem.readInt(u16, ib[2..4], .little),
                .quality = ib[4],
                .meta = std.mem.readInt(u16, ib[5..7], .little),
                .use_times = if (slot_stride >= 11) @as(f32, @bitCast(std.mem.readInt(u32, ib[7..11], .little))) else 0,
            };
        }
        const jn: usize = data[off];
        off += 1;
        if (off + jn * 10 > data.len) {
            std.debug.print("zdtd: restore player: truncated journal at record {d}/{d}\n", .{ i, n });
            return;
        }
        var quests: [ecs.components.max_journal]ecs.components.QuestProgress = undefined;
        var qi: usize = 0;
        while (qi < jn) : (qi += 1) {
            // v5 entries append name_len/name/poi_valid/rect after the fixed
            // 10-byte core; v<=4 entries are core only. The name is the stock
            // Quest.Write identity, so a quests.xml edit cannot reshuffle the
            // restored quest into a different one (byName wins over the stored
            // parse-order def_id); the rect keeps the POI the quest was handed.
            if (off + 10 > data.len) {
                std.debug.print("zdtd: restore player: truncated journal core at record {d}/{d}\n", .{ i, n });
                return;
            }
            const qb = data[off..][0..10];
            off += 10;
            if (qi < quests.len) quests[qi] = .{
                .def_id = std.mem.readInt(u16, qb[0..2], .little),
                .quest_code = std.mem.readInt(i32, qb[2..6], .little),
                .active = (qb[6] & 1) != 0,
                .completed = (qb[6] & 2) != 0,
                .ready_turn_in = (qb[6] & 4) != 0,
                .progress = std.mem.readInt(u16, qb[7..9], .little),
                .phase = qb[9],
                // Bit 3 was always zero before rally markers existed, so old
                // saves read back as "marker not yet used" without a bump.
                // Bit 4 (failed) is v6+; older saves read back un-failed.
                .rally_activated = (qb[6] & 8) != 0,
                .failed = (qb[6] & 16) != 0,
            };
            if (version >= 5) {
                // name_len + name + poi_valid + rect(24)
                if (off >= data.len) {
                    std.debug.print("zdtd: restore player: truncated journal name at record {d}/{d}\n", .{ i, n });
                    return;
                }
                const qnl: usize = data[off];
                off += 1;
                if (qnl > max_quest_name_len or off + qnl + 25 > data.len) {
                    std.debug.print("zdtd: restore player: truncated journal name/rect at record {d}/{d}\n", .{ i, n });
                    return;
                }
                if (qi < quests.len) {
                    const qname = data[off..][0..qnl];
                    // Stock identity: resolve by name first; a def dropped from
                    // quests.xml keeps its stored id fallback so the slot is
                    // not silently rebound to a different quest.
                    if (qnl > 0) {
                        if (self.sim.catalog.byName(qname)) |qd| quests[qi].def_id = qd.id;
                    }
                    off += qnl;
                    const poi_valid = data[off];
                    off += 1;
                    if (poi_valid != 0) {
                        var rect: ecs.components.PoiRect = .{};
                        inline for (.{ &rect.x, &rect.y, &rect.z, &rect.size_x, &rect.size_y, &rect.size_z }) |f| {
                            f.* = @bitCast(std.mem.readInt(u32, data[off..][0..4], .little));
                            off += 4;
                        }
                        if (rect.valid()) quests[qi].poi = rect;
                    } else {
                        off += 24;
                    }
                    if (version >= 6) {
                        // obj_n + obj_n×u16 per-objective progress
                        if (off >= data.len) {
                            std.debug.print("zdtd: restore player: truncated journal obj_n at record {d}/{d}\n", .{ i, n });
                            return;
                        }
                        const obj_n: usize = data[off];
                        off += 1;
                        if (obj_n > ecs.quest.max_quest_objectives or off + obj_n * 2 > data.len) {
                            std.debug.print("zdtd: restore player: truncated journal obj_progress at record {d}/{d}\n", .{ i, n });
                            return;
                        }
                        var oi: usize = 0;
                        while (oi < obj_n and oi < quests[qi].obj_progress.len) : (oi += 1) {
                            quests[qi].obj_progress[oi] = std.mem.readInt(u16, data[off..][0..2], .little);
                            off += 2;
                        }
                        off += (obj_n -| @min(obj_n, quests[qi].obj_progress.len)) * 2;
                    }
                } else {
                    off += qnl + 25;
                    if (version >= 6) {
                        if (off >= data.len) {
                            std.debug.print("zdtd: restore player: truncated journal obj_n at record {d}/{d}\n", .{ i, n });
                            return;
                        }
                        const obj_n: usize = data[off];
                        off += 1 + obj_n * 2;
                    }
                }
            }
        }
        if (!(c.name_len == nl and std.mem.eql(u8, c.name[0..nl], name_slice))) {
            // ZPV3 records carry a progression tail after the journal;
            // consume it for non-matching records too so the scan stays
            // aligned with the next record.
            if (v3) {
                off = rec_start + (zpvRecordLen(data, rec_start, version) catch |e| {
                    std.debug.print("zdtd: restore player: corrupt tail at record {d}/{d} ({s})\n", .{ i, n, @errorName(e) });
                    return;
                });
            }
            continue;
        }
        const x: f32 = @bitCast(std.mem.readInt(u32, rest[0..4], .little));
        var y: f32 = @bitCast(std.mem.readInt(u32, rest[4..8], .little));
        const z: f32 = @bitCast(std.mem.readInt(u32, rest[8..12], .little));
        const coins = std.mem.readInt(u32, rest[12..16], .little);
        const ps = self.sim.playerByPeer(c.slot) orelse return;
        if (y < 2) {
            const sp2 = self.world.primarySpawn();
            y = @floatFromInt(sp2.y);
        }
        self.sim.transform[ps] = .{ .x = x, .y = y, .z = z, .yaw = 0 };
        if (self.sim.mask[ps].wallet) self.sim.wallet[ps].coins = coins;
        if (self.sim.mask[ps].inventory) {
            self.sim.inventory[ps] = .{};
            var fi: usize = 0;
            while (fi < inv_n and fi < inv.len) : (fi += 1) {
                if (fi < self.sim.inventory[ps].slots.len) self.sim.inventory[ps].slots[fi] = inv[fi];
            }
        }
        if (self.sim.mask[ps].journal) {
            self.sim.journal[ps] = .{};
            var fq: usize = 0;
            while (fq < jn and fq < quests.len) : (fq += 1) {
                self.sim.journal[ps].slots[fq] = quests[fq];
                // ZPV5 persists the POI rect (stock PositionData[2/3]), so a
                // restored quest keeps the prefab it was handed; legacy files
                // have none and re-resolve from the world (stock re-derives
                // QuestPrefab from the position data it persisted — old zdtd
                // saves simply lack the data, so the nearest-POI fallback is
                // the honest equivalent, audit B26).
                if (self.sim.journal[ps].slots[fq].poi.valid()) continue;
                const qd = self.sim.catalog.byId(quests[fq].def_id) orelse continue;
                if (self.sim.poiAt(qd.tx, qd.tz)) |rect| {
                    self.sim.journal[ps].slots[fq].poi = rect;
                } else if (qd.kind == .goto_point or qd.kind == .stay_within or qd.kind == .craft) {
                    if (self.sim.nearestPoi(
                        self.sim.transform[ps].x,
                        self.sim.transform[ps].z,
                    )) |rect| {
                        self.sim.journal[ps].slots[fq].poi = rect;
                    }
                }
            }
        }
        // ZPV3 progression tail: level/xp/survival stats + active buffs.
        if (v3) {
            if (off >= data.len) return;
            const prog = data[off];
            off += 1;
            if (prog == 1 and off + 2 + 8 + 16 + 1 <= data.len) {
                c.level = std.mem.readInt(u16, data[off..][0..2], .little);
                off += 2;
                c.xp = std.mem.readInt(u64, data[off..][0..8], .little);
                off += 8;
                var stats: [4]f32 = undefined;
                inline for (0..4) |si| {
                    stats[si] = @bitCast(std.mem.readInt(u32, data[off..][0..4], .little));
                    off += 4;
                }
                if (self.sim.mask[ps].health) {
                    self.sim.health[ps].food = stats[0];
                    self.sim.health[ps].food_max = stats[1];
                    self.sim.health[ps].water = stats[2];
                    self.sim.health[ps].water_max = stats[3];
                }
                // ZPV8: hp (0..max) after the stats block. Restored on the
                // post-spawn restore pass (tryRestorePlayer runs again after
                // spawnPlayer), so a relog keeps the player's wounds instead
                // of granting a free full heal. Negative hp = migrated record
                // sentinel: keep the spawn path's full health.
                if (version >= 8 and off + 4 <= data.len and self.sim.mask[ps].health) {
                    const hp: f32 = @bitCast(std.mem.readInt(u32, data[off..][0..4], .little));
                    if (hp >= 0) self.sim.health[ps].hp = hp;
                    off += 4;
                } else if (version >= 8) {
                    off += 4;
                }
                if (off < data.len) {
                    const buff_n = data[off];
                    off += 1;
                    if (off + buff_n * 19 <= data.len) {
                        const bs = self.sim.buffsMut(ps);
                        var bi: usize = 0;
                        while (bi < buff_n) : (bi += 1) {
                            const bb = data[off..][0..19];
                            off += 19;
                            const slot = bs.findFree() orelse break;
                            slot.* = .{
                                .active = true,
                                .def_id = std.mem.readInt(u16, bb[0..2], .little),
                                .stack_mult = bb[2],
                                .flags = @bitCast(bb[3]),
                                .duration_ticks = std.mem.readInt(u32, bb[4..8], .little),
                                .update_ticks = std.mem.readInt(u16, bb[8..10], .little),
                                .update_rate_ticks = std.mem.readInt(i32, bb[10..14], .little),
                                .duration_max = @bitCast(std.mem.readInt(u32, bb[14..18], .little)),
                                .remove_on_death = bb[18] != 0,
                            };
                        }
                    }
                }
                // Bedroll tail (see savePlayers / zpvRecordLen): gated on the
                // file's own version, not "bytes remain" (ambiguous whenever
                // another record follows this one in the file).
                if (version >= 4 and off < data.len) {
                    const bed_present = data[off];
                    off += 1;
                    if (bed_present == 1 and off + 12 <= data.len) {
                        c.has_bed = true;
                        c.bed_x = std.mem.readInt(i32, data[off..][0..4], .little);
                        off += 4;
                        c.bed_y = std.mem.readInt(i32, data[off..][0..4], .little);
                        off += 4;
                        c.bed_z = std.mem.readInt(i32, data[off..][0..4], .little);
                        off += 4;
                    } else {
                        c.has_bed = false;
                    }
                }
            }
        }
        return;
    }
}

pub fn saveEntities(self: *Game) !void {
    var path: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/entities.zen", .{self.world.world_dir});
    // Vehicle/turret records (32 B each) plus the power-wire section
    // (24 B per saved edge, 512 max).
    var buf: [ecs.max_entities * 32 + ecs.electric.max_wires * 24 + 16]u8 = undefined;
    var w = wire_binary.Writer{ .buf = &buf };
    // Overflow must propagate (callers log persistence errors): a silent
    // abort here would drop the vehicle/turret save without any signal.
    try w.writeBytes("ZENT");
    try w.writeU16(0); // count patched below
    var count: u16 = 0;
    var i: usize = 0;
    while (i < ecs.max_entities) : (i += 1) {
        if (!self.sim.alive[i] or !self.sim.mask[i].transform) continue;
        if (self.sim.kind[i] == .vehicle) {
            const v = self.sim.vehicle[i];
            try w.writeByte(1);
            try w.writeByte(@intFromEnum(v.kind));
            try w.writeF32(self.sim.transform[i].x);
            try w.writeF32(self.sim.transform[i].y);
            try w.writeF32(self.sim.transform[i].z);
            try w.writeF32(self.sim.transform[i].yaw);
            try w.writeF32(v.fuel);
            try w.writeByte(v.seat_count);
            try w.writeF32(v.max_speed);
            count += 1;
        } else if (self.sim.kind[i] == .turret) {
            const t = self.sim.turret[i];
            try w.writeByte(2);
            try w.writeF32(self.sim.transform[i].x);
            try w.writeF32(self.sim.transform[i].y);
            try w.writeF32(self.sim.transform[i].z);
            try w.writeF32(t.range);
            try w.writeF32(t.damage);
            try w.writeU16(t.ammo);
            count += 1;
        }
    }
    // Power wire edges by endpoint position (node ids are per-session).
    // The grid also keeps a live wire list plus any pending reconnect set;
    // saving both would duplicate, so persist the live wires only.
    if (self.sim.power.wire_n > 0) {
        var edge_buf: [ecs.electric.max_wires * 24]u8 = undefined;
        var ew = wire_binary.Writer{ .buf = &edge_buf };
        var edges: u16 = 0;
        var wi: usize = 0;
        while (wi < self.sim.power.wire_n) : (wi += 1) {
            const wire = self.sim.power.wires[wi];
            const na = self.sim.power.indexOfId(wire.a) orelse continue;
            const nb = self.sim.power.indexOfId(wire.b) orelse continue;
            const pa = self.sim.power.nodes[na];
            const pb = self.sim.power.nodes[nb];
            try ew.writeI32(pa.x);
            try ew.writeI32(pa.y);
            try ew.writeI32(pa.z);
            try ew.writeI32(pb.x);
            try ew.writeI32(pb.y);
            try ew.writeI32(pb.z);
            edges += 1;
        }
        if (edges > 0) {
            try w.writeByte(3);
            try w.writeU16(edges);
            try w.writeBytes(ew.written());
            count += 1;
        }
    }
    const written = w.written();
    std.mem.writeInt(u16, written[4..6], count, .little);
    try io_fs.writeFile(p, written);
}

/// Restore vehicles/turrets from entities.zen. A missing file is a fresh
/// world (OpenFailed); a corrupt record fails the load loudly. Turrets
/// whose block was removed no longer resolve a power node and are skipped.
pub fn loadEntities(self: *Game) !void {
    var path: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/entities.zen", .{self.world.world_dir});
    const data = io_fs.readFileAll(self.allocator, p) catch |err| switch (err) {
        error.FileNotFound => return error.OpenFailed,
        else => return error.ReadFailed,
    };
    defer self.allocator.free(data);
    if (data.len < 6 or !std.mem.eql(u8, data[0..4], "ZENT")) return error.BadMagic;
    const count = std.mem.readInt(u16, data[4..6], .little);
    var r = wire_binary.Reader{ .data = data, .pos = 6 };
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const rec_type = r.readByte() catch return error.Truncated;
        switch (rec_type) {
            1 => {
                const kind: ecs.components.VehicleKind = @enumFromInt(r.readByte() catch return error.Truncated);
                const x = r.readF32() catch return error.Truncated;
                const y = r.readF32() catch return error.Truncated;
                const z = r.readF32() catch return error.Truncated;
                const yaw = r.readF32() catch return error.Truncated;
                const fuel = r.readF32() catch return error.Truncated;
                const seats = r.readByte() catch return error.Truncated;
                const max_speed = r.readF32() catch return error.Truncated;
                if (self.sim.spawnVehicleEx(kind, x, y, z, 200, max_speed, seats)) |nid| {
                    if (self.sim.slotOfNetId(nid)) |vs| {
                        self.sim.vehicle[vs].fuel = fuel;
                        self.sim.transform[vs].yaw = yaw;
                    }
                }
            },
            2 => {
                const x = r.readF32() catch return error.Truncated;
                const y = r.readF32() catch return error.Truncated;
                const z = r.readF32() catch return error.Truncated;
                const range = r.readF32() catch return error.Truncated;
                const damage = r.readF32() catch return error.Truncated;
                const ammo = r.readU16() catch return error.Truncated;
                if (self.sim.spawnTurret(x, y, z)) |nid| {
                    if (self.sim.slotOfNetId(nid)) |ts| {
                        self.sim.turret[ts].range = range;
                        self.sim.turret[ts].damage = damage;
                        self.sim.turret[ts].ammo = ammo;
                    }
                }
            },
            3 => {
                // Power wire edges by endpoint position; the nodes rebuild
                // from the block grid as chunks scan, so edges queue as
                // pending and reconnect when both endpoints exist.
                const edges = r.readU16() catch return error.Truncated;
                var ei: usize = 0;
                while (ei < edges) : (ei += 1) {
                    const wp = ecs.electric.WirePos{
                        .ax = r.readI32() catch return error.Truncated,
                        .ay = r.readI32() catch return error.Truncated,
                        .az = r.readI32() catch return error.Truncated,
                        .bx = r.readI32() catch return error.Truncated,
                        .by = r.readI32() catch return error.Truncated,
                        .bz = r.readI32() catch return error.Truncated,
                    };
                    self.sim.power.addPendingWire(wp);
                }
            },
            else => return error.BadRecord,
        }
    }
}

pub fn saveClaims(self: *Game) !void {
    var path: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/claims.zlc", .{self.world.world_dir});
    var buf: [max_land_claims * (4 + 4 + 4 + 1 + 32 + 4) + 8]u8 = undefined;
    var o: usize = 0;
    @memcpy(buf[0..4], "ZCLC");
    o = 6; // count patched below
    var count: u16 = 0;
    var i: usize = 0;
    while (i < self.land_claims_n) : (i += 1) {
        const c = &self.land_claims[i];
        if (o + 49 > buf.len) break;
        std.mem.writeInt(i32, buf[o..][0..4], c.x, .little);
        std.mem.writeInt(i32, buf[o + 4 ..][0..4], c.y, .little);
        std.mem.writeInt(i32, buf[o + 8 ..][0..4], c.z, .little);
        buf[o + 12] = c.owner_name_len;
        @memcpy(buf[o + 13 ..][0..32], &c.owner_name);
        std.mem.writeInt(u32, buf[o + 45 ..][0..4], c.owner_seen_day, .little);
        o += 49;
        count += 1;
    }
    std.mem.writeInt(u16, buf[4..6], count, .little);
    try io_fs.writeFile(p, buf[0..o]);
}

/// Restore land claims from claims.zlc. Restored claims have no live owner
/// until their player logs in (reclaimForName re-maps owner_entity); the
/// preserved seen_day keeps the offline expiry math honest. A missing file
/// means fresh world (OpenFailed, like containers.load); any other read
/// failure surfaces so the caller can log before the next save clobbers.
pub fn loadClaims(self: *Game) !void {
    var path: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/claims.zlc", .{self.world.world_dir});
    const data = io_fs.readFileAll(self.allocator, p) catch |err| switch (err) {
        error.FileNotFound => return error.OpenFailed,
        else => return error.ReadFailed,
    };
    defer self.allocator.free(data);
    if (data.len < 6 or !std.mem.eql(u8, data[0..4], "ZCLC")) return error.BadMagic;
    const count = std.mem.readInt(u16, data[4..6], .little);
    var o: usize = 6;
    var i: usize = 0;
    while (i < count and self.land_claims_n < max_land_claims) : (i += 1) {
        if (o + 49 > data.len) return error.Truncated;
        const x = std.mem.readInt(i32, data[o..][0..4], .little);
        const y = std.mem.readInt(i32, data[o + 4 ..][0..4], .little);
        const z = std.mem.readInt(i32, data[o + 8 ..][0..4], .little);
        const name_len = data[o + 12];
        if (name_len > 32) return error.BadRecord;
        var name: [32]u8 = .{0} ** 32;
        @memcpy(name[0..name_len], data[o + 13 ..][0..name_len]);
        const seen = std.mem.readInt(u32, data[o + 45 ..][0..4], .little);
        o += 49;
        self.land_claims[self.land_claims_n] = .{
            .x = x,
            .y = y,
            .z = z,
            .owner_entity = -1, // re-mapped on login
            .owner_online = false,
            .owner_seen_day = seen,
            .owner_name = name,
            .owner_name_len = name_len,
        };
        self.land_claims_n += 1;
    }
}

/// Trader stock persists across restart (traders.zst, magic "ZTR1"): stock
/// `TraderManager` saves its per-trader inventory, so a player's trading
/// window does not re-roll on reboot. Records are keyed by the trader's
/// `TraderStock.name`, entries by item **name** (AssignIds ids are
/// version-dependent), and unknown item names fail closed to a skipped entry.
/// Format: magic | version u8 | count u16 | per trader: name_len u8 + name,
/// reset_interval i32, last_restock_day u32, wallet i32, wallet_default i32,
/// n u8, n x (item_name_len u8 + name, count u16, quality u8, price u16,
/// sell u16, markup i8).
pub fn saveTraders(self: *Game) !void {
    var path: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/traders.zst", .{self.world.world_dir});
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    const B = struct {
        fn byte(a: std.mem.Allocator, b: *std.ArrayList(u8), v: u8) !void {
            try b.append(a, v);
        }
        fn u16v(a: std.mem.Allocator, b: *std.ArrayList(u8), v: u16) !void {
            var t: [2]u8 = undefined;
            std.mem.writeInt(u16, &t, v, .little);
            try b.appendSlice(a, &t);
        }
        fn i32v(a: std.mem.Allocator, b: *std.ArrayList(u8), v: i32) !void {
            var t: [4]u8 = undefined;
            std.mem.writeInt(i32, &t, v, .little);
            try b.appendSlice(a, &t);
        }
        fn u32v(a: std.mem.Allocator, b: *std.ArrayList(u8), v: u32) !void {
            var t: [4]u8 = undefined;
            std.mem.writeInt(u32, &t, v, .little);
            try b.appendSlice(a, &t);
        }
    };
    try buf.appendSlice(self.allocator, "ZTR1");
    try B.byte(self.allocator, &buf, 1); // version
    const count_pos = buf.items.len;
    try buf.appendNTimes(self.allocator, 0, 2);
    var count: u16 = 0;
    var i: usize = 0;
    while (i < ecs.max_entities) : (i += 1) {
        if (!self.sim.alive[i] or !self.sim.mask[i].trader_stock) continue;
        const st = &self.sim.trader_stock[i];
        if (st.name.len == 0 or st.name.len > 255) continue;
        try B.byte(self.allocator, &buf, @intCast(st.name.len));
        try buf.appendSlice(self.allocator, st.name);
        try B.i32v(self.allocator, &buf, st.reset_interval);
        try B.u32v(self.allocator, &buf, st.last_restock_day);
        try B.i32v(self.allocator, &buf, st.wallet);
        try B.i32v(self.allocator, &buf, st.wallet_default);
        const n: u8 = @intCast(@min(st.n, ecs.components.max_stock));
        try B.byte(self.allocator, &buf, n);
        var e: usize = 0;
        while (e < n) : (e += 1) {
            const item_name = if (self.items.byId(st.entries[e].item)) |d| d.name else "";
            if (item_name.len == 0 or item_name.len > 255) {
                // Fail closed: an unresolvable entry is dropped, never a stub.
                continue;
            }
            try B.byte(self.allocator, &buf, @intCast(item_name.len));
            try buf.appendSlice(self.allocator, item_name);
            try B.u16v(self.allocator, &buf, st.entries[e].count);
            try B.byte(self.allocator, &buf, st.entries[e].quality);
            try B.u16v(self.allocator, &buf, st.entries[e].price);
            try B.u16v(self.allocator, &buf, st.entries[e].sell);
            try B.byte(self.allocator, &buf, @bitCast(st.entries[e].markup));
        }
        count +|= 1;
    }
    std.mem.writeInt(u16, buf.items[count_pos..][0..2], count, .little);
    try io_fs.writeFile(p, buf.items);
}

/// Restore trader stock from traders.zst. Traders are matched by their stock
/// name (the spawn slot can shift across restarts); a trader with no saved
/// record keeps its fresh XML fill. A missing file means fresh world
/// (OpenFailed, like claims); any other read failure surfaces so the caller
/// can log before the next save clobbers. The clock is loaded separately, so
/// last_restock_day restores as stored; if a save predates a clock roll, the
/// restock window math (day -| last) degrades safely.
pub fn loadTraders(self: *Game) !void {
    var path: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/traders.zst", .{self.world.world_dir});
    const data = io_fs.readFileAll(self.allocator, p) catch |err| switch (err) {
        error.FileNotFound => return error.OpenFailed,
        else => return error.ReadFailed,
    };
    defer self.allocator.free(data);
    if (data.len < 7 or !std.mem.eql(u8, data[0..4], "ZTR1")) return error.BadMagic;
    if (data[4] != 1) return error.BadVersion;
    const count = std.mem.readInt(u16, data[5..7], .little);
    var o: usize = 7;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (o >= data.len) return error.Truncated;
        const name_len = data[o];
        o += 1;
        if (o + name_len > data.len) return error.Truncated;
        const name = data[o .. o + name_len];
        o += name_len;
        if (o + 17 > data.len) return error.Truncated;
        const reset_interval = std.mem.readInt(i32, data[o..][0..4], .little);
        const last_restock_day = std.mem.readInt(u32, data[o + 4 ..][0..4], .little);
        const wallet = std.mem.readInt(i32, data[o + 8 ..][0..4], .little);
        const wallet_default = std.mem.readInt(i32, data[o + 12 ..][0..4], .little);
        const n = data[o + 16];
        o += 17;
        if (n > ecs.components.max_stock) return error.BadRecord;
        // Find the live trader by stock name; a trader missing from this world
        // (map changed) is skipped, its record harmless.
        var ts: ?ecs.Slot = null;
        var s: usize = 0;
        while (s < ecs.max_entities) : (s += 1) {
            if (self.sim.alive[s] and self.sim.mask[s].trader_stock and
                std.mem.eql(u8, self.sim.trader_stock[s].name, name))
            {
                ts = @intCast(s);
                break;
            }
        }
        const t = ts orelse continue;
        self.sim.trader_stock[t].reset_interval = reset_interval;
        self.sim.trader_stock[t].last_restock_day = last_restock_day;
        self.sim.trader_stock[t].wallet = wallet;
        self.sim.trader_stock[t].wallet_default = wallet_default;
        var restored: usize = 0;
        var e: usize = 0;
        while (e < n) : (e += 1) {
            if (o >= data.len) return error.Truncated;
            const ilen = data[o];
            o += 1;
            if (o + ilen > data.len) return error.Truncated;
            const iname = data[o .. o + ilen];
            o += ilen;
            if (o + 8 > data.len) return error.Truncated;
            const count_v = std.mem.readInt(u16, data[o..][0..2], .little);
            const quality = data[o + 2];
            const price = std.mem.readInt(u16, data[o + 3 ..][0..2], .little);
            const sell = std.mem.readInt(u16, data[o + 5 ..][0..2], .little);
            const markup = @as(i8, @bitCast(data[o + 7]));
            o += 8;
            const iid = self.items.ecsIdByName(iname);
            if (iid == 0) continue; // unknown item (version drift) -> skipped
            if (restored >= ecs.components.max_stock) break;
            self.sim.trader_stock[t].entries[restored] = .{
                .item = iid,
                .count = count_v,
                .quality = quality,
                .price = price,
                .sell = sell,
                .markup = markup,
            };
            restored += 1;
        }
        self.sim.trader_stock[t].n = restored;
    }
}

pub fn zpv2DropName(allocator: std.mem.Allocator, data: []const u8, name: []const u8) !Zpv2Drop {
    if (name.len == 0 or name.len > 32) return .{};
    if (data.len < 8 or !std.mem.eql(u8, data[0..3], "ZPV") or
        (data[3] != '2' and data[3] != '3' and data[3] != '4' and data[3] != '5' and data[3] != '6' and data[3] != '7' and data[3] != '8'))
        return error.CorruptPlayersFile;
    const version: u8 = data[3] - '0';
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
