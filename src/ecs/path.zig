//! Lightweight grid path helper for zombie chase (no commercial A*).

const std = @import("std");

pub const max_path: usize = 32;

pub const Point = struct { x: i32, z: i32 };

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

/// Greedy walk toward goal on a solid-ground heuristic (no full graph).
/// `solid` returns true if cell blocks movement at feet y.
pub fn greedyToward(
    path: *Path,
    sx: i32,
    sz: i32,
    gx: i32,
    gz: i32,
    max_steps: usize,
    solid: *const fn (x: i32, z: i32) bool,
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
        // sidestep if blocked
        if (solid(nx, nz)) {
            if (@abs(dx) >= @abs(dz)) {
                nz = z + if (dz >= 0) @as(i32, 1) else -1;
                nx = x;
                if (solid(nx, nz)) {
                    nz = z + if (dz >= 0) @as(i32, -1) else 1;
                    if (solid(nx, nz)) break;
                }
            } else {
                nx = x + if (dx >= 0) @as(i32, 1) else -1;
                nz = z;
                if (solid(nx, nz)) {
                    nx = x + if (dx >= 0) @as(i32, -1) else 1;
                    if (solid(nx, nz)) break;
                }
            }
        }
        path.points[path.len] = .{ .x = nx, .z = nz };
        path.len += 1;
        x = nx;
        z = nz;
    }
}

/// BFS shortest path on 4-neighborhood (A* with zero heuristic). Caps nodes.
/// `solid` true = blocked. ponytail: small open set, upgrade if long-range needed.
pub fn bfsToward(
    path: *Path,
    sx: i32,
    sz: i32,
    gx: i32,
    gz: i32,
    max_expand: usize,
    solid: *const fn (x: i32, z: i32) bool,
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
            if (solid(nx, nz)) continue;
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
        // Fall back to greedy if BFS fails.
        greedyToward(path, sx, sz, gx, gz, max_path, solid);
        return;
    }
    // Reconstruct reverse then flip into path.
    var chain: [max_path]Point = undefined;
    var cn: usize = 0;
    var cur: i32 = found;
    while (cur >= 0 and cn < max_path) {
        chain[cn] = .{ .x = qx[@intCast(cur)], .z = qz[@intCast(cur)] };
        cn += 1;
        cur = parent[@intCast(cur)];
    }
    // chain[cn-1] is start; skip start, walk toward goal.
    var i: isize = @intCast(cn);
    i -= 2; // first step after start
    while (i >= 0 and path.len < max_path) : (i -= 1) {
        path.points[path.len] = chain[@intCast(i)];
        path.len += 1;
    }
}

test "greedy path moves toward" {
    const open = struct {
        fn s(_: i32, _: i32) bool {
            return false;
        }
    }.s;
    var p: Path = .{};
    greedyToward(&p, 0, 0, 5, 0, 16, open);
    try std.testing.expect(p.len >= 5);
    try std.testing.expectEqual(@as(i32, 1), p.points[0].x);
}

test "bfs path around obstacle" {
    const wall = struct {
        fn s(x: i32, z: i32) bool {
            // wall at x=2 for z=0..2, gap at z=3
            return x == 2 and z >= 0 and z <= 2;
        }
    }.s;
    var p: Path = .{};
    bfsToward(&p, 0, 0, 4, 0, 200, wall);
    try std.testing.expect(p.len >= 4);
    // must not step on wall
    for (p.points[0..p.len]) |pt| {
        try std.testing.expect(!(pt.x == 2 and pt.z >= 0 and pt.z <= 2));
    }
}
