//! Spatial interest: grid cells → nearby players for replication.
//! M11: dirty gating helpers for serialize-once fan-out (encode once, memcpy per peer).
//! Decision: docs/adr/0008-serialize-once-interest.md.

const std = @import("std");
const Dirty = @import("components.zig").Dirty;

pub const cell_size: f32 = 32.0;

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

/// Bit set of observers, one bit per client slot (bit k = client k).
pub fn ObserverMask(comptime lanes: comptime_int) type {
    return std.meta.Int(.unsigned, lanes);
}

/// Which of `lanes` observers have entity cell (ecx,ecz) in interest range,
/// as one word. This is stock's per-entity `trackedPlayers` set computed on
/// the fly (NetEntityDistributionEntry::SendToPlayers, asm.il:800867): the
/// caller then walks set bits instead of re-testing every client slot for
/// spawn-on-approach, observer presence and fan-out.
///
/// `active` masks off slots with no joined peer; their cell/radius entries are
/// ignored, so callers need not keep them meaningful. Per-lane semantics are
/// exactly `cellsInRange`, including a negative radius never matching.
pub fn observerMask(
    comptime lanes: comptime_int,
    cx: *const [lanes]i32,
    cz: *const [lanes]i32,
    radius: *const [lanes]i32,
    active: ObserverMask(lanes),
    ecx: i32,
    ecz: i32,
) ObserverMask(lanes) {
    if (active == 0) return 0;
    const V = @Vector(lanes, i32);
    const U = @Vector(lanes, u32);
    const zero: V = @splat(0);
    const r: V = radius.*;
    // @abs of the signed delta, compared unsigned: mirrors cellsInRange, and a
    // negative radius has no unsigned counterpart so it is rejected outright.
    const ru: U = @intCast(@max(r, zero));
    const dx: U = @abs(@as(V, cx.*) - @as(V, @splat(ecx)));
    const dz: U = @abs(@as(V, cz.*) - @as(V, @splat(ecz)));
    const hit = (dx <= ru) & (dz <= ru) & (r >= zero);
    const bits: ObserverMask(lanes) = @bitCast(hit);
    return bits & active;
}

/// Scalar reference for `observerMask`. Tests only: the vector form is the one
/// on the tick path, and this exists to prove they agree.
pub fn observerMaskRef(
    comptime lanes: comptime_int,
    cx: *const [lanes]i32,
    cz: *const [lanes]i32,
    radius: *const [lanes]i32,
    active: ObserverMask(lanes),
    ecx: i32,
    ecz: i32,
) ObserverMask(lanes) {
    var out: ObserverMask(lanes) = 0;
    for (0..lanes) |k| {
        const bit = @as(ObserverMask(lanes), 1) << @intCast(k);
        if (active & bit == 0) continue;
        if (cellsInRange(cx[k], cz[k], ecx, ecz, radius[k])) out |= bit;
    }
    return out;
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

test "observerMask matches the scalar reference over random observers" {
    const lanes = 64;
    var cx: [lanes]i32 = undefined;
    var cz: [lanes]i32 = undefined;
    var rad: [lanes]i32 = undefined;
    var prng = std.Random.DefaultPrng.init(0x11ce_5e11);
    const rnd = prng.random();
    var round: usize = 0;
    while (round < 512) : (round += 1) {
        for (0..lanes) |k| {
            cx[k] = rnd.intRangeAtMost(i32, -40, 40);
            cz[k] = rnd.intRangeAtMost(i32, -40, 40);
            // Include negative radii: an unconfigured client must never match.
            rad[k] = rnd.intRangeAtMost(i32, -2, 9);
        }
        const active = rnd.int(u64);
        const ecx = rnd.intRangeAtMost(i32, -40, 40);
        const ecz = rnd.intRangeAtMost(i32, -40, 40);
        try std.testing.expectEqual(
            observerMaskRef(lanes, &cx, &cz, &rad, active, ecx, ecz),
            observerMask(lanes, &cx, &cz, &rad, active, ecx, ecz),
        );
    }
}

test "observerMask edges: empty active, radius zero, cross-origin, last lane" {
    const lanes = 64;
    var cx: [lanes]i32 = .{7} ** lanes;
    var cz: [lanes]i32 = .{7} ** lanes;
    var rad: [lanes]i32 = .{3} ** lanes;
    // No joined peers: no observer regardless of geometry.
    try std.testing.expectEqual(@as(u64, 0), observerMask(lanes, &cx, &cz, &rad, 0, 7, 7));
    // Radius 0 is same-cell only.
    rad[0] = 0;
    cx[0] = 0;
    cz[0] = 0;
    try std.testing.expectEqual(@as(u64, 1), observerMask(lanes, &cx, &cz, &rad, 1, 0, 0));
    try std.testing.expectEqual(@as(u64, 0), observerMask(lanes, &cx, &cz, &rad, 1, 1, 0));
    // Negative cells are adjacent across the origin, not folded onto it.
    rad[1] = 1;
    cx[1] = -1;
    cz[1] = 0;
    try std.testing.expectEqual(@as(u64, 2), observerMask(lanes, &cx, &cz, &rad, 2, 0, 0));
    try std.testing.expectEqual(@as(u64, 0), observerMask(lanes, &cx, &cz, &rad, 2, 2, 0));
    // Lane 63 must land in the top bit, not fall off the word.
    cx[63] = 100;
    cz[63] = 100;
    rad[63] = 1;
    const top = @as(u64, 1) << 63;
    try std.testing.expectEqual(top, observerMask(lanes, &cx, &cz, &rad, top, 100, 101));
    try std.testing.expectEqual(@as(u64, 0), observerMask(lanes, &cx, &cz, &rad, top, 100, 103));
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
