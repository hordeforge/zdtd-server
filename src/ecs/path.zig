//! Lightweight grid path helpers for zombie chase (greedy, BFS, A*).

const std = @import("std");

pub const max_path: usize = 32;

pub const Point = struct { x: i32, z: i32 };

/// `solid(ctx, x, z)` true = cell blocks movement.
pub const SolidFn = *const fn (?*anyopaque, i32, i32) bool;

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

    pub fn peek(self: *const Path) ?Point {
        if (self.cursor >= self.len) return null;
        return self.points[self.cursor];
    }
};

/// Greedy walk toward goal. `solid` true = blocked.
pub fn greedyToward(
    path: *Path,
    sx: i32,
    sz: i32,
    gx: i32,
    gz: i32,
    max_steps: usize,
    ctx: ?*anyopaque,
    solid: SolidFn,
) void {
    path.clear();
    var x = sx;
    var z = sz;
    var steps: usize = 0;
    const limit = @min(max_steps, max_path);
    while (steps < limit) : (steps += 1) {
        const dx = gx - x;
        const dz = gz - z;
        if (dx == 0 and dz == 0) break;
        var nx = x;
        var nz = z;
        if (@abs(dx) >= @abs(dz)) {
            nx += if (dx > 0) @as(i32, 1) else -1;
        } else {
            nz += if (dz > 0) @as(i32, 1) else -1;
        }
        if (solid(ctx, nx, nz)) {
            if (@abs(dx) >= @abs(dz)) {
                nz = z + if (dz >= 0) @as(i32, 1) else -1;
                nx = x;
                if (solid(ctx, nx, nz)) {
                    nz = z + if (dz >= 0) @as(i32, -1) else 1;
                    if (solid(ctx, nx, nz)) break;
                }
            } else {
                nx = x + if (dx >= 0) @as(i32, 1) else -1;
                nz = z;
                if (solid(ctx, nx, nz)) {
                    nx = x + if (dx >= 0) @as(i32, -1) else 1;
                    if (solid(ctx, nx, nz)) break;
                }
            }
        }
        path.points[path.len] = .{ .x = nx, .z = nz };
        path.len += 1;
        x = nx;
        z = nz;
    }
}

/// BFS shortest path on 4-neighborhood. Caps nodes; greedy fallback.
pub fn bfsToward(
    path: *Path,
    sx: i32,
    sz: i32,
    gx: i32,
    gz: i32,
    max_expand: usize,
    ctx: ?*anyopaque,
    solid: SolidFn,
) void {
    path.clear();
    if (sx == gx and sz == gz) return;
    const max_nodes: usize = 256;
    var qx: [max_nodes]i32 = undefined;
    var qz: [max_nodes]i32 = undefined;
    var parent: [max_nodes]i32 = .{-1} ** max_nodes;
    var seen_x: [max_nodes]i32 = undefined;
    var seen_z: [max_nodes]i32 = undefined;
    var seen_n: usize = 0;
    var qh: usize = 0;
    var qt: usize = 0;
    const key = struct {
        fn has(xs: []const i32, zs: []const i32, n: usize, x: i32, z: i32) bool {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (xs[i] == x and zs[i] == z) return true;
            }
            return false;
        }
    }.has;
    qx[qt] = sx;
    qz[qt] = sz;
    qt += 1;
    seen_x[0] = sx;
    seen_z[0] = sz;
    seen_n = 1;
    var found: i32 = -1;
    var expanded: usize = 0;
    const dirs = [_][2]i32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } };
    while (qh < qt and expanded < max_expand) : (expanded += 1) {
        const cx = qx[qh];
        const cz = qz[qh];
        const ci: i32 = @intCast(qh);
        qh += 1;
        if (cx == gx and cz == gz) {
            found = ci;
            break;
        }
        for (dirs) |d| {
            const nx = cx + d[0];
            const nz = cz + d[1];
            if (solid(ctx, nx, nz)) continue;
            if (key(seen_x[0..seen_n], seen_z[0..seen_n], seen_n, nx, nz)) continue;
            if (qt >= max_nodes or seen_n >= max_nodes) break;
            qx[qt] = nx;
            qz[qt] = nz;
            parent[qt] = ci;
            seen_x[seen_n] = nx;
            seen_z[seen_n] = nz;
            seen_n += 1;
            qt += 1;
        }
    }
    if (found < 0) {
        greedyToward(path, sx, sz, gx, gz, max_path, ctx, solid);
        return;
    }
    reconstruct(path, &qx, &qz, &parent, found);
}

fn manhattan(ax: i32, az: i32, bx: i32, bz: i32) u32 {
    const dx: u32 = @intCast(@abs(ax - bx));
    const dz: u32 = @intCast(@abs(az - bz));
    return dx + dz;
}

/// Grid A* on 4-neighborhood, Manhattan heuristic. Deterministic equal-f ties
/// (lower node index wins). Caps expand/node table; greedy fallback.
pub fn aStarToward(
    path: *Path,
    sx: i32,
    sz: i32,
    gx: i32,
    gz: i32,
    max_expand: usize,
    ctx: ?*anyopaque,
    solid: SolidFn,
) void {
    path.clear();
    if (sx == gx and sz == gz) return;
    if (solid(ctx, gx, gz)) {
        greedyToward(path, sx, sz, gx, gz, max_path, ctx, solid);
        return;
    }

    const max_nodes: usize = 256;
    var nx_arr: [max_nodes]i32 = undefined;
    var nz_arr: [max_nodes]i32 = undefined;
    var g_cost: [max_nodes]u32 = .{std.math.maxInt(u32)} ** max_nodes;
    var parent: [max_nodes]i32 = .{-1} ** max_nodes;
    var closed: [max_nodes]bool = .{false} ** max_nodes;
    var n_nodes: usize = 0;

    const find = struct {
        fn idx(xs: []const i32, zs: []const i32, n: usize, x: i32, z: i32) ?usize {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (xs[i] == x and zs[i] == z) return i;
            }
            return null;
        }
    }.idx;

    var open: [max_nodes]u16 = undefined;
    var open_n: usize = 0;

    nx_arr[0] = sx;
    nz_arr[0] = sz;
    g_cost[0] = 0;
    n_nodes = 1;
    open[0] = 0;
    open_n = 1;

    var found: i32 = -1;
    var expanded: usize = 0;
    const dirs = [_][2]i32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } };
    const span = manhattan(sx, sz, gx, gz) + 8;

    while (open_n > 0 and expanded < max_expand) : (expanded += 1) {
        var best_oi: usize = 0;
        var best_f: u32 = std.math.maxInt(u32);
        var best_idx: u16 = 0;
        var oi: usize = 0;
        while (oi < open_n) : (oi += 1) {
            const ni = open[oi];
            const f = g_cost[ni] + manhattan(nx_arr[ni], nz_arr[ni], gx, gz);
            if (f < best_f or (f == best_f and ni < best_idx)) {
                best_f = f;
                best_oi = oi;
                best_idx = ni;
            }
        }
        open_n -= 1;
        open[best_oi] = open[open_n];
        const ci: usize = best_idx;
        if (closed[ci]) continue;
        closed[ci] = true;

        const cx = nx_arr[ci];
        const cz = nz_arr[ci];
        if (cx == gx and cz == gz) {
            found = @intCast(ci);
            break;
        }

        for (dirs) |d| {
            const nx = cx + d[0];
            const nz = cz + d[1];
            if (solid(ctx, nx, nz)) continue;
            if (manhattan(sx, sz, nx, nz) > span) continue;

            const tent_g = g_cost[ci] + 1;
            const existing = find(nx_arr[0..n_nodes], nz_arr[0..n_nodes], n_nodes, nx, nz);
            const ni: usize = blk: {
                if (existing) |e| {
                    if (closed[e]) continue;
                    if (tent_g >= g_cost[e]) continue;
                    break :blk e;
                }
                if (n_nodes >= max_nodes) continue;
                const e = n_nodes;
                nx_arr[e] = nx;
                nz_arr[e] = nz;
                n_nodes += 1;
                break :blk e;
            };
            g_cost[ni] = tent_g;
            parent[ni] = @intCast(ci);
            var in_open = false;
            var k: usize = 0;
            while (k < open_n) : (k += 1) {
                if (open[k] == ni) {
                    in_open = true;
                    break;
                }
            }
            if (!in_open and open_n < max_nodes) {
                open[open_n] = @intCast(ni);
                open_n += 1;
            }
        }
    }

    if (found < 0) {
        greedyToward(path, sx, sz, gx, gz, max_path, ctx, solid);
        return;
    }
    reconstruct(path, &nx_arr, &nz_arr, &parent, found);
}

fn reconstruct(
    path: *Path,
    xs: *const [256]i32,
    zs: *const [256]i32,
    parent: *const [256]i32,
    found: i32,
) void {
    var chain: [max_path]Point = undefined;
    var cn: usize = 0;
    var cur: i32 = found;
    while (cur >= 0 and cn < max_path) {
        chain[cn] = .{ .x = xs[@intCast(cur)], .z = zs[@intCast(cur)] };
        cn += 1;
        cur = parent[@intCast(cur)];
    }
    var i: isize = @intCast(cn);
    i -= 2;
    while (i >= 0 and path.len < max_path) : (i -= 1) {
        path.points[path.len] = chain[@intCast(i)];
        path.len += 1;
    }
}

const test_open = struct {
    fn s(_: ?*anyopaque, _: i32, _: i32) bool {
        return false;
    }
}.s;

const test_wall = struct {
    fn s(_: ?*anyopaque, x: i32, z: i32) bool {
        return x == 2 and z >= 0 and z <= 2;
    }
}.s;

const test_wall_wide = struct {
    fn s(_: ?*anyopaque, x: i32, z: i32) bool {
        return x == 2 and z >= -2 and z <= 2;
    }
}.s;

test "greedy path moves toward" {
    var p: Path = .{};
    greedyToward(&p, 0, 0, 5, 0, 16, null, test_open);
    try std.testing.expect(p.len >= 5);
    try std.testing.expectEqual(@as(i32, 1), p.points[0].x);
}

test "bfs path around obstacle" {
    var p: Path = .{};
    bfsToward(&p, 0, 0, 4, 0, 200, null, test_wall);
    try std.testing.expect(p.len >= 4);
    for (p.points[0..p.len]) |pt| {
        try std.testing.expect(!(pt.x == 2 and pt.z >= 0 and pt.z <= 2));
    }
}

test "aStar path around simple obstacle" {
    var p: Path = .{};
    aStarToward(&p, 0, 0, 4, 0, 200, null, test_wall_wide);
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
    aStarToward(&p, 0, 0, 3, 0, 64, null, test_open);
    try std.testing.expectEqual(@as(usize, 3), p.len);
    try std.testing.expectEqual(@as(i32, 1), p.points[0].x);
    try std.testing.expectEqual(@as(i32, 2), p.points[1].x);
    try std.testing.expectEqual(@as(i32, 3), p.points[2].x);
}
