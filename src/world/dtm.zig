//! Stock 7DTD baked heightmap loader (Navezgane / Pregen*).
//!
//! Layout (RE + measured on dedicated Data/Worlds, V3.1.0 b14):
//!   map_info.xml  property HeightMapSize value="W,H"
//!   dtm.raw       W*H little-endian u16 samples, gameY * 256
//!   World XZ → DTM: dx = wx + W/2, dz = wz + H/2  (origin at map center)
//! Prefer dtm_processed.raw when present (same layout).

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const xml_util = @import("../assets/xml_util.zig");

pub const Heightmap = struct {
    width: i32,
    height: i32,
    /// Owned buffer of u16 samples (width*height), row-major Z then X (index = dz*width + dx).
    samples: []u16,
    allocator: std.mem.Allocator,
    half_w: i32,
    half_h: i32,

    pub fn deinit(self: *Heightmap) void {
        self.allocator.free(self.samples);
        self.* = undefined;
    }

    /// Surface block Y at world XZ (u16; stock DTM stores gameY*256 in u16 samples).
    /// Out of bounds → null. `samples >> 8` caps the result at 255.
    pub fn heightAtWorld(self: *const Heightmap, wx: i32, wz: i32) ?u16 {
        const dx = wx + self.half_w;
        const dz = wz + self.half_h;
        if (dx < 0 or dz < 0 or dx >= self.width or dz >= self.height) return null;
        const idx: usize = @intCast(@as(i64, dz) * @as(i64, self.width) + @as(i64, dx));
        return @as(u16, self.samples[idx] >> 8);
    }

    /// Fill a 16×16 chunk height plane for chunk (cx, cz). Missing samples use `fallback`.
    /// Plane remains u8 for stock wire/disk.
    pub fn fillChunkHeights(self: *const Heightmap, cx: i32, cz: i32, out: *[256]u8, fallback: u8) void {
        const base_x = cx * 16;
        const base_z = cz * 16;
        var lz: i32 = 0;
        while (lz < 16) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < 16) : (lx += 1) {
                const h16 = self.heightAtWorld(base_x + lx, base_z + lz) orelse @as(u16, fallback);
                out[@intCast(lx + lz * 16)] = if (h16 > 255) 255 else @intCast(h16);
            }
        }
    }
};

pub const SpawnPoint = struct {
    x: i32,
    y: i32,
    z: i32,
};

pub const MapMeta = struct {
    width: i32 = 0,
    height: i32 = 0,
    name: []const u8 = "",
};

/// Minimal parse of map_info.xml for HeightMapSize="W,H".
pub fn parseMapInfoSize(xml: []const u8) !struct { w: i32, h: i32 } {
    // Look for HeightMapSize" value=" or HeightMapSize"value="
    const key = "HeightMapSize";
    const ki = std.mem.indexOf(u8, xml, key) orelse return error.NoHeightMapSize;
    const rest = xml[ki..];
    const q1 = std.mem.indexOf(u8, rest, "\"") orelse return error.BadMapInfo;
    const after = rest[q1 + 1 ..];
    // may be Name" first if we hit wrong - find value=
    const vkey = "value=";
    const vi = std.mem.indexOf(u8, rest, vkey) orelse return error.BadMapInfo;
    var p = rest[vi + vkey.len ..];
    // skip optional quote
    if (p.len > 0 and p[0] == '"') p = p[1..];
    // read W,H
    var w: i32 = 0;
    var h: i32 = 0;
    var i: usize = 0;
    while (i < p.len and p[i] >= '0' and p[i] <= '9') : (i += 1) {
        w = w * 10 + (p[i] - '0');
    }
    if (i >= p.len or p[i] != ',') return error.BadMapInfo;
    i += 1;
    const h0 = i;
    while (i < p.len and p[i] >= '0' and p[i] <= '9') : (i += 1) {
        h = h * 10 + (p[i] - '0');
    }
    if (i == h0 or w <= 0 or h <= 0) return error.BadMapInfo;
    _ = after;
    return .{ .w = w, .h = h };
}

/// Parse spawnpoints.xml entries position="x,y,z".
pub fn parseSpawnPoints(xml: []const u8, out: []SpawnPoint) usize {
    var n: usize = 0;
    var search: usize = 0;
    while (n < out.len) {
        const rest = xml[search..];
        const pi = std.mem.indexOf(u8, rest, "position=\"") orelse break;
        var p = rest[pi + "position=\"".len ..];
        const x = parseI32Prefix(p) orelse break;
        p = skipToComma(p) orelse break;
        p = p[1..];
        const y = parseI32Prefix(p) orelse break;
        p = skipToComma(p) orelse break;
        p = p[1..];
        const z = parseI32Prefix(p) orelse break;
        out[n] = .{ .x = x, .y = y, .z = z };
        n += 1;
        search += pi + 10;
    }
    return n;
}

const parseI32Prefix = xml_util.parseI32Prefix;

fn skipToComma(s: []const u8) ?[]const u8 {
    const i = std.mem.indexOfScalar(u8, s, ',') orelse return null;
    return s[i..];
}

fn fileExists(path: []const u8) bool {
    return io_fs.fileExistsSimple(path);
}

fn joinPath(buf: []u8, a: []const u8, b: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ a, b });
}

/// Load stock world folder: map_info.xml + dtm_processed.raw|dtm.raw.
pub fn loadFromWorldDir(allocator: std.mem.Allocator, world_dir: []const u8) !Heightmap {
    var path_buf: [1024]u8 = undefined;
    const info_path = try joinPath(&path_buf, world_dir, "map_info.xml");
    const info_xml = try io_fs.readFileAll(allocator, info_path);
    defer allocator.free(info_xml);
    const size = try parseMapInfoSize(info_xml);
    const expected: usize = @as(usize, @intCast(size.w)) * @as(usize, @intCast(size.h)) * 2;

    // Prefer processed DTM when present.
    var dtm_path_buf: [1024]u8 = undefined;
    const processed = try joinPath(&dtm_path_buf, world_dir, "dtm_processed.raw");
    const raw_name = if (fileExists(processed)) "dtm_processed.raw" else "dtm.raw";
    const dtm_path = try joinPath(&dtm_path_buf, world_dir, raw_name);
    const raw = try io_fs.readFileAll(allocator, dtm_path);
    defer allocator.free(raw);
    if (raw.len < expected) return error.DtmTooSmall;
    if (raw.len != expected) {
        // Some builds pad; require at least full grid.
    }

    const count: usize = @intCast(@as(i64, size.w) * @as(i64, size.h));
    const samples = try allocator.alloc(u16, count);
    errdefer allocator.free(samples);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        samples[i] = std.mem.readInt(u16, raw[i * 2 ..][0..2], .little);
    }

    return .{
        .width = size.w,
        .height = size.h,
        .samples = samples,
        .allocator = allocator,
        .half_w = @divTrunc(size.w, 2),
        .half_h = @divTrunc(size.h, 2),
    };
}

pub fn loadSpawnPoints(allocator: std.mem.Allocator, world_dir: []const u8, out: []SpawnPoint) !usize {
    var path_buf: [1024]u8 = undefined;
    const path = try joinPath(&path_buf, world_dir, "spawnpoints.xml");
    if (!fileExists(path)) return 0;
    const xml = try io_fs.readFileAll(allocator, path);
    defer allocator.free(xml);
    return parseSpawnPoints(xml, out);
}

test "parse HeightMapSize navezgane style" {
    const xml =
        \\<MapInfo>
        \\  <property name="HeightMapSize"value="6144,6144"/>
        \\</MapInfo>
    ;
    const s = try parseMapInfoSize(xml);
    try std.testing.expectEqual(@as(i32, 6144), s.w);
    try std.testing.expectEqual(@as(i32, 6144), s.h);
}

test "parse HeightMapSize spaced" {
    const xml =
        \\<property name="HeightMapSize" value="8192,8192" />
    ;
    const s = try parseMapInfoSize(xml);
    try std.testing.expectEqual(@as(i32, 8192), s.w);
}

test "parse spawnpoints" {
    const xml =
        \\<spawnpoints>
        \\  <spawnpoint position="-273,61,449" rotation="0,51,0" />
        \\  <spawnpoint position="163,61,818" rotation="0,125,0" />
        \\</spawnpoints>
    ;
    var out: [8]SpawnPoint = undefined;
    const n = parseSpawnPoints(xml, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(i32, -273), out[0].x);
    try std.testing.expectEqual(@as(i32, 61), out[0].y);
    try std.testing.expectEqual(@as(i32, 449), out[0].z);
}

test "synthetic dtm center mapping" {
    // 32x32 map, constant height 70 → raw 70*256
    const w: i32 = 32;
    const h: i32 = 32;
    const count: usize = @intCast(w * h);
    const samples = try std.testing.allocator.alloc(u16, count);
    defer std.testing.allocator.free(samples);
    @memset(samples, 70 * 256);
    // bump world (0,0) which is DTM (16,16)
    samples[@intCast(16 * w + 16)] = 80 * 256;

    var hm: Heightmap = .{
        .width = w,
        .height = h,
        .samples = samples,
        .allocator = std.testing.allocator,
        .half_w = 16,
        .half_h = 16,
    };
    try std.testing.expectEqual(@as(u16, 80), hm.heightAtWorld(0, 0).?);
    try std.testing.expectEqual(@as(u16, 70), hm.heightAtWorld(1, 0).?);
    try std.testing.expect(hm.heightAtWorld(-17, 0) == null);

    var plane: [256]u8 = undefined;
    hm.fillChunkHeights(0, 0, &plane, 64);
    try std.testing.expectEqual(@as(u8, 80), plane[0]); // lx=0,lz=0 → world 0,0
}

test "load live Navezgane if present" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Worlds/Navezgane";
    if (!fileExists(path ++ "/dtm.raw")) return error.SkipZigTest;
    var hm = try loadFromWorldDir(std.testing.allocator, path);
    defer hm.deinit();
    try std.testing.expectEqual(@as(i32, 6144), hm.width);
    // Spawn (-273,61,449) surface should be ~60
    const h = hm.heightAtWorld(-273, 449).?;
    try std.testing.expect(h >= 55 and h <= 65);
    var spawns: [16]SpawnPoint = undefined;
    const n = try loadSpawnPoints(std.testing.allocator, path, &spawns);
    try std.testing.expect(n >= 1);
    try std.testing.expectEqual(@as(i32, -273), spawns[0].x);
}
