//! C2S spawn arms: quest entity spawn, request-to-spawn-entity.
//!
//! Split out of c2s/misc.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const wire_binary = @import("../../wire/binary.zig");
const packages = @import("../../wire/packages.zig");
const stock_entity = @import("../../wire/stock_entity.zig");

/// How far from the requesting player a client-requested spawn may land, and how
/// far above or below it. Stock trusts the authored ECD; zdtd bounds it (rule 20)
/// rather than spawning at an arbitrary point in the world.
const request_spawn_range: f32 = 8.0;
const request_spawn_vertical_range: f32 = 8.0;

/// Resolve an entityclasses row into the sim's `EntityClass` shape.
fn entityClassFromDef(def: anytype) ecs_world_mod.EntityClass {
    return .{
        .name = def.name,
        .max_hp = def.max_hp,
        .kind = switch (def.kind) {
            .animal => .animal,
            else => .zombie,
        },
        .hash = def.hash,
        .loot_list = def.loot_list,
        .drop_prob = def.loot_drop_prob,
        .stomps_spikes = def.stomps_spikes,
    };
}

const ecs_world_mod = @import("../../ecs/world.zig");

/// True when `name` is a spawn package and was handled.
pub fn handleSpawn(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageQuestEntitySpawn")) {
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        // Stock body (RE protocol-packages.md 6.17; read IL at
        // il/netpackages-v3.2.0/NetPackageQuestEntitySpawn_il.txt IL_0002-001F):
        // entityType i32 | gamestageGroup string | entityIDQuestHolder i32.
        // The third field is the quest holder's entity id, not a count. It was
        // read as one, so a single packet summoned that many zombies with the
        // client choosing the number. Stock ProcessPackage (IL=37) calls
        // SpawnQuestEntity exactly once, so there is no per-request cap to
        // apply: the count is not client-chosen at all.
        var r: wire_binary.Reader = .{ .data = body };
        _ = r.readI32() catch return true; // entityType (-1 = resolve from group)
        var gname: [64]u8 = undefined;
        _ = r.readString(&gname) catch return true; // gamestageGroup
        const holder_id = r.readI32() catch return true;
        // The holder is the player whose quest summons. A packet naming another
        // player would spawn at the sender on someone else's quest, so require
        // the sender's own entity.
        if (self.rejectIfNotSender(c, peer.local_id, holder_id, .none)) return true;
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        if (!self.sim.mask[ps].journal or !self.sim.journal[ps].anyActive()) {
            self.harness.counters.inc(.c2s_rejects);
            return true;
        }
        const t = self.sim.transform[ps];
        const zdef = self.entities.defaultZombie();
        // Sandbox 43 `MaxEnemyTier` applies on every stock create, quest
        // summons included: a class above the cap degrades or the spawn is
        // skipped.
        const zclass = self.clampSpawnClass(zdef) orelse return true;
        // A35: spawn the full resolved class so the quest summon carries stats.
        _ = self.sim.spawnZombieDef(t.x + 6, t.y, t.z, zdef.max_hp, zclass);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageRequestToSpawnEntity")) {
        // V3.2.0 client-requested spawn (protocol.md section 5.0): the client
        // places a held entity (`ItemClassHeldEntity`), a falling tree or a
        // dropped item this way and waits for `NetPackageConfirmSpawnEntity` to
        // consume its pending `EntityPlayerLocal.SpawnRequest`; the entity must
        // also reach it, because the ack resolves the created id in its world.
        // The ECD is client-authored, so the class has to resolve in the
        // entityclass catalog, the transform has to sit near the requester and
        // the per-tick spawn token has to be free.
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        const req = stock_entity.parseSpawnRequest(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        const t = self.sim.transform[ps];
        const dx = req.x - t.x;
        const dz = req.z - t.z;
        const dy = req.y - t.y;
        if (dx * dx + dz * dz > request_spawn_range * request_spawn_range or @abs(dy) > request_spawn_vertical_range) {
            self.harness.counters.inc(.c2s_rejects);
            return true;
        }
        const def = self.entities.byHash(req.entity_class) orelse return true;
        // Only the kinds zdtd can own server-side are spawned here; a dropped
        // item, falling block/tree or player class never reaches this point (the
        // reader refuses those middles), so the remaining kinds are the living
        // ones.
        const spawned: ?ecs_world_mod.NetId = switch (def.kind) {
            .zombie => self.sim.spawnZombieDef(req.x, req.y, req.z, def.max_hp, entityClassFromDef(def)),
            .animal => self.sim.spawnAnimalDef(req.x, req.y, req.z, entityClassFromDef(def)),
            else => null,
        };
        const nid = spawned orelse return true;
        const created: i32 = self.sim.network_id[self.sim.slotOfNetId(nid) orelse return true].id;
        // The ack is what clears the client's pending request; it resolves the
        // created entity id in the client's own world, which the spawn package
        // (sent by the interest pass) provides.
        if (req.has_request_key) {
            var ack: [32]u8 = undefined;
            const ab = packages.buildConfirmSpawnEntityBody(&ack, created, &req.request_key) catch {
                self.harness.counters.inc(.encode_errors);
                return true;
            };
            try self.sendGame(peer, "NetPackageConfirmSpawnEntity", ab);
        }
        return true;
    }
    return false;
}
