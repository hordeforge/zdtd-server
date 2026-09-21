//! Entity stat bodies: StatChanged/EnumStat, award-kill, attack
//! target, and the stealth bodies with their bit-packing tests.
//!
//! Split out of the packages.zig facade (same builders, same tests);
//! import via `packages.stock_estats` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// Stock NetPackageEntityStatChanged/EnumStat (nested enum).
pub const EntityStatKind = enum(u8) {
    health = 0,
    stamina = 1,
    sickness = 2,
    gassiness = 3,
    speed_modifier = 4,
    wellness = 5,
    core_temp_old = 6,
    food = 7,
    water = 8,
};

/// Stock body after channel pkgId (NetPackageEntityTargeted + StatChanged fields):
/// entityId:i32 | instigatorId:i32 | enumStat:u8 | value:f32 | max:f32 | maxModifier:f32
pub fn buildEntityStatChangedBody(
    buf: []u8,
    entity_id: i32,
    instigator_id: i32,
    kind: EntityStatKind,
    value: f32,
    max: f32,
    max_modifier: f32,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeI32(instigator_id);
    try w.writeByte(@intFromEnum(kind));
    try w.writeF32(value);
    try w.writeF32(max);
    try w.writeF32(max_modifier);
    return w.written();
}

/// Stock NetPackageEntityAwardKillServer body (read IL=9): EntityId:i32 (the
/// killer) | KilledEntityId:i32. Sent by `GameManager.AwardKill` (IL=27) to a
/// remote killer so its client fires the local EntityKill event that kill
/// challenges subscribe to.
pub fn buildAwardKillBody(buf: []u8, killer_id: i32, killed_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(killer_id);
    try w.writeI32(killed_id);
    return w.written();
}

/// Stock NetPackageSetAttackTarget body (read IL=8, GetLength 8):
/// entityId:i32 (the NetPackageEntityTargeted base) | targetId:i32. The
/// client feeds it to `EntityAlive::SetAttackTargetClient`, which backs
/// `GetAttackTargetLocal` for remote entities (drone beam targeting and the
/// DynamicMusic threat level read it). `target_id` is -1 for "no target",
/// which is what stock sends when the attack-target window expires
/// (EntityAlive::OnUpdateLive) as well as on an explicit clear.
pub fn buildSetAttackTargetBody(buf: []u8, entity_id: i32, target_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeI32(target_id);
    return w.written();
}

/// Stock NetPackageEntityStealth body (write IL=12): id:i32 | data:u16.
///
/// The three `Setup` overloads pack `data` three mutually exclusive ways, and
/// none of them combines the crouch flag with the light/noise payload:
///   - `Setup(player, isCrouching)` sets data to exactly 0 or 1 (IL=13, :9).
///   - `Setup(local, smellRadius, eating, sheltered)` is the smell form,
///     tagged with bit 1 and routed server-side (IL=36, :24).
///   - `Setup(player, lightLevel, noiseVolume, isAlert)` packs
///     `(byte)lightLevel | ((noise & 127) << 8)`, plus bit 15 for alert
///     (IL=26, :62). This is the one PlayerStealth.TickServer broadcasts.
/// The client branch reads `light = (byte)data`, so the light level owns the
/// whole low byte (ProcessPackage IL_009F-00A5). ORing a crouch bit into the
/// light form would land inside that byte and report light+1.
pub fn buildEntityStealthBody(
    buf: []u8,
    entity_id: i32,
    light_level: u8,
    noise_volume: u8,
    is_alert: bool,
) ![]u8 {
    var data: u16 = @as(u16, light_level) | (@as(u16, noise_volume & 127) << 8);
    if (is_alert) data |= 32768;
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeU16(data);
    return w.written();
}

/// The crouch-only `Setup(player, isCrouching)` form (IL=13): data is the bare
/// flag, never combined with the light/noise payload.
pub fn buildEntityStealthCrouchBody(buf: []u8, entity_id: i32, is_crouching: bool) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeU16(@intFromBool(is_crouching));
    return w.written();
}

test "entity stealth body packs the stock data bits" {
    var buf: [16]u8 = undefined;
    const body = try buildEntityStealthBody(&buf, 107, 5, 90, true);
    try std.testing.expectEqual(@as(usize, 6), body.len);
    try std.testing.expectEqual(@as(i32, 107), std.mem.readInt(i32, body[0..4], .little));
    const data = std.mem.readInt(u16, body[4..6], .little);
    try std.testing.expectEqual(@as(u16, 5), data & 0xff); // light
    try std.testing.expectEqual(@as(u16, 90), (data >> 8) & 127); // noise
    try std.testing.expect(data & 32768 != 0); // alert
}

test "stealth light owns the whole low byte" {
    // The client reads light as (byte)data, so an odd light value must not be
    // confusable with the crouch form: light 5 stays 5, never 4 or 5|crouch.
    var buf: [16]u8 = undefined;
    for ([_]u8{ 0, 1, 2, 3, 5, 127, 254, 255 }) |light| {
        const body = try buildEntityStealthBody(&buf, 107, light, 0, false);
        const data = std.mem.readInt(u16, body[4..6], .little);
        try std.testing.expectEqual(@as(u16, light), data & 0xff);
    }
}

test "crouch stealth body is the bare flag form" {
    var buf: [16]u8 = undefined;
    const on = try buildEntityStealthCrouchBody(&buf, 107, true);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, on[4..6], .little));
    var buf2: [16]u8 = undefined;
    const off = try buildEntityStealthCrouchBody(&buf2, 107, false);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, off[4..6], .little));
}

test "entity stat changed body size" {
    var buf: [32]u8 = undefined;
    // value and max were both 100 and maxModifier 0, so the three trailing
    // floats were two duplicates and a zero: a swap among them emitted the
    // same bytes. Distinct values make the run observable.
    const body = try buildEntityStatChangedBody(&buf, 106, -1, .health, 75, 100, 25);
    try std.testing.expectEqual(@as(usize, 4 + 4 + 1 + 4 + 4 + 4), body.len);
    try std.testing.expectEqual(@as(i32, 106), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, body[4..8], .little)); // instigator
    try std.testing.expectEqual(@as(u8, 0), body[8]); // Health
    const f32At = struct {
        fn get(b: []const u8, off: usize) f32 {
            return @bitCast(std.mem.readInt(u32, b[off..][0..4], .little));
        }
    }.get;
    try std.testing.expectEqual(@as(f32, 75), f32At(body, 9)); // value
    try std.testing.expectEqual(@as(f32, 100), f32At(body, 13)); // max
    try std.testing.expectEqual(@as(f32, 25), f32At(body, 17)); // maxModifier
}

