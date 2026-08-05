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

/// DecoState.GeneratedActive. Forced: RestoreGeneratedDecos (asm.il ends 1258023)
/// deletes state 2 (Dynamic) decos on the DecoResetWorldChunk path.
pub const deco_state_active: u8 = 0;

/// On-wire DecoObject size: u64 pos + f32 realY + u32 rawData + u8 state
/// (DecoObject::Write, asm.il ends 1264030). NOT the stock
/// `NetPackageDecoUpdate.decoSize = 0x10` literal (asm.il 808289): that field is
/// declared and never referenced anywhere in the assembly, so it is a stale
/// estimate, not the record size.
pub const deco_size: usize = 17;
/// NetPackageDecoUpdate.decosPerPackage (asm.il 808291); Setup caps each package
/// at this many objects (`ldc.i4 0x8000` at Setup IL_000b).
pub const decos_per_package: usize = 0x8000;
/// zdtd per-package cap. Body is `objects_off + n*deco_size`; 4096 keeps one
/// package at ~68 KiB so it frames inside `Game.send_buf` (256 KiB) and stays in
/// the same fragment-count band as a stock chunk.
pub const zdtd_decos_per_package: usize = 4096;

/// Body offsets: firstPackage:bool | dataLen:i32 | count:i32 | objects.
pub const header_len: usize = 5;
pub const objects_off: usize = header_len + 4;

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

/// Bytes a DecoUpdate body needs for `n` objects.
pub fn decoUpdateLen(n: usize) usize {
    return objects_off + n * deco_size;
}

/// Patch the header of a DecoUpdate body whose objects were written in place at
/// `objects_off`. `end` is the writer position past the last object. Single
/// framing implementation: `buildDecoUpdate` and the streaming sender share it.
pub fn finishDecoUpdate(buf: []u8, first_package: bool, count: usize, end: usize) ![]u8 {
    if (count > decos_per_package) return error.TooManyDecos;
    if (buf.len < end or end < objects_off) return error.Overflow;
    // Illegal state: header count must describe exactly the bytes written.
    if (end - objects_off != count * deco_size) return error.Overflow;
    buf[0] = if (first_package) 1 else 0;
    std.mem.writeInt(i32, buf[1..5], @intCast(end - header_len), .little);
    std.mem.writeInt(i32, buf[5..9], @intCast(count), .little);
    return buf[0..end];
}

/// NetPackageDecoUpdate body: firstPackage:bool | dataLen:i32 | payload(count:i32 + objects).
pub fn buildDecoUpdate(buf: []u8, first_package: bool, objs: []const DecoObj) ![]u8 {
    if (objs.len > decos_per_package) return error.TooManyDecos;
    if (buf.len < decoUpdateLen(objs.len)) return error.Overflow;
    var w: binary.Writer = .{ .buf = buf, .pos = objects_off };
    for (objs) |o| try writeDecoObject(&w, o);
    return finishDecoUpdate(buf, first_package, objs.len, w.pos);
}

/// Streams DecoObjects into a caller-owned body buffer, cutting a new package
/// every `cap` objects. Mirrors stock `NetPackageDecoUpdate.Setup`, which is
/// called back to back until the write list is drained (`SendDecosToClient`,
/// asm.il 1263272): the first package carries `firstPackage=true` (the client
/// allocates `DecoManager.loadedDecos` only then), every continuation `false`.
///
/// Contract: the body returned by `take` aliases `buf`, so it must be sent
/// before the next `push`.
pub const PackageWriter = struct {
    buf: []u8,
    cap: usize,
    count: usize = 0,
    pos: usize = objects_off,
    /// Packages already handed out by `take`.
    sent: usize = 0,

    pub fn init(buf: []u8, cap: usize) !PackageWriter {
        if (cap == 0 or cap > decos_per_package) return error.TooManyDecos;
        if (buf.len < decoUpdateLen(cap)) return error.Overflow;
        return .{ .buf = buf, .cap = cap };
    }

    /// True when the current package is at capacity: `take` before pushing again.
    pub fn full(self: *const PackageWriter) bool {
        return self.count >= self.cap;
    }

    pub fn push(self: *PackageWriter, o: DecoObj) !void {
        if (self.full()) return error.TooManyDecos;
        var w: binary.Writer = .{ .buf = self.buf, .pos = self.pos };
        try writeDecoObject(&w, o);
        self.pos = w.pos;
        self.count += 1;
    }

    /// Finish the current package (possibly empty) and start the next one.
    pub fn take(self: *PackageWriter) ![]u8 {
        const body = try finishDecoUpdate(self.buf, self.sent == 0, self.count, self.pos);
        self.sent += 1;
        self.count = 0;
        self.pos = objects_off;
        return body;
    }
};

/// Deterministic sparse tree placement from surface heights in a world XZ window.
/// `height_at(wx,wz)` returns surface Y (block top / standing height base); 0 or
/// out-of-range skips the cell. `every_n`: place when hash % every_n == 0 (lower
/// = denser). Tree ids are caller-supplied (runtime AssignIds), never pinned:
/// an id the client cannot resolve NREs inside its world-load coroutine
/// (DecoManager.TryAddToOccupiedMap IL_0008 derefs Block::isMultiBlock unguarded).
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

/// World cells per terrain chunk side; `out` must hold `chunk_cells` objects.
pub const chunk_side: i32 = 16;
pub const chunk_cells: usize = 16 * 16;

/// Deco for one terrain chunk (16×16 world cells at chunk cx,cz).
pub fn generateForTerrainChunkIds(
    out: []DecoObj,
    cx: i32,
    cz: i32,
    height_at: *const fn (ctx: ?*anyopaque, wx: i32, wz: i32) u16,
    ctx: ?*anyopaque,
    every_n: u32,
    oak_id: u32,
    dead_id: u32,
) usize {
    const wx0 = cx * chunk_side;
    const wz0 = cz * chunk_side;
    return generateAroundIds(
        out,
        wx0,
        wz0,
        wx0 + chunk_side,
        wz0 + chunk_side,
        height_at,
        ctx,
        every_n,
        oak_id,
        dead_id,
    );
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

test "deco update one object golden layout" {
    var buf: [64]u8 = undefined;
    const o: DecoObj = .{ .x = -273, .y = 62, .z = 449, .real_y = 62.0, .block_raw = 24629 };
    const body = try buildDecoUpdate(&buf, true, &.{o});
    // 5 header + 4 count + 17 object (8 pos + 4 realY + 4 rawData + 1 state).
    try std.testing.expectEqual(@as(usize, 26), body.len);
    try std.testing.expectEqual(@as(u8, 1), body[0]);
    // dataLen counts count:i32 + objects only, not the firstPackage byte or itself.
    try std.testing.expectEqual(@as(i32, 21), std.mem.readInt(i32, body[1..5], .little));
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, body[5..9], .little));
    try std.testing.expectEqual(vector3iToU64(-273, 62, 449), std.mem.readInt(u64, body[9..17], .little));
    try std.testing.expectEqual(@as(f32, 62.0), @as(f32, @bitCast(std.mem.readInt(u32, body[17..21], .little))));
    try std.testing.expectEqual(@as(u32, 24629), std.mem.readInt(u32, body[21..25], .little));
    try std.testing.expectEqual(deco_state_active, body[25]);
}

test "deco update continuation header is 0" {
    var buf: [64]u8 = undefined;
    const o: DecoObj = .{ .x = 1, .y = 2, .z = 3, .real_y = 2.0, .block_raw = 7 };
    const body = try buildDecoUpdate(&buf, false, &.{ o, o });
    try std.testing.expectEqual(@as(u8, 0), body[0]);
    try std.testing.expectEqual(@as(i32, 4 + 2 * deco_size), std.mem.readInt(i32, body[1..5], .little));
    try std.testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, body[5..9], .little));
    try std.testing.expectEqual(decoUpdateLen(2), body.len);
}

test "deco update rejects short buffer and over-cap counts" {
    var small: [24]u8 = undefined;
    const o: DecoObj = .{ .x = 0, .y = 1, .z = 0, .real_y = 1.0, .block_raw = 1 };
    try std.testing.expectError(error.Overflow, buildDecoUpdate(&small, true, &.{o}));
    var buf: [64]u8 = undefined;
    // finishDecoUpdate is the shared guard: count must match the bytes written.
    try std.testing.expectError(error.Overflow, finishDecoUpdate(&buf, true, 2, objects_off + deco_size));
    try std.testing.expectError(error.TooManyDecos, finishDecoUpdate(&buf, true, decos_per_package + 1, objects_off));
    try std.testing.expect(zdtd_decos_per_package <= decos_per_package);
}

test "PackageWriter splits into first + continuation packages" {
    var buf: [decoUpdateLen(3)]u8 = undefined;
    var pw = try PackageWriter.init(&buf, 3);
    const o: DecoObj = .{ .x = 4, .y = 5, .z = 6, .real_y = 5.0, .block_raw = 42 };
    var counts: [3]i32 = undefined;
    var firsts: [3]u8 = undefined;
    var pushed: usize = 0;
    // 7 objects at cap 3 => packages of 3, 3, 1.
    while (pushed < 7) : (pushed += 1) {
        if (pw.full()) {
            const body = try pw.take();
            firsts[pw.sent - 1] = body[0];
            counts[pw.sent - 1] = std.mem.readInt(i32, body[5..9], .little);
        }
        try pw.push(o);
    }
    const last = try pw.take();
    firsts[pw.sent - 1] = last[0];
    counts[pw.sent - 1] = std.mem.readInt(i32, last[5..9], .little);
    try std.testing.expectEqual(@as(usize, 3), pw.sent);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0 }, &firsts);
    try std.testing.expectEqualSlices(i32, &.{ 3, 3, 1 }, &counts);
    try std.testing.expectEqual(decoUpdateLen(1), last.len);
}

test "PackageWriter empty take is a valid first package" {
    var buf: [64]u8 = undefined;
    var pw = try PackageWriter.init(&buf, 2);
    const body = try pw.take();
    try std.testing.expectEqual(@as(u8, 1), body[0]);
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, body[5..9], .little));
    try std.testing.expectEqual(decoUpdateLen(0), body.len);
}

test "PackageWriter rejects undersized buffer and bad cap" {
    var buf: [decoUpdateLen(2)]u8 = undefined;
    try std.testing.expectError(error.Overflow, PackageWriter.init(&buf, 3));
    try std.testing.expectError(error.TooManyDecos, PackageWriter.init(&buf, 0));
    var pw = try PackageWriter.init(&buf, 2);
    const o: DecoObj = .{ .x = 0, .y = 1, .z = 0, .real_y = 1.0, .block_raw = 1 };
    try pw.push(o);
    try pw.push(o);
    try std.testing.expectError(error.TooManyDecos, pw.push(o));
}

fn flatHeight(ctx: ?*anyopaque, wx: i32, wz: i32) u16 {
    _ = wx;
    _ = wz;
    const h: *const u16 = @ptrCast(@alignCast(ctx.?));
    return h.*;
}

test "generateAroundIds is deterministic and only emits supplied ids" {
    var h: u16 = 40;
    var a: [512]DecoObj = undefined;
    var b: [512]DecoObj = undefined;
    const na = generateAroundIds(&a, 0, 0, 48, 48, flatHeight, &h, 29, 100, 200);
    const nb = generateAroundIds(&b, 0, 0, 48, 48, flatHeight, &h, 29, 100, 200);
    try std.testing.expectEqual(na, nb);
    try std.testing.expect(na > 0);
    try std.testing.expectEqualSlices(DecoObj, a[0..na], b[0..nb]);
    var saw_oak = false;
    var saw_dead = false;
    for (a[0..na]) |o| {
        try std.testing.expect(o.block_raw == 100 or o.block_raw == 200);
        saw_oak = saw_oak or o.block_raw == 100;
        saw_dead = saw_dead or o.block_raw == 200;
        try std.testing.expectEqual(deco_state_active, o.state);
        // Placed one above the surface, realYPos == block Y (stock: (int)(y+0.5)).
        try std.testing.expectEqual(@as(i32, h + 1), o.y);
        try std.testing.expectEqual(@as(f32, @floatFromInt(o.y)), o.real_y);
    }
    try std.testing.expect(saw_oak and saw_dead);
}

test "generateAroundIds skips unusable surface heights" {
    var h: u16 = 0;
    var out: [64]DecoObj = undefined;
    try std.testing.expectEqual(@as(usize, 0), generateAroundIds(&out, 0, 0, 64, 64, flatHeight, &h, 29, 1, 2));
    h = 251;
    try std.testing.expectEqual(@as(usize, 0), generateAroundIds(&out, 0, 0, 64, 64, flatHeight, &h, 29, 1, 2));
}

test "generateForTerrainChunkIds stays inside its chunk" {
    var h: u16 = 40;
    var out: [chunk_side * chunk_side]DecoObj = undefined;
    const n = generateForTerrainChunkIds(&out, -3, 5, flatHeight, &h, 17, 11, 12);
    for (out[0..n]) |o| {
        try std.testing.expect(o.x >= -48 and o.x < -32);
        try std.testing.expect(o.z >= 80 and o.z < 96);
    }
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
