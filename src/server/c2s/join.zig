//! Join state machine — extracted from game.zig handlePackage (stock SM).
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
const assets_gamestages = @import("../../assets/gamestages.zig");
const ecs = @import("../../ecs/root.zig");
const phase_gate = @import("../phase_gate.zig");
const clock = @import("../../util/clock.zig");
const version_mod = @import("../../version.zig");

const sanitizePlayerName = c2s_text.sanitizePlayerName;

/// True when handled (join SM package). False lets caller fall through to c2s/*.
pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    const sp = self.world.primarySpawn();
    if (std.mem.eql(u8, name, "NetPackagePlayerLogin")) {
        // ServerPassword already enforced at LiteNet ConnectRequest (net.server_password).
        // Stock PlayerAllowed replaces LastGameServerInfo with GameServerInfo(loginAnswer.data).
        // data must be full GSI ToString text (not "ok") so worldInfoCo can parse ServerVersion.
        const gsi = try self.buildLoginGsiText(self.body_buf[4096..8192]);
        if (c.joined and c.entity_id > 0) {
            const ans = try packages.buildLoginAnswerBody(self.body_buf[0..2048], true, gsi);
            try self.sendGame(peer, "NetPackagePlayerLoginAnswer", ans);
            const spawned = try packages.buildSpawnedBody(
                self.body_buf[256..384],
                @intFromEnum(packages.RespawnType.join_multiplayer),
                sp.x,
                sp.y,
                sp.z,
                c.entity_id,
            );
            try self.sendGame(peer, "NetPackagePlayerSpawnedInWorld", spawned);
            return true;
        }
        // Name (save key) plus both platform identities, per asm.il 832140.
        if (body.len > 1) {
            if (packages.parsePlayerLogin(body, c.name[0..])) |login| {
                // Strip C0/DEL so login names cannot inject CR/LF into admin
                // replies, audit lines, or GSI-adjacent operator surfaces.
                c.name_len = sanitizePlayerName(c.name[0..], login.name);
                c.puid_primary = login.internalId();
                c.puid_native = login.native;
                // VersionAuthorizer (asm.il VersionAuthorizer): the client's
                // compatibilityVersion must equal LongStringNoBuild
                // (`version.stock_wire_comp` = "V 3.10" for V3.1.0 b14,
                // `{0} {1}.{2}` with the raw Minor) ordinal-ignore-case, or
                // stock kicks EKickReason.VersionMismatch(4). A different
                // client build must not join and desync silently.
                if (!std.ascii.eqlIgnoreCase(login.compVersion(), version_mod.stock_wire_comp)) {
                    self.harness.counters.inc(.c2s_version_rejects);
                    if (c.peer) |p| {
                        var denied: [64]u8 = undefined;
                        if (packages.buildPlayerDeniedBody(&denied, .version_mismatch, 0, 0, "")) |body2| {
                            self.sendGame(p, "NetPackagePlayerDenied", body2) catch
                                self.harness.counters.inc(.net_send_errors);
                        } else |_| self.harness.counters.inc(.encode_errors);
                    }
                    std.debug.print("zdtd: login version mismatch comp='{s}' want='{s}' slot={d}\n", .{ login.compVersion(), version_mod.stock_wire_comp, c.slot });
                    return true;
                }
            } else |_| {
                // A login body zdtd cannot fully decode still gets its name
                // read, because refusing the join would lock the player out
                // over a field the server never trusts anyway. The identity
                // stays null and the deterministic fallback below applies.
                self.harness.counters.inc(.c2s_malformed);
                var r: wire_binary.Reader = .{ .data = body };
                if (r.readString(c.name[0..])) |nm| {
                    c.name_len = sanitizePlayerName(c.name[0..], nm);
                } else |_| {}
            }
        }
        // Wasm/static plugin join gate: after sanitization, before any join effect.
        // First deny wins; traps are ignored (allow). Ordering: plugin allowlist
        // before identity ban so a custom allowlist can coexist with ban_list.
        {
            var deny_buf: [256]u8 = undefined;
            const name_slice = if (c.name_len > 0) c.name[0..c.name_len] else "";
            if (self.plugins.playerLoginDeny(@intCast(c.slot), name_slice, &deny_buf)) |reason| {
                self.harness.counters.inc(.join_fail);
                std.debug.print("zdtd: PlayerLogin plugin deny slot={d} reason={s}\n", .{ c.slot, reason });
                self.dropClientSlot(c.slot, "plugin-deny");
                return true;
            }
            if (self.wasm_plugins.playerLoginDeny(@intCast(c.slot), name_slice, &deny_buf)) |reason| {
                self.harness.counters.inc(.join_fail);
                std.debug.print("zdtd: PlayerLogin wasm deny slot={d} reason={s}\n", .{ c.slot, reason });
                self.dropClientSlot(c.slot, "wasm-deny");
                return true;
            }
        }
        // Identity ban (`ban add`) outlives the connection an IP ban catches,
        // so it is checked once the login name is known.
        if (c.name_len != 0 and self.ban_list.banned(c.name[0..c.name_len], clock.wallSeconds())) {
            self.harness.counters.inc(.join_fail);
            self.dropClientSlot(c.slot, "identity-ban");
            return true;
        }
        const ans = try packages.buildLoginAnswerBody(self.body_buf[0..2048], true, gsi);
        try self.sendGame(peer, "NetPackagePlayerLoginAnswer", ans);
        const surf0 = self.spawnSurface(sp.x, sp.z);
        const was_joined = c.joined;
        const eid = self.sim.spawnPlayer(@floatFromInt(surf0.x), @floatFromInt(surf0.y), @floatFromInt(surf0.z), @intCast(c.slot)) orelse return true;
        c.entity_id = eid;
        // Restored claims keyed by this login name get their live owner
        // entity re-mapped here (entity ids are reassigned per session).
        self.reclaimForName(c.name[0..c.name_len], eid);
        c.joined = true;
        c.view_radius = self.view_radius;
        // PlayerDataFile::CopyTo clamps a not-yet-set bornAt down to the
        // current world time (asm.il ~1975949), so a fresh session starts
        // at zero days survived rather than at the -1 sentinel.
        if (!was_joined) c.game_stage_born_world_time = self.sim.director.clock.worldTimeBits();
        self.tryRestorePlayer(c);
        // Stock: LoginAnswer only. Configs must arrive after StartAsClient starts
        // WaitForConfigsFromServer (which resets WasReceivedFromServer). That is
        // after RequestToEnterGame is sent from the client.
        self.refreshInfoPlayers();
        self.harness.counters.inc(.join_ok);
        if (was_joined) {
            self.harness.counters.inc(.reconnects);
            self.noteEvidence(c, peer.local_id, eid, .flood, .info, .none, 1, 0);
        }
        // Name length only in logs (name stays on admin listplayers / webui).
        std.debug.print("zdtd: PlayerLogin name_len={d} entity={d} body={d}\n", .{ c.name_len, eid, body.len });
        return true;
    }
    // Stock: StartAsClient starts config-wait coroutine, then RequestToEnterGame.
    // Send local ConfigFiles now so the wait can finish; then WorldInfo.
    if (std.mem.eql(u8, name, "NetPackageRequestToEnterGame")) {
        std.debug.print("zdtd: RequestToEnterGame entity={d}\n", .{c.entity_id});
        // One deadline covers the whole must-deliver enter bundle. Clear it at
        // the request boundary so later critical exchanges (sign data,
        // PlayerId) receive their own bounded budget.
        peer.critical_budget_deadline_ns = clock.monoNs() + game_mod.critical_retry_budget_ns;
        defer peer.critical_budget_deadline_ns = 0;
        if (c.entity_id <= 0) {
            const surf_e = self.spawnSurface(sp.x, sp.z);
            c.entity_id = self.sim.spawnPlayer(@floatFromInt(surf_e.x), @floatFromInt(surf_e.y), @floatFromInt(surf_e.z), @intCast(c.slot)) orelse return true;
            c.joined = true;
            self.tryRestorePlayer(c);
        }
        // Before the configs: the client only runs Block::AssignIds after the
        // ConfigFile package (WorldStaticData LoadBlocks IL_0058, asm.il
        // 2014542), and stock sends the mapping at this same point.
        try self.sendBlockIdMapping(peer);
        try self.sendLocalConfigFiles(peer);
        const wi = try packages.buildWorldInfoBody(self.body_buf[0..256], self.world_name, 6144, 6144, sp.x, sp.y, sp.z, 0);
        try self.sendGameCritical(peer, "NetPackageWorldInfo", wi);
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
        std.debug.print("zdtd: AuthConfirmation body={d}\n", .{body.len});
        return true;
    }
    // worldInfoCo: after configs, client RequestWorldSignDataFromServer and blocks until
    // SignDataResponse(isLastBatch=true). Send prefab library shells (guid+name, 0 layers).
    if (std.mem.eql(u8, name, "NetPackageSignDataRequest")) {
        try self.sendSignDataBatches(peer);
        return true;
    }
    // worldInfoCo: after createWorld, client sends WorldInitInfoRequest and waits for
    // worldInitInfoReceived (set by ProcessPackage of WorldInitInfo).
    if (std.mem.eql(u8, name, "NetPackageWorldInitInfoRequest")) {
        // Same hang class as DynamicClientArrive: WorldInitInfo after enter can
        // restart createWorld and leave the client on Creating player.
        if (c.entered) return true;
        const wi = try packages.buildWorldInitInfoEmpty(self.body_buf[0..16]);
        try self.sendGame(peer, "NetPackageWorldInitInfo", wi);
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
            try self.sendJoinBundle(c, peer, sp.x, sp.y, sp.z, c.entity_id);
            std.debug.print("zdtd: DynamicClientArrive -> join bundle (spawn fallback) entity={d}\n", .{c.entity_id});
        } else {
            const wi = try packages.buildWorldInitInfoEmpty(self.body_buf[0..16]);
            try self.sendGame(peer, "NetPackageWorldInitInfo", wi);
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
            if (dim > 8) dim = 8;
            c.view_radius = dim;
        } else |_| {
            c.view_radius = self.view_radius;
        }
        const surf = self.spawnSurface(sp.x, sp.z);
        if (c.entity_id <= 0) {
            c.entity_id = self.sim.spawnPlayer(@floatFromInt(surf.x), @floatFromInt(surf.y), @floatFromInt(surf.z), @intCast(c.slot)) orelse return true;
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
                self.sim.respawnPlayer(
                    si,
                    @floatFromInt(bed_surf.x),
                    @as(f32, @floatFromInt(bed_surf.y)) + 0.08,
                    @floatFromInt(bed_surf.z),
                );
                if (packages.buildEntityStatBody(self.body_buf[512..640], c.entity_id, 100, 100)) |hb| {
                    try self.sendGame(peer, "NetPackageEntityStatChanged", hb);
                } else |_| {}
                if (packages.buildEntityTeleportBody(&self.body_buf, c.entity_id, @floatFromInt(sp.x), @floatFromInt(sp.y), @floatFromInt(sp.z), 0, 0, 0, true)) |tb| {
                    try self.sendGame(peer, "NetPackageEntityTeleport", tb);
                } else |_| {}
                if (packages.buildEntityTeleportBody(&self.body_buf, c.entity_id, @as(f32, @floatFromInt(bed_surf.x)), @as(f32, @floatFromInt(bed_surf.y)) + 0.08, @as(f32, @floatFromInt(bed_surf.z)), 0, 0, 0, true)) |tb| {
                    try self.sendGame(peer, "NetPackageEntityTeleport", tb);
                } else |_| {}
                const spawned = try packages.buildSpawnedBody(
                    self.body_buf[256..384],
                    @intFromEnum(packages.RespawnType.died),
                    bed_surf.x,
                    bed_surf.y,
                    bed_surf.z,
                    c.entity_id,
                );
                try self.sendGame(peer, "NetPackagePlayerSpawnedInWorld", spawned);
                std.debug.print("zdtd: respawn heal entity={d}\n", .{c.entity_id});
            }
        } else {
            c.entity_id = self.sim.spawnPlayer(@floatFromInt(surf.x), @floatFromInt(surf.y), @floatFromInt(surf.z), @intCast(c.slot)) orelse return true;
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
        try self.sendJoinBundle(c, peer, surf.x, surf.y, surf.z, c.entity_id);
        return true;
    }
    return false;
}
