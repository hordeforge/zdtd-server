//! Explosion body: the client explosion broadcast with the layout test.
//!
//! Split out of the packages.zig facade (same builder, same test);
//! import via `packages.stock_explosion` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");
const readWorldF32 = @import("stock_motion.zig").readWorldF32;
const readWorldI32 = @import("stock_motion.zig").readWorldI32;

/// NetPackageExplosionClient (RE protocol-packages.md 6.15 + write IL=60):
/// `center` Vector3 | `rotation` Quaternion | `expType` i16 | `blastPower` u16 |
/// `blastRadius` u16 | `blockDamage` u16 | `entityId` i32 | `changeCount` u16,
/// then changeCount x BlockChangeInfo. zdtd emits the FX with an empty change
/// list: block results already ride the authoritative SetBlock path, so
/// repeating them here would apply them twice on the client.
pub fn buildExplosionClient(
    buf: []u8,
    cx: f32,
    cy: f32,
    cz: f32,
    exp_type: i16,
    blast_power: u16,
    blast_radius: u16,
    block_damage: u16,
    entity_id: i32,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeF32(cx);
    try w.writeF32(cy);
    try w.writeF32(cz);
    // Quaternion identity (x,y,z,w)
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(1);
    try w.writeI16(exp_type);
    try w.writeU16(blast_power);
    try w.writeU16(blast_radius);
    try w.writeU16(block_damage);
    try w.writeI32(entity_id);
    try w.writeU16(0); // explosionChanges count
    return w.written();
}

test "explosion client body layout" {
    // No test covered this builder. It is pos Vector3 | identity quaternion |
    // type i16 | blastPower u16 | blastRadius u16 | blockDamage u16 |
    // entityId i32 | changes count u16, and the three u16 in a row are the
    // part a swap moves without changing the length.
    var buf: [64]u8 = undefined;
    const body = try buildExplosionClient(&buf, 11, 12, 13, 3, 21, 22, 23, 106);
    try std.testing.expectEqual(@as(usize, 12 + 16 + 2 + 6 + 4 + 2), body.len);
    const f32At = struct {
        fn get(b: []const u8, off: usize) f32 {
            return @bitCast(std.mem.readInt(u32, b[off..][0..4], .little));
        }
    }.get;
    try std.testing.expectEqual(@as(f32, 11), f32At(body, 0));
    try std.testing.expectEqual(@as(f32, 12), f32At(body, 4));
    try std.testing.expectEqual(@as(f32, 13), f32At(body, 8));
    // Identity quaternion: three zeros then w = 1.
    try std.testing.expectEqual(@as(f32, 0), f32At(body, 12));
    try std.testing.expectEqual(@as(f32, 1), f32At(body, 24));
    try std.testing.expectEqual(@as(i16, 3), std.mem.readInt(i16, body[28..30], .little));
    try std.testing.expectEqual(@as(u16, 21), std.mem.readInt(u16, body[30..32], .little)); // blastPower
    try std.testing.expectEqual(@as(u16, 22), std.mem.readInt(u16, body[32..34], .little)); // blastRadius
    try std.testing.expectEqual(@as(u16, 23), std.mem.readInt(u16, body[34..36], .little)); // blockDamage
    try std.testing.expectEqual(@as(i32, 106), std.mem.readInt(i32, body[36..40], .little));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, body[40..42], .little));
}

/// C2S ExplosionInitiate head (protocol-frames §12).
/// worldPos 3xf32 | blockPos 3xi32 | quat 4xf32 | blobLen u16 | blob | entityId i32 | delay f32 …
pub const ExplosionInitiate = struct {
    wx: f32 = 0,
    wy: f32 = 0,
    wz: f32 = 0,
    bx: i32 = 0,
    by: i32 = 0,
    bz: i32 = 0,
    entity_id: i32 = -1,
    delay_s: f32 = 0,
    /// Best-effort radius from nested blob (default 3).
    radius: f32 = 3,
    block_damage: u16 = 50,
    /// ExplosionData.EntityRadius, a raw i16 in blocks (default 3).
    entity_radius: f32 = 3,
    /// ExplosionData.entityDamage (default 0 -> falls back to block_damage).
    entity_damage: f32 = 0,
};

/// Read side of NetPackageExplosionInitiate (RE protocol-packages.md,
/// inventories/netpackage-bodies.md write IL=55): `worldPos` Vector3 |
/// `blockPos` Vector3i | `rotation` Quaternion | `explosionBlobLen` u16 + blob
/// | `entityId` i32 | `delay` f32 | `bRemoveBlockAtExplPosition` bool | item
/// present bool + ItemValue.
///
/// The two trailing fields are not read. `bRemoveBlockAtExplPosition` clears
/// the center block in stock (GameManager.ExplosionServer IL=50), which
/// c2s/blocks.zig does anyway, and the optional ItemValue feeds passives
/// 19/20/21 (block damage, entity damage, radius) that zdtd does not apply to
/// a client-supplied blast. Both sit at the end of the body, so skipping them
/// cannot desync the reader.
pub fn parseExplosionInitiate(body: []const u8) !ExplosionInitiate {
    var r: binary.Reader = .{ .data = body };
    var out: ExplosionInitiate = .{};
    out.wx = try readWorldF32(&r);
    out.wy = try readWorldF32(&r);
    out.wz = try readWorldF32(&r);
    out.bx = try readWorldI32(&r);
    out.by = try readWorldI32(&r);
    out.bz = try readWorldI32(&r);
    // quat 4xf32
    _ = try r.readF32();
    _ = try r.readF32();
    _ = try r.readF32();
    _ = try r.readF32();
    const blob_len = try r.readU16();
    if (blob_len > 0) {
        if (r.remaining() < blob_len) return error.EndOfStream;
        const blob = r.data[r.pos .. r.pos + blob_len];
        r.pos += blob_len;
        // ExplosionData.Read (IL): particleIndex i16 | duration i16*0.1 |
        // blockRadius i16*0.05 | entityRadius i16 | blastPower i16 |
        // blockDamage f32 | entityDamage f32 | blockTags string |
        // ignoreHeatMap bool | damageType i16 | DamageMultiplier(i16 n + pairs) |
        // buffCount u8 + strings. We consume through blockDamage; rest unused.
        var br: binary.Reader = .{ .data = blob };
        _ = br.readI16() catch 0; // particleIndex
        _ = br.readI16() catch 0; // duration deci-seconds
        const radius_raw = br.readI16() catch 0;
        if (radius_raw > 0) out.radius = @as(f32, @floatFromInt(radius_raw)) * 0.05;
        // EntityRadius is a raw i16 in blocks: the RE table notes a scale
        // factor on Duration (x10) and BlockRadius (x20) and leaves this row
        // blank (protocol-packages.md ExplosionData, Read IL=82). Dividing it
        // by 20 as well turned the stock value 6 into 0.3, which the caller
        // then clamped up to its 1 m floor, so a stock explosion barely
        // reached any entity while its block damage worked normally.
        if (br.readI16()) |er| {
            if (er > 0) out.entity_radius = @floatFromInt(er);
        } else |_| {}
        _ = br.readI16() catch 0; // blastPower
        if (br.readF32()) |bd| {
            if (bd > 0 and bd <= 65535) out.block_damage = @trunc(bd);
        } else |_| {}
        if (br.readF32()) |ed| {
            if (ed > 0 and ed <= 65535) out.entity_damage = ed;
        } else |_| {}
    }
    if (r.remaining() >= 4) out.entity_id = try r.readI32();
    if (r.remaining() >= 4) out.delay_s = try r.readF32();
    return out;
}


test "explosion initiate parse head" {
    var buf: [128]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try w.writeF32(1);
    try w.writeF32(70);
    try w.writeF32(2);
    try w.writeI32(1);
    try w.writeI32(70);
    try w.writeI32(2);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(1);
    try w.writeU16(0);
    try w.writeI32(106);
    try w.writeF32(0.5);
    const p = try parseExplosionInitiate(w.written());
    try std.testing.expectApproxEqAbs(@as(f32, 1), p.wx, 0.01);
    try std.testing.expectEqual(@as(i32, 70), p.by);
    try std.testing.expectEqual(@as(i32, 106), p.entity_id);
}
test "explosion initiate parses ExplosionData blob positionally" {
    var buf: [160]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try w.writeF32(1);
    try w.writeF32(70);
    try w.writeF32(2);
    try w.writeI32(1);
    try w.writeI32(70);
    try w.writeI32(2);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(1);
    // ExplosionData blob: particle 3, duration 10, blockRadius raw 80 (=4.0),
    // entityRadius 4, blastPower 100, blockDamage 250.0, entityDamage 60.0
    var blob_buf: [64]u8 = undefined;
    var bw: binary.Writer = .{ .buf = &blob_buf };
    try bw.writeI16(3);
    try bw.writeI16(10);
    try bw.writeI16(80);
    try bw.writeI16(4);
    try bw.writeI16(100);
    try bw.writeF32(250.0);
    try bw.writeF32(60.0);
    const blob = bw.written();
    try w.writeU16(@intCast(blob.len));
    try w.writeBytes(blob);
    try w.writeI32(107);
    try w.writeF32(0);
    const p = try parseExplosionInitiate(w.written());
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), p.radius, 0.01);
    try std.testing.expectEqual(@as(u16, 250), p.block_damage);
    try std.testing.expectEqual(@as(i32, 107), p.entity_id);
}
test "explosion blob decodes radii at their stock scales" {
    // ExplosionData (RE protocol-packages.md, Read IL=82): Duration is stored
    // x10 and BlockRadius x20, EntityRadius and BlastPower are raw. The stock
    // cop/feral explosion is radius_blocks 5, radius_entities 6, so a blob
    // carrying 100 and 6 must decode to 5.0 and 6.0 blocks.
    var body: [128]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    try w.writeF32(10); // worldPos
    try w.writeF32(70);
    try w.writeF32(10);
    try w.writeI32(10); // blockPos
    try w.writeI32(70);
    try w.writeI32(10);
    try w.writeF32(0); // rotation quaternion
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(1);

    var blob: [64]u8 = undefined;
    var bw: binary.Writer = .{ .buf = &blob };
    try bw.writeI16(3); // particleIndex
    try bw.writeI16(25); // duration, x10 -> 2.5 s
    try bw.writeI16(100); // blockRadius, x20 -> 5 blocks
    try bw.writeI16(6); // entityRadius, raw -> 6 blocks
    try bw.writeI16(1); // blastPower
    try bw.writeF32(120); // blockDamage
    try bw.writeF32(45); // entityDamage
    const blob_bytes = bw.written();

    try w.writeU16(@intCast(blob_bytes.len));
    try w.writeBytes(blob_bytes);
    try w.writeI32(42); // entityId
    try w.writeF32(0); // delay

    const ex = try parseExplosionInitiate(w.written());
    try std.testing.expectEqual(@as(i32, 42), ex.entity_id);
    try std.testing.expectApproxEqAbs(@as(f32, 5), ex.radius, 0.001);
    // The bug this pins: entity_radius was divided by 20 as well, so the stock
    // value 6 arrived as 0.3 and the caller's 1 m floor swallowed it.
    try std.testing.expectApproxEqAbs(@as(f32, 6), ex.entity_radius, 0.001);
    try std.testing.expectEqual(@as(u16, 120), ex.block_damage);
    try std.testing.expectApproxEqAbs(@as(f32, 45), ex.entity_damage, 0.001);
}
