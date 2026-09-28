//! C2S join arm: RequestToSpawnPlayer (profile, spawn, respawn, bundle).
//!
//! Split out of c2s/join.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const assets_gamestages = @import("../../assets/gamestages.zig");
const ecs = @import("../../ecs/root.zig");
const clock = @import("../../util/clock.zig");
const game_player = @import("../game/player.zig");

/// Stock `GameManager::RequestToSpawnPlayer` floor for the client's requested
/// `chunkViewDim` (`Mathf.Clamp(_chunkViewDim, 4, pref190)`, GameManager.il.txt
/// IL_0021-002A). The ceiling is `ServerMaxAllowedViewDistance` (GamePrefs 190),
/// itself clamped into 4..12 at IL_0011-0020.
pub const min_spawn_chunk_view_dim: i32 = 4;

/// Stock's clamp for a joining client's requested chunk view:
/// `Mathf.Clamp(_chunkViewDim, 4, pref190)` with pref190 already clamped into
/// 4..12 (`GameManager::RequestToSpawnPlayer`, GameManager.il.txt
/// IL_0006-002A). `requested < 1` is not a stock form; zdtd reads it as "use
/// the server's own radius", which is why it is resolved before the clamp.
pub fn clampSpawnChunkViewDim(requested: i32, server_max: i32, server_view_radius: i32) i32 {
    const ceiling = @max(min_spawn_chunk_view_dim, server_max);
    const dim = if (requested < 1) server_view_radius else requested;
    return @max(min_spawn_chunk_view_dim, @min(dim, ceiling));
}

/// True when `name` is a spawn-player package and was handled.
pub fn handleSpawnPlayer(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    const sp = self.world.primarySpawn();
    if (std.mem.eql(u8, name, "NetPackageRequestToSpawnPlayer")) {
        if (packages.parseRequestToSpawnPlayer(body)) |req| {
            // chunkViewDim is in chunks. Stock clamps the client's request into
            // [4, ServerMaxAllowedViewDistance] (GameManager.il.txt
            // IL_0021-002A); the old hardcoded cap of 8 silently shrank a stock
            // client asking for 10 or 12 and ignored the operator's pref.
            c.view_radius = clampSpawnChunkViewDim(req.chunk_view_dim, self.server_max_view_distance, self.view_radius);
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
            c.entity_id = game_player.spawnOrFail(
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
            c.entity_id = game_player.spawnOrFail(
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

test "spawn chunk view clamp follows the stock pref, not a hardcoded 8" {
    // IL: pref190 (ServerMaxAllowedViewDistance) is clamped into 4..12, then the
    // client's chunkViewDim is clamped into [4, pref190].
    try std.testing.expectEqual(@as(i32, 12), clampSpawnChunkViewDim(12, 12, 7));
    try std.testing.expectEqual(@as(i32, 10), clampSpawnChunkViewDim(10, 12, 7));
    try std.testing.expectEqual(@as(i32, 4), clampSpawnChunkViewDim(1, 12, 7)); // floor
    try std.testing.expectEqual(@as(i32, 4), clampSpawnChunkViewDim(9, 4, 7)); // operator ceiling
    // A request below 1 is zdtd's "server default" form, then clamped.
    try std.testing.expectEqual(@as(i32, 7), clampSpawnChunkViewDim(0, 12, 7));
    try std.testing.expectEqual(@as(i32, 4), clampSpawnChunkViewDim(0, 4, 7));
    // A pref outside the stock range cannot widen the clamp.
    try std.testing.expectEqual(@as(i32, 4), clampSpawnChunkViewDim(9, 0, 7));
}
