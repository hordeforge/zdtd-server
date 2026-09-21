//! Chunk-remove bodies: key build/parse pair.
//!
//! Split out of the packages.zig facade (same code, moved verbatim);
//! the roundtrip test stays in the facade where it already exercises
//! these names.
//! import via `packages.stock_chunkremove` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");
const stock_map = @import("stock_map.zig");
const makeChunkKey = stock_map.makeChunkKey;
const extractChunkKeyX = stock_map.extractChunkKeyX;
const extractChunkKeyZ = stock_map.extractChunkKeyZ;

/// Stock NetPackageChunkRemove: chunkKey i64 (WorldChunkCache.MakeChunkKey).
pub fn buildChunkRemoveBody(buf: []u8, cx: i32, cz: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI64(makeChunkKey(cx, cz));
    return w.written();
}

/// Read side of NetPackageChunkRemove: one `chunkKey` i64, the key
/// buildChunkRemoveBody writes. The coordinates come back out through the same
/// WorldChunkCache.MakeChunkKey packing, so any i64 decodes to some chunk and
/// the range check belongs at the caller, not here.
pub fn parseChunkRemoveBody(body: []const u8) !struct { cx: i32, cz: i32 } {
    if (body.len < 8) return error.EndOfStream;
    const key = std.mem.readInt(i64, body[0..8], .little);
    return .{ .cx = extractChunkKeyX(key), .cz = extractChunkKeyZ(key) };
}
