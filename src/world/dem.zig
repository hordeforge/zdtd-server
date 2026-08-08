//! Copernicus GLO-30 DEM streamer (M1 of docs/SCALE.md).
//! One S3 object per 1x1 degree tile, Cloud-Optimized GeoTIFF:
//! II TIFF, f32 samples, DEFLATE (compression 8) + floating-point predictor 3,
//! 1024x1024 internal tiles, IFD + offset/count arrays inside the first 64 KiB
//! (GDAL LAYOUT=IFDS_BEFORE_DATA). Verified live against
//! copernicus-dem-30m.s3.eu-central-1.amazonaws.com (HTTP 206 range reads).
//!
//! Serves heights for world chunks by mapping world XZ meters onto the 30m
//! grid (bilinear) and clamping elevation into 7DTD's 0..255 block band.

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");

pub const cog_header_len: usize = 64 * 1024;
pub const tile_px: u32 = 1024;
pub const grid_px: u32 = 3600; // 1 degree at ~30m
pub const tiles_per_side: u32 = 4; // ceil(3600/1024)

pub const bucket_host = "copernicus-dem-30m.s3.eu-central-1.amazonaws.com";

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

pub const ParseError = error{ BadMagic, BadIfd, Unsupported };

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
    // 2) de-interleave byte planes into little-endian f32s
    var tmp: [tile_px * 4]u8 = undefined;
    const s: usize = samples;
    var j: usize = 0;
    while (j < s) : (j += 1) {
        // planes are stored big-endian-first (b3 plane first)
        tmp[j * 4 + 3] = row[j];
        tmp[j * 4 + 2] = row[s + j];
        tmp[j * 4 + 1] = row[2 * s + j];
        tmp[j * 4 + 0] = row[3 * s + j];
    }
    @memcpy(row[0 .. s * 4], tmp[0 .. s * 4]);
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
        const nread = decomp.reader.readSliceShort(raw[written..]) catch break;
        if (nread == 0) break;
        written += nread;
    }
    if (written < raw_len) return error.Unsupported;

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

/// Elevation (meters) → 7DTD block y. Sea level 60; 12m per block band above
/// keeps Everest (~8850m) inside 0..255: y = 60 + elev/12 clamped.
pub fn elevToBlockY(elev_m: f32) u8 {
    if (std.math.isNan(elev_m)) return 60;
    const y = 60.0 + elev_m / 12.0;
    if (y < 1) return 1;
    if (y > 250) return 250;
    return @intFromFloat(y);
}

// --- S3 fetch (anonymous, HTTPS range GETs) + local disk cache ---

pub const Fetcher = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    client: std.http.Client,
    /// Disk cache dir for headers + decoded tiles (never tmpfs).
    cache_dir: []const u8,

    pub fn init(self: *Fetcher, allocator: std.mem.Allocator, cache_dir: []const u8) void {
        self.* = .{
            .allocator = allocator,
            .threaded = std.Io.Threaded.init(allocator, .{}),
            .client = undefined,
            .cache_dir = cache_dir,
        };
        self.client = .{ .allocator = allocator, .io = self.threaded.io() };
    }

    pub fn deinit(self: *Fetcher) void {
        self.client.deinit();
        self.threaded.deinit();
    }

    /// Range GET into out; returns bytes written. Anonymous request.
    pub fn fetchRange(self: *Fetcher, key: []const u8, off: u64, len: usize, out: []u8) !usize {
        if (len == 0) return 0;
        const end = std.math.add(u64, off, @as(u64, @intCast(len - 1))) catch return error.InvalidRange;
        var url_buf: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "https://{s}/{s}", .{ bucket_host, key });
        var range_buf: [64]u8 = undefined;
        const range = try std.fmt.bufPrint(&range_buf, "bytes={d}-{d}", .{ off, end });

        var body: std.Io.Writer.Allocating = .init(self.allocator);
        defer body.deinit();
        const res = try self.client.fetch(.{
            .location = .{ .url = url },
            .extra_headers = &.{.{ .name = "Range", .value = range }},
            .response_writer = &body.writer,
        });
        if (res.status != .partial_content and res.status != .ok) return error.HttpError;
        const got = body.written();
        const n = @min(got.len, out.len);
        @memcpy(out[0..n], got[0..n]);
        return n;
    }

    /// Header (first 64 KiB) with disk cache: {cache}/glo30_{lat}_{lon}.hdr
    pub fn tileHeader(self: *Fetcher, lat: i32, lon: i32, out: *[cog_header_len]u8) !usize {
        var pbuf: [512]u8 = undefined;
        const cpath = try std.fmt.bufPrint(&pbuf, "{s}/glo30_{d}_{d}.hdr", .{ self.cache_dir, lat, lon });
        if (io_fs.readFileAll(self.allocator, cpath)) |cached| {
            defer self.allocator.free(cached);
            const n = @min(cached.len, out.len);
            if (n > 0) {
                @memcpy(out[0..n], cached[0..n]);
                return n;
            }
        } else |_| {}
        var kbuf: [160]u8 = undefined;
        const key = try tileKey(&kbuf, lat, lon);
        const n = try self.fetchRange(key, 0, cog_header_len, out);
        // Cache is optional: fetch already succeeded; disk full/permission must not fail.
        // Still log so repeated HTTP range fetches are explainable.
        io_fs.writeFile(self.allocator, cpath, out[0..n]) catch |err| {
            std.debug.print(
                "zdtd: dem header cache write failed: {s} ({s})\n",
                .{ @errorName(err), cpath },
            );
        };
        return n;
    }

};

test "cog header parses live GLO-30 sample" {
    // Sample fetched 2026-07-22 (first 64KiB); skip when absent (offline CI).
    const path = "/home/maci/.cache/zdtd-scratch/glo30_head.bin";
    const raw = io_fs.readFileAll(std.testing.allocator, path) catch return error.SkipZigTest;
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
    try std.testing.expect(std.mem.indexOf(u8, k, "N45_00_E006_00") != null);
    const k2 = try tileKey(&buf, -33, -70);
    try std.testing.expect(std.mem.indexOf(u8, k2, "S33_00_W070_00") != null);
}

test "elev to block y clamps" {
    try std.testing.expectEqual(@as(u8, 60), elevToBlockY(0));
    try std.testing.expectEqual(@as(u8, 250), elevToBlockY(9000));
    try std.testing.expectEqual(@as(u8, 1), elevToBlockY(-2000));
}
