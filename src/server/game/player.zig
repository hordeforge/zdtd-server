//! Player progression / gamestage / XP — extracted from game.zig; helpers take *Game.
//!
//! Extracted from game.zig following the chunk_stream / replicate_te / persist /
//! game_net precedent: helpers take `*Game` as first param and are called as
//! `game_player.awardXp(g, slot, base)`. game.zig keeps one-line forwarders so
//! existing callers/tests stay unchanged.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const packages = @import("../../wire/packages.zig");
const assets_gamestages = @import("../../assets/gamestages.zig");

const max_clients = game_mod.max_clients;

/// GameStats[54] party_shared_kill_range (stock default 100; no V3.1.0
/// serverconfig key, so it rides the GameStats blob default).
const party_shared_kill_range_sq: f32 = 100.0 * 100.0;

/// Award XP to a client's server-side ledger, scaled by XPMultiplier.
/// Levels up using progression.xml exp curve when loaded.
pub fn awardXp(self: *Game, slot: usize, base: u64) void {
    if (slot >= self.clients.len) return;
    const c = &self.clients[slot];
    c.xp += base * self.xp_multiplier / 100;
    // Compute the current cumulative threshold once, then advance it as
    // levels are crossed. Re-summing from level one on every iteration is
    // quadratic for large XP awards.
    var next_threshold: u64 = 0;
    var level: u16 = 1;
    while (level <= c.level) : (level += 1) {
        next_threshold += self.progression.expForLevel(level);
    }
    while (c.level < self.progression.max_level) {
        if (c.xp < next_threshold) break;
        c.level += 1;
        next_threshold += self.progression.expForLevel(c.level);
    }
}

/// Party.GetPartyXP + GameManager.SharedKillServer (parties-factions.md
/// §2.3): the killer's XP is `base * (1 - 0.1 * MemberCountInRange)` where
/// MemberCountInRange counts the other members within GameStats[54]
/// (party_shared_kill_range, stock default 100); every other in-range
/// member gets the same split XP through NetPackageSharedPartyKill so the
/// client shows the shared-kill tooltip. Out of party the award is full.
pub fn killXpAward(self: *Game, killer_slot: usize, base: u64) void {
    const killer = &self.clients[killer_slot];
    const party = self.parties.partyByMember(killer.entity_id);
    var in_range: u8 = 0;
    if (party) |p| {
        if (self.sim.playerByPeer(killer_slot)) |ks| {
            const kt = self.sim.transform[ks];
            for (p.members[0..p.n]) |m| {
                if (m == killer.entity_id) continue;
                const ms = self.sim.slotOfNetId(m) orelse continue;
                if (!self.sim.mask[ms].transform) continue;
                const dx = self.sim.transform[ms].x - kt.x;
                const dz = self.sim.transform[ms].z - kt.z;
                if (dx * dx + dz * dz <= party_shared_kill_range_sq) in_range += 1;
            }
        }
    }
    const split: u64 = if (party != null)
        base * (100 - 10 * @as(u64, in_range)) / 100
    else
        base;
    awardXp(self, killer_slot, split);
    if (party) |p| {
        for (p.members[0..p.n]) |m| {
            if (m == killer.entity_id) continue;
            if (self.clientByEntityId(m)) |mate| {
                awardXp(self, mate.slot, split);
                if (mate.peer) |peer| {
                    if (packages.stock_party.buildSharedKillBody(&self.body_buf, .{
                        .entity_type = 3, // zombieEntity (class hash name in stock; ECD carries the class)
                        .xp = @intCast(@min(split, std.math.maxInt(i32))),
                        .entity_id = killer.entity_id,
                        .killer_id = killer.entity_id,
                    })) |skb| {
                        self.sendGame(peer, "NetPackageSharedPartyKill", skb) catch |err| {
                            self.harness.counters.inc(.net_send_errors);
                            std.debug.print("zdtd: send SharedPartyKill failed: {s}\n", .{@errorName(err)});
                        };
                    } else |_| {}
                }
            }
        }
    }
}

/// EntityPlayer::get_gameStage for one client (asm.il ~503972). Biome and
/// quest modifiers are zero: biomes.xml GameStageMod/Bonus and quests.xml
/// GameStageMod/Bonus are not parsed yet (docs/GAP_ANALYSIS.md).
pub fn gameStageOf(self: *const Game, slot: usize) i32 {
    if (slot >= self.clients.len) return 1;
    const c = &self.clients[slot];
    const now = self.sim.director.clock.worldTimeBits();
    return assets_gamestages.playerStage(self.gamestages.config, .{
        .level = c.level,
        .days_alive = assets_gamestages.daysAlive(now, c.game_stage_born_world_time, c.level),
    });
}

/// EntityPlayer::GetLootStage for one client (asm.il ~504215): level driven,
/// with no POI tier or biome terms until those tables are parsed.
pub fn lootStageOf(self: *const Game, slot: usize) i32 {
    if (slot >= self.clients.len) return 1;
    return assets_gamestages.lootStage(.{ .level = self.clients[slot].level });
}

/// GameStageDefinition::CalcGameStageAround (asm.il ~1093351): party stage
/// over joined players within `radius` of (wx,wz). Stock also requires the
/// same PrefabInstance; zdtd has no per-player POI tracking, so distance
/// alone decides. Pass a negative radius for "every joined player".
pub fn partyStageAround(self: *const Game, wx: f32, wz: f32, radius: f32) i32 {
    var stages: [max_clients]i32 = undefined;
    var n: usize = 0;
    for (&self.clients, 0..) |*c, i| {
        if (!c.joined) continue;
        if (radius >= 0) {
            const ps = self.sim.playerByPeer(c.slot) orelse continue;
            const dx = self.sim.transform[ps].x - wx;
            const dz = self.sim.transform[ps].z - wz;
            if (dx * dx + dz * dz > radius * radius) continue;
        }
        stages[n] = gameStageOf(self, i);
        n += 1;
    }
    if (n == 0) return 0;
    return assets_gamestages.partyLevel(self.gamestages.config, stages[0..n]);
}

/// EntityPlayer::GetHighestPartyLootStage (asm.il ~504467) over all joined
/// clients. Container contents are shared world state, so a per-viewer
/// stage would make the same chest differ between clients; the party high
/// water mark is both stock-shaped and viewer independent.
pub fn partyLootStage(self: *const Game) i32 {
    var best: i32 = 1;
    for (&self.clients, 0..) |*c, i| {
        if (!c.joined) continue;
        best = @max(best, lootStageOf(self, i));
    }
    return best;
}

/// Party.GetHighestLootStage for one player: the max loot stage across the
/// player's party members, or the player alone when ungrouped. World-gen
/// fills with no player context keep the global partyLootStage.
pub fn lootStageForPlayer(self: *Game, peer_slot: usize) i32 {
    if (peer_slot >= self.clients.len or !self.clients[peer_slot].joined) return partyLootStage(self);
    const me = self.clients[peer_slot].entity_id;
    var best: i32 = 1;
    if (self.parties.partyByMember(me)) |p| {
        for (p.members[0..p.n]) |m| {
            if (self.clientByEntityId(m)) |mc| {
                best = @max(best, lootStageOf(self, mc.slot));
            }
        }
        return best;
    }
    return @max(1, lootStageOf(self, peer_slot));
}
