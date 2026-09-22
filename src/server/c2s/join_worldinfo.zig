//! C2S join arms: sign data, POI metadata, world-init info, client arrive.
//!
//! Split out of c2s/join.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const prefabs_mod = @import("../../world/prefabs.zig");

/// True when `name` is a world-info package and was handled.
pub fn handleWorldInfo(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    _ = body;
    const sp = self.world.primarySpawn();
    if (std.mem.eql(u8, name, "NetPackageSignDataRequest")) {
        try self.sendSignDataBatches(peer);
        return true;
    }
    // V3.2.0 POI metadata (changelog-3.2.0 §3.2): the client's
    // DynamicPrefabDecorator.RequestWorldPOIMetadataFromServer asks for the
    // minimal per-POI metadata (position/size/rot/tier/trader/tags) it needs
    // for custom-POI LOD and trader-area rendering. Replaces the removed
    // NetPackagePOIAround. Empty C2S body; the response is compressed
    // (channel 1, get_Compress).
    if (std.mem.eql(u8, name, "NetPackagePOIMetadataRequest")) {
        if (self.world.prefabs) |*pf| {
            var records: [packages.max_poi_metadata]packages.PoiMetadata = undefined;
            var n: usize = 0;
            for (pf.items) |d| {
                if (n >= records.len) break;
                const qd = pf.questData(d.name) orelse prefabs_mod.QuestData{};
                records[n] = .{
                    .x = d.x,
                    .y = d.stampY(),
                    .z = d.z,
                    .size_x = d.size_x,
                    .size_y = d.size_y,
                    .size_z = d.size_z,
                    .rotation = d.rot,
                    .tier = qd.tier,
                    .trader_area = qd.is_trader_area,
                    .prefab_name = d.name,
                    .tags = qd.poi_tags,
                    .quest_tags = qd.tags,
                };
                n += 1;
            }
            // Build into a 256 KiB slice, not the old 64 KiB: 512 records of
            // name/tags/quest_tags can exceed 64 KiB on dense maps (Pregen's
            // 3469 prefabs overflowed it deterministically, so the response
            // silently never shipped - 2026-08-29 soak find). body_buf is
            // 512 KiB and idle here (the request arrives after the configs).
            const body_out = try packages.buildPoiMetadataResponse(self.body_buf[0..262144], records[0..n]);
            // Join wait: DynamicPrefabDecorator blocks until the response; a
            // silent WindowFull under the 16 ms stream budget wedges createWorld.
            try self.sendGameCritical(peer, "NetPackagePOIMetadataResponse", body_out);
        }
        return true;
    }
    // worldInfoCo: after createWorld, client sends WorldInitInfoRequest and waits for
    // worldInitInfoReceived (set by ProcessPackage of WorldInitInfo).
    if (std.mem.eql(u8, name, "NetPackageWorldInitInfoRequest")) {
        // Same hang class as DynamicClientArrive: WorldInitInfo after enter can
        // restart createWorld and leave the client on Creating player.
        if (c.entered) return true;
        const wi = try packages.buildWorldInitInfoEmpty(self.body_buf[0..16]);
        try self.sendGameCritical(peer, "NetPackageWorldInitInfo", wi);
        std.debug.print("zdtd: WorldInitInfoRequest -> empty entity={d}\n", .{c.entity_id});
        // Stream from here, not at spawn. The client needs collision meshes
        // for the spawn chunk and its 8 neighbours before
        // World.IsPositionAvailable succeeds; until then updateRespawn parks
        // in ClampingToValidWorldPos. OnAddedToWorld meanwhile sets
        // EntityAlive.bSpawned, and updateRespawn short-circuits to Done on
        // that, abandoning the sequence before it closes the loading screen.
        c.world_ready = true;
        return true;
    }
    // createWorld posts DynamicClientArrive. Prefer RequestToSpawnPlayer for the
    // join bundle. Re-sending WorldInitInfo after PlayerId restarts createWorld
    // mid-session and leaves the stock client on "Creating player".
    if (std.mem.eql(u8, name, "NetPackageDynamicClientArrive")) {
        if (c.entered) {
            // Already in-world. Stock DynamicClientArrive is dynamic-mesh
            // inventory reconcile (not implemented); join SM must not re-answer.
            return true;
        }
        // Fallback spawn path when RequestToSpawnPlayer never arrives / fails parse.
        if (c.entity_id > 0) {
            c.view_radius = if (c.view_radius < 1) self.view_radius else c.view_radius;
            // One deadline for the whole must-deliver bundle (same rule as the
            // RequestToEnterGame path): without it every sendGameCritical in
            // the bundle re-arms its own budget and a peer that stops ACKing
            // costs the tick one full budget per critical package.
            const owns_bundle_budget = peer.armCriticalBudget(game_mod.critical_retry_budget_ns);
            defer peer.releaseCriticalBudget(owns_bundle_budget);
            try self.sendJoinBundle(c, peer, sp.x, sp.y, sp.z, c.entity_id);
            std.debug.print("zdtd: DynamicClientArrive -> join bundle (spawn fallback) entity={d}\n", .{c.entity_id});
        } else {
            const wi = try packages.buildWorldInitInfoEmpty(self.body_buf[0..16]);
            try self.sendGameCritical(peer, "NetPackageWorldInitInfo", wi);
            std.debug.print("zdtd: DynamicClientArrive -> WorldInitInfo empty (pre-spawn) entity={d}\n", .{c.entity_id});
            // Head start on the spawn area. createWorld posts this package, so
            // the client's ChunkCache exists and will keep these. The client
            // needs collision meshes (Chunk.GetAvailable == IsCollisionMeshGenerated)
            // for the spawn chunk and its 8 neighbours before
            // World.IsPositionAvailable succeeds; until then updateRespawn parks
            // in ClampingToValidWorldPos. Meanwhile OnAddedToWorld sets
            // EntityAlive.bSpawned, and updateRespawn's first line short-circuits
            // to Done on that, abandoning the sequence before it closes the
            // loading screen. Streaming only at spawn time loses that race by
            // ~40s; stock has the area meshed well before the player appears.
            if (self.wire_chunks) {
                const r0: i32 = if (c.view_radius < 1) self.chunk_stream_radius_min else @min(c.view_radius, self.chunk_stream_radius_max);
                try self.sendSpawnArea(peer, sp.x, sp.z, r0);
            }
        }
        return true;
    }
    return false;
}
