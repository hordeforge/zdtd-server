//! Save/restore for zdtd-owned persistence: players.zsv (ZPV4), entities.zen
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
/// field), or 4 (ZPV4, tail's buff list followed unconditionally by a
/// bedroll presence byte). The bedroll field is **not** detected by "more
/// bytes remain in the file": that is ambiguous whenever another record
/// follows this one, since the next record's own name_len byte would be
/// misread as this record's bed_present. Only the file's own magic decides
/// whether a bedroll field is present, the same way `prog` already gates the
/// rest of the v3 tail.
pub fn zpvRecordLen(data: []const u8, off: usize, version: u8) error{CorruptPlayersFile}!usize {
    if (off >= data.len) return error.CorruptPlayersFile;
    const nl: usize = data[off];
    if (nl > 32 or off + 1 + nl + 16 + 1 > data.len) return error.CorruptPlayersFile;
    var p = off + 1 + nl + 16;
    const inv_n: usize = data[p];
    p += 1 + inv_n * 7;
    if (p >= data.len) return error.CorruptPlayersFile;
    const jn: usize = data[p];
    p += 1 + jn * 10;
    if (p > data.len) return error.CorruptPlayersFile;
    if (version >= 3) {
        if (p >= data.len) return error.CorruptPlayersFile;
        const prog = data[p];
        p += 1;
        if (prog == 1) {
            if (p + 2 + 8 + 16 + 1 > data.len) return error.CorruptPlayersFile;
            p += 2 + 8 + 16;
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

/// True when `zpvRecordLen` would find `prog == 1` for this record, i.e. it
/// has a progression tail (and therefore needs a bed_present byte appended to
/// become v4-shaped). Callers must have already validated the record with
/// `zpvRecordLen`, so no bound is re-checked here.
fn zpvRecordHasProgTail(data: []const u8, off: usize, version: u8) bool {
    if (version < 3) return false;
    const nl: usize = data[off];
    var p = off + 1 + nl + 16;
    const inv_n: usize = data[p];
    p += 1 + inv_n * 7;
    const jn: usize = data[p];
    p += 1 + jn * 10;
    return data[p] == 1;
}

pub fn playersPath(self: *const Game, buf: []u8) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{s}/players.zsv", .{self.world.world_dir});
}

/// Record layout (v4): magic ZPV4 | n:u32 | records…
/// each: name_len:u8 | name | x,y,z:f32 | coins:u32 |
///   inv_n:u8 | inv_n×(item:u16, count:u16, quality:u8, meta:u16) |
///   jn:u8 | jn×(def_id:u16, quest_code:i32, flags:u8, progress:u16, phase:u8)
///   prog:u8 (1 = present) | level:u16 | xp:u64 | food/max/water/max:f32×4 |
///   buff_n:u8 | buff_n×(def_id:u16, stack:u8, flags:u8, dur_ticks:u32,
///   upd_ticks:u16, upd_rate:i32, dur_max:f32, remove_on_death:u8) |
///   bed_present:u8 (1 = present) | bed_present×(bed_x,bed_y,bed_z:i32)
/// bed_present is v4-only; it is not written or read at all under an older
/// magic, since "more bytes remain in the file" cannot distinguish "one more
/// field of this record" from "the next record has begun" (zpvRecordLen).
/// ZPV2 (no progression tail) and ZPV3 (tail, no bedroll) files are still
/// read and upgrade in place on the next save. Merge-write: offline players'
/// existing records are carried over, not erased.
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
    var old_version: u8 = 4;
    if (io_fs.readFileAll(self.allocator, path)) |old_data| {
        old_file = old_data;
        if (old_data.len < 8 or !std.mem.eql(u8, old_data[0..3], "ZPV") or
            (old_data[3] != '2' and old_data[3] != '3' and old_data[3] != '4'))
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
    try out.appendSlice(self.allocator, &[_]u8{ 'Z', 'P', 'V', '4', 0, 0, 0, 0 });
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
            var online = false;
            for (&self.clients) |*cl| {
                if (cl.joined and cl.name_len == nl and std.mem.eql(u8, cl.name[0..nl], rec_name)) {
                    online = true;
                    break;
                }
            }
            if (online) continue;
            try out.appendSlice(self.allocator, old_recs[rec_start..off]);
            // Upgrade a legacy record to the current v4 layout so the file
            // stays uniformly parseable under v4 semantics on the next pass:
            // v2 -> v3 needs an empty prog byte (0, no tail at all); v3 (or an
            // upgraded v2) needs a bed_present byte (0) appended only when it
            // actually has a progression tail, since a tail-less record has
            // nowhere for a bedroll field to attach.
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
        var rec: [768]u8 = undefined;
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
                if (o + 7 > rec.len) break;
                std.mem.writeInt(u16, rec[o..][0..2], s.item_id, .little);
                std.mem.writeInt(u16, rec[o + 2 ..][0..2], s.count, .little);
                rec[o + 4] = s.quality;
                std.mem.writeInt(u16, rec[o + 5 ..][0..2], s.meta, .little);
                o += 7;
                inv_n += 1;
            }
        }
        rec[inv_start] = inv_n;
        const j_start = o;
        o += 1;
        var jn: u8 = 0;
        if (self.sim.mask[ps].journal) {
            for (self.sim.journal[ps].slots) |q| {
                if (!q.active and !q.completed) continue;
                if (o + 10 > rec.len) break;
                std.mem.writeInt(u16, rec[o..][0..2], q.def_id, .little);
                std.mem.writeInt(i32, rec[o + 2 ..][0..4], q.quest_code, .little);
                rec[o + 6] = (@as(u8, @intFromBool(q.active))) | (@as(u8, @intFromBool(q.completed)) << 1) | (@as(u8, @intFromBool(q.ready_turn_in)) << 2) | (@as(u8, @intFromBool(q.rally_activated)) << 3);
                std.mem.writeInt(u16, rec[o + 7 ..][0..2], q.progress, .little);
                rec[o + 9] = q.phase;
                o += 10;
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
        (data[3] != '2' and data[3] != '3' and data[3] != '4'))
    {
        std.debug.print("zdtd: restore player: bad players file header\n", .{});
        return;
    }
    const version: u8 = data[3] - '0';
    const v3 = version >= 3;
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
        if (off + inv_n * 7 + 1 > data.len) {
            std.debug.print("zdtd: restore player: truncated inventory at record {d}/{d}\n", .{ i, n });
            return;
        }
        var inv: [ecs.components.max_inv_slots]ecs.components.InvSlot = undefined;
        var k: usize = 0;
        while (k < inv_n) : (k += 1) {
            const ib = data[off..][0..7];
            off += 7;
            if (k < inv.len) inv[k] = .{
                .item_id = std.mem.readInt(u16, ib[0..2], .little),
                .count = std.mem.readInt(u16, ib[2..4], .little),
                .quality = ib[4],
                .meta = std.mem.readInt(u16, ib[5..7], .little),
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
                .rally_activated = (qb[6] & 8) != 0,
            };
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
                // The POI rect is derived from the world, not persisted:
                // re-resolve it so a restored quest keeps its rally rect.
                // Defs without a static position re-bind the nearest POI
                // (audit B26), matching what questAccept did at hand-out.
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
                if (version == 4 and off < data.len) {
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
    var buf: [ecs.max_entities * 32 + 8]u8 = undefined;
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

pub fn zpv2DropName(allocator: std.mem.Allocator, data: []const u8, name: []const u8) !Zpv2Drop {
    if (name.len == 0 or name.len > 32) return .{};
    if (data.len < 8 or !std.mem.eql(u8, data[0..3], "ZPV") or
        (data[3] != '2' and data[3] != '3' and data[3] != '4'))
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
