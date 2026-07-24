//! Spatial interest: grid cells → nearby players for replication.

const std = @import("std");
const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const max_entities = @import("world.zig").max_entities;

pub const cell_size: f32 = 32.0;
pub const default_radius_cells: i32 = 3;

fn cellOf(x: f32, z: f32) struct { cx: i32, cz: i32 } {
    return .{
        .cx = @divFloor(@as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(cell_size))),
        .cz = @divFloor(@as(i32, @intFromFloat(z)), @as(i32, @intFromFloat(cell_size))),
    };
}

/// Returns true if entity slot `e` is in interest range of player at (px,pz).
pub fn inRange(px: f32, pz: f32, ex: f32, ez: f32, radius_cells: i32) bool {
    const a = cellOf(px, pz);
    const b = cellOf(ex, ez);
    const dx = a.cx - b.cx;
    const dz = a.cz - b.cz;
    return @abs(dx) <= radius_cells and @abs(dz) <= radius_cells;
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
}
