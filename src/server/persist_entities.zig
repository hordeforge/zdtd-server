//! Entity persistence: entities.zen save/restore (ZEN2; ZENT loads).
//!
//! Split out of server/persist.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("game.zig");
const Game = game_mod.Game;
const wire_binary = @import("../wire/binary.zig");
const ecs = @import("../ecs/root.zig");
const io_fs = @import("../util/io_fs.zig");

/// Bytes an `entities.zen` basket record occupies: the type byte, the slot
/// count, then one current-stride slot per basket slot. Same shape as the
/// player record (`InvSlot.writePersist`), so a basket cannot silently drop
/// stats/flags the way the old v12-only encoder did.
const basket_record_max: usize =
    2 + ecs.components.max_basket_slots * ecs.components.inv_slot_persist_stride;

/// Record type for a vehicle's basket, written directly after the vehicle it
/// belongs to. A new record type rather than a magic bump: a world saved
/// before baskets persisted still loads, it just has no type-4 records.
const zen_rec_basket: u8 = 4;

/// Record type for the owner name of the entity written just before it.
/// Same reason as the basket record: appending to the turret record would
/// have shifted a format older worlds still hold.
const zen_rec_owner: u8 = 5;

/// Bytes an owner record occupies: type byte, length byte, then the name.
const owner_record_max: usize = 2 + ecs.components.max_owner_name;

/// Record type for the player-set state of one power node, keyed by world
/// position. The grid itself is rebuilt from the block plane on chunk load
/// (`scanChunkPower`), which recovers the layout but resets everything the
/// player configured: a generator comes back with a full tank, a trigger with
/// default delay and duration, a motion sensor targeting nobody. A switch
/// latch is not here because it already rides the block meta.
const zen_rec_power: u8 = 6;

/// Bytes a power-node record occupies: type byte, three i32 coordinates,
/// fuel f32, delay u8, duration u8, target i32.
const power_record_bytes: usize = 1 + 12 + 4 + 1 + 1 + 4;

/// Record type for a loot bag on the ground. Stock protects dropped backpacks
/// as a persisted category (RE save-region.md ProtectedPositionCache), and a
/// death bag holds a whole player inventory, so losing it to a restart is the
/// largest single loss in this family. Bags never expire in zdtd, so without
/// this every one of them died at shutdown.
const zen_rec_bag: u8 = 7;

/// Marks the preceding bag record as an air-drop supply crate. Its `supply_drop`
/// nav marker is a server push (RE map-objects.md:306) re-registered for each
/// joining player, so without this a crate restored from disk sat on the map
/// full of loot with nothing pointing at it. A separate record rather than a
/// field on the bag: old saves stay readable, exactly as `zen_rec_owner` tags
/// the turret record before it.
const zen_rec_supply_crate: u8 = 8;

/// Marks the preceding bag record as a player death backpack. Stock spawns the
/// "Backpack" entity class (EntityBackpack) for the death drop and the generic
/// "DroppedLootContainer" for a block spill; a restart that restored a backpack
/// as a ground bag changed the wire class. One tag follows the bag, like
/// `zen_rec_supply_crate` (a bag is never both).
const zen_rec_backpack: u8 = 9;

/// Bytes a bag record occupies at most: type byte, three f32 coordinates,
/// slot count, a current-stride slot per filled slot, and the one-byte tag
/// (supply-crate or backpack) that may follow it. A bag carries at most one.
const bag_record_max: usize =
    1 + 12 + 1 + ecs.components.max_inv_slots * ecs.components.inv_slot_persist_stride + 1;

/// Write one inventory slot in the shared persist shape. Shared so a second
/// store persisting InvSlots cannot drift into its own narrower encoding.
fn writeSaveSlot(w: *wire_binary.Writer, s: ecs.components.InvSlot) !void {
    var tmp: [ecs.components.inv_slot_persist_stride]u8 = undefined;
    s.writePersist(&tmp);
    try w.writeBytes(&tmp);
}

/// Read one inventory slot. `full` selects the current stride (ZEN2); false
/// keeps the legacy ZENT 21-byte v12 shape so older entity files still load.
fn readSaveSlot(r: *wire_binary.Reader, full: bool) !ecs.components.InvSlot {
    const stride: usize = if (full) ecs.components.inv_slot_persist_stride else 21;
    var tmp: [ecs.components.inv_slot_persist_stride]u8 = undefined;
    var i: usize = 0;
    while (i < stride) : (i += 1) tmp[i] = try r.readByte();
    return ecs.components.InvSlot.readPersist(tmp[0..stride]);
}

pub fn saveEntities(self: *Game) !void {
    var path: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/entities.zen", .{self.world.world_dir});
    // Vehicle/turret records (32 B each), one optional basket record per
    // vehicle and one optional owner record per turret, the power-wire
    // section (24 B per saved edge, 512 max), and at most one node-state
    // record per power node. Heap, not stack: the shared InvSlot stride
    // makes the worst-case bag budget multi-MB.
    const cap = ecs.max_entities * (32 + basket_record_max + owner_record_max + bag_record_max) +
        ecs.electric.max_wires * 2 * 24 +
        ecs.electric.max_nodes * power_record_bytes + 16;
    const buf = try self.allocator.alloc(u8, cap);
    defer self.allocator.free(buf);
    var w = wire_binary.Writer{ .buf = buf };
    // Overflow must propagate (callers log persistence errors): a silent
    // abort here would drop the vehicle/turret save without any signal.
    try w.writeBytes("ZEN2");
    try w.writeU16(0); // count patched below
    var count: u16 = 0;
    var i: usize = 0;
    while (i < ecs.max_entities) : (i += 1) {
        if (!self.sim.alive[i] or !self.sim.mask[i].transform) continue;
        if (self.sim.kind[i] == .vehicle) {
            const v = self.sim.vehicle[i];
            try w.writeByte(1);
            try w.writeByte(@intFromEnum(v.kind));
            try w.writeF32(self.sim.transform[i].x);
            try w.writeF32(self.sim.transform[i].y);
            try w.writeF32(self.sim.transform[i].z);
            try w.writeF32(self.sim.transform[i].yaw);
            try w.writeF32(v.fuel);
            try w.writeByte(v.seat_count);
            try w.writeF32(v.max_speed);
            count += 1;
            // The basket is server-held storage: the C2S bag write reach-gates
            // it and clamps its stacks like any other container, so dropping
            // it on restart destroys items the server accepted.
            if (v.basket_n > 0) {
                try w.writeByte(zen_rec_basket);
                try w.writeByte(v.basket_n);
                for (v.basket[0..v.basket_n]) |s| try writeSaveSlot(&w, s);
                count += 1;
            }
        } else if (self.sim.kind[i] == .turret) {
            const t = self.sim.turret[i];
            try w.writeByte(2);
            try w.writeF32(self.sim.transform[i].x);
            try w.writeF32(self.sim.transform[i].y);
            try w.writeF32(self.sim.transform[i].z);
            try w.writeF32(t.range);
            try w.writeF32(t.damage);
            try w.writeU16(t.ammo);
            count += 1;
            // Trap kills pay the owner XP, quest progress and a kill count,
            // so an owner lost on restart silently moves that reward to
            // nobody. The client slot is per-session; the name is what can be
            // saved, and the login path re-maps the slot from it.
            if (t.owner_name_len > 0) {
                try w.writeByte(zen_rec_owner);
                try w.writeByte(t.owner_name_len);
                try w.writeBytes(t.owner_name[0..t.owner_name_len]);
                count += 1;
            }
        } else if (self.sim.kind[i] == .loot_bag and self.sim.mask[i].inventory) {
            // A death bag holds a whole player inventory and never expires,
            // so a restart used to be the one thing that could destroy it.
            const inv = &self.sim.inventory[i];
            var filled: u8 = 0;
            for (inv.slots) |sl| {
                if (sl.item_id != 0 and sl.count > 0) filled += 1;
            }
            if (filled == 0) continue;
            try w.writeByte(zen_rec_bag);
            try w.writeF32(self.sim.transform[i].x);
            try w.writeF32(self.sim.transform[i].y);
            try w.writeF32(self.sim.transform[i].z);
            try w.writeByte(filled);
            for (inv.slots) |sl| {
                if (sl.item_id == 0 or sl.count == 0) continue;
                try writeSaveSlot(&w, sl);
            }
            count += 1;
            if (self.sim.loot_bag[i].supply_crate) {
                try w.writeByte(zen_rec_supply_crate);
                count += 1;
            } else if (self.sim.loot_bag[i].backpack) {
                try w.writeByte(zen_rec_backpack);
                count += 1;
            }
        }
    }
    // Power wire edges by endpoint position (node ids are per-session).
    // Both the live wire list and the pending-reconnect set are written: they
    // are disjoint, not duplicates. A pending edge is one loaded from a
    // previous save whose endpoints have not come back yet (the blocks sit in
    // chunks nobody has visited this session), and `reconnectPending` only
    // promotes it once both are present. Writing the live list alone dropped
    // every such edge on each save, so a base in unvisited chunks lost its
    // wiring after one restart.
    if (self.sim.power.wire_n > 0 or self.sim.power.pending_wire_n > 0) {
        // Live plus pending, each capped at max_wires: 24 bytes per edge.
        var edge_buf: [ecs.electric.max_wires * 2 * 24]u8 = undefined;
        var ew = wire_binary.Writer{ .buf = &edge_buf };
        var edges: u16 = 0;
        var wi: usize = 0;
        while (wi < self.sim.power.wire_n) : (wi += 1) {
            const wire = self.sim.power.wires[wi];
            const na = self.sim.power.indexOfId(wire.a) orelse continue;
            const nb = self.sim.power.indexOfId(wire.b) orelse continue;
            const pa = self.sim.power.nodes[na];
            const pb = self.sim.power.nodes[nb];
            try ew.writeI32(pa.x);
            try ew.writeI32(pa.y);
            try ew.writeI32(pa.z);
            try ew.writeI32(pb.x);
            try ew.writeI32(pb.y);
            try ew.writeI32(pb.z);
            edges += 1;
        }
        // Carry the not-yet-reconnected edges through untouched, in the same
        // endpoint-position form the loader reads back.
        var pi: usize = 0;
        while (pi < self.sim.power.pending_wire_n) : (pi += 1) {
            const pw = self.sim.power.pending_wires[pi];
            try ew.writeI32(pw.ax);
            try ew.writeI32(pw.ay);
            try ew.writeI32(pw.az);
            try ew.writeI32(pw.bx);
            try ew.writeI32(pw.by);
            try ew.writeI32(pw.bz);
            edges += 1;
        }
        if (edges > 0) {
            try w.writeByte(3);
            try w.writeU16(edges);
            try w.writeBytes(ew.written());
            count += 1;
        }
    }
    // Player-set node state, keyed by position. Only nodes that differ from
    // what a fresh scan would produce are written: a world of untouched
    // default nodes should not grow the file, and a node whose block is gone
    // by the next load simply finds no match.
    var ni: usize = 0;
    while (ni < self.sim.power.node_n) : (ni += 1) {
        const n = self.sim.power.nodes[ni];
        const fuel_default = n.capacity;
        const configured = n.fuel_or_energy != fuel_default or
            n.delay_idx != 0 or n.duration_idx != 1 or n.target_type != 0;
        if (!configured) continue;
        try w.writeByte(zen_rec_power);
        try w.writeI32(n.x);
        try w.writeI32(n.y);
        try w.writeI32(n.z);
        try w.writeF32(n.fuel_or_energy);
        try w.writeByte(n.delay_idx);
        try w.writeByte(n.duration_idx);
        try w.writeI32(n.target_type);
        count += 1;
    }
    const written = w.written();
    std.mem.writeInt(u16, written[4..6], count, .little);
    try io_fs.writeFile(p, written);
}

/// Restore vehicles/turrets from entities.zen. A missing file is a fresh
/// world (OpenFailed); a corrupt record fails the load loudly. Turrets
/// whose block was removed no longer resolve a power node and are skipped.
pub fn loadEntities(self: *Game) !void {
    var path: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/entities.zen", .{self.world.world_dir});
    const data = io_fs.readFileAll(self.allocator, p) catch |err| switch (err) {
        error.FileNotFound => return error.OpenFailed,
        else => return error.ReadFailed,
    };
    defer self.allocator.free(data);
    if (data.len < 6) return error.BadMagic;
    const full_slots = std.mem.eql(u8, data[0..4], "ZEN2");
    if (!full_slots and !std.mem.eql(u8, data[0..4], "ZENT")) return error.BadMagic;
    const count = std.mem.readInt(u16, data[4..6], .little);
    var r = wire_binary.Reader{ .data = data, .pos = 6 };
    // A basket record applies to the vehicle written just before it, so the
    // loader carries that slot forward. Null when the last record was not a
    // vehicle, or when the vehicle failed to spawn.
    var last_vehicle: ?ecs.Slot = null;
    // Same carry for the owner record, which follows the turret it names.
    var last_turret: ?ecs.Slot = null;
    // Same carry for the supply-crate tag, which follows the bag it marks.
    var last_bag: ?ecs.Slot = null;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const rec_type = r.readByte() catch return error.Truncated;
        if (rec_type != zen_rec_basket) last_vehicle = null;
        if (rec_type != zen_rec_owner) last_turret = null;
        if (rec_type != zen_rec_supply_crate and rec_type != zen_rec_backpack) last_bag = null;
        switch (rec_type) {
            1 => {
                // VehicleKind is an exhaustive enum(u8), so @enumFromInt panics
                // on an out-of-range byte: range-check the raw value first or a
                // corrupt entities.zen takes the server down on load. Same
                // shape as the allies.zal status byte.
                const kind_raw = r.readByte() catch return error.Truncated;
                if (kind_raw >= @typeInfo(ecs.components.VehicleKind).@"enum".fields.len) return error.BadRecord;
                const kind: ecs.components.VehicleKind = @enumFromInt(kind_raw);
                const x = r.readF32() catch return error.Truncated;
                const y = r.readF32() catch return error.Truncated;
                const z = r.readF32() catch return error.Truncated;
                const yaw = r.readF32() catch return error.Truncated;
                const fuel = r.readF32() catch return error.Truncated;
                const seats = r.readByte() catch return error.Truncated;
                const max_speed = r.readF32() catch return error.Truncated;
                // Restore the loader's per-kind max HP (EntityVehicle C#
                // constants: gyro 250, 4x4 300, rest 200) - a saved gyro/4x4
                // must not come back at the flat 200.
                const vhp: f32 = if (self.vehicles.byKind(kind)) |vd| vd.max_hp else 200;
                if (self.sim.spawnVehicleEx(kind, x, y, z, vhp, max_speed, seats)) |nid| {
                    if (self.sim.slotOfNetId(nid)) |vs| {
                        self.sim.vehicle[vs].fuel = fuel;
                        self.sim.transform[vs].yaw = yaw;
                        last_vehicle = vs;
                    }
                }
            },
            2 => {
                const x = r.readF32() catch return error.Truncated;
                const y = r.readF32() catch return error.Truncated;
                const z = r.readF32() catch return error.Truncated;
                const range = r.readF32() catch return error.Truncated;
                const damage = r.readF32() catch return error.Truncated;
                const ammo = r.readU16() catch return error.Truncated;
                if (self.sim.spawnTurret(x, y, z)) |nid| {
                    if (self.sim.slotOfNetId(nid)) |ts| {
                        self.sim.turret[ts].range = range;
                        self.sim.turret[ts].damage = damage;
                        self.sim.turret[ts].ammo = ammo;
                        last_turret = ts;
                    }
                }
            },
            3 => {
                // Power wire edges by endpoint position; the nodes rebuild
                // from the block grid as chunks scan, so edges queue as
                // pending and reconnect when both endpoints exist.
                const edges = r.readU16() catch return error.Truncated;
                var ei: usize = 0;
                while (ei < edges) : (ei += 1) {
                    const wp = ecs.electric.WirePos{
                        .ax = r.readI32() catch return error.Truncated,
                        .ay = r.readI32() catch return error.Truncated,
                        .az = r.readI32() catch return error.Truncated,
                        .bx = r.readI32() catch return error.Truncated,
                        .by = r.readI32() catch return error.Truncated,
                        .bz = r.readI32() catch return error.Truncated,
                    };
                    self.sim.power.addPendingWire(wp);
                }
            },
            zen_rec_basket => {
                const n = r.readByte() catch return error.Truncated;
                if (n > ecs.components.max_basket_slots) return error.BadRecord;
                // Read every slot the record claims even when there is no
                // vehicle to put them in: leaving bytes in the stream would
                // shift every record after this one.
                var bi: usize = 0;
                while (bi < n) : (bi += 1) {
                    const s = readSaveSlot(&r, full_slots) catch return error.Truncated;
                    if (last_vehicle) |vs| self.sim.vehicle[vs].basket[bi] = s;
                }
                if (last_vehicle) |vs| self.sim.vehicle[vs].basket_n = n;
            },
            zen_rec_owner => {
                const n = r.readByte() catch return error.Truncated;
                if (n > ecs.components.max_owner_name) return error.BadRecord;
                // Consume the name whether or not there is a turret to give
                // it to: leftover bytes would shift every later record.
                var nb: [ecs.components.max_owner_name]u8 = undefined;
                var ni: usize = 0;
                while (ni < n) : (ni += 1) nb[ni] = r.readByte() catch return error.Truncated;
                // The slot stays -1 until that player logs in: entity ids and
                // client slots are per-session, so the login re-map is what
                // reconnects the name to a live slot.
                if (last_turret) |ts| self.sim.turret[ts].setOwnerName(nb[0..n]);
            },
            zen_rec_power => {
                // Queued, not applied: this runs before any chunk has been
                // scanned, so the node does not exist yet. Same lazy-chunk
                // problem the pending wires above solve the same way.
                self.sim.power.addPendingState(.{
                    .x = r.readI32() catch return error.Truncated,
                    .y = r.readI32() catch return error.Truncated,
                    .z = r.readI32() catch return error.Truncated,
                    .fuel_or_energy = r.readF32() catch return error.Truncated,
                    .delay_idx = r.readByte() catch return error.Truncated,
                    .duration_idx = r.readByte() catch return error.Truncated,
                    .target_type = r.readI32() catch return error.Truncated,
                });
            },
            zen_rec_bag => {
                const bx = r.readF32() catch return error.Truncated;
                const by = r.readF32() catch return error.Truncated;
                const bz = r.readF32() catch return error.Truncated;
                const n = r.readByte() catch return error.Truncated;
                if (n > ecs.components.max_inv_slots) return error.BadRecord;
                // Read every slot the record claims even if the bag cannot be
                // spawned: leftover bytes would shift every later record.
                var inv: ecs.components.Inventory = .{};
                var bi: usize = 0;
                while (bi < n) : (bi += 1) {
                    const sl = readSaveSlot(&r, full_slots) catch return error.Truncated;
                    if (bi < inv.slots.len) inv.slots[bi] = sl;
                }
                if (n > 0) {
                    if (self.sim.spawnLootBagFrom(bx, by, bz, &inv, 0, n)) |nid| {
                        // The marker on the owner's map is rebuilt from the
                        // player record's own state, not from here: bags carry
                        // no owner, so a restored bag is anyone's to collect,
                        // which is what stock's unowned ground bag is.
                        last_bag = self.sim.slotOfNetId(nid);
                    }
                }
            },
            zen_rec_supply_crate => {
                // Tags the bag written just before it. A tag with no bag ahead
                // of it means the bag failed to spawn (entity cap), so there is
                // nothing to mark and the record is simply consumed.
                if (last_bag) |bs| self.sim.loot_bag[bs].supply_crate = true;
            },
            zen_rec_backpack => {
                // Same carry as the supply-crate tag: a restored death bag must
                // broadcast as the Backpack class, not the spill class.
                if (last_bag) |bs| self.sim.loot_bag[bs].backpack = true;
            },
            else => return error.BadRecord,
        }
    }
}
