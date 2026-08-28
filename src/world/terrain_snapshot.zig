//! Read-mostly terrain footing snapshot for the A* inner loop.
//!
//! `Game.pathStepAt` is the pathfinder predicate: the feet Y a body can occupy
//! in the destination column, or blocked. Every probe takes the single
//! process-global `Game.terrain_mu` because it calls `World.getOrCreate`, and
//! A* runs on parallel AI workers with up to `path_max_expand * 4` probes per
//! replan. That makes it the hottest lock in the sim.
//!
//! This module rebuilds a per-column surface descriptor once per tick on the
//! main thread, before the AI phase, and answers probes lock-free. It is
//! conservative by construction:
//!
//!   * built with `chunks.getPtr`, never `getOrCreate`, so a hit returns the
//!     same footing the hook would have computed;
//!   * it only answers the surface case (feet one above the topmost solid
//!     block). A column whose surface is out of the body's step/drop band could
//!     still have an interior floor (cave, POI storey) that only a full column
//!     scan can find, so those probes return `null`;
//!   * a miss returns `null` and the caller falls through to the existing
//!     locked path, preserving the on-demand chunk generation side effect that
//!     A* triggers today.
//!
//! Nothing mutates blocks while AI workers run (`Game.step` order is net poll →
//! sim_entities → sleepers/block damage), so the snapshot is consistent for the
//! whole AI phase.
//!
//! Cap: `max_chunks` entries. With many widely separated players the window
//! truncates and the tail falls back to the locked hook; `misses` measures it.

const std = @import("std");
const store = @import("store.zig");

/// Chebyshev radius in chunks around each player ((2r+1)^2 chunks per player).
pub const snap_radius_chunks: i32 = 2;
/// Open-addressing slots (power of two). Load factor stays <= 0.5.
pub const cap: usize = 512;
/// Max chunks covered per rebuild.
pub const max_chunks: usize = 256;

/// Topmost non-air block Y per column, mirroring store.Chunk.heights. Kept
/// dense (max_chunks, not cap) because the table is 2x oversized for probing.
const ChunkCols = struct {
    surface: [256]u8 = .{0} ** 256,
};

pub const Snapshot = struct {
    keys: [cap]u64 = .{0} ** cap,
    used: [cap]bool = .{false} ** cap,
    /// Index into `cols` for a used slot.
    at: [cap]u16 = .{0} ** cap,
    cols: [max_chunks]ChunkCols = [_]ChunkCols{.{}} ** max_chunks,
    n: usize = 0,
    /// Column height of the world this snapshot was rebuilt from (wire
    /// profile; stock 256). Set in `rebuild`.
    y_dim: i32 = 256,
    /// Probes that fell through to the locked hook (window truncation or a
    /// non-resident chunk). Atomic: `solid` runs on parallel AI workers.
    misses: std.atomic.Value(u64) = .init(0),

    fn slotFor(key: u64) usize {
        // Same mix/probe shape as ecs/path.zig NodeMap.
        return @intCast((key *% 0x9e3779b97f4a7c15 >> 32) & (cap - 1));
    }

    pub fn clear(self: *Snapshot) void {
        @memset(&self.used, false);
        self.n = 0;
    }

    /// Insert `key` (or find it). Returns the dense `cols` index; null when the
    /// window is full or the key is already covered this rebuild.
    fn put(self: *Snapshot, key: u64) ?usize {
        var i = slotFor(key);
        var probes: usize = 0;
        while (probes < cap) : (probes += 1) {
            if (!self.used[i]) {
                if (self.n >= max_chunks) return null;
                self.used[i] = true;
                self.keys[i] = key;
                self.at[i] = @intCast(self.n);
                self.n += 1;
                return self.n - 1;
            }
            if (self.keys[i] == key) return null; // already covered this rebuild
            i = (i + 1) & (cap - 1);
        }
        return null;
    }

    fn find(self: *const Snapshot, key: u64) ?usize {
        var i = slotFor(key);
        var probes: usize = 0;
        while (probes < cap) : (probes += 1) {
            if (!self.used[i]) return null;
            if (self.keys[i] == key) return i;
            i = (i + 1) & (cap - 1);
        }
        return null;
    }

    /// Rebuild the window from resident chunks around `px`/`pz` (parallel
    /// arrays, same length). Player order and the dz/dx walk are fixed so the
    /// covered set is a pure function of the player positions.
    /// Returns the number of chunks covered.
    pub fn rebuild(self: *Snapshot, w: *store.World, px: []const f32, pz: []const f32) usize {
        std.debug.assert(px.len == pz.len);
        self.clear();
        self.y_dim = w.yDim();
        for (px, pz) |x, z| {
            const cx = @divFloor(@as(i32, @floor(x)), store.chunk_size);
            const cz = @divFloor(@as(i32, @floor(z)), store.chunk_size);
            var dz: i32 = -snap_radius_chunks;
            while (dz <= snap_radius_chunks) : (dz += 1) {
                var dx: i32 = -snap_radius_chunks;
                while (dx <= snap_radius_chunks) : (dx += 1) {
                    const pos: store.ChunkPos = .{ .x = cx + dx, .z = cz + dz };
                    const key = pos.hash();
                    // getPtr only: generating here would change which chunks
                    // exist and when, i.e. change sim outcomes.
                    const ch = w.chunks.getPtr(key) orelse continue;
                    const at = self.put(key) orelse continue;
                    fillCols(ch, &self.cols[at]);
                }
            }
        }
        return self.n;
    }

    fn fillCols(ch: *const store.Chunk, out: *ChunkCols) void {
        var lz: i32 = 0;
        while (lz < store.chunk_size) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < store.chunk_size) : (lx += 1) {
                const idx: usize = @intCast(lx * store.chunk_size + lz);
                const h: u16 = ch.heightAt(lx, lz);
                out.surface[idx] = if (h > 255) 255 else @intCast(h);
            }
        }
    }

    /// Feet Y a body coming from `from_y` would occupy on this column's surface,
    /// or null when the snapshot cannot answer.
    ///
    /// Sound because `heights` is the topmost non-air block: nothing above it is
    /// solid, so `surface + 1` always has headroom and no higher cell can be
    /// standable. When that candidate is outside the body's step/drop band the
    /// answer would have to come from an interior floor (cave, POI storey), and
    /// only a full column scan finds those, so the probe misses and the caller
    /// falls through to the locked hook. Walls and building interiors therefore
    /// still pay the lock; open terrain, which is the bulk of the search, does
    /// not. Lock-free and allocation-free; safe from parallel AI workers.
    pub fn standable(self: *Snapshot, wx: i32, wz: i32, from_y: i32) ?i32 {
        const t = store.World.worldToChunk(wx, wz);
        const slot = self.find(t.pos.hash()) orelse {
            _ = self.misses.fetchAdd(1, .monotonic);
            return null;
        };
        const idx: usize = @intCast(t.lx * store.chunk_size + t.lz);
        const feet: i32 = @as(i32, self.cols[self.at[slot]].surface[idx]) + 1;
        if (feet > from_y + store.max_step_up or feet < from_y - store.max_drop or
            feet > self.y_dim - store.body_height)
        {
            _ = self.misses.fetchAdd(1, .monotonic);
            return null;
        }
        return feet;
    }
};

const testing = std.testing;

fn tmpWorld(dir: []const u8) !store.World {
    return store.World.init(testing.allocator, dir);
}

test "snapshot answers what the locked standable probe would, for every column" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    var w = try tmpWorld(dir);
    defer w.deinit();

    // Fixture built only through setBlock: poking ch.blocks behind the height
    // invariant is exactly what hid the old tautological probe.
    const base: i32 = store.sea_level;
    try w.setBlockWorld(3, base + 1, 4, store.block_stone); // one-block step up
    try w.setBlockWorld(9, base, 9, store.block_air); // one-block dip
    try w.setBlockWorld(15, base + 3, 0, store.block_stone); // roof over a floor

    var snap: Snapshot = .{};
    const px = [_]f32{4};
    const pz = [_]f32{4};
    const covered = snap.rebuild(&w, &px, &pz);
    try testing.expect(covered >= 1);

    const from_y: i32 = base + 1;
    var lz: i32 = 0;
    while (lz < 16) : (lz += 1) {
        var lx: i32 = 0;
        while (lx < 16) : (lx += 1) {
            const want = try w.standableWorld(lx, lz, from_y);
            // A hit must agree with the locked hook; a miss is always allowed
            // (the caller falls through to it).
            if (snap.standable(lx, lz, from_y)) |got| try testing.expectEqual(want, @as(?i32, got));
        }
    }
    // The roof column is out of the step band, so it must miss rather than
    // claim the roof is walkable.
    try testing.expect(snap.standable(15, 0, from_y) == null);
    try testing.expectEqual(@as(?i32, base + 1), try w.standableWorld(15, 0, from_y));
    // Flat, step-up and dip columns are all answered without the lock.
    try testing.expectEqual(@as(?i32, base + 1), snap.standable(0, 0, from_y));
    try testing.expectEqual(@as(?i32, base + 2), snap.standable(3, 4, from_y));
    try testing.expectEqual(@as(?i32, base), snap.standable(9, 9, from_y));
}

test "snapshot returns null outside the window and counts the miss" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    var w = try tmpWorld(dir);
    defer w.deinit();
    _ = try w.getOrCreate(.{ .x = 0, .z = 0 });

    var snap: Snapshot = .{};
    const px = [_]f32{0};
    const pz = [_]f32{0};
    _ = snap.rebuild(&w, &px, &pz);
    // 100 chunks away: never covered at radius 2.
    try testing.expect(snap.standable(1600, 1600, store.sea_level + 1) == null);
    try testing.expectEqual(@as(u64, 1), snap.misses.load(.monotonic));
}

test "snapshot rebuild is idempotent and player-order independent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    var w = try tmpWorld(dir);
    defer w.deinit();
    _ = try w.getOrCreate(.{ .x = 0, .z = 0 });
    _ = try w.getOrCreate(.{ .x = 6, .z = 0 });

    var a: Snapshot = .{};
    var b: Snapshot = .{};
    const px1 = [_]f32{ 4, 100 };
    const pz1 = [_]f32{ 4, 4 };
    const px2 = [_]f32{ 100, 4 };
    const pz2 = [_]f32{ 4, 4 };
    const na = a.rebuild(&w, &px1, &pz1);
    const nb = b.rebuild(&w, &px2, &pz2);
    try testing.expectEqual(na, nb);
    try testing.expectEqual(@as(usize, 2), na);
    // Same answers for every column of both covered chunks.
    for ([_]i32{ 0, 96 }) |base| {
        var lz: i32 = 0;
        while (lz < 16) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < 16) : (lx += 1) {
                const y = store.sea_level + 1;
                try testing.expectEqual(a.standable(base + lx, lz, y), b.standable(base + lx, lz, y));
            }
        }
    }
    // Rebuilding again over the same set reproduces the same count.
    try testing.expectEqual(na, a.rebuild(&w, &px1, &pz1));
}

test "snapshot table caps at max_chunks and never aliases a rejected key" {
    // Exercised on the table directly: materializing >256 chunks costs 256 KiB
    // each, which is not what this cap is about.
    var snap: Snapshot = .{};
    var i: usize = 0;
    var last_in: u64 = 0;
    while (i < max_chunks) : (i += 1) {
        const key = (store.ChunkPos{ .x = @intCast(i), .z = 7 }).hash();
        try testing.expect(snap.put(key) != null);
        last_in = key;
    }
    try testing.expectEqual(max_chunks, snap.n);
    const overflow = (store.ChunkPos{ .x = 9999, .z = 7 }).hash();
    try testing.expect(snap.put(overflow) == null);
    try testing.expectEqual(max_chunks, snap.n);
    // The rejected key must miss, not resolve to some other chunk's slot.
    try testing.expect(snap.find(overflow) == null);
    try testing.expect(snap.find(last_in) != null);
    // Duplicate insert of a covered key is a no-op (dedupe, not a second slot).
    try testing.expect(snap.put(last_in) == null);
    try testing.expectEqual(max_chunks, snap.n);
    snap.clear();
    try testing.expectEqual(@as(usize, 0), snap.n);
    try testing.expect(snap.find(last_in) == null);
}
