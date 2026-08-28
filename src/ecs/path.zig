//! Lightweight grid path helpers for zombie chase (greedy, BFS, A*).
//!
//! The grid is 2D (XZ) but every cell carries the feet Y a body would stand at,
//! supplied by the `StepFn` move predicate. Nodes are still keyed on (x,z)
//! alone: a column reachable at two heights (a bridge over a tunnel) resolves to
//! whichever height the search reached first. That keeps the node table and the
//! caps unchanged and is accurate for the surface-plus-POI shapes zdtd has.

const std = @import("std");

pub const max_path: usize = 32;

pub const Point = struct { x: i32, z: i32, y: i32 };

/// `step(ctx, from_x, from_z, from_y, to_x, to_z)` returns the feet Y a body
/// standing at (from_x, from_y, from_z) would occupy after moving one cell to
/// (to_x, to_z), or null when the move is blocked: a wall, no headroom, or a
/// drop deeper than the body takes. A plain "is this cell solid" test cannot
/// express step-up, drop or a POI floor under a roof, so the predicate returns
/// the destination height rather than a bool.
pub const StepFn = *const fn (?*anyopaque, i32, i32, i32, i32, i32) ?i32;

pub const Path = struct {
    points: [max_path]Point = undefined,
    len: usize = 0,
    cursor: usize = 0,

    pub fn clear(self: *Path) void {
        self.len = 0;
        self.cursor = 0;
    }

    pub fn next(self: *Path) ?Point {
        if (self.cursor >= self.len) return null;
        const p = self.points[self.cursor];
        self.cursor += 1;
        return p;
    }
};

/// Open-addressed coord→node-index map for BFS/A* dedup. Fixed 512 slots
/// (2x max node cap, so load factor <= 0.5); 1 KiB, lives on the stack.
const NodeMap = struct {
    const cap: usize = 512;
    const empty: u16 = 0xffff;
    table: [cap]u16 = .{empty} ** cap,

    fn slot(x: i32, z: i32) usize {
        const ux: u32 = @bitCast(x);
        const uz: u32 = @bitCast(z);
        return (ux *% 0x9e3779b1 ^ uz *% 0x85ebca77) & (cap - 1);
    }

    fn get(self: *const NodeMap, xs: []const i32, zs: []const i32, x: i32, z: i32) ?usize {
        var i = slot(x, z);
        while (self.table[i] != empty) : (i = (i + 1) & (cap - 1)) {
            const n = self.table[i];
            if (xs[n] == x and zs[n] == z) return n;
        }
        return null;
    }

    fn put(self: *NodeMap, x: i32, z: i32, n: usize) void {
        var i = slot(x, z);
        while (self.table[i] != empty) i = (i + 1) & (cap - 1);
        self.table[i] = @intCast(n);
    }
};

/// Greedy walk toward goal, following the move predicate one cell at a time.
pub fn greedyToward(
    path: *Path,
    sx: i32,
    sz: i32,
    sy: i32,
    gx: i32,
    gz: i32,
    max_steps: usize,
    ctx: ?*anyopaque,
    step: StepFn,
) void {
    path.clear();
    var x = sx;
    var z = sz;
    var y = sy;
    var steps: usize = 0;
    const limit = @min(max_steps, max_path);
    while (steps < limit) : (steps += 1) {
        const dx = gx - x;
        const dz = gz - z;
        if (dx == 0 and dz == 0) break;
        const along_x = @abs(dx) >= @abs(dz);
        // Preferred move first, then the two sidesteps on the other axis.
        var cand: [3][2]i32 = undefined;
        if (along_x) {
            cand[0] = .{ x + if (dx > 0) @as(i32, 1) else -1, z };
            cand[1] = .{ x, z + if (dz >= 0) @as(i32, 1) else -1 };
            cand[2] = .{ x, z + if (dz >= 0) @as(i32, -1) else 1 };
        } else {
            cand[0] = .{ x, z + if (dz > 0) @as(i32, 1) else -1 };
            cand[1] = .{ x + if (dx >= 0) @as(i32, 1) else -1, z };
            cand[2] = .{ x + if (dx >= 0) @as(i32, -1) else 1, z };
        }
        var moved = false;
        for (cand) |cd| {
            const ny = step(ctx, x, z, y, cd[0], cd[1]) orelse continue;
            path.points[path.len] = .{ .x = cd[0], .z = cd[1], .y = ny };
            path.len += 1;
            x = cd[0];
            z = cd[1];
            y = ny;
            moved = true;
            break;
        }
        if (!moved) break;
    }
}

/// BFS shortest path on 4-neighborhood. Caps nodes; greedy fallback.
pub fn bfsToward(
    path: *Path,
    sx: i32,
    sz: i32,
    sy: i32,
    gx: i32,
    gz: i32,
    max_expand: usize,
    ctx: ?*anyopaque,
    step: StepFn,
) void {
    path.clear();
    if (sx == gx and sz == gz) return;
    const max_nodes: usize = 256;
    var qx: [max_nodes]i32 = undefined;
    var qz: [max_nodes]i32 = undefined;
    var qy: [max_nodes]i32 = undefined;
    var parent: [max_nodes]i32 = .{-1} ** max_nodes;
    var seen_n: usize = 0;
    var qh: usize = 0;
    var qt: usize = 0;
    var seen: NodeMap = .{};
    qx[qt] = sx;
    qz[qt] = sz;
    qy[qt] = sy;
    qt += 1;
    seen.put(sx, sz, 0);
    seen_n = 1;
    var found: i32 = -1;
    var expanded: usize = 0;
    const dirs = [_][2]i32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } };
    while (qh < qt and expanded < max_expand) : (expanded += 1) {
        const cx = qx[qh];
        const cz = qz[qh];
        const cy = qy[qh];
        const ci: i32 = @intCast(qh);
        qh += 1;
        if (cx == gx and cz == gz) {
            found = ci;
            break;
        }
        for (dirs) |d| {
            const nx = cx + d[0];
            const nz = cz + d[1];
            if (seen.get(qx[0..seen_n], qz[0..seen_n], nx, nz) != null) continue;
            const ny = step(ctx, cx, cz, cy, nx, nz) orelse continue;
            if (qt >= max_nodes) break;
            qx[qt] = nx;
            qz[qt] = nz;
            qy[qt] = ny;
            parent[qt] = ci;
            seen.put(nx, nz, seen_n);
            seen_n += 1;
            qt += 1;
        }
    }
    if (found < 0) {
        greedyToward(path, sx, sz, sy, gx, gz, max_path, ctx, step);
        return;
    }
    reconstruct(path, &qx, &qz, &qy, &parent, found);
}

fn manhattan(ax: i32, az: i32, bx: i32, bz: i32) u32 {
    const dx: u32 = @intCast(@abs(ax - bx));
    const dz: u32 = @intCast(@abs(az - bz));
    return dx + dz;
}

/// Binary min-heap entry: f-cost primary, node index secondary (deterministic ties).
const OpenEntry = struct { f: u32, ni: u16 };

fn openLess(a: OpenEntry, b: OpenEntry) bool {
    return a.f < b.f or (a.f == b.f and a.ni < b.ni);
}

fn openPush(heap: []OpenEntry, n: *usize, e: OpenEntry) void {
    if (n.* >= heap.len) return;
    var i = n.*;
    n.* = i + 1;
    while (i > 0) {
        const p = (i - 1) / 2;
        if (!openLess(e, heap[p])) break;
        heap[i] = heap[p];
        i = p;
    }
    heap[i] = e;
}

fn openPop(heap: []OpenEntry, n: *usize) ?OpenEntry {
    if (n.* == 0) return null;
    const out = heap[0];
    n.* -= 1;
    if (n.* == 0) return out;
    const last = heap[n.*];
    var i: usize = 0;
    while (true) {
        const l = i * 2 + 1;
        if (l >= n.*) break;
        var best = l;
        const r = l + 1;
        if (r < n.* and openLess(heap[r], heap[l])) best = r;
        if (!openLess(heap[best], last)) break;
        heap[i] = heap[best];
        i = best;
    }
    heap[i] = last;
    return out;
}

/// Grid A* on 4-neighborhood, Manhattan heuristic. Deterministic equal-f ties
/// (lower node index wins). Caps expand/node table; greedy fallback.
/// Open set is a binary heap (was linear scan extract-min each expand).
/// Returns the number of nodes expanded so callers can meter a tick budget.
pub fn aStarToward(
    path: *Path,
    sx: i32,
    sz: i32,
    sy: i32,
    gx: i32,
    gz: i32,
    max_expand: usize,
    ctx: ?*anyopaque,
    step: StepFn,
) usize {
    path.clear();
    if (sx == gx and sz == gz) return 0;

    const max_nodes: usize = 256;
    // Heap may hold stale entries after g improves; size above node cap.
    const heap_cap: usize = 512;
    var nx_arr: [max_nodes]i32 = undefined;
    var nz_arr: [max_nodes]i32 = undefined;
    var ny_arr: [max_nodes]i32 = undefined;
    var cost_so_far: [max_nodes]u32 = .{std.math.maxInt(u32)} ** max_nodes;
    var parent: [max_nodes]i32 = .{-1} ** max_nodes;
    var closed: [max_nodes]bool = .{false} ** max_nodes;
    var n_nodes: usize = 0;

    var node_map: NodeMap = .{};

    var heap: [heap_cap]OpenEntry = undefined;
    var heap_n: usize = 0;

    nx_arr[0] = sx;
    nz_arr[0] = sz;
    ny_arr[0] = sy;
    cost_so_far[0] = 0;
    n_nodes = 1;
    node_map.put(sx, sz, 0);
    openPush(heap[0..], &heap_n, .{ .f = manhattan(sx, sz, gx, gz), .ni = 0 });

    var found: i32 = -1;
    var expanded: usize = 0;
    const dirs = [_][2]i32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } };
    const span = manhattan(sx, sz, gx, gz) + 8;

    while (expanded < max_expand) : (expanded += 1) {
        const popped = openPop(heap[0..], &heap_n) orelse break;
        const ci: usize = popped.ni;
        if (closed[ci]) continue;
        // Lazy heap: skip stale entries whose f no longer matches current g.
        const cur_f = cost_so_far[ci] + manhattan(nx_arr[ci], nz_arr[ci], gx, gz);
        if (popped.f != cur_f) continue;
        closed[ci] = true;

        const cx = nx_arr[ci];
        const cz = nz_arr[ci];
        const cy = ny_arr[ci];
        if (cx == gx and cz == gz) {
            found = @intCast(ci);
            break;
        }

        for (dirs) |d| {
            const nx = cx + d[0];
            const nz = cz + d[1];
            if (manhattan(sx, sz, nx, nz) > span) continue;

            const tent_g = cost_so_far[ci] + 1;
            const existing = node_map.get(nx_arr[0..n_nodes], nz_arr[0..n_nodes], nx, nz);
            if (existing) |e| {
                if (closed[e]) continue;
                if (tent_g >= cost_so_far[e]) continue;
            } else if (n_nodes >= max_nodes) continue;
            // Probe last: it is the expensive call (terrain lock / column scan)
            // and the cheap rejects above already dropped most neighbours.
            const ny = step(ctx, cx, cz, cy, nx, nz) orelse continue;
            const ni: usize = existing orelse blk: {
                const e = n_nodes;
                nx_arr[e] = nx;
                nz_arr[e] = nz;
                node_map.put(nx, nz, e);
                n_nodes += 1;
                break :blk e;
            };
            ny_arr[ni] = ny;
            cost_so_far[ni] = tent_g;
            parent[ni] = @intCast(ci);
            const f = tent_g + manhattan(nx, nz, gx, gz);
            openPush(heap[0..], &heap_n, .{ .f = f, .ni = @intCast(ni) });
        }
    }

    if (found < 0) {
        greedyToward(path, sx, sz, sy, gx, gz, max_path, ctx, step);
        return expanded;
    }
    reconstruct(path, &nx_arr, &nz_arr, &ny_arr, &parent, found);
    return expanded;
}

fn reconstruct(
    path: *Path,
    xs: *const [256]i32,
    zs: *const [256]i32,
    ys: *const [256]i32,
    parent: *const [256]i32,
    found: i32,
) void {
    var chain: [max_path]Point = undefined;
    var cn: usize = 0;
    var cur: i32 = found;
    while (cur >= 0 and cn < max_path) {
        const i: usize = @intCast(cur);
        chain[cn] = .{ .x = xs[i], .z = zs[i], .y = ys[i] };
        cn += 1;
        cur = parent[i];
    }
    var i: isize = @intCast(cn);
    i -= 2;
    while (i >= 0 and path.len < max_path) : (i -= 1) {
        path.points[path.len] = chain[@intCast(i)];
        path.len += 1;
    }
}

/// Flat open grid: every move succeeds and keeps the current height.
pub fn openStep(_: ?*anyopaque, _: i32, _: i32, from_y: i32, _: i32, _: i32) ?i32 {
    return from_y;
}

const test_wall = struct {
    fn s(_: ?*anyopaque, _: i32, _: i32, from_y: i32, x: i32, z: i32) ?i32 {
        if (x == 2 and z >= 0 and z <= 2) return null;
        return from_y;
    }
}.s;

const test_wall_wide = struct {
    fn s(_: ?*anyopaque, _: i32, _: i32, from_y: i32, x: i32, z: i32) ?i32 {
        if (x == 2 and z >= -2 and z <= 2) return null;
        return from_y;
    }
}.s;

/// Terrain ramp: column height is x (one step up per cell east), so the body
/// can walk east but never climb the two-block ledge at x == 5.
const test_ramp = struct {
    fn s(_: ?*anyopaque, _: i32, _: i32, from_y: i32, x: i32, _: i32) ?i32 {
        const h: i32 = if (x >= 5) 6 else x;
        if (h - from_y > 1) return null;
        return h;
    }
}.s;

test "greedy path moves toward" {
    var p: Path = .{};
    greedyToward(&p, 0, 0, 64, 5, 0, 16, null, openStep);
    try std.testing.expect(p.len >= 5);
    try std.testing.expectEqual(@as(i32, 1), p.points[0].x);
    try std.testing.expectEqual(@as(i32, 64), p.points[0].y);
}

test "bfs path around obstacle" {
    var p: Path = .{};
    bfsToward(&p, 0, 0, 64, 4, 0, 200, null, test_wall);
    try std.testing.expect(p.len >= 4);
    for (p.points[0..p.len]) |pt| {
        try std.testing.expect(!(pt.x == 2 and pt.z >= 0 and pt.z <= 2));
    }
}

test "aStar path around simple obstacle" {
    var p: Path = .{};
    _ = aStarToward(&p, 0, 0, 64, 4, 0, 200, null, test_wall_wide);
    try std.testing.expect(p.len >= 4);
    for (p.points[0..p.len]) |pt| {
        try std.testing.expect(!(pt.x == 2 and pt.z >= -2 and pt.z <= 2));
    }
    const last = p.points[p.len - 1];
    try std.testing.expect(last.x == 4 and last.z == 0);
    try std.testing.expect(p.len <= 12);
}

test "aStar open field is straight" {
    var p: Path = .{};
    const expanded = aStarToward(&p, 0, 0, 64, 3, 0, 64, null, openStep);
    try std.testing.expectEqual(@as(usize, 3), p.len);
    try std.testing.expectEqual(@as(i32, 1), p.points[0].x);
    try std.testing.expectEqual(@as(i32, 2), p.points[1].x);
    try std.testing.expectEqual(@as(i32, 3), p.points[2].x);
    try std.testing.expect(expanded > 0 and expanded <= 64);
}

test "aStar carries feet height up a ramp and refuses the ledge" {
    var p: Path = .{};
    _ = aStarToward(&p, 0, 0, 0, 4, 0, 200, null, test_ramp);
    try std.testing.expectEqual(@as(usize, 4), p.len);
    for (p.points[0..p.len], 1..) |pt, i| {
        try std.testing.expectEqual(@as(i32, @intCast(i)), pt.y);
    }
    // x == 5 is a two-block ledge from x == 4: unreachable, so A* falls back to
    // greedy and stops at the wall instead of teleporting up it.
    var q: Path = .{};
    _ = aStarToward(&q, 0, 0, 0, 8, 0, 200, null, test_ramp);
    for (q.points[0..q.len]) |pt| try std.testing.expect(pt.x < 5);
}

test "aStar is deterministic for the same inputs" {
    var a: Path = .{};
    var b: Path = .{};
    const ea = aStarToward(&a, -3, -3, 64, 6, 5, 200, null, test_wall_wide);
    const eb = aStarToward(&b, -3, -3, 64, 6, 5, 200, null, test_wall_wide);
    try std.testing.expectEqual(ea, eb);
    try std.testing.expectEqual(a.len, b.len);
    try std.testing.expectEqualSlices(Point, a.points[0..a.len], b.points[0..b.len]);
}

test "aStar never returns a step the predicate refused" {
    // Deterministic sweep over pseudo-random blocked grids and height fields.
    // The fuzz target in src/fuzz.zig drives the same invariants from a seed;
    // this keeps them covered in the ordinary test run.
    const Grid = struct {
        seed: u32,
        fn h(self: *const @This(), x: i32, z: i32) u32 {
            const ux: u32 = @bitCast(x);
            const uz: u32 = @bitCast(z);
            return (ux *% 0x9e3779b1) ^ (uz *% 0x85ebca77) ^ (self.seed *% 0xc2b2ae35);
        }
        fn step(ctx: ?*anyopaque, _: i32, _: i32, from_y: i32, x: i32, z: i32) ?i32 {
            const self: *const @This() = @ptrCast(@alignCast(ctx.?));
            const v = self.h(x, z);
            if (v % 5 == 0) return null;
            const y: i32 = 60 + @as(i32, @intCast((v >> 8) % 4));
            if (y > from_y + 1 or y < from_y - 3) return null;
            return y;
        }
    };
    var seed: u32 = 1;
    while (seed <= 200) : (seed += 1) {
        var grid: Grid = .{ .seed = seed };
        const sx: i32 = @intCast(seed % 7);
        const sz: i32 = @intCast((seed / 7) % 7);
        const gx: i32 = sx + @as(i32, @intCast(seed % 11)) - 5;
        const gz: i32 = sz + @as(i32, @intCast((seed / 11) % 11)) - 5;
        const sy: i32 = 60 + @as(i32, @intCast((grid.h(sx, sz) >> 8) % 4));
        var p: Path = .{};
        _ = aStarToward(&p, sx, sz, sy, gx, gz, 96, &grid, Grid.step);
        var px = sx;
        var pz = sz;
        var py = sy;
        for (p.points[0..p.len]) |pt| {
            try std.testing.expectEqual(@as(u32, 1), @abs(pt.x - px) + @abs(pt.z - pz));
            const allowed = Grid.step(&grid, px, pz, py, pt.x, pt.z) orelse
                return error.PathCrossesBlockedCell;
            try std.testing.expectEqual(allowed, pt.y);
            px = pt.x;
            pz = pt.z;
            py = pt.y;
        }
    }
}

test "aStar sealed goal falls back to greedy without reaching it" {
    const Sealed = struct {
        fn s(_: ?*anyopaque, _: i32, _: i32, from_y: i32, x: i32, _: i32) ?i32 {
            if (x == 2) return null;
            return from_y;
        }
    };
    var p: Path = .{};
    const expanded = aStarToward(&p, 0, 0, 64, 4, 0, 96, null, Sealed.s);
    try std.testing.expect(expanded > 0);
    for (p.points[0..p.len]) |pt| try std.testing.expect(pt.x != 2);
    if (p.len > 0) {
        const last = p.points[p.len - 1];
        try std.testing.expect(!(last.x == 4 and last.z == 0));
    }
}
