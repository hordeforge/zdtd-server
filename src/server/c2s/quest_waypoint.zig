//! C2S quest arms: goto/treasure points, allies, waypoints, kill awards.
//!
//! Split out of c2s/quest.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const rng_util = @import("../../util/rng.zig");
const systems = @import("../../ecs/systems.zig");

/// True when `name` is a waypoint/ally/kill package and was handled.
pub fn handleWaypoint(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageQuestGotoPoint")) {
        // Stock NetPackageQuestGotoPoint (read IL=43): traderId, playerId,
        // questCode, questTags, position, size, difficulty, GotoType,
        // biomeFilter - the client reports reaching the goto marker so the
        // server completes the objective. zdtd completes goto objectives
        // server-side by proximity (questTickGoto, radius^2 check on the
        // player's position each tick), so the report is a redundant echo:
        // validate and drop.
        if (body.len < 32) {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageQuestTreasurePoint")) {
        // This is a REQUEST, not a progress echo. ObjectiveTreasureChest
        // ::GetPosition (ObjectiveTreasureChest.il.txt:232) only asks the
        // server when the quest carries neither PositionData TreasurePoint(4)
        // nor TreasureOffset(8), and zdtd fills only 0..3, so a stock client
        // always asks. Stock's server resolves a dig site and sends the
        // package back to that player (ProcessPackage :242, SendPackage
        // :322); dropping it left the treasure quest with no marker and no
        // way to finish.
        const req = packages.parseQuestTreasurePoint(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        switch (req.action) {
            // The client telling us where it dug, and the derived
            // blocks-per-reduction step. Nothing to answer.
            packages.quest_point_update_treasure, packages.quest_point_update_blocks => return true,
            packages.quest_point_get_treasure => {},
            // GetGotoPoint rides the same package; zdtd already ships the
            // Location marker in the journal, so the client does not ask.
            else => return true,
        }
        if (req.player_id != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        const s = systems.questFindByCode(&self.sim, c.slot, req.quest_code) orelse {
            self.harness.counters.inc(.c2s_rejects);
            return true;
        };
        // Stock scans for a buriable spot around the quest's POI, falling back
        // to the player. zdtd has no buried-container search, so anchor the
        // dig site on the same POI the journal already advertises and let the
        // client's own radius shrink guide the player in.
        const px = self.sim.transform[ps].x;
        const pz = self.sim.transform[ps].z;
        const cx: f32 = if (s.poi.valid()) s.poi.x + s.poi.size_x * 0.5 else px;
        const cz: f32 = if (s.poi.valid()) s.poi.z + s.poi.size_z * 0.5 else pz;
        const gy_u = self.world.heightWorld(@trunc(cx), @trunc(cz)) catch {
            self.harness.counters.inc(.c2s_rejects);
            return true;
        };
        const gy: i32 = gy_u;
        var buf: [64]u8 = undefined;
        const reply = packages.buildQuestTreasurePointReply(
            &buf,
            req.player_id,
            req.quest_code,
            req.blocks_per_reduction,
            @trunc(cx),
            gy,
            @trunc(cz),
            0,
            0,
            0,
        ) catch {
            self.harness.counters.inc(.encode_errors);
            return true;
        };
        try self.sendGame(peer, "NetPackageQuestTreasurePoint", reply);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageAllyRequest")) {
        try self.handleAllyRequest(c, body);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageAllyResponse")) {
        self.harness.counters.inc(.ownership_rejects);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageWaypoint")) {
        // Rate gate (LandClaimRepair precedent): Everyone-mode relays the
        // waypoint to every connected peer; unthrottled a spam loop fans
        // C2S bandwidth out for free (bandwidth DoS).
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        // Stock NetPackageWaypoint.ProcessPackage (IL=29): ValidEntityIdForSender
        // gate, then GameManager.WaypointInviteServer (IL=164) relays to the
        // inviter's allies (EnumWaypointInviteMode Friends=0, AllyStore.IsAlly
        // on primary ids) or to all players (Everyone=1), skipping the
        // inviter, with the waypoint cloned, bTracked cleared and
        // inviterEntityId re-keyed to the inviter (Setup).
        const wp = packages.parseWaypointInvite(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        if (wp.inviter_entity_id != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        const inviter_id = c.puid_primary.get() orelse return true;
        for (&self.clients) |*cl| {
            if (!cl.joined or cl.entity_id == c.entity_id) continue;
            const target_peer = cl.peer orelse continue;
            if (wp.invite_mode == 0) {
                const target_id = cl.puid_primary.get() orelse continue;
                if (!self.allies.isAlly(inviter_id, target_id)) continue;
            }
            const relay = packages.buildWaypointInviteBody(self.body_buf[0..512], &wp, c.entity_id) catch continue;
            self.sendGame(target_peer, "NetPackageWaypoint", relay) catch |err| {
                self.harness.counters.inc(.net_send_errors);
                std.debug.print("zdtd: send Waypoint failed: {s}\n", .{@errorName(err)});
            };
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntityAwardKillServer")) {
        // Stock body: killerEntityId i32 | killedEntityId i32; the client
        // reports a kill its local player scored (EntityAlive.OnEntityDeath
        // -> AwardKill) so the server can run QuestEventManager.EntityKilled.
        // zdtd credits kill objectives and XP authoritatively at the death
        // path instead (questOnZombieKilled for player melee/ranged kills
        // and turret/trap kills), so this report is a redundant echo of an
        // already-credited kill: applying it would double-credit. Validate
        // the body and drop.
        if (body.len < 8) {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageSharedPartyKill")) {
        // Stock body (read IL=17): entityTypeID i32 | xp i32 | entityID i32 |
        // killerID i32. A client reaches SendToServer only through
        // GameManager.SharedKillServer's !IsServer branch (IL=162), so the
        // package is a forward of a kill the sender's client already scored.
        // zdtd computes the party split server-side in killXpAward
        // (Party.GetPartyXP over GameStats[54] party_shared_kill_range) and
        // fans the result out itself, so accepting the report would award
        // the same kill twice. Validate the body and drop.
        _ = packages.stock_party.readSharedKillBody(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        return true;
    }
    return false;
}
