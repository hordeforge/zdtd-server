//! Load stock `biomes.png` (RGBA8 non-interlaced) for chunk biome ids.
//! PNG pixels = biomemapcolor RGB keys (biomes.xml), NOT biome ids.
//! Map color→biomemap id on load so Chunk.m_Biomes stays < 50
//! (CalcDominantBiome indexes int[50]; raw R=186 burnt_forest OOB).
//! World XZ center origin (same as DTM): img_x = wx + W/2.

const std = @import("std");
const linux = std.os.linux;

/// Stock biomes.xml biomemapcolor → biomemap id (v3.1 Navezgane).
/// Unknown → pine_forest (3). Always < 50 for CalcDominantBiome.
pub fn colorToId(r: u8, g: u8, b: u8) u8 {
    const rgb: u32 = (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
    return switch (rgb) {
        0xFFFFFF => 1, // snow
        0x004000 => 3, // pine_forest
        0xFFE477 => 5, // desert
        0x0000FF => 6, // water
        0x001234 => 19, // underwater
        0xFF0000 => 7, // radiated
        0xFFA800 => 8, // wasteland
        0xBA00FF => 9, // burnt_forest
        else => 3, // unknown → pine_forest
    };
}

pub const BiomeMap = struct {
    width: i32 = 0,
    height: i32 = 0,
    /// biomemap ids (not PNG color channels), row-major.
    r: []u8 = &.{},
    allocator: std.mem.Allocator = undefined,
    half_w: i32 = 0,
    half_h: i32 = 0,

    pub fn deinit(self: *BiomeMap) void {
        if (self.r.len != 0) self.allocator.free(self.r);
        self.* = .{};
    }

    /// Biome id for world XZ; null if OOB / unloaded.
    pub fn atWorld(self: *const BiomeMap, wx: i32, wz: i32) ?u8 {
        if (self.r.len == 0) return null;
        const dx = wx + self.half_w;
        const dz = wz + self.half_h;
        if (dx < 0 or dz < 0 or dx >= self.width or dz >= self.height) return null;
        const idx: usize = @intCast(@as(i64, dz) * @as(i64, self.width) + @as(i64, dx));
        return self.r[idx];
    }

    /// Dominant biomemap id over 16×16 chunk columns.
    pub fn chunkDominant(self: *const BiomeMap, cx: i32, cz: i32) u8 {
        if (self.r.len == 0) return 3;
        const base_x = cx * 16;
        const base_z = cz * 16;
        // CalcDominantBiome uses int[50]; only count valid ids.
        var counts: [50]u16 = .{0} ** 50;
        var lz: i32 = 0;
        while (lz < 16) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < 16) : (lx += 1) {
                if (self.atWorld(base_x + lx, base_z + lz)) |b| {
                    if (b < 50) counts[b] +%= 1;
                }
            }
        }
        var best: u8 = 3;
        var best_n: u16 = 0;
        var i: usize = 0;
        while (i < 50) : (i += 1) {
            if (counts[i] > best_n) {
                best_n = counts[i];
                best = @intCast(i);
            }
        }
        return best;
    }
};

fn readFileAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_z: [2048]u8 = undefined;
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
    return buf[0..off];
}

/// Minimal PNG decoder: 8-bit RGBA or RGB, non-interlaced, filter 0–4.
pub fn loadPngR(allocator: std.mem.Allocator, path: []const u8) !BiomeMap {
    const file = try readFileAll(allocator, path);
    defer allocator.free(file);
    if (file.len < 33) return error.ShortPng;
    if (!std.mem.eql(u8, file[0..8], "\x89PNG\r\n\x1a\n")) return error.BadMagic;

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var idat_list: std.ArrayList(u8) = .empty;
    defer idat_list.deinit(allocator);

    var pos: usize = 8;
    while (pos + 12 <= file.len) {
        const clen = std.mem.readInt(u32, file[pos..][0..4], .big);
        const ctype = file[pos + 4 ..][0..4];
        pos += 8;
        if (pos + clen + 4 > file.len) return error.ShortPng;
        const cdata = file[pos .. pos + clen];
        if (std.mem.eql(u8, ctype, "IHDR")) {
            if (clen < 13) return error.BadIhdr;
            width = std.mem.readInt(u32, cdata[0..4], .big);
            height = std.mem.readInt(u32, cdata[4..8], .big);
            bit_depth = cdata[8];
            color_type = cdata[9];
            if (cdata[10] != 0 or cdata[11] != 0 or cdata[12] != 0) return error.UnsupportedPng;
            if (bit_depth != 8) return error.UnsupportedPng;
            if (color_type != 2 and color_type != 6) return error.UnsupportedPng;
        } else if (std.mem.eql(u8, ctype, "IDAT")) {
            try idat_list.appendSlice(allocator, cdata);
        } else if (std.mem.eql(u8, ctype, "IEND")) {
            break;
        }
        pos += clen + 4; // data + crc
    }
    if (width == 0 or height == 0 or idat_list.items.len == 0) return error.NoIdat;

    const bpp: usize = if (color_type == 6) 4 else 3;
    const stride = @as(usize, width) * bpp;
    const raw_len = (@as(usize, height)) * (1 + stride);

    // zlib inflate (PNG IDAT is zlib-wrapped deflate). Same API as wire/frame.zig.
    const inflated = try allocator.alloc(u8, raw_len);
    defer allocator.free(inflated);
    {
        var in: std.Io.Reader = .fixed(idat_list.items);
        var out: std.Io.Writer = .fixed(inflated);
        var dec: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
        const nread = dec.reader.streamRemaining(&out) catch return error.BadInflate;
        if (nread != raw_len) return error.BadInflate;
    }

    const out_ids = try allocator.alloc(u8, @as(usize, width) * @as(usize, height));
    errdefer allocator.free(out_ids);

    // Unfilter scanlines → biomemap id via RGB color key.
    var prev: []const u8 = &[_]u8{};
    var y: usize = 0;
    var row_off: usize = 0;
    while (y < height) : (y += 1) {
        const filter = inflated[row_off];
        const row = inflated[row_off + 1 .. row_off + 1 + stride];
        var x: usize = 0;
        while (x < stride) : (x += 1) {
            const left: u8 = if (x >= bpp) row[x - bpp] else 0;
            const up: u8 = if (prev.len > x) prev[x] else 0;
            const up_left: u8 = if (prev.len > x and x >= bpp) prev[x - bpp] else 0;
            const recon: u8 = switch (filter) {
                0 => row[x],
                1 => row[x] +% left,
                2 => row[x] +% up,
                3 => row[x] +% @as(u8, @truncate((@as(u16, left) + up) / 2)),
                4 => row[x] +% paeth(left, up, up_left),
                else => return error.BadFilter,
            };
            // write back for next left
            @constCast(row.ptr)[x] = recon;
        }
        // RGB → biomemap id (not raw R)
        var px: usize = 0;
        while (px < width) : (px += 1) {
            const o = px * bpp;
            out_ids[y * width + px] = colorToId(row[o], row[o + 1], row[o + 2]);
        }
        prev = row;
        row_off += 1 + stride;
    }

    const w: i32 = @intCast(width);
    const h: i32 = @intCast(height);
    return .{
        .width = w,
        .height = h,
        .r = out_ids,
        .allocator = allocator,
        .half_w = @divTrunc(w, 2),
        .half_h = @divTrunc(h, 2),
    };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const aa: i16 = a;
    const bb: i16 = b;
    const cc: i16 = c;
    const p = aa + bb - cc;
    const pa = @abs(p - aa);
    const pb = @abs(p - bb);
    const pc = @abs(p - cc);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

pub fn tryLoad(allocator: std.mem.Allocator, map_dir: []const u8) !?BiomeMap {
    var path_buf: [2048]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, "{s}/biomes.png", .{map_dir});
    return loadPngR(allocator, p) catch null;
}

test "colorToId stock keys" {
    try std.testing.expectEqual(@as(u8, 1), colorToId(255, 255, 255));
    try std.testing.expectEqual(@as(u8, 3), colorToId(0, 64, 0));
    try std.testing.expectEqual(@as(u8, 5), colorToId(255, 228, 119));
    try std.testing.expectEqual(@as(u8, 8), colorToId(255, 168, 0));
    try std.testing.expectEqual(@as(u8, 9), colorToId(186, 0, 255));
    try std.testing.expectEqual(@as(u8, 19), colorToId(0, 18, 52));
    try std.testing.expectEqual(@as(u8, 3), colorToId(1, 2, 3));
}

test "load navezgane biomes.png if present" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Worlds/Navezgane/biomes.png";
    var path_z: [512]u8 = undefined;
    if (p.len >= path_z.len) return error.SkipZigTest;
    @memcpy(path_z[0..p.len], p);
    path_z[p.len] = 0;
    const rc = linux.open(path_z[0..p.len :0].ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
    _ = linux.close(@intCast(rc));

    var m = try loadPngR(std.testing.allocator, p);
    defer m.deinit();
    try std.testing.expectEqual(@as(i32, 3072), m.width);
    try std.testing.expectEqual(@as(i32, 3072), m.height);
    try std.testing.expectEqual(@as(usize, 3072 * 3072), m.r.len);
    // Spawn (-273,449) is burnt_forest color → biomemap id 9
    try std.testing.expectEqual(@as(u8, 9), m.atWorld(-273, 449).?);
    try std.testing.expect(m.chunkDominant(@divFloor(-273, 16), @divFloor(449, 16)) < 50);
}
