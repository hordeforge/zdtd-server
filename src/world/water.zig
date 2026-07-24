//! Stock water_info.xml point sources (used as local water-table hints).

const std = @import("std");
const linux = std.os.linux;

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

    /// Carve/fill heights: ensure surface is not above water y within radius (pools).
    pub fn applyToChunkHeights(self: *const Sources, cx: i32, cz: i32, heights: *[256]u8) void {
        const base_x = cx * 16;
        const base_z = cz * 16;
        const radius: i32 = 12;
        var lz: i32 = 0;
        while (lz < 16) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < 16) : (lx += 1) {
                const wx = base_x + lx;
                const wz = base_z + lz;
                if (self.waterYNear(wx, wz, radius)) |wy| {
                    const idx: usize = @intCast(lx + lz * 16);
                    // Pull surface down to water table if terrain is lower than a rim...
                    // For lakes, lower surrounding terrain slightly above water, set water cells to wy.
                    if (heights[idx] < wy) {
                        // keep terrain; water fills air column conceptually
                    } else if (heights[idx] <= wy + 2) {
                        heights[idx] = wy;
                    }
                }
            }
        }
    }
};

fn readFileAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_z: [1024]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const rc = linux.open(path_z[0..path.len :0].ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const end = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(end) != .SUCCESS) return error.SeekFailed;
    const size: usize = @intCast(end);
    _ = linux.lseek(fd, 0, linux.SEEK.SET);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    var off: usize = 0;
    while (off < size) {
        const n = linux.read(fd, buf[off..].ptr, size - off);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        off += @intCast(n);
    }
    if (off != size) return error.ShortRead;
    return buf;
}

fn parseI32Prefix(s: []const u8) ?i32 {
    if (s.len == 0) return null;
    var i: usize = 0;
    var neg = false;
    if (s[0] == '-') {
        neg = true;
        i = 1;
    }
    if (i >= s.len or s[i] < '0' or s[i] > '9') return null;
    var v: i32 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = v * 10 + (s[i] - '0');
    }
    return if (neg) -v else v;
}

/// Parse `<Water pos="x, y, z"/>` entries.
pub fn loadFromWorldDir(allocator: std.mem.Allocator, world_dir: []const u8) !Sources {
    var path_buf: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/water_info.xml", .{world_dir});
    const xml = readFileAll(allocator, path) catch {
        return .{ .points = try allocator.alloc(WaterPoint, 0), .allocator = allocator };
    };
    defer allocator.free(xml);

    var count: usize = 0;
    var search: usize = 0;
    while (search < xml.len) {
        const rest = xml[search..];
        const i = std.mem.indexOf(u8, rest, "pos=\"") orelse break;
        count += 1;
        search += i + 5;
    }
    var pts = try allocator.alloc(WaterPoint, count);
    errdefer allocator.free(pts);
    var n: usize = 0;
    search = 0;
    while (n < count) {
        const rest = xml[search..];
        const i = std.mem.indexOf(u8, rest, "pos=\"") orelse break;
        var p = rest[i + 5 ..];
        search += i + 5;
        // skip spaces
        while (p.len > 0 and p[0] == ' ') p = p[1..];
        const x = parseI32Prefix(p) orelse continue;
        const c1 = std.mem.indexOfScalar(u8, p, ',') orelse continue;
        p = p[c1 + 1 ..];
        while (p.len > 0 and p[0] == ' ') p = p[1..];
        const y = parseI32Prefix(p) orelse continue;
        const c2 = std.mem.indexOfScalar(u8, p, ',') orelse continue;
        p = p[c2 + 1 ..];
        while (p.len > 0 and p[0] == ' ') p = p[1..];
        const z = parseI32Prefix(p) orelse continue;
        pts[n] = .{ .x = x, .y = y, .z = z };
        n += 1;
    }
    pts = try allocator.realloc(pts, n);
    return .{ .points = pts, .allocator = allocator };
}

test "parse water pos" {
    const xml =
        \\<WaterSources>
        \\  <Water pos="1855, 77, 1406"/>
        \\  <Water pos="-192, 72, 1924"/>
        \\</WaterSources>
    ;
    mkdirP("worlds");
    mkdirP("worlds/zdtd_water_test");
    writeFile("worlds/zdtd_water_test/water_info.xml", xml);
    var s = try loadFromWorldDir(std.testing.allocator, "worlds/zdtd_water_test");
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 2), s.points.len);
    try std.testing.expectEqual(@as(i32, 1855), s.points[0].x);
    try std.testing.expectEqual(@as(i32, 77), s.points[0].y);
    try std.testing.expectEqual(@as(i32, -192), s.points[1].x);
    try std.testing.expect(s.waterYNear(1855, 1406, 5).? == 77);
}

fn mkdirP(path: []const u8) void {
    var buf: [512]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (buf[i] != '/') continue;
        buf[i] = 0;
        _ = linux.mkdir(buf[0..i :0].ptr, 0o755);
        buf[i] = '/';
    }
    var zbuf: [513]u8 = undefined;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    _ = linux.mkdir(zbuf[0..path.len :0].ptr, 0o755);
}

fn writeFile(path: []const u8, data: []const u8) void {
    var path_z: [512]u8 = undefined;
    if (path.len >= path_z.len) return;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const rc = linux.open(path_z[0..path.len :0].ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    _ = linux.write(fd, data.ptr, data.len);
    _ = linux.close(fd);
}
