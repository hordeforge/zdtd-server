//! C2S quest arms: land-claim repair, shared quests, party actions.
//!
//! Split out of c2s/quest.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");
const c2s_text = @import("../c2s_text.zig");
const replicate_te = @import("../game/replicate_te.zig");

/// Fallback quest-giver marker Y when the trader NPC is not yet in the sim
/// (the marker snaps to the real transform once the entity loads). A
/// plausible ground height, not stock data; the giver marker is client-side.
pub const quest_giver_fallback_y: f32 = 70;

/// True when `name` is a party/quest-share package and was handled.
pub fn handleParty(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
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
    return false;
}
