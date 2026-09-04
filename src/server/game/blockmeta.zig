//! Sparse block meta persist extracted from game.zig. Partial block damage
//! moved into the chunk damage plane (ZCH3, GAP "Player block damage"), so
//! this file persists only the `block_raw` rotation/meta cache mirror.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const io_fs = @import("../../util/io_fs.zig");
const util_log = @import("../../util/log.zig");

const block_meta_header_len = 4 + @sizeOf(u16);
const block_raw_record_len = @sizeOf(u64) + @sizeOf(u32);
const block_meta_max_len = block_meta_header_len +
    game_mod.max_block_raw_entries * block_raw_record_len;

pub fn saveBlockMeta(self: *const Game) !void {
    var path: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/blockmeta.zbm", .{self.world.world_dir});
    var buf: [block_meta_max_len]u8 = undefined;
    var o: usize = 0;
    @memcpy(buf[0..4], "ZBM2");
    o = 4;
    var raw_ord: [self.block_raw_key.len]u16 = undefined;
    const raw_n = self.block_raw_n;
    var ri: usize = 0;
    while (ri < raw_n) : (ri += 1) raw_ord[ri] = @intCast(ri);
    std.mem.sort(u16, raw_ord[0..raw_n], self, struct {
        fn less(g: *const Game, a: u16, b: u16) bool {
            return g.block_raw_key[a] < g.block_raw_key[b];
        }
    }.less);
    std.mem.writeInt(u16, buf[o..][0..2], @intCast(raw_n), .little);
    o += 2;
    for (raw_ord[0..raw_n]) |idx| {
        std.debug.assert(o + block_raw_record_len <= buf.len);
        std.mem.writeInt(u64, buf[o..][0..8], self.block_raw_key[idx], .little);
        std.mem.writeInt(u32, buf[o + 8 ..][0..4], self.block_raw[idx], .little);
        o += block_raw_record_len;
    }
    try io_fs.writeFile(p, buf[0..o]);
}

pub fn loadBlockMeta(self: *Game) !void {
    var path: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/blockmeta.zbm", .{self.world.world_dir});
    const data = io_fs.readFileAll(self.allocator, p) catch |err| switch (err) {
        error.FileNotFound => return error.OpenFailed,
        else => return err,
    };
    defer self.allocator.free(data);
    // Magic check needs 4 bytes in hand: `data.len < 6` short-circuits the
    // ZBM2 compare, so the ZBM1 arm would slice a 0-3 byte truncated file.
    if (data.len < 4) return error.ReadFailed;
    if (data.len < 6 or !std.mem.eql(u8, data[0..4], "ZBM2")) {
        if (std.mem.eql(u8, data[0..4], "ZBM1")) return; // pre-damage-plane: HP lived here
        return error.ReadFailed;
    }
    var o: usize = 4;
    const rn = std.mem.readInt(u16, data[o..][0..2], .little);
    o += 2;
    if (o + @as(usize, rn) * 12 > data.len) return error.ReadFailed;
    self.block_raw_n = @min(@as(usize, rn), self.block_raw_key.len);
    // Loop bound is the raw on-disk count, not the clamped one: `o` must land
    // past every record the file actually has, even the ones dropped for
    // exceeding the fixed array, or every field parsed after this desyncs.
    for (0..rn) |i| {
        if (i < self.block_raw_n) {
            self.block_raw_key[i] = std.mem.readInt(u64, data[o..][0..8], .little);
            self.block_raw[i] = std.mem.readInt(u32, data[o + 8 ..][0..4], .little);
        }
        o += 12;
    }
}

pub fn saveWeather(self: *const Game) !void {
    var path: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/weather.zwt", .{self.world.world_dir});
    var buf: [1024]u8 = undefined;
    const enc = try self.world.weather.encode(&buf);
    try io_fs.writeFile(p, enc);
}

pub fn restoreWeather(self: *Game) void {
    var path: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "{s}/weather.zwt", .{self.world.world_dir}) catch {
        std.debug.print("zdtd: weather.zwt path too long; keeping fresh roll\n", .{});
        return;
    };
    if (!io_fs.fileExists(p)) return;
    var buf: [1024]u8 = undefined;
    const bytes = io_fs.readFileInto(p, &buf) catch |err| {
        self.harness.counters.inc(.persistence_errors);
        std.debug.print("zdtd: restore weather failed: {s}\n", .{@errorName(err)});
        return;
    };
    if (self.world.weather.decode(bytes, &self.world.biome_layers_table)) {
        util_log.info("zdtd: weather state restored ({d} biomes)\n", .{self.world.weather.n});
    } else {
        std.debug.print("zdtd: weather.zwt unreadable or mismatched; keeping fresh roll\n", .{});
    }
}

test "block metadata buffer holds both stores at capacity" {
    // 6 header + 256 raw records (u64 key + u32 raw). The HP section moved to
    // the chunk damage plane (ZCH3) and is no longer part of this file.
    try std.testing.expectEqual(@as(usize, 3078), block_meta_max_len);
}

test "a blockmeta.zbm shorter than its magic fails instead of panicking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var path_buf: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, "{s}/blockmeta.zbm", .{g.world.world_dir});
    // 0..3 bytes: too short even for the 4-byte magic the ZBM1 arm compares.
    for (0..4) |n| {
        try io_fs.writeFile(p, "ZBM"[0..n]);
        try std.testing.expectError(error.ReadFailed, loadBlockMeta(g));
    }
    // A declared record count the file cannot back must be rejected before the
    // loop runs, or the reads walk past the buffer. That bound is what makes
    // the "loop over the raw count, not the clamped one" comment above safe.
    var empty_table: [6]u8 = undefined;
    @memcpy(empty_table[0..4], "ZBM2");
    std.mem.writeInt(u16, empty_table[4..6], 8, .little); // claims 8, carries 0
    try io_fs.writeFile(p, &empty_table);
    try std.testing.expectError(error.ReadFailed, loadBlockMeta(g));

    // One record short of the declared count: the off-by-one a `>=` bound
    // would let through.
    var one_short: [6 + 12]u8 = @splat(0);
    @memcpy(one_short[0..4], "ZBM2");
    std.mem.writeInt(u16, one_short[4..6], 2, .little); // claims 2, carries 1
    try io_fs.writeFile(p, &one_short);
    try std.testing.expectError(error.ReadFailed, loadBlockMeta(g));

    // The exact count parses and lands in the store.
    var ok: [6 + 12]u8 = @splat(0);
    @memcpy(ok[0..4], "ZBM2");
    std.mem.writeInt(u16, ok[4..6], 1, .little);
    std.mem.writeInt(u64, ok[6..14], 0x1122334455667788, .little);
    std.mem.writeInt(u32, ok[14..18], 0xAABBCCDD, .little);
    try io_fs.writeFile(p, &ok);
    try loadBlockMeta(g);
    try std.testing.expectEqual(@as(usize, 1), g.block_raw_n);
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), g.block_raw_key[0]);
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), g.block_raw[0]);

    std.debug.print("PASS blockmeta-zbm: truncated header and short record table rejected\n", .{});
}
