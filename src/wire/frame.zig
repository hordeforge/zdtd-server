//! Game channel envelope + inner packages (stock NetConnectionSimple layout).

const std = @import("std");
const binary = @import("binary.zig");
const protocol = @import("../protocol.zig");
const flate = std.compress.flate;

/// Re-export wire constants (single source of truth in protocol.zig).
pub const challenge_marker = protocol.challenge_marker;
pub const challenge_size = protocol.challenge_size;

/// Inflate window for C2S compressed envelopes (stock Noemax deflate).
const inflate_cap: usize = 512 * 1024;

/// Expansion ceiling per envelope. Without it a ~1.3 KiB datagram can force a
/// full 512 KiB inflate plus a package-stream scan, ~400x amplification per
/// packet. Stock package streams compress nowhere near this ratio.
const max_inflate_ratio: usize = 64;

/// Holds last inflated package stream so Package.body slices remain valid
/// until the next parseChannelPayload call. Nested parseChannelPayload that
/// needs inflate fails closed (see parse_depth) so bodies of the outer parse
/// are not clobbered. Game.onData also holds `pumping` to avoid nested parse.
var inflate_storage: [inflate_cap]u8 = undefined;
/// In-flight parseChannelPayload nesting depth (single-threaded game loop).
var parse_depth: u8 = 0;

pub const Package = struct {
    id: u16,
    body: []const u8,
};

pub fn isChallenge(data: []const u8) bool {
    return protocol.challengeEchoValid(data);
}

pub fn buildChallenge(out: *[challenge_size]u8, guid: [16]u8) void {
    out.*[0] = challenge_marker;
    @memcpy(out.*[1..17], &guid);
}

/// Inflate stock C2S compressed payload. Header-sniff picks the container so
/// the common case decompresses in one pass; the others stay as fallback.
fn inflatePayload(src: []const u8) ?[]const u8 {
    // Nested parse (parse_depth > 1) would overwrite inflate_storage while an
    // outer Package.body still aliases it. Fail closed; same as corrupt deflate.
    if (parse_depth > 1) return null;

    const first: flate.Container = if (src.len >= 2 and src[0] == 0x1f and src[1] == 0x8b)
        .gzip
    else if (src.len >= 2 and src[0] & 0x0f == 8 and (@as(u16, src[0]) << 8 | src[1]) % 31 == 0)
        .zlib
    else
        .raw;
    // A confident sniff (gzip magic / valid zlib header) is authoritative: a
    // late failure means the stream is malformed, and re-inflating it as the
    // other containers costs up to 3 more full passes over attacker-controlled
    // input. Only the inconclusive .raw sniff keeps the fallback attempts
    // (their header checks fail immediately on genuine raw-deflate data).
    const containers: []const flate.Container = if (first == .raw)
        &.{ .raw, .zlib, .gzip }
    else
        &.{first};
    const cap = @min(inflate_cap, src.len *| max_inflate_ratio);
    for (containers) |container| {
        var in: std.Io.Reader = .fixed(src);
        var out: std.Io.Writer = .fixed(inflate_storage[0..cap]);
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
/// Not reentrant for compressed envelopes: nested calls that need inflate
/// return 0 so outer Package.body slices into inflate_storage stay valid.
pub fn parseChannelPayload(data: []const u8, out: []Package) usize {
    parse_depth +%= 1;
    defer parse_depth -%= 1;

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
        const inflated = inflatePayload(raw) orelse return 0;
        break :blk inflated;
    } else raw;

    return parsePackageStream(stream, count, out);
}

/// Bytes before the (possibly compressed) package stream: channel + payload
/// size + compressed + encrypted + package count.
pub const envelope_len: usize = 9;

/// Single-package envelope with the stock `compressed` flag set. The package
/// stream is raw-deflated the way `NetConnectionAbs::Compress` does it
/// (asm.il 788600-788684, Noemax DeflateOutputStream), and the client picks the
/// inflate path off the same per-envelope flag (asm.il 792605); `payload_size`
/// counts the compressed bytes, since that is what the receive loop slices
/// before handing the buffer to `Decompress` (asm.il 788690-788728).
///
/// Streaming rather than body-in, bytes-out: the only package that needs this is
/// the full "blocks" NameIdMapping, ~950 KB uncompressed, which fits no body
/// buffer. `body_len` must therefore be known before the first byte is pushed.
///
/// Pinned between `begin` and `finish`: `comp` holds a pointer to `sink`, so the
/// struct must not be copied or moved once begun.
pub const DeflateFramer = struct {
    buf: []u8,
    sink: std.Io.Writer,
    comp: flate.Compress,

    /// Window the deflate matcher needs; callers own the storage.
    pub const window_len: usize = flate.max_window_len;

    pub fn begin(
        self: *DeflateFramer,
        buf: []u8,
        window: []u8,
        channel: u8,
        pkg_id: u16,
        body_len: usize,
    ) error{Overflow}!void {
        // `Compress.init` asserts both of these; turn them into errors so a
        // mis-sized caller buffer cannot panic a live server.
        if (buf.len <= envelope_len + 8) return error.Overflow;
        if (window.len < window_len) return error.Overflow;
        const content_len: usize = 2 + body_len;
        if (content_len > std.math.maxInt(i32)) return error.Overflow;

        buf[0] = channel;
        // payload_size is patched by `finish` once the deflate size is known.
        @memset(buf[1..5], 0);
        buf[5] = 1; // compressed
        buf[6] = 0; // encrypted
        std.mem.writeInt(u16, buf[7..9], 1, .little); // count

        self.buf = buf;
        self.sink = .fixed(buf[envelope_len..]);
        self.comp = flate.Compress.init(&self.sink, window, .raw, .default) catch return error.Overflow;

        var head: [6]u8 = undefined;
        std.mem.writeInt(i32, head[0..4], @intCast(content_len), .little);
        std.mem.writeInt(u16, head[4..6], pkg_id, .little);
        self.comp.writer.writeAll(&head) catch return error.Overflow;
    }

    /// Sink for the package body. Bytes pushed here must total exactly the
    /// `body_len` passed to `begin`, or the client's package stream is short.
    pub fn writer(self: *DeflateFramer) *std.Io.Writer {
        return &self.comp.writer;
    }

    pub fn finish(self: *DeflateFramer) error{Overflow}![]u8 {
        self.comp.finish() catch return error.Overflow;
        const n = self.sink.end;
        std.mem.writeInt(i32, self.buf[1..5], @intCast(n), .little);
        return self.buf[0 .. envelope_len + n];
    }
};

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

test "DeflateFramer roundtrips through the inbound parser" {
    var window: [DeflateFramer.window_len]u8 = undefined;
    var out: [8192]u8 = undefined;
    var pkgs: [2]Package = undefined;

    // Empty body: the envelope still has to carry one parseable package.
    var fr: DeflateFramer = undefined;
    try fr.begin(&out, &window, 0, 77, 0);
    const empty = try fr.finish();
    try std.testing.expectEqual(@as(u8, 1), empty[5]);
    try std.testing.expectEqual(@as(i32, @intCast(empty.len - envelope_len)), std.mem.readInt(i32, empty[1..5], .little));
    try std.testing.expectEqual(@as(usize, 1), parseChannelPayload(empty, &pkgs));
    try std.testing.expectEqual(@as(u16, 77), pkgs[0].id);
    try std.testing.expectEqual(@as(usize, 0), pkgs[0].body.len);

    // One byte.
    try fr.begin(&out, &window, 0, 5, 1);
    try fr.writer().writeByte(0xab);
    const one = try fr.finish();
    try std.testing.expectEqual(@as(usize, 1), parseChannelPayload(one, &pkgs));
    try std.testing.expectEqualSlices(u8, &.{0xab}, pkgs[0].body);
}

test "DeflateFramer keeps a body far larger than the frame buffer" {
    var window: [DeflateFramer.window_len]u8 = undefined;
    // 200 KiB body through a 128 KiB frame buffer, at a compression ratio in the
    // same band the mapping blob lands in (~6x). That is the whole point of the
    // streaming framer: the payload never fits a body buffer uncompressed, and
    // the inbound parser's `max_inflate_ratio` guard still has to accept it.
    const body_len: usize = 200 * 1024;
    var out: [128 * 1024]u8 = undefined;
    var fr: DeflateFramer = undefined;
    try fr.begin(&out, &window, 0, 123, body_len);
    var i: usize = 0;
    while (i < body_len) : (i += 1) {
        try fr.writer().writeByte(bodyByte(i));
    }
    const framed = try fr.finish();
    try std.testing.expect(framed.len < out.len);
    try std.testing.expect(framed.len * max_inflate_ratio > body_len);

    var pkgs: [2]Package = undefined;
    try std.testing.expectEqual(@as(usize, 1), parseChannelPayload(framed, &pkgs));
    try std.testing.expectEqual(@as(u16, 123), pkgs[0].id);
    try std.testing.expectEqual(body_len, pkgs[0].body.len);
    i = 0;
    while (i < body_len) : (i += 1) {
        try std.testing.expectEqual(bodyByte(i), pkgs[0].body[i]);
    }
}

/// Partly incompressible filler: one noisy byte in four, the rest constant.
/// Wraps are deliberate: `@truncate(i)` folds a usize counter mod 2^32 before
/// the hash multiply, and taking the top byte of `h` keeps the output noisy.
fn bodyByte(i: usize) u8 {
    if (i % 4 != 0) return 0;
    const h: u32 = @as(u32, @truncate(i)) *% 2654435761;
    return @truncate(h >> 24);
}

test "DeflateFramer rejects undersized buffers and overflows instead of truncating" {
    var window: [DeflateFramer.window_len]u8 = undefined;
    var tiny: [16]u8 = undefined;
    var fr: DeflateFramer = undefined;
    try std.testing.expectError(error.Overflow, fr.begin(&tiny, &window, 0, 1, 0));

    var small_window: [8]u8 = undefined;
    var out: [4096]u8 = undefined;
    try std.testing.expectError(error.Overflow, fr.begin(&out, &small_window, 0, 1, 0));

    // Incompressible body larger than the frame buffer must fail, not truncate.
    var noise: [4096]u8 = undefined;
    var seed: u32 = 0x9e3779b9;
    for (&noise) |*b| {
        seed = seed *% 1664525 +% 1013904223;
        b.* = @truncate(seed >> 24);
    }
    var frame_buf: [256]u8 = undefined;
    try fr.begin(&frame_buf, &window, 0, 9, noise.len);
    const pushed = fr.writer().writeAll(&noise);
    const finished = if (pushed) |_| fr.finish() else |_| error.Overflow;
    try std.testing.expectError(error.Overflow, finished);
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

test "channel parser rejects malformed envelope and package lengths" {
    var pkgs: [2]Package = undefined;

    var envelope: [32]u8 = @splat(0);
    envelope[0] = 0;
    std.mem.writeInt(u16, envelope[7..9], 1, .little);

    std.mem.writeInt(i32, envelope[1..5], -1, .little);
    try std.testing.expectEqual(@as(usize, 0), parseChannelPayload(envelope[0..9], &pkgs));

    std.mem.writeInt(i32, envelope[1..5], 6, .little);
    try std.testing.expectEqual(@as(usize, 0), parseChannelPayload(envelope[0..14], &pkgs));

    std.mem.writeInt(i32, envelope[1..5], 6, .little);
    std.mem.writeInt(i32, envelope[9..13], 1, .little);
    try std.testing.expectEqual(@as(usize, 0), parseChannelPayload(envelope[0..15], &pkgs));

    envelope[6] = 1;
    std.mem.writeInt(i32, envelope[9..13], 2, .little);
    try std.testing.expectEqual(@as(usize, 0), parseChannelPayload(envelope[0..15], &pkgs));
}
