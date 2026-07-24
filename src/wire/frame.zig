//! Game channel envelope + inner packages (stock NetConnectionSimple layout).

const std = @import("std");
const binary = @import("binary.zig");
const flate = std.compress.flate;

pub const challenge_marker: u8 = 0xCA;
pub const challenge_size: usize = 17;

/// Inflate window for C2S compressed envelopes (stock Noemax deflate).
const inflate_cap: usize = 512 * 1024;

/// Holds last inflated package stream so Package.body slices remain valid
/// until the next parseChannelPayload call.
var inflate_storage: [inflate_cap]u8 = undefined;

pub const Package = struct {
    id: u16,
    body: []const u8,
};

pub fn isChallenge(data: []const u8) bool {
    return data.len == challenge_size and data[0] == challenge_marker;
}

pub fn buildChallenge(out: *[challenge_size]u8, guid: [16]u8) void {
    out.*[0] = challenge_marker;
    @memcpy(out.*[1..17], &guid);
}

/// Inflate stock C2S compressed payload (try zlib, raw, gzip).
fn inflatePayload(src: []const u8) ?[]const u8 {
    const containers = [_]flate.Container{ .zlib, .raw, .gzip };
    for (containers) |container| {
        var in: std.Io.Reader = .fixed(src);
        var out: std.Io.Writer = .fixed(&inflate_storage);
        var dec: flate.Decompress = .init(&in, container, &.{});
        const n = dec.reader.streamRemaining(&out) catch continue;
        if (n == 0) continue;
        return inflate_storage[0..n];
    }
    return null;
}

fn parsePackageStream(payload: []const u8, count: u16, out: []Package) usize {
    var po: usize = 0;
    var n: usize = 0;
    var i: u16 = 0;
    while (i < count and n < out.len) : (i += 1) {
        if (po + 6 > payload.len) break;
        const content_len: i32 = std.mem.readInt(i32, payload[po..][0..4], .little);
        if (content_len < 2) break;
        const cl: usize = @intCast(content_len);
        if (po + 4 + cl > payload.len) break;
        const id = std.mem.readInt(u16, payload[po + 4 ..][0..2], .little);
        const body = payload[po + 6 .. po + 4 + cl];
        out[n] = .{ .id = id, .body = body };
        n += 1;
        po += 4 + cl;
    }
    return n;
}

/// Parse channel-prefixed game message into packages.
/// Supports stock uncompressed and deflate-compressed (Noemax) envelopes.
/// Encrypted payloads are still rejected.
pub fn parseChannelPayload(data: []const u8, out: []Package) usize {
    if (data.len < 9) return 0;
    var o: usize = 1; // skip channel
    const payload_size: i32 = std.mem.readInt(i32, data[o..][0..4], .little);
    o += 4;
    const compressed = data[o];
    o += 1;
    const encrypted = data[o];
    o += 1;
    const count = std.mem.readInt(u16, data[o..][0..2], .little);
    o += 2;
    if (payload_size < 0) return 0;
    const ps: usize = @intCast(payload_size);
    if (o + ps > data.len) return 0;
    if (encrypted != 0) return 0;
    if (count == 0) return 0;

    const raw = data[o .. o + ps];
    const stream: []const u8 = if (compressed != 0) blk: {
        const inflated = inflatePayload(raw) orelse {
            std.debug.print("zdtd: frame inflate failed len={d} cnt={d}\n", .{ raw.len, count });
            return 0;
        };
        break :blk inflated;
    } else raw;

    const n = parsePackageStream(stream, count, out);
    if (compressed != 0 and n > 0) {
        std.debug.print("zdtd: frame inflated pkgs={d}/{d} raw={d} plain={d}\n", .{ n, count, raw.len, stream.len });
    }
    return n;
}

/// Frame one package: channel + envelope + single inner package (uncompressed).
pub fn framePackage(buf: []u8, channel: u8, pkg_id: u16, body: []const u8) error{Overflow}![]u8 {
    const content_len: usize = 2 + body.len;
    const payload_size: usize = 4 + content_len;
    const total: usize = 1 + 8 + payload_size;
    if (total > buf.len) return error.Overflow;

    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(channel);
    try w.writeI32(@intCast(payload_size));
    try w.writeByte(0); // compressed
    try w.writeByte(0); // encrypted
    try w.writeU16(1); // count
    try w.writeI32(@intCast(content_len));
    try w.writeU16(pkg_id);
    try w.writeBytes(body);
    return w.written();
}

test "frame roundtrip pos body size" {
    var body: [30]u8 = undefined;
    @memset(&body, 0);
    // minimal pos body
    var bw: binary.Writer = .{ .buf = &body };
    try bw.writeI32(42);
    try bw.writeF32(1.5);
    try bw.writeF32(2.5);
    try bw.writeF32(3.5);
    try bw.writeBool(false);
    try bw.writeF32(10);
    try bw.writeF32(20);
    try bw.writeF32(30);
    try bw.writeBool(true);
    try std.testing.expectEqual(@as(usize, 30), bw.pos);

    var frame_buf: [128]u8 = undefined;
    const framed = try framePackage(&frame_buf, 0, 99, bw.written());
    var pkgs: [4]Package = undefined;
    const n = parseChannelPayload(framed, &pkgs);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u16, 99), pkgs[0].id);
    try std.testing.expectEqual(@as(usize, 30), pkgs[0].body.len);
}

test "challenge detect" {
    var ch: [17]u8 = undefined;
    buildChallenge(&ch, .{0} ** 16);
    try std.testing.expect(isChallenge(&ch));
    try std.testing.expect(!isChallenge(ch[0..16]));
}

test "compressed zlib package stream parses" {
    // Uncompressed package stream: content_len=7, id=42, body="hello"
    // LE: 07 00 00 00 2a 00 68 65 6c 6c 6f
    // zlib (default) of that stream, captured via python zlib.compress:
    // python: zlib.compress(struct.pack('<IH',7,42)+b'hello')
    const compressed = [_]u8{
        0x78, 0x9c, 0x63, 0x67, 0x60, 0x60, 0xd0, 0x62, 0xc8, 0x48, 0xcd, 0xc9,
        0xc9, 0x07, 0x00, 0x07, 0xa5, 0x02, 0x46,
    };

    var env: [64]u8 = undefined;
    env[0] = 0;
    std.mem.writeInt(i32, env[1..5], @intCast(compressed.len), .little);
    env[5] = 1;
    env[6] = 0;
    std.mem.writeInt(u16, env[7..9], 1, .little);
    @memcpy(env[9 .. 9 + compressed.len], &compressed);
    const framed = env[0 .. 9 + compressed.len];

    var pkgs: [4]Package = undefined;
    const n = parseChannelPayload(framed, &pkgs);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u16, 42), pkgs[0].id);
    try std.testing.expectEqualStrings("hello", pkgs[0].body);
}
