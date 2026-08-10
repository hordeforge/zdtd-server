//! LiteNetLib wire packet property helpers.
//! Property ordinals match the **game** Managed LiteNetLib (7DTD V3.1.0 b14),
//! which differs from upstream LiteNetLib 1.x (no ReliableMerged slot; ConnectRequest=5).

const std = @import("std");
const constantTimeEql = @import("../util/secret.zig").constantTimeEql;

pub const protocol_id: i32 = 13;
pub const channeled_header_size: usize = 4;
/// FragmentId:u16 + FragmentPart:u16 + FragmentsTotal:u16 (after channeled header).
pub const fragment_header_size: usize = 6;
pub const fragmented_header_total: usize = channeled_header_size + fragment_header_size; // 10
/// Game LiteNetLib NetConstants.MaxPacketSize (PossibleMtu last entry).
pub const max_packet_size: usize = 1327;
/// Max user bytes in one non-fragmented channeled datagram.
pub const max_single_user: usize = max_packet_size - channeled_header_size;
/// Max user bytes per fragment part.
pub const max_fragment_user: usize = max_packet_size - fragmented_header_total;
pub const fragment_flag: u8 = 0x80;
pub const connect_request_header: usize = 18;
pub const connect_accept_size: usize = 15;
pub const max_sequence: u16 = 32768;
pub const window_size: usize = 64;

/// PacketProperty as reflected from game LiteNetLib.dll (not nuget 1.2).
pub const Property = enum(u8) {
    unreliable = 0,
    channeled = 1,
    ack = 2,
    ping = 3,
    pong = 4,
    connect_request = 5,
    connect_accept = 6,
    disconnect = 7,
    unconnected_message = 8,
    mtu_check = 9,
    mtu_ok = 10,
    broadcast = 11,
    merged = 12,
    shutdown_ok = 13,
    peer_not_found = 14,
    invalid_protocol = 15,
    nat_message = 16,
    empty = 17,
    /// Ordinals 18..31 are unassigned; keep the enum non-exhaustive so a hostile
    /// datagram cannot turn @enumFromInt into an illegal-value panic.
    _,
};

pub fn propertyOf(byte0: u8) Property {
    return @enumFromInt(byte0 & 0x1F);
}

pub fn connectionNumberOf(byte0: u8) u8 {
    return (byte0 >> 5) & 0x3;
}

pub fn makeByte0(prop: Property, conn_num: u8) u8 {
    return (@intFromEnum(prop) & 0x1F) | ((conn_num & 0x3) << 5);
}

pub const ConnectRequest = struct {
    connection_time: i64,
    connection_number: u8,
    peer_id: i32,
    data: []const u8,
};

/// Disconnect header: prop + connectTime:i64. Extra payload starts at offset 9.
pub const disconnect_header_size: usize = 9;

/// Stock NetworkServerLiteNetLib reject payloads (EAdditionalDisconnectCause in byte0).
pub const reject_invalid_password = [_]u8{ 0, 0 };
pub const reject_rate_limit = [_]u8{ 1, 0 };

pub fn parseConnectRequest(raw: []const u8) ?ConnectRequest {
    if (raw.len < connect_request_header) return null;
    if (propertyOf(raw[0]) != .connect_request) return null;
    const pid = std.mem.readInt(i32, raw[1..][0..4], .little);
    if (pid != protocol_id) return null;
    const connection_time = std.mem.readInt(i64, raw[5..][0..8], .little);
    const peer_id = std.mem.readInt(i32, raw[13..][0..4], .little);
    const addr_size: usize = raw[17];
    if (addr_size != 16 and addr_size != 28) return null;
    if (raw.len < connect_request_header + addr_size) return null;
    const data_start = connect_request_header + addr_size;
    return .{
        .connection_time = connection_time,
        .connection_number = connectionNumberOf(raw[0]),
        .peer_id = peer_id,
        .data = if (data_start < raw.len) raw[data_start..] else raw[0..0],
    };
}

/// LiteNetLib NetDataReader.GetString: u16 LE length; 0 => empty; else UTF-8 of (len-1) bytes.
pub fn readNetString(data: []const u8) ?[]const u8 {
    if (data.len < 2) return null;
    const n = std.mem.readInt(u16, data[0..2], .little);
    if (n == 0) return data[0..0];
    const byte_len: usize = n - 1;
    if (data.len < 2 + byte_len) return null;
    return data[2..][0..byte_len];
}

/// LiteNetLib NetDataWriter.Put(string): u16 LE (utf8_len+1), 0 for empty/null; then UTF-8.
pub fn writeNetString(buf: []u8, s: []const u8) ![]u8 {
    if (s.len == 0) {
        if (buf.len < 2) return error.Overflow;
        std.mem.writeInt(u16, buf[0..2], 0, .little);
        return buf[0..2];
    }
    if (s.len > 65534) return error.Overflow;
    const total = 2 + s.len;
    if (buf.len < total) return error.Overflow;
    std.mem.writeInt(u16, buf[0..2], @intCast(s.len + 1), .little);
    @memcpy(buf[2..][0..s.len], s);
    return buf[0..total];
}

/// Connect-key equality for ServerPassword (stock ConnectionRequestCheck).
/// Missing/malformed key only matches an empty server password.
/// Content compare is constant-time; length is mixed into the accumulator so a
/// pure length mismatch does not short-circuit the content loop when both sides
/// are non-empty (still bounded by the longer slice).
pub fn connectKeyMatches(data: []const u8, server_password: []const u8) bool {
    const key = readNetString(data) orelse return server_password.len == 0;
    return constantTimeEql(key, server_password);
}

pub fn writeConnectAccept(buf: []u8, connect_time: i64, connect_num: u8, local_peer_id: i32) ![]u8 {
    if (buf.len < connect_accept_size) return error.Overflow;
    buf[0] = makeByte0(.connect_accept, connect_num);
    std.mem.writeInt(i64, buf[1..][0..8], connect_time, .little);
    buf[9] = connect_num;
    buf[10] = 0; // not reused
    std.mem.writeInt(i32, buf[11..][0..4], local_peer_id, .little);
    return buf[0..connect_accept_size];
}

/// Disconnect (property 7): [byte0][connectTime:i64][extra...]. Used for password reject.
pub fn writeDisconnect(buf: []u8, connect_time: i64, connect_num: u8, extra: []const u8) ![]u8 {
    const total = disconnect_header_size + extra.len;
    if (buf.len < total) return error.Overflow;
    buf[0] = makeByte0(.disconnect, connect_num);
    std.mem.writeInt(i64, buf[1..][0..8], connect_time, .little);
    if (extra.len > 0) @memcpy(buf[disconnect_header_size..][0..extra.len], extra);
    return buf[0..total];
}

pub fn writeChanneled(buf: []u8, seq: u16, channel_id: u8, conn_num: u8, user: []const u8) ![]u8 {
    const total = channeled_header_size + user.len;
    if (buf.len < total) return error.Overflow;
    buf[0] = makeByte0(.channeled, conn_num);
    std.mem.writeInt(u16, buf[1..][0..2], seq, .little);
    buf[3] = channel_id;
    @memcpy(buf[4..][0..user.len], user);
    return buf[0..total];
}

/// One fragment of a large reliable message (IsFragmented bit set on byte0).
pub fn writeChanneledFragment(
    buf: []u8,
    seq: u16,
    channel_id: u8,
    conn_num: u8,
    frag_id: u16,
    frag_part: u16,
    frag_total: u16,
    user_part: []const u8,
) ![]u8 {
    const total = fragmented_header_total + user_part.len;
    if (buf.len < total) return error.Overflow;
    buf[0] = makeByte0(.channeled, conn_num) | fragment_flag;
    std.mem.writeInt(u16, buf[1..][0..2], seq, .little);
    buf[3] = channel_id;
    std.mem.writeInt(u16, buf[4..][0..2], frag_id, .little);
    std.mem.writeInt(u16, buf[6..][0..2], frag_part, .little);
    std.mem.writeInt(u16, buf[8..][0..2], frag_total, .little);
    @memcpy(buf[fragmented_header_total..][0..user_part.len], user_part);
    return buf[0..total];
}

pub fn isFragmented(byte0: u8) bool {
    return (byte0 & fragment_flag) != 0;
}

pub const ChanneledInfo = struct {
    seq: u16,
    channel_id: u8,
    fragmented: bool,
    frag_id: u16 = 0,
    frag_part: u16 = 0,
    frag_total: u16 = 0,
    user: []const u8,
};

pub fn parseChanneled(raw: []const u8) ?ChanneledInfo {
    if (raw.len < channeled_header_size) return null;
    // Merged (0x0c) is a different framing: [prop][u16 len][subpacket]*: not channeled.
    if (propertyOf(raw[0]) != .channeled) return null;
    const seq = std.mem.readInt(u16, raw[1..][0..2], .little);
    const channel_id = raw[3];
    if (isFragmented(raw[0])) {
        if (raw.len < fragmented_header_total) return null;
        return .{
            .seq = seq,
            .channel_id = channel_id,
            .fragmented = true,
            .frag_id = std.mem.readInt(u16, raw[4..][0..2], .little),
            .frag_part = std.mem.readInt(u16, raw[6..][0..2], .little),
            .frag_total = std.mem.readInt(u16, raw[8..][0..2], .little),
            .user = raw[fragmented_header_total..],
        };
    }
    return .{
        .seq = seq,
        .channel_id = channel_id,
        .fragmented = false,
        .user = raw[channeled_header_size..],
    };
}

/// Ack packet: header + window start in sequence field + bitmap bytes.
/// Game LiteNet uses payload size (windowSize-1)/8+2 (=9 for window 64).
pub fn writeAck(buf: []u8, channel_id: u8, conn_num: u8, window_start: u16, bits: []const u8) ![]u8 {
    const bitmap_bytes: usize = (window_size - 1) / 8 + 2;
    const total = channeled_header_size + bitmap_bytes;
    if (buf.len < total) return error.Overflow;
    buf[0] = makeByte0(.ack, conn_num);
    std.mem.writeInt(u16, buf[1..][0..2], window_start, .little);
    buf[3] = channel_id;
    @memset(buf[channeled_header_size..][0..bitmap_bytes], 0);
    const n = @min(bits.len, bitmap_bytes);
    @memcpy(buf[channeled_header_size..][0..n], bits[0..n]);
    return buf[0..total];
}

pub fn channeledUserData(raw: []const u8) ?struct { seq: u16, channel_id: u8, user: []const u8 } {
    const info = parseChanneled(raw) orelse return null;
    // Non-fragment path only (fragments need reassembly at Peer).
    if (info.fragmented) return null;
    return .{ .seq = info.seq, .channel_id = info.channel_id, .user = info.user };
}

test "connect accept encodes every stock field" {
    var buf: [32]u8 = undefined;
    const a = try writeConnectAccept(&buf, 12345, 2, 17);
    try std.testing.expectEqual(@as(usize, 15), a.len);
    try std.testing.expectEqual(Property.connect_accept, propertyOf(a[0]));
    try std.testing.expectEqual(@as(u8, 2), connectionNumberOf(a[0]));
    try std.testing.expectEqual(@as(i64, 12345), std.mem.readInt(i64, a[1..][0..8], .little));
    try std.testing.expectEqual(@as(u8, 2), a[9]);
    try std.testing.expectEqual(@as(u8, 0), a[10]);
    try std.testing.expectEqual(@as(i32, 17), std.mem.readInt(i32, a[11..][0..4], .little));

    var short: [connect_accept_size - 1]u8 = undefined;
    try std.testing.expectError(error.Overflow, writeConnectAccept(&short, 0, 0, 0));
}

test "unassigned property ordinal does not trap" {
    var b: u8 = 18;
    while (b < 32) : (b += 1) {
        const p = propertyOf(b);
        try std.testing.expect(p != .connect_request);
        try std.testing.expect(p != .channeled);
    }
}

test "net string empty and roundtrip" {
    var buf: [64]u8 = undefined;
    const empty = try writeNetString(&buf, "");
    try std.testing.expectEqual(@as(usize, 2), empty.len);
    try std.testing.expectEqualStrings("", readNetString(empty).?);
    const hi = try writeNetString(&buf, "secret");
    try std.testing.expectEqualStrings("secret", readNetString(hi).?);
    try std.testing.expect(connectKeyMatches(hi, "secret"));
    try std.testing.expect(!connectKeyMatches(hi, "other"));
    try std.testing.expect(connectKeyMatches(empty, ""));
    try std.testing.expect(!connectKeyMatches(empty, "x"));
    try std.testing.expect(connectKeyMatches(&.{}, ""));
    try std.testing.expect(!connectKeyMatches(&.{}, "x"));
}

test "net string rejects truncated payload and oversized writes" {
    try std.testing.expect(readNetString(&.{ 2, 0 }) == null);
    try std.testing.expect(readNetString(&.{1}) == null);

    var short: [3]u8 = undefined;
    try std.testing.expectError(error.Overflow, writeNetString(&short, "ab"));

    const oversized = [_]u8{'x'} ** 65535;
    var unused: [2]u8 = undefined;
    try std.testing.expectError(error.Overflow, writeNetString(&unused, &oversized));
}

test "connect request rejects invalid protocol address size and truncation" {
    var raw: [connect_request_header + 28]u8 = @splat(0);
    raw[0] = makeByte0(.connect_request, 3);
    std.mem.writeInt(i32, raw[1..][0..4], protocol_id, .little);
    std.mem.writeInt(i64, raw[5..][0..8], 42, .little);
    std.mem.writeInt(i32, raw[13..][0..4], 7, .little);

    raw[17] = 16;
    const parsed = parseConnectRequest(raw[0 .. connect_request_header + 16]).?;
    try std.testing.expectEqual(@as(i64, 42), parsed.connection_time);
    try std.testing.expectEqual(@as(u8, 3), parsed.connection_number);
    try std.testing.expectEqual(@as(i32, 7), parsed.peer_id);
    try std.testing.expectEqual(@as(usize, 0), parsed.data.len);

    try std.testing.expect(parseConnectRequest(raw[0 .. connect_request_header + 15]) == null);
    raw[17] = 17;
    try std.testing.expect(parseConnectRequest(&raw) == null);
    raw[17] = 16;
    std.mem.writeInt(i32, raw[1..][0..4], protocol_id + 1, .little);
    try std.testing.expect(parseConnectRequest(&raw) == null);
}

test "disconnect reject invalid password layout" {
    var buf: [32]u8 = undefined;
    const d = try writeDisconnect(&buf, 99, 1, &reject_invalid_password);
    try std.testing.expectEqual(@as(usize, 11), d.len);
    try std.testing.expectEqual(Property.disconnect, propertyOf(d[0]));
    try std.testing.expectEqual(@as(u8, 1), connectionNumberOf(d[0]));
    try std.testing.expectEqual(@as(i64, 99), std.mem.readInt(i64, d[1..][0..8], .little));
    try std.testing.expectEqual(@as(u8, 0), d[9]);
    try std.testing.expectEqual(@as(u8, 0), d[10]);
}

test "channeled wrap" {
    var buf: [64]u8 = undefined;
    const user = "hello";
    const p = try writeChanneled(&buf, 7, 2, 0, user);
    const u = channeledUserData(p).?;
    try std.testing.expectEqual(@as(u16, 7), u.seq);
    try std.testing.expectEqual(@as(u8, 2), u.channel_id);
    try std.testing.expectEqualStrings(user, u.user);
}

test "fragmented channeled header" {
    var buf: [64]u8 = undefined;
    const part = "abcdefgh";
    const p = try writeChanneledFragment(&buf, 9, 2, 0, 3, 1, 4, part);
    try std.testing.expect(isFragmented(p[0]));
    const info = parseChanneled(p).?;
    try std.testing.expect(info.fragmented);
    try std.testing.expectEqual(@as(u16, 9), info.seq);
    try std.testing.expectEqual(@as(u8, 2), info.channel_id);
    try std.testing.expectEqual(@as(u8, 0), connectionNumberOf(p[0]));
    try std.testing.expectEqual(@as(u16, 3), info.frag_id);
    try std.testing.expectEqual(@as(u16, 1), info.frag_part);
    try std.testing.expectEqual(@as(u16, 4), info.frag_total);
    try std.testing.expectEqualStrings(part, info.user);
    try std.testing.expect(channeledUserData(p) == null);
}

test "packet writers reject one-byte-short buffers" {
    var channeled: [channeled_header_size + 2]u8 = undefined;
    try std.testing.expectError(error.Overflow, writeChanneled(channeled[0 .. channeled.len - 1], 1, 0, 0, "ab"));

    var fragment: [fragmented_header_total + 2]u8 = undefined;
    try std.testing.expectError(error.Overflow, writeChanneledFragment(
        fragment[0 .. fragment.len - 1],
        1,
        0,
        0,
        1,
        0,
        1,
        "ab",
    ));

    var disconnect: [disconnect_header_size + reject_rate_limit.len]u8 = undefined;
    try std.testing.expectError(error.Overflow, writeDisconnect(
        disconnect[0 .. disconnect.len - 1],
        1,
        0,
        &reject_rate_limit,
    ));
}

test "ack encodes header, fixed bitmap, and zero padding" {
    const bitmap_bytes: usize = (window_size - 1) / 8 + 2;
    var buf: [channeled_header_size + bitmap_bytes]u8 = undefined;
    const ack = try writeAck(&buf, 3, 2, 32767, &.{ 0x81, 0x42 });

    try std.testing.expectEqual(Property.ack, propertyOf(ack[0]));
    try std.testing.expectEqual(@as(u8, 2), connectionNumberOf(ack[0]));
    try std.testing.expectEqual(@as(u16, 32767), std.mem.readInt(u16, ack[1..][0..2], .little));
    try std.testing.expectEqual(@as(u8, 3), ack[3]);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x42 }, ack[4..6]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** (bitmap_bytes - 2)), ack[6..]);

    var short: [channeled_header_size + bitmap_bytes - 1]u8 = undefined;
    try std.testing.expectError(error.Overflow, writeAck(&short, 0, 0, 0, &.{}));
}

test "channeled parser rejects truncated headers and wrong property" {
    const ordinary = [_]u8{ makeByte0(.channeled, 0), 1, 0 };
    try std.testing.expect(parseChanneled(&ordinary) == null);

    var fragmented: [fragmented_header_total]u8 = @splat(0);
    fragmented[0] = makeByte0(.channeled, 0) | fragment_flag;
    try std.testing.expect(parseChanneled(fragmented[0 .. fragmented_header_total - 1]) == null);

    fragmented[0] = makeByte0(.merged, 0);
    try std.testing.expect(parseChanneled(&fragmented) == null);
}
