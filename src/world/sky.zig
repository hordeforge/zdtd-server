//! Stock sky day/night model (RE entity-ai.md SkyManager): pure world-time →
//! daylight-curve functions for the clone-side world-light model.
//!
//! Slice 1 of the light model: the day/night ambient leg only, feeding the
//! stealth-meter light byte (PlayerStealth.TickServer S2C). Everything
//! position-dependent in `LightManager.GetLightLevel` (chunk block light
//! `BlockLight`, moving light entities `GetLightLevelFromMovingLights`, shade
//! `CalcShadeLight` and the moon term `GetMoonBrightness`) is 0 and recorded
//! as later slices; the ambient total collapses to the day curve (the real
//! `AmbientTotal` folds sky-color luma × sky scale × day/night brightness ×
//! moon scale, `WorldEnvironment.AmbientSpectrumFrameUpdate`).

const std = @import("std");

/// Stock world-time day length (24000 ticks) and hour (1000 ticks): the fixed
/// mapping behind SkyManager.TimeOfDay.
pub const day_ticks: u64 = 24000;
pub const ticks_per_hour: u64 = 1000;

/// Stock SkyManager.TimeOfDay: `(timeOfDay % 24000) / 1000` → hour 0..24.
pub fn timeOfDay(world_time_bits: u64) f32 {
    return @as(f32, @floatFromInt(world_time_bits % day_ticks)) /
        @as(f32, @floatFromInt(ticks_per_hour));
}

/// Stock SkyManager.UpdateSunMoonAngles (IL=348) target: day hours map
/// `(hour - dawn) / (dusk - dawn)` into [0, 1); night hours wrap through the
/// `24 - dusk` window into [1, 2); `× 0.5` clamps the target to [0, 1], so
/// worldRotation reaches 0 at dawn, 0.5 at dusk and 1.0 at the next dawn.
/// Stock smooths worldRotation toward the target with `Lerp(0.05)`/frame;
/// slice 1 uses the target directly (no per-tick state), which only shifts
/// the curve by the ~2 min of smoothing lag, and the discontinuity at dawn
/// (1 → 0) is invisible to the day curve (both sides are 0.5).
pub fn sunMoonTarget(hour: f32, dawn: f32, dusk: f32) f32 {
    var target: f32 = undefined;
    if (hour >= dawn and hour < dusk) {
        target = (hour - dawn) / (dusk - dawn);
    } else {
        const v5 = 24.0 - dusk;
        const v6 = v5 + dawn;
        target = if (hour < dawn) (v5 + hour) / v6 else (hour - dusk) / v6;
        target += 1.0;
    }
    return @min(@max(target * 0.5, 0.0), 1.0);
}

/// Stock SkyManager.CalcDayPercent (IL=54) over the direct sun target: 0.5 at
/// dawn and dusk, 1.0 at 13:00, 0.0 at ~1:00 (the night minimum), clamped to
/// [0, 1]. `isAllTimeNight` (client-only setting) returns 1; not modeled.
pub fn dayPercent(world_time_bits: u64, dawn: f32, dusk: f32) f32 {
    const rot = sunMoonTarget(timeOfDay(world_time_bits), dawn, dusk);
    if (rot < 0.5) {
        const a = std.math.pow(f32, 1.0 - @abs(0.25 - rot) * 4.0, 0.6) * 0.68 + 0.5;
        return @min(a, 1.0);
    }
    const b = 0.5 - std.math.pow(f32, 1.0 - @abs(0.75 - rot) * 4.0, 0.6) * 0.68;
    return @max(b, 0.0);
}

/// Slice-1 ambient: the stock `LightManager.GetLightLevel` (IL=117) ambient
/// term `AmbientTotal^0.6 × 0.5` with `AmbientTotal` collapsed to the day
/// curve (no sky-color scaling); block light, shade and moon terms are 0
/// until later slices. Output 0..0.5: 0 at ~1:00, ~0.33 at dawn/dusk, 0.5 at
/// noon.
pub fn ambientLuma(day_pct: f32) f32 {
    return std.math.pow(f32, day_pct, 0.6) * 0.5;
}

test "sky: TimeOfDay maps world time to the stock hour" {
    // GameUtils::DayTimeToWorldTime day 6, 10:30 → 6×24000 + 10500.
    try std.testing.expectEqual(@as(f32, 10.5), timeOfDay(6 * 24000 + 10500));
    // Day wrap: midnight of a new day is hour 0, 23:59:59 is ~24.
    try std.testing.expectEqual(@as(f32, 0.0), timeOfDay(24000));
    try std.testing.expectApproxEqAbs(@as(f32, 23.999), timeOfDay(23999), 0.001);
}

test "sky: sunMoonTarget spans dawn 0 → dusk 0.5 → next dawn 1" {
    // Stock default dawn 4 / dusk 22 (SkyManager cctor IL_002C-0034).
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sunMoonTarget(4, 4, 22), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sunMoonTarget(22, 4, 22), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), sunMoonTarget(13, 4, 22), 0.0001);
    // Night wrap: 23:00 → (23-22)/6 + 1 = 1.1667 → 0.5833; midnight → 0.6667.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5833), sunMoonTarget(23, 4, 22), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6667), sunMoonTarget(0, 4, 22), 0.0001);
    // Custom dawn/dusk shift the window.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sunMoonTarget(20, 6, 20), 0.0001);
}

test "sky: dayPercent curve pins stock daylight shape" {
    const dawn: f32 = 4;
    const dusk: f32 = 22;
    // Noon and 13:00 (rotation 0.25) are full daylight (capped 1.0).
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dayPercent(12 * 1000, dawn, dusk), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dayPercent(13 * 1000, dawn, dusk), 0.0001);
    // Dawn and dusk sit at the 0.5 floor of the day curve.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), dayPercent(4 * 1000, dawn, dusk), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), dayPercent(22 * 1000, dawn, dusk), 0.0001);
    // Symmetric shoulders (8:30 / 17:30): (1 - 0.5)^0.6 × 0.68 + 0.5.
    try std.testing.expectApproxEqAbs(@as(f32, 0.9486), dayPercent(8 * 1000 + 500, dawn, dusk), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9486), dayPercent(17 * 1000 + 500, dawn, dusk), 0.0001);
    // Night minimum: midnight and 1:00 floor at 0.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dayPercent(0, dawn, dusk), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dayPercent(1 * 1000, dawn, dusk), 0.0001);
}

test "sky: ambientLuma applies the GetLightLevel ambient shaping" {
    // AmbientTotal^0.6 × 0.5: 0.5 at full daylight, 0 at the night minimum,
    // ~0.33 at the dawn/dusk 0.5 day percent.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), ambientLuma(1.0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ambientLuma(0.0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3299), ambientLuma(0.5), 0.0001);
}
