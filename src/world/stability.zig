//! Stock block stability plane and falling-block trigger (RE:
//! `../7dtd-engine-research/docs/stability.md`, dumps 2026-08-06).
//!
//! Port of `StabilityCalculator` + `StabilityInitializer` + `ChannelCalculator`
//! to the SoA chunk store. The plane is a per-block byte (0..15): 15 full
//! support, 0 unsupported (the only value that falls), non-support blocks
//! capped at 1. Horizontal spread decays 1 per block step; vertical spread
//! keeps the value going up and decays 1 going down; a block whose
//! `StabilitySupport` is false never carries more than 1.
//!
//! The plane is derived state, never persisted: a chunk computes it once on
//! first touch (reset + distribute, like stock ResetStability +
//! DistributeStability). The reset writes a conservative upper bound (15 for
//! every support block), so an untouched floating structure reads as stable;
//! the first edit under it relaxes the affected region to the true fixpoint
//! and fells it, matching the client's own collapse. Spread never enters a
//! chunk whose plane is not computed yet (its first-touch distribute covers
//! it), so the recursion is bounded per chunk. Block edits run the incremental
//! path: placing sets the block's byte from its supported neighbors and
//! re-spreads; removing relaxes the affected region to a fixpoint and returns
//! the positions whose byte hit 0, which the caller turns into falling blocks
//! / air.
//!
//! Hot path discipline: no heap on the tick. The removal relaxation uses a
//! fixed queue and a fixed open-addressing visited set (named caps, drop past
//! the cap); the caller owns the fixed `fallen` output array.

const std = @import("std");
const store = @import("store.zig");

/// Stability grid cell value for a fully-supported block (stock
/// StabilityInitializer fills to maxStability; 15 matches the stock grid's
/// full value, RE: stability.md).
pub const stability_full: u8 = 15;
/// Cap on one removal relaxation: cells visited beyond this are dropped
/// (stock physicsIsolation stops at 1000 per run; we give the whole removal
/// a larger budget so a big structure still collapses in one pass).
pub const max_relax_cells: usize = 8192;
/// Cap on the caller-provided fallen output per removal pass.
pub const max_fallen: usize = 4096;

pub const Pos = struct { x: i32, y: i32, z: i32 };

/// Per-block facts probed by the caller (game.zig resolves through the
/// maxdamage table + block id -> name). Keeps this module table-agnostic.
pub const Facts = struct {
    support: bool,
    ignore: bool,
};

pub const FactsFn = *const fn (ctx: ?*anyopaque, id: u16) Facts;

/// One horizontal neighbour offset list (N/S/E/W), matching stock
/// Vector3i.HORIZONTAL_DIRECTIONS order.
const hdirs = [_][3]i32{ .{ 0, 0, 1 }, .{ 1, 0, 0 }, .{ 0, 0, -1 }, .{ -1, 0, 0 } };
/// All six directions (stock Vector3i.AllDirections).
const dirs = [_][3]i32{
    .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 }, .{ 1, 0, 0 }, .{ 0, 0, -1 }, .{ -1, 0, 0 },
};

fn chunkOf(w: *store.World, px: i32, pz: i32) ?*store.Chunk {
    const pos = store.ChunkPos{ .x = px, .z = pz };
    return w.chunks.get(pos.hash());
}

/// Block id at a world position, or 0 when the chunk is not resident.
fn blockAtWorld(w: *store.World, x: i32, y: i32, z: i32) u16 {
    if (y < 0 or y >= w.yDim()) return 0;
    const t = store.World.worldToChunk(x, z);
    const c = chunkOf(w, t.pos.x, t.pos.z) orelse return 0;
    return c.blockAt(t.lx, y, t.lz);
}

/// Stability byte at a world position; 0 when the chunk is not resident or the
/// plane is not computed.
fn stabAtWorld(w: *store.World, x: i32, y: i32, z: i32) u8 {
    if (y < 0 or y >= w.yDim()) return 0;
    const t = store.World.worldToChunk(x, z);
    const c = chunkOf(w, t.pos.x, t.pos.z) orelse return 0;
    return c.stabilityAt(t.lx, y, t.lz);
}

/// Compute the plane for a chunk if absent: reset (15 support / 1 non-support)
/// then distribute. Init/load path (allocation allowed).
pub fn ensureComputed(w: *store.World, c: *store.Chunk, allocator: std.mem.Allocator, fctx: ?*anyopaque, facts: FactsFn) !void {
    if (c.stability != null) return;
    const plane = try c.ensureStability(allocator);
    _ = plane;
    var x: i32 = 0;
    while (x < 16) : (x += 1) {
        var z: i32 = 0;
        while (z < 16) : (z += 1) {
            var y: i32 = 0;
            while (y < w.yDim()) : (y += 1) {
                const id = c.blockAt(x, y, z);
                if (id == 0) continue;
                const f = facts(fctx, id);
                if (f.ignore) continue;
                c.setStabilityByte(x, y, z, if (f.support) stability_full else 1);
            }
        }
    }
    distribute(w, c, fctx, facts);
}

/// Stock StabilityInitializer::DistributeStability: spread from every block
/// whose byte is > 1. `w` is needed for cross-chunk neighbour reads.
pub fn distribute(w: *store.World, c: *store.Chunk, fctx: ?*anyopaque, facts: FactsFn) void {
    var x: i32 = 0;
    while (x < 16) : (x += 1) {
        var z: i32 = 0;
        while (z < 16) : (z += 1) {
            var y: i32 = 0;
            while (y < w.yDim()) : (y += 1) {
                const s = c.stabilityAt(x, y, z);
                if (s > 1) spreadHorizontal(w, c, x, y, z, s, fctx, facts);
            }
        }
    }
}

/// StabilityInitializer::spreadHorizontal: decay 1 per step, cap 1 on
/// non-support blocks, recurse horizontally and vertically from support blocks.
fn spreadHorizontal(w: *store.World, c: *store.Chunk, lx: i32, y: i32, lz: i32, stab: u8, fctx: ?*anyopaque, facts: FactsFn) void {
    if (stab <= 1) return;
    const v: u8 = stab - 1;
    for (hdirs) |d| {
        const nx = lx + d[0];
        const nz = lz + d[2];
        // Resolve the (possibly neighbour) chunk for this cell.
        if (nx < 0 or nx >= 16 or nz < 0 or nz >= 16) {
            const nc = chunkOf(w, c.pos.x + @divFloor(nx, 16), c.pos.z + @divFloor(nz, 16)) orelse continue;
            spreadCell(w, nc, @mod(nx, 16), y, @mod(nz, 16), v, fctx, facts);
        } else {
            spreadCell(w, c, nx, y, nz, v, fctx, facts);
        }
    }
}

/// Spread into one cell: skip air/liquid/ignore, cap 1 on non-support, set if
/// higher, then recurse (horizontal + vertical) from support blocks.
fn spreadCell(w: *store.World, c: *store.Chunk, lx: i32, y: i32, lz: i32, v: u8, fctx: ?*anyopaque, facts: FactsFn) void {
    if (y < 0 or y >= w.yDim()) return;
    // A chunk without a plane reads 0 everywhere, so the value check below
    // would never stop the recursion; never spread into an uncomputed chunk.
    // Its own first-touch distribute covers it.
    if (c.stability == null) return;
    const id = c.blockAt(lx, y, lz);
    if (id == 0 or w.isWaterId(id)) return;
    const f = facts(fctx, id);
    if (f.ignore) return;
    var vv = v;
    if (!f.support) vv = @min(vv, 1);
    if (vv <= c.stabilityAt(lx, y, lz)) return;
    c.setStabilityByte(lx, y, lz, vv);
    if (!f.support) return;
    spreadHorizontal(w, c, lx, y, lz, vv, fctx, facts);
    spreadVertical(w, c, lx, y, lz, vv, fctx, facts);
}

/// StabilityInitializer::spreadVertical: keep the value going up (cap 1 on
/// non-support), decay 1 per block going down.
fn spreadVertical(w: *store.World, c: *store.Chunk, lx: i32, y: i32, lz: i32, stab: u8, fctx: ?*anyopaque, facts: FactsFn) void {
    // Upward from y+1 with the same value.
    var uy: i32 = y + 1;
    while (uy < w.yDim()) : (uy += 1) {
        const id = c.blockAt(lx, uy, lz);
        if (id == 0 or w.isWaterId(id)) break;
        const f = facts(fctx, id);
        if (f.ignore) break;
        var v = stab;
        if (!f.support) v = @min(v, 1);
        if (v <= c.stabilityAt(lx, uy, lz)) break;
        c.setStabilityByte(lx, uy, lz, v);
        if (!f.support) break;
        spreadHorizontal(w, c, lx, uy, lz, v, fctx, facts);
    }
    // Downward from y-1, decaying one per step.
    var vv: u8 = stab;
    var dy: i32 = y - 1;
    while (dy >= 0 and vv > 1) : (dy -= 1) {
        vv -= 1;
        const id = c.blockAt(lx, dy, lz);
        if (id == 0 or w.isWaterId(id)) break;
        const f = facts(fctx, id);
        if (f.ignore) break;
        var v = vv;
        if (!f.support) v = @min(v, 1);
        if (v <= c.stabilityAt(lx, dy, lz)) break;
        c.setStabilityByte(lx, dy, lz, v);
        if (!f.support) break;
        spreadHorizontal(w, c, lx, dy, lz, v, fctx, facts);
    }
}

/// Pack a world position into a u64 key for the visited set (y 8 bits, x/z 26
/// bits each, biased by 2^25 so negative coords are distinct; covers +-33M
/// blocks, far beyond any map).
fn posKey(x: i32, y: i32, z: i32) u64 {
    const bx: u64 = @as(u32, @bitCast(x +% (1 << 25))) & 0x3FFFFFF;
    const bz: u64 = @as(u32, @bitCast(z +% (1 << 25))) & 0x3FFFFFF;
    return bx << 34 | bz << 8 | @as(u64, @intCast(y & 0xFF));
}

/// ChannelCalculator::getMaxStabilityAround: max stability over the 6
/// neighbours whose block is StabilitySupport, plus the stability of the block
/// directly below. `from_down` is true when the max comes from below.
fn maxStabilityAround(w: *store.World, x: i32, y: i32, z: i32, fctx: ?*anyopaque, facts: FactsFn) struct { max: u8, down: u8, from_down: bool } {
    var max: u8 = 0;
    var down: u8 = 0;
    for (dirs) |d| {
        const nx = x + d[0];
        const ny = y + d[1];
        const nz = z + d[2];
        if (ny < 0 or ny >= w.yDim()) continue;
        const id = blockAtWorld(w, nx, ny, nz);
        if (id == 0) continue;
        const f = facts(fctx, id);
        if (!f.support) continue;
        const s = stabAtWorld(w, nx, ny, nz);
        if (d[1] == -1) down = s;
        max = @max(max, s);
    }
    return .{ .max = max, .down = down, .from_down = max == down };
}

/// ChannelCalculator::ChangeStability core: the new stability for a block
/// given its supported neighbours.
fn recomputeStability(w: *store.World, x: i32, y: i32, z: i32, id: u16, fctx: ?*anyopaque, facts: FactsFn) u8 {
    const m = maxStabilityAround(w, x, y, z, fctx, facts);
    var v: i32 = if (m.from_down) m.max else m.max - 1;
    v = @max(v, 0);
    const f = facts(fctx, id);
    if (!f.support) v = @min(v, 1);
    return @intCast(v);
}

/// ChannelCalculator::IsBlockSupportedByNeighbor: any 6-neighbour with
/// stability > 1 counts as support.
fn isSupportedByNeighbor(w: *store.World, x: i32, y: i32, z: i32) bool {
    for (dirs) |d| {
        const nx = x + d[0];
        const ny = y + d[1];
        const nz = z + d[2];
        if (ny < 0 or ny >= w.yDim()) continue;
        const t = store.World.worldToChunk(nx, nz);
        const c = chunkOf(w, t.pos.x, t.pos.z) orelse continue;
        const id = c.blockAt(t.lx, ny, t.lz);
        if (id == 0 or w.isWaterId(id)) continue;
        if (c.stabilityAt(t.lx, ny, t.lz) > 1) return true;
    }
    return false;
}

/// Remove a block at (x,y,z) (the caller already set it to air) and recompute
/// the plane per the stock ChannelCalculator removal: the dependency chain
/// that was supported by the removed block is zeroed, then every affected
/// neighbour is relaxed to its new fixpoint. Returns the positions whose
/// stability hit 0 (caller converts them to falling blocks / air). No heap:
/// fixed stack + visited set + change list; drops past the named caps.
pub fn removeBlockAt(
    w: *store.World,
    x: i32,
    y: i32,
    z: i32,
    allocator: std.mem.Allocator,
    fctx: ?*anyopaque,
    facts: FactsFn,
    fallen: []Pos,
) usize {
    var n_fallen: usize = 0;
    if (y < 0 or y >= w.yDim()) return 0;

    const t0 = store.World.worldToChunk(x, z);
    const c0 = chunkOf(w, t0.pos.x, t0.pos.z) orelse return 0;
    ensureComputed(w, c0, allocator, fctx, facts) catch return 0;
    const removed_stab = c0.stabilityAt(t0.lx, y, t0.lz);
    c0.setStabilityByte(t0.lx, y, t0.lz, 0);

    var stack: [max_relax_cells]struct { pos: Pos, stab: u8 } = undefined;
    var visited: [max_relax_cells]u64 = undefined;
    var change: [max_relax_cells]Pos = undefined;
    var sp: usize = 0;
    var v_n: usize = 0;
    var chg_n: usize = 0;

    stack[0] = .{ .pos = .{ .x = x, .y = y, .z = z }, .stab = removed_stab };
    sp = 1;
    visited[0] = posKey(x, y, z);
    v_n = 1;

    while (sp > 0) {
        sp -= 1;
        const cur = stack[sp].pos;
        const is_root = (cur.x == x and cur.y == y and cur.z == z);
        // Stock zeroes each cell as the recursion enters it (the root was
        // zeroed above; re-zeroing is harmless).
        {
            const tz = store.World.worldToChunk(cur.x, cur.z);
            if (chunkOf(w, tz.pos.x, tz.pos.z)) |cz| cz.setStabilityByte(tz.lx, cur.y, tz.lz, 0);
        }
        // The dependency chain falls unconditionally (stock stab0); the root
        // is already air and was handled by the caller, so it is not reported.
        if (!is_root and n_fallen < fallen.len) {
            fallen[n_fallen] = cur;
            n_fallen += 1;
        }
        const cur_stab = stack[sp].stab;
        for (dirs) |d| {
            const nx = cur.x + d[0];
            const ny = cur.y + d[1];
            const nz = cur.z + d[2];
            if (ny < 0 or ny >= w.yDim()) continue;
            const key = posKey(nx, ny, nz);
            var dup = false;
            var vi: usize = 0;
            while (vi < v_n) : (vi += 1) {
                if (visited[vi] == key) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            if (v_n >= visited.len) return n_fallen; // named cap: drop the rest

            const t = store.World.worldToChunk(nx, nz);
            const c = chunkOf(w, t.pos.x, t.pos.z) orelse continue;
            const id = c.blockAt(t.lx, ny, t.lz);
            if (id == 0 or w.isWaterId(id)) continue;
            const f = facts(fctx, id);
            if (f.ignore) continue;
            ensureComputed(w, c, allocator, fctx, facts) catch continue;
            const nbr_stab = c.stabilityAt(t.lx, ny, t.lz);
            if (nbr_stab == 1 and !f.support) {
                // A stability-1 non-support block: falls unless something else
                // still supports it (stock IsBlockSupportedByNeighbor).
                if (!isSupportedByNeighbor(w, nx, ny, nz)) {
                    c.setStabilityByte(t.lx, ny, t.lz, 0);
                    if (n_fallen < fallen.len) {
                        fallen[n_fallen] = .{ .x = nx, .y = ny, .z = nz };
                        n_fallen += 1;
                    }
                }
                visited[v_n] = key;
                v_n += 1;
                continue;
            }
            visited[v_n] = key;
            v_n += 1;
            // Stock recursion: descend into the dependency chain (the cell was
            // supported by this level's cell), otherwise queue a recompute.
            // `cur_stab > 0` guards the u8 underflow when the removed cell's
            // plane was computed after the caller aired it (the lazy first
            // computation sees the cell empty, so removed_stab is 0; nothing
            // can be "one less than" the bottom).
            if ((cur_stab > 0 and nbr_stab == cur_stab - 1) or (d[1] == 1 and nbr_stab == cur_stab)) {
                if (sp >= stack.len) return n_fallen;
                stack[sp] = .{ .pos = .{ .x = nx, .y = ny, .z = nz }, .stab = nbr_stab };
                sp += 1;
            } else if (nbr_stab >= cur_stab) {
                if (chg_n < change.len) {
                    change[chg_n] = .{ .x = nx, .y = ny, .z = nz };
                    chg_n += 1;
                }
            }
        }
    }

    // Relax the affected neighbours to their fixpoint; a lowered cell
    // propagates to its own neighbours (stock ChangeStability recursion).
    var head: usize = 0;
    while (head < chg_n) : (head += 1) {
        const pos = change[head];
        const t = store.World.worldToChunk(pos.x, pos.z);
        const c = chunkOf(w, t.pos.x, t.pos.z) orelse continue;
        const id = c.blockAt(t.lx, pos.y, t.lz);
        if (id == 0 or w.isWaterId(id)) continue;
        const f = facts(fctx, id);
        if (f.ignore) continue;
        const cur_v = c.stabilityAt(t.lx, pos.y, t.lz);
        if (cur_v == 0) continue;
        const v = recomputeStability(w, pos.x, pos.y, pos.z, id, fctx, facts);
        if (v >= cur_v) continue;
        c.setStabilityByte(t.lx, pos.y, t.lz, v);
        if (v == 0) {
            if (n_fallen < fallen.len) {
                fallen[n_fallen] = pos;
                n_fallen += 1;
            }
        }
        // Propagate: neighbours of a lowered cell may lose support too.
        for (dirs) |d| {
            const nx = pos.x + d[0];
            const ny = pos.y + d[1];
            const nz = pos.z + d[2];
            if (ny < 0 or ny >= w.yDim()) continue;
            const key = posKey(nx, ny, nz);
            var dup = false;
            var vi: usize = 0;
            while (vi < v_n) : (vi += 1) {
                if (visited[vi] == key) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            if (v_n >= visited.len or chg_n >= change.len) return n_fallen;
            visited[v_n] = key;
            v_n += 1;
            change[chg_n] = .{ .x = nx, .y = ny, .z = nz };
            chg_n += 1;
        }
    }
    return n_fallen;
}

/// Place a block at (x,y,z) (the caller already wrote it) and spread its
/// stability into the region. Init/load path when it allocates a plane.
pub fn placeBlockAt(
    w: *store.World,
    x: i32,
    y: i32,
    z: i32,
    allocator: std.mem.Allocator,
    fctx: ?*anyopaque,
    facts: FactsFn,
) void {
    if (y < 0 or y >= w.yDim()) return;
    const t = store.World.worldToChunk(x, z);
    const c = chunkOf(w, t.pos.x, t.pos.z) orelse return;
    ensureComputed(w, c, allocator, fctx, facts) catch return;
    const id = c.blockAt(t.lx, y, t.lz);
    if (id == 0) return;
    const v = recomputeStability(w, x, y, z, id, fctx, facts);
    if (v <= c.stabilityAt(t.lx, y, t.lz)) return;
    c.setStabilityByte(t.lx, y, t.lz, v);
    if (v > 1) spreadHorizontal(w, c, t.lx, y, t.lz, v, fctx, facts);
}

const testing = std.testing;

/// Facts probe for tests: a fixed block id range where id 1 supports, id 2 is
/// non-support, id 3 ignores stability, everything else supports.
fn testFacts(_: ?*anyopaque, id: u16) Facts {
    return switch (id) {
        3 => .{ .support = false, .ignore = true },
        2 => .{ .support = false, .ignore = false },
        else => .{ .support = true, .ignore = false },
    };
}

/// Build a flat test world: air at and above `surface_y`, solid (id 1) below.
/// `dir` is a caller-owned scratch dir (tmpDir), so tests never write into the
/// repo tree and never see residue from a previous run.
fn testWorld(gpa: std.mem.Allocator, surface_y: i32, dir: []const u8) *store.World {
    const w = gpa.create(store.World) catch unreachable;
    w.* = store.World.init(gpa, dir) catch unreachable;
    var cx: i32 = 0;
    while (cx < 2) : (cx += 1) {
        var cz: i32 = 0;
        while (cz < 2) : (cz += 1) {
            const c = w.getOrCreate(.{ .x = cx, .z = cz }) catch unreachable;
            // Biome-layer regen fills surface blocks above surface_y; zero the
            // whole column so the world is exactly "terrain below, air above"
            // and the test placements are the only structure.
            var lx: i32 = 0;
            while (lx < 16) : (lx += 1) {
                var lz: i32 = 0;
                while (lz < 16) : (lz += 1) {
                    var y: i32 = 0;
                    while (y < 256) : (y += 1) {
                        c.setBlock(gpa, lx, y, lz, if (y < surface_y) 1 else 0) catch unreachable;
                    }
                }
            }
        }
    }
    return w;
}

test "stability: terrain supports a column; cutting the base fells it" {
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];

    const w = testWorld(gpa, 60, dir);
    defer {
        w.deinit();
        gpa.destroy(w);
    }
    // Column at (2, z=2) from y=60 up to 65 (4 blocks above the surface).
    var y: i32 = 60;
    while (y < 65) : (y += 1) {
        w.setBlockWorld(2, y, 2, 1) catch unreachable;
    }
    // First touch computes the plane for the column's chunk.
    const t = store.World.worldToChunk(2, 2);
    const c = blk: {
        const p = store.ChunkPos{ .x = t.pos.x, .z = t.pos.z };
        break :blk w.chunks.get(p.hash()).?;
    };
    try ensureComputed(w, c, gpa, null, testFacts);
    // Column base sits on terrain (15) and the blocks above inherit support.
    try testing.expectEqual(@as(u8, stability_full), c.stabilityAt(2, 60, 2));
    try testing.expectEqual(@as(u8, stability_full), c.stabilityAt(2, 64, 2));

    // Remove the base block; the four blocks above lose support and fall.
    w.setBlockWorld(2, 60, 2, 0) catch unreachable;
    var fallen: [max_fallen]Pos = undefined;
    const n = removeBlockAt(w, 2, 60, 2, gpa, null, testFacts, &fallen);
    try testing.expectEqual(@as(usize, 4), n);
    // Every fallen block is above the cut, in the column.
    for (fallen[0..n]) |p| {
        try testing.expectEqual(@as(i32, 2), p.x);
        try testing.expectEqual(@as(i32, 2), p.z);
        try testing.expect(p.y > 60 and p.y < 65);
    }
}

test "stability: overhang beyond support falls after the support goes" {
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];

    const w = testWorld(gpa, 60, dir);
    defer {
        w.deinit();
        gpa.destroy(w);
    }
    // Shelf: three blocks at y=61 (on terrain at 60), overhanging one block
    // beyond the base at y=61: (10,61,10), (11,61,10) hangs over air.
    w.setBlockWorld(10, 61, 10, 1) catch unreachable;
    w.setBlockWorld(11, 61, 10, 1) catch unreachable;
    const t = store.World.worldToChunk(10, 10);
    const c = blk: {
        const p = store.ChunkPos{ .x = t.pos.x, .z = t.pos.z };
        break :blk w.chunks.get(p.hash()).?;
    };
    try ensureComputed(w, c, gpa, null, testFacts);
    // The overhang keeps the base's stability (sideways spread at the same level).
    try testing.expectEqual(@as(u8, stability_full), c.stabilityAt(11, 61, 10));

    // Cut the base at (10,61,10): the overhang is now unsupported.
    w.setBlockWorld(10, 61, 10, 0) catch unreachable;
    var fallen: [max_fallen]Pos = undefined;
    const n = removeBlockAt(w, 10, 61, 10, gpa, null, testFacts, &fallen);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(i32, 11), fallen[0].x);
    try testing.expectEqual(@as(i32, 61), fallen[0].y);
    try testing.expectEqual(@as(i32, 10), fallen[0].z);
}

test "stability: non-support blocks cap at 1 and never carry support" {
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];

    const w = testWorld(gpa, 60, dir);
    defer {
        w.deinit();
        gpa.destroy(w);
    }
    // A non-support block (id 2) sitting on terrain, with a support block (id 1)
    // above it.
    w.setBlockWorld(4, 60, 4, 2) catch unreachable;
    w.setBlockWorld(4, 61, 4, 1) catch unreachable;
    const t = store.World.worldToChunk(4, 4);
    const c = blk: {
        const p = store.ChunkPos{ .x = t.pos.x, .z = t.pos.z };
        break :blk w.chunks.get(p.hash()).?;
    };
    try ensureComputed(w, c, gpa, null, testFacts);
    // The non-support block caps at 1; the block above it is stable (15).
    try testing.expectEqual(@as(u8, 1), c.stabilityAt(4, 60, 4));
    try testing.expectEqual(@as(u8, stability_full), c.stabilityAt(4, 61, 4));

    // Removing the non-support block: the support block above loses its only
    // support and falls; the terrain below stays.
    w.setBlockWorld(4, 60, 4, 0) catch unreachable;
    var fallen: [max_fallen]Pos = undefined;
    const n = removeBlockAt(w, 4, 60, 4, gpa, null, testFacts, &fallen);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(i32, 4), fallen[0].x);
    try testing.expectEqual(@as(i32, 61), fallen[0].y);
    try testing.expectEqual(@as(i32, 4), fallen[0].z);
}

test "stability: a dig whose plane computes after the cell is air does not underflow" {
    // The C2S dig handler airs the block (setBlockRawWorld) BEFORE the first
    // stability touch, so the lazy plane computes with the dug cell empty and
    // removed_stab reads 0. removeBlockAt must treat that as "nothing was
    // supported from below" instead of underflowing `cur_stab - 1` (the
    // pre-fix behaviour panicked on the first dig in any fresh chunk).
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];

    const w = testWorld(gpa, 60, dir);
    defer {
        w.deinit();
        gpa.destroy(w);
    }
    w.setBlockWorld(4, 61, 4, 1) catch unreachable;
    // Air the cell first, exactly like the dig handler does before
    // stabilityAfterSetBlock, then remove: no crash, nothing falls (the
    // plane cell was computed empty).
    w.setBlockWorld(4, 61, 4, 0) catch unreachable;
    var fallen: [max_fallen]Pos = undefined;
    const n = removeBlockAt(w, 4, 61, 4, gpa, null, testFacts, &fallen);
    try testing.expectEqual(@as(usize, 0), n);
}
