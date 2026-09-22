//! AI steering math: yaw wrap + SeekYaw speed law.
//!
//! Split out of ecs/ai_tasks.zig (same code, moved verbatim).

const std = @import("std");

pub fn wrap360(deg: f32) f32 {
    const r = @mod(deg, 360.0);
    return if (r < 0) r + 360.0 else r;
}

/// Entity::SeekYaw (asm.il:399475) speed law, applied per tick instead of via
/// stock's yawSeekAngle/yawSeekTimeMax slew: normalize both angles, wrap the
/// delta into [-180,180], and slow quadratically inside `slow_at` with a
/// 20 deg/s floor. Returns the new yaw in [0,360).
pub fn seekYawStep(cur_deg: f32, target_deg: f32, max_turn_deg: f32, slow_at_deg: f32, min_speed_deg: f32, dt: f32) f32 {
    const cur = wrap360(cur_deg);
    const tgt = wrap360(target_deg);
    var delta = tgt - cur;
    if (delta < -180.0) delta += 360.0;
    if (delta > 180.0) delta -= 360.0;
    const mag = @abs(delta);
    if (mag == 0) return tgt;
    var speed = max_turn_deg;
    if (mag < slow_at_deg and slow_at_deg > 0) {
        const f = mag / slow_at_deg;
        speed = @max(max_turn_deg * f * f, min_speed_deg);
    }
    const step = @min(speed * dt, mag);
    return wrap360(cur + std.math.sign(delta) * step);
}
