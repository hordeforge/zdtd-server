//! Read-mostly terrain "blocked" snapshot for the A* inner loop.
//!
//! `Game.pathSolidAt` is the pathfinder predicate: one bit per column,
//! `isSolid(lx, heightAt(lx,lz) + 1, lz)`. Today every probe takes the single
//! process-global `Game.terrain_mu` because it calls `World.getOrCreate`, and
//! A* runs on parallel AI workers with up to `path_max_expand * 4` probes per
//! replan. That makes it the hottest lock in the sim.
//!
//! This module rebuilds a 256-bit-per-chunk mask once per tick on the main
//! thread, before the AI phase, and answers probes lock-free. It is
//! behaviour-identical by construction:
//!
//!   * built with `chunks.getPtr`, never `getOrCreate`, so a hit returns the
//!     byte-identical bit the hook would have computed;
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

const mask_bytes: usize = 256 / 8; // one bit per (lx,lz) column

pub const Snapshot = struct {
    keys: [cap]u64 = .{0} ** cap,
    used: [cap]bool = .{false} ** cap,
    blocked: [cap][mask_bytes]u8 = .{.{0} ** mask_bytes} ** cap,
    n: usize = 0,
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

    /// Insert `key` (or find it). Null when the window is full.
    fn put(self: *Snapshot, key: u64) ?usize {
        var i = slotFor(key);
        var probes: usize = 0;
        while (probes < cap) : (probes += 1) {
            if (!self.used[i]) {
                if (self.n >= max_chunks) return null;
                self.used[i] = true;
                self.keys[i] = key;
                self.n += 1;
                return i;
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
        for (px, pz) |x, z| {
            const cx = @divFloor(@as(i32, @intFromFloat(@floor(x))), store.chunk_size);
            const cz = @divFloor(@as(i32, @intFromFloat(@floor(z))), store.chunk_size);
            var dz: i32 = -snap_radius_chunks;
            while (dz <= snap_radius_chunks) : (dz += 1) {
                var dx: i32 = -snap_radius_chunks;
                while (dx <= snap_radius_chunks) : (dx += 1) {
                    const pos: store.ChunkPos = .{ .x = cx + dx, .z = cz + dz };
                    const key = pos.hash();
                    // getPtr only: generating here would change which chunks
                    // exist and when, i.e. change sim outcomes.
                    const ch = w.chunks.getPtr(key) orelse continue;
                    const slot = self.put(key) orelse continue;
                    fillMask(ch, &self.blocked[slot]);
                }
            }
        }
        return self.n;
    }

    fn fillMask(ch: *const store.Chunk, out: *[mask_bytes]u8) void {
        @memset(out, 0);
        var lz: i32 = 0;
        while (lz < store.chunk_size) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < store.chunk_size) : (lx += 1) {
                const h: i32 = ch.heightAt(lx, lz);
                if (!ch.isSolid(lx, h + 1, lz)) continue;
                const idx: usize = @intCast(lx * store.chunk_size + lz);
                out[idx >> 3] |= @as(u8, 1) << @intCast(idx & 7);
            }
        }
    }

    /// Blocked bit for a world column, or null when outside the window.
    /// Lock-free and allocation-free; safe from parallel AI workers.
    pub fn solid(self: *Snapshot, wx: i32, wz: i32) ?bool {
        const t = store.World.worldToChunk(wx, wz);
        const slot = self.find(t.pos.hash()) orelse {
            _ = self.misses.fetchAdd(1, .monotonic);
            return null;
        };
        const idx: usize = @intCast(t.lx * store.chunk_size + t.lz);
        return (self.blocked[slot][idx >> 3] >> @intCast(idx & 7)) & 1 != 0;
    }
};

const testing = std.testing;

fn tmpWorld(dir: []const u8) !store.World {
    return store.World.init(testing.allocator, dir);
}

test "snapshot matches the direct heightAt/isSolid probe for every column" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    var w = try tmpWorld(dir);
    defer w.deinit();

    const ch = try w.getOrCreate(.{ .x = 0, .z = 0 });
    // Write the body cell directly: setBlock would raise `heights` with it, and
    // the mask must have some bits set to be worth comparing.
    const b = ch.blocks orelse return error.NoBlocks;
    for ([_][2]i32{ .{ 3, 4 }, .{ 9, 9 }, .{ 15, 0 } }) |col| {
        const y: i32 = @as(i32, ch.heightAt(col[0], col[1])) + 1;
        b[@intCast(col[0] + col[1] * 16 + y * 256)] = store.block_stone;
    }
    try testing.expect(ch.isSolid(3, @as(i32, ch.heightAt(3, 4)) + 1, 4));

    var snap: Snapshot = .{};
    const px = [_]f32{4};
    const pz = [_]f32{4};
    const covered = snap.rebuild(&w, &px, &pz);
    try testing.expect(covered >= 1);

    var lz: i32 = 0;
    while (lz < 16) : (lz += 1) {
        var lx: i32 = 0;
        while (lx < 16) : (lx += 1) {
            const c2 = w.chunks.getPtr((store.ChunkPos{ .x = 0, .z = 0 }).hash()).?;
            const want = c2.isSolid(lx, @as(i32, c2.heightAt(lx, lz)) + 1, lz);
            const got = snap.solid(lx, lz) orelse return error.UnexpectedMiss;
            try testing.expectEqual(want, got);
        }
    }
    try testing.expectEqual(@as(u64, 0), snap.misses.load(.monotonic));
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
    try testing.expect(snap.solid(1600, 1600) == null);
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
                try testing.expectEqual(a.solid(base + lx, lz), b.solid(base + lx, lz));
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
