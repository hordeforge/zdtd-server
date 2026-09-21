//! Trader persistence: traders.zst save/restore plus the pure
//! blob scanner (fuzzable without a Game).
//!
//! Split out of server/persist.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("game.zig");
const Game = game_mod.Game;
const io_fs = @import("../util/io_fs.zig");
const ecs = @import("../ecs/root.zig");

/// Walk a traders.zst blob and return the offset one past the last record,
/// without touching sim state. `loadTraders` does the same walk inline and then
/// applies each record; keeping a pure copy makes the cursor arithmetic - the
/// part that desynced when a skipped record failed to consume its entries -
/// fuzzable without standing up a whole Game.
///
/// A record whose trader is absent from the world is still fully consumed, so a
/// blob that parses here parses identically in the loader.
pub fn ztrScanLen(data: []const u8) error{ BadMagic, BadVersion, Truncated, BadRecord }!usize {
    if (data.len < 7 or !std.mem.eql(u8, data[0..4], "ZTR1")) return error.BadMagic;
    if (data[4] != 1 and data[4] != 2) return error.BadVersion;
    const v2 = data[4] == 2;
    const count = std.mem.readInt(u16, data[5..7], .little);
    var o: usize = 7;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (o >= data.len) return error.Truncated;
        const name_len = data[o];
        o += 1;
        if (o + name_len > data.len) return error.Truncated;
        o += name_len;
        if (o + 17 > data.len) return error.Truncated;
        const n = data[o + 16];
        o += 17;
        if (n > ecs.components.max_stock) return error.BadRecord;
        var e: usize = 0;
        while (e < n) : (e += 1) {
            if (o >= data.len) return error.Truncated;
            const ilen = data[o];
            o += 1;
            if (o + ilen > data.len) return error.Truncated;
            o += ilen;
            if (o + 8 > data.len) return error.Truncated;
            o += 8;
            if (v2) {
                if (o >= data.len) return error.Truncated;
                const sn = data[o];
                o += 1;
                if (sn > ecs.components.max_item_stats) return error.BadRecord;
                if (o + @as(usize, sn) * 5 > data.len) return error.Truncated;
                o += @as(usize, sn) * 5;
            }
        }
    }
    return o;
}

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
    try B.byte(self.allocator, &buf, 2); // version (v2: stat blob per entry)
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
        // The count byte must equal the number of entries actually written:
        // the reader walks exactly that many, so writing a header of `n` and
        // then dropping an unresolvable entry would leave it reading the next
        // record's bytes as this record's tail. Count the writable ones first.
        var writable: u8 = 0;
        {
            var c: usize = 0;
            while (c < n) : (c += 1) {
                const nm = if (self.items.byId(st.entries[c].item)) |d| d.name else "";
                if (nm.len == 0 or nm.len > 255) continue;
                writable += 1;
            }
        }
        try B.byte(self.allocator, &buf, writable);
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
            // v2 stat blob: the rolled ItemValue stats survive a restart.
            const sn: u8 = @intCast(@min(st.entries[e].stats_n, ecs.components.max_item_stats));
            try B.byte(self.allocator, &buf, sn);
            var si: usize = 0;
            while (si < sn) : (si += 1) {
                const stt = st.entries[e].stats[si];
                try B.byte(self.allocator, &buf, stt.effect);
                try B.u16v(self.allocator, &buf, @bitCast(stt.slot_a));
                try B.u16v(self.allocator, &buf, @bitCast(stt.slot_b));
            }
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
    _ = try ztrScanLen(data);
    const v2 = data[4] == 2;
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
        // A trader missing from this world (map changed) is skipped, but its
        // record still has to be consumed: `o` sits at the first stock entry
        // here, so returning to the outer loop without walking the entries
        // would parse the next record from the middle of this one (an item
        // name length read as a trader name length, and so on).
        if (ts) |t| {
            self.sim.trader_stock[t].reset_interval = reset_interval;
            self.sim.trader_stock[t].last_restock_day = last_restock_day;
            self.sim.trader_stock[t].wallet = wallet;
            self.sim.trader_stock[t].wallet_default = wallet_default;
        }
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
            // v2 stat blob; v1 records end here and restore as no stats.
            var stats: [ecs.components.max_item_stats]ecs.components.ItemStat = .{ecs.components.ItemStat{}} ** ecs.components.max_item_stats;
            var stats_n: u8 = 0;
            if (v2) {
                if (o >= data.len) return error.Truncated;
                const sn = data[o];
                o += 1;
                if (sn > ecs.components.max_item_stats) return error.BadRecord;
                if (o + @as(usize, sn) * 5 > data.len) return error.Truncated;
                var si: usize = 0;
                while (si < sn) : (si += 1) {
                    stats[si] = .{
                        .effect = data[o],
                        .slot_a = @bitCast(std.mem.readInt(u16, data[o + 1 ..][0..2], .little)),
                        .slot_b = @bitCast(std.mem.readInt(u16, data[o + 3 ..][0..2], .little)),
                    };
                    o += 5;
                }
                stats_n = sn;
            }
            const t = ts orelse continue; // no live trader: entry consumed, dropped
            const iid = self.items.ecsIdByName(iname);
            if (iid == 0) continue; // unknown item (version drift) -> skipped
            // Full: keep consuming the remaining entries so `o` still lands on
            // the next record boundary.
            if (restored >= ecs.components.max_stock) continue;
            self.sim.trader_stock[t].entries[restored] = .{
                .item = iid,
                .count = count_v,
                .quality = quality,
                .price = price,
                .sell = sell,
                .markup = markup,
                .stats = stats,
                .stats_n = stats_n,
            };
            restored += 1;
        }
        if (ts) |t| self.sim.trader_stock[t].n = restored;
    }
}
