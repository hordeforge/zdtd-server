//! Join state machine - extracted from game.zig handlePackage (stock SM).
//! Owns the 7 join packages that must stay coherent: PlayerLogin →
//! RequestToEnterGame → AuthConfirmation → SignDataRequest →
//! WorldInitInfoRequest → DynamicClientArrive → RequestToSpawnPlayer.
//! Bodies are verbatim copies (stock asm.il comments kept). This file is
//! imported via src/server/root.zig so `zig build test` aggregates it; game.zig
//! keeps only a one-line delegate.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const wire_binary = @import("../../wire/binary.zig");
const c2s_text = @import("../c2s_text.zig");
const prefabs_mod = @import("../../world/prefabs.zig");
const assets_gamestages = @import("../../assets/gamestages.zig");
const ecs = @import("../../ecs/root.zig");
const clock = @import("../../util/clock.zig");
const admin_cmds = @import("../admin_cmds.zig");
const version_mod = @import("../../version.zig");
const plugin_compose = @import("../game/plugin_compose.zig");
const join_login = @import("join_login.zig");
const join_enter = @import("join_enter.zig");

const sanitizePlayerName = c2s_text.sanitizePlayerName;

const apm = @import("../../apm/root.zig");

/// Upper bound on C2S RequestToSpawnPlayer.chunkViewDim (viewDist 8 mesh core).
const max_spawn_chunk_view_dim: i32 = 8;

/// Spawn a player entity or record a join failure. A full entity table used to
/// return null with no counter and no log, so `join_ok`/`join_fail` stayed flat
/// while the peer hung mid-login with no operator signal.
fn spawnPlayerOrFail(self: *Game, c: *Client, x: f32, y: f32, z: f32, where: []const u8) ?i32 {
    if (self.sim.spawnPlayer(x, y, z, @intCast(c.slot))) |eid| return eid;
    self.harness.counters.inc(.join_fail);
    var ts: [19]u8 = undefined;
    std.debug.print(
        "zdtd: {s} player spawn failed ({s}) slot={d} name_len={d}\n",
        .{ clock.wallStamp(&ts), where, c.slot, c.name_len },
    );
    return null;
}

/// True when handled (join SM package). False lets caller fall through to c2s/*.
pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    // Join-phase attribution (GAP "Join-burst tick budget"): the whole C2S
    // join handler is one apm section so the residual synchronous join work
    // (spawn-area core, join bundle, respawn logic) is measurable separately
    // from the paced chunk drain (.replicate) and the rest of net_poll.
    const sc = apm.profiler.scope(&self.harness.prof, .join);
    defer sc.end();
    const sp = self.world.primarySpawn();
    if (try join_login.handleLogin(self, c, peer, name, body)) return true;
    if (try join_enter.handleEnter(self, c, peer, name, body)) return true;
    // worldInfoCo: after configs, client RequestWorldSignDataFromServer and blocks until
    // SignDataResponse(isLastBatch=true). Send prefab library shells (guid+name, 0 layers).
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
    if (std.mem.eql(u8, name, "NetPackageRequestToSpawnPlayer")) {
        if (packages.parseRequestToSpawnPlayer(body)) |req| {
            // chunkViewDim is in chunks; clamp for reliable window (join uses ≤2).
            var dim: i32 = req.chunk_view_dim;
            if (dim < 1) dim = self.view_radius;
            dim = @min(dim, max_spawn_chunk_view_dim);
            c.view_radius = dim;
        } else |_| {
            c.view_radius = self.view_radius;
        }
        // The client's own character profile rides the same body. Stock stores
        // it on the ECD it writes back (GameManager::RequestToSpawnPlayer
        // GameManager.il.txt:4614-4617) so the player sees their real
        // appearance and everyone nearby sees it too; a malformed or absent
        // profile keeps the previous/default one instead of failing the spawn.
        if (packages.parseRequestToSpawnProfile(body)) |prof| {
            c.profile = prof;
            c.profile_ok = true;
        } else |_| {}
        const surf = self.spawnSurface(sp.x, sp.z);
        if (c.entity_id <= 0) {
            c.entity_id = spawnPlayerOrFail(
                self,
                c,
                @floatFromInt(surf.x),
                @floatFromInt(surf.y),
                @floatFromInt(surf.z),
                "RequestToSpawnPlayer",
            ) orelse {
                self.dropClientSlot(c.slot, "spawn-full");
                return true;
            };
        } else if (self.sim.slotOfNetId(c.entity_id)) |si| {
            // Respawn heal/teleport only when actually dead; a live player
            // resending RequestToSpawn must not get a free heal + escape.
            if (!self.sim.alive[si] or self.sim.health[si].hp <= 0) {
                // Only sanctioned un-kill: a raw alive[] write would leave
                // the cached kind group out of sync.
                // EntityPlayer::SetAlive (asm.il ~503838): a death costs
                // daysAliveChangeWhenKilled days off the survival streak.
                c.game_stage_born_world_time = assets_gamestages.bornAtAfterDeath(
                    self.gamestages.config,
                    self.sim.director.clock.worldTimeBits(),
                    c.game_stage_born_world_time,
                );
                // Respawn target: the player's bedroll when set (stock
                // EntityPlayer.spawnPoint), else the world spawn.
                const rpx: i32 = if (c.has_bed) c.bed_x else sp.x;
                const rpz: i32 = if (c.has_bed) c.bed_z else sp.z;
                const bed_surf = self.spawnSurface(rpx, rpz);
                // Sanctioned respawn funnel: revive + heal + clear death
                // buffs/IsBloodMoonDead + place + mark dirty in one call.
                // The cleared death buffs have to reach the clients: stock's
                // removals drain through the tick that emits the wire (RE
                // buffs.md:194), so a silent clear leaves the icon on every
                // HUD for the rest of the session.
                var cleared: [ecs.components.max_buffs_per_entity]ecs.buff.Removed = undefined;
                const cleared_n = self.sim.respawnPlayer(
                    si,
                    @floatFromInt(bed_surf.x),
                    @as(f32, @floatFromInt(bed_surf.y)) + 0.08,
                    @floatFromInt(bed_surf.z),
                    cleared[0..],
                );
                for (cleared[0..@min(cleared_n, cleared.len)]) |rm| {
                    const def = self.buffs.byId(rm.def_id) orelse continue;
                    self.relayBuff(c.entity_id, def.name, false, -1, null) catch {};
                }
                // Stock playerMale respawn rows (entityclasses.xml): re-add the
                // check buffs (survive death anyway, belt-and-braces), the
                // 6.5 s spawn-protection buff (buffDeathFoodDrinkAdjust: PDR
                // 100 + HP set on update) and the near-death trauma trigger
                // (fires trauma + regen on its remove). Without these a
                // respawned player takes full damage at the spawn point.
                for ([_][]const u8{
                    "buffStatusCheck01",
                    "buffStatusCheck02",
                    "buffDeathFoodDrinkAdjust",
                    "buffNearDeathTraumaTrigger",
                }) |bname| {
                    _ = self.addCatalogBuff(c.entity_id, si, bname, c.entity_id);
                }
                // Stock `onSelfRespawn` rows fire after the respawn: the only
                // stock row is buffNearDeathProtection's self-remove (a stale
                // protection buff from a previous life clears here, matching
                // the TRIGGERED_BY comment on the trauma trigger).
                self.fireRespawn(si);
                // The DeathPenalty-selected respawn sequence adjusts what the
                // funnel restored (game_on_respawn_injured halves Food/Water
                // and may add buffInfectionCatch; the others SetMax, and
                // _permanent also clears the biome badges and hazard timers).
                // Data, not code: the client's own respawn flow asks the server
                // for exactly this sequence (GameEventManager::HandleActionClient
                // IL=416 forwards the request), and running it here covers the
                // order where the request has not arrived yet.
                if (Game.respawnSequenceName(self.death_penalty)) |seq_name| {
                    _ = self.runGameEventSequence(c.slot, seq_name);
                }
                // Arm the next death. The guard exists so one death cannot
                // produce two bags (the C2S kill path and the hp-replicate
                // detector both see the same corpse); it used to ride
                // `has_backpack`, which stays set until the bag is collected,
                // so a player who died again before collecting dropped
                // nothing at all and lost the inventory outright. The map
                // marker keeps pointing at the uncollected bag, which is
                // correct: it is still lying there.
                c.bagged_this_death = false;
                c.death_counted = false;
                // Respawn confirm first (the client leaves the death screen
                // and enters the spawned state), then position + HP so the
                // post-respawn state cannot be discarded while still dead.
                const spawned = try packages.buildSpawnedBody(
                    self.body_buf[256..384],
                    @intFromEnum(packages.RespawnType.died),
                    bed_surf.x,
                    bed_surf.y,
                    bed_surf.z,
                    c.entity_id,
                );
                try self.sendGame(peer, "NetPackagePlayerSpawnedInWorld", spawned);
                if (packages.buildEntityTeleportBody(&self.body_buf, c.entity_id, @as(f32, @floatFromInt(bed_surf.x)), @as(f32, @floatFromInt(bed_surf.y)) + 0.08, @as(f32, @floatFromInt(bed_surf.z)), 0, 0, 0, true)) |tb| {
                    try self.sendGame(peer, "NetPackageEntityTeleport", tb);
                } else |_| {}
                // Redundant with the replicate pass by content (respawnPlayer
                // marks hp dirty, so game/replicate_health.zig sends the same
                // EntityStatChanged on the next tick), but not by timing: this
                // one rides the respawn burst so the client's health bar is
                // right the moment it regains control rather than up to a
                // replicate interval later. Removing it alone keeps the
                // hp-replication scenario green, which is why it reads as
                // untested.
                if (packages.buildEntityStatChangedBody(self.body_buf[512..640], c.entity_id, -1, .health, 100, 100, 0)) |hb| {
                    try self.sendGame(peer, "NetPackageEntityStatChanged", hb);
                } else |_| {}
                std.debug.print("zdtd: respawn heal entity={d} slot={d}\n", .{ c.entity_id, c.slot });
            }
        } else {
            c.entity_id = spawnPlayerOrFail(
                self,
                c,
                @floatFromInt(surf.x),
                @floatFromInt(surf.y),
                @floatFromInt(surf.z),
                "RequestToSpawnPlayer-rebind",
            ) orelse {
                self.dropClientSlot(c.slot, "spawn-full");
                return true;
            };
        }
        c.joined = true;
        // Stream the spawn area before the bundle, while the client is still
        // waiting on its spawn request. NetPackagePlayerId creates the local
        // player, which opens the spawn-selection window; that window's
        // updateLoadState returns on `cgo >= viewDist^2 - 10` and stops being
        // ticked once the loading screen covers it, so a client that spawns
        // with no displayed chunks stays in WaitingForSpawnWindowToClose
        // behind the loading screen. Sending here (not inside sendJoinBundle)
        // keeps the pre-world DynamicClientArrive fallback untouched: chunks
        // sent before the client's world exists are dropped and wedge the join.
        if (self.wire_chunks and !c.entered) {
            const r0: i32 = if (c.view_radius < 1) self.chunk_stream_radius_min else @min(c.view_radius, self.chunk_stream_radius_max);
            try self.sendSpawnArea(peer, surf.x, surf.z, r0);
        }
        // Death-respawn already sent Spawned+stats; still re-send join bundle so the
        // client re-enters IsSpawned (playtest saw hp=100 but IsSpawned=false without it).
        // One deadline for the bundle, as in the RequestToEnterGame path.
        const owns_bundle_budget = peer.armCriticalBudget(game_mod.critical_retry_budget_ns);
        defer peer.releaseCriticalBudget(owns_bundle_budget);
        try self.sendJoinBundle(c, peer, surf.x, surf.y, surf.z, c.entity_id);
        return true;
    }
    return false;
}
