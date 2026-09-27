//! C2S vehicle + attach arms: data sync, spawn control, entity attach.
//!
//! Split out of c2s/misc.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const systems = @import("../../ecs/systems.zig");
const protocol = @import("../../protocol.zig");
const assets_vehicles = @import("../../assets/vehicles.zig");

/// True when `name` is a vehicle/attach package and was handled.
pub fn handleVehicle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageVehicleDataSync")) {
        // Real stock body (asm.il:844254); the opaque ReadSyncData payload
        // stays undecoded and is only relayed, as the stock server does.
        const s = packages.parseVehicleDataSync(body) catch return true;
        if (s.sender_id != c.entity_id) return true;
        const vi = self.sim.slotOfNetId(s.vehicle_id) orelse return true;
        if (!self.sim.mask[vi].vehicle) return true;
        if (self.sim.vehicle[vi].driverNetId() != c.entity_id) return true;
        try self.broadcastExcept("NetPackageVehicleDataSync", body, c.slot);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageVehicleSpawn") and body.len == packages.vehicle_control_len) {
        const vc = packages.parseVehicleControl(body) catch return true;
        const vi = self.sim.slotOfNetId(vc.entity_id) orelse return true;
        if (!self.sim.mask[vi].vehicle) return true;
        switch (vc.op) {
            0 => try self.seatRider(c.entity_id, vi, systems.seat_any),
            1 => try self.unseatRider(c.entity_id),
            2 => {
                // Passengers do not steer: only seat 0 drives (asm.il:542176).
                if (self.sim.vehicle[vi].driverNetId() != c.entity_id) return true;
                systems.vehicleControl(&self.sim, vi, vc.throttle, vc.steer, 1.0 / @as(f32, @floatFromInt(protocol.ticks_per_second)));
            },
            else => {},
        }
        return true;
    }
    // A stock NetPackageVehicleSpawn body is a placement request: the client's
    // ItemActionSpawnVehicle sends it when a placeable vehicle item is used
    // (shop write IL=24: entityType i32 | pos | rot | ItemValue | placer).
    // zdtd serves it authoritatively: the sender must own the placer id, the
    // claimed entity class must be a stock vehicle whose placeable item is the
    // one claimed, and the spot must be in reach. The item itself is consumed
    // by the client and lands through the inventory path, as every other
    // client-side consume does.
    if (std.mem.eql(u8, name, "NetPackageVehicleSpawn") and body.len >= packages.vehicle_spawn_min_len) {
        const req = packages.parseVehicleSpawn(body) catch return true;
        // Stock's ProcessPackage gate: ValidEntityIdForSender(placer).
        if (req.entity_that_placed != c.entity_id) return true;
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        const pt = self.sim.transform[ps];
        if (self.rejectIfBeyondEditRange(
            c,
            peer.local_id,
            c.entity_id,
            .block,
            pt.x,
            pt.y,
            pt.z,
            req.x,
            req.y,
            req.z,
        )) return true;
        // The claimed class must be a vehicle the claimed item places: resolve
        // the class hash through entityclasses.xml, its vehicles.xml def, and
        // the placeable item name that def implies, then require the packet's
        // ItemValue to be that item. A forged body cannot spawn a zombie or an
        // unowned vehicle by naming a class the item does not place.
        const edef = self.entities.byHash(req.entity_type) orelse return true;
        if (edef.kind != .vehicle) return true;
        const vd = self.vehicles.byName(edef.name) orelse return true;
        const want_item = assets_vehicles.placeableItemName(vd.kind) orelse return true;
        const item_ecs = Game.reverseItemType(self, req.item.type_id);
        const idef = self.items.byId(item_ecs) orelse return true;
        if (!std.mem.eql(u8, idef.name, want_item)) return true;
        if (!std.math.isFinite(req.x) or !std.math.isFinite(req.y) or !std.math.isFinite(req.z)) return true;
        const nid = self.sim.spawnVehicleEx(
            vd.kind,
            req.x,
            req.y,
            req.z,
            vd.max_hp,
            vd.velocity_max,
            vd.seat_count,
        ) orelse return true;
        if (self.sim.slotOfNetId(nid)) |vs| {
            // Owner: stock sets EntityVehicle.SetOwner from the placer's
            // PlatformUserIdentifier, which is what the map waypoint list
            // filters on (VehicleManager.UpdateVehicleWaypointsForPlayer).
            self.sim.vehicle[vs].owner_slot = @intCast(c.slot);
            // The class the ECD announces: the one the body claimed, already
            // resolved to a vehicle through entityclasses.xml above. Without
            // it the announce falls back to the zombie class, so replicate
            // only announces vehicles whose class resolves.
            self.sim.mask[vs].class_id = true;
            self.sim.class_id[vs].hash = req.entity_type;
            self.sim.transform[vs].yaw = req.ry;
            // Force the next interest pass to send the ECD, so peers see the
            // vehicle entity and not just its transform stream.
            for (&self.clients) |*cl| {
                if (!cl.joined) continue;
                cl.known_entities.unset(vs);
            }
        }
        // The placer sees the parked vehicle on their map right away:
        // VehicleManager.UpdateVehicleWaypointsForPlayer runs when the vehicle
        // list changes, not only at join.
        if (c.peer) |p| try self.sendVehicleWaypoints(p, c.slot);
        // Stock sends the new server-side counts from the spawn package's own
        // ProcessPackage (IL_00E5), which is what the client's limit UI reads.
        self.broadcastVehicleCount();
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntityAttach")) {
        const a = packages.parseEntityAttach(body) catch return true;
        if (a.rider_id != c.entity_id) return true;
        // Types 0/2 are the server branch of NetPackageEntityAttach::
        // ProcessPackage (asm.il:844722); the server answers with 1/3 and
        // never echoes the client's own body, which would put every peer on
        // the server branch.
        if (packages.attachTypeIsDetach(a.attach_type)) {
            // Detach carries vehicleId = -1 (asm.il:406816): resolve the hull
            // from server state, never from the packet.
            try self.unseatRider(c.entity_id);
        } else {
            const vi = self.sim.slotOfNetId(a.vehicle_id) orelse return true;
            if (!self.sim.mask[vi].vehicle) return true;
            try self.seatRider(c.entity_id, vi, a.slot);
        }
        return true;
    }
    return false;
}
