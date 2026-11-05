//! Stock NetPackageSignDataResponse body builder (prefab sign libraries).
//! Entry data (`SignEntry`, catalog load) lives in assets/signs.zig; only the
//! wire encode lives here so assets stays free of wire dependencies.

const std = @import("std");
const binary = @import("binary.zig");
const signs = @import("../assets/signs.zig");
const stock_paths = @import("../util/stock_paths.zig");

pub const SignEntry = signs.SignEntry;

/// Cap for the `data` blob of one response batch. Stock cuts at
/// `cSignSyncBatchBytes` = 1 MiB; zdtd cuts at 48 KiB because batches build
/// into the 512 KiB `body_buf` and the client reassembles by `isLastBatch`
/// either way, more batches, same drawings.
pub const max_batch_payload: usize = 48 * 1024;

/// `SignData.Write` binary version the b18 client stamps and reads
/// (`cCurrentBinaryVersion`; signs.md §2). `Read` rejects a blob whose version
/// is out of 1..=3, so this head must be present or the client drops the entry.
pub const sign_data_version: i32 = 3;

/// `SignData.SignSharing.Private` (gameplay/signs.md §5): the default, and the
/// one mode the join download withholds from another player's client.
pub const sharing_private: u8 = 0;

/// The `sharing` byte from a serialized `SignData` head, or null when the blob
/// is too short to carry it (fail closed: callers treat null as Private).
/// Head order is `version i32 | guid 16 | name string | ticks i64 | nextPoly,
/// nextText, nextNoise, nextGroup i32 | sharing u8` (gameplay/signs.md §2).
pub fn blobSharing(blob: []const u8) ?u8 {
    var r: binary.Reader = .{ .data = blob };
    _ = r.readI32() catch return null; // version
    if (r.remaining() < 16) return null;
    r.pos += 16; // guid
    r.skipString() catch return null; // name
    _ = r.readI64() catch return null; // lastModified
    var i: usize = 0;
    while (i < 4) : (i += 1) _ = r.readI32() catch return null;
    return r.readByte() catch null;
}

/// Encode SignData with its layer stack (research gameplay/signs.md §2):
/// version, guid, name, ticks, four next-ids, sharing byte, layer count, then
/// each layer as TypeId byte + InternalWrite payload + shared tail. A layer
/// that fails to encode aborts the entry (fail closed) rather than sending a
/// truncated drawing.
pub fn writeSignData(w: *binary.Writer, e: SignEntry) !void {
    try w.writeI32(sign_data_version); // version head (b18, signs.md §2)
    try w.writeBytes(&e.guid);
    try w.writeString(e.name);
    try w.writeI64(e.modified_ticks);
    try w.writeI32(e.next_poly);
    try w.writeI32(e.next_text);
    try w.writeI32(e.next_noise);
    try w.writeI32(e.next_group);
    try w.writeByte(e.sharing); // SignSharing: Private=0, Selectable=1, Copyable=2
    try w.writeI32(@intCast(e.layers.len));
    for (e.layers) |l| try writeLayer(w, l);
}

/// One layer: TypeId byte, InternalWrite payload, then the shared tail
/// (name, transform pos/rot/scale, render color+mode, warp count + warps).
fn writeLayer(w: *binary.Writer, l: signs.Layer) !void {
    try w.writeByte(l.kind);
    switch (l.kind) {
        signs.layer_group => {
            try w.writeByte(l.b[0]);
            try w.writeF32(l.f[0]);
            try w.writeF32(l.f[1]);
            try w.writeByte(l.b[1]);
            try w.writeI32(@intCast(l.children.len));
            for (l.children) |c| try writeLayer(w, c);
        },
        signs.layer_text => {
            try w.writeString(l.text_a);
            try w.writeString(l.text_b);
            try w.writeF32(l.f[0]);
            try w.writeF32(l.f[1]);
            try w.writeF32(l.f[2]);
            try w.writeF32(l.f[3]);
        },
        signs.layer_polygon => {
            try w.writeI32(l.i[0]);
            try w.writeF32(l.f[0]);
            try w.writeF32(l.f[1]);
            try w.writeF32(l.f[2]);
            try w.writeF32(l.f[3]);
            try w.writeF32(l.f[4]);
            try w.writeByte(l.b[0]);
        },
        signs.layer_noise => {
            try w.writeI32(l.i[0]);
            try w.writeI32(l.i[1]);
            try w.writeF32(l.f[0]);
            try w.writeF32(l.f[1]);
            try w.writeF32(l.f[2]);
        },
        else => return error.Overflow,
    }
    try w.writeString(l.name);
    try w.writeF32(l.pos[0]);
    try w.writeF32(l.pos[1]);
    try w.writeF32(l.rot);
    try w.writeF32(l.scale[0]);
    try w.writeF32(l.scale[1]);
    // Unity Color: 4 floats RGBA (StreamUtils.Write(Color)).
    try w.writeF32(l.color[0]);
    try w.writeF32(l.color[1]);
    try w.writeF32(l.color[2]);
    try w.writeF32(l.color[3]);
    try w.writeByte(l.mode);
    try w.writeI32(@intCast(l.warps.len));
    for (l.warps) |x| try writeWarp(w, x);
}

/// One warp: TypeId byte + InternalWrite payload.
fn writeWarp(w: *binary.Writer, x: signs.Warp) !void {
    try w.writeByte(x.kind);
    switch (x.kind) {
        signs.warp_skew => {
            try w.writeF32(x.f[0]);
            try w.writeF32(x.f[1]);
            try w.writeF32(x.f[2]);
        },
        signs.warp_bulge => {
            try w.writeF32(x.f[0]);
            try w.writeF32(x.f[1]);
            try w.writeF32(x.f[2]);
        },
        signs.warp_twirl => {
            try w.writeF32(x.f[0]);
            try w.writeF32(x.f[1]);
            try w.writeF32(x.f[2]);
            try w.writeF32(x.f[3]);
        },
        signs.warp_kaleido => {
            try w.writeF32(x.f[0]);
            try w.writeF32(x.f[1]);
            try w.writeI32(@trunc(x.f[2]));
            try w.writeF32(x.f[3]);
            try w.writeF32(x.f[4]);
        },
        signs.warp_perspective => {
            try w.writeF32(x.f[0]);
            try w.writeF32(x.f[1]);
            try w.writeF32(x.f[2]);
            try w.writeF32(x.f[3]);
        },
        signs.warp_arc => {
            try w.writeF32(x.f[0]);
            try w.writeF32(x.f[1]);
            try w.writeF32(x.f[2]);
        },
        signs.warp_stretch => {
            try w.writeF32(x.f[0]);
            try w.writeF32(x.f[1]);
            try w.writeF32(x.f[2]);
            try w.writeF32(x.f[3]);
            try w.writeF32(x.f[4]);
            try w.writeF32(x.f[5]);
        },
        signs.warp_grid => {
            try w.writeI32(@trunc(x.f[0]));
            try w.writeF32(x.f[1]);
            try w.writeF32(x.f[2]);
            try w.writeF32(x.f[3]);
            try w.writeF32(x.f[4]);
            try w.writeF32(x.f[5]);
        },
        else => return error.Overflow,
    }
}

/// One NetPackageSignDataResponse body: isLastBatch + dataLen + data.
/// `data` layout: u32 size_marker (includes 4 + payload), then (library, SignData)* .
pub fn buildSignDataResponseBatch(
    buf: []u8,
    entries: []const SignEntry,
    start: usize,
    is_last: bool,
) !struct { body: []u8, next: usize } {
    if (buf.len < 32) return error.Overflow;
    // Reserve: bool(1) + i32 dataLen(4) + u32 size(4) + payload
    const data_start: usize = 1 + 4;
    const size_off = data_start;
    const payload_off = size_off + 4;
    if (payload_off >= buf.len) return error.Overflow;

    var w: binary.Writer = .{ .buf = buf, .pos = payload_off };
    var i = start;
    while (i < entries.len) : (i += 1) {
        const before = w.pos;
        writeSignEntry(&w, entries[i]) catch {
            w.pos = before;
            break;
        };
        // keep under max_batch_payload for the data blob
        if (w.pos - data_start > max_batch_payload and i > start) {
            w.pos = before;
            break;
        }
    }
    // if nothing fit and we have entries left, force one
    if (i == start and start < entries.len) {
        w.pos = payload_off;
        try writeSignEntry(&w, entries[start]);
        i = start + 1;
    }

    const end_pos = w.pos;
    const size_incl: u32 = @intCast(end_pos - size_off); // includes the u32 size field
    std.mem.writeInt(u32, buf[size_off..][0..4], size_incl, .little);

    const data_len: i32 = @intCast(end_pos - data_start);
    buf[0] = @intFromBool(is_last and i >= entries.len);
    std.mem.writeInt(i32, buf[1..5], data_len, .little);
    return .{ .body = buf[0..end_pos], .next = i };
}

/// A `(libraryId, raw SignData blob)` pair for the player-library batch.
pub const RawSignEntry = struct { library_id: []const u8, blob: []const u8 };

/// Build one `NetPackageSignDataResponse` batch over player-library signs
/// (V3.3.0 b18; `../7dtd-engine-research/docs/gameplay/signs.md` §7, join shape
/// `../7dtd-engine-research/docs/network/protocol-packages.md` §1.5.7): the
/// payload is `[string libraryId, SignData.Read] x N` and each blob is already a
/// serialized `SignData` (the client sent it as one), so it is written verbatim
/// rather than re-encoded. Same envelope as `buildSignDataResponseBatch`
/// (isLast | dataLen | u32 size marker | payload).
pub fn buildSignDataResponseBatchRaw(
    buf: []u8,
    entries: []const RawSignEntry,
    start: usize,
    is_last: bool,
) !struct { body: []u8, next: usize } {
    if (buf.len < 32) return error.Overflow;
    const data_start: usize = 1 + 4;
    const size_off = data_start;
    const payload_off = size_off + 4;
    if (payload_off >= buf.len) return error.Overflow;

    var w: binary.Writer = .{ .buf = buf, .pos = payload_off };
    var i = start;
    while (i < entries.len) : (i += 1) {
        const before = w.pos;
        if (writeRawSignEntry(&w, entries[i])) |_| {} else |_| {
            w.pos = before;
            break;
        }
        if (w.pos - data_start > max_batch_payload and i > start) {
            w.pos = before;
            break;
        }
    }
    if (i == start and start < entries.len) {
        w.pos = payload_off;
        try writeRawSignEntry(&w, entries[start]);
        i = start + 1;
    }

    const end_pos = w.pos;
    const size_incl: u32 = @intCast(end_pos - size_off);
    std.mem.writeInt(u32, buf[size_off..][0..4], size_incl, .little);
    const data_len: i32 = @intCast(end_pos - data_start);
    buf[0] = @intFromBool(is_last and i >= entries.len);
    std.mem.writeInt(i32, buf[1..5], data_len, .little);
    return .{ .body = buf[0..end_pos], .next = i };
}

fn writeRawSignEntry(w: *binary.Writer, e: RawSignEntry) !void {
    try w.writeString(e.library_id);
    try w.writeBytes(e.blob);
}

fn writeSignEntry(w: *binary.Writer, e: SignEntry) !void {
    try w.writeString(e.library);
    try writeSignData(w, e);
}

/// A parsed `NetPackageSingleSignData` body (protocol-packages.md §1.5.2):
/// `libraryId string | i32 signBlobLen | signBlob bytes`.
pub const SingleSignData = struct {
    library_id: []const u8,
    blob: []const u8,
};

/// Parse `NetPackageSingleSignData`. A non-positive `signBlobLen` yields a
/// null blob, which the caller drops (stock logs an empty blob and ignores it,
/// §1.5.2). `lib_buf` holds the decoded library id; `blob` slices `body`.
pub fn parseSingleSignData(body: []const u8, lib_buf: []u8) !SingleSignData {
    var r: binary.Reader = .{ .data = body };
    const lib = try r.readString(lib_buf);
    const blob_len = try r.readI32();
    if (blob_len <= 0) return .{ .library_id = lib, .blob = &.{} };
    const n: usize = @intCast(blob_len);
    if (n > r.remaining()) return error.EndOfStream;
    const blob = r.data[r.pos..][0..n];
    return .{ .library_id = lib, .blob = blob };
}

/// A parsed `NetPackageSignDelete` body (protocol-packages.md §1.5.3):
/// `GlobalSignId` = `libraryId string | 16 raw Guid bytes`.
pub const SignDelete = struct {
    library_id: []const u8,
    sign_guid: [16]u8,
};

/// Parse `NetPackageSignDelete`. Fails closed on a truncated guid.
pub fn parseSignDelete(body: []const u8, lib_buf: []u8) !SignDelete {
    var r: binary.Reader = .{ .data = body };
    const lib = try r.readString(lib_buf);
    if (r.remaining() < 16) return error.EndOfStream;
    var guid: [16]u8 = undefined;
    @memcpy(&guid, r.data[r.pos..][0..16]);
    r.pos += 16;
    return .{ .library_id = lib, .sign_guid = guid };
}

test "sign blob sharing head is readable and truncated heads fail closed" {
    const e = [_]SignEntry{.{
        .library = "Steam_1001",
        .name = "drawing",
        .guid = @splat(0x44),
        .sharing = 2,
    }};
    var buf: [256]u8 = undefined;
    const r = try buildSignDataResponseBatch(&buf, &e, 0, true);
    // Body: isLast | dataLen | size marker | library string | SignData.
    var rd: binary.Reader = .{ .data = r.body[9..] };
    var s_buf: [32]u8 = undefined;
    _ = try rd.readString(&s_buf);
    try std.testing.expectEqual(@as(?u8, 2), blobSharing(rd.data[rd.pos..]));
    // A blob cut before the sharing byte is Private, never guessed. The tail
    // after sharing is the layer count (i32), so cutting it and the byte gives
    // the head the filter sees on a truncated push.
    const head_len = rd.data.len - rd.pos;
    try std.testing.expectEqual(@as(?u8, null), blobSharing(rd.data[rd.pos..][0 .. head_len - 5]));
    try std.testing.expectEqual(@as(?u8, null), blobSharing(&[_]u8{ 3, 0, 0, 0 }));
}

test "raw sign batch writes libraryId and verbatim blob" {
    const blob = [_]u8{ 3, 0, 0, 0, 1, 2, 3, 4 };
    const entries = [_]RawSignEntry{
        .{ .library_id = "Steam_1001", .blob = &blob },
    };
    var buf: [256]u8 = undefined;
    const r = try buildSignDataResponseBatchRaw(&buf, &entries, 0, true);
    try std.testing.expectEqual(@as(usize, 1), r.next);
    try std.testing.expectEqual(@as(u8, 1), r.body[0]); // isLast
    // Payload: library string, then the blob verbatim.
    var rd: binary.Reader = .{ .data = r.body[9..] };
    var s_buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Steam_1001", try rd.readString(&s_buf));
    try std.testing.expectEqualSlices(u8, &blob, rd.data[rd.pos..][0..blob.len]);
    rd.pos += blob.len;
    try std.testing.expectEqual(@as(usize, 0), rd.remaining());
}

test "sign batch empty layers" {
    var g: [16]u8 = @splat(0);
    g[0] = 1;
    // The four next_* counters and modified_ticks default to 0, which left
    // them indistinguishable from each other and from the literal 0 layer
    // count written beside them.
    const e = [_]SignEntry{.{
        .library = "house_01",
        .name = "Front",
        .guid = g,
        .next_poly = 11,
        .next_text = 12,
        .next_noise = 13,
        .next_group = 14,
        .modified_ticks = 0x0102030405060708,
    }};
    var buf: [4096]u8 = undefined;
    const r = try buildSignDataResponseBatch(&buf, &e, 0, true);
    try std.testing.expect(r.body[0] == 1); // last
    try std.testing.expectEqual(@as(usize, 1), r.next);
    const dlen = std.mem.readInt(i32, r.body[1..5], .little);
    try std.testing.expect(dlen > 4);

    // SignData is positional: isLast | dataLen i32 | size marker u32 |
    // library string | version i32 | guid[16] | name string | ticks i64 |
    // nextPoly | nextText | nextNoise | nextGroup | sharing u8 | layer count.
    var rd: binary.Reader = .{ .data = r.body[9..] }; // past isLast, dataLen, marker
    var s_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("house_01", try rd.readString(&s_buf));
    try std.testing.expectEqual(@as(i32, sign_data_version), try rd.readI32()); // version
    try std.testing.expectEqualSlices(u8, &g, rd.data[rd.pos..][0..16]);
    rd.pos += 16;
    try std.testing.expectEqualStrings("Front", try rd.readString(&s_buf));
    try std.testing.expectEqual(@as(i64, 0x0102030405060708), try rd.readI64());
    try std.testing.expectEqual(@as(i32, 11), try rd.readI32()); // nextPoly
    try std.testing.expectEqual(@as(i32, 12), try rd.readI32()); // nextText
    try std.testing.expectEqual(@as(i32, 13), try rd.readI32()); // nextNoise
    try std.testing.expectEqual(@as(i32, 14), try rd.readI32()); // nextGroup
    try std.testing.expectEqual(@as(u8, 0), try rd.readByte()); // sharing (Private)
    try std.testing.expectEqual(@as(i32, 0), try rd.readI32()); // layer count
    try std.testing.expectEqual(@as(usize, 0), rd.remaining());
}

test "sign layer encode round-trips the stock field order" {
    // One polygon layer with a warp, encoded per the IL field orders
    // (PolygonSignLayer::InternalWrite IL=29, SignLayer::Write IL=54,
    // TwirlWarp::InternalWrite IL=13): TypeId, subclass payload, shared
    // tail (name, pos/rot/scale, color RGBA, mode, warp count + warps).
    const e = [_]SignEntry{.{
        .library = "lib",
        .name = "S",
        .guid = @splat(0),
        .layers = &[_]signs.Layer{.{
            .kind = signs.layer_polygon,
            .name = "p",
            .pos = .{ 1, 2 },
            .rot = 3,
            .scale = .{ 4, 5 },
            .color = .{ 0.5, 0.25, 1, 0 },
            .mode = signs.mode_color_and_mask,
            .warps = &[_]signs.Warp{.{ .kind = signs.warp_twirl, .f = .{ 6, 7, 8, 9, 0, 0 } }},
            .f = .{ 0, 0, 0, 0, 10, 11, 0 },
            .i = .{ 4, 0 },
            .b = .{ 1, 0 },
        }},
    }};
    var buf: [1024]u8 = undefined;
    const r = try buildSignDataResponseBatch(&buf, &e, 0, true);
    try std.testing.expectEqual(@as(usize, 1), r.next);
    var rd: binary.Reader = .{ .data = r.body[9..] };
    var s_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("lib", try rd.readString(&s_buf));
    rd.pos += 4; // version head
    rd.pos += 16; // guid
    try std.testing.expectEqualStrings("S", try rd.readString(&s_buf));
    rd.pos += 8 + 16; // ticks + four next-ids
    rd.pos += 1; // sharing byte
    try std.testing.expectEqual(@as(i32, 1), try rd.readI32()); // layer count
    try std.testing.expectEqual(@as(u8, 2), try rd.readByte()); // polygon TypeId
    try std.testing.expectEqual(@as(i32, 4), try rd.readI32()); // sides
    for ([_]f32{ 0, 0, 0, 0, 10 }) |want| try std.testing.expectEqual(want, try rd.readF32());
    try std.testing.expectEqual(@as(u8, 1), try rd.readByte()); // shapeMode
    try std.testing.expectEqualStrings("p", try rd.readString(&s_buf));
    for ([_]f32{ 1, 2, 3, 4, 5 }) |want| try std.testing.expectEqual(want, try rd.readF32());
    for ([_]f32{ 0.5, 0.25, 1, 0 }) |want| try std.testing.expectEqual(want, try rd.readF32());
    try std.testing.expectEqual(@as(u8, 1), try rd.readByte()); // ColorAndMask
    try std.testing.expectEqual(@as(i32, 1), try rd.readI32()); // warp count
    try std.testing.expectEqual(@as(u8, 2), try rd.readByte()); // twirl TypeId
    for ([_]f32{ 6, 7, 8, 9 }) |want| try std.testing.expectEqual(want, try rd.readF32());
    try std.testing.expectEqual(@as(usize, 0), rd.remaining());
}

test "sign batches carry the stock layered catalog" {
    // The [D] Default Sign parses ~30 layers; the batcher must emit it with
    // a nonzero layer count and correct is_last, not split or drop it.
    const gd = stock_paths.dedicated_server;
    if (!@import("../util/io_fs.zig").dirExists(gd)) return error.SkipZigTest;
    var path_buf: [2048]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, "{s}/Data/Prefabs", .{gd});
    var cfg_buf: [2048]u8 = undefined;
    const cfg = try std.fmt.bufPrint(&cfg_buf, "{s}/Data/Config/signs.xml", .{gd});
    var cat = try signs.loadFromPrefabsRoot(std.testing.allocator, p, cfg);
    defer cat.deinit();
    try std.testing.expect(cat.entries.len > 0);
    var buf: [128 * 1024]u8 = undefined;
    var start: usize = 0;
    var batches: usize = 0;
    var layered: usize = 0;
    while (start < cat.entries.len) {
        const last = start + 1 >= cat.entries.len;
        const r = try buildSignDataResponseBatch(&buf, cat.entries, start, last);
        try std.testing.expect(r.next > start);
        for (cat.entries[start..r.next]) |e| {
            if (e.layers.len > 0) layered += 1;
        }
        batches += 1;
        start = r.next;
        if (batches > 4096) return error.TestUnexpectedResult;
    }
    try std.testing.expect(layered > 0);
    try std.testing.expect(start == cat.entries.len);
}
