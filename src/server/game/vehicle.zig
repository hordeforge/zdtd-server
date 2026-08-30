//! Vehicle seat + positions S2C helpers - extracted verbatim from game.zig.
//! seatRider / unseatRider (NetPackageEntityAttach) and the periodic
//! NetPackageVehiclePositions broadcast.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");
const weather_mod = @import("weather.zig");

/// Seat a rider and tell every client which seat it landed in. The stock
/// server answers a mount request with AttachType 1 carrying the RESOLVED
/// slot (NetPackageEntityAttach::ProcessPackage, asm.il:844722 IL_008d) and
/// the client applies that index verbatim, so this number is the whole of
/// "passengers render in the right seat".
pub fn seatRider(self: *Game, rider_id: i32, vslot: ecs.Slot, requested: i16) !void {
    const seat = systems.vehicleAttach(&self.sim, vslot, rider_id, requested) orelse return;
    const body = packages.buildEntityAttach(
        self.body_buf[0..11],
        .attach_client,
        rider_id,
        self.sim.network_id[vslot].id,
        seat,
    ) catch return;
    try self.broadcast("NetPackageEntityAttach", body);
}

/// Unseat a rider and broadcast AttachType 3 with vehicleId and slot both
/// -1, matching the server branch of Entity::SendDetach (asm.il:406816).
/// Sim seat is freed even if the wire body cannot be built; encode failure
/// is logged so a silent ghost seat on remotes is not invisible.
pub fn unseatRider(self: *Game, rider_id: i32) !void {
    _ = systems.vehicleDetach(&self.sim, rider_id) orelse return;
    const body = packages.buildEntityAttach(
        self.body_buf[0..11],
        .detach_client,
        rider_id,
        -1,
        packages.slot_any,
    ) catch |err| {
        std.debug.print(
            "zdtd: unseat encode failed entity={d}: {s}\n",
            .{ rider_id, @errorName(err) },
        );
        return;
    };
    try self.broadcast("NetPackageEntityAttach", body);
}

/// Replay current occupancy to one peer so a late joiner draws riders in
/// their seats instead of standing on the hull.
pub fn sendSeatedRiders(self: *Game, peer: *ln_peer.Peer) !void {
    for (ecs.groupSlice(&self.sim, .vehicle)) |i| {
        if (!self.sim.mask[i].vehicle or !self.sim.mask[i].network_id) continue;
        const v = self.sim.vehicle[i];
        for (v.seats[0..v.usableSeats()], 0..) |rider, seat| {
            if (rider < 0) continue;
            const body = packages.buildEntityAttach(
                self.body_buf[0..11],
                .attach_client,
                rider,
                self.sim.network_id[i].id,
                @intCast(seat),
            ) catch continue;
            try self.sendGame(peer, "NetPackageEntityAttach", body);
        }
    }
}

pub fn broadcastVehiclePositions(self: *Game) !void {
    // Do not flood pre-enter stock clients (World still null / reader dies on short bodies).
    if (!weather_mod.anyEnteredClient(self)) return;
    // Stock NetPackageVehiclePositions: count:i32, then (entityId:i32 + Vector3:f32*3)*count
    var o: usize = 4;
    var n: i32 = 0;
    for (ecs.groupSlice(&self.sim, .vehicle)) |i| {
        if (!self.sim.mask[i].vehicle) continue;
        if (o + 16 > 1024) break;
        std.mem.writeInt(i32, self.body_buf[o..][0..4], self.sim.network_id[i].id, .little);
        o += 4;
        inline for (.{ self.sim.transform[i].x, self.sim.transform[i].y, self.sim.transform[i].z }) |f| {
            std.mem.writeInt(u32, self.body_buf[o..][0..4], @as(u32, @bitCast(f)), .little);
            o += 4;
        }
        n += 1;
    }
    if (n == 0) return;
    std.mem.writeInt(i32, self.body_buf[0..4], n, .little);
    try self.broadcast("NetPackageVehiclePositions", self.body_buf[0..o]);
}

pub fn broadcastTurretSync(self: *Game) !void {
    // Disabled: stock NetPackageTurretSync is per-entity (id, target, isOn, ItemValue).
    // Our multi-entity blob breaks ItemValue.Read and kills the client reader thread.
    _ = self;
}
