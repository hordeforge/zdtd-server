//! Copernicus GLO-30 DEM codec: COG header parse, tile decode, S3 object key
//! and elevation-to-block mapping (fuzz-covered in src/fuzz.zig). The S3
//! range-fetch streaming layer (M1 of docs/SCALE.md) is parked until M11 and
//! stays in git history for resurrection.
//!
//! Formats: II TIFF, f32 samples, DEFLATE (compression 8) + floating-point
//! predictor 3, 1024x1024 internal tiles, IFD + offset/count arrays inside
//! the first 64 KiB (GDAL LAYOUT=IFDS_BEFORE_DATA).
//!
//! Elevation maps world XZ meters onto the 30m grid (bilinear) and clamps
//! into 7DTD's 0..255 block band.

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const stock_paths = @import("../util/stock_paths.zig");

pub const cog_header_len: usize = 64 * 1024;
/// Copernicus GLO-30 COG decode tile edge, 1024 px (dem.zig header).
pub const tile_px: u32 = 1024;
pub const grid_px: u32 = 3600; // 1 degree at ~30m
pub const tiles_per_side: u32 = 4; // ceil(3600/1024)

pub const CogInfo = struct {
    width: u32 = 0,
    height: u32 = 0,
    tile_w: u32 = 0,
    tile_h: u32 = 0,
    compression: u16 = 0,
    predictor: u16 = 0,
    tile_offsets: [tiles_per_side * tiles_per_side]u32 = @splat(0),
    tile_counts: [tiles_per_side * tiles_per_side]u32 = @splat(0),
    tile_n: u32 = 0,
};

pub const ParseError = error{ BadMagic, BadIfd, BadInflate, Unsupported };

/// Parse the first-64KiB header of a GLO-30 COG (full IFD level 0 only).
pub fn parseCogHeader(head: []const u8) ParseError!CogInfo {
    if (head.len < 16 or !std.mem.eql(u8, head[0..4], "II*\x00")) return error.BadMagic;
    const ifd_off = std.mem.readInt(u32, head[4..8], .little);
    if (ifd_off + 2 > head.len) return error.BadIfd;
    const n = std.mem.readInt(u16, head[ifd_off..][0..2], .little);
    var info: CogInfo = .{};
    var offsets_at: u32 = 0;
    var counts_at: u32 = 0;
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        const e = ifd_off + 2 + @as(u32, i) * 12;
        if (e + 12 > head.len) return error.BadIfd;
        const tag = std.mem.readInt(u16, head[e..][0..2], .little);
        const cnt = std.mem.readInt(u32, head[e + 4 ..][0..4], .little);
        const val = std.mem.readInt(u32, head[e + 8 ..][0..4], .little);
        switch (tag) {
            256 => info.width = val,
            257 => info.height = val,
            259 => info.compression = @truncate(val),
            317 => info.predictor = @truncate(val),
            322 => info.tile_w = val,
            323 => info.tile_h = val,
            324 => {
                offsets_at = val;
                info.tile_n = cnt;
            },
            325 => counts_at = val,
            else => {},
        }
    }
    if (info.compression != 8 or info.tile_w != tile_px) return error.Unsupported;
    if (info.tile_n == 0 or info.tile_n > info.tile_offsets.len) return error.Unsupported;
    var t: u32 = 0;
    while (t < info.tile_n) : (t += 1) {
        const oo = offsets_at + t * 4;
        const co = counts_at + t * 4;
        if (oo + 4 > head.len or co + 4 > head.len) return error.BadIfd;
        info.tile_offsets[t] = std.mem.readInt(u32, head[oo..][0..4], .little);
        info.tile_counts[t] = std.mem.readInt(u32, head[co..][0..4], .little);
    }
    return info;
}

/// Undo TIFF predictor 3 (floating-point horizontal byte-plane differencing)
/// for one row of f32 samples, in place. Layout per spec: the row is stored as
/// byte planes (all b3, all b2, all b1, all b0 for LE floats) with horizontal
/// differencing applied across the plane bytes.
pub fn undoFloatPredictorRow(row: []u8, samples: u32) void {
    // 1) integrate horizontal differences across the raw row bytes
    var i: usize = 1;
    while (i < row.len) : (i += 1) row[i] +%= row[i - 1];
    // 2) de-interleave byte planes into little-endian f32s (SIMD gather).
    deinterleaveFloatPlanes(row, samples);
}

/// Pack TIFF predictor-3 byte planes into LE f32 sample bytes in `row`.
/// Scalar equivalent: `tmp[j*4+k] = row[(3-k)*s + j]` for k in 0..3.
fn deinterleaveFloatPlanes(row: []u8, samples: u32) void {
    var tmp: [tile_px * 4]u8 = undefined;
    const s: usize = samples;
    std.debug.assert(row.len >= s * 4);
    std.debug.assert(s <= tile_px);
    const lanes: usize = 16;
    var j: usize = 0;
    while (j + lanes <= s) : (j += lanes) {
        const p3: @Vector(lanes, u8) = row[j..][0..lanes].*;
        const p2: @Vector(lanes, u8) = row[s + j ..][0..lanes].*;
        const p1: @Vector(lanes, u8) = row[2 * s + j ..][0..lanes].*;
        const p0: @Vector(lanes, u8) = row[3 * s + j ..][0..lanes].*;
        // Four-way per-sample interleave [p0,p1,p2,p3] via pairwise shuffles.
        // a = interleave(p0,p1), b = interleave(p2,p3), then interleave pairs.
        const a = interleaveU8(p0, p1);
        const b = interleaveU8(p2, p3);
        const out = interleaveU8Pairs(a, b);
        tmp[j * 4 ..][0 .. lanes * 4].* = out;
    }
    while (j < s) : (j += 1) {
        tmp[j * 4 + 3] = row[j];
        tmp[j * 4 + 2] = row[s + j];
        tmp[j * 4 + 1] = row[2 * s + j];
        tmp[j * 4 + 0] = row[3 * s + j];
    }
    @memcpy(row[0 .. s * 4], tmp[0 .. s * 4]);
}

/// Interleave corresponding lanes of two 16-wide u8 vectors:
/// out = [a0,b0,a1,b1,...,a15,b15] as a 32-lane vector.
fn interleaveU8(a: @Vector(16, u8), b: @Vector(16, u8)) @Vector(32, u8) {
    return @shuffle(u8, a, b, @Vector(32, i32){
        0,  -1, 1,  -2, 2,  -3, 3,  -4, 4,  -5, 5,  -6, 6,  -7, 7,  -8,
        8,  -9, 9,  -10, 10, -11, 11, -12, 12, -13, 13, -14, 14, -15, 15, -16,
    });
}

/// Interleave 2-byte pairs from two 32-wide vectors into a 64-wide result:
/// a=[a0,a1,...], b=[b0,b1,...] → [a0,a1,b0,b1, a2,a3,b2,b3, ...].
fn interleaveU8Pairs(a: @Vector(32, u8), b: @Vector(32, u8)) @Vector(64, u8) {
    return @shuffle(u8, a, b, @Vector(64, i32){
        0,  1,  -1, -2, 2,  3,  -3, -4, 4,  5,  -5, -6, 6,  7,  -7, -8,
        8,  9,  -9, -10, 10, 11, -11, -12, 12, 13, -13, -14, 14, 15, -15, -16,
        16, 17, -17, -18, 18, 19, -19, -20, 20, 21, -21, -22, 22, 23, -23, -24,
        24, 25, -25, -26, 26, 27, -27, -28, 28, 29, -29, -30, 30, 31, -31, -32,
    });
}

/// Elevation (meters) → 7DTD block y. Sea level 60, 12m per block band above;
/// y = 60 + elev/12 clamped to [1, 250] (the clamp, not the 12m scale, is what
/// keeps extremes like Everest ~8850m in range).
pub fn elevToBlockY(elev_m: f32) u8 {
    if (std.math.isNan(elev_m)) return 60;
    const y = 60.0 + elev_m / 12.0;
    if (y < 1) return 1;
    if (y > 250) return 250;
    return @trunc(y);
}

/// Batch `elevToBlockY` over a contiguous elevation plane. Hot DEM tile path.
/// Scalar equivalent: `out[i] = elevToBlockY(elev[i])`.
pub fn elevToBlockYPlane(elev: []const f32, out: []u8) void {
    std.debug.assert(out.len >= elev.len);
    const lanes: usize = 8;
    const V = @Vector(lanes, f32);
    const sea: V = @splat(60.0);
    const inv12: V = @splat(1.0 / 12.0);
    const lo: V = @splat(1.0);
    const hi: V = @splat(250.0);
    const nan_y: @Vector(lanes, u8) = @splat(60);
    var i: usize = 0;
    while (i + lanes <= elev.len) : (i += lanes) {
        const e: V = elev[i..][0..lanes].*;
        const nan = e != e;
        const y = sea + e * inv12;
        const clamped = @max(lo, @min(y, hi));
        const bytes: @Vector(lanes, u8) = @intFromFloat(@trunc(clamped));
        out[i..][0..lanes].* = @select(u8, nan, nan_y, bytes);
    }
    while (i < elev.len) : (i += 1) {
        out[i] = elevToBlockY(elev[i]);
    }
}

/// Decode one DEFLATE tile blob into f32 heights (tile_px*tile_px).
pub fn decodeTile(allocator: std.mem.Allocator, blob: []const u8, out: []f32) !void {
    if (out.len < tile_px * tile_px) return error.Unsupported;
    const raw_len: usize = @as(usize, tile_px) * tile_px * 4;
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);

    var in: std.Io.Reader = .fixed(blob);
    var decomp_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp: std.compress.flate.Decompress = .init(&in, .zlib, &decomp_buf);
    var written: usize = 0;
    while (written < raw_len) {
        const nread = decomp.reader.readSliceShort(raw[written..]) catch return error.BadInflate;
        if (nread == 0) break;
        written += nread;
    }
    if (written < raw_len) return error.BadInflate;

    // predictor 3 per row
    var y: u32 = 0;
    while (y < tile_px) : (y += 1) {
        const row = raw[@as(usize, y) * tile_px * 4 ..][0 .. tile_px * 4];
        undoFloatPredictorRow(row, tile_px);
        var x: u32 = 0;
        while (x < tile_px) : (x += 1) {
            const b = row[@as(usize, x) * 4 ..][0..4];
            out[@as(usize, y) * tile_px + x] = @bitCast(std.mem.readInt(u32, b, .little));
        }
    }
}

/// S3 object key for a 1x1 degree GLO-30 tile ("N45"/"W006" style).
pub fn tileKey(buf: []u8, lat: i32, lon: i32) ![]const u8 {
    const ns: u8 = if (lat >= 0) 'N' else 'S';
    const ew: u8 = if (lon >= 0) 'E' else 'W';
    const alat: u32 = @abs(lat);
    const alon: u32 = @abs(lon);
    return std.fmt.bufPrint(
        buf,
        "Copernicus_DSM_COG_10_{c}{d:0>2}_00_{c}{d:0>3}_00_DEM/Copernicus_DSM_COG_10_{c}{d:0>2}_00_{c}{d:0>3}_00_DEM.tif",
        .{ ns, alat, ew, alon, ns, alat, ew, alon },
    );
}

/// Map world meters (block units) to lat/lon around an anchor. 7DTD blocks are
/// 1m; GLO-30 is ~30m/px, so world meters / 30 = DEM pixels.
pub const Anchor = struct {
    lat: f64, // degrees, world origin
    lon: f64,
};

test "cog header parses live GLO-30 sample" {
    // Sample fetched 2026-07-22 (first 64KiB); skip when absent (offline CI).
    const path = stock_paths.scratch("/glo30_head.bin");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    const raw = try io_fs.readFileAll(std.testing.allocator, path);
    defer std.testing.allocator.free(raw);
    if (raw.len == 0) return error.SkipZigTest;
    var head: [cog_header_len]u8 = undefined;
    const nr = @min(raw.len, head.len);
    @memcpy(head[0..nr], raw[0..nr]);
    const info = try parseCogHeader(head[0..nr]);
    try std.testing.expectEqual(@as(u32, 3600), info.width);
    try std.testing.expectEqual(@as(u32, 1024), info.tile_w);
    try std.testing.expectEqual(@as(u16, 8), info.compression);
    try std.testing.expectEqual(@as(u16, 3), info.predictor);
    try std.testing.expectEqual(@as(u32, 16), info.tile_n);
    try std.testing.expect(info.tile_offsets[0] > 0);
    try std.testing.expect(info.tile_counts[0] > 0);
}

test "tile key format" {
    var buf: [160]u8 = undefined;
    const k = try tileKey(&buf, 45, 6);
    try std.testing.expect(std.mem.find(u8, k, "N45_00_E006_00") != null);
    const k2 = try tileKey(&buf, -33, -70);
    try std.testing.expect(std.mem.find(u8, k2, "S33_00_W070_00") != null);
}

test "decode tile classifies corrupt deflate data" {
    const out = try std.testing.allocator.alloc(f32, tile_px * tile_px);
    defer std.testing.allocator.free(out);
    try std.testing.expectError(error.BadInflate, decodeTile(std.testing.allocator, &.{ 0x78, 0x9c }, out));
}

test "elev to block y clamps" {
    try std.testing.expectEqual(@as(u8, 60), elevToBlockY(0));
    try std.testing.expectEqual(@as(u8, 250), elevToBlockY(9000));
    try std.testing.expectEqual(@as(u8, 1), elevToBlockY(-2000));
}

test "elevToBlockYPlane SIMD matches scalar elevToBlockY" {
    var elev: [64]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(0xde11);
    const rnd = prng.random();
    for (&elev, 0..) |*e, i| {
        e.* = switch (i % 7) {
            0 => std.math.nan(f32),
            1 => -5000,
            2 => 12000,
            else => rnd.float(f32) * 4000 - 500,
        };
    }
    var simd_out: [64]u8 = undefined;
    var scalar_out: [64]u8 = undefined;
    elevToBlockYPlane(&elev, &simd_out);
    for (elev, &scalar_out) |e, *o| o.* = elevToBlockY(e);
    try std.testing.expectEqualSlices(u8, &scalar_out, &simd_out);
}

test "deinterleaveFloatPlanes SIMD matches scalar plane pack" {
    const samples: u32 = 48; // not a multiple of 16 alone for the tail; 48 = 3*16
    var row: [48 * 4]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x71ff);
    prng.random().bytes(&row);

    var simd_row = row;
    deinterleaveFloatPlanes(&simd_row, samples);

    var scalar_row = row;
    {
        var tmp: [48 * 4]u8 = undefined;
        const s: usize = samples;
        var j: usize = 0;
        while (j < s) : (j += 1) {
            tmp[j * 4 + 3] = scalar_row[j];
            tmp[j * 4 + 2] = scalar_row[s + j];
            tmp[j * 4 + 1] = scalar_row[2 * s + j];
            tmp[j * 4 + 0] = scalar_row[3 * s + j];
        }
        @memcpy(scalar_row[0 .. s * 4], tmp[0 .. s * 4]);
    }
    try std.testing.expectEqualSlices(u8, &scalar_row, &simd_row);
}

test "deinterleaveFloatPlanes handles non-multiple-of-16 sample counts" {
    const samples: u32 = 20;
    var row: [20 * 4]u8 = undefined;
    @memset(&row, 0xA5);
    row[0] = 1;
    row[20] = 2;
    row[40] = 3;
    row[60] = 4;
    var simd_row = row;
    deinterleaveFloatPlanes(&simd_row, samples);
    // Sample 0 LE bytes come from planes at offsets 3s,2s,s,0 → 4,3,2,1
    try std.testing.expectEqual(@as(u8, 4), simd_row[0]);
    try std.testing.expectEqual(@as(u8, 3), simd_row[1]);
    try std.testing.expectEqual(@as(u8, 2), simd_row[2]);
    try std.testing.expectEqual(@as(u8, 1), simd_row[3]);
}
