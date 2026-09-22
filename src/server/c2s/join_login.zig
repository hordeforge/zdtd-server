//! C2S join arm: PlayerLogin validate, spawn, join bundle.
//!
//! Split out of c2s/join.zig (same code, moved verbatim).

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
const clock = @import("../../util/clock.zig");
const admin_cmds = @import("../admin_cmds.zig");
const version_mod = @import("../../version.zig");
const plugin_compose = @import("../game/plugin_compose.zig");
const sanitizePlayerName = c2s_text.sanitizePlayerName;

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

/// True when `name` is a login package and was handled.
pub fn handleLogin(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    const sp = self.world.primarySpawn();
    if (std.mem.eql(u8, name, "NetPackagePlayerLogin")) {
        // ServerPassword already enforced at LiteNet ConnectRequest (net.server_password).
        // Stock PlayerAllowed replaces LastGameServerInfo with GameServerInfo(loginAnswer.data).
        // data must be full GSI ToString text (not "ok") so worldInfoCo can parse ServerVersion.
        const gsi = try self.buildLoginGsiText(self.body_buf[4096..8192]);
        if (c.joined and c.entity_id > 0) {
            const ans = try packages.buildLoginAnswerBody(self.body_buf[0..2048], true, gsi);
            try self.sendGameCritical(peer, "NetPackagePlayerLoginAnswer", ans);
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
                // (`version.stock_wire_comp` = "V 3.2.0" - the EMPIRICALLY
                // verified value, network.md login-version-gate section; the
                // IL reading "V 3.20" is wrong in practice; the Minor=10
                // advertising that kicked every 3.2.0 client is fixed) ordinal-
                // ignore-case, or stock kicks EKickReason.VersionMismatch(4).
                // A different client build must not join and desync silently.
                if (!std.ascii.eqlIgnoreCase(login.compVersion(), version_mod.stock_wire_comp)) {
                    // Keep the specific counter for version triage, and also
                    // bump join_fail so the join_ok/join_fail ratio and the
                    // webui join_fail gauge cover every deny reason.
                    self.harness.counters.inc(.c2s_version_rejects);
                    self.harness.counters.inc(.join_fail);
                    if (c.peer) |p| {
                        var denied: [64]u8 = undefined;
                        if (packages.buildPlayerDeniedBody(&denied, .version_mismatch, 0, 0, "")) |body2| {
                            self.sendGame(p, "NetPackagePlayerDenied", body2) catch
                                self.harness.counters.inc(.net_send_errors);
                        } else |_| self.harness.counters.inc(.encode_errors);
                    }
                    var ts: [19]u8 = undefined;
                    std.debug.print(
                        "zdtd: {s} login version mismatch comp='{s}' want='{s}' slot={d} local_id={d}\n",
                        .{ clock.wallStamp(&ts), login.compVersion(), version_mod.stock_wire_comp, c.slot, peer.local_id },
                    );
                    self.dropClientSlot(c.slot, "version-mismatch");
                    return true;
                }
                // Stock PlayerSlotsAuthorizer.Authorize (IL=174) rejects a
                // full server with EKickReason.PlayerLimitExceeded(5) at
                // login time (after PackageIds), so the client shows "server
                // full" instead of hanging. The tiered gate: normal players
                // join while total < max; reserved-tier players (perm <=
                // ServerReservedSlotsPermission) need ServerReservedSlots > 0
                // and free reserved seats (privileged occupants < max -
                // ServerReservedSlots); the admin tier (ServerAdminSlots > 0
                // and perm <= ServerAdminSlotsPermission) joins while total <
                // max + ServerAdminSlots. A zero reserved/admin count disables
                // that tier (GAME_OPTIONS).
                const incoming_perm = self.permLevelOf(c);
                var total: u16 = 0;
                var privileged: u16 = 0;
                for (&self.clients) |*cl| {
                    if (!cl.joined) continue;
                    total += 1;
                    if (self.permLevelOf(cl) <= self.reserved_slots_permission) privileged += 1;
                }
                var cap_ok = total < self.max_players;
                // ServerReservedSlots=0 disables the reserved tier (GAME_OPTIONS /
                // PlayerSlotsAuthorizer); without this gate a perm-0 admin could
                // still climb past max via privileged < max - 0.
                if (!cap_ok and self.reserved_slots > 0 and incoming_perm <= self.reserved_slots_permission) {
                    cap_ok = privileged < (self.max_players -| self.reserved_slots);
                }
                if (!cap_ok and self.admin_slots > 0 and incoming_perm <= self.admin_slots_permission) {
                    cap_ok = total < self.max_players + self.admin_slots;
                }
                if (!cap_ok) {
                    self.harness.counters.inc(.join_fail);
                    if (c.peer) |p| {
                        var denied: [64]u8 = undefined;
                        if (packages.buildPlayerDeniedBody(&denied, .player_limit_exceeded, 0, 0, "")) |body2| {
                            self.sendGame(p, "NetPackagePlayerDenied", body2) catch
                                self.harness.counters.inc(.net_send_errors);
                        } else |_| self.harness.counters.inc(.encode_errors);
                    }
                    std.debug.print("zdtd: login server full slot={d} joined={d} max={d}\n", .{ c.slot, total, self.max_players });
                    return true;
                }
            } else |_| {
                // A login body zdtd cannot fully decode still gets its name
                // read, because refusing the join would lock the player out
                // over a field the server never trusts anyway. The identity
                // stays null and the deterministic fallback below applies.
                self.harness.counters.inc(.c2s_malformed);
                var r: wire_binary.Reader = .{ .data = body };
                if (r.readStringTruncating(c.name[0..])) |nm| {
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
            if (plugin_compose.playerLoginDeny(self, @intCast(c.slot), name_slice, &deny_buf)) |reason| {
                self.harness.counters.inc(.join_fail);
                // Reason length only: the guest may echo the login name into the
                // deny text (hooks receive the name), and process logs must not
                // hold that string (same rule as PlayerLogin name_len).
                std.debug.print("zdtd: PlayerLogin plugin deny slot={d} reason_len={d}\n", .{ c.slot, reason.len });
                self.dropClientSlot(c.slot, "plugin-deny");
                return true;
            }
        }
        // Identity ban (`ban add`) outlives the connection an IP ban catches,
        // so it is checked once the login identity is known. The primary key
        // is the platform id (stock AdminBlacklist keys on the platform
        // identifier, so a rename cannot evade); name-keyed entries cover
        // legacy bans.zsv rows and sessions without a platform identity.
        const wall_now = clock.wallSeconds();
        var banned = false;
        var ban_idx: ?usize = null;
        if (c.puid_primary.get()) |pid| {
            if (self.ban_list.bannedId(pid.platform, pid.id, wall_now)) {
                banned = true;
                ban_idx = self.ban_list.findId(pid.platform, pid.id);
            }
        }
        if (!banned and c.name_len != 0) {
            if (self.ban_list.banned(c.name[0..c.name_len], wall_now)) {
                banned = true;
                ban_idx = self.ban_list.find(c.name[0..c.name_len]);
            }
        }
        if (banned) {
            self.harness.counters.inc(.join_fail);
            // Stock always sends PlayerDenied before the drop so the client
            // shows the ban UI (banUntil via DateTime.ToBinary) instead of a
            // bare timeout (scenarios.zig guard-kick note).
            if (c.peer) |p| {
                var until_bin: i64 = 0;
                var reason: []const u8 = "";
                if (ban_idx) |i| {
                    const e = &self.ban_list.entries[i];
                    until_bin = clock.unixSecondsToDateTimeBinaryUtc(e.expires_unix);
                    reason = e.reason.slice();
                }
                // i32+i32+i64 + 7-bit len + max_reason
                var denied: [4 + 4 + 8 + 5 + admin_cmds.max_reason]u8 = undefined;
                if (packages.buildPlayerDeniedBody(&denied, .banned, 0, until_bin, reason)) |body2| {
                    self.sendGame(p, "NetPackagePlayerDenied", body2) catch
                        self.harness.counters.inc(.net_send_errors);
                } else |_| self.harness.counters.inc(.encode_errors);
            }
            var ts: [19]u8 = undefined;
            std.debug.print(
                "zdtd: {s} login identity ban slot={d} name_len={d} local_id={d}\n",
                .{ clock.wallStamp(&ts), c.slot, c.name_len, peer.local_id },
            );
            self.dropClientSlot(c.slot, "identity-ban");
            return true;
        }
        // Stock BansAndWhitelistAuthorizer.Authorize (IL=71): with a
        // non-empty whitelist only whitelisted players and admins join;
        // everyone else is denied EKickReason.NotOnWhitelist(7) (admins
        // bypass via AdminUsers.HasEntry). Platform composite when the
        // client presented one; name only for no-platform sessions - a
        // display name must not mint whitelist/admin standing for a peer
        // that already has a platform id (stock HasEntry IL=30).
        if (self.whitelist.n > 0) {
            const wl_hit = self.permissionListHit(&self.whitelist, c);
            const adm_hit = self.permissionListHit(&self.admin_list, c);
            if (!wl_hit and !adm_hit) {
                self.harness.counters.inc(.join_fail);
                if (c.peer) |p| {
                    var denied: [64]u8 = undefined;
                    if (packages.buildPlayerDeniedBody(&denied, .not_on_whitelist, 0, 0, "")) |body2| {
                        self.sendGame(p, "NetPackagePlayerDenied", body2) catch
                            self.harness.counters.inc(.net_send_errors);
                    } else |_| self.harness.counters.inc(.encode_errors);
                }
                std.debug.print("zdtd: login not on whitelist slot={d} name_len={d}\n", .{ c.slot, c.name_len });
                self.dropClientSlot(c.slot, "whitelist-deny");
                return true;
            }
        }
        // Reserve the player entity before LoginAnswer so a full entity table
        // cannot leave the client believing it joined with no server entity.
        const surf0 = self.spawnSurface(sp.x, sp.z);
        const was_joined = c.joined;
        const eid = spawnPlayerOrFail(
            self,
            c,
            @floatFromInt(surf0.x),
            @floatFromInt(surf0.y),
            @floatFromInt(surf0.z),
            "PlayerLogin",
        ) orelse {
            self.dropClientSlot(c.slot, "spawn-full");
            return true;
        };
        c.entity_id = eid;
        const ans = try packages.buildLoginAnswerBody(self.body_buf[0..2048], true, gsi);
        try self.sendGameCritical(peer, "NetPackagePlayerLoginAnswer", ans);
        // Stock AuthFinalizer.Authorize (IL=10): the last authorizer step
        // sends an empty AuthConfirmation, which the client echoes back
        // (ProcessPackage IL_002E, SendToServer). The echo arm below already
        // handles it; without the send the round-trip never starts.
        // GetLength 9 is the base NetPackage header; the body is empty
        // (read IL=1, write IL=4 both touch nothing past the base).
        try self.sendGame(peer, "NetPackageAuthConfirmation", &.{});
        // Restored claims keyed by this login name get their live owner
        // entity re-mapped here (entity ids are reassigned per session).
        self.reclaimForName(c.name[0..c.name_len], eid);
        self.reclaimTurretsForName(c.name[0..c.name_len], c.slot);
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
        // local_id ties this line to the earlier "peer connected" / challenge logs.
        std.debug.print(
            "zdtd: PlayerLogin name_len={d} entity={d} slot={d} local_id={d} body={d}\n",
            .{ c.name_len, eid, c.slot, peer.local_id, body.len },
        );
        return true;
    }
    return false;
}
