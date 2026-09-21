//! NetPackageDamageEntity body (V3.2.0 packed-flags head + 30-field stock
//! body; RE inventories/netpackage-bodies.md, write IL=144, changelog-3.2.0
//! §3.1 / protocol.md §6.5).
//!
//! Split out of the packages.zig facade (same builders, same golden tests);
//! import via `packages.stock_damage` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// NetPackageDamageEntity flags (V3.2.0 packed u32 bitfield; the 3.1.0 wire
/// wrote ten separate booleans, changelog-3.2.0 §3.1 / protocol.md §6.5).
pub const dmg_can_hit_special: u32 = 0x001;
pub const dmg_cripple_legs: u32 = 0x002;
pub const dmg_critical: u32 = 0x004;
pub const dmg_dismember: u32 = 0x008;
pub const dmg_fatal: u32 = 0x010;
pub const dmg_from_buff: u32 = 0x020;
pub const dmg_ignore_consecutive: u32 = 0x040;
pub const dmg_ignore_party_share: u32 = 0x080;
pub const dmg_pain_hit: u32 = 0x100;
pub const dmg_turn_into_crawler: u32 = 0x200;
pub const dmg_trap_kill_xp: u32 = 0x400;

/// NetPackageDamageEntity (RE inventories/netpackage-bodies.md, write IL=144).
/// All 30 fields in stock order: `entityId` i32 | `flags` u32 | `damageSrc` u8 |
/// `damageTyp` u8 | `strength` u16 | `hitDirection` u8 | `hitBodyPart` i16 |
/// `movementState` u8 | `attackerEntityId` i32 | dir f32 x3 | `blockPos`
/// (StreamUtils Vector3i) | `hitTransformName` string | hitTransformPosition
/// f32 x3 | uvHit f32 x2 | `KillXPScale` f32 | `damageMultiplier` f32 |
/// `random` f32 | `bonusDamageType` u8 | `StunType` u8 | `StunDuration` f32 |
/// `ArmorSlot` u8 | `ArmorSlotGroup` u8 | `ArmorDamage` u16 | `attackingItem`
/// bool, then the ItemValue only when that bool is true.
///
/// zdtd fills the head (entity, flags, source, type, strength, attacker) and
/// writes the descriptive tail as neutral values: hit transform, uv and armour
/// slots describe a client-side hit report we do not originate, and the false
/// `attackingItem` flag is the stock null path rather than a truncation.
pub fn buildDamageBody(buf: []u8, entity_id: i32, source: u8, dtype: u8, strength: u16, fatal: bool, attacker: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    var flags: u32 = dmg_pain_hit;
    if (fatal) flags |= dmg_fatal;
    try w.writeU32(flags);
    try w.writeByte(source);
    try w.writeByte(dtype);
    try w.writeU16(strength);
    try w.writeByte(0); // hitDirection
    try w.writeI16(0); // bodyPart
    try w.writeByte(0); // movementState
    try w.writeI32(attacker);
    try w.writeF32(0);
    try w.writeF32(-1);
    try w.writeF32(0); // dirV
    try w.writeI32(0);
    try w.writeI32(0);
    try w.writeI32(0); // blockPos
    try w.writeString(""); // hitTransformName
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0); // hitTransformPosition
    try w.writeF32(0);
    try w.writeF32(0); // uvHit
    try w.writeF32(1); // KillXPScale
    try w.writeF32(1); // damageMultiplier
    try w.writeF32(0); // random
    try w.writeByte(0); // bonusDamageType
    try w.writeByte(0); // StunType
    try w.writeF32(0); // StunDuration
    try w.writeByte(0); // ArmorSlot
    try w.writeByte(0); // ArmorSlotGroup
    try w.writeU16(0); // ArmorDamage
    try w.writeBool(false); // attackingItem present
    return w.written();
}

/// Read side of the V3.2.0 NetPackageDamageEntity head: `entityId` i32 |
/// packed flags u32 | `source` u8 | `damageType` u8 | `strength` u16 |
/// `hitDirection` u8 | `hitBodyPart` i16, matching the builder above (the ten
/// 3.1.0 booleans folded into one flag word in 3.2.0; docs/wire/PACKAGES.md).
/// The tail past the head is not decoded: the server recomputes damage from
/// its own weapon and armor state, so those fields are not values it acts on.
pub fn parseDamageHead(body: []const u8) !struct { entity_id: i32, source: u8, dtype: u8, strength: u16, fatal: bool, trap_kill_xp: bool, body_part: i16 } {
    if (body.len < 4 + 4 + 1 + 1 + 2 + 1 + 2 + 1) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const entity_id = try r.readI32();
    const flags = try r.readU32();
    const source = try r.readByte();
    const dtype = try r.readByte();
    const strength = try r.readU16();
    _ = try r.readByte(); // hitDirection
    const body_part = try r.readI16(); // hitBodyPart (EnumBodyPartHit)
    _ = try r.readByte(); // movementState
    return .{
        .entity_id = entity_id,
        .source = source,
        .dtype = dtype,
        .strength = strength,
        .fatal = (flags & dmg_fatal) != 0,
        .trap_kill_xp = (flags & dmg_trap_kill_xp) != 0,
        .body_part = body_part,
    };
}

test "DamageEntity V3.2.0 golden layout: packed flags + KillXPScale at fixed offsets" {
    // The 3.1.0 ten-boolean wire was repacked (changelog-3.2.0 §3.1); the
    // stock client Reads this body on the C2S damage path, so the byte
    // layout is pinned here, not just the build/parse roundtrip (a
    // self-consistent build+parse break would still pass scenarios but
    // desync the real client's Read). Offsets derived from the builder's
    // write order: entityId 0, flags 4, source 8, dtype 9, strength 10,
    // hitDirection 12, bodyPart 13, movementState 15, attacker 16, ...,
    // KillXPScale 65, damageMultiplier 69.
    var buf: [128]u8 = undefined;
    const body = try buildDamageBody(&buf, 0x11223344, 1, 3, 100, true, 0x55667788);
    try std.testing.expectEqual(@as(usize, 88), body.len);
    try std.testing.expectEqual(@as(i32, 0x11223344), std.mem.readInt(i32, body[0..4], .little));
    // fatal=true -> pain_hit | fatal = 0x100 | 0x010.
    try std.testing.expectEqual(@as(u32, 0x110), std.mem.readInt(u32, body[4..8], .little));
    try std.testing.expectEqual(@as(u8, 1), body[8]); // source
    try std.testing.expectEqual(@as(u8, 3), body[9]); // dtype
    try std.testing.expectEqual(@as(u16, 100), std.mem.readInt(u16, body[10..12], .little));
    try std.testing.expectEqual(@as(i32, 0x55667788), std.mem.readInt(i32, body[16..20], .little));
    // The direction vector at 20 is (0, -1, 0): two zeros around a -1, so the
    // -1 is the only observable word and its position is what a swap moves.
    const f32At = struct {
        fn get(b: []const u8, off: usize) f32 {
            return @bitCast(std.mem.readInt(u32, b[off..][0..4], .little));
        }
    }.get;
    try std.testing.expectEqual(@as(f32, 0), f32At(body, 20));
    try std.testing.expectEqual(@as(f32, -1), f32At(body, 24)); // dirV y
    try std.testing.expectEqual(@as(f32, 0), f32At(body, 28));
    // KillXPScale (V3.2.0 addition) sits at 65; damageMultiplier at 69.
    const kxs: f32 = @bitCast(std.mem.readInt(u32, body[65..69], .little));
    try std.testing.expectEqual(@as(f32, 1.0), kxs);
    const dm: f32 = @bitCast(std.mem.readInt(u32, body[69..73], .little));
    try std.testing.expectEqual(@as(f32, 1.0), dm);
    const head = try parseDamageHead(body);
    try std.testing.expectEqual(@as(i32, 0x11223344), head.entity_id);
    try std.testing.expectEqual(@as(u16, 100), head.strength);
    try std.testing.expect(head.fatal);
    try std.testing.expect(!head.trap_kill_xp);
}

test "DamageEntity packed flags: fatal and trap_kill_xp bits parse independently" {
    var buf: [128]u8 = undefined;
    // trap_kill_xp only (0x400): fatal must be false, trap true. The head
    // needs the full 16 bytes (entityId+flags+source+dtype+strength+
    // hitDirection+bodyPart+movementState) before parseDamageHead accepts it.
    var w: binary.Writer = .{ .buf = &buf };
    try w.writeI32(7);
    try w.writeU32(dmg_trap_kill_xp);
    try w.writeByte(0); // source
    try w.writeByte(0); // dtype
    try w.writeU16(5); // strength
    try w.writeByte(0); // hitDirection
    try w.writeI16(0); // bodyPart
    try w.writeByte(0); // movementState
    const body = buf[0..w.written().len];
    const head = try parseDamageHead(body);
    try std.testing.expect(!head.fatal);
    try std.testing.expect(head.trap_kill_xp);
    try std.testing.expectEqual(@as(u16, 5), head.strength);
}
