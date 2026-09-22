//! Vehicle sim: kind speed defaults, drive control, seat attach/detach.
//!
//! Split out of ecs/systems.zig (same code, moved verbatim);
//! re-exported so existing `systems.*` call sites keep working.

const std = @import("std");
const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const max_entities = @import("world.zig").max_entities;
const c = @import("components.zig");
const query = @import("query.zig");

/// Fixed-point damage unit (1.0 hp = 100). Mirrors systems.zig.
const dmg_scale: u32 = 100;

/// Kind defaults when vehicles.xml velocityMax missing (A12: XML first, then this).
/// Stock `velocityMax_turbo` first components (vehicles.xml: bicycle 6,
/// minibike 7, motorcycle 9.8, 4x4 10, gyro 9); the loader reads the same
/// field, so offline and XML mode agree.
pub fn vehicleKindDefaultSpeed(kind: c.VehicleKind) f32 {
    return switch (kind) {
        .bicycle => 6,
        .minibike => 7,
        .motorcycle => 9.8,
        .four_by_four => 10,
        .gyrocopter => 9,
    };
}

pub fn vehicleControl(w: *World, slot: Slot, throttle: f32, steer: f32, dt: f32) void {
    if (!w.alive[slot] or !w.mask[slot].vehicle or !w.mask[slot].transform) return;
    if (w.vehicle[slot].driverNetId() < 0) return;
    var v = &w.vehicle[slot];
    v.throttle = throttle;
    v.steer = steer;
    const max_spd: f32 = if (v.max_speed > 0.1) v.max_speed else vehicleKindDefaultSpeed(v.kind);
    const vr = &w.rules.vehicle;
    // Stronger accel so a short C2S drive pulse still moves (playtest >=0.4 m).
    v.speed += throttle * vr.accel_mps2 * dt;
    v.speed = @min(v.speed, max_spd);
    v.speed = @max(v.speed, -max_spd * vr.reverse_frac);
    // Coast decay only when no throttle input.
    if (@abs(throttle) < 0.05) v.speed *= 1.0 - vr.coast_decay * dt;
    const spd_frac = if (max_spd > 0.01) @abs(v.speed) / max_spd else 0;
    w.transform[slot].yaw += steer * vr.steer_deg_per_s * dt * @max(spd_frac, vr.min_turn_speed_frac);
    const rad = w.transform[slot].yaw * (std.math.pi / 180.0);
    w.transform[slot].x += @sin(rad) * v.speed * dt;
    w.transform[slot].z += @cos(rad) * v.speed * dt;
    if (v.kind != .bicycle) {
        if (v.fuel <= 0) {
            v.speed = 0;
            return;
        }
        v.fuel -= @abs(v.speed) * vr.fuel_per_m * dt;
        v.fuel = @max(v.fuel, 0);
    }
}

/// Apply held throttle/steer every sim tick (stock client may send sparse drive pkgs).
pub fn vehicleTickHeld(w: *World, dt: f32) void {
    for (query.groupSlice(w, .vehicle)) |i| {
        if (!w.alive[i] or !w.mask[i].vehicle) continue;
        if (w.vehicle[i].driverNetId() < 0) continue;
        const v = w.vehicle[i];
        // Re-apply held input; zero throttle still coasts via vehicleControl.
        vehicleControl(w, i, v.throttle, v.steer, dt);
    }
}

/// Wire sentinel for "any free seat": the stock client always mounts with -1
/// (EntityVehicle::EnterVehicle → StartAttachToEntity(this, -1), asm.il:541872).
pub const seat_any: i16 = -1;

/// Seat this rider already holds on this vehicle, mirroring
/// Entity::FindAttachSlot (asm.il:406478).
pub fn vehicleFindSeat(w: *const World, vslot: Slot, player_net: i32) ?u8 {
    if (player_net < 0) return null; // -1 marks a free seat, never a rider
    if (!w.alive[vslot] or !w.mask[vslot].vehicle) return null;
    for (w.vehicle[vslot].seats, 0..) |rider, s| {
        if (rider == player_net) return @intCast(s);
    }
    return null;
}

/// Vehicle slot this rider occupies, whichever vehicle that is.
pub fn vehicleOfRider(w: *const World, player_net: i32) ?Slot {
    if (player_net < 0) return null;
    for (query.groupSlice(w, .vehicle)) |i| {
        if (!w.alive[i] or !w.mask[i].vehicle) continue;
        for (w.vehicle[i].seats) |rider| {
            if (rider == player_net) return i;
        }
    }
    return null;
}

/// Seat a rider, returning the resolved seat index, mirroring
/// Entity::AttachEntityToSelf (asm.il:406554): a negative request takes the
/// first free seat, re-requesting the held seat (or -1 while held) is a no-op,
/// and an out-of-range request fails. Unlike stock, an explicit request for an
/// occupied seat is refused instead of evicting the sitting rider: the request
/// comes off the wire and must not be able to unseat someone else.
pub fn vehicleAttach(w: *World, vslot: Slot, player_net: i32, requested: i16) ?u8 {
    if (player_net < 0) return null;
    if (!w.alive[vslot] or !w.mask[vslot].vehicle) return null;
    const n: i16 = w.vehicle[vslot].usableSeats();
    if (requested >= n) return null;

    const held = vehicleFindSeat(w, vslot, player_net);
    if (held) |h| {
        if (requested < 0 or requested == h) return h;
    } else {
        // Fresh mount: proximity gate, and vacate any other vehicle first so a
        // rider can never occupy two hulls at once.
        const ps = w.slotOfNetId(player_net) orelse return null;
        if (!w.mask[ps].transform or !w.mask[vslot].transform) return null;
        const dx = w.transform[ps].x - w.transform[vslot].x;
        const dz = w.transform[ps].z - w.transform[vslot].z;
        if (dx * dx + dz * dz > w.rules.ai.mount_range_sq) return null;
        _ = vehicleDetach(w, player_net);
    }

    const v = &w.vehicle[vslot];
    const seat: u8 = if (requested >= 0) @intCast(requested) else blk: {
        for (v.seats[0..v.usableSeats()], 0..) |rider, s| {
            if (rider < 0) break :blk @intCast(s);
        }
        return null; // full: FindAttachSlot(null) == -1
    };
    if (v.seats[seat] >= 0) return null;
    if (held) |h| { // seat change on the same vehicle
        v.seats[h] = -1;
        if (h == c.driver_seat) vehicleStop(v);
    }
    v.seats[seat] = player_net;
    return seat;
}

pub const Dismount = struct {
    vehicle_net: i32,
    seat: u8,
};

/// Unseat a rider from whatever vehicle holds it. The stock detach package
/// carries vehicleId = -1 (Entity::SendDetach, asm.il:406816), so the server
/// must resolve the hull from its own occupancy state.
pub fn vehicleDetach(w: *World, player_net: i32) ?Dismount {
    const vslot = vehicleOfRider(w, player_net) orelse return null;
    const seat = vehicleFindSeat(w, vslot, player_net).?;
    const v = &w.vehicle[vslot];
    v.seats[seat] = -1;
    // Only losing the driver stops the hull; passengers leaving change nothing.
    if (seat == c.driver_seat) vehicleStop(v);
    return .{ .vehicle_net = w.network_id[vslot].id, .seat = seat };
}

pub fn vehicleStop(v: *c.Vehicle) void {
    v.speed = 0;
    v.throttle = 0;
    v.steer = 0;
}

pub fn systemVehicles(w: *World, dt: f32) void {
    // Vehicle physics does not change entity membership, so the dense group
    // avoids a full-capacity scan on every tick, especially for parked fleets.
    for (query.groupSlice(w, .vehicle)) |i| {
        if (!w.mask[i].vehicle or !w.mask[i].transform) continue;
        var v = &w.vehicle[i];

        // Vertical physics: gravity accumulator + terrain-top clamp. Runs for
        // every vehicle (parked included). Skipped when no terrain hook is set.
        // rules.vehicle.gravity (RE EntityVehicle::cGravity, asm.il:536018;
        // distinct from World::Gravity 0.08) is the config surface (ADR 0021).
        const t = &w.transform[i];
        if (w.groundY(t.x, t.z)) |gy| {
            if (t.y > gy) {
                v.vy += w.rules.vehicle.gravity * dt;
                t.y += v.vy * dt;
                if (t.y <= gy) { // landed / no-fly
                    t.y = gy;
                    v.vy = 0;
                }
            } else { // no-sink: snap up to surface, kill downward velocity
                t.y = gy;
                v.vy = @max(v.vy, 0);
            }
        }

        // Every occupied seat rides the hull. The client parents the rider to
        // the seat transform itself (EntityVehicle::GetAttachedToInfo,
        // asm.il:542503), so the server only owns the hull-relative position.
        for (&v.seats, 0..) |*rider, s| {
            if (rider.* < 0) continue;
            const pi = w.slotOfNetId(rider.*) orelse {
                // The rider entity is gone (death, despawn): free the seat, or
                // the hull stays occupied and, for seat 0, undriveable forever.
                rider.* = -1;
                if (s == c.driver_seat) vehicleStop(v);
                continue;
            };
            if (!w.mask[pi].transform) continue;
            w.transform[pi].x = w.transform[i].x;
            w.transform[pi].y = w.transform[i].y + 1;
            w.transform[pi].z = w.transform[i].z;
            w.transform[pi].yaw = w.transform[i].yaw;
        }
    }
}

test "vehicle falls under gravity and settles on terrain" {
    var w: World = .{};
    defer w.deinit();
    w.ground_fn = &testGround;
    const id = w.spawnVehicle(.minibike, 0, 100, 0).?;
    const s = w.slotOfNetId(id).?;
    var t: f32 = 0;
    while (t < 20.0) : (t += 0.05) {
        systemVehicles(&w, 0.05);
        try std.testing.expect(w.transform[s].y >= 65); // never sinks past ground
    }
    try std.testing.expectApproxEqAbs(@as(f32, 65), w.transform[s].y, 0.001);
    try std.testing.expectEqual(@as(f32, 0), w.vehicle[s].vy);
}
test "vehicle below ground pops up in one tick, no-sink" {
    var w: World = .{};
    defer w.deinit();
    w.ground_fn = &testGround;
    const id = w.spawnVehicle(.four_by_four, 0, 40, 0).?;
    const s = w.slotOfNetId(id).?;
    systemVehicles(&w, 0.05);
    try std.testing.expectEqual(@as(f32, 65), w.transform[s].y);
    try std.testing.expect(w.vehicle[s].vy >= 0);
}
test "vehicle physics skipped without ground hook (headless invariant)" {
    var w: World = .{};
    defer w.deinit();
    const id = w.spawnVehicle(.bicycle, 0, 100, 0).?;
    const s = w.slotOfNetId(id).?;
    systemVehicles(&w, 0.05);
    try std.testing.expectEqual(@as(f32, 100), w.transform[s].y);
}
test "driver seat tracks clamped vehicle y+1" {
    var w: World = .{};
    defer w.deinit();
    w.ground_fn = &testGround;
    const vid = w.spawnVehicle(.motorcycle, 0, 100, 0).?;
    const vs = w.slotOfNetId(vid).?;
    const pid = w.spawnPlayer(0, 100, 0, 0).?;
    const ps = w.slotOfNetId(pid).?;
    try std.testing.expectEqual(@as(?u8, 0), vehicleAttach(&w, vs, pid, seat_any));
    var t: f32 = 0;
    while (t < 20.0) : (t += 0.05) {
        systemVehicles(&w, 0.05);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 65), w.transform[vs].y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 66), w.transform[ps].y, 0.001);
}
fn testGround(_: ?*anyopaque, _: i32, _: i32) f32 {
    return 65;
}

test "multi-seat: passenger rides the hull and cannot steer" {
    var w: World = .{};
    defer w.deinit();
    w.ground_fn = &testGround;
    const vid = w.spawnVehicleEx(.four_by_four, 0, 70, 0, 300, 14, 4).?;
    const vs = w.slotOfNetId(vid).?;
    const drv = w.spawnPlayer(0, 70, 0, 0).?;
    const pax = w.spawnPlayer(1, 70, 0, 1).?;
    try std.testing.expectEqual(@as(?u8, 0), vehicleAttach(&w, vs, drv, seat_any));
    try std.testing.expectEqual(@as(?u8, 1), vehicleAttach(&w, vs, pax, 1));
    const pax_slot = w.slotOfNetId(pax).?;

    vehicleControl(&w, vs, 1.0, 0.0, 0.05);
    var t: f32 = 0;
    while (t < 1.0) : (t += 0.05) {
        vehicleTickHeld(&w, 0.05);
        systemVehicles(&w, 0.05);
    }
    try std.testing.expect(w.vehicle[vs].speed > 0);
    try std.testing.expectApproxEqAbs(w.transform[vs].z, w.transform[pax_slot].z, 0.001);
    try std.testing.expectApproxEqAbs(w.transform[vs].y + 1, w.transform[pax_slot].y, 0.001);
    try std.testing.expectEqual(drv, w.vehicle[vs].driverNetId());
}

test "multi-seat: a destroyed rider releases its seat on the next tick" {
    var w: World = .{};
    defer w.deinit();
    w.ground_fn = &testGround;
    const vid = w.spawnVehicleEx(.four_by_four, 0, 70, 0, 300, 14, 4).?;
    const vs = w.slotOfNetId(vid).?;
    const drv = w.spawnPlayer(0, 70, 0, 0).?;
    const pax = w.spawnPlayer(1, 70, 0, 1).?;
    _ = vehicleAttach(&w, vs, drv, seat_any).?;
    _ = vehicleAttach(&w, vs, pax, seat_any).?;
    vehicleControl(&w, vs, 1.0, 0.0, 0.5);

    w.destroy(w.slotOfNetId(pax).?);
    systemVehicles(&w, 0.05);
    try std.testing.expectEqual(@as(u8, 3), w.vehicle[vs].freeSeats());
    try std.testing.expect(w.vehicle[vs].speed > 0); // driver kept the hull moving

    w.destroy(w.slotOfNetId(drv).?);
    systemVehicles(&w, 0.05);
    try std.testing.expectEqual(@as(u8, 4), w.vehicle[vs].freeSeats());
    try std.testing.expectEqual(@as(f32, 0), w.vehicle[vs].speed);
}

test "multi-seat: four riders fill a truck, the fifth is refused" {
    var w: World = .{};
    defer w.deinit();
    const vid = w.spawnVehicleEx(.four_by_four, 0, 70, 0, 300, 14, 4).?;
    const vs = w.slotOfNetId(vid).?;
    var riders: [5]i32 = undefined;
    for (&riders, 0..) |*r, i| r.* = w.spawnPlayer(1, 70, 0, @intCast(i)).?;
    for (riders[0..4], 0..) |r, i| {
        try std.testing.expectEqual(@as(?u8, @intCast(i)), vehicleAttach(&w, vs, r, seat_any));
    }
    try std.testing.expectEqual(@as(?u8, null), vehicleAttach(&w, vs, riders[4], seat_any));
    try std.testing.expectEqual(@as(u8, 0), w.vehicle[vs].freeSeats());
}
test "multi-seat: out-of-range seat request is refused" {
    var w: World = .{};
    defer w.deinit();
    const vid = w.spawnVehicleEx(.gyrocopter, 0, 70, 0, 250, 20, 2).?;
    const vs = w.slotOfNetId(vid).?;
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    try std.testing.expectEqual(@as(?u8, null), vehicleAttach(&w, vs, p, 3));
    try std.testing.expectEqual(@as(?u8, null), vehicleAttach(&w, vs, p, 2));
    try std.testing.expectEqual(@as(?u8, 1), vehicleAttach(&w, vs, p, 1));
}
test "multi-seat: re-attaching with -1 keeps the held seat" {
    var w: World = .{};
    defer w.deinit();
    const vid = w.spawnVehicleEx(.four_by_four, 0, 70, 0, 300, 14, 4).?;
    const vs = w.slotOfNetId(vid).?;
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    try std.testing.expectEqual(@as(?u8, 2), vehicleAttach(&w, vs, p, 2));
    try std.testing.expectEqual(@as(?u8, 2), vehicleAttach(&w, vs, p, seat_any));
    try std.testing.expectEqual(@as(?u8, 2), vehicleAttach(&w, vs, p, 2));
    try std.testing.expectEqual(@as(u8, 3), w.vehicle[vs].freeSeats());
}
test "multi-seat: an occupied seat is never stolen from its rider" {
    var w: World = .{};
    defer w.deinit();
    const vid = w.spawnVehicleEx(.four_by_four, 0, 70, 0, 300, 14, 4).?;
    const vs = w.slotOfNetId(vid).?;
    const a = w.spawnPlayer(0, 70, 0, 0).?;
    const b = w.spawnPlayer(1, 70, 0, 1).?;
    try std.testing.expectEqual(@as(?u8, 0), vehicleAttach(&w, vs, a, 0));
    try std.testing.expectEqual(@as(?u8, null), vehicleAttach(&w, vs, b, 0));
    try std.testing.expectEqual(a, w.vehicle[vs].driverNetId());
}
test "multi-seat: only the driver leaving stops the hull" {
    var w: World = .{};
    defer w.deinit();
    const vid = w.spawnVehicleEx(.four_by_four, 0, 70, 0, 300, 14, 4).?;
    const vs = w.slotOfNetId(vid).?;
    const drv = w.spawnPlayer(0, 70, 0, 0).?;
    const pax = w.spawnPlayer(1, 70, 0, 1).?;
    _ = vehicleAttach(&w, vs, drv, seat_any).?;
    _ = vehicleAttach(&w, vs, pax, 2).?;
    vehicleControl(&w, vs, 1.0, 0.0, 0.5);
    try std.testing.expect(w.vehicle[vs].speed > 0);

    const pax_out = vehicleDetach(&w, pax).?;
    try std.testing.expectEqual(vid, pax_out.vehicle_net);
    try std.testing.expectEqual(@as(u8, 2), pax_out.seat);
    try std.testing.expect(w.vehicle[vs].speed > 0);

    const drv_out = vehicleDetach(&w, drv).?;
    try std.testing.expectEqual(@as(u8, 0), drv_out.seat);
    try std.testing.expectEqual(@as(f32, 0), w.vehicle[vs].speed);
    try std.testing.expectEqual(@as(u8, 4), w.vehicle[vs].freeSeats());
}

test "multi-seat: detaching an unseated player reports nothing" {
    var w: World = .{};
    defer w.deinit();
    const vid = w.spawnVehicleEx(.minibike, 0, 70, 0, 200, 12, 1).?;
    const vs = w.slotOfNetId(vid).?;
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    try std.testing.expectEqual(@as(?Dismount, null), vehicleDetach(&w, p));
    // A free seat is -1; the sentinel must never resolve to a rider.
    try std.testing.expectEqual(@as(?Dismount, null), vehicleDetach(&w, -1));
    try std.testing.expectEqual(@as(?u8, null), vehicleFindSeat(&w, vs, -1));
}
test "multi-seat: mounting a second vehicle vacates the first" {
    var w: World = .{};
    defer w.deinit();
    const a_id = w.spawnVehicleEx(.four_by_four, 0, 70, 0, 300, 14, 4).?;
    const b_id = w.spawnVehicleEx(.four_by_four, 2, 70, 0, 300, 14, 4).?;
    const a_slot = w.slotOfNetId(a_id).?;
    const b_slot = w.slotOfNetId(b_id).?;
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    try std.testing.expectEqual(@as(?u8, 1), vehicleAttach(&w, a_slot, p, 1));
    try std.testing.expectEqual(@as(?u8, 0), vehicleAttach(&w, b_slot, p, seat_any));
    try std.testing.expectEqual(@as(u8, 4), w.vehicle[a_slot].freeSeats());
    try std.testing.expectEqual(b_slot, vehicleOfRider(&w, p).?);
}
test "multi-seat: spawn clamps a nonsense seat count into range" {
    var w: World = .{};
    defer w.deinit();
    const zero = w.spawnVehicleEx(.bicycle, 0, 70, 0, 200, 6, 0).?;
    const huge = w.spawnVehicleEx(.bicycle, 4, 70, 0, 200, 6, 255).?;
    try std.testing.expectEqual(@as(u8, 1), w.vehicle[w.slotOfNetId(zero).?].seat_count);
    try std.testing.expectEqual(@as(u8, c.max_seats), w.vehicle[w.slotOfNetId(huge).?].seat_count);
}
test "multi-seat: mounting out of reach is refused" {
    var w: World = .{};
    defer w.deinit();
    const vid = w.spawnVehicleEx(.four_by_four, 0, 70, 0, 300, 14, 4).?;
    const vs = w.slotOfNetId(vid).?;
    const p = w.spawnPlayer(40, 70, 0, 0).?;
    try std.testing.expectEqual(@as(?u8, null), vehicleAttach(&w, vs, p, seat_any));
    try std.testing.expectEqual(@as(?u8, null), vehicleAttach(&w, vs, p, 2));
}
