//! worldglobal.xml `<environment>` ambient scales: the day/night pairs the
//! server-side ambient leg folds at night (stock `WorldEnvironment`
//! dataAmbient* Vector2 fields, parsed from the `<property name=...>`
//! rows). Only the scales the stealth/AI ambient computation reads are
//! carried; fog/water/inside rows stay client render state.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const paths = @import("paths.zig");
const stock_paths = @import("../util/stock_paths.zig");

/// Day/night pair from a `"day, night"` property value.
pub const DayNight = struct {
    day: f32 = 1.0,
    night: f32 = 1.0,
};

pub const Table = struct {
    /// `ambientSkyScale "1, .7"`.
    sky: DayNight = .{ .day = 1.0, .night = 0.7 },
    /// `ambientGroundScale ".3, .05"`.
    ground: DayNight = .{ .day = 0.3, .night = 0.05 },
    /// `ambientEquatorScale ".7, .45"`.
    equator: DayNight = .{ .day = 0.7, .night = 0.45 },
    /// `ambientMoon ".8, .4"` (add, scale).
    moon_add: f32 = 0.8,
    moon_scale: f32 = 0.4,
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn empty() Table {
        return .{};
    }

    pub fn deinit(self: *Table) void {
        arena_util.destroyHolder(&self.arena_ptr);
        self.* = .{};
    }

    /// Night ambient floor for the slice-1 curve: the day curve is 0 at
    /// ~1:00 by construction, but stock's night scales keep the total above
    /// 0 (sky .7, ground .05, equator .45, plus the moon add). The floor is
    /// the mean of the three night scales times the slice-1 0.5 output gain,
    /// so a stock file yields ~0.06 instead of 0; the moon brightness fold
    /// multiplies on top in the tick computation as before.
    pub fn nightFloor(self: Table) f32 {
        return (self.sky.night + self.ground.night + self.equator.night) / 3.0 * 0.5;
    }
};

fn parsePair(text: []const u8) ?DayNight {
    var it = std.mem.splitScalar(u8, text, ',');
    const a = it.next() orelse return null;
    const b = it.next() orelse return null;
    const day = std.fmt.parseFloat(f32, std.mem.trim(u8, a, " \t")) catch return null;
    const night = std.fmt.parseFloat(f32, std.mem.trim(u8, b, " \t")) catch return null;
    return .{ .day = day, .night = night };
}

fn parseMoon(text: []const u8, t: *Table) void {
    var it = std.mem.splitScalar(u8, text, ',');
    const a = it.next() orelse return;
    const b = it.next() orelse return;
    t.moon_add = std.fmt.parseFloat(f32, std.mem.trim(u8, a, " \t")) catch return;
    t.moon_scale = std.fmt.parseFloat(f32, std.mem.trim(u8, b, " \t")) catch return;
}

pub fn loadFromSlice(allocator: std.mem.Allocator, raw: []const u8) !Table {
    const clean = try xml.stripComments(allocator, raw);
    defer allocator.free(clean);
    var t: Table = .{};
    // Defaults are the stock values (struct initializers); only declared
    // rows override, so a minimal/modded file degrades gracefully.
    if (xml.propertyValue(clean, "ambientSkyScale")) |v| {
        if (parsePair(v)) |p| t.sky = p;
    }
    if (xml.propertyValue(clean, "ambientGroundScale")) |v| {
        if (parsePair(v)) |p| t.ground = p;
    }
    if (xml.propertyValue(clean, "ambientEquatorScale")) |v| {
        if (parsePair(v)) |p| t.equator = p;
    }
    if (xml.propertyValue(clean, "ambientMoon")) |v| parseMoon(v, &t);
    return t;
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Table {
    const raw = try io_fs.readFileAll(allocator, path);
    defer allocator.free(raw);
    // No arena: the table holds plain scalars (no retained slices), so
    // deinit is a no-op and there is nothing to leak.
    return loadFromSlice(allocator, raw);
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?Table {
    return paths.tryLoadConfig("worldglobal.xml", Table, loadFromPath, allocator, game_dir, config_dir);
}

test "worldglobal environment scales parse with stock defaults" {
    const p = stock_paths.configFile("worldglobal.xml");
    if (!io_fs.fileExists(p)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, p);
    defer t.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), t.sky.day, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), t.sky.night, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), t.ground.day, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), t.ground.night, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), t.equator.day, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.45), t.equator.night, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), t.moon_add, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), t.moon_scale, 1e-4);
    // Stock night floor is above 0 (the audit row's complaint).
    try std.testing.expect(t.nightFloor() > 0.05);
}

test "worldglobal slice parse tolerates minimal files" {
    var t = try loadFromSlice(std.testing.allocator, "<worldglobal><environment></environment></worldglobal>");
    defer t.deinit();
    // Absent rows keep the stock defaults.
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), t.sky.night, 1e-4);
    try std.testing.expect(t.nightFloor() > 0.05);
    var t2 = try loadFromSlice(std.testing.allocator, "<worldglobal><environment><property name=\"ambientSkyScale\" value=\"0.5, 0.25\"/></environment></worldglobal>");
    defer t2.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), t2.sky.night, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), t2.ground.night, 1e-4);
}
