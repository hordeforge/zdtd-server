//! Collector tile-entity state: the `TileEntityCollector` producer family
//! (dew collector, apiary, chicken coop; `BlockCollector` in blocks.xml).
//!
//! Stock keeps this in a chunk-owned `TileEntityCollector` with four item
//! arrays (items/fuel/catalyst/mod slots), per-output-type conversion budgets
//! and fill data. This is the laid-out half zdtd owns: the output slots and the
//! world-time conversion budget, keyed by cell. Non-goals: the four-array wire
//! body (the TE stream), fuel/catalyst conversion counts and the audio
//! broadcasts, which are recorded residuals.
const std = @import("std");

/// Cells with a collector TE. Stock caps chunk TEs per chunk; a flat array
/// keyed by cell is enough for a dedi's placed blocks.
pub const max_collectors: usize = 256;

/// `BlockCollector` output arrays in stock are `outputGridInitialHeight` rows
/// tall; the shipped dew collector has one output slot and the apiary/coop add
/// a couple more.
pub const max_output_slots: usize = 6;

pub const Slot = struct {
    type_id: i32 = 0,
    count: u16 = 0,
    quality: u16 = 0,
};

pub const Collector = struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    block_id: u16 = 0,
    /// `itemsInternal`: the output slots.
    items: [max_output_slots]Slot = @splat(.{}),
    /// World-time stamp of the last production pass (`lastWorldTimes`).
    last_world: u64 = 0,
    /// World-time units left in the current conversion (`fillTimeLeft`). The
    /// first fill draws its time (`HandleUpdate` creates the `FillData` with
    /// `RandomRange(MinConvertTime, MaxConvertTime)`), so a fresh collector
    /// waits one fill before its first item.
    fill_left: f32 = 0,
    fill_started: bool = false,
    /// Deterministic draw state for `RandomRange(MinConvertTime,
    /// MaxConvertTime)` (rule 22: seeded from the cell, not the clock).
    rng: u32 = 1,
    /// Set when the produced state changed and the owners still need it.
    dirty: bool = false,

    pub fn isFull(self: *const Collector) bool {
        for (&self.items) |*s| {
            if (s.type_id == 0 or s.count == 0) return false;
        }
        return true;
    }

    /// First free output slot, or null when full.
    pub fn firstFree(self: *Collector) ?*Slot {
        for (&self.items) |*s| {
            if (s.type_id == 0 or s.count == 0) return s;
        }
        return null;
    }

    /// `FillData` draw: a uniform value in [min, max] in world-time units.
    pub fn drawFillTime(self: *Collector, min: i32, max: i32) f32 {
        const lo: u32 = @intCast(@max(min, 0));
        const hi: u32 = @intCast(@max(max, min));
        if (hi == 0) return 0;
        // xorshift32 (same generator family as the loot/AI draws).
        var x = self.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.rng = x;
        const span = hi - lo + 1;
        return @floatFromInt(lo + x % span);
    }
};

pub const Store = struct {
    items: [max_collectors]Collector = undefined,
    used: [max_collectors]bool = .{false} ** max_collectors,

    pub fn get(self: *Store, x: i32, y: i32, z: i32) ?*Collector {
        for (self.items[0..], self.used[0..]) |*c, u| {
            if (u and c.x == x and c.y == y and c.z == z) return c;
        }
        return null;
    }

    pub fn getOrCreate(self: *Store, x: i32, y: i32, z: i32, block_id: u16) ?*Collector {
        if (self.get(x, y, z)) |c| {
            c.block_id = block_id;
            return c;
        }
        for (self.items[0..], self.used[0..]) |*c, *u| {
            if (!u.*) {
                u.* = true;
                // Seed from the cell so a restart reproduces the same fill draws
                // (rule 22); the xorshift state must be non-zero.
                var h: u32 = @bitCast(x *% 73856093 ^ y *% 19349663 ^ z *% 83492791);
                h ^= @as(u32, block_id) *% 2654435761;
                c.* = .{ .x = x, .y = y, .z = z, .block_id = block_id, .rng = if (h == 0) 1 else h };
                return c;
            }
        }
        return null;
    }

    pub fn removeAt(self: *Store, x: i32, y: i32, z: i32) bool {
        for (self.items[0..], self.used[0..]) |*c, *u| {
            if (u.* and c.x == x and c.y == y and c.z == z) {
                u.* = false;
                c.* = .{};
                return true;
            }
        }
        return false;
    }

    pub fn count(self: *const Store) usize {
        var n: usize = 0;
        for (self.used) |u| {
            if (u) n += 1;
        }
        return n;
    }
};

test "collector store keys by cell and seeds its draw state" {
    var s: Store = .{};
    const c = s.getOrCreate(10, 70, 10, 1733).?;
    try std.testing.expect(c.rng != 0);
    c.last_world = 500;
    try std.testing.expectEqual(@as(usize, 1), s.count());
    try std.testing.expect(s.get(10, 70, 10) != null);
    // Draws stay inside [min, max] and deterministic for the same cell.
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        const v = c.drawFillTime(10, 20);
        try std.testing.expect(v >= 10 and v <= 20);
    }
    const again = s.getOrCreate(10, 70, 10, 1733).?;
    try std.testing.expectEqual(@as(u64, 500), again.last_world);
    try std.testing.expect(s.removeAt(10, 70, 10));
    try std.testing.expectEqual(@as(usize, 0), s.count());
}
