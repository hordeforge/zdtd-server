//! Spatial interest: grid cells → nearby players for replication.
//! M11: dirty gating helpers for serialize-once fan-out (encode once, memcpy per peer).
//! Decision: docs/adr/0008-serialize-once-interest.md.

const std = @import("std");
const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const max_entities = @import("world.zig").max_entities;
const Dirty = @import("components.zig").Dirty;

pub const cell_size: f32 = 32.0;
pub const default_radius_cells: i32 = 3;

/// Main-tick period for PosAndRot heartbeat when no dirty bits (paired with
/// motion_replicate_period in game.zig; effective interval is LCM).
pub const pos_heartbeat_period_ticks: u64 = 5;

pub fn cellOf(x: f32, z: f32) struct { cx: i32, cz: i32 } {
    // Floor the division, not the coordinate: truncating first puts every
    // position in (-cell_size, 0) into cell 0 and skews range around the origin.
    return .{
        .cx = @intFromFloat(@floor(x / cell_size)),
        .cz = @intFromFloat(@floor(z / cell_size)),
    };
}

/// Range test on precomputed cells: hot entity × client loops resolve each
/// side's cell once per pass instead of redoing the float math per pair.
pub fn cellsInRange(acx: i32, acz: i32, bcx: i32, bcz: i32, radius_cells: i32) bool {
    return @abs(acx - bcx) <= radius_cells and @abs(acz - bcz) <= radius_cells;
}

/// Returns true if entity slot `e` is in interest range of player at (px,pz).
pub fn inRange(px: f32, pz: f32, ex: f32, ez: f32, radius_cells: i32) bool {
    const a = cellOf(px, pz);
    const b = cellOf(ex, ez);
    return cellsInRange(a.cx, a.cz, b.cx, b.cz, radius_cells);
}

/// Whether this entity should emit PosAndRot this motion pass.
/// Dirty pos/rot always; otherwise heartbeat every `pos_heartbeat_period_ticks`.
pub fn needsPosSend(d: Dirty, tick_n: u64) bool {
    if (d.pos or d.rot) return true;
    return tick_n % pos_heartbeat_period_ticks == 0;
}

/// Clear bits that serialize-once interest has fanned out this pass.
pub fn clearAfterReplicate(d: *Dirty) void {
    d.pos = false;
    d.rot = false;
    d.spawn = false;
    d.flags = false;
}

/// For each alive entity, set dirty.pos when far from last_sent (caller tracks).
pub fn markNearbyDirty(w: *World, px: f32, pz: f32, radius_cells: i32) void {
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        if (!w.alive[i] or !w.mask[i].transform) continue;
        if (!inRange(px, pz, w.transform[i].x, w.transform[i].z, radius_cells)) continue;
        if (w.mask[i].dirty) {
            w.dirty[i].pos = true;
        }
    }
}

test "interest cell range" {
    try std.testing.expect(inRange(0, 0, 10, 10, 1));
    try std.testing.expect(!inRange(0, 0, 200, 0, 1));
    // Floor division (not trunc-to-zero): positions in (-cell_size, 0) must not
    // collapse into cell 0 with positive-side neighbors.
    const neg = cellOf(-1, -1);
    try std.testing.expectEqual(@as(i32, -1), neg.cx);
    try std.testing.expectEqual(@as(i32, -1), neg.cz);
    const pos = cellOf(0, 0);
    try std.testing.expectEqual(@as(i32, 0), pos.cx);
    try std.testing.expectEqual(@as(i32, 0), pos.cz);
    // Exact cell boundary: cell_size maps to next cell.
    const edge = cellOf(cell_size, cell_size);
    try std.testing.expectEqual(@as(i32, 1), edge.cx);
    try std.testing.expectEqual(@as(i32, 1), edge.cz);
    // Radius 0: same cell only.
    try std.testing.expect(cellsInRange(0, 0, 0, 0, 0));
    try std.testing.expect(!cellsInRange(0, 0, 1, 0, 0));
    // Cross-origin interest: cell -1 and 0 are adjacent (radius 1).
    try std.testing.expect(inRange(-1, 0, 1, 0, 1));
    try std.testing.expect(!inRange(-1, 0, cell_size + 1, 0, 1));
}

test "needsPosSend dirty and heartbeat" {
    const clean: Dirty = .{};
    try std.testing.expect(needsPosSend(clean, 0));
    try std.testing.expect(!needsPosSend(clean, 1));
    try std.testing.expect(needsPosSend(clean, 5));
    const moved: Dirty = .{ .pos = true };
    try std.testing.expect(needsPosSend(moved, 1));
    try std.testing.expect(needsPosSend(moved, 3));
}

test "clearAfterReplicate keeps hp inv remove" {
    var d: Dirty = .{ .pos = true, .rot = true, .spawn = true, .flags = true, .hp = true, .inv = true, .remove = true };
    clearAfterReplicate(&d);
    try std.testing.expect(!d.pos);
    try std.testing.expect(!d.rot);
    try std.testing.expect(!d.spawn);
    try std.testing.expect(!d.flags);
    try std.testing.expect(d.hp);
    try std.testing.expect(d.inv);
    try std.testing.expect(d.remove);
}
