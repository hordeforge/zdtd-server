//! Mirror placed decorations into the server block store, so collision, harvest
//! and chunk streaming agree with what the client renders.
//!
//! Semantics come from `ChunkCluster::addDistantDecorationBlocks`
//! (asm.il 1126815-1127012), which the client runs itself from `LightChunk`
//! (asm.il 1127022) for every deco it holds:
//!
//!   - Skip the whole decoration when the block already at its position is a
//!     multiblock (IL_008f-IL_009b). That is what makes the server writing the
//!     same blocks first convergent rather than conflicting: the client sees its
//!     own tree already there and leaves it alone.
//!   - Single-block decoration: write it only where the world block is air
//!     (IL_0196-IL_01ba).
//!   - Multiblock decoration: write every cell of `Block.multiBlockPos`
//!     unconditionally. Offset (0,0,0) gets the parent value as-is; every other
//!     offset gets the same value with `ischild` set and `parent*` pointing back
//!     at the parent, i.e. the negated offset (IL_0129-IL_015e).
//!
//! Stability 15 and the density re-write (IL_0172-IL_0186) have no counterpart
//! here: zdtd's chunk store has no stability plane, and `setBlockDecoRaw` leaves
//! the cell's density untouched, which is what `SetDensityRaw(previous)` amounts
//! to.

const std = @import("std");
const store = @import("store.zig");

/// `BlockValue::get_ischild` mask (asm.il 140846-140858).
pub const ischild_bit: u32 = 0x40000000;

/// `BlockValue` bit fields the child encoding uses.
/// meta = bits 22..25 (asm.il 140570-140601), meta2 = bits 26..29 (140605-140636),
/// rotationAndMeta3 = bits 16..21 (140689-140730).
const meta_shift: u5 = 22;
const meta2_shift: u5 = 26;
const rot_meta3_shift: u5 = 16;
const nibble: u32 = 0xf;
const six_bits: u32 = 0x3f;

/// Offsets a multiblock occupies at rotation 0, from blocks.xml `MultiBlockDim`.
/// Stock builds this list in `Block::Init` (asm.il 92240-92325):
/// `x` runs from `-(dim.x / 2)` to `RoundToInt(dim.x / 2 + 0.1) - 1`, `y` from 0
/// to `dim.y - 1`, `z` like `x`. `MultiBlockArray::Get` rotates that list by the
/// BlockValue rotation (asm.il 89728-89773); at rotation 0 the quaternion is
/// identity, so the raw list is the answer.
pub const Offset = struct { x: i8, y: i8, z: i8 };

pub const max_cells: usize = 256;

pub const Offsets = struct {
    n: u16 = 0,
    items: [max_cells]Offset = undefined,

    pub fn slice(self: *const Offsets) []const Offset {
        return self.items[0..self.n];
    }
};

fn axisLo(dim: u8) i32 {
    // C# integer division on a positive value: truncating.
    return -@divTrunc(@as(i32, dim), 2);
}

fn axisHi(dim: u8) i32 {
    const half: f32 = @as(f32, @floatFromInt(dim)) / 2.0 + 0.1;
    return @as(i32, @round(half)) - 1;
}

/// Cell offsets for a `MultiBlockDim`. Returns a single (0,0,0) for 1x1x1.
/// Dimensions whose cell count exceeds `max_cells` yield nothing: writing a
/// partial multiblock would leave orphan children pointing at no parent.
pub fn offsetsFor(dim_x: u8, dim_y: u8, dim_z: u8) Offsets {
    var out: Offsets = .{};
    if (dim_x == 0 or dim_y == 0 or dim_z == 0) return out;
    const cells = @as(usize, dim_x) * @as(usize, dim_y) * @as(usize, dim_z);
    if (cells > max_cells) return out;
    var x = axisLo(dim_x);
    const x_hi = axisHi(dim_x);
    while (x <= x_hi) : (x += 1) {
        var y: i32 = 0;
        while (y < dim_y) : (y += 1) {
            var z = axisLo(dim_z);
            const z_hi = axisHi(dim_z);
            while (z <= z_hi) : (z += 1) {
                if (out.n >= max_cells) return .{};
                out.items[out.n] = .{ .x = @intCast(x), .y = @intCast(y), .z = @intCast(z) };
                out.n += 1;
            }
        }
    }
    return out;
}

/// Child rawData for a cell at `off` from the parent: same block value with
/// `ischild` set and `parent*` = -off, packed the way the setters do it
/// (`parentx = meta - 8`, `parenty = rotationAndMeta3 - 32`, `parentz = meta2 - 8`;
/// asm.il 140882-140960). Returns null when an offset does not fit those fields,
/// so an oversized multiblock is skipped rather than mis-encoded.
pub fn childRaw(parent_raw: u32, off: Offset) ?u32 {
    const px: i32 = -@as(i32, off.x);
    const py: i32 = -@as(i32, off.y);
    const pz: i32 = -@as(i32, off.z);
    // meta and meta2 are 4 bits (value + 8 in 0..15); rotationAndMeta3 is 6 bits.
    if (px < -8 or px > 7) return null;
    if (pz < -8 or pz > 7) return null;
    if (py < -32 or py > 31) return null;
    var raw = parent_raw | ischild_bit;
    raw = (raw & ~(nibble << meta_shift)) | (@as(u32, @intCast(px + 8)) << meta_shift);
    raw = (raw & ~(nibble << meta2_shift)) | (@as(u32, @intCast(pz + 8)) << meta2_shift);
    raw = (raw & ~(six_bits << rot_meta3_shift)) | (@as(u32, @intCast(py + 32)) << rot_meta3_shift);
    return raw;
}

pub const Placement = struct {
    x: i32,
    y: i32,
    z: i32,
    /// Full BlockValue rawData of the decoration (type + rotation 0).
    raw: u32,
    /// Cell offsets; a single (0,0,0) entry means a plain single block.
    offsets: Offsets,
};

/// Cells actually written (0 when the placement was skipped).
pub fn apply(world: *store.World, p: Placement) !usize {
    const cells = p.offsets.slice();
    if (cells.len == 0) return 0;
    // Existing multiblock at the anchor: stock leaves the position alone.
    if (try isMultiBlockAnchor(world, p)) return 0;

    if (cells.len == 1 and cells[0].x == 0 and cells[0].y == 0 and cells[0].z == 0) {
        // Single block: air only.
        if (try world.blockWorld(p.x, p.y, p.z) != world.terrain_ids.air) return 0;
        try world.setBlockDecoWorld(p.x, p.y, p.z, p.raw);
        return 1;
    }

    // Multiblock: encode every child before writing anything, so a cell that
    // cannot be encoded aborts the whole decoration instead of half-writing it.
    var raws: [max_cells]u32 = undefined;
    for (cells, 0..) |off, i| {
        if (off.x == 0 and off.y == 0 and off.z == 0) {
            raws[i] = p.raw;
        } else {
            raws[i] = childRaw(p.raw, off) orelse return 0;
        }
    }
    for (cells, 0..) |off, i| {
        try world.setBlockDecoWorld(p.x + off.x, p.y + off.y, p.z + off.z, raws[i]);
    }
    return cells.len;
}

/// True when the anchor cell already holds a decoration parent or child, which is
/// stock's `Block.isMultiBlock` guard. zdtd has no per-block multiblock flag, so
/// the check is on the value we would have written: `ischild`, or the exact same
/// block type already standing there.
fn isMultiBlockAnchor(world: *store.World, p: Placement) !bool {
    const t = store.World.worldToChunk(p.x, p.z);
    const c = try world.getOrCreate(t.pos);
    const existing = c.rawAt(t.lx, p.y, t.lz);
    if (existing & ischild_bit != 0) return true;
    return (existing & 0xffff) == (p.raw & 0xffff) and (existing & 0xffff) != world.terrain_ids.air;
}

test "single block dim yields one zero offset" {
    const o = offsetsFor(1, 1, 1);
    try std.testing.expectEqual(@as(u16, 1), o.n);
    try std.testing.expectEqual(Offset{ .x = 0, .y = 0, .z = 0 }, o.items[0]);
}

test "1x7x1 tree stacks straight up" {
    const o = offsetsFor(1, 7, 1);
    try std.testing.expectEqual(@as(u16, 7), o.n);
    for (o.slice(), 0..) |off, i| {
        try std.testing.expectEqual(@as(i8, 0), off.x);
        try std.testing.expectEqual(@as(i8, 0), off.z);
        try std.testing.expectEqual(@as(i8, @intCast(i)), off.y);
    }
}

test "3x2x3 boulder centres on x and z and rises on y" {
    const o = offsetsFor(3, 2, 3);
    try std.testing.expectEqual(@as(u16, 18), o.n);
    var min_x: i8 = 127;
    var max_x: i8 = -128;
    var max_y: i8 = -128;
    for (o.slice()) |off| {
        min_x = @min(min_x, off.x);
        max_x = @max(max_x, off.x);
        max_y = @max(max_y, off.y);
    }
    try std.testing.expectEqual(@as(i8, -1), min_x);
    try std.testing.expectEqual(@as(i8, 1), max_x);
    try std.testing.expectEqual(@as(i8, 1), max_y);
}

test "even dims match the stock rounding" {
    // dim 2: x from -(2/2) = -1 to RoundToInt(1.1) - 1 = 0.
    const o = offsetsFor(2, 1, 2);
    try std.testing.expectEqual(@as(u16, 4), o.n);
    var saw_neg = false;
    var saw_zero = false;
    for (o.slice()) |off| {
        try std.testing.expect(off.x == -1 or off.x == 0);
        saw_neg = saw_neg or off.x == -1;
        saw_zero = saw_zero or off.x == 0;
    }
    try std.testing.expect(saw_neg and saw_zero);
}

test "degenerate and oversized dims place nothing" {
    try std.testing.expectEqual(@as(u16, 0), offsetsFor(0, 4, 1).n);
    try std.testing.expectEqual(@as(u16, 0), offsetsFor(1, 0, 1).n);
    try std.testing.expectEqual(@as(u16, 0), offsetsFor(9, 9, 9).n);
}

test "child raw encodes ischild and the negated parent offset" {
    const parent: u32 = 24629;
    const child = childRaw(parent, .{ .x = 0, .y = 3, .z = 0 }).?;
    try std.testing.expect(child & ischild_bit != 0);
    try std.testing.expectEqual(@as(u32, 24629), child & 0xffff);
    // parenty = rotationAndMeta3 - 32 must read back as -3.
    const rot_meta3: i32 = @intCast((child >> rot_meta3_shift) & six_bits);
    try std.testing.expectEqual(@as(i32, -3), rot_meta3 - 32);
    const meta: i32 = @intCast((child >> meta_shift) & nibble);
    try std.testing.expectEqual(@as(i32, 0), meta - 8);
    const meta2: i32 = @intCast((child >> meta2_shift) & nibble);
    try std.testing.expectEqual(@as(i32, 0), meta2 - 8);

    // Negative offsets round-trip too (boulder cells at -1 on x and z).
    const corner = childRaw(parent, .{ .x = -1, .y = 0, .z = -1 }).?;
    const cx: i32 = @as(i32, @intCast((corner >> meta_shift) & nibble)) - 8;
    const cz: i32 = @as(i32, @intCast((corner >> meta2_shift) & nibble)) - 8;
    try std.testing.expectEqual(@as(i32, 1), cx);
    try std.testing.expectEqual(@as(i32, 1), cz);
}

test "child raw refuses offsets the bit fields cannot hold" {
    try std.testing.expectEqual(@as(?u32, null), childRaw(1, .{ .x = 9, .y = 0, .z = 0 }));
    try std.testing.expectEqual(@as(?u32, null), childRaw(1, .{ .x = 0, .y = 0, .z = 9 }));
    try std.testing.expectEqual(@as(?u32, null), childRaw(1, .{ .x = 0, .y = 33, .z = 0 }));
}

/// `dir` is a caller-owned scratch dir (tmpDir), so tests never write into the
/// repo root.
fn testWorld(dir: []const u8) !store.World {
    var w = try store.World.init(std.testing.allocator, dir);
    w.terrain_ids = .{};
    return w;
}

test "single block deco only fills air and leaves terrain height alone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var w = try testWorld(dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)]);
    defer w.deinit();
    const h = try w.heightWorld(4, 4);
    const before = try w.blockWorld(4, h, 4);

    const n = try apply(&w, .{ .x = 4, .y = h + 1, .z = 4, .raw = 24626, .offsets = offsetsFor(1, 1, 1) });
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u16, 24626), try w.blockWorld(4, h + 1, 4));
    // Terrain surface must not follow the tree up: spawn placement, void rescue
    // and the deco height callback all read heightWorld.
    try std.testing.expectEqual(h, try w.heightWorld(4, 4));
    try std.testing.expectEqual(before, try w.blockWorld(4, h, 4));
    // Ground below is untouched.
    try std.testing.expect(try w.blockWorld(4, h - 1, 4) != 24626);

    // Occupied cell: a second, different single block must not overwrite.
    const again = try apply(&w, .{ .x = 4, .y = h + 1, .z = 4, .raw = 24629, .offsets = offsetsFor(1, 1, 1) });
    try std.testing.expectEqual(@as(usize, 0), again);
    try std.testing.expectEqual(@as(u16, 24626), try w.blockWorld(4, h + 1, 4));
}

test "multiblock tree writes parent plus children" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var w = try testWorld(dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)]);
    defer w.deinit();
    const h = try w.heightWorld(9, 11);
    const n = try apply(&w, .{ .x = 9, .y = h + 1, .z = 11, .raw = 24629, .offsets = offsetsFor(1, 7, 1) });
    try std.testing.expectEqual(@as(usize, 7), n);

    const t = store.World.worldToChunk(9, 11);
    const c = try w.getOrCreate(t.pos);
    const parent = c.rawAt(t.lx, h + 1, t.lz);
    try std.testing.expectEqual(@as(u32, 24629), parent);
    try std.testing.expect(parent & ischild_bit == 0);
    var dy: i32 = 1;
    while (dy < 7) : (dy += 1) {
        const child = c.rawAt(t.lx, h + 1 + dy, t.lz);
        try std.testing.expectEqual(@as(u32, 24629), child & 0xffff);
        try std.testing.expect(child & ischild_bit != 0);
        const py: i32 = @as(i32, @intCast((child >> rot_meta3_shift) & six_bits)) - 32;
        try std.testing.expectEqual(-dy, py);
    }
    try std.testing.expectEqual(h, try w.heightWorld(9, 11));

    // Re-running the same placement is a no-op: the anchor is already a tree.
    try std.testing.expectEqual(@as(usize, 0), try apply(&w, .{ .x = 9, .y = h + 1, .z = 11, .raw = 24629, .offsets = offsetsFor(1, 7, 1) }));
    // A different species onto an existing multiblock child is also skipped.
    try std.testing.expectEqual(@as(usize, 0), try apply(&w, .{ .x = 9, .y = h + 3, .z = 11, .raw = 24626, .offsets = offsetsFor(1, 1, 1) }));
}

test "multiblock spanning a chunk edge writes into both chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var w = try testWorld(dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)]);
    defer w.deinit();
    const h = try w.heightWorld(15, 15);
    const n = try apply(&w, .{ .x = 15, .y = h + 1, .z = 15, .raw = 24629, .offsets = offsetsFor(3, 2, 3) });
    try std.testing.expectEqual(@as(usize, 18), n);
    try std.testing.expectEqual(@as(u16, 24629), try w.blockWorld(16, h + 1, 16));
    try std.testing.expectEqual(@as(u16, 24629), try w.blockWorld(14, h + 1, 14));
    // Neither chunk's surface height moved.
    try std.testing.expectEqual(h, try w.heightWorld(16, 16));
    try std.testing.expectEqual(h, try w.heightWorld(14, 14));
}
