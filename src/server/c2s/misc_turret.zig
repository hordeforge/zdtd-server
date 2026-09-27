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
        if (self.sim.spawnTurret(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z))) |tid| {
            // Stock sends the new counts from the turret tracker when a turret
            // is added (`TurretTracker` IL_002D), next to the vehicle count.
            self.broadcastVehicleCount();
            if (self.sim.slotOfNetId(tid)) |ts| {
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
