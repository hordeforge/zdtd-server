//! Stock NetPackageSignDataResponse body builder (prefab sign libraries).
//! Entry data (`SignEntry`, catalog load) lives in assets/signs.zig; only the
//! wire encode lives here so assets stays free of wire dependencies.

const std = @import("std");
const binary = @import("binary.zig");
const signs = @import("../assets/signs.zig");

pub const SignEntry = signs.SignEntry;

/// Cap for the `data` blob of one response batch.
pub const max_batch_payload: usize = 48 * 1024;

/// Encode minimal SignData (zero layers).
pub fn writeSignData(w: *binary.Writer, e: SignEntry) !void {
    try w.writeBytes(&e.guid);
    try w.writeString(e.name);
    try w.writeI64(e.modified_ticks);
    try w.writeI32(e.next_poly);
    try w.writeI32(e.next_text);
    try w.writeI32(e.next_noise);
    try w.writeI32(e.next_group);
    try w.writeI32(0); // layer count
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
    const e = [_]SignEntry{.{
        .library = "house_01",
        .name = "Front",
        .guid = g,
    }};
    var buf: [4096]u8 = undefined;
    const r = try buildSignDataResponseBatch(&buf, &e, 0, true);
    try std.testing.expect(r.body[0] == 1); // last
    try std.testing.expectEqual(@as(usize, 1), r.next);
    const dlen = std.mem.readInt(i32, r.body[1..5], .little);
    try std.testing.expect(dlen > 4);
}
