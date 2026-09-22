//! C2S spawn arms: quest entity spawn, request-to-spawn-entity.
//!
//! Split out of c2s/misc.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const wire_binary = @import("../../wire/binary.zig");

/// True when `name` is a spawn package and was handled.
pub fn handleSpawn(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    _ = peer;
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
        if (holder_id != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        if (!self.sim.mask[ps].journal or !self.sim.journal[ps].anyActive()) {
            self.harness.counters.inc(.c2s_rejects);
            return true;
        }
        const t = self.sim.transform[ps];
        const zdef = self.entities.defaultZombie();
        const zclass = self.entityClassOf(zdef);
        // A35: spawn the full resolved class so the quest summon carries stats.
        _ = self.sim.spawnZombieDef(t.x + 6, t.y, t.z, zdef.max_hp, zclass);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageRequestToSpawnEntity")) {
        // The generic ECD request does not prove item ownership or a legal
        // spawn class. Typed drop/throw paths must validate and consume the
        // corresponding server-side inventory first.
        return true;
    }
    return false;
}
