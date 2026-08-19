//! Stock water_info.xml point sources (used as local water-table hints).

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const xml_util = @import("../assets/xml_util.zig");

pub const WaterPoint = struct {
    x: i32,
    y: i32,
    z: i32,
};

pub const Sources = struct {
    points: []WaterPoint,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Sources) void {
        self.allocator.free(self.points);
        self.* = undefined;
    }

    /// If (wx,wz) is near a water source (within radius blocks), return water surface y.
    pub fn waterYNear(self: *const Sources, wx: i32, wz: i32, radius: i32) ?u8 {
        const r2 = radius * radius;
        for (self.points) |p| {
            const dx = wx - p.x;
            const dz = wz - p.z;
            if (dx * dx + dz * dz <= r2) {
                return @intCast(@min(255, @max(0, p.y)));
            }
        }
        return null;
    }

    /// Worldgen carve radius (blocks) around a water source: heights within this
    /// radius are lowered to the water surface so pools read as flat (zdtd-owned
    /// worldgen, PROVENANCE.md 3.7; named constant, not anonymous).
    const pool_carve_radius: i32 = 12;

    /// Carve/fill heights: ensure surface is not above water y within radius (pools).
    pub fn applyToChunkHeights(self: *const Sources, cx: i32, cz: i32, heights: *[256]u8) void {
        const base_x = cx * 16;
        const base_z = cz * 16;
        const radius: i32 = pool_carve_radius;
        var lz: i32 = 0;
        while (lz < 16) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < 16) : (lx += 1) {
                const wx = base_x + lx;
                const wz = base_z + lz;
                if (self.waterYNear(wx, wz, radius)) |wy| {
                    const idx: usize = @intCast(lx + lz * 16);
                    // Clamp near-rim terrain down to the water table; deeper
                    // terrain keeps its height (water fills the air column).
                    // `heights[idx] <= wy + 2` would overflow u8 at wy >= 254,
                    // so compare the clamped delta instead.
                    if (heights[idx] >= wy and heights[idx] - wy <= 2) {
                        heights[idx] = wy;
                    }
                }
            }
        }
    }
};

const parseI32Prefix = xml_util.parseI32Prefix;

/// Parse `<Water pos="x, y, z"/>` entries from water_info.xml bytes.
pub fn parseXml(allocator: std.mem.Allocator, xml: []const u8) !Sources {
    var count: usize = 0;
    var search: usize = 0;
    while (search < xml.len) {
        const rest = xml[search..];
        const i = std.mem.find(u8, rest, "pos=\"") orelse break;
        count += 1;
        search += i + 5;
    }
    var pts = try allocator.alloc(WaterPoint, count);
    errdefer allocator.free(pts);
    var n: usize = 0;
    search = 0;
    while (n < count) {
        const rest = xml[search..];
        const i = std.mem.find(u8, rest, "pos=\"") orelse break;
        var p = rest[i + 5 ..];
        search += i + 5;
        p = std.mem.trimStart(u8, p, " ");
        const x = parseI32Prefix(p) orelse continue;
        const c1 = std.mem.findScalar(u8, p, ',') orelse continue;
        p = std.mem.trimStart(u8, p[c1 + 1 ..], " ");
        const y = parseI32Prefix(p) orelse continue;
        const c2 = std.mem.findScalar(u8, p, ',') orelse continue;
        p = std.mem.trimStart(u8, p[c2 + 1 ..], " ");
        const z = parseI32Prefix(p) orelse continue;
        pts[n] = .{ .x = x, .y = y, .z = z };
        n += 1;
    }
    pts = try allocator.realloc(pts, n);
    return .{ .points = pts, .allocator = allocator };
}

/// Load water_info.xml from a world directory (`pos="x, y, z"` entries).
pub fn loadFromWorldDir(allocator: std.mem.Allocator, world_dir: []const u8) !Sources {
    var path_buf: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/water_info.xml", .{world_dir});
    // Missing file is normal for flat/proc worlds; other I/O errors must not look like "no water".
    const xml = io_fs.readFileAll(allocator, path) catch |err| {
        switch (err) {
            error.FileNotFound => {},
            else => std.debug.print(
                "zdtd: water_info.xml read failed: {s} ({s})\n",
                .{ @errorName(err), path },
            ),
        }
        return .{ .points = try allocator.alloc(WaterPoint, 0), .allocator = allocator };
    };
    defer allocator.free(xml);
    return parseXml(allocator, xml);
}

test "parse water pos" {
    const xml =
        \\<WaterSources>
        \\  <Water pos="1855, 77, 1406"/>
        \\  <Water pos="-192, 72, 1924"/>
        \\</WaterSources>
    ;
    io_fs.mkdirPath("worlds");
    io_fs.mkdirPath("worlds/zdtd_water_test");
    try io_fs.writeFile("worlds/zdtd_water_test/water_info.xml", xml);
    var s = try loadFromWorldDir(std.testing.allocator, "worlds/zdtd_water_test");
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 2), s.points.len);
    try std.testing.expectEqual(@as(i32, 1855), s.points[0].x);
    try std.testing.expectEqual(@as(i32, 77), s.points[0].y);
    try std.testing.expectEqual(@as(i32, -192), s.points[1].x);
    try std.testing.expect(s.waterYNear(1855, 1406, 5).? == 77);
}
