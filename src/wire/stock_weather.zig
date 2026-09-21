//! Weather bodies: biome snapshot struct and the broadcast builder,
//! with the layout tests.
//!
//! Split out of the packages.zig facade (same code, same tests);
//! import via `packages.stock_weather` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// One biome weather snapshot (WeatherPackage on wire).
pub const WeatherBiome = struct {
    biome_id: u8 = 3,
    group_index: u8 = 0,
    /// Number of weather groups this biome has in the biomes.xml we serve. The
    /// client indexes weatherGroups with groupIndex unchecked, so this bounds it.
    group_count: u8 = 1,
    remaining_seconds: u8 = 0,
    /// temp, precip, cloud, wind, fog. Raw biomes.xml scale (temp F, rest 0..100);
    /// the client divides by 100 (BiomeWeather::FogPercent, asm.il ~2048596).
    params: [5]f32 = .{ 70, 0, 20, 10, 5 },
};

/// Stock NetPackageWeather: no count prefix; client sizes from its biomeWeather.Count.
/// Emit one entry per biomemap biome we care about (same count both sides ideally).
/// RE: weather-environment.md §3: biomeId u8, groupIndex u8, remainingSeconds u8, 5xf32.
///
/// groupIndex is clamped here because BiomeDefinition::SetWeatherGroup (asm.il
/// ~1250261) does an unchecked weatherGroups[_index]: an out-of-range index is an
/// unhandled exception inside ClientProcessPackages on an unmodified client.
/// Index 0 always exists for a biome that has weather at all.
pub fn buildWeatherBody(buf: []u8, biomes: []const WeatherBiome) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    for (biomes) |b| {
        try w.writeByte(b.biome_id);
        try w.writeByte(if (b.group_index < b.group_count) b.group_index else 0);
        try w.writeByte(b.remaining_seconds);
        for (b.params) |p| try w.writeF32(p);
    }
    return w.written();
}

test "weather body five biomes is 115" {
    var buf: [256]u8 = undefined;
    var biomes: [5]WeatherBiome = [_]WeatherBiome{.{}} ** 5;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        biomes[i].biome_id = @intCast(i + 1);
        biomes[i].group_index = @intCast(i);
        biomes[i].group_count = 11;
        biomes[i].remaining_seconds = @intCast(10 + i);
        biomes[i].params = .{ 70 + @as(f32, @floatFromInt(i)), 0.1, 0.2, 0.3, 0.4 };
    }
    const body = try buildWeatherBody(&buf, biomes[0..]);
    // 5 × (3 bytes + 5×f32) = 5 × 23 = 115
    try std.testing.expectEqual(@as(usize, 115), body.len);
    // Entry 0 layout: biomeId, groupIndex, remainingSeconds, then params[0] f32
    try std.testing.expectEqual(@as(u8, 1), body[0]);
    try std.testing.expectEqual(@as(u8, 0), body[1]);
    try std.testing.expectEqual(@as(u8, 10), body[2]);
    const temp0: f32 = @bitCast(std.mem.readInt(u32, body[3..7], .little));
    try std.testing.expectEqual(@as(f32, 70), temp0);
    // Entry 4 starts at 4*23 = 92
    try std.testing.expectEqual(@as(u8, 5), body[92]);
    try std.testing.expectEqual(@as(u8, 4), body[93]);
    try std.testing.expectEqual(@as(u8, 14), body[94]);
    const temp4: f32 = @bitCast(std.mem.readInt(u32, body[95..99], .little));
    try std.testing.expectEqual(@as(f32, 74), temp4);
}

test "weather body clamps out of range group index" {
    var buf: [128]u8 = undefined;
    const biomes = [_]WeatherBiome{
        .{ .biome_id = 3, .group_index = 5, .group_count = 11 },
        .{ .biome_id = 5, .group_index = 5, .group_count = 4 },
        .{ .biome_id = 8, .group_index = 0, .group_count = 0 },
    };
    const body = try buildWeatherBody(&buf, biomes[0..]);
    try std.testing.expectEqual(@as(usize, 69), body.len);
    try std.testing.expectEqual(@as(u8, 5), body[1]);
    // Index past the biome's group list would throw inside SetWeatherGroup.
    try std.testing.expectEqual(@as(u8, 0), body[24]);
    try std.testing.expectEqual(@as(u8, 0), body[47]);
}
