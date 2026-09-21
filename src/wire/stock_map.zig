//! Chunk + minimap-map wire bodies: the zdtd height-plane test/loadgen
//! payload with the stock NetPackageChunk envelope, and NetPackageMapChunks.
//!
//! Split out of the packages.zig facade (same builders, same tests);
//! import via `packages.stock_map` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");
const stock_deco = @import("stock_deco.zig");

/// One minimap chunk piece: the map-database key (RE IMapChunkDatabase
/// ToChunkDBKey: ((x & 0xFFFF) << 16) | (z & 0xFFFF)) + 256 RGB555 colors.
pub const MapChunkPiece = struct {
    key: i32,
    colors: [256]u16,
};

/// NetPackageMapChunks (Assembly-CSharp write IL=109): entityId i32, count
/// u16, then per piece (dbKey i32 + 256 u16 colors). Channel 1, Compress=true
/// (the caller sends via sendCompressed); protocol-packages.md §3.3.
pub fn buildMapChunksBody(buf: []u8, entity_id: i32, pieces: []const MapChunkPiece) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeU16(@intCast(pieces.len));
    for (pieces) |p| {
        try w.writeI32(p.key);
        for (p.colors) |c| try w.writeU16(c);
    }
    return w.written();
}

test "MapChunks body is entityId + count + key + 256 colors per piece" {
    var buf: [4096]u8 = undefined;
    var colors: [256]u16 = .{0} ** 256;
    colors[0] = 434;
    colors[255] = 16816;
    const pieces = [_]MapChunkPiece{.{ .key = 0x00010002, .colors = colors }};
    const b = try buildMapChunksBody(&buf, 107, &pieces);
    try std.testing.expectEqual(@as(usize, 4 + 2 + 4 + 512), b.len);
    try std.testing.expectEqual(@as(i32, 107), std.mem.readInt(i32, b[0..4], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, b[4..6], .little));
    try std.testing.expectEqual(@as(i32, 0x00010002), std.mem.readInt(i32, b[6..10], .little));
    try std.testing.expectEqual(@as(u16, 434), std.mem.readInt(u16, b[10..12], .little));
    try std.testing.expectEqual(@as(u16, 16816), std.mem.readInt(u16, b[10 + 255 * 2 ..][0..2], .little));
}

/// NetPackageChunk body (zdtd intermediate payload + optional stock envelope).
///
/// Inner payload (always):
///   cx:i32 LE | cz:i32 LE | ydim:i32 LE (=256) | heights:u8[256]
/// heights[lx + lz*16] = surface Y. Size = 268.
///
/// Stock envelope (layout D, default for S→C):
///   overwrite:bool(=true) | cx:i16 | cy:i16(=0) | cz:i16 | dataLen:i32 | payload
/// Stock clients still need a real Chunk.write blob inside payload; bots/loadgen
/// parse either envelope or bare payload via parseChunkBody.
pub const chunk_body_size: usize = 12 + 256;
/// Envelope overhead: 1 + 2+2+2 + 4 = 11.
pub const chunk_stock_envelope_overhead: usize = 11;

/// WorldChunkCache.MakeChunkKey(x, z): ((z & 0xFFFFFF) << 24) | (x & 0xFFFFFF)
pub const makeChunkKey = stock_deco.makeChunkKey;

pub fn extractChunkKeyX(key: i64) i32 {
    // extractX: sign-extend low 24 bits
    const u: i32 = @truncate(key);
    return (u << 8) >> 8;
}

pub fn extractChunkKeyZ(key: i64) i32 {
    // extractZ from stock IL: ((key >> 16) as i32) >> 8 → effectively high 24 of low 48
    const shifted: i32 = @truncate(key >> 16);
    return shifted >> 8;
}

/// zdtd height-map payload for tests and loadgen, **not a stock package body**:
/// cx i32 | cz i32 | ydim i32 | 256 height bytes. The stock chunk body is built
/// by stock_chunk.buildNetPackageChunkNew; see buildStockChunkEnvelope below.
pub fn buildChunkPayload(buf: []u8, cx: i32, cz: i32, heights: *const [256]u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(cx);
    try w.writeI32(cz);
    try w.writeI32(256); // ydim
    try w.writeBytes(heights);
    return w.written();
}

/// Test/loadgen helper: stock NetPackageChunk envelope (overwrite=true) around
/// a height-plane payload. Production client stream uses
/// `stock_chunk.buildNetPackageChunkNew`.
pub fn buildChunkBody(buf: []u8, cx: i32, cz: i32, heights: *const [256]u8) ![]u8 {
    if (buf.len < chunk_stock_envelope_overhead + chunk_body_size) return error.Overflow;
    var payload_buf: [chunk_body_size]u8 = undefined;
    const payload = try buildChunkPayload(&payload_buf, cx, cz, heights);
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(true);
    try w.writeI16(@intCast(cx));
    try w.writeI16(0); // cy
    try w.writeI16(@intCast(cz));
    try w.writeI32(@intCast(payload.len));
    try w.writeBytes(payload);
    return w.written();
}

pub const ChunkParsed = struct {
    cx: i32,
    cz: i32,
    heights: []const u8,
};

/// Read side of buildChunkBody: the stock NetPackageChunk envelope
/// (`overwrite` bool | cx,cy,cz i16 | `len` i32 | payload) wrapped around
/// zdtd's height-plane payload, which is **not a stock chunk body**. The real
/// client stream is built by stock_chunk.buildNetPackageChunkNew and read by
/// the client, never by this function; this decodes what the tests and loadgen
/// write.
///
/// A body that does not start with a 0/1 discriminant is taken as a bare
/// payload, so both forms round-trip through one entry point.
pub fn parseChunkBody(body: []const u8) !ChunkParsed {
    // Stock envelope?
    if (body.len >= chunk_stock_envelope_overhead + chunk_body_size and (body[0] == 0 or body[0] == 1)) {
        var r: binary.Reader = .{ .data = body };
        const overwrite = try r.readBool();
        if (overwrite) {
            const cx = try r.readI16();
            _ = try r.readI16();
            const cz = try r.readI16();
            const data_len = try r.readI32();
            if (data_len < 0 or r.remaining() < @as(usize, @intCast(data_len))) return error.EndOfStream;
            const payload = body[r.pos .. r.pos + @as(usize, @intCast(data_len))];
            // Prefer coords from envelope when payload is height plane
            if (payload.len >= chunk_body_size) {
                const inner = try parseChunkPayload(payload);
                return .{ .cx = cx, .cz = cz, .heights = inner.heights };
            }
            return .{ .cx = cx, .cz = cz, .heights = payload };
        }
    }
    return parseChunkPayload(body);
}

fn parseChunkPayload(body: []const u8) !ChunkParsed {
    var r: binary.Reader = .{ .data = body };
    const cx = try r.readI32();
    const cz = try r.readI32();
    _ = try r.readI32();
    if (r.remaining() < 256) return error.EndOfStream;
    const heights = body[r.pos .. r.pos + 256];
    return .{ .cx = cx, .cz = cz, .heights = heights };
}

test "chunk body layout size and fields" {
    var heights: [256]u8 = .{64} ** 256;
    heights[5 + 5 * 16] = 70;
    var buf: [300]u8 = undefined;
    const body = try buildChunkBody(&buf, 1, -2, &heights);
    try std.testing.expectEqual(chunk_stock_envelope_overhead + chunk_body_size, body.len);
    try std.testing.expectEqual(@as(u8, 1), body[0]); // overwrite
    const p = try parseChunkBody(body);
    try std.testing.expectEqual(@as(i32, 1), p.cx);
    try std.testing.expectEqual(@as(i32, -2), p.cz);
    try std.testing.expectEqual(@as(u8, 70), p.heights[5 + 5 * 16]);
    // The envelope's three i16 are cx, cy, cz. The parser reads cx and cz by
    // offset, so it would agree with the writer even if both moved together;
    // read the raw words instead. Layout: overwrite bool | cx | cy | cz | len.
    try std.testing.expectEqual(@as(i16, 1), std.mem.readInt(i16, body[1..3], .little));
    try std.testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, body[3..5], .little)); // cy
    try std.testing.expectEqual(@as(i16, -2), std.mem.readInt(i16, body[5..7], .little));
    try std.testing.expectEqual(@as(i32, chunk_body_size), std.mem.readInt(i32, body[7..11], .little));

    // bare payload still parses
    const bare = try buildChunkPayload(buf[0..chunk_body_size], 3, 4, &heights);
    const p2 = try parseChunkBody(bare);
    try std.testing.expectEqual(@as(i32, 3), p2.cx);
    try std.testing.expectEqual(@as(i32, 4), p2.cz);
    // Payload head is cx | cz | ydim as i32, ydim distinct from both coords.
    try std.testing.expectEqual(@as(i32, 3), std.mem.readInt(i32, bare[0..4], .little));
    try std.testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, bare[4..8], .little));
    try std.testing.expectEqual(@as(i32, 256), std.mem.readInt(i32, bare[8..12], .little));
}
