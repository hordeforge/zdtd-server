//! C2S quest/social/trade domain: shared quests, party and ally actions,
//! buff add/remove, quest events and objective updates, the NPC quest list,
//! trader data and vending-machine edits.
//!
//! Extracted from game.zig's handlePackage following the replicate_te
//! precedent. `handle` returns true when the package name belongs to this
//! domain; handlePackage falls through to the remaining arms otherwise.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");
const rng_util = @import("../../util/rng.zig");
const c2s_text = @import("../c2s_text.zig");
const replicate_te = @import("../replicate_te.zig");
const vending_mod = @import("../../world/vending.zig");

/// Fallback quest-giver marker Y when the trader NPC is not yet in the sim
/// (the marker snaps to the real transform once the entity loads). A
/// plausible ground height, not stock data; the giver marker is client-side.
const quest_giver_fallback_y: f32 = 70;

/// True when `name` belongs to this domain and was handled.
pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageLandClaimRepair")) {
        // Stock ProcessPackage (IL=33): resolve the TE at the block position
        // and, on beginRepair, run RepairAll server-side; ending repair clears
        // IsRepairing for the owner. It emits nothing, so neither do we: the
        // old broadcast fanned a stock-silent package to every peer.
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        const req = packages.parseLandClaimRepair(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        if (!req.begin_repair) return true;
        // Only the claim owner may repair it: stock guards the TE through
        // LocalPlayerIsOwner on the client path, and the server resolves the
        // claim at the keystone. A request outside any claim, or for someone
        // else's, is dropped and counted like the other ownership gates.
        const claim = self.claimCovering(req.x, req.z) orelse {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        };
        if (claim.owner_entity != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        _ = self.repairClaimArea(req.x, req.z);
        // Stock answers the repair pass with Setup(blockPos, false) to the
        // requester (repair coroutine IL_0337), clearing its IsRepairing.
        if (packages.buildLandClaimRepairBody(&self.body_buf, req.x, req.y, req.z, false)) |done| {
            self.sendGame(peer, "NetPackageLandClaimRepair", done) catch |err| {
                self.harness.counters.inc(.net_send_errors);
                std.debug.print("zdtd: LandClaimRepair done send failed slot={d}: {s}\n", .{ c.slot, @errorName(err) });
            };
        } else |_| {}
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageSharedQuest")) {
        // Rate gate (LandClaimRepair precedent): the fallback/else branches
        // broadcast the body to every connected peer; unthrottled a spam
        // loop fans C2S bandwidth out for free (bandwidth DoS).
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        const head = packages.stock_quest.parseSharedQuestHead(body) catch return true;
        // Stock GameManager.QuestShareServer: if sharedWith is local, handle; else
        // forward package to sharedWithEntityID. We forward the body unchanged and
        // update server journal only when quest_id maps to a known catalog def.
        if (head.event == .share_quest) {
            if (head.quest_id_len > 0) {
                if (self.sim.catalog.byName(head.questId())) |d| {
                    _ = systems.questAccept(&self.sim, c.slot, d.id);
                }
            }
            const with = if (head.shared_with_entity_id > 0) head.shared_with_entity_id else c.entity_id;
            if (with == c.entity_id) {
                try self.sendGame(peer, "NetPackageSharedQuest", body);
            } else {
                // Forward to the named peer only. GameManager.QuestShareServer
                // (IL=37, il/full-v3.2.0/_global/GameManager.il.txt:9081) sends
                // with _attachedToEntityId = sharedWithEntityID, so exactly one
                // client receives it and an absent target receives nothing.
                // The old fallback broadcast the offer to every peer, which let
                // one client push a quest offer to the whole server by naming
                // an id nobody holds.
                for (&self.clients) |*cl| {
                    if (!cl.joined or cl.entity_id != with) continue;
                    // Give the target a journal entry carrying the OWNER's
                    // stock quest code and placement. The share packet already
                    // told the target's client that code (SharedQuestData.
                    // questCode), and stock resolves shared-quest traffic by
                    // code alone (QuestJournal.GetSharedQuest IL=33,
                    // RemoveSharedQuestByOwner IL=54), so an entry allocated
                    // with a fresh code would leave the member's objective
                    // mirrors unresolvable. Placement rides the sender's own
                    // copy: both instances run the same POI. Only the sender's
                    // own live instance qualifies, so a code the sender does
                    // not run (spoofed or stale) creates no member entry.
                    const own = systems.questFindByCode(&self.sim, c.slot, head.quest_code) orelse {
                        if (cl.peer) |tp| try self.sendGame(tp, "NetPackageSharedQuest", body);
                        break;
                    };
                    _ = systems.questAcceptWithCode(&self.sim, cl.slot, own.def_id, head.quest_code, own.poi);
                    if (systems.questFindByCode(&self.sim, cl.slot, head.quest_code)) |ms| ms.is_shared = true;
                    if (cl.peer) |tp| try self.sendGame(tp, "NetPackageSharedQuest", body);
                    break;
                }
            }
        } else if (head.event == .remove_quest) {
            // Event 1 is sent by the quest OWNER whose client dropped its own
            // (non-shared) quest (QuestJournal.HandlePartyRemoveQuest client
            // branch: Setup(questCode, OwnerPlayer.entityId)). Stock's
            // ProcessPackage case 1 server branch (IL_0076) resolves
            // sharedByEntityID, requires that player to hold a Party, and
            // re-broadcasts the remove to every OTHER party member (remote ones
            // get the package, local ones run RemoveSharedQuestByOwner/Entry);
            // the sender is excluded. zdtd echoed the body back to the sender
            // and told the party nothing. Refuse a sender naming someone else
            // (anti-spoof) before any journal mutation, then fan out.
            if (head.shared_by_entity_id != c.entity_id) {
                self.harness.counters.inc(.ownership_rejects);
                return true;
            }
            // Prefer stock Quest.QuestCode; fall back to catalog def_id for old clients.
            if (head.quest_code != 0) {
                if (systems.questFindByCode(&self.sim, c.slot, head.quest_code)) |s| {
                    s.active = false;
                    s.completed = false;
                } else if (head.quest_code > 0 and head.quest_code <= 65535) {
                    if (systems.questFindActive(&self.sim, c.slot, @intCast(head.quest_code))) |s| {
                        s.active = false;
                        s.completed = false;
                    }
                }
            }
            if (self.parties.partyByMember(head.shared_by_entity_id)) |p| {
                for (p.members[0..p.n]) |m| {
                    if (m == head.shared_by_entity_id) continue;
                    if (self.clientByEntityId(m)) |member| {
                        if (member.peer) |mp| try self.sendGame(mp, "NetPackageSharedQuest", body);
                    }
                }
            }
        } else {
            // add_shared_member (2) / remove_shared_member (3). Stock sends
            // these from the MEMBER's QuestJournal, not the owner's:
            // QuestJournal.il passes sharedBy = Quest.SharedOwnerID and
            // sharedWith = OwnerPlayer.entityId (RemoveQuest IL=74 and the
            // accept path near IL=420), then ProcessPackage case 2/3
            // (IL_019D/IL_0340) resolves sharedByEntityID, requires that
            // player to hold a Party, and delivers the package to
            // sharedByEntityID's client (SendPackage _attachedToEntityId =
            // ldloc.1 at IL_028A), which applies Quest.AddSharedWith /
            // RemoveSharedWith. zdtd required the sender to BE the owner and
            // echoed the body back to the sender, so a member accepting or
            // dropping a shared quest was counted ownership_rejects and the
            // owner never heard about it. Gate on the sender naming itself as
            // the member (sharedWith) and deliver to the owner (sharedBy).
            const by = head.shared_by_entity_id;
            if (head.shared_with_entity_id != c.entity_id) {
                self.harness.counters.inc(.ownership_rejects);
                return true;
            }
            if (self.parties.partyByMember(by) == null) return true;
            for (&self.clients) |*cl| {
                if (!cl.joined or cl.entity_id != by) continue;
                if (cl.peer) |op| try self.sendGame(op, "NetPackageSharedQuest", body);
                break;
            }
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackagePartyQuestChange")) {
        const q = packages.parsePartyQuestChange(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        if (q.sender_entity != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        const p = self.parties.partyByMember(c.entity_id) orelse return true;
        for (p.members[0..p.n]) |m| {
            if (m == c.entity_id) continue;
            if (self.clientByEntityId(m)) |member| {
                if (member.peer) |mp| {
                    self.sendGame(mp, "NetPackagePartyQuestChange", body) catch |err| {
                        self.harness.counters.inc(.net_send_errors);
                        std.debug.print("zdtd: send PartyQuestChange failed: {s}\n", .{@errorName(err)});
                    };
                }
            }
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackagePartyActions")) {
        try self.handlePartyActions(c, body);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackagePartyData")) {
        self.harness.counters.inc(.ownership_rejects);
        return true;
    }
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
            if (cl.peer == null) continue;
            if (wp.invite_mode == 0) {
                const target_id = cl.puid_primary.get() orelse continue;
                if (!self.allies.isAlly(inviter_id, target_id)) continue;
            }
            const relay = packages.buildWaypointInviteBody(self.body_buf[0..512], &wp, c.entity_id) catch continue;
            self.sendGame(cl.peer.?, "NetPackageWaypoint", relay) catch |err| {
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
    if (std.mem.eql(u8, name, "NetPackageAddRemoveBuff")) {
        // Rate gate: an accepted add relays the buff to every peer
        // (relayBuff broadcastExcept); unthrottled a spam loop fans the
        // relay out for free while flipping the buff set (bandwidth DoS).
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        try self.handleAddRemoveBuff(c, body);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageQuestEvent")) {
        try self.handleQuestEvent(peer, c, body);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageQuestObjectiveUpdate")) {
        // Stock wire: treasure/block objective events mirror the client's
        // own quest progress into the server journal (so it persists and
        // can coordinate). block_activated advances the block_activate
        // phase; treasure_complete advances the fetch phase (the client dug
        // the chest / finished the fetch), so a treasure/fetch quest reaches
        // turn-in through its real event instead of the old kill-loot hack.
        // treasure_radius_break is mid-dig progress: the client shrank the
        // dig radius, which triggers the quest's TreasureRadiusReduction
        // event: roll its chance and fire the nested SpawnGSEnemy ambush
        // (stock QuestClass TreasureRadiusReduction event; quests.xml
        // `chance 0.25` with 1-3 SleeperGSList enemies per radius step).
        // Also accept legacy zdtd-native {def_id u16, op u8} for unit fixtures.
        if (packages.parseQuestObjectiveUpdate(body)) |u| {
            switch (u.event_type) {
                .block_activated => _ = systems.questObjectiveEvent(&self.sim, c.slot, u.quest_code, .block_activate),
                .treasure_complete => _ = systems.questObjectiveEvent(&self.sim, c.slot, u.quest_code, .fetch_item),
                .treasure_radius_break => questTreasureRadiusBreak(self, c.slot, u.quest_code),
            }
            // Stock re-broadcasts to the sender's party only for the two
            // events whose HandlePlayer acts (ProcessPackage IL=180): case 0
            // treasure_radius_break and case 2 block_activated. Case 1
            // treasure_complete is server-local and does NOT fan out: the
            // server calls QuestEventManager.FinishTreasureQuest(questCode,
            // sender), and HandlePlayer ignores the event entirely (its
            // switch falls through at IL_0074). The two fan-out Setups differ
            // on the wire: case 0 uses the 3-arg Setup, which resets blockPos
            // to Vector3i.zero (Setup IL=14), while case 2 uses the 4-arg
            // Setup and keeps it. Relaying the raw inbound body would leak the
            // dig position into the case 0 relay, so rebuild that one.
            if (u.event_type != .treasure_complete) {
                if (self.parties.partyByMember(c.entity_id)) |p| {
                    for (p.members[0..p.n]) |m| {
                        if (m == c.entity_id) continue;
                        const member = self.clientByEntityId(m) orelse continue;
                        if (u.event_type == .block_activated) {
                            _ = systems.questObjectiveEvent(&self.sim, member.slot, u.quest_code, .block_activate);
                        }
                        if (member.peer) |mp| {
                            const relay: []const u8 = if (u.event_type == .treasure_radius_break)
                                packages.buildQuestObjectiveUpdate(&self.body_buf, .{
                                    .sender_entity_id = u.sender_entity_id,
                                    .quest_code = u.quest_code,
                                    .event_type = .treasure_radius_break,
                                }) catch continue
                            else
                                body;
                            self.sendGame(mp, "NetPackageQuestObjectiveUpdate", relay) catch |err| {
                                self.harness.counters.inc(.net_send_errors);
                                std.debug.print("zdtd: send QuestObjectiveUpdate relay failed: {s}\n", .{@errorName(err)});
                            };
                        }
                    }
                }
            }
        } else |_| {
            if (packages.parseQuestOp(body)) |op| {
                if (op.op == 1) _ = self.acceptQuestFor(c, op.def_id);
            } else |_| {}
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageNPCQuestList")) {
        // Stock trader quest-list exchange: FetchList with QuestPacketEntry offers.
        const head = packages.parseNpcQuestList(body) catch packages.NpcQuestListHead{
            .npc_entity_id = 0,
            .player_entity_id = c.entity_id,
            .event_type = .fetch_list,
        };
        var tx: f32 = 0;
        var ty: f32 = quest_giver_fallback_y;
        var tz: f32 = 0;
        if (self.sim.slotOfNetId(head.npc_entity_id)) |ni| {
            if (self.sim.mask[ni].transform) {
                tx = self.sim.transform[ni].x;
                ty = self.sim.transform[ni].y;
                tz = self.sim.transform[ni].z;
                // Same reach gate as the trade, the TraderData echo and the
                // window open ([sim] trader_use_range): the remove_quest arm
                // below accepts an offer into the journal, so an ungated list
                // exchange hands out quests from every trader on the map.
                // An id that names nothing keeps the fallback marker position
                // and grants nothing, so only a resolved NPC is checked.
                if (!self.inTradeReach(c, tx, ty, tz)) {
                    self.harness.counters.inc(.bounds_rejects);
                    return true;
                }
            }
        }
        // max_quest_tier (quests.xml root): stock clamps the offered tier
        // window to the declared maximum (accept + offer paths below).
        const req_tier: u8 = blk: {
            const mt = self.sim.catalog.max_tier;
            // Clamp: tier_level is a raw wire i32 and a hostile value above
            // 255 would trap the u8 cast; any tier above the stock max is
            // nonsense, so the max_tier comparison below picks mt anyway.
            const tl: u8 = @intCast(@min(@max(head.tier_level, 0), 255));
            if (mt > 0 and tl > mt) break :blk mt;
            break :blk tl;
        };
        if (head.event_type == .remove_quest) {
            // Stock accept marker (asm.il 827746-827975): the client took
            // the removeIndex'th offer, filtered by DifficultyTier and
            // non-active quests. Accept it into the journal and re-send the
            // list without it, so the client stops offering it.
            if (self.sim.catalog.listById(self.traderQuestList(head.npc_entity_id))) |list| {
                var idx: u32 = 0;
                for (list.entries) |qid| {
                    const d = self.sim.catalog.byId(qid) orelse continue;
                    if (d.name.len == 0 or !self.isStockClientQuestName(d.name)) continue;
                    if (d.difficulty_tier != req_tier) continue;
                    const ps = self.sim.playerByPeer(c.slot) orelse break;
                    if (self.sim.mask[ps].journal and self.sim.journal[ps].hasActive(qid)) continue;
                    if (idx == head.remove_index) {
                        _ = self.acceptQuestFor(c, qid);
                        // Quest giver for PositionDataTypes.QuestGiver (0):
                        // the trader that offered the quest, so the client's
                        // return-to-giver marker points at the real NPC.
                        if (self.sim.playerByPeer(c.slot)) |pslot| {
                            if (self.sim.mask[pslot].journal) {
                                if (self.sim.journal[pslot].findActive(qid)) |qs| {
                                    qs.giver_x = tx;
                                    qs.giver_y = ty;
                                    qs.giver_z = tz;
                                }
                            }
                        }
                        break;
                    }
                    idx += 1;
                }
            }
            var offers: [8]packages.stock_quest.QuestPacketEntry = undefined;
            const on = self.buildTraderQuestOffers(self.traderQuestList(head.npc_entity_id), c.slot, tx, ty, tz, @intCast(@max(req_tier, 0)), &offers);
            const body_out = try packages.buildNpcQuestListFetch(
                self.body_buf[0..2048],
                head.npc_entity_id,
                if (head.player_entity_id != 0) head.player_entity_id else c.entity_id,
                head.tier_level,
                offers[0..on],
            );
            try self.sendGame(peer, "NetPackageNPCQuestList", body_out);
            return true;
        }
        if (head.event_type == .fetch_list or head.event_type == .reset_quests) {
            var offers: [8]packages.stock_quest.QuestPacketEntry = undefined;
            const on = self.buildTraderQuestOffers(self.traderQuestList(head.npc_entity_id), c.slot, tx, ty, tz, @intCast(@max(req_tier, 0)), &offers);
            const body_out = try packages.buildNpcQuestListFetch(
                self.body_buf[0..2048],
                head.npc_entity_id,
                if (head.player_entity_id != 0) head.player_entity_id else c.entity_id,
                head.tier_level,
                offers[0..on],
            );
            try self.sendGame(peer, "NetPackageNPCQuestList", body_out);
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageTraderData")) {
        // Stock ToServer body (asm.il 843046): isEntity | entityId /
        // tePosition | hasTraderData | TraderData::Write. A real client's
        // post-trade copy is length-distinguishable from the loadgen/sim
        // 9-byte trade body (which is exactly 9 bytes).
        if (body.len > 9 and body[0] <= 1) {
            if (packages.parseTraderDataToServer(body) catch null) |td| {
                if (td.has_trader_data) {
                    try self.applyTraderDataCopyFrom(c, td);
                    return true;
                }
            }
        }
        // Exactly 9, not >= 9: a stock ToServer body with isEntity=false and
        // hasTraderData=false is 14 bytes, and its body[8] is the high byte of
        // te_y, which is 0 for any real world coordinate. With >= 9 that body
        // fell through to the trade arm and was decoded as a trade whose qty
        // came from two te_y bytes.
        if (body.len == 9 and (body[8] == 0 or body[8] == 1)) {
            try self.handleTrade(c, body);
            return true;
        }
        // Same reach gate as the trade and the TraderData echo. Opening the
        // window advances trader_interact phases, turns in a ready quest and
        // pays its rewards, so without this a player could farm every quest
        // turn-in on the map by naming targets from spawn. The header decides
        // what the leading bytes mean: an entity id when isEntity, otherwise
        // the tile-entity position (a vending machine). The zdtd short open
        // body carries neither, so it has no position to check.
        if (packages.parseTraderDataToServer(body) catch null) |open| {
            if (open.is_entity) {
                const ni = self.sim.slotOfNetId(open.entity_id) orelse return true;
                if (!self.sim.mask[ni].transform) return true;
                const np = self.sim.transform[ni];
                if (!self.inTradeReach(c, np.x, np.y, np.z)) {
                    self.harness.counters.inc(.bounds_rejects);
                    return true;
                }
            } else if (!self.inTradeReach(
                c,
                @floatFromInt(open.te_x),
                @floatFromInt(open.te_y),
                @floatFromInt(open.te_z),
            )) {
                self.harness.counters.inc(.bounds_rejects);
                return true;
            }
        }
        // Stock trader quest offers (npc from open body when present).
        const npc_id: i32 = if (body.len >= 4) std.mem.readInt(i32, body[0..4], .little) else 0;
        systems.questOnTraderOpen(&self.sim, c.slot);
        // Server-side catalog accept for loadgen/sim; stock UI uses NPCQuestList.
        if (self.sim.catalog.listById(self.traderQuestList(npc_id))) |list| {
            for (list.entries) |qid| {
                if (self.acceptQuestFor(c, qid)) break;
            }
        }
        try self.sendTraderSnapshot(peer, null);
        var offers: [8]packages.stock_quest.QuestPacketEntry = undefined;
        var tx: f32 = 0;
        var ty: f32 = quest_giver_fallback_y;
        var tz: f32 = 0;
        if (self.sim.slotOfNetId(npc_id)) |ni| {
            if (self.sim.mask[ni].transform) {
                tx = self.sim.transform[ni].x;
                ty = self.sim.transform[ni].y;
                tz = self.sim.transform[ni].z;
            }
        }
        const on = self.buildTraderQuestOffers(self.traderQuestList(npc_id), c.slot, tx, ty, tz, 0, &offers);
        const qbody = try packages.buildNpcQuestListFetch(
            self.body_buf[512..2560],
            npc_id,
            c.entity_id,
            0,
            offers[0..on],
        );
        try self.sendGame(peer, "NetPackageNPCQuestList", qbody);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackagePlayerVendingMachine")) {
        // Vending rent / clear (loot-economy.md §6, asm.il 833593):
        // removing=false rents (or extends) the machine for the sender;
        // removing=true clears ownership. Server-authoritative: only the
        // sender's own identity may act, rent costs TraderInfo.RentCost
        // currency, and the rental term is 30 in-game days.
        var plat_buf: [packages.platform_user.max_platform_len]u8 = undefined;
        var id_buf: [packages.platform_user.max_id_len]u8 = undefined;
        const acc = packages.parseVendingMachineAccess(body, &plat_buf, &id_buf) catch return true;
        const mine = c.puid_primary.get() orelse c.puid_native.get() orelse return true;
        if (!acc.user.eql(mine)) return true;
        const key: vending_mod.PosKey = .{ .x = acc.x, .y = acc.y, .z = acc.z };
        const vm = self.vending.get(key) orelse return true;
        const day = self.sim.director.clock.day;
        // Expired rentals clear first (currentDay > rental_end_day).
        if (vm.rental_end_day > 0 and day > vm.rental_end_day) vm.clear();
        if (acc.removing) {
            // Stock TryRemoveVendingMachinePosition acts on the sender's
            // own per-player list: only the owner may clear the machine.
            if (!vm.owner.matches(acc.user)) return true;
            vm.clear();
            try replicate_te.sendVendingTe(self, peer, acc.x, acc.y, acc.z);
            return true;
        }
        const info = self.traders.traderInfo(@intCast(vm.trader_id)) orelse return true;
        if (!info.rentable) return true;
        if (vm.rental_end_day > 0 and !vm.owner.matches(acc.user)) return true; // other owner (CanRent 1)
        const coins = self.coinItemId();
        if (coins == 0) return true;
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        if (!self.sim.mask[ps].wallet) return true;
        // One machine per player (CanRent 2, checkAlreadyRentingVM).
        if (vm.rental_end_day == 0) {
            for (self.vending.items[0..], self.vending.used[0..]) |*other, u| {
                if (!u) continue;
                if (&other.* == vm) continue;
                if (other.rental_end_day > 0 and other.owner.matches(acc.user)) return true;
            }
        }
        // Sync wallet from inventory coins (same rule as trade).
        if (self.sim.mask[ps].inventory) {
            const inv_coins = self.sim.inventory[ps].countItem(coins);
            if (inv_coins > self.sim.wallet[ps].coins) self.sim.wallet[ps].coins = inv_coins;
        }
        const cost: u32 = @intCast(@max(0, info.rent_cost));
        if (self.sim.wallet[ps].coins < cost) return true; // insufficient currency (CanRent 3)
        if (self.sim.mask[ps].inventory) {
            const have = self.sim.inventory[ps].countItem(coins);
            // removeItem takes a u16 count; a wallet synced from many coin
            // stacks can hold more than 65535, so drain in u16 chunks rather
            // than truncating the cast.
            const from_inv: u32 = @min(have, cost);
            if (from_inv > 0) {
                var left: u32 = from_inv;
                while (left > 0) {
                    const chunk: u16 = @intCast(@min(left, @as(u32, std.math.maxInt(u16))));
                    if (!self.sim.inventory[ps].removeItem(coins, chunk)) return true;
                    left -= chunk;
                }
            }
        }
        self.sim.wallet[ps].coins -= cost;
        vm.owner.set(acc.user) catch return true;
        // Stock term: RentTimeInDays (trader_info rent_time; Table default 30).
        // Explicit 0 / negative still floors to 30 (stock ctor default).
        const term: i32 = if (info.rent_time > 0) info.rent_time else 30;
        const day_i: i32 = @intCast(day);
        vm.rental_end_day = if (vm.rental_end_day > 0) vm.rental_end_day + term else day_i + term;
        vm.rentable = info.rentable;
        // The owning player sees its machine's stock; re-send the TE.
        try replicate_te.sendVendingTe(self, peer, acc.x, acc.y, acc.z);
        return true;
    }
    return false;
}

/// TreasureRadiusReduction quest event (stock QuestClass events): each
/// treasure-dig radius step the client reports (`treasure_radius_break`)
/// rolls the quest's event `chance` and fires the nested SpawnGSEnemy ambush
/// around the player (quests.xml: chance 0.25, 1-3 SleeperGSList enemies).
/// Deterministic per (world time, quest code, step); the Game spawn hook owns
/// the gamestage resolution.
fn questTreasureRadiusBreak(self: *Game, peer_slot: usize, quest_code: i32) void {
    const s = systems.questFindByCode(&self.sim, peer_slot, quest_code) orelse return;
    const d = self.sim.catalog.byId(s.def_id) orelse return;
    var i: usize = 0;
    while (i < @min(@as(usize, d.event_n), ecs.quest.max_quest_events)) : (i += 1) {
        const ev = d.events[i];
        if (ev.spawn_list.len == 0) continue;
        var rng = rng_util.XorShift32.initFromNetId(
            @bitCast(@as(u32, @truncate(self.sim.director.clock.worldTimeBits())) ^ @as(u32, @bitCast(quest_code))),
        );
        const roll = @as(f32, @floatFromInt(rng.nextBounded(1000))) / 1000.0;
        if (ev.chance > 0 and roll >= ev.chance) continue;
        if (self.sim.quest_spawn_fn) |f| {
            const ps = self.sim.playerByPeer(peer_slot) orelse return;
            f(
                self.sim.quest_spawn_ctx,
                s.poi,
                ev.spawn_list,
                ev.spawn_min,
                ev.spawn_max,
                self.sim.transform[ps].x,
                self.sim.transform[ps].z,
            );
        }
        return; // one event fires per radius step
    }
}
