//! C2S turret arms: animation-data relay, turret spawn.
//!
//! Split out of c2s/misc.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const relayBodyExcept = @import("misc_relay.zig").relayBodyExcept;
const binary = @import("../../wire/binary.zig");

/// True when `name` is a turret package and was handled.
pub fn handleTurret(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageEntityAnimationData")) {
        // Stock NetPackageEntityAnimationData (client-originated: the local
        // AvatarController broadcasts the avatar anim params; ProcessPackage
        // IL=64 re-Setups + relays to the other players). The server
        // re-broadcasts the raw body to the entity's tracked players, gated
        // on the sender's own entity id (the anim params describe its own
        // avatar). Same rate gate as the wire tool: an unthrottled spam loop
        // would fan a broadcast out to every other peer for free.
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        const anim = packages.parseAnimationData(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        if (self.rejectIfNotSender(c, peer.local_id, anim.entity_id, .none)) return true;
        // Trim to the parsed body: the parameter list is variable length, so a
        // raw relay would forward whatever a peer appended.
        relayBodyExcept(self, "NetPackageEntityAnimationData", body[0..anim.wire_len], anim.entity_id, "EntityAnimationData");
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageTurretSpawn")) {
        if (body.len < 12) return true;
        // Stock's body is `entityType` i32 | pos Vector3 (3 x f32) | rot
        // Vector3 | ItemValue | `entityThatPlaced` i32 (RE
        // inventories/netpackage-bodies.md, write IL=24). zdtd also accepts a
        // compact 12-byte form of three i32 world coordinates for loadgen and
        // the scenarios. Reading the stock body as that compact form decoded
        // the float bit patterns as coordinates in the billions, which the
        // reach gate then rejected: a real client's turret never got placed.
        const stock = body.len >= 16;
        // The tail after the position is rot Vector3 | ItemValue |
        // entityThatPlaced. Stock applies the rotation to the spawned turret
        // (the client renders it facing where the placer aimed) and stores the
        // source item on the entity; zdtd has no turret item model, so only the
        // yaw is applied. The placer is taken from the sender, which is
        // stricter than the body's own id and matches ValidEntityIdForSender.
        // The head carries the entity class the client wants (stock
        // EntityFactory.CreateEntity(entityType, ...)). Resolved fail-closed
        // against entityclasses.xml: the class is what the ECD announces, and
        // an unresolved one would fall back to the zombie class in replicate.
        const stock_class: ?i32 = if (stock) blk: {
            const et = std.mem.readInt(i32, body[0..4], .little);
            const e = self.entities.byHash(et) orelse break :blk null;
            if (e.kind != .turret) break :blk null;
            break :blk et;
        } else null;
        // Stock branches on the item's tag: a `drone` item goes to
        // DroneManager, a ranged/melee trap to the turret path
        // (RE vehicles-drones-turrets.md 1200-1204). zdtd has no drone
        // subsystem, so a body claiming a resolved NON-turret class is refused
        // outright: without this a junk drone spawned a 15 W auto turret, which
        // is a fabricated entity, not a missing one. An unresolved hash keeps
        // the legacy path, because the client may predate a catalog load.
        if (stock) {
            const et = std.mem.readInt(i32, body[0..4], .little);
            if (self.entities.byHash(et)) |e| {
                if (e.kind != .turret) {
                    self.harness.counters.inc(.c2s_rejects);
                    return true;
                }
            }
        }
        const stock_yaw: f32 = if (stock and body.len >= 28) blk: {
            const ry: f32 = @bitCast(std.mem.readInt(u32, body[20..24], .little));
            if (!std.math.isFinite(ry)) return true;
            break :blk ry;
        } else 0;
        const x, const y, const z = if (stock) blk: {
            const fx: f32 = @bitCast(std.mem.readInt(u32, body[4..8], .little));
            const fy: f32 = @bitCast(std.mem.readInt(u32, body[8..12], .little));
            const fz: f32 = @bitCast(std.mem.readInt(u32, body[12..16], .little));
            if (!std.math.isFinite(fx) or !std.math.isFinite(fy) or !std.math.isFinite(fz)) return true;
            break :blk .{
                std.math.lossyCast(i32, @floor(fx)),
                std.math.lossyCast(i32, @floor(fy)),
                std.math.lossyCast(i32, @floor(fz)),
            };
        } else .{
            std.mem.readInt(i32, body[0..4], .little),
            std.mem.readInt(i32, body[4..8], .little),
            std.mem.readInt(i32, body[8..12], .little),
        };
        // Same rate gate as SetBlock: a spam loop must not plant turrets
        // faster than the bucket refills and drain the entity table.
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        // Client-chosen coordinates: same reach + claim gate as SetBlock, so a
        // spam loop cannot plant turrets map-wide and drain the entity table.
        if (!self.placeAllowed(c, x, y, z)) return true;
        // The deployed turret's magazine rides its item value's Meta
        // (`EntityTurret.get_AmmoCount` = `OriginalItemValue.Meta`, like a gun's
        // magazine; vehicles-drones-turrets.md:1096-1098). The item value sits
        // after `entityType i32 | pos f32x3 | rot f32x3` and is variable length,
        // so a body too short to hold it keeps the block-derived default.
        var magazine: ?u16 = null;
        var deploy_item: ?packages.stock_inv.StockSlot = null;
        if (stock and body.len > 28) {
            var ir: binary.Reader = .{ .data = body[28..] };
            if (packages.stock_inv.readItemValue(&ir)) |iv| {
                // `ItemValue.None` (a zero version byte) carries no item: the
                // default chain stands. A real item's meta is the magazine,
                // and meta 0 is a genuinely empty one.
                if (iv.type_id != 0) {
                    magazine = iv.meta;
                    deploy_item = iv;
                }
            } else |_| {}
        }
        // The item's uses are the turret's health (`EntityTurret.get_Health`
        // IL=12): a fully worn item deploys at 1 hp, and each shot degrades it,
        // which `turretTick` applies.
        var max_use: f32 = 0;
        if (deploy_item) |iv| {
            if (iv.type_id != 0) {
                max_use = @floatFromInt(self.itemMaxUseTimes(@intCast(@as(u32, @intCast(iv.type_id))), @intCast(@min(iv.quality, 255))));
            }
        }
        if (self.sim.spawnTurretEx(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z), .{
            .ammo = magazine,
            .item_type = if (deploy_item) |iv| iv.type_id else 0,
            .item_quality = if (deploy_item) |iv| iv.quality else 0,
            .item_use_times = if (deploy_item) |iv| iv.use_times else 0,
            .item_max_use = max_use,
        })) |tid| {
            // Stock sends the new counts from the turret tracker when a turret
            // is added (`TurretTracker` IL_002D), next to the vehicle count.
            self.broadcastVehicleCount();
            if (self.sim.slotOfNetId(tid)) |ts| {
                // Stock's ProcessPackage sets the turret's rotation from the
                // body before spawning it into the world.
                self.sim.transform[ts].yaw = stock_yaw;
                if (stock_class) |ch| {
                    self.sim.mask[ts].class_id = true;
                    self.sim.class_id[ts].hash = ch;
                }
                self.sim.turret[ts].owner_slot = @intCast(c.slot);
                // The slot dies with the session; the name is what lets a
                // restart hand the turret back to whoever placed it.
                self.sim.turret[ts].setOwnerName(c.name[0..c.name_len]);
                var gi: ?u16 = null;
                var i: usize = 0;
                while (i < self.sim.power.node_n) : (i += 1) {
                    if (self.sim.power.nodes[i].kind == .generator) {
                        gi = self.sim.power.nodes[i].id;
                        break;
                    }
                }
                if (gi) |gid| {
                    _ = self.sim.power.connect(gid, self.sim.turret[ts].power_node);
                    self.sim.power.resolve();
                }
            }
        }
        return true;
    }
    return false;
}
