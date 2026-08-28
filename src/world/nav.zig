//! nav.zig — coarse walkability grid + BFS pathfinding over loaded chunks.
//!
//! Borrowed in spirit from the Recast/Detour navmesh used by the Unvanquished
//! bots (see `../7dtd-fps-bots/docs/oss-fps-bot-survey.md`): the host owns the
//! navigation data (world geometry), the wasm bot guest owns the decisions
//! (ADR 0026). This is a lightweight grid, not a full Recast tile mesh: cells
//! are `cell_size` blocks, walkable when a body can stand there
//! (`Chunk.standableY`), connected when the surface step is small. Paths are
//! BFS over the grid. No heap allocation on the query path (fixed arrays).

const std = @import("std");
const store = @import("store.zig");
const World = store.World;
const Chunk = store.Chunk;
const chunk_size = store.chunk_size;
const body_height = store.body_height;
const max_step_up = store.max_step_up;

pub const cell_size: i32 = 4; // blocks per nav cell
pub const cells_per_chunk: i32 = chunk_size / cell_size; // 4
/// Search region cap: 64x64 cells around the bounding box (4096 cells).
pub const max_region = 64;
pub const max_cells = max_region * max_region;
/// Path waypoint cap (cells along the path, excluding the start).
pub const max_waypoints = 32;
/// Max surface step between connected cells (one block step + tolerance).
const max_step: i32 = max_step_up + 1;

pub const Cell = struct { x: i32, z: i32 };

/// Surface feet-Y of the cell center, or null when a body cannot stand there.
/// Fails closed: a chunk that is not loaded is not walkable.
pub fn cellSurfaceY(w: *const World, wx: i32, wz: i32) ?i32 {
    const bx = wx * cell_size + cell_size / 2;
    const bz = wz * cell_size + cell_size / 2;
    const t = World.worldToChunk(bx, bz);
    const ch = w.chunks.getPtr(t.pos.hash()) orelse return null;
    return ch.standableY(t.lx, t.lz, w.yDim() - body_height, max_step_up, w.yDim());
}

/// BFS path in cell coords from (sx, sz) to (tx, tz). Writes the cell path
/// (first cell after the start, ending at the target cell) into `out` and
/// returns the waypoint count, or 0 when no path exists, a cell is
/// unwalkable, or the search cap is hit. `out` must hold max_waypoints cells.
pub fn findPath(w: *const World, sx: i32, sz: i32, tx: i32, tz: i32, out: []Cell) usize {
    // Bound the search region around the two endpoints.
    const min_x = @min(sx, tx) - max_region / 2;
    const min_z = @min(sz, tz) - max_region / 2;
    const width = max_region;
    const height = max_region;
    if (sx < min_x or sx >= min_x + width) return 0;
    if (sz < min_z or sz >= min_z + height) return 0;
    if (tx < min_x or tx >= min_x + width) return 0;
    if (tz < min_z or tz >= min_z + height) return 0;

    const start_surf = cellSurfaceY(w, sx, sz) orelse return 0;
    const target_surf = cellSurfaceY(w, tx, tz) orelse return 0;

    var visited: [max_cells]bool = [_]bool{false} ** max_cells;
    var parent: [max_cells]i32 = [_]i32{-1} ** max_cells;
    var frontier: [max_cells]i32 = undefined;
    var front_head: usize = 0;
    var front_tail: usize = 0;

    const idxOf = struct {
        fn idx(ix: i32, iz: i32, mx: i32, mz: i32, wd: i32) usize {
            return @intCast((ix - mx) + (iz - mz) * wd);
        }
    }.idx;

    const start_idx = idxOf(sx, sz, min_x, min_z, width);
    const target_idx = idxOf(tx, tz, min_x, min_z, width);
    visited[start_idx] = true;
    frontier[front_tail] = @intCast(start_idx);
    front_tail += 1;

    // 4-neighbour movement: bots step orthogonally between cells.
    const dxs = [4]i32{ 1, -1, 0, 0 };
    const dzs = [4]i32{ 0, 0, 1, -1 };

    var found = false;
    while (front_head < front_tail) : (front_head += 1) {
        const cur = frontier[front_head];
        const cx = @mod(cur, width) + min_x;
        const cz = @divFloor(cur, width) + min_z;
        if (cur == target_idx) {
            found = true;
            break;
        }
        const cur_surf = cellSurfaceY(w, cx, cz) orelse continue;
        var d: usize = 0;
        while (d < 4) : (d += 1) {
            const nx = cx + dxs[d];
            const nz = cz + dzs[d];
            if (nx < min_x or nx >= min_x + width) continue;
            if (nz < min_z or nz >= min_z + height) continue;
            const ni = idxOf(nx, nz, min_x, min_z, width);
            if (visited[ni]) continue;
            const n_surf = cellSurfaceY(w, nx, nz) orelse continue;
            const step = @abs(n_surf - cur_surf);
            if (step > max_step) continue;
            visited[ni] = true;
            parent[ni] = @intCast(cur);
            if (front_tail < max_cells) {
                frontier[front_tail] = @intCast(ni);
                front_tail += 1;
            }
        }
    }
    if (!found) return 0;

    // Reconstruct: target back to start, then reverse.
    var rev: [max_waypoints]Cell = undefined;
    var n_rev: usize = 0;
    var cur: i32 = @intCast(target_idx);
    while (cur != start_idx and n_rev < max_waypoints) : (n_rev += 1) {
        const cx = @mod(cur, width) + min_x;
        const cz = @divFloor(cur, width) + min_z;
        rev[n_rev] = .{ .x = cx, .z = cz };
        cur = parent[@intCast(cur)];
        if (cur < 0) return 0;
    }
    // Reverse into out (drop the target cell if we hit the cap).
    const count = n_rev;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        out[i] = rev[count - 1 - i];
    }
    // Surface sanity: the path must end where a body can stand.
    _ = start_surf;
    _ = target_surf;
    return count;
}

test "nav: flat floor cells are walkable and path across chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();

    // Raised platform at y=72 across two chunks (x 0..31, z 0..15). The world
    // has a default ground lower down; the platform must win as the surface.
    var x: i32 = 0;
    while (x < 32) : (x += 1) {
        var z: i32 = 0;
        while (z < 16) : (z += 1) {
            try w.setBlockWorld(x, 72, z, 1);
        }
    }

    // Cell (0,0) center (2,2): standable on the platform -> feet y 73.
    try std.testing.expectEqual(@as(?i32, 73), cellSurfaceY(&w, 0, 0));

    // Path from cell (0,0) to (5,0): crosses the chunk border (chunk 0 -> 1).
    var path: [max_waypoints]Cell = undefined;
    const n = findPath(&w, 0, 0, 5, 0, &path);
    try std.testing.expect(n > 0);
    try std.testing.expectEqual(@as(i32, 5), path[n - 1].x);
    try std.testing.expectEqual(@as(i32, 0), path[n - 1].z);
}

test "nav: a wall blocks the path, gaps route around" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();

    var x: i32 = 0;
    while (x < 64) : (x += 1) {
        var z: i32 = 0;
        while (z < 32) : (z += 1) {
            try w.setBlockWorld(x, 72, z, 1);
        }
    }
    // Wall spanning the full cell band z=8..11 (cells z==2), x=8..24, y=72..75
    // (four blocks so a two-block-tall body cannot step over). The band ends
    // inside the search region so a path can route around its left gap.
    x = 8;
    while (x < 24) : (x += 1) {
        var z: i32 = 8;
        while (z < 12) : (z += 1) {
            var y: i32 = 72;
            while (y < 76) : (y += 1) {
                try w.setBlockWorld(x, y, z, 1);
            }
        }
    }

    var path: [max_waypoints]Cell = undefined;
    // From cell (2,0) to (10,4): the straight line crosses the wall band (z==2
    // at x=8..24), so the path must route around it via the left gap.
    const n = findPath(&w, 2, 0, 10, 4, &path);
    try std.testing.expect(n > 0);
    // No waypoint may sit inside the wall band.
    for (path[0..n]) |c| {
        // Walled cells are z==2 with centers inside the wall x=8..24: cells x=2..5.
        try std.testing.expect(!(c.z == 2 and c.x >= 2 and c.x <= 5));
    }
}

test "nav: an unloaded chunk is unwalkable, path to it fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();

    // Floor only in chunk (0,0): x 0..15, z 0..15 at y=72.
    var x: i32 = 0;
    while (x < 16) : (x += 1) {
        var z: i32 = 0;
        while (z < 16) : (z += 1) {
            try w.setBlockWorld(x, 72, z, 1);
        }
    }
    // Cell (0,0) walkable on the floor; cell (4,0) center (18,2) is in chunk
    // (1,0) which was never created: fail-closed unwalkable.
    try std.testing.expectEqual(@as(?i32, 73), cellSurfaceY(&w, 0, 0));
    try std.testing.expectEqual(@as(?i32, null), cellSurfaceY(&w, 4, 0));

    var path: [max_waypoints]Cell = undefined;
    try std.testing.expectEqual(@as(usize, 0), findPath(&w, 0, 0, 4, 0, &path));
}
