//! Horizontal movement envelope: max speed over server dt, clamp to last good.
//! No heap; pure math for PosAndRot / RelPosAndRot C2S.

const std = @import("std");

/// Soft cap: sprint (~6 m/s) + vehicle-on-foot margin. Excess is clamped.
pub const max_horizontal_speed_mps: f32 = 20.0;
/// Floor dt so a double-packet same tick does not divide by zero.
pub const min_dt_s: f32 = 1.0 / 40.0;
/// Cap dt after long stall so one packet cannot jump the whole map.
pub const max_dt_s: f32 = 1.0;

pub fn clampDtSeconds(dt_s: f32) f32 {
    if (!(dt_s > 0) or !std.math.isFinite(dt_s)) return min_dt_s;
    return @min(max_dt_s, @max(min_dt_s, dt_s));
}

pub fn horizontalDistance(dx: f32, dz: f32) f32 {
    return @sqrt(dx * dx + dz * dz);
}

pub fn horizontalSpeedMps(dx: f32, dz: f32, dt_s: f32) f32 {
    const dt = clampDtSeconds(dt_s);
    return horizontalDistance(dx, dz) / dt;
}

/// Clamp (new_x, new_z) toward last good so horizontal travel ≤ max_speed * dt.
/// Y is unchanged by the caller. Returns clamped xz and whether a clamp ran.
pub fn clampHorizontal(
    last_x: f32,
    last_z: f32,
    new_x: f32,
    new_z: f32,
    dt_s: f32,
    max_speed_mps: f32,
) struct { x: f32, z: f32, clamped: bool } {
    const dt = clampDtSeconds(dt_s);
    const max_dist = max_speed_mps * dt;
    const dx = new_x - last_x;
    const dz = new_z - last_z;
    const dist = horizontalDistance(dx, dz);
    if (!std.math.isFinite(dist) or !std.math.isFinite(max_dist) or !(max_dist > 0)) {
        return .{ .x = last_x, .z = last_z, .clamped = true };
    }
    if (!(dist > max_dist)) {
        return .{ .x = new_x, .z = new_z, .clamped = false };
    }
    const s = max_dist / dist;
    return .{
        .x = last_x + dx * s,
        .z = last_z + dz * s,
        .clamped = true,
    };
}

/// dt from server tick delta (20 TPS). Zero/underflow → min_dt.
pub fn dtFromTicks(prev_tick: u64, now_tick: u64, tick_s: f32) f32 {
    if (now_tick <= prev_tick) return min_dt_s;
    const d: f32 = @floatFromInt(now_tick - prev_tick);
    return clampDtSeconds(d * tick_s);
}

test "clampHorizontal accepts within budget" {
    const r = clampHorizontal(0, 0, 5, 0, 1.0, max_horizontal_speed_mps);
    try std.testing.expect(!r.clamped);
    try std.testing.expectEqual(@as(f32, 5), r.x);
    try std.testing.expectEqual(@as(f32, 0), r.z);
}

test "clampHorizontal clamps over soft max" {
    // 100 m in 1 s at 20 m/s cap → 20 m along +x
    const r = clampHorizontal(0, 0, 100, 0, 1.0, max_horizontal_speed_mps);
    try std.testing.expect(r.clamped);
    try std.testing.expect(@abs(r.x - max_horizontal_speed_mps) < 0.01);
    try std.testing.expectEqual(@as(f32, 0), r.z);
}

test "clampHorizontal diagonal" {
    const r = clampHorizontal(0, 0, 100, 100, 1.0, 10.0);
    try std.testing.expect(r.clamped);
    const dist = horizontalDistance(r.x, r.z);
    try std.testing.expect(@abs(dist - 10.0) < 0.02);
}

test "clampHorizontal rejects non-finite input and invalid limits" {
    const inf = std.math.inf(f32);
    const nan = std.math.nan(f32);

    for ([_]struct { x: f32, z: f32, speed: f32 }{
        .{ .x = inf, .z = 0, .speed = max_horizontal_speed_mps },
        .{ .x = nan, .z = 0, .speed = max_horizontal_speed_mps },
        .{ .x = 10, .z = 0, .speed = inf },
        .{ .x = 10, .z = 0, .speed = nan },
        .{ .x = 10, .z = 0, .speed = 0 },
    }) |input| {
        const r = clampHorizontal(3, 4, input.x, input.z, 1.0, input.speed);
        try std.testing.expect(r.clamped);
        try std.testing.expectEqual(@as(f32, 3), r.x);
        try std.testing.expectEqual(@as(f32, 4), r.z);
    }
}

test "dtFromTicks" {
    const tick_s: f32 = 1.0 / 20.0;
    try std.testing.expect(@abs(dtFromTicks(0, 20, tick_s) - 1.0) < 0.001);
    try std.testing.expectEqual(min_dt_s, dtFromTicks(5, 5, tick_s));
    try std.testing.expectEqual(min_dt_s, dtFromTicks(10, 5, tick_s)); // reverse/zero span
    try std.testing.expectEqual(max_dt_s, dtFromTicks(0, 10_000, tick_s));
}

test "horizontalSpeedMps" {
    const s = horizontalSpeedMps(20, 0, 1.0);
    try std.testing.expect(@abs(s - 20.0) < 0.01);
    // Non-positive / non-finite dt floors to min_dt_s (no div-by-zero, no inf).
    const s_zero = horizontalSpeedMps(1, 0, 0);
    try std.testing.expect(@abs(s_zero - (1.0 / min_dt_s)) < 0.01);
    const s_neg = horizontalSpeedMps(1, 0, -1);
    try std.testing.expect(@abs(s_neg - (1.0 / min_dt_s)) < 0.01);
    try std.testing.expect(std.math.isFinite(horizontalSpeedMps(1, 0, std.math.nan(f32))));
}
