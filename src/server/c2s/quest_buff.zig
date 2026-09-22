//! C2S quest arms: buff add/remove, quest events, objective updates.
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
const rng_util = @import("../../util/rng.zig");

/// Deterministic per (world time, quest code, step); the Game spawn hook owns
/// the gamestage resolution.
///
/// Idempotent against redelivery: the same world-time report is dropped, and
/// steps are capped at stock `DefaultTreasureRadius` (9) so a spammy client
/// cannot unbounded-spawn ambushes for one dig.
fn questTreasureRadiusBreak(self: *Game, peer_slot: usize, quest_code: i32) void {
    const s = systems.questFindByCode(&self.sim, peer_slot, quest_code) orelse return;
    const d = self.sim.catalog.byId(s.def_id) orelse return;
    const wt = self.sim.director.clock.worldTimeBits();
    // Same world-time redelivery (client retry before the clock advances).
    if (s.treasure_radius_steps > 0 and s.last_treasure_radius_wt == wt) return;
    // Stock ObjectiveTreasureChest ctor (~982843): DefaultTreasureRadius = 9,
    // blocksPerReduction = 1.
    const max_treasure_radius_steps: u8 = 9;
    if (s.treasure_radius_steps >= max_treasure_radius_steps) return;
    s.treasure_radius_steps += 1;
    s.last_treasure_radius_wt = wt;
    var i: usize = 0;
    while (i < @min(@as(usize, d.event_n), ecs.quest.max_quest_events)) : (i += 1) {
        const ev = d.events[i];
        if (ev.spawn_list.len == 0) continue;
        var rng = rng_util.XorShift32.initFromNetId(
            @bitCast(@as(u32, @truncate(wt)) ^ @as(u32, @bitCast(quest_code)) ^ (@as(u32, s.treasure_radius_steps) << 16)),
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

/// True when `name` is a buff/quest-update package and was handled.
pub fn handleBuff(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
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
    return false;
}
