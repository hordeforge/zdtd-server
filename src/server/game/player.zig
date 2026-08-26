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
const systems = @import("../../ecs/systems.zig");

const max_clients = game_mod.max_clients;

/// GameStats[54] party_shared_kill_range (stock default 100; no V3.1.0
/// serverconfig key, so it rides the `[sim] party_shared_kill_range` surface).
/// Award XP to a client's server-side ledger, scaled by XPMultiplier.
/// Levels up using progression.xml exp curve when loaded.
pub fn awardXp(self: *Game, slot: usize, base: u64) void {
    if (slot >= self.clients.len) return;
    const c = &self.clients[slot];
    const before_xp = c.xp;
    // Widen before the multiply: base (verdict-scaled) times an operator
    // XPMultiplier can wrap u64 otherwise; the ledger add saturates.
    c.xp +|= @intCast(@min(@as(u128, base) * self.xp_multiplier / 100, @as(u128, std.math.maxInt(u64))));
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
        // Level-up grants skill points (progression.xml skill_points_per_level;
        // RE progression.md: LevelUp -> GrantPoints: player level += 1, skill
        // points += award).
        c.skill_points +|= self.progression.skill_points_per_level;
        // Level-up refreshes the EntityNetworkStats snapshot the peers hold:
        // stock's NED dirty path pushes PlayerStats when progression changes.
        broadcastPlayerStats(self, slot);
    }
    // Stat-changed observer (ADR 0034): the XP/level leg, one call per award.
    if (c.xp != before_xp) {
        const h = &self.sim.health[self.sim.playerByPeer(slot) orelse return];
        self.statChangedObserver( c.entity_id, @intFromFloat(h.hp), @intFromFloat(h.food), @intFromFloat(h.water), @intFromFloat(h.stamina), c.level, @intCast(@min(c.xp, std.math.maxInt(i32))));
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
        .skill_points = @intCast(@min(c.skill_points, 65535)),
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
        if (g > 0) {
            // Clamp before the cast: a modded ExperienceGain past u64 range
            // (finite) traps the float->int conversion. 2^31 is exact in f32.
            return @intFromFloat(@min(@trunc(g), 2147483648.0));
        }
    }
    // Rules floor (progression.kill_xp_fallback) when the class resolved no
    // ExperienceGain (offline/builtin catalog or recycled slot).
    return @intFromFloat(@max(0, self.sim.rules.progression.kill_xp_fallback));
}

/// Party.GetPartyXP + GameManager.SharedKillServer (parties-factions.md
/// §2.3): the killer's XP is `base * (1 - 0.1 * MemberCountInRange)` where
/// MemberCountInRange counts the other members within GameStats[54]
/// (party_shared_kill_range, stock default 100); every other in-range
/// member gets the same split XP through NetPackageSharedPartyKill so the
/// client shows the shared-kill tooltip. Out of party the award is full.
pub fn killXpAward(self: *Game, killer_slot: usize, base: u64, scale_pct: u32) void {
    // on_entity_killed verdict >0 scales the kill XP (100 = keep). base is
    // xpGainFor-clamped to i32 range, so the u64 product cannot overflow.
    const base_scaled: u64 = base * scale_pct / 100;
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
        base_scaled * (100 - 10 * @as(u64, in_range)) / 100
    else
        base_scaled;
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

/// Stock SharedKillServer -> SharedKillClient (IL=65): an in-range party
/// mate's EntityKilled quest event fires for the same kill, so their shared
/// quest copies advance (the same GameStats[54] range as the XP share gates
/// the mate). zdtd journals are per-player; a mate advances when they hold
/// the same quest def active. Wire: the mate's own journal write reaches
/// their client through the regular progress path.
pub fn questKillForParty(self: *Game, killer_slot: usize, vx: f32, vz: f32) void {
    const killer = &self.clients[killer_slot];
    const party = self.parties.partyByMember(killer.entity_id) orelse return;
    if (self.sim.playerByPeer(killer_slot)) |ks| {
        const kt = self.sim.transform[ks];
        for (party.members[0..party.n]) |m| {
            if (m == killer.entity_id) continue;
            const ms = self.sim.slotOfNetId(m) orelse continue;
            if (!self.sim.mask[ms].transform) continue;
            const dx = self.sim.transform[ms].x - kt.x;
            const dz = self.sim.transform[ms].z - kt.z;
            if (dx * dx + dz * dz > self.party_shared_kill_range * self.party_shared_kill_range) continue;
            const mate_peer = self.sim.player[ms].peer_slot;
            if (mate_peer >= 0) {
                systems.questOnZombieKilled(&self.sim, @intCast(mate_peer), vx, vz);
            }
        }
    }
}

/// Stock PlayerStealth.TickServer S2C (IL_0470): every 16 ticks, when the
/// packed stealth state changed, broadcast NetPackageEntityStealth for the
/// player so other clients render the stealth meter. Noise is the sim's
/// CalcVolume fold; alert = any alert zombie within 12 m (stock scan); light
/// stays 0 until the clone-side world-light model lands (RE-blocked,
/// documented).
pub fn tickStealthBroadcast(self: *Game) void {
    if ((self.tick_n % 16) != 0) return;
    for (&self.clients) |*c| {
        if (!c.joined or c.entity_id <= 0) continue;
        const ps = self.sim.playerByPeer(c.slot) orelse continue;
        if (!self.sim.mask[ps].transform) continue;
        const noise = self.sim.stealth[ps].noise_volume;
        const noise8: u8 = @intFromFloat(@min(noise, 127.0));
        const crouch = self.sim.player[ps].crouching;
        var alert = false;
        const px = self.sim.transform[ps].x;
        const pz = self.sim.transform[ps].z;
        for (self.sim.kind_groups.slice(.zombie)) |zs| {
            if (!self.sim.alive[zs] or !self.sim.mask[zs].zombie_ai) continue;
            if (!self.sim.mask[zs].transform or !self.sim.zombie_ai[zs].alert) continue;
            const dx = self.sim.transform[zs].x - px;
            const dz = self.sim.transform[zs].z - pz;
            if (dx * dx + dz * dz <= 12.0 * 12.0) {
                alert = true;
                break;
            }
        }
        if (noise8 == c.stealth_noise_sent and crouch == c.stealth_crouch_sent and alert == c.stealth_alert_sent) continue;
        c.stealth_noise_sent = noise8;
        c.stealth_crouch_sent = crouch;
        c.stealth_alert_sent = alert;
        if (packages.buildEntityStealthBody(self.body_buf[0..16], c.entity_id, 0, noise8, alert, crouch)) |sb| {
            self.broadcastExcept("NetPackageEntityStealth", sb, null) catch |err| {
                self.harness.counters.inc(.net_send_errors);
                std.debug.print("zdtd: EntityStealth broadcast failed: {s}\n", .{@errorName(err)});
            };
        } else |_| {}
    }
}

/// EntityPlayer::get_gameStage for one client (asm.il ~503972). The biome
/// terms come from the player's current biome (biomes.xml gamestage_modifier
/// / gamestage_bonus, progression.md 5) and the quest terms from the active
/// quest (quests.xml gamestage_mod / gamestage_bonus, applied below).
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


/// Purchased level of a progression value (attribute/perk) for a client.
pub fn skillLevelOf(self: *const Game, slot: usize, skill: []const u8) u8 {
    if (slot >= self.clients.len) return 0;
    const c = &self.clients[slot];
    for (c.skill_levels[0..c.skill_level_n]) |sl| {
        if (std.mem.eql(u8, sl.name, skill)) return sl.level;
    }
    return 0;
}

/// CalculatedCostForLevel (stock ProgressionClass; the exact IL rounding is
/// RE-tracked, formula shape from progression.xml base_skill_point_cost x
/// cost_multiplier_per_level^(level-1), standard stock geometric cost).
fn skillCostForLevel(def_cost: u16, mult: f32, level: u8) u32 {
    if (level <= 1) return def_cost;
    var acc: f64 = @as(f64, @floatFromInt(def_cost));
    var i: u8 = 1;
    while (i < level) : (i += 1) acc *= @as(f64, mult);
    const v: u64 = @round(acc);
    return @intCast(@max(1, @min(v, 65535)));
}

/// Catalog-validated cost of buying `skill` at `target_level`, or null when
/// the purchase would be denied (unknown skill, not the next level, already
/// maxed, unmet parent attribute). Mirrors the validation inside
/// purchaseSkillAtCost so the on_perk_spend verdict can scale the cost
/// before the purchase applies (ADR 0033).
pub fn skillCostOf(self: *const Game, slot: usize, skill: []const u8, target_level: u8) ?u32 {
    if (slot >= self.clients.len) return null;
    const cur = self.skillLevelOf(slot, skill);
    if (target_level != cur + 1) return null; // one level per purchase
    const pt = self.progression_table;
    // Resolve the skill: attributes first, then perks.
    var is_attr = false;
    var max_level: u8 = 0;
    var base_cost: u16 = 1;
    var cost_mult: f32 = 1.0;
    for (pt.attributes) |a| {
        if (!std.mem.eql(u8, a.name, skill)) continue;
        is_attr = true;
        max_level = a.max_level;
        base_cost = a.base_cost;
        cost_mult = a.cost_mult;
        break;
    }
    if (!is_attr) {
        var parent: []const u8 = "";
        for (pt.perks) |pk| {
            if (!std.mem.eql(u8, pk.name, skill)) continue;
            max_level = pk.max_level;
            parent = pk.parent_attr;
            break;
        }
        if (max_level == 0) return null; // unknown skill
        if (parent.len > 0 and self.skillLevelOf(slot, parent) == 0) return null;
    }
    if (cur >= max_level) return null;
    return skillCostForLevel(base_cost, cost_mult, target_level);
}

/// Purchase one progression level (NetPackageEntitySetSkillLevelServer,
/// RE progression.md §3 SpendSkillPoints). Validates: known skill, one level
/// at a time, max level, SP balance >= cost, and (for perks) the parent
/// attribute purchased. Applies server-side and echoes
/// NetPackageEntitySetSkillLevelClient. Returns false when denied.
pub fn purchaseSkill(self: *Game, slot: usize, skill: []const u8, target_level: u8) bool {
    return purchaseSkillAtCost(self, slot, skill, target_level, null);
}

/// Purchase with an explicit cost override (the on_perk_spend verdict may
/// scale the catalog cost, ADR 0033); null keeps the catalog cost.
pub fn purchaseSkillAtCost(self: *Game, slot: usize, skill: []const u8, target_level: u8, cost_override: ?u32) bool {
    if (slot >= self.clients.len) return false;
    const c = &self.clients[slot];
    const cost = self.skillCostOf(slot, skill, target_level) orelse return false;
    const eff_cost = cost_override orelse cost;
    if (c.skill_points < eff_cost) return false;
    c.skill_points -= eff_cost;
    var i: usize = 0;
    while (i < c.skill_level_n) : (i += 1) {
        if (std.mem.eql(u8, c.skill_levels[i].name, skill)) {
            c.skill_levels[i].level = target_level;
            return true;
        }
    }
    if (c.skill_level_n < c.skill_levels.len) {
        c.skill_levels[c.skill_level_n] = .{ .name = skill, .level = target_level };
        c.skill_level_n += 1;
        return true;
    }
    return false;
}

const assets_progression_test = @import("../../assets/progression.zig");

test "skill ledger: level-up awards SP; purchase validates, prereqs and spends" {
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_ledger", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    // Minimal progression tree: one attribute + one perk gated on it.
    const attrs = [_]assets_progression_test.AttrDef{
        .{ .name = "attGeneral", .max_level = 10, .base_cost = 1, .cost_mult = 1.14 },
    };
    const perks = [_]assets_progression_test.PerkDef{
        .{ .name = "perkLightEater", .max_level = 5, .parent_attr = "attGeneral" },
    };
    g.progression_table.attributes = &attrs;
    g.progression_table.perks = &perks;
    g.progression.skill_points_per_level = 1;

    // Level up from 1 to 2: skill_points_per_level awarded per new level.
    const level1_xp = g.progression.expForLevel(1);
    g.awardXp(0, level1_xp);
    try std.testing.expectEqual(@as(u16, 2), g.clients[0].level);
    try std.testing.expectEqual(@as(u32, 1), g.clients[0].skill_points);

    // Perk without the parent attribute: prereq denies.
    try std.testing.expect(!g.purchaseSkill(0, "perkLightEater", 1));
    // Unknown skill denies.
    try std.testing.expect(!g.purchaseSkill(0, "notASkill", 1));
    // Buy the attribute first (cost 1 = base), then the perk.
    try std.testing.expect(g.purchaseSkill(0, "attGeneral", 1));
    try std.testing.expectEqual(@as(u8, 1), g.skillLevelOf(0, "attGeneral"));
    try std.testing.expectEqual(@as(u32, 0), g.clients[0].skill_points);
    // Second level would cost base x mult (1.14 -> round 1): still 0 SP.
    try std.testing.expect(!g.purchaseSkill(0, "attGeneral", 2));
    // Perk buys at base cost 1.
    g.clients[0].skill_points = 1;
    try std.testing.expect(g.purchaseSkill(0, "perkLightEater", 1));
    try std.testing.expectEqual(@as(u8, 1), g.skillLevelOf(0, "perkLightEater"));
    try std.testing.expectEqual(@as(u32, 0), g.clients[0].skill_points);
    // Re-purchase of the same level denies (one level per request).
    try std.testing.expect(!g.purchaseSkill(0, "perkLightEater", 1));
    std.debug.print("PASS skill-ledger: SP award, cost, prereq, echo state\n", .{});
}

test "killXpAward scales by the on_entity_killed verdict percent" {
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_killscale", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    // killXpAward(slot, base, scale): 200 base x 150% = 300 (xp_multiplier
    // default 100 keeps 1.0x).
    const before = g.clients[0].xp;
    g.killXpAward(0, 200, 150);
    try std.testing.expectEqual(before + 300, g.clients[0].xp);
    std.debug.print("PASS kill-xp-scale: 200 x 150% = {d}\n", .{g.clients[0].xp - before});
}
