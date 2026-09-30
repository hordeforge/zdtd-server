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
const io_fs = @import("../util/io_fs.zig");

/// Cells with a collector TE. Stock caps chunk TEs per chunk; a flat array
/// keyed by cell is enough for a dedi's placed blocks.
pub const max_collectors: usize = 256;

/// `BlockCollector` output arrays in stock are `outputGridInitialHeight` rows
/// tall; the shipped dew collector has one output slot and the apiary/coop add
/// a couple more.
pub const max_output_slots: usize = 6;

/// Fuel slots (`fuelGridHeight` rows).
pub const max_fuel_slots: usize = 4;

/// Catalyst slots (`catalystGridHeight` rows).
pub const max_catalyst_slots: usize = 4;

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
    /// `fuelSlotsInternal`: what a fuel-costed output burns.
    fuel: [max_fuel_slots]Slot = @splat(.{}),
    /// `catalystSlotsInternal`: the conversion catalysts.
    catalyst: [max_catalyst_slots]Slot = @splat(.{}),
    /// `outOfFuel` map flag (stock's `isDisabled` leg).
    out_of_fuel: bool = false,
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

    /// Persisted record: pos, block, the conversion budget, the draw state and
    /// the output slots. Fixed size so a truncated tail is a clean reject.
    // pos (12) + block (4) + fill_started (1) + fill_left (4) + last_world (8)
    // + rng (4) + the output slots and the fuel slots (8 each).
    const persisted_record_size: usize = 12 + 4 + 1 + 4 + 8 + 4 + max_output_slots * 8 + max_fuel_slots * 8 + max_catalyst_slots * 8;

    pub fn count(self: *const Store) usize {
        var n: usize = 0;
        for (self.used) |u| {
            if (u) n += 1;
        }
        return n;
    }

/// Persist all live collectors to {dir}/collectors.zcl (ZCL1). Records sorted by
/// pos so the bytes do not depend on slot assignment order. Best-effort like the
/// other saves; a missing file is a fresh world on load.
pub fn save(self: *const Store, dir: []const u8, allocator: std.mem.Allocator) !void {
    var path: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/collectors.zcl", .{dir});
    const buf = try allocator.alloc(u8, 4 + 2 + max_collectors * persisted_record_size);
    defer allocator.free(buf);
    @memcpy(buf[0..4], "ZCL1");
    var o: usize = 6;

    var idxs: [max_collectors]u16 = undefined;
    var n_idx: usize = 0;
    for (self.used, 0..) |u, i| {
        if (!u) continue;
        idxs[n_idx] = @intCast(i);
        n_idx += 1;
    }
    std.mem.sort(u16, idxs[0..n_idx], self, struct {
        fn less(store: *const Store, a: u16, b: u16) bool {
            const ca = store.items[a];
            const cb = store.items[b];
            if (ca.x != cb.x) return ca.x < cb.x;
            if (ca.y != cb.y) return ca.y < cb.y;
            return ca.z < cb.z;
        }
    }.less);

    var n_records: u16 = 0;
    for (idxs[0..n_idx]) |ii| {
        const c = &self.items[ii];
        if (o + persisted_record_size > buf.len) break;
        std.mem.writeInt(i32, buf[o..][0..4], c.x, .little);
        std.mem.writeInt(i32, buf[o + 4 ..][0..4], c.y, .little);
        std.mem.writeInt(i32, buf[o + 8 ..][0..4], c.z, .little);
        std.mem.writeInt(u32, buf[o + 12 ..][0..4], c.block_id, .little);
        buf[o + 16] = @intFromBool(c.fill_started);
        std.mem.writeInt(u32, buf[o + 17 ..][0..4], @bitCast(c.fill_left), .little);
        std.mem.writeInt(u64, buf[o + 21 ..][0..8], c.last_world, .little);
        std.mem.writeInt(u32, buf[o + 29 ..][0..4], c.rng, .little);
        o += 33;
        for (c.items) |sl| {
            std.mem.writeInt(i32, buf[o..][0..4], sl.type_id, .little);
            std.mem.writeInt(u16, buf[o + 4 ..][0..2], sl.count, .little);
            std.mem.writeInt(u16, buf[o + 6 ..][0..2], sl.quality, .little);
            o += 8;
        }
        for (c.fuel) |sl| {
            std.mem.writeInt(i32, buf[o..][0..4], sl.type_id, .little);
            std.mem.writeInt(u16, buf[o + 4 ..][0..2], sl.count, .little);
            std.mem.writeInt(u16, buf[o + 6 ..][0..2], sl.quality, .little);
            o += 8;
        }
        for (c.catalyst) |sl| {
            std.mem.writeInt(i32, buf[o..][0..4], sl.type_id, .little);
            std.mem.writeInt(u16, buf[o + 4 ..][0..2], sl.count, .little);
            std.mem.writeInt(u16, buf[o + 6 ..][0..2], sl.quality, .little);
            o += 8;
        }
        n_records += 1;
    }
    std.mem.writeInt(u16, buf[4..6], n_records, .little);
    try io_fs.writeFile(p, buf[0..o]);
}

/// Decode a ZCL1 buffer. A bad magic, a short header or a record that runs past
/// the buffer is rejected whole.
pub fn loadFromSlice(self: *Store, buf: []const u8) !void {
    if (buf.len < 6 or !std.mem.eql(u8, buf[0..4], "ZCL1")) return error.ReadFailed;
    const n_records = std.mem.readInt(u16, buf[4..6], .little);
    var o: usize = 6;
    var i: usize = 0;
    while (i < n_records) : (i += 1) {
        if (o + persisted_record_size > buf.len) return error.ReadFailed;
        const x = std.mem.readInt(i32, buf[o..][0..4], .little);
        const y = std.mem.readInt(i32, buf[o + 4 ..][0..4], .little);
        const z = std.mem.readInt(i32, buf[o + 8 ..][0..4], .little);
        const block_id: u16 = @intCast(std.mem.readInt(u32, buf[o + 12 ..][0..4], .little));
        const c = self.getOrCreate(x, y, z, block_id) orelse return error.ReadFailed;
        c.fill_started = buf[o + 16] != 0;
        c.fill_left = @bitCast(std.mem.readInt(u32, buf[o + 17 ..][0..4], .little));
        c.last_world = std.mem.readInt(u64, buf[o + 21 ..][0..8], .little);
        const rng = std.mem.readInt(u32, buf[o + 29 ..][0..4], .little);
        c.rng = if (rng == 0) 1 else rng;
        o += 33;
        for (&c.items) |*sl| {
            sl.type_id = std.mem.readInt(i32, buf[o..][0..4], .little);
            sl.count = std.mem.readInt(u16, buf[o + 4 ..][0..2], .little);
            sl.quality = std.mem.readInt(u16, buf[o + 6 ..][0..2], .little);
            o += 8;
        }
        for (&c.fuel) |*sl| {
            sl.type_id = std.mem.readInt(i32, buf[o..][0..4], .little);
            sl.count = std.mem.readInt(u16, buf[o + 4 ..][0..2], .little);
            sl.quality = std.mem.readInt(u16, buf[o + 6 ..][0..2], .little);
            o += 8;
        }
        for (&c.catalyst) |*sl| {
            sl.type_id = std.mem.readInt(i32, buf[o..][0..4], .little);
            sl.count = std.mem.readInt(u16, buf[o + 4 ..][0..2], .little);
            sl.quality = std.mem.readInt(u16, buf[o + 6 ..][0..2], .little);
            o += 8;
        }
    }
}

/// Load {dir}/collectors.zcl. A missing file is a fresh world.
pub fn load(self: *Store, dir: []const u8, allocator: std.mem.Allocator) !void {
    var path: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/collectors.zcl", .{dir});
    const buf = io_fs.readFileAll(allocator, p) catch |e| switch (e) {
        error.FileNotFound => return error.OpenFailed,
        else => return e,
    };
    defer allocator.free(buf);
    try self.loadFromSlice(buf);
}
};

test "ZCL1 round-trips a collector and rejects a bad magic" {
    var a: Store = .{};
    const c = a.getOrCreate(5, 70, 9, 1733).?;
    c.items[0] = .{ .type_id = 900, .count = 3, .quality = 2 };
    c.fill_started = true;
    c.fill_left = 12.5;
    c.last_world = 987654;
    const buf = try std.testing.allocator.alloc(u8, 4 + 2 + max_collectors * Store.persisted_record_size);
    defer std.testing.allocator.free(buf);
    var w: usize = 0;
    @memcpy(buf[0..4], "ZCL1");
    w = 6;
    std.mem.writeInt(i32, buf[w..][0..4], 5, .little);
    std.mem.writeInt(i32, buf[w + 4 ..][0..4], 70, .little);
    std.mem.writeInt(i32, buf[w + 8 ..][0..4], 9, .little);
    std.mem.writeInt(u32, buf[w + 12 ..][0..4], 1733, .little);
    buf[w + 16] = 1;
    std.mem.writeInt(u32, buf[w + 17 ..][0..4], @bitCast(@as(f32, 12.5)), .little);
    std.mem.writeInt(u64, buf[w + 21 ..][0..8], 987654, .little);
    std.mem.writeInt(u32, buf[w + 29 ..][0..4], 7, .little);
    w += 33;
    std.mem.writeInt(i32, buf[w..][0..4], 900, .little);
    std.mem.writeInt(u16, buf[w + 4 ..][0..2], 3, .little);
    std.mem.writeInt(u16, buf[w + 6 ..][0..2], 2, .little);
    w += 8;
    // Remaining output slots plus the fuel slots.
    const empty_slots = (max_output_slots - 1) + max_fuel_slots + max_catalyst_slots;
    @memset(buf[w .. w + empty_slots * 8], 0);
    w += empty_slots * 8;
    std.mem.writeInt(u16, buf[4..6], 1, .little);

    var b: Store = .{};
    try b.loadFromSlice(buf[0..w]);
    const rb = b.get(5, 70, 9).?;
    try std.testing.expectEqual(@as(u16, 1733), rb.block_id);
    try std.testing.expectEqual(@as(i32, 900), rb.items[0].type_id);
    try std.testing.expectEqual(@as(u16, 3), rb.items[0].count);
    try std.testing.expect(rb.fill_started);
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), rb.fill_left, 0.001);
    try std.testing.expectEqual(@as(u64, 987654), rb.last_world);

    var bad = buf[0..w];
    bad[0] = 'X';
    try std.testing.expectError(error.ReadFailed, b.loadFromSlice(bad));
    try std.testing.expectError(error.ReadFailed, b.loadFromSlice(buf[0 .. w - 1]));
}

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
