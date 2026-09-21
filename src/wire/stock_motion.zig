//! Entity motion bodies: PosAndRot/teleport, spawn response, trader
//! stock data, rel-pos, AliveFlags, speeds, and the player-data ECD
//! head parser.
//!
//! Split out of the packages.zig facade (same builders, same shapes);
//! import via `packages.stock_motion` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");
const stock_inv = @import("stock_inv.zig");
const stock_entity = @import("stock_entity.zig");
const components = @import("../ecs/components.zig");

/// NetPackageEntityPosAndRot (RE protocol-packages.md 5.5.1, write IL=76):
/// `entityId` i32 | pos.x,y,z f32 | `bUseQRotation` bool | rot.x,y,z f32 euler
/// degrees (the `false` branch) | `onGround` bool. The client applies it with 3
/// update steps.
pub fn buildPosAndRotBody(buf: []u8, entity_id: i32, x: f32, y: f32, z: f32, rx: f32, ry: f32, rz: f32, on_ground: bool) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeF32(x);
    try w.writeF32(y);
    try w.writeF32(z);
    try w.writeBool(false);
    try w.writeF32(rx);
    try w.writeF32(ry);
    try w.writeF32(rz);
    try w.writeBool(on_ground);
    return w.written();
}

/// NetPackageEntityTeleport shares PosAndRot wire (subclass of EntityPosAndRot).
pub fn buildEntityTeleportBody(buf: []u8, entity_id: i32, x: f32, y: f32, z: f32, rx: f32, ry: f32, rz: f32, on_ground: bool) ![]u8 {
    return buildPosAndRotBody(buf, entity_id, x, y, z, rx, ry, rz, on_ground);
}

/// NetPackageEntitySpawnResponse: success:bool | ItemValue. The client's
/// ProcessPackage dereferences ItemValue.ItemClass unconditionally, so the
/// item must be real: an empty sentinel NREs the stock client (the reason
/// this is only sent on place/throw, never on join). `item` null still
/// writes the empty sentinel for callers that only need the ack.
pub fn buildEntitySpawnResponse(buf: []u8, success: bool, item: ?stock_inv.StockSlot) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(success);
    if (item) |it| {
        try stock_inv.writeItemValue(&w, it);
    } else {
        try stock_inv.writeEmptyItemValue(&w);
    }
    return w.written();
}

/// Stock TraderData with primary inventory entries (ItemStack + markup i8 + addedByPlayer).
pub const TraderStockEntry = stock_entity.TraderStockEntry;

/// Stock NetPackageTraderData.write (asm.il 839492-839540): the entity id and
/// tePosition are mutually exclusive. Write(bool = entityId != -1); when true it
/// writes ONLY the i32 entityId and branches past the position write. Our near-spawn
/// trader is an EntityTrader, so we always take the entity-id branch. Emitting a
/// tePosition here would desync the client's read and corrupt the TraderData body.
pub fn buildTraderDataStock(
    buf: []u8,
    entity_id: i32,
    trader_id: i32,
    available_money: i32,
    entries: []const TraderStockEntry,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(true); // entityId != -1
    try w.writeI32(entity_id);
    try w.writeBool(true); // has TraderData
    try stock_entity.writeTraderDataBody(&w, .{
        .trader_id = trader_id,
        .available_money = available_money,
        .entries = entries,
    });
    return w.written();
}

/// Widest world coordinate a client may claim. Downstream sim code funnels
/// positions through `@floor(v)`, which traps on NaN/inf/huge in
/// safe builds, so non-finite coordinates are rejected at the wire boundary
/// rather than clamped somewhere deeper.
const world_coord_limit: f32 = 1 << 24;

pub fn readWorldF32(r: *binary.Reader) binary.ReadError!f32 {
    const v = try r.readF32();
    if (!std.math.isFinite(v) or @abs(v) > world_coord_limit) return error.Overflow;
    return v;
}

/// Finite float for rot/speed fields (no world-coord range).
fn readFiniteF32(r: *binary.Reader) binary.ReadError!f32 {
    const v = try r.readF32();
    if (!std.math.isFinite(v)) return error.Overflow;
    return v;
}

/// Integer counterpart of readWorldF32: same range, so a small per-axis
/// delta (block-dig radius etc.) added to it downstream cannot overflow i32.
const world_coord_limit_i32: i32 = 1 << 24;

pub fn readWorldI32(r: *binary.Reader) binary.ReadError!i32 {
    const v = try r.readI32();
    if (v > world_coord_limit_i32 or v < -world_coord_limit_i32) return error.Overflow;
    return v;
}

/// Read side of NetPackageEntityPosAndRot (RE protocol-packages.md 5.5.1, write
/// IL=76): `entityId` i32 | pos.x,y,z f32 | `bUseQRotation` bool | then either
/// euler f32 x3 or a quaternion f32 x4, mutually exclusive | `onGround` bool.
/// NetPackageEntityTeleport has no own write and rides this exact body (5.5.2),
/// so both C2S handlers share this parser.
///
/// Rotation is consumed but not returned: the server keeps the yaw it already
/// has for the entity, and a rotation from the wire is not a value it acts on.
/// Position goes through readWorldF32 so a coordinate outside the world bound
/// is an error here, not a teleport the sim has to undo.
/// `wire_len` is where the stock body ends, which is not `body.len`: the
/// `bUseQRotation` branch makes the length variable, and a peer may append
/// trailing bytes. A relay must forward `body[0..wire_len]`, never the raw
/// slice.
pub fn parsePosAndRotBody(body: []const u8) !struct { entity_id: i32, x: f32, y: f32, z: f32, on_ground: bool, wire_len: usize } {
    if (body.len < 30) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const entity_id = try r.readI32();
    const x = try readWorldF32(&r);
    const y = try readWorldF32(&r);
    const z = try readWorldF32(&r);
    const use_q = try r.readBool();
    if (!use_q) {
        _ = try readFiniteF32(&r);
        _ = try readFiniteF32(&r);
        _ = try readFiniteF32(&r);
    } else {
        _ = try readFiniteF32(&r);
        _ = try readFiniteF32(&r);
        _ = try readFiniteF32(&r);
        _ = try readFiniteF32(&r);
    }
    const on_ground = try r.readBool();
    return .{ .entity_id = entity_id, .x = x, .y = y, .z = z, .on_ground = on_ground, .wire_len = r.pos };
}

/// NetPackageEntityRelPosAndRot (RE protocol-packages.md 5.5.4, write IL=30).
/// Extends the Rotation body (5.5.3), so the full wire order is: `entityId` i32
/// | `bUseQRotation` bool | rot.x,y,z i16 (EncodeRot, rot*256/360) | dPos.x,y,z
/// i16 (1/32 block) | `onGround` bool | `updateSteps` i16. The body-inventory
/// table lists only the five fields after the Rotation base.
pub fn buildRelPosBody(buf: []u8, entity_id: i32, dx: i16, dy: i16, dz: i16, rx: i16, ry: i16, rz: i16, on_ground: bool, steps: i16) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeBool(false);
    try w.writeI16(rx);
    try w.writeI16(ry);
    try w.writeI16(rz);
    try w.writeI16(dx);
    try w.writeI16(dy);
    try w.writeI16(dz);
    try w.writeBool(on_ground);
    try w.writeI16(steps);
    return w.written();
}

/// Stock NetPackageEntityAliveFlags bits actually set on the S2C path (V3).
/// Values are canonical in ecs/components.zig (single source of truth for the
/// bit numbers); these aliases keep the stock wire naming.
pub const cF_approaching_player: u16 = components.flag_approaching_player;
pub const cF_spawned: u16 = components.flag_spawned;
pub const cF_is_alert: u16 = components.flag_is_alert;
/// Stock `IsCrouching` bit (protocol-packages.md 5.5.6): set by the client's
/// EntityFlags/AliveFlags package; the sim reads it for the stealth sense
/// gates (hear muffle + sleeper detect).
pub const cF_crouching: u16 = components.flag_crouching;

/// NetPackageEntityAliveFlags (RE inventories/netpackage-bodies.md, write
/// IL=8): the EntityTargeted base entityId, then `flags` u16. Bit meanings in
/// protocol-packages.md 5.5.6.
pub fn buildAliveFlagsBody(buf: []u8, entity_id: i32, flags: u16) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeU16(flags);
    return w.written();
}

/// Read side of NetPackageEntityAliveFlags (RE protocol-packages.md 5.5.6,
/// write IL=8): `entityId` i32 | `flags` u16, the order buildAliveFlagsBody
/// writes. Unknown bits are kept rather than masked off: the bit meanings are
/// canonical in ecs/components.zig and the caller decides which it acts on, so
/// dropping a bit here would hide a client the RE table does not yet cover.
pub fn parseAliveFlagsBody(body: []const u8) !struct { entity_id: i32, flags: u16 } {
    var r: binary.Reader = .{ .data = body };
    return .{ .entity_id = try r.readI32(), .flags = try r.readU16() };
}

/// NetPackageEntitySpeeds: EntityTargeted entityId + movementState:u8 + speedForward/strafe:f32.
pub fn buildEntitySpeedsBody(buf: []u8, entity_id: i32, movement_state: u8, speed_forward: f32, speed_strafe: f32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeByte(movement_state);
    try w.writeF32(speed_forward);
    try w.writeF32(speed_strafe);
    return w.written();
}

/// Read side of NetPackageEntitySpeeds (RE protocol-packages.md residual table,
/// write IL=17, Process IL=37): `entityId` i32 | `movementState` u8 |
/// `speedForward` f32 | `speedStrafe` f32, the order buildEntitySpeedsBody
/// writes. Both speeds go through readFiniteF32, so a NaN or infinity from the
/// wire is an error instead of a value that poisons every later comparison.
pub fn parseEntitySpeedsBody(body: []const u8) !struct { entity_id: i32, movement_state: u8, speed_forward: f32, speed_strafe: f32 } {
    if (body.len < 13) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    return .{
        .entity_id = try r.readI32(),
        .movement_state = try r.readByte(),
        .speed_forward = try readFiniteF32(&r),
        .speed_strafe = try readFiniteF32(&r),
    };
}

/// Head of PlayerDataFile.WriteNetwork / ECD.write(networkWrite=false) for the
/// SavePlayerData C2S body: `FileVersion` u8 | `entityClass` i32 | `id` i32 |
/// `lifetime` f32 | pos f32 x3 (RE EntityCreationData.write, protocol-packages
/// 5.1).
///
/// Returns the entity id only. The position used to come back too, and both
/// call sites discarded it with "pos unreliable (origin-relative); ignore" -
/// the client writes it relative to its own origin, so it is not a world
/// coordinate the server can use. Handing back three unchecked f32 that nobody
/// consumes is the same shape as the nearEntityId guess removed the same day:
/// a value the server cannot act on should not leave the parser. The pos bytes
/// are still consumed so the version/length validation this function exists for
/// stays exact.
pub fn parsePlayerDataEcdHead(body: []const u8) !struct { entity_id: i32 } {
    if (body.len < 1 + 4 + 4 + 4 + 12) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const ver = try r.readByte();
    if (ver != 35 and ver != 36) return error.EndOfStream;
    _ = try r.readI32(); // entityClass
    const entity_id = try r.readI32();
    _ = try r.readF32(); // lifetime
    _ = try r.readF32(); // pos.x, origin-relative
    _ = try r.readF32(); // pos.y
    _ = try r.readF32(); // pos.z
    return .{ .entity_id = entity_id };
}
