//! C2S join arms: enter game, auth, world folder, spawned-in-world.
//!
//! Split out of c2s/join.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const clock = @import("../../util/clock.zig");
const game_player = @import("../game/player.zig");
const log = @import("../../util/log.zig");

/// True when `name` is an enter-game package and was handled.
pub fn handleEnter(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    const sp = self.world.primarySpawn();
    if (std.mem.eql(u8, name, "NetPackageRequestToEnterGame")) {
        log.infoTagged("RequestToEnterGame entity={d} slot={d} local_id={d}\n", .{ c.entity_id, c.slot, peer.local_id });
        // One deadline covers the whole must-deliver enter bundle. Clear it at
        // the request boundary so later critical exchanges (sign data,
        // PlayerId) receive their own bounded budget.
        const owns_bundle_budget = peer.armCriticalBudget(game_mod.critical_retry_budget_ns);
        defer peer.releaseCriticalBudget(owns_bundle_budget);
        if (c.entity_id <= 0) {
            const surf_e = self.spawnSurface(sp.x, sp.z);
            c.entity_id = game_player.spawnOrFail(
                self,
                c,
                @floatFromInt(surf_e.x),
                @floatFromInt(surf_e.y),
                @floatFromInt(surf_e.z),
                "RequestToEnterGame",
            ) orelse {
                self.dropClientSlot(c.slot, "spawn-full");
                return true;
            };
            c.joined = true;
            self.tryRestorePlayer(c);
        }
        // Before the configs: the client only runs Block::AssignIds after the
        // ConfigFile package (WorldStaticData LoadBlocks IL_0058, asm.il
        // 2014542), and stock sends the mapping at this same point.
        try self.sendBlockIdMapping(peer);
        // Stock order: NetPackageLocalization (IL_0222) before
        // SendXmlsToClient (IL_0242), so the client has the modlet names before
        // it renders anything from the catalogs.
        try self.sendLocalization(peer);
        try self.sendLocalConfigFiles(peer);
        const wi = try packages.buildWorldInfoBody(self.body_buf[0..256], self.world_name, 6144, 6144, sp.x, sp.y, sp.z, 0);
        try self.sendGameCritical(peer, "NetPackageWorldInfo", wi);
        // Stock order: WorldInfo (10) then ChunkClusterInfo (11); the client
        // sets chunkClusterLoaded and only then applies spawn points (12).
        try self.sendChunkClusterInfo(peer);
        try self.sendWorldSpawnPoints(peer);
        // Stock sends World.TraderAreas right after SpawnPoints and before
        // GameStats (GameManager/<RequestToEnterGame>d__195 MoveNext,
        // protocol.md step 12); the client builds the safe zones and the
        // closing-time teleports from it.
        try self.sendWorldAreas(peer);
        const wt = try packages.buildWorldTimeBody(self.body_buf[1024..1040], self.sim.director.clock.worldTimeBits());
        try self.sendGameCritical(peer, "NetPackageWorldTime", wt);
        try self.sendGameStats(peer);
        // NetPackageWeather: only after client WeatherManager.InitPackages (post-enter).
        // Early send → NCSimple "parsed 2 vs expected 117" and disconnect.
        // Fixed-size clients only apply trees from S2C deco (no local random gen),
        // and this is the client's only deco window (see sendDecoAroundSpawn).
        try self.sendDecoAroundSpawn(c, peer, sp.x, sp.z);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageAuthConfirmation")) {
        // Client echoes empty AuthConfirmation; stock AuthFinalizer expects the round-trip.
        // Nothing to apply; acknowledge by no-op so the session stays live.
        log.info("zdtd: AuthConfirmation body={d}\n", .{body.len});
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageWorldFolder")) {
        // Stock ProcessPackage (IL=93) on the server branch calls
        // StartSendingPacketsToClient. zdtd's flat/default worlds ship no
        // world files (WorldInfo hashCount=0), but worldInfoCo still waits on
        // WorldReceivedAndUncompressed after RequestWorld, so answer with one
        // empty last-part that clears the wait (uncompressWorld count=0).
        const part = try packages.buildEmptyWorldFolderTransfer(&self.body_buf);
        try self.sendGameCritical(peer, "NetPackageWorldFolder", part);
        log.info("zdtd: WorldFolder empty transfer local_id={d} body={d}\n", .{ peer.local_id, part.len });
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackagePlayerSpawnedInWorld")) {
        // The client echoes this after it finishes spawning locally (stock
        // GameManager.RequestToSpawn -> SendToServer, direction 0 both ways).
        // Stock's server ProcessPackage (IL=47) validates the claimed entity
        // against the sender (ValidEntityIdForSender), runs
        // PlayerSpawnedInWorld (SetAlive on died-respawns; vehicle/drone
        // waypoints and the spawn mod-event for joins), then rebroadcasts the
        // confirm to every other peer on channel 192 so tracking clients run
        // their spawn handling. Apply the same: speaking for another entity
        // is dropped and counted, and the rebroadcast carries the sender's
        // verified entity id rather than echoing a forged one. The vehicle
        // waypoint leg is covered separately (sendVehicleWaypoints ships them
        // to the owner on join); drones have no zdtd surface yet.
        const rep = packages.parseSpawnedBody(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        if (self.rejectIfNotSender(c, peer.local_id, rep.entity_id, .none)) return true;
        for (&self.clients) |*cl| {
            if (cl.slot == c.slot or !cl.joined) continue;
            const op = cl.peer orelse continue;
            self.sendGame(op, "NetPackagePlayerSpawnedInWorld", body) catch |err| {
                self.harness.counters.inc(.net_send_errors);
                log.err("spawn confirm relay failed slot={d}: {s}\n", .{ cl.slot, @errorName(err) });
            };
        }
        return true;
    }
    return false;
}
