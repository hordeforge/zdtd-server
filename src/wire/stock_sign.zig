//! Stock NetPackageSignDataResponse body builder (prefab sign libraries).
//! Entry data (`SignEntry`, catalog load) lives in assets/signs.zig; only the
//! wire encode lives here so assets stays free of wire dependencies.

const std = @import("std");
const binary = @import("binary.zig");
const signs = @import("../assets/signs.zig");

pub const SignEntry = signs.SignEntry;

/// Cap for the `data` blob of one response batch. Stock cuts at
/// `cSignSyncBatchBytes` = 1 MiB; zdtd cuts at 48 KiB because batches build
/// into the 512 KiB `body_buf` and the client reassembles by `isLastBatch`
/// either way — more batches, same drawings.
pub const max_batch_payload: usize = 48 * 1024;

/// Encode SignData with its layer stack (research gameplay/signs.md §2:
/// guid, name, ticks, four next-ids, layer count, then each layer as TypeId
/// byte + InternalWrite payload + shared tail). A layer that fails to encode
/// aborts the entry (fail closed) rather than sending a truncated drawing.
pub fn writeSignData(w: *binary.Writer, e: SignEntry) !void {
    try w.writeBytes(&e.guid);
    try w.writeString(e.name);
    try w.writeI64(e.modified_ticks);
    try w.writeI32(e.next_poly);
    try w.writeI32(e.next_text);
    try w.writeI32(e.next_noise);
    try w.writeI32(e.next_group);
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
            try w.writeI32(@intFromFloat(x.f[2]));
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
            try w.writeI32(@intFromFloat(x.f[0]));
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

fn writeSignEntry(w: *binary.Writer, e: SignEntry) !void {
    try w.writeString(e.library);
    try writeSignData(w, e);
}

test "sign batch empty layers" {
    var g: [16]u8 = .{0} ** 16;
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

    // SignData is positional and nothing read it back: isLast | dataLen i32 |
    // size marker u32 | library string | guid[16] | name string | ticks i64 |
    // nextPoly | nextText | nextNoise | nextGroup | layer count, all i32.
    var rd: binary.Reader = .{ .data = r.body[9..] }; // past isLast, dataLen, marker
    var s_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("house_01", try rd.readString(&s_buf));
    try std.testing.expectEqualSlices(u8, &g, rd.data[rd.pos..][0..16]);
    rd.pos += 16;
    try std.testing.expectEqualStrings("Front", try rd.readString(&s_buf));
    try std.testing.expectEqual(@as(i64, 0x0102030405060708), try rd.readI64());
    try std.testing.expectEqual(@as(i32, 11), try rd.readI32()); // nextPoly
    try std.testing.expectEqual(@as(i32, 12), try rd.readI32()); // nextText
    try std.testing.expectEqual(@as(i32, 13), try rd.readI32()); // nextNoise
    try std.testing.expectEqual(@as(i32, 14), try rd.readI32()); // nextGroup
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
        .guid = .{0} ** 16,
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
    rd.pos += 16; // guid
    try std.testing.expectEqualStrings("S", try rd.readString(&s_buf));
    rd.pos += 8 + 16; // ticks + four next-ids
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
    const gd = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
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
