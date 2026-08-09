//! Load stock `biomes.png` (RGBA8 non-interlaced) for chunk biome ids.
//! PNG pixels = biomemapcolor RGB keys (biomes.xml), NOT biome ids.
//! Map color→biomemap id on load so Chunk.m_Biomes stays < 50
//! (CalcDominantBiome indexes int[50]; raw R=186 burnt_forest OOB).
//! World XZ center origin (same as DTM): img_x = wx + W/2.

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const xml = @import("../assets/xml_util.zig");
const paths = @import("../assets/paths.zig");

/// RGB packed 0xRRGGBB → biomemap id. Loaded from biomes.xml; fallback for tests.
pub const ColorTable = struct {
    /// sparse: we store pairs in parallel arrays (small N).
    colors: []const u32 = &.{},
    ids: []const u8 = &.{},
    default_id: u8 = 3,
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn empty() ColorTable {
        return .{};
    }

    pub fn deinit(self: *ColorTable) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = .{};
    }

    pub fn lookup(self: *const ColorTable, r: u8, g: u8, b: u8) u8 {
        const rgb: u32 = (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
        for (self.colors, self.ids) |c, id| {
            if (c == rgb) return id;
        }
        return self.default_id;
    }
};

/// Fallback when biomes.xml is missing (offline tests). Matches stock V3.1 keys.
pub fn colorToId(r: u8, g: u8, b: u8) u8 {
    return fallback_colors.lookup(r, g, b);
}

const fallback_colors = blk: {
    @setEvalBranchQuota(1000);
    break :blk ColorTable{
        .colors = &[_]u32{ 0xFFFFFF, 0x004000, 0xFFE477, 0x0000FF, 0x001234, 0xFF0000, 0xFFA800, 0xBA00FF },
        .ids = &[_]u8{ 1, 3, 5, 6, 19, 7, 8, 9 },
        .default_id = 3,
    };
};

fn parseHexColor(s: []const u8) ?u32 {
    var t = std.mem.trim(u8, s, " \t\"'");
    if (t.len > 0 and t[0] == '#') t = t[1..];
    if (t.len != 6) return null;
    return std.fmt.parseInt(u32, t, 16) catch null;
}

/// Load biomemapcolor + biomemap id from biomes.xml.
pub fn loadColorTable(allocator: std.mem.Allocator, path: []const u8) !ColorTable {
    const raw = try io_fs.readFileAll(allocator, path);
    defer allocator.free(raw);
    const clean = try xml.stripComments(allocator, raw);
    defer allocator.free(clean);

    const ap = try allocator.create(std.heap.ArenaAllocator);
    ap.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        ap.deinit();
        allocator.destroy(ap);
    }
    const arena = ap.allocator();

    // name → id from <biomemap id="09" name="burnt_forest"/>
    var name_to_id: std.StringHashMapUnmanaged(u8) = .{};
    var i: usize = 0;
    while (i < clean.len) {
        const mi = std.mem.findPos(u8, clean, i, "<biomemap") orelse break;
        const id_s = xml.attr(clean, mi, "id") orelse {
            i = mi + 9;
            continue;
        };
        const nm = xml.attr(clean, mi, "name") orelse {
            i = mi + 9;
            continue;
        };
        const id_n = std.fmt.parseInt(u8, id_s, 10) catch {
            i = mi + 9;
            continue;
        };
        try name_to_id.put(arena, try arena.dupe(u8, nm), id_n);
        i = mi + 9;
    }

    var colors: std.ArrayList(u32) = .empty;
    defer colors.deinit(allocator);
    var ids: std.ArrayList(u8) = .empty;
    defer ids.deinit(allocator);

    i = 0;
    while (i < clean.len) {
        const bi = std.mem.findPos(u8, clean, i, "<biome ") orelse break;
        const bname = xml.attr(clean, bi, "name") orelse {
            i = bi + 7;
            continue;
        };
        const col_s = xml.attr(clean, bi, "biomemapcolor") orelse {
            i = bi + 7;
            continue;
        };
        const rgb = parseHexColor(col_s) orelse {
            i = bi + 7;
            continue;
        };
        const id = name_to_id.get(bname) orelse {
            i = bi + 7;
            continue;
        };
        try colors.append(allocator, rgb);
        try ids.append(allocator, id);
        i = bi + 7;
    }

    const cslice = try arena.alloc(u32, colors.items.len);
    @memcpy(cslice, colors.items);
    const islice = try arena.alloc(u8, ids.items.len);
    @memcpy(islice, ids.items);
    const def: u8 = name_to_id.get("pine_forest") orelse 3;
    return .{
        .colors = cslice,
        .ids = islice,
        .default_id = def,
        .arena_ptr = ap,
    };
}

pub fn tryLoadColorTable(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?ColorTable {
    var path_buf: [2048]u8 = undefined;
    const path = paths.resolveConfigXml(&path_buf, "biomes.xml", game_dir, config_dir) orelse return null;
    return loadColorTable(allocator, path) catch |err| {
        switch (err) {
            error.FileNotFound => {},
            else => std.debug.print(
                "zdtd: load biomes.xml colors failed: {s} ({s})\n",
                .{ @errorName(err), path },
            ),
        }
        return null;
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
    /// Blocks per biomes.png pixel (world size / png size); Navezgane ships 3072px for a 6144 world.
    scale: i32 = 1,

    pub fn deinit(self: *BiomeMap) void {
        if (self.r.len != 0) self.allocator.free(self.r);
        self.* = .{};
    }

    /// Biome id for world XZ; null if OOB / unloaded.
    pub fn atWorld(self: *const BiomeMap, wx: i32, wz: i32) ?u8 {
        if (self.r.len == 0) return null;
        // PNG row 0 is north (+Z), so Z flips; X maps straight through.
        const dx = @divFloor(wx, self.scale) + self.half_w;
        const dz = self.half_h - 1 - @divFloor(wz, self.scale);
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

/// Minimal PNG decoder: 8-bit RGBA or RGB, non-interlaced, filter 0–4.
pub fn loadPngR(allocator: std.mem.Allocator, path: []const u8) !BiomeMap {
    return loadPngRWithColors(allocator, path, null);
}

pub fn loadPngRWithColors(allocator: std.mem.Allocator, path: []const u8, colors: ?*const ColorTable) !BiomeMap {
    const file = try io_fs.readFileAll(allocator, path);
    defer allocator.free(file);
    return parsePng(allocator, file, colors);
}

/// Largest supported map edge; also guards raw_len math against overflow and
/// claimed-dimension allocation bombs from untrusted files.
pub const max_png_dim: u32 = 16384;

pub fn parsePng(allocator: std.mem.Allocator, file: []const u8, colors: ?*const ColorTable) !BiomeMap {
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
            if (width == 0 or height == 0 or width > max_png_dim or height > max_png_dim) return error.UnsupportedPng;
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
            const ct = colors orelse &fallback_colors;
            out_ids[y * width + px] = ct.lookup(row[o], row[o + 1], row[o + 2]);
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
    return tryLoadWithColors(allocator, map_dir, null);
}

pub fn tryLoadWithColors(allocator: std.mem.Allocator, map_dir: []const u8, colors: ?*const ColorTable) !?BiomeMap {
    var path_buf: [2048]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, "{s}/biomes.png", .{map_dir});
    return loadPngRWithColors(allocator, p, colors) catch |err| {
        switch (err) {
            error.FileNotFound => {},
            else => std.debug.print(
                "zdtd: load biomes.png failed: {s} ({s})\n",
                .{ @errorName(err), p },
            ),
        }
        return null;
    };
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
    if (!io_fs.fileExists(p)) return error.SkipZigTest;

    var m = try loadPngR(std.testing.allocator, p);
    defer m.deinit();
    m.scale = 2; // 3072px biomes.png over the 6144 Navezgane world
    try std.testing.expectEqual(@as(i32, 3072), m.width);
    try std.testing.expectEqual(@as(i32, 3072), m.height);
    try std.testing.expectEqual(@as(usize, 3072 * 3072), m.r.len);
    // All 8 stock spawnpoints sit in pine_forest under the scale-2 north-up
    // mapping (the old 1:1 no-flip read put this one in burnt_forest).
    try std.testing.expectEqual(@as(u8, 3), m.atWorld(-273, 449).?);
    try std.testing.expect(m.chunkDominant(@divFloor(-273, 16), @divFloor(449, 16)) < 50);
}
