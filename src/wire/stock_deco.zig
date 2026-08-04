//! Stock NetPackageDecoUpdate + DecoObject wire (V3.0.1).
//! Client fixed-size worlds only show grass/trees from server deco packages
//! (client decorateChunkRandom is a no-op when bFixedSize).

const std = @import("std");
const binary = @import("binary.zig");

/// Runtime Block.blockID after AssignIds (bundled dump, comptime).
/// DecoObject requires BlockShapeDistantDeco (+ Model). plantShrub is ModelEntity only.
const assignids = @import("../assets/assignids_comptime.zig");
pub const plant_shrub: u32 = assignids.plant_shrub;
pub const tree_dead_pine_leaf: u32 = assignids.tree_dead_pine_leaf;
pub const tree_dead_02: u32 = assignids.tree_dead_02;
pub const tree_oak_sml: u32 = assignids.tree_oak_sml;
pub const tree_winter_evergreen: u32 = assignids.tree_winter_evergreen;

/// Storage / loot containers (same AssignIds dump).
pub const cnt_wooden_chest_closed: u32 = assignids.cnt_wooden_chest_closed;
pub const cnt_wooden_chest_open: u32 = assignids.cnt_wooden_chest_open;
pub const cnt_wood_writable_crate: u32 = assignids.cnt_wood_writable_crate;
pub const cnt_desk_safe: u32 = assignids.cnt_desk_safe;
pub const cnt_hardened_chest_insecure: u32 = assignids.cnt_hardened_chest_insecure;

/// DecoState.GeneratedActive
pub const deco_state_active: u8 = 0;

/// GameUtils.Vector3iToUInt64
pub fn vector3iToU64(x: i32, y: i32, z: i32) u64 {
    const xu: u64 = @as(u64, @intCast(@as(u32, @bitCast(x +% 32768)) & 0xFFFF));
    const yu: u64 = @as(u64, @intCast(@as(u32, @bitCast(y +% 32768)) & 0xFFFF));
    const zu: u64 = @as(u64, @intCast(@as(u32, @bitCast(z +% 32768)) & 0xFFFF));
    return (xu << 32) | (yu << 16) | zu;
}

pub const DecoObj = struct {
    x: i32,
    y: i32,
    z: i32,
    real_y: f32,
    block_raw: u32,
    state: u8 = deco_state_active,
};

pub fn writeDecoObject(w: *binary.Writer, o: DecoObj) !void {
    try w.writeU64(vector3iToU64(o.x, o.y, o.z));
    try w.writeF32(o.real_y);
    try w.writeU32(o.block_raw);
    try w.writeByte(o.state);
}

/// NetPackageDecoUpdate body: firstPackage:bool | dataLen:i32 | payload(count:i32 + objects).
pub fn buildDecoUpdate(buf: []u8, first_package: bool, objs: []const DecoObj) ![]u8 {
    if (buf.len < 16) return error.Overflow;
    const payload_off: usize = 1 + 4;
    var w: binary.Writer = .{ .buf = buf, .pos = payload_off };
    try w.writeI32(@intCast(objs.len));
    for (objs) |o| try writeDecoObject(&w, o);
    const end = w.pos;
    const data_len: i32 = @intCast(end - payload_off);
    buf[0] = if (first_package) 1 else 0;
    std.mem.writeInt(i32, buf[1..5], data_len, .little);
    return buf[0..end];
}

/// Deterministic sparse plant/tree placement from surface heights in a world XZ window.
/// `height_at(wx,wz)` returns surface Y (block top / standing height base).
/// `every_n`: place when hash % every_n == 0 (lower = denser). Typical 19–37.
pub fn generateAround(
    out: []DecoObj,
    wx0: i32,
    wz0: i32,
    wx1: i32,
    wz1: i32,
    height_at: *const fn (ctx: ?*anyopaque, wx: i32, wz: i32) u16,
    ctx: ?*anyopaque,
    every_n: u32,
) usize {
    return generateAroundIds(out, wx0, wz0, wx1, wz1, height_at, ctx, every_n, tree_oak_sml, tree_dead_02);
}

/// Same, with caller-supplied (runtime-resolved) tree block ids so the ids
/// match the connected client's registry instead of a pinned capture.
pub fn generateAroundIds(
    out: []DecoObj,
    wx0: i32,
    wz0: i32,
    wx1: i32,
    wz1: i32,
    height_at: *const fn (ctx: ?*anyopaque, wx: i32, wz: i32) u16,
    ctx: ?*anyopaque,
    every_n: u32,
    oak_id: u32,
    dead_id: u32,
) usize {
    const step: u32 = if (every_n < 3) 3 else every_n;
    var n: usize = 0;
    var wz = wz0;
    while (wz < wz1 and n < out.len) : (wz += 1) {
        var wx = wx0;
        while (wx < wx1 and n < out.len) : (wx += 1) {
            const h = mix(wx, wz);
            if (h % step != 0) continue;
            const y: i32 = height_at(ctx, wx, wz);
            if (y < 2 or y >= 250) continue;
            // Only DistantDecoTree + Model blocks (CreateGameObject isinst DistantDeco).
            const kind = h % 7;
            const block: u32 = if (kind <= 2) oak_id else dead_id;
            // Place on surface: block y often surface+1 for plants
            const by = y + 1;
            out[n] = .{
                .x = wx,
                .y = by,
                .z = wz,
                .real_y = @floatFromInt(by),
                .block_raw = block,
            };
            n += 1;
        }
    }
    return n;
}

/// Deco for one terrain chunk (16×16 world cells at chunk cx,cz).
pub fn generateForTerrainChunk(
    out: []DecoObj,
    cx: i32,
    cz: i32,
    height_at: *const fn (ctx: ?*anyopaque, wx: i32, wz: i32) u16,
    ctx: ?*anyopaque,
    every_n: u32,
) usize {
    const wx0 = cx * 16;
    const wz0 = cz * 16;
    return generateAround(out, wx0, wz0, wx0 + 16, wz0 + 16, height_at, ctx, every_n);
}

fn mix(x: i32, z: i32) u32 {
    var h: u32 = @bitCast(x *% 374761393 +% z *% 668265263);
    h ^= h >> 13;
    h *%= 1274126177;
    return h;
}

test "vector3i pack roundtrip bits" {
    const p = vector3iToU64(-273, 61, 449);
    const x: i32 = @as(i32, @intCast(@as(u16, @truncate(p >> 32)))) -% 32768;
    const y: i32 = @as(i32, @intCast(@as(u16, @truncate(p >> 16)))) -% 32768;
    const z: i32 = @as(i32, @intCast(@as(u16, @truncate(p)))) -% 32768;
    try std.testing.expectEqual(@as(i32, -273), x);
    try std.testing.expectEqual(@as(i32, 61), y);
    try std.testing.expectEqual(@as(i32, 449), z);
}

test "deco update empty first" {
    var buf: [64]u8 = undefined;
    const body = try buildDecoUpdate(&buf, true, &.{});
    try std.testing.expectEqual(@as(u8, 1), body[0]);
    try std.testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, body[1..5], .little));
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, body[5..9], .little));
}

test "deco plant/tree runtime block ids" {
    // AssignIds: non-terrain IDs are >> XML index; 6xxx values hit shipping/shapes.
    try std.testing.expect(tree_dead_02 > 1000);
    try std.testing.expect(tree_oak_sml > 1000);
    try std.testing.expectEqual(@as(u32, 24626), tree_dead_02);
    try std.testing.expectEqual(@as(u32, 24629), tree_oak_sml);
    try std.testing.expectEqual(@as(u32, 24651), tree_winter_evergreen);
}

/// WorldChunkCache.MakeChunkKey(x, z). Canonical definition; packages.makeChunkKey aliases this.
pub fn makeChunkKey(cx: i32, cz: i32) i64 {
    const x = @as(i64, cx) & 0xFFFFFF;
    const z = @as(i64, cz) & 0xFFFFFF;
    return (z << 24) | x;
}

/// NetPackageDecoResetWorldChunk body: dataLen:i32 | chunkKey:i64 (WorldChunkCache key).
pub fn buildDecoResetWorldChunk(buf: []u8, cx: i32, cz: i32) ![]u8 {
    const key = makeChunkKey(cx, cz);
    if (buf.len < 12) return error.Overflow;
    std.mem.writeInt(i32, buf[0..4], 8, .little);
    std.mem.writeInt(i64, buf[4..12], key, .little);
    return buf[0..12];
}

test "deco reset body size" {
    var buf: [16]u8 = undefined;
    const body = try buildDecoResetWorldChunk(&buf, -18, 28);
    try std.testing.expectEqual(@as(usize, 12), body.len);
    try std.testing.expectEqual(@as(i32, 8), std.mem.readInt(i32, body[0..4], .little));
}
