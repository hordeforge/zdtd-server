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
const assets_biome_layers = @import("../../assets/biome_layers.zig");
const ecs_party = @import("../../ecs/party.zig");

const max_clients = game_mod.max_clients;

/// GameStats[54] party_shared_kill_range (stock default 100; no V3.1.0
/// serverconfig key, so it rides the `[sim] party_shared_kill_range` surface).

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
        // Level-up refreshes the EntityNetworkStats snapshot the peers hold:
        // stock's NED dirty path pushes PlayerStats when progression changes.
        broadcastPlayerStats(self, slot);
    }
}

/// Push the player's NetPackagePlayerStats snapshot to every connected peer
/// (stock NED dirty path on progression change). The player's own client
/// derives its level locally from AddExpClient, so self is excluded.
pub fn broadcastPlayerStats(self: *Game, slot: usize) void {
    if (slot >= self.clients.len) return;
    const c = &self.clients[slot];
    if (c.peer == null or c.entity_id <= 0 or c.name_len == 0) return;
    const exp_to_next: i32 = @intCast(@min(
        self.progression.expForLevel(@min(c.level, self.progression.max_level)),
        std.math.maxInt(i32),
    ));
    if (packages.stock_xp.buildPlayerStatsBody(self.body_buf[32..160], .{
        .entity_id = c.entity_id,
        .entity_name = c.name[0..c.name_len],
        .level = c.level,
        .exp_to_next = exp_to_next,
    })) |psb| {
        for (&self.clients) |*cl| {
            if (!cl.joined or cl.peer == null or cl.entity_id == c.entity_id) continue;
            if (cl.peer) |p| self.sendGame(p, "NetPackagePlayerStats", psb) catch {};
        }
    } else |_| {}
}

/// entityclasses ExperienceGain for the just-killed entity (130 rabbit ..
/// 2500 zombieBear; most zombies resolve through the `^xpNormal01`-style
/// replace_properties ladder). Falls back to the flat zdtd floor when the
/// class did not resolve one (offline/builtin catalog, or the slot already
/// recycled).
pub fn xpGainFor(self: *Game, victim_nid: i32) u64 {
    if (self.sim.slotOfNetId(victim_nid)) |s| {
        const g = self.sim.class_id[s].xp_gain;
        if (g > 0) return @trunc(g);
    }
    return 100;
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
                if (dx * dx + dz * dz <= self.party_shared_kill_range * self.party_shared_kill_range) in_range += 1;
            }
        }
    }
    const split: u64 = if (party != null)
        base * (100 - 10 * @as(u64, in_range)) / 100
    else
        base;
    awardXp(self, killer_slot, split);
    // Stock sends NetPackageEntityAddExpClient (xpType 0 = Kill) so the
    // killer's client shows the XP icon and applies the gain locally; the
    // party split is server-computed, so the killer cannot derive it alone.
    // Mates get NetPackageSharedPartyKill instead (below), matching stock.
    if (killer.peer) |peer| {
        if (packages.stock_xp.buildAddExpClientBody(&self.body_buf, .{
            .entity_id = killer.entity_id,
            .xp = @intCast(@min(split, std.math.maxInt(i32))),
            .xp_type = packages.stock_xp.xp_type_kill,
        })) |xb| {
            self.sendGame(peer, "NetPackageEntityAddExpClient", xb) catch |err| {
                self.harness.counters.inc(.net_send_errors);
                std.debug.print("zdtd: send AddExpClient failed: {s}\n", .{@errorName(err)});
            };
        } else |_| {}
    }
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

/// EntityPlayer::get_gameStage for one client (asm.il ~503972). The biome
/// terms come from the player's current biome (biomes.xml gamestage_modifier
/// / gamestage_bonus, progression.md 5); quest modifiers are still zero
/// (quests.xml GameStageMod/Bonus not parsed yet, docs/GAP_ANALYSIS.md).
pub fn gameStageOf(self: *const Game, slot: usize) i32 {
    if (slot >= self.clients.len) return 1;
    const c = &self.clients[slot];
    const now = self.sim.director.clock.worldTimeBits();
    const bmods = biomeStageMods(self, slot);
    // QuestClass stage terms (progression.md 5): the active quest's
    // gamestage_mod/bonus multiply/add onto the stage. Stock uses
    // ActiveQuest (the first active journal quest); 7 stock quests carry the
    // terms (infested clears).
    var qmod: f32 = 0;
    var qbonus: f32 = 0;
    if (self.sim.playerByPeer(c.slot)) |ps| {
        if (self.sim.mask[ps].journal) {
            for (self.sim.journal[ps].slots) |q| {
                if (!q.active or q.completed or q.ready_turn_in) continue;
                const qd = self.sim.catalog.byId(q.def_id) orelse continue;
                if (qd.gamestage_mod != 0 or qd.gamestage_bonus != 0) {
                    qmod = qd.gamestage_mod;
                    qbonus = qd.gamestage_bonus;
                    break;
                }
            }
        }
    }
    return assets_gamestages.playerStage(self.gamestages.config, .{
        .level = c.level,
        .days_alive = assets_gamestages.daysAlive(now, c.game_stage_born_world_time, c.level),
        .biome_mod = bmods.game_mod,
        .biome_bonus = bmods.game_bonus,
        .quest_mod = qmod,
        .quest_bonus = qbonus,
    });
}

/// The player's biome stage modifiers (biomes.xml), resolved from the biome
/// map under the client's sim position. Zero default when no biome data.
fn biomeStageMods(self: *const Game, slot: usize) assets_biome_layers.BiomeMods {
    if (slot >= self.clients.len) return .{};
    const c = &self.clients[slot];
    const ps = self.sim.playerByPeer(c.slot) orelse return .{};
    if (!self.sim.mask[ps].transform) return .{};
    const t = self.sim.transform[ps];
    const bm = self.world.biomes orelse return .{};
    const id = bm.atWorld(@floor(t.x), @floor(t.z)) orelse return .{};
    const name = self.world.biome_layers_table.nameById(id) orelse return .{};
    return self.world.biome_layers_table.biomeMods(name);
}

/// EntityPlayer::GetLootStage for one client (asm.il ~504215): level driven,
/// with the biome lootstage terms and no POI tier terms until those tables
/// are parsed.
pub fn lootStageOf(self: *const Game, slot: usize) i32 {
    if (slot >= self.clients.len) return 1;
    const bmods = biomeStageMods(self, slot);
    // POITierMod/Bonus (loot_settings, indexed DifficultyTier-1): the tier of
    // the POI the player stands in scales the loot stage (RE GetLootStage,
    // asm.il ~504240). Clamped to the settings array; no POI/tier = 0.
    var poi_mod: f32 = 0;
    var poi_bonus: f32 = 0;
    if (self.sim.poi_tier_fn) |f| {
        if (self.sim.playerByPeer(self.clients[slot].slot)) |ps| {
            if (self.sim.mask[ps].transform) {
                const t = self.sim.transform[ps];
                const tier = f(self.sim.poi_tier_ctx, t.x, t.z);
                if (tier >= 1) {
                    const idx: usize = @intCast(tier - 1);
                    if (idx < self.loot.poi_tier_mod.len) poi_mod = self.loot.poi_tier_mod[idx];
                    if (idx < self.loot.poi_tier_bonus.len) poi_bonus = self.loot.poi_tier_bonus[idx];
                }
            }
        }
    }
    return assets_gamestages.lootStage(.{
        .level = self.clients[slot].level,
        .poi_tier_mod = poi_mod,
        .poi_tier_bonus = poi_bonus,
        .biome_mod = bmods.loot_mod,
        .biome_bonus = bmods.loot_bonus,
    });
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

/// Party.get_HighestGameStage (parties-factions.md "Group gamestage /
/// loot"): the max member game stage of the largest party, or of all joined
/// players when nobody is grouped. Stock feeds this to the blood-moon
/// director and horde difficulty, which scale to the group high water mark
/// rather than the weighted CalcPartyLevel. Sleeper volumes keep
/// partyStageAround (CalcGameStageAround) below.
pub fn partyHighestGameStage(self: *Game) i32 {
    var best: i32 = 0;
    var best_party: ?*const ecs_party.Party = null;
    var best_n: usize = 0;
    for (&self.parties.parties, &self.parties.used) |*p, *u| {
        if (!u.*) continue;
        if (p.n > best_n) {
            best_n = p.n;
            best_party = p;
        }
    }
    if (best_party) |p| {
        for (p.members[0..p.n]) |m| {
            if (self.clientByEntityId(m)) |mc| {
                best = @max(best, gameStageOf(self, mc.slot));
            }
        }
        return @max(1, best);
    }
    for (&self.clients, 0..) |*c, i| {
        if (!c.joined) continue;
        best = @max(best, gameStageOf(self, i));
    }
    return @max(1, best);
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
