//! Player persistence: save-all and restore-one paths.
//!
//! Split out of server/persist.zig (same code, moved verbatim).

const std = @import("std");
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
const persist = @import("persist.zig");
const logPersistErr = persist.logPersistErr;
const zpvVersionFromMagic = persist.zpvVersionFromMagic;
const zpvMagicByte = persist.zpvMagicByte;
const zpvSlotStride = persist.zpvSlotStride;
const persist_version = persist.persist_version;
const ZpvIdentity = persist.ZpvIdentity;
const zpvIdentityFrom = persist.zpvIdentityFrom;
const emitZpv12SlotsFrom = persist.emitZpv12SlotsFrom;
const emitZpv12Slots = persist.emitZpv12Slots;
const emitZpv9Tail = persist.emitZpv9Tail;
const emitZpv11Skills = persist.emitZpv11Skills;
const emitZpv13Backpacks = persist.emitZpv13Backpacks;
const emitZpv14Stats = persist.emitZpv14Stats;
const emitZpv15Identity = persist.emitZpv15Identity;
const zpvRecordHasProgTail = persist.zpvRecordHasProgTail;
const zpvRecordSpan = persist.zpvRecordSpan;
const zpvRecordLen = persist.zpvRecordLen;
const RecordSpan = persist.RecordSpan;
const zpv_stats_tail_len = persist.zpv_stats_tail_len;
const tailStartOf = persist.tailStartOf;
const max_quest_name_len = persist.max_quest_name_len;

/// Record layout (v5+): magic ZPVN | n:u32 | records…
/// each: name_len:u8 | name | x,y,z:f32 | coins:u32 |
///   inv_n:u8 | inv_n×(item:u16, count:u16, quality:u8, meta:u16[, use_times:f32 from v7]) |
///   jn:u8 | jn×(def_id:u16, quest_code:i32, flags:u8, progress:u16, phase:u8,
///     name_len:u8, name, poi_valid:u8, poi rect:f32×6)
///   prog:u8 (1 = present) | level:u16 | xp:u64 | food/max/water/max:f32×4 |
///   hp:f32 (v8+) | born_world_time:u64 (v9+) |
///   buff_n:u8 | buff_n×(def_id:u16, stack:u8, flags:u8, dur_ticks:u32,
///   upd_ticks:u16, upd_rate:i32, dur_max:f32, remove_on_death:u8) |
///   bed_present:u8 (1 = present) | bed_present×(bed_x,bed_y,bed_z:i32) |
///   (v11+) skill_points:u32 | skill_n:u8 | skill_n×(name_len:u8, name, level:u8)
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
    var old_version: u8 = 9;
    if (io_fs.readFileAll(self.allocator, path)) |old_data| {
        old_file = old_data;
        if (old_data.len < 8 or !std.mem.eql(u8, old_data[0..3], "ZPV"))
            return error.CorruptPlayersFile;
        old_version = zpvVersionFromMagic(old_data[3]) orelse return error.CorruptPlayersFile;
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
    try out.appendSlice(self.allocator, &[_]u8{ 'Z', 'P', 'V', zpvMagicByte(persist_version), 0, 0, 0, 0 });
    var written: u32 = 0;
    {
        var ri: u32 = 0;
        var off: usize = 0;
        while (ri < old_count) : (ri += 1) {
            const rec_start = off;
            const rec_span = zpvRecordSpan(old_recs, off, old_version) catch return error.CorruptPlayersFile;
            const rec_len = rec_span.len;
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
            var rec_ident: ZpvIdentity = .{};
            if (rec_span.identity_off != 0) {
                // Identity of the carried record, so a rename (or a different
                // name claiming the same account) still merges into one row.
                zpvIdentityFrom(old_recs, rec_span.identity_off, &rec_ident);
            }
            for (&self.clients) |*cl| {
                if (!cl.joined or cl.entity_id <= 0 or cl.name_len == 0) continue;
                const name_matches = cl.name_len == nl and std.mem.eql(u8, cl.name[0..nl], rec_name);
                if (!rec_ident.matchesClient(cl, name_matches)) continue;
                if (self.sim.playerByPeer(cl.slot) == null) continue;
                rewritten = true;
                break;
            }
            if (rewritten) continue;
            if (old_version >= 12) {
                const inv_pos = rec_start + 1 + nl + 16;
                const inv_n = old_recs[inv_pos];
                const src_stride = zpvSlotStride(old_version);
                const slots_end = inv_pos + 1 + inv_n * src_stride;
                try out.appendSlice(self.allocator, old_recs[rec_start..inv_pos]);
                try emitZpv12SlotsFrom(&out, self.allocator, old_recs, inv_pos, inv_n, src_stride);
                try out.appendSlice(self.allocator, old_recs[slots_end..off]);
                if (had_prog_tail and old_version < 13) try emitZpv13Backpacks(&out, self.allocator, null);
                if (had_prog_tail and old_version < 14) {
                    try emitZpv14Stats(&out, self.allocator, null);
                }
                // The carried bytes are v12+ shaped, so a v15 file already
                // holds its identity section; only older records need one.
                if (old_version < 15) try emitZpv15Identity(&out, self.allocator, null);
                written += 1;
                continue;
            }
            if (old_version >= 10) {
                // v10/v11 differ from v12 only in the slot stride (13 vs 21:
                // v12 appends four mod ids) and, for v10, the missing skill
                // tail. The header is rewritten to ZPVC either way, so a
                // verbatim carry would leave 13-byte slots in a file the
                // reader walks with a 21-byte stride - every later field in
                // the record reads from the wrong offset and the next load
                // fails as CorruptPlayersFile. Widen the slots instead.
                const inv_pos: usize = rec_start + 1 + nl + 16;
                const inv_n: usize = old_recs[inv_pos];
                const slots_end = inv_pos + 1 + inv_n * 13;
                try out.appendSlice(self.allocator, old_recs[rec_start..inv_pos]);
                try emitZpv12Slots(&out, self.allocator, old_recs, inv_pos, inv_n);
                try out.appendSlice(self.allocator, old_recs[slots_end..off]);
                if (old_version == 10 and had_prog_tail) try emitZpv11Skills(&out, self.allocator, null);
                if (had_prog_tail) try emitZpv13Backpacks(&out, self.allocator, null);
                if (had_prog_tail) try emitZpv14Stats(&out, self.allocator, null);
                try emitZpv15Identity(&out, self.allocator, null);
                written += 1;
                continue;
            }
            if (old_version == 9) {
                // v9 records need only the slot widen 11 -> 13 (seed).
                const inv_pos: usize = rec_start + 1 + nl + 16;
                const inv_n: usize = old_recs[inv_pos];
                const slots_end = inv_pos + 1 + inv_n * 11;
                try out.appendSlice(self.allocator, old_recs[rec_start..inv_pos]);
                try emitZpv12SlotsFrom(&out, self.allocator, old_recs, inv_pos, inv_n, 11);
                try out.appendSlice(self.allocator, old_recs[slots_end..off]);
                if (had_prog_tail) try emitZpv11Skills(&out, self.allocator, null);
                if (had_prog_tail) try emitZpv13Backpacks(&out, self.allocator, null);
                if (had_prog_tail) try emitZpv14Stats(&out, self.allocator, null);
                written += 1;
                continue;
            }
            if (old_version == 8) {
                // v8 records are v9-shaped except the tail born_world_time:
                // insert a zero (the pre-ZPV9 behavior for carried records).
                const tail_start = tailStartOf(old_recs, rec_start, nl, 8) catch return error.CorruptPlayersFile;
                const inv_pos: usize = rec_start + 1 + nl + 16;
                const inv_n: usize = old_recs[inv_pos];
                const slots_end = inv_pos + 1 + inv_n * 11;
                try out.appendSlice(self.allocator, old_recs[rec_start..inv_pos]);
                try emitZpv12SlotsFrom(&out, self.allocator, old_recs, inv_pos, inv_n, 11);
                try out.appendSlice(self.allocator, old_recs[slots_end..tail_start]);
                try emitZpv9Tail(&out, self.allocator, old_recs, tail_start, off, 8);
                if (had_prog_tail) try emitZpv11Skills(&out, self.allocator, null);
                if (had_prog_tail) try emitZpv13Backpacks(&out, self.allocator, null);
                if (had_prog_tail) try emitZpv14Stats(&out, self.allocator, null);
                written += 1;
                continue;
            }
            if (old_version == 7) {
                // v7 records need the slot widen (7 -> 13, appending zero
                // use_times + seed) AND the tail hp + born fields: split at
                // the slot block, widen, carry the journal verbatim, emit the
                // tail.
                const inv_pos: usize = rec_start + 1 + nl + 16;
                const inv_n: usize = old_recs[inv_pos];
                const slots_end = inv_pos + 1 + inv_n * 11;
                const tail_start = tailStartOf(old_recs, rec_start, nl, 7) catch return error.CorruptPlayersFile;
                try out.appendSlice(self.allocator, old_recs[rec_start..inv_pos]);
                try emitZpv12SlotsFrom(&out, self.allocator, old_recs, inv_pos, inv_n, 11);
                try out.appendSlice(self.allocator, old_recs[slots_end..tail_start]);
                try emitZpv9Tail(&out, self.allocator, old_recs, tail_start, off, 7);
                if (had_prog_tail) try emitZpv11Skills(&out, self.allocator, null);
                if (had_prog_tail) try emitZpv13Backpacks(&out, self.allocator, null);
                if (had_prog_tail) try emitZpv14Stats(&out, self.allocator, null);
                written += 1;
                continue;
            }
            if (old_version == 6) {
                // v6 records need the slot widen, the journal kept verbatim,
                // and the tail hp + born fields.
                const inv_pos: usize = rec_start + 1 + nl + 16;
                const inv_n: usize = old_recs[inv_pos];
                const slots_end = inv_pos + 1 + inv_n * 7;
                const tail_start = tailStartOf(old_recs, rec_start, nl, 6) catch return error.CorruptPlayersFile;
                try out.appendSlice(self.allocator, old_recs[rec_start..inv_pos]);
                try emitZpv12SlotsFrom(&out, self.allocator, old_recs, inv_pos, inv_n, 7);
                try out.appendSlice(self.allocator, old_recs[slots_end..tail_start]);
                try emitZpv9Tail(&out, self.allocator, old_recs, tail_start, off, 6);
                if (had_prog_tail) try emitZpv11Skills(&out, self.allocator, null);
                if (had_prog_tail) try emitZpv13Backpacks(&out, self.allocator, null);
                if (had_prog_tail) try emitZpv14Stats(&out, self.allocator, null);
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
            try emitZpv12SlotsFrom(&out, self.allocator, old_recs, inv_pos, inv_n, 7);
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
            try emitZpv9Tail(&out, self.allocator, old_recs, qp, off, old_version);
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
            if (had_prog_tail) try emitZpv11Skills(&out, self.allocator, null);
            if (had_prog_tail) try emitZpv13Backpacks(&out, self.allocator, null);
            if (had_prog_tail) try emitZpv14Stats(&out, self.allocator, null);
            written += 1;
        }
    }
    for (&self.clients) |*cl| {
        if (!cl.joined or cl.entity_id <= 0 or cl.name_len == 0) continue;
        const ps = self.sim.playerByPeer(cl.slot) orelse continue;
        const head_bytes = 1 + 32 + 3 * 4 + 4 + 1;
        const inv_bytes = comptime ecs.components.max_inv_slots * zpvSlotStride(persist_version);
        const quest_bytes = 10 + 1 + max_quest_name_len + 25 + 1 + ecs.quest.max_quest_objectives * 2;
        const journal_bytes = 1 + ecs.components.max_journal * quest_bytes;
        const progression_bytes = 1 + 2 + 8 + 16 + 4 + 8 + 1;
        const buff_bytes = ecs.components.max_buffs_per_entity * 19;
        const bed_bytes = 1 + 12;
        const rec_capacity = head_bytes + inv_bytes + journal_bytes + progression_bytes + buff_bytes + bed_bytes;
        var rec: [rec_capacity]u8 = undefined;
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
            // The write below emits a full v12 slot, so the room it needs is
            // the v12 stride. Reading it off `zpvSlotStride` keeps the bound
            // and the layout on one number: the previous literal 13 was the
            // v10 stride left behind when v12 appended the mod ids, so the
            // guard admitted a slot with room for the head and none for the
            // tail.
            const slot_bytes = zpvSlotStride(persist_version);
            for (self.sim.inventory[ps].slots) |s| {
                // Shared InvSlot persist shape (ZPV17): see InvSlot.writePersist.
                if (o + slot_bytes > rec.len) return error.PlayerRecordTooLarge;
                s.writePersist(rec[o..][0..slot_bytes]);
                o += slot_bytes;
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
                if (qname.len > max_quest_name_len) return error.QuestNameTooLong;
                if (o + 10 + 1 + qname.len + 25 + 1 + obj_n * 2 > rec.len) return error.PlayerRecordTooLarge;
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
        var tail_has_prog = false;
        if (o + progression_bytes + buff_bytes + bed_bytes <= rec.len) {
            tail_has_prog = true;
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
            // ZPV9: game-stage born world time, so days-alive (and the
            // gamestage) survives a server restart instead of snapping to
            // the level cap.
            if (o + 8 <= rec.len) {
                std.mem.writeInt(u64, rec[o..][0..8], cl.game_stage_born_world_time, .little);
                o += 8;
            }
            const buff_n_pos = o;
            rec[o] = 0;
            o += 1;
            var buff_n: u8 = 0;
            if (self.sim.mask[ps].buffs) {
                for (self.sim.buffs[ps].slots) |b| {
                    if (!b.active) continue;
                    if (o + 19 > rec.len) return error.PlayerRecordTooLarge;
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
            return error.PlayerRecordTooLarge;
        }
        try out.appendSlice(self.allocator, rec[0..o]);
        // ZPV11 skill tail rides the progression tail: appended after the
        // record bytes, only when prog == 1 (zpvRecordLen walks it the same
        // way). Appending before the record would misalign the next record.
        if (tail_has_prog) try emitZpv11Skills(&out, self.allocator, cl);
        if (tail_has_prog) try emitZpv13Backpacks(&out, self.allocator, cl);
        if (tail_has_prog) try emitZpv14Stats(&out, self.allocator, cl);
        if (tail_has_prog) try emitZpv15Identity(&out, self.allocator, cl);
        // Identity-keyed row with no identity to key on: the row falls back to
        // the login name, so another client can still claim it (ADR 0038). A
        // real client always presents one; the bots do not, which is why this
        // is a counted notice rather than a write refusal.
        if (tail_has_prog and cl.puid_primary.get() == null and self.harness.counters.get(.identity_less_saves) == 0) {
            self.harness.counters.inc(.identity_less_saves);
            std.debug.print(
                "zdtd: player save has no platform identity; row stays name-keyed (ADR 0038)\n",
                .{},
            );
        }
        written += 1;
    }
    std.mem.writeInt(u32, out.items[4..][0..4], written, .little);
    try io_fs.writeFile(path, out.items);
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
    if (data.len < 8 or data[0] != 'Z' or data[1] != 'P' or data[2] != 'V') {
        std.debug.print("zdtd: restore player: bad players file header\n", .{});
        return;
    }
    const version = zpvVersionFromMagic(data[3]) orelse {
        std.debug.print("zdtd: restore player: bad players file header\n", .{});
        return;
    };
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
        // v15 identity, parsed from the record's own tail offset rather than
        // the read cursor: the matcher below has to decide before the body is
        // walked, and the tail layout does not depend on the cursor.
        var rec_ident: ZpvIdentity = .{};
        if (version >= 15) {
            // The body walk below re-walks the same record for its fields; the
            // length walk already validated it, so a failure here is the same
            // corrupt tail the caller reports.
            const sp = zpvRecordSpan(data, rec_start, version) catch RecordSpan{ .len = 0 };
            if (sp.identity_off != 0) zpvIdentityFrom(data, sp.identity_off, &rec_ident);
        }
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
            // `inv_n` is a u8 off disk, so a record claiming more slots than
            // the array holds must keep consuming bytes without writing.
            if (k < inv.len) inv[k] = ecs.components.InvSlot.readPersist(ib);
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
        // Identity wins over the name: a record that carries one belongs to
        // that account, so a different player typing the same display name
        // cannot load it (the stock PrimaryId.CombinedString key). A legacy
        // record with no identity is still matched by name so it can be
        // upgraded in place on the next save.
        const name_match = c.name_len == nl and std.mem.eql(u8, c.name[0..nl], name_slice);
        if (!rec_ident.matchesClient(c, name_match)) {
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
            // Bring saved stacks down to the current items.xml cap, but only
            // for items the catalog resolves. The file is server-written and
            // was legal when saved; the cap can still move under it when a
            // Stacknumber is lowered or the world is loaded against a
            // different game-dir, and nothing else would ever correct that.
            //
            // Deliberately not clampInventoryStacks: that path uses
            // itemStackFor, which fails closed to 1 for an id it cannot
            // resolve. Failing closed is right against a client claim and
            // destructive here, where an unresolved id (game-dir absent, mod
            // removed) would silently crush a legitimate stack to 1 on every
            // load. An unknown id keeps whatever the save recorded.
            for (&self.sim.inventory[ps].slots) |*s| {
                if (s.count == 0 or s.item_id == 0) continue;
                if (self.items.byId(s.item_id) == null) continue;
                // The sandbox MaxStackSize multiplier belongs in the cap: the
                // raw Stacknumber would crush a legitimately scaled stack.
                s.count = @min(s.count, self.items.stackFor(s.item_id));
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
                // QuestPrefab from the position data it persisted - old zdtd
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
                // ZPV9: game-stage born world time (days-alive persists).
                if (version >= 9 and off + 8 <= data.len) {
                    c.game_stage_born_world_time = std.mem.readInt(u64, data[off..][0..8], .little);
                    off += 8;
                } else if (version >= 9) {
                    off += 8;
                }
                if (off < data.len) {
                    const buff_n: usize = data[off];
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
                // ZPV11 skill tail: purchased attribute/perk levels restore so
                // the spend ledger and the level-scaled VM effects survive.
                // Names resolve against the progression catalog (arena
                // lifetime); a name the catalog no longer carries is dropped
                // fail-closed (a mod removed the perk).
                if (version >= 11 and off + 5 <= data.len) {
                    c.skill_points = std.mem.readInt(u32, data[off..][0..4], .little);
                    off += 4;
                    const skill_n: usize = data[off];
                    off += 1;
                    var si: usize = 0;
                    while (si < skill_n and c.skill_level_n < c.skill_levels.len) : (si += 1) {
                        if (off >= data.len) break;
                        const snl: usize = data[off];
                        off += 1;
                        if (snl == 0 or snl > 63 or off + snl + 1 > data.len) break;
                        const sname = data[off..][0..snl];
                        off += snl;
                        const slevel = data[off];
                        off += 1;
                        var resolved: ?[]const u8 = null;
                        for (self.progression_table.attributes) |a| {
                            if (std.mem.eql(u8, a.name, sname)) {
                                resolved = a.name;
                                break;
                            }
                        }
                        if (resolved == null) {
                            for (self.progression_table.perks) |pk| {
                                if (std.mem.eql(u8, pk.name, sname)) {
                                    resolved = pk.name;
                                    break;
                                }
                            }
                        }
                        if (resolved == null) {
                            for (self.progression_table.crafting_skills) |sk| {
                                if (std.mem.eql(u8, sk.name, sname)) {
                                    resolved = sk.name;
                                    break;
                                }
                            }
                        }
                        const rname = resolved orelse continue;
                        c.skill_levels[c.skill_level_n] = .{ .name = rname, .level = slevel };
                        c.skill_level_n += 1;
                    }
                }
            }
            if (version >= 13) {
                if (off < data.len) {
                    const bp_n: usize = data[off];
                    off += 1;
                    var bi: usize = 0;
                    while (bi < bp_n and off + 12 <= data.len) : (bi += 1) {
                        const bx = std.mem.readInt(i32, data[off..][0..4], .little);
                        const by = std.mem.readInt(i32, data[off + 4 ..][0..4], .little);
                        const bz = std.mem.readInt(i32, data[off + 8 ..][0..4], .little);
                        off += 12;
                        // addBackpack caps and evicts, so a file claiming more
                        // markers than the cap cannot overrun the array.
                        c.addBackpack(bx, by, bz);
                    }
                }
            }
            // ZPV14 stats tail: the character-sheet counters stock keeps in
            // PlayerDataFile. Restored before the join bundle so the PlayerId
            // PDF (and the PlayerStats push) carry the surviving totals.
            if (version >= 14 and off + zpv_stats_tail_len <= data.len) {
                c.deaths = std.mem.readInt(i32, data[off..][0..4], .little);
                c.zombie_kills = @intCast(@min(
                    std.mem.readInt(u32, data[off + 4 ..][0..4], .little),
                    std.math.maxInt(u16),
                ));
                c.player_kills = @intCast(@min(
                    std.mem.readInt(u32, data[off + 8 ..][0..4], .little),
                    std.math.maxInt(u16),
                ));
                off += zpv_stats_tail_len;
            }
        }
        return;
    }
}
