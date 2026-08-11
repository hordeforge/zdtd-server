//! Sparse block meta + damage persist extracted from game.zig.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const io_fs = @import("../../util/io_fs.zig");
const util_log = @import("../../util/log.zig");

const block_meta_header_len = 4 + @sizeOf(u16);
const block_raw_record_len = @sizeOf(u64) + @sizeOf(u32);
const block_hp_count_len = @sizeOf(u16);
const block_hp_record_len = @sizeOf(u64) + @sizeOf(u16);
const block_meta_max_len = block_meta_header_len +
    256 * block_raw_record_len + block_hp_count_len +
    256 * block_hp_record_len;

pub fn saveBlockMeta(self: *const Game) !void {
    var path: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/blockmeta.zbm", .{self.world.world_dir});
    var buf: [block_meta_max_len]u8 = undefined;
    var o: usize = 0;
    @memcpy(buf[0..4], "ZBM1");
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
    if (o + 2 > buf.len) return error.WriteFailed;
    var hp_ord: [self.block_hp_key.len]u16 = undefined;
    const hp_n = self.block_hp_n;
    var hi: usize = 0;
    while (hi < hp_n) : (hi += 1) hp_ord[hi] = @intCast(hi);
    std.mem.sort(u16, hp_ord[0..hp_n], self, struct {
        fn less(g: *const Game, a: u16, b: u16) bool {
            return g.block_hp_key[a] < g.block_hp_key[b];
        }
    }.less);
    std.mem.writeInt(u16, buf[o..][0..2], @intCast(hp_n), .little);
    o += 2;
    for (hp_ord[0..hp_n]) |idx| {
        std.debug.assert(o + block_hp_record_len <= buf.len);
        std.mem.writeInt(u64, buf[o..][0..8], self.block_hp_key[idx], .little);
        std.mem.writeInt(u16, buf[o + 8 ..][0..2], self.block_hp[idx], .little);
        o += block_hp_record_len;
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
    if (data.len < 6 or !std.mem.eql(u8, data[0..4], "ZBM1")) return error.ReadFailed;
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
    if (o + 2 > data.len) return error.ReadFailed;
    const hn = std.mem.readInt(u16, data[o..][0..2], .little);
    o += 2;
    if (o + @as(usize, hn) * 10 > data.len) return error.ReadFailed;
    self.block_hp_n = @min(@as(usize, hn), self.block_hp_key.len);
    for (0..hn) |i| {
        if (i < self.block_hp_n) {
            self.block_hp_key[i] = std.mem.readInt(u64, data[o..][0..8], .little);
            self.block_hp[i] = std.mem.readInt(u16, data[o + 8 ..][0..2], .little);
        }
        o += 10;
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
    try std.testing.expectEqual(@as(usize, 5640), block_meta_max_len);
}
