//! World-clock persist extracted from game.zig (ZCL1: worldTime u64).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const io_fs = @import("../../util/io_fs.zig");
const logPersistErr = game_mod.logPersistErr;

pub fn saveClock(self: *const Game) !void {
    var path: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/clock.zcl", .{self.world.world_dir});
    var buf: [16]u8 = undefined;
    @memcpy(buf[0..4], "ZCL1");
    std.mem.writeInt(u64, buf[4..12], self.sim.director.clock.worldTimeBits(), .little);
    try io_fs.writeFile(self.allocator, p, buf[0..12]);
}

pub fn restoreClock(self: *Game) void {
    var path: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "{s}/clock.zcl", .{self.world.world_dir}) catch {
        std.debug.print("zdtd: clock.zcl path too long; keeping fresh clock\n", .{});
        return;
    };
    if (!io_fs.fileExistsSimple(p)) return;
    var buf: [16]u8 = undefined;
    const bytes = io_fs.readFileInto(self.allocator, p, &buf) catch |err| {
        logPersistErr(self, "restore clock", err);
        return;
    };
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "ZCL1")) {
        std.debug.print("zdtd: clock.zcl unreadable or mismatched; keeping fresh clock\n", .{});
        return;
    }
    const wt = std.mem.readInt(u64, bytes[4..12], .little);
    self.sim.director.clock.day = @intCast(wt / 24000 + 1);
    self.sim.director.clock.hours = @as(f32, @floatFromInt(wt % 24000)) / 1000.0;
    std.debug.print("zdtd: clock restored day={d} hours={d:.2}\n", .{ self.sim.director.clock.day, self.sim.director.clock.hours });
}
