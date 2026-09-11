//! Player progression / gamestage / XP - extracted from game.zig; helpers take *Game.
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
const ecs = @import("../../ecs/root.zig");
const assets_buffs = @import("../../assets/buffs.zig");
const assets_progression = @import("../../assets/progression.zig");
const assets_items = @import("../../assets/items.zig");
const ecs_party = @import("../../ecs/party.zig");
const systems = @import("../../ecs/systems.zig");

const max_clients = game_mod.max_clients;

/// GameStats[54] party_shared_kill_range (stock default 100; no V3.1.0
/// serverconfig key, so it rides the `[sim] party_shared_kill_range` surface).
/// Award XP to a client's server-side ledger, scaled by XPMultiplier.
/// Levels up using progression.xml exp curve when loaded. Non-kill sources
/// (harvest, quest Exp, craft, magazine GiveExp) also push
/// NetPackageEntityAddExpClient as `_xpOther` so the owning client shows
/// the icon; kill XP uses awardXpSilent + a typed Kill packet instead.
pub fn awardXp(self: *Game, slot: usize, base: u64) void {
    awardXpTyped(self, slot, base, packages.stock_xp.xp_type_other);
}

/// Ledger + level-up only. Kill XP and party-share use this so the typed
/// S2C packet (AddExpClient Kill / SharedPartyKill) is the only client notify.
pub fn awardXpSilent(self: *Game, slot: usize, base: u64) void {
    awardXpTyped(self, slot, base, null);
}

fn awardXpTyped(self: *Game, slot: usize, base: u64, notify_type: ?i16) void {
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
        if (self.sim.playerByPeer(slot)) |ps| {
            const h = &self.sim.health[ps];
            self.statChangedObserver(c.entity_id, @trunc(h.hp), @trunc(h.food), @trunc(h.water), @trunc(h.stamina), c.level, @intCast(@min(c.xp, std.math.maxInt(i32))));
        }
        if (notify_type) |xp_type| {
            const granted: i32 = @intCast(@min(c.xp -| before_xp, std.math.maxInt(i32)));
            if (granted > 0 and c.entity_id > 0) {
                if (c.peer) |peer| {
                    if (packages.stock_xp.buildAddExpClientBody(&self.body_buf, .{
                        .entity_id = c.entity_id,
                        .xp = granted,
                        .xp_type = xp_type,
                    })) |xb| {
                        self.sendGame(peer, "NetPackageEntityAddExpClient", xb) catch |err| {
                            self.harness.counters.inc(.net_send_errors);
                            std.debug.print("zdtd: send AddExpClient failed: {s}\n", .{@errorName(err)});
                        };
                    } else |_| {}
                }
            }
        }
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
        .deaths = c.deaths,
        .killed_zombies = c.zombie_kills,
        .killed_players = c.player_kills,
        // Stock fills the whole EntityNetworkStats from the entity, held
        // stack included. Omitting it told every other client the player had
        // just put their weapon away on each progression push.
        .held_item = if (self.sim.playerByPeer(slot)) |ps|
            self.playerHoldingStock(ps)
        else
            null,
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
            return @trunc(@min(@trunc(g), 2147483648.0));
        }
    }
    // Rules floor (progression.kill_xp_fallback) when the class resolved no
    // ExperienceGain (offline/builtin catalog or recycled slot).
    return @trunc(@max(0, self.sim.rules.progression.kill_xp_fallback));
}

/// Party.GetPartyXP + GameManager.SharedKillServer (parties-factions.md
/// §2.3): the killer's XP is `base * (1 - 0.1 * MemberCountInRange)` where
/// MemberCountInRange counts the other members within GameStats[54]
/// (party_shared_kill_range, stock default 100); every other in-range
/// member gets the same split XP through NetPackageSharedPartyKill so the
/// client shows the shared-kill tooltip. Out of party the award is full.
pub fn killXpAward(self: *Game, killer_slot: usize, base: u64, scale_pct: u32, trap_kill: bool, killed_entity_id: i32) void {
    // Stock SharedKillServer (IL=162) builds every mate's
    // NetPackageSharedPartyKill from the killed entity: entityTypeID =
    // entityAlive.entityClass, entityID = entityAlive.entityId, killerID =
    // the killer (Setup IL=14; the client SharedKillClient IL=65 resolves the
    // class for the tooltip and fires EntityKilled on entityID). Read it from
    // the corpse before the dwell sweep frees the slot; 0/unset falls back to
    // the stock default zombie class, matching the spawn wire (replicate.zig).
    const killed_class: i32 = if (self.sim.slotOfNetId(killed_entity_id)) |ks| blk: {
        if (self.sim.mask[ks].class_id and self.sim.class_id[ks].hash != 0) break :blk self.sim.class_id[ks].hash;
        break :blk packages.stock_entity.class_zombie_default;
    } else packages.stock_entity.class_zombie_default;
    // on_entity_killed verdict >0 scales the kill XP (100 = keep). base is
    // xpGainFor-clamped to i32 range, so the u64 product cannot overflow.
    const base_scaled: u64 = base * scale_pct / 100;
    const killer = &self.clients[killer_slot];
    const party = self.parties.partyByMember(killer.entity_id);
    // V3.2.0 (changelog-3.2.0 §4.3): `EntityAlive.PartyShareKillServer`
    // skips the party share when `bTrapKillXP` is set; the
    // [rules.progression] trap_xp_party_share override re-enables it.
    const share_party = !trap_kill or self.sim.rules.progression.trap_xp_party_share;
    var in_range: u8 = 0;
    if (share_party) {
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
    }
    const split: u64 = if (party != null and share_party)
        base_scaled * (100 - 10 * @as(u64, in_range)) / 100
    else
        base_scaled;
    awardXpSilent(self, killer_slot, split);
    // Stock sends NetPackageEntityAddExpClient (xpType 0 = Kill) so the
    // killer's client shows the XP icon and applies the gain locally; the
    // party split is server-computed, so the killer cannot derive it alone.
    // Mates get NetPackageSharedPartyKill instead (below), matching stock.
    // awardXpSilent keeps the ledger from also emitting `_xpOther`.
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
                awardXpSilent(self, mate.slot, split);
                if (mate.peer) |peer| {
                    if (packages.stock_party.buildSharedKillBody(&self.body_buf, .{
                        .entity_type = killed_class,
                        .xp = @intCast(@min(split, std.math.maxInt(i32))),
                        .entity_id = killed_entity_id,
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

/// Stock `GameManager.AwardKill` (IL=27): when the killer is a remote entity
/// the server ships `NetPackageEntityAwardKillServer(killerId, killedId)` to
/// it, and the receiving client runs `QuestEventManager.EntityKilled`
/// (IL=24), which fires its local `EntityKill` event. That event is what
/// `Challenges/ChallengeObjectiveKill` and `ChallengeObjectiveKillByTag`
/// subscribe to, so without this send a player's kill challenges never
/// advance - challenges are client-tracked, and this is the wire that feeds
/// them.
///
/// Server-side credit (quests, XP, the score counter) is computed on the
/// death path and is not affected: this notifies, it does not award. The
/// inbound direction stays an accept-and-drop (DIVERGENCES 1.12).
pub fn awardKillNotify(self: *Game, killer_slot: usize, killed_entity_id: i32) void {
    const killer = &self.clients[killer_slot];
    const peer = killer.peer orelse return;
    if (killer.entity_id <= 0) return;
    var buf: [8]u8 = undefined;
    const body = packages.buildAwardKillBody(&buf, killer.entity_id, killed_entity_id) catch return;
    self.sendGame(peer, "NetPackageEntityAwardKillServer", body) catch |err| {
        self.harness.counters.inc(.net_send_errors);
        std.debug.print("zdtd: send AwardKill failed: {s}\n", .{@errorName(err)});
    };
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
/// is the player's TickServer lightLevel (0..200) from the per-tick ambient
/// (step.zig) + crouch, folded exactly like the S2C Setup(lightLevel,
/// noiseVolume, alert) IL=26 conv.u1 (systems.stealthLightLevel). The
/// selfLight/movingLight and speedAverage terms are 0 until item lights +
/// movement visibility land (documented).
pub fn tickStealthBroadcast(self: *Game) void {
    if ((self.tick_n % 16) != 0) return;
    for (&self.clients) |*c| {
        if (!c.joined or c.entity_id <= 0) continue;
        const ps = self.sim.playerByPeer(c.slot) orelse continue;
        if (!self.sim.mask[ps].transform) continue;
        const noise = self.sim.stealth[ps].noise_volume;
        const noise8: u8 = @trunc(@min(noise, 127.0));
        const crouch = self.sim.player[ps].crouching;
        const light8: u8 = @trunc(@min(
            systems.stealthLightLevel(self.sim.ambient_light, self.sim.heldLightFor(ps), crouch, self.sim.rules.ai.stealth_light_passive, self.sim.stealth[ps].speed_average),
            255.0,
        ));
        var alert = false;
        const px = self.sim.transform[ps].x;
        const pz = self.sim.transform[ps].z;
        for (self.sim.kind_groups.slice(.zombie)) |zs| {
            if (!self.sim.alive[zs] or !self.sim.mask[zs].zombie_ai) continue;
            if (!self.sim.mask[zs].transform or !self.sim.zombie_ai[zs].alert) continue;
            const dx = self.sim.transform[zs].x - px;
            const dz = self.sim.transform[zs].z - pz;
            const ar = self.sim.rules.ai.stealth_alert_radius;
            if (dx * dx + dz * dz <= ar * ar) {
                alert = true;
                break;
            }
        }
        if (noise8 == c.stealth_noise_sent and crouch == c.stealth_crouch_sent and alert == c.stealth_alert_sent and light8 == c.stealth_light_sent) continue;
        const crouch_changed = crouch != c.stealth_crouch_sent;
        const levels_changed = noise8 != c.stealth_noise_sent or alert != c.stealth_alert_sent or light8 != c.stealth_light_sent;
        c.stealth_noise_sent = noise8;
        c.stealth_crouch_sent = crouch;
        c.stealth_alert_sent = alert;
        c.stealth_light_sent = light8;
        // Stock's Setup overloads are mutually exclusive: the crouch flag has
        // its own package and never rides the light/noise payload, whose low
        // byte the client reads whole as the light level.
        if (crouch_changed) {
            if (packages.buildEntityStealthCrouchBody(self.body_buf[0..16], c.entity_id, crouch)) |cb| {
                self.broadcastExcept("NetPackageEntityStealth", cb, null) catch |err| {
                    self.harness.counters.inc(.net_send_errors);
                    std.debug.print("zdtd: EntityStealth broadcast failed: {s}\n", .{@errorName(err)});
                };
            } else |_| {}
        }
        if (!levels_changed) continue;
        if (packages.buildEntityStealthBody(self.body_buf[0..16], c.entity_id, light8, noise8, alert)) |sb| {
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

/// ProgressionClass::CalculatedCostForLevel (IL=423):
/// `conv.i4(Mathf.Pow(CostMultiplier, level) * BaseCostToLevel)`. Mathf.Pow
/// computes in double and casts back to float (the same shape as expForLevel),
/// and `conv.i4` truncates toward zero, so the ladder is cheaper than the old
/// `round(base * mult^(level-1))`: for stock attributes (1, 1.14) level 5 costs
/// 1, not 2. Level 0 has no cost.
fn skillCostForLevel(def_cost: u16, mult: f32, level: u8) u32 {
    if (level == 0) return 0;
    const powf: f32 = @floatCast(std.math.pow(f64, mult, @floatFromInt(level)));
    const v = @as(f32, @floatFromInt(def_cost)) * powf;
    if (!(v > 0)) return 0; // NaN / <= 0; a zero-cost row is free like stock
    if (v >= 65535) return 65535;
    return @intFromFloat(@trunc(v));
}

/// Catalog-validated cost of buying `skill` at `target_level`, or null when
/// the purchase would be denied (unknown skill, not the next level, already
/// maxed, above the level the `<level_requirements>` allow, a book). Mirrors
/// the validation inside purchaseSkillAtCost so the on_perk_spend verdict can
/// scale the cost before the purchase applies (ADR 0033).
///
/// The level gate is stock's own: `ProgressionClass::GetCalculatedMaxLevel`
/// (IL=343) takes the highest `<level_requirements>` block whose gates pass.
/// It replaced a check that required the perk's `parent` attribute, which is a
/// `<skill>` grouping name (`perkPummelPete parent="skillStrengthCombat"`) that
/// is never levelled, so every perk purchase was denied.
pub fn skillCostOf(self: *const Game, slot: usize, skill: []const u8, target_level: u8) ?u32 {
    if (slot >= self.clients.len) return null;
    const c = &self.clients[slot];
    const cur = self.skillLevelOf(slot, skill);
    if (target_level != cur + 1) return null; // one level per purchase
    const pt = self.progression_table;
    // Resolve the skill: attributes first, then perks/books.
    var max_level: u8 = 0;
    var base_cost: u16 = 1;
    var cost_mult: f32 = 1.0;
    var override_cost: []const u16 = &.{};
    var found = false;
    for (pt.attributes) |a| {
        if (!std.mem.eql(u8, a.name, skill)) continue;
        max_level = a.max_level;
        base_cost = a.base_cost;
        cost_mult = a.cost_mult;
        override_cost = a.override_cost;
        found = true;
        break;
    }
    if (!found) {
        for (pt.perks) |pk| {
            if (!std.mem.eql(u8, pk.name, skill)) continue;
            // A `<book>` is granted by reading its item, never bought.
            if (pk.book) return null;
            max_level = pk.max_level;
            base_cost = pk.base_cost;
            cost_mult = pk.cost_mult;
            override_cost = pk.override_cost;
            found = true;
            break;
        }
    }
    if (!found or max_level == 0) return null; // unknown skill
    if (cur >= max_level) return null;
    // Stock's purchase gate (ProgressionClass::GetCalculatedMaxLevel, IL=343).
    const allowed = pt.calculatedMaxLevel(c.skill_levels[0..c.skill_level_n], c.level, skill) orelse max_level;
    if (target_level > allowed) return null;
    // ProgressionClass.OverrideCost replaces the curve when the row has one
    // (IL=423). Stock indexes the table by `level - 1`; a level past its end
    // refuses rather than falling back to the curve.
    if (override_cost.len > 0) {
        const idx = @as(usize, target_level) - 1;
        if (idx >= override_cost.len) return null;
        return override_cost[idx];
    }
    return skillCostForLevel(base_cost, cost_mult, target_level);
}

/// Purchase one progression level (NetPackageEntitySetSkillLevelServer,
/// RE progression.md §3 SpendSkillPoints). Validates: known skill, one level
/// at a time, max level, the stock `<level_requirements>` gate for that level,
/// SP balance >= cost. Applies server-side and echoes
/// NetPackageEntitySetSkillLevelClient. Returns false when denied.
pub fn purchaseSkill(self: *Game, slot: usize, skill: []const u8, target_level: u8) bool {
    return purchaseSkillAtCost(self, slot, skill, target_level, null);
}

/// Purchase with an explicit cost override (the on_perk_spend verdict may
/// scale the catalog cost, ADR 0033); null keeps the catalog cost.
pub fn purchaseSkillAtCost(self: *Game, slot: usize, skill: []const u8, target_level: u8, cost_override: ?u32) bool {
    if (slot >= self.clients.len) return false;
    const c = &self.clients[slot];
    // The C2S caller reads the name into a stack buffer, so the ledger must
    // hold catalog memory: skill_levels outlives the packet frame and is what
    // the save writer and the passive-effects fold read.
    const interned = internProgressionName(self, skill) orelse return false;
    const cost = self.skillCostOf(slot, interned, target_level) orelse return false;
    const eff_cost = cost_override orelse cost;
    if (c.skill_points < eff_cost) return false;
    c.skill_points -= eff_cost;
    var i: usize = 0;
    while (i < c.skill_level_n) : (i += 1) {
        if (std.mem.eql(u8, c.skill_levels[i].name, interned)) {
            c.skill_levels[i].level = target_level;
            return true;
        }
    }
    if (c.skill_level_n < c.skill_levels.len) {
        c.skill_levels[c.skill_level_n] = .{ .name = interned, .level = target_level };
        c.skill_level_n += 1;
        return true;
    }
    return false;
}

/// Intern a progression.xml name (attribute, perk, or crafting_skill) so
/// Client.skill_levels points at catalog memory, not a transient buffer.
fn internProgressionName(self: *const Game, name: []const u8) ?[]const u8 {
    for (self.progression_table.attributes) |a| {
        if (std.mem.eql(u8, a.name, name)) return a.name;
    }
    for (self.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, name)) return pk.name;
    }
    for (self.progression_table.crafting_skills) |sk| {
        if (std.mem.eql(u8, sk.name, name)) return sk.name;
    }
    return null;
}

/// Catalog MaxLevel for a progression name (attribute, perk, or
/// crafting_skill). Unknown names return null (fail closed).
fn progressionMaxLevel(self: *const Game, name: []const u8) ?u16 {
    for (self.progression_table.attributes) |a| {
        if (std.mem.eql(u8, a.name, name)) return a.max_level;
    }
    for (self.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, name)) return pk.max_level;
    }
    for (self.progression_table.crafting_skills) |sk| {
        if (std.mem.eql(u8, sk.name, name)) return sk.max_level;
    }
    return null;
}

/// MinEventActionAddProgressionLevel (RE minevents.md IL=143): add `delta`
/// to the named ProgressionValue, clamped to the crafting_skill max_level
/// (stock magazines ship level="1"). Unknown names fail closed.
pub fn addProgressionLevel(self: *Game, slot: usize, name: []const u8, delta: u8) bool {
    if (delta == 0 or slot >= self.clients.len) return false;
    const interned = internProgressionName(self, name) orelse return false;
    const max_level: u16 = progressionMaxLevel(self, interned) orelse 100;
    const c = &self.clients[slot];
    var i: usize = 0;
    while (i < c.skill_level_n) : (i += 1) {
        if (std.mem.eql(u8, c.skill_levels[i].name, interned)) {
            const cur: u16 = c.skill_levels[i].level;
            const next: u16 = @min(max_level, cur + delta);
            if (next == cur) return false;
            c.skill_levels[i].level = @intCast(next);
            return true;
        }
    }
    if (c.skill_level_n >= c.skill_levels.len) return false;
    const first: u16 = @min(max_level, delta);
    c.skill_levels[c.skill_level_n] = .{ .name = interned, .level = @intCast(first) };
    c.skill_level_n += 1;
    return true;
}

/// MinEventActionSetProgressionLevel with level=-1 (RE minevents.md IL=104):
/// set ProgressionClass.MaxLevel. Stock almanacs/journals ship only -1.
/// Unknown names fail closed.
pub fn setProgressionLevelMax(self: *Game, slot: usize, name: []const u8) bool {
    if (slot >= self.clients.len) return false;
    const interned = internProgressionName(self, name) orelse return false;
    const max_level = progressionMaxLevel(self, interned) orelse return false;
    const target: u8 = if (max_level > 255) 255 else @intCast(max_level);
    const c = &self.clients[slot];
    var i: usize = 0;
    while (i < c.skill_level_n) : (i += 1) {
        if (std.mem.eql(u8, c.skill_levels[i].name, interned)) {
            if (c.skill_levels[i].level == target) return false;
            c.skill_levels[i].level = target;
            return true;
        }
    }
    if (c.skill_level_n >= c.skill_levels.len) return false;
    c.skill_levels[c.skill_level_n] = .{ .name = interned, .level = target };
    c.skill_level_n += 1;
    return true;
}

/// Magazine / almanac eat: items.xml AddProgressionLevel and/or
/// SetProgressionLevel(level=-1) plus GiveExp on the consumed item.
/// GiveExp (RE minevents.md IL=63) is `_xpOther` / XPTypes 8 on stock; the
/// wire maps any non-kill type to `_xpOther`, so AddExpClient uses
/// xp_type_other. Unknown names fail closed; 0 exp is a no-op.
pub fn grantMagazineRead(self: *Game, slot: usize, item_id: u16) void {
    if (item_id == 0 or slot >= self.clients.len) return;
    const def = self.items.byId(item_id) orelse return;
    if (def.progression_add > 0 and def.progression_name.len > 0) {
        _ = addProgressionLevel(self, slot, def.progression_name, def.progression_add);
    }
    for (def.progression_set_max) |pname| {
        _ = setProgressionLevelMax(self, slot, pname);
    }
    if (def.eat_exp == 0) return;
    awardXp(self, slot, def.eat_exp);
}

/// Fold one named passive over a client's purchased attribute/perk levels
/// (level-aware curveAt) plus an actor sim slot's active buffs at level 1.
/// Shared by the DismemberSelfChance (143) dismember fold and the Bartering
/// (148/149) trade folds: base_add/subtract accumulate, base_set overrides,
/// perc ops skipped (no stock row for these names uses them). Returns 0 with
/// no rows, which is the stock unbuffed value, not a silent default.
pub fn namedPassiveFold(self: *const Game, slot: usize, actor_sim_slot: ?ecs.Slot, name: []const u8) f32 {
    if (slot >= self.clients.len) return 0;
    const c = &self.clients[slot];
    var bonus: f32 = 0;
    // Perk/attribute leg.
    for (c.skill_levels[0..c.skill_level_n]) |sl| {
        if (sl.level == 0) continue;
        const passives: []const assets_buffs.Passive = blk: {
            for (self.progression_table.attributes) |a| {
                if (std.mem.eql(u8, a.name, sl.name)) break :blk a.passives;
            }
            for (self.progression_table.perks) |pk| {
                if (std.mem.eql(u8, pk.name, sl.name)) break :blk pk.passives;
            }
            break :blk &.{};
        };
        for (passives) |p| {
            if (!std.mem.eql(u8, p.name, name)) continue;
            const v = assets_buffs.curveAt(p, sl.level);
            switch (p.op) {
                .base_set, .set => bonus = v,
                .base_add, .add => bonus += v,
                .base_subtract, .subtract => bonus -= v,
                else => {},
            }
        }
    }
    // Active-buff leg at level 1.
    if (actor_sim_slot) |as| {
        if (self.sim.mask[as].buffs) {
            for (self.sim.buffs[as].slots) |bs| {
                if (!bs.active) continue;
                const def = self.buffs.byId(bs.def_id) orelse continue;
                for (def.passives) |p| {
                    if (!std.mem.eql(u8, p.name, name)) continue;
                    const v = assets_buffs.curveAt(p, 1);
                    switch (p.op) {
                        .base_set, .set => bonus = v,
                        .base_add, .add => bonus += v,
                        .base_subtract, .subtract => bonus -= v,
                        else => {},
                    }
                }
            }
        }
    }
    return bonus;
}

/// Attacker's DismemberSelfChance bonus (stock passive 143) for the dismember
/// roll: the region multiplier is the base, and perk + active-buff rows add
/// on top (EffectManager.GetValue, RE GetDismemberChance IL=128).
pub fn dismemberSelfChance(self: *const Game, slot: usize, actor_sim_slot: ?ecs.Slot) f32 {
    return namedPassiveFold(self, slot, actor_sim_slot, "DismemberSelfChance");
}

/// Barter scales (RE XUiM_Trader GetBuyPrice IL=240 / GetSellPrice IL=217):
/// buying pays `unit - unit * BarteringBuying(148)`, selling gains
/// `unit + unit * BarteringSelling(149)`. Hook bodies for the ECS trade path.
pub fn barterBuyScale(ctx: ?*anyopaque, slot: usize) f32 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const as = g.sim.playerByPeer(slot);
    return @max(0, 1 - namedPassiveFold(g, slot, as, "BarteringBuying"));
}

pub fn barterSellScale(ctx: ?*anyopaque, slot: usize) f32 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const as = g.sim.playerByPeer(slot);
    return 1 + @max(0, namedPassiveFold(g, slot, as, "BarteringSelling"));
}

const assets_progression_test = @import("../../assets/progression.zig");
const requirements_test = @import("../../assets/requirements.zig");

test "skill ledger: level-up awards SP; purchase validates, level gate and spends" {
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_ledger", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    // Minimal progression tree: one attribute + one perk whose level 1 is
    // gated on the attribute (stock's shape: the gate is `<level_requirements>`
    // on a progression name, not the perk's `parent` grouping name).
    const gate_l1 = [_]requirements_test.Requirement{.{ .kind = .progression_level, .op = .ge, .value = 1, .arg = "attGeneral" }};
    const gate_l2 = [_]requirements_test.Requirement{.{ .kind = .progression_level, .op = .ge, .value = 3, .arg = "attGeneral" }};
    const lvl_reqs = [_]assets_progression_test.LevelReq{
        .{ .level = 1, .reqs = &gate_l1 },
        .{ .level = 2, .reqs = &gate_l2 },
    };
    const attrs = [_]assets_progression_test.AttrDef{
        .{ .name = "attGeneral", .max_level = 10, .base_cost = 1, .cost_mult = 1.14 },
    };
    const perks = [_]assets_progression_test.PerkDef{
        .{ .name = "perkLightEater", .max_level = 5, .parent_attr = "skillGeneral", .level_reqs = &lvl_reqs },
    };
    g.progression_table.attributes = &attrs;
    g.progression_table.perks = &perks;
    g.progression.skill_points_per_level = 1;

    // Level up from 1 to 2: skill_points_per_level awarded per new level.
    const level1_xp = g.progression.expForLevel(1);
    g.awardXp(0, level1_xp);
    try std.testing.expectEqual(@as(u16, 2), g.clients[0].level);
    try std.testing.expectEqual(@as(u32, 1), g.clients[0].skill_points);

    // Perk with unmet level gate: denied, no SP spent.
    try std.testing.expect(!g.purchaseSkill(0, "perkLightEater", 1));
    try std.testing.expectEqual(@as(u32, 1), g.clients[0].skill_points);
    // Unknown skill denies.
    try std.testing.expect(!g.purchaseSkill(0, "notASkill", 1));
    // Buy the attribute first (cost 1 = base), then the perk level 1.
    try std.testing.expect(g.purchaseSkill(0, "attGeneral", 1));
    try std.testing.expectEqual(@as(u8, 1), g.skillLevelOf(0, "attGeneral"));
    try std.testing.expectEqual(@as(u32, 0), g.clients[0].skill_points);
    // Second level would cost base x mult (1.14 -> round 1): still 0 SP.
    try std.testing.expect(!g.purchaseSkill(0, "attGeneral", 2));
    // Perk buys at base cost 1 now that its level-1 gate passes.
    g.clients[0].skill_points = 1;
    try std.testing.expect(g.purchaseSkill(0, "perkLightEater", 1));
    try std.testing.expectEqual(@as(u8, 1), g.skillLevelOf(0, "perkLightEater"));
    try std.testing.expectEqual(@as(u32, 0), g.clients[0].skill_points);
    // Re-purchase of the same level denies (one level per request).
    try std.testing.expect(!g.purchaseSkill(0, "perkLightEater", 1));
    // Level 2 needs attGeneral >= 3, which the ledger does not hold yet.
    g.clients[0].skill_points = 5;
    try std.testing.expect(!g.purchaseSkill(0, "perkLightEater", 2));
    try std.testing.expectEqual(@as(u32, 5), g.clients[0].skill_points);
    g.clients[0].skill_levels[0] = .{ .name = "attGeneral", .level = 3 };
    try std.testing.expect(g.purchaseSkill(0, "perkLightEater", 2));
    try std.testing.expectEqual(@as(u8, 2), g.skillLevelOf(0, "perkLightEater"));
    std.debug.print("PASS skill-ledger: SP award, cost, level gate, echo state\n", .{});
}

test "skill cost follows CalculatedCostForLevel and the row override table" {
    // IL=423: conv.i4(Mathf.Pow(CostMultiplier, level) * BaseCostToLevel), with
    // Mathf.Pow in double cast back to float and conv.i4 truncating. Stock
    // attributes are base 1 / mult 1.14, so the goldens are 1,1,1,1,1,2,2,2,3,3
    // (the old round(base*mult^(level-1)) gave 2 at level 5 and 3 at level 8).
    const goldens = [_]u32{ 1, 1, 1, 1, 1, 2, 2, 2, 3, 3 };
    for (goldens, 0..) |want, i| {
        try std.testing.expectEqual(want, skillCostForLevel(1, 1.14, @intCast(i + 1)));
    }
    // A flat multiplier (stock perks: mult 1) costs the base at every level.
    try std.testing.expectEqual(@as(u32, 1), skillCostForLevel(1, 1.0, 5));
    try std.testing.expectEqual(@as(u32, 3), skillCostForLevel(3, 1.0, 4));
    // A zero-cost row is free (stock conv.i4 of 0); level 0 has no cost.
    try std.testing.expectEqual(@as(u32, 0), skillCostForLevel(0, 1.14, 3));
    try std.testing.expectEqual(@as(u32, 0), skillCostForLevel(1, 1.14, 0));
}

test "override_cost replaces the curve and refuses past its end" {
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_cost", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    const attrs = [_]assets_progression_test.AttrDef{
        .{ .name = "attPerception", .max_level = 10, .base_cost = 1, .cost_mult = 1.14 },
    };
    const gate = [_]requirements_test.Requirement{.{ .kind = .progression_level, .op = .ge, .value = 1, .arg = "attPerception" }};
    const lvl = [_]assets_progression_test.LevelReq{
        .{ .level = 1, .reqs = &gate },
        .{ .level = 2, .reqs = &gate },
    };
    // Stock shape: perkPummelPete carries override_cost="1,2,2,3".
    const perks = [_]assets_progression_test.PerkDef{
        .{ .name = "perkPummelPete", .max_level = 4, .level_reqs = &lvl, .override_cost = &.{ 1, 2 } },
    };
    g.progression_table.attributes = &attrs;
    g.progression_table.perks = &perks;
    g.clients[0].skill_levels[0] = .{ .name = "attPerception", .level = 4 };
    g.clients[0].skill_level_n = 1;
    g.clients[0].skill_points = 10;
    // The attribute ladder: level 5 costs 1 under the stock formula.
    try std.testing.expectEqual(@as(?u32, 1), g.skillCostOf(0, "attPerception", 5));
    // The override table wins for the perk.
    try std.testing.expectEqual(@as(?u32, 1), g.skillCostOf(0, "perkPummelPete", 1));
    try std.testing.expect(g.purchaseSkill(0, "perkPummelPete", 1));
    try std.testing.expectEqual(@as(u32, 9), g.clients[0].skill_points);
    try std.testing.expectEqual(@as(?u32, 2), g.skillCostOf(0, "perkPummelPete", 2));
    try std.testing.expect(g.purchaseSkill(0, "perkPummelPete", 2));
    try std.testing.expectEqual(@as(u32, 7), g.clients[0].skill_points);
    // Level 3 has no override entry: stock would index past the table, so the
    // purchase refuses instead of falling back to the curve.
    try std.testing.expect(g.skillCostOf(0, "perkPummelPete", 3) == null);
    try std.testing.expect(!g.purchaseSkill(0, "perkPummelPete", 3));
    try std.testing.expectEqual(@as(u32, 7), g.clients[0].skill_points);
    std.debug.print("PASS perk cost: stock curve + row override_cost\n", .{});
}

test "killXpAward scales by the on_entity_killed verdict percent" {
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_killscale", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    // killXpAward(slot, base, scale, trap, killed): 200 base x 150% = 300
    // (xp_multiplier default 100 keeps 1.0x). No corpse net id -> the shared
    // kill class falls back to the stock default (unused here, no party).
    const before = g.clients[0].xp;
    g.killXpAward(0, 200, 150, false, 0);
    try std.testing.expectEqual(before + 300, g.clients[0].xp);
    std.debug.print("PASS kill-xp-scale: 200 x 150% = {d}\n", .{g.clients[0].xp - before});
}

test "addProgressionLevel clamps to crafting_skill max and fails closed on unknown names" {
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_magread", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    const skills = [_]assets_progression.CraftingSkill{
        .{ .name = "craftingHarvestingTools", .max_level = 5, .entries = &.{} },
    };
    g.progression_table.crafting_skills = &skills;
    try std.testing.expect(!g.addProgressionLevel(0, "notASkill", 1));
    try std.testing.expect(g.addProgressionLevel(0, "craftingHarvestingTools", 1));
    try std.testing.expectEqual(@as(u8, 1), g.skillLevelOf(0, "craftingHarvestingTools"));
    try std.testing.expect(g.addProgressionLevel(0, "craftingHarvestingTools", 1));
    try std.testing.expectEqual(@as(u8, 2), g.skillLevelOf(0, "craftingHarvestingTools"));
    try std.testing.expect(g.addProgressionLevel(0, "craftingHarvestingTools", 10));
    try std.testing.expectEqual(@as(u8, 5), g.skillLevelOf(0, "craftingHarvestingTools"));
    try std.testing.expect(!g.addProgressionLevel(0, "craftingHarvestingTools", 1));
}

test "grantMagazineRead awards GiveExp through the server ledger" {
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_magxp", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    const skills = [_]assets_progression.CraftingSkill{
        .{ .name = "craftingHarvestingTools", .max_level = 100, .entries = &.{} },
    };
    g.progression_table.crafting_skills = &skills;
    const defs = [_]assets_items.ItemDef{
        .{
            .id = 100,
            .name = "harvestingToolsSkillMagazine",
            .is_eat = true,
            .progression_name = "craftingHarvestingTools",
            .progression_add = 1,
            .eat_exp = 50,
        },
    };
    g.items = .{ .defs = &defs, .source = .xml };
    const before = g.clients[0].xp;
    g.grantMagazineRead(0, 100);
    try std.testing.expectEqual(before + 50, g.clients[0].xp);
    try std.testing.expectEqual(@as(u8, 1), g.skillLevelOf(0, "craftingHarvestingTools"));
}

test "grantMagazineRead SetProgressionLevel -1 sets perk to max" {
    // RE minevents.md IL=104: level=-1 sets ProgressionClass.MaxLevel.
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_setmax", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    const perks = [_]assets_progression.PerkDef{
        .{ .name = "perkFiremansAlmanacHeat", .max_level = 5 },
        .{ .name = "perkFiremansAlmanacComplete", .max_level = 1 },
    };
    g.progression_table.perks = &perks;
    const set_names = [_][]const u8{ "perkFiremansAlmanacHeat", "perkFiremansAlmanacComplete" };
    const defs = [_]assets_items.ItemDef{
        .{
            .id = 100,
            .name = "bookFiremansAlmanacHeat",
            .is_eat = true,
            .progression_set_max = &set_names,
            .eat_exp = 50,
        },
    };
    g.items = .{ .defs = &defs, .source = .xml };
    const before = g.clients[0].xp;
    g.grantMagazineRead(0, 100);
    try std.testing.expectEqual(before + 50, g.clients[0].xp);
    try std.testing.expectEqual(@as(u8, 5), g.skillLevelOf(0, "perkFiremansAlmanacHeat"));
    try std.testing.expectEqual(@as(u8, 1), g.skillLevelOf(0, "perkFiremansAlmanacComplete"));
    // Idempotent at max.
    try std.testing.expect(!g.setProgressionLevelMax(0, "perkFiremansAlmanacHeat"));
    try std.testing.expect(!g.setProgressionLevelMax(0, "notAPerk"));
}

test "dismemberSelfChance folds perk levels and active buffs, 0 when absent" {
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_dismember143", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    // No rows anywhere: the stock unbuffed value.
    try std.testing.expectEqual(@as(f32, 0), g.dismemberSelfChance(0, null));
    // Perk leg: a DismemberSelfChance base_add curve 0.1/level.
    const perks = [_]assets_progression.PerkDef{
        .{
            .name = "perkSkullCrusher",
            .max_level = 5,
            .passives = &.{.{ .name = "DismemberSelfChance", .op = .base_add, .curve = .{ 0.1, 0.2, 0.3, 0, 0, 0, 0, 0 }, .curve_len = 3, .curve_levels = .{ 1, 2, 3, 0, 0, 0, 0, 0 }, .curve_levels_len = 3 }},
        },
    };
    g.progression_table.perks = &perks;
    _ = g.sim.spawnPlayer(0, 70, 0, 0).?;
    g.clients[0].skill_levels[0] = .{ .name = "perkSkullCrusher", .level = 2 };
    g.clients[0].skill_level_n = 1;
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), g.dismemberSelfChance(0, null), 0.0001);
    // Unknown skill names are ignored (fail closed).
    g.clients[0].skill_levels[0].name = "notAPerk";
    try std.testing.expectEqual(@as(f32, 0), g.dismemberSelfChance(0, null));
    g.clients[0].skill_levels[0].name = "perkSkullCrusher";
    // Buff leg: an active buff's untagged row adds at level 1.
    const defs = [_]assets_buffs.BuffDef{
        .{ .name = "testDismemberBuff", .passives = &.{.{ .name = "DismemberSelfChance", .op = .base_add, .value = 0.5 }} },
    };
    g.buffs.defs = defs[0..];
    const ps = g.sim.playerByPeer(0) orelse return error.TestUnexpectedResult;
    const bs = g.sim.buffsMut(ps);
    bs.slots[0] = .{ .active = true, .def_id = 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), g.dismemberSelfChance(0, ps), 0.0001);
    // Inactive buff contributes nothing.
    bs.slots[0].active = false;
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), g.dismemberSelfChance(0, ps), 0.0001);
    // Removing the perk level reverts exactly.
    g.clients[0].skill_level_n = 0;
    try std.testing.expectEqual(@as(f32, 0), g.dismemberSelfChance(0, ps));
    std.debug.print("PASS dismember-143: perk curve + buff leg fold, revertible\n", .{});
}

test "barter scales discount buying and bonus selling off the same fold" {
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_barter", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    // No rows: scales are identity (slot 0 has no player yet, so the
    // buff leg resolves empty and only the empty perk ledger folds).
    // g is already *Game; &g would be **Game and mis-cast.
    const ctx: ?*anyopaque = @ptrCast(g);
    try std.testing.expectEqual(@as(f32, 1), barterBuyScale(ctx, 0));
    try std.testing.expectEqual(@as(f32, 1), barterSellScale(ctx, 0));
    const perks = [_]assets_progression.PerkDef{
        .{
            .name = "perkBetterBarter",
            .max_level = 5,
            .passives = &.{
                .{ .name = "BarteringBuying", .op = .base_add, .curve = .{ 0.05, 0.1, 0, 0, 0, 0, 0, 0 }, .curve_len = 2, .curve_levels = .{ 1, 2, 0, 0, 0, 0, 0, 0 }, .curve_levels_len = 2 },
                .{ .name = "BarteringSelling", .op = .base_add, .curve = .{ 0.05, 0.1, 0, 0, 0, 0, 0, 0 }, .curve_len = 2, .curve_levels = .{ 1, 2, 0, 0, 0, 0, 0, 0 }, .curve_levels_len = 2 },
            },
        },
    };
    g.progression_table.perks = &perks;
    _ = g.sim.spawnPlayer(0, 70, 0, 0).?;
    g.clients[0].skill_levels[0] = .{ .name = "perkBetterBarter", .level = 2 };
    g.clients[0].skill_level_n = 1;
    // Level 2: 10% off buys, 10% over sells.
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), barterBuyScale(ctx, 0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), barterSellScale(ctx, 0), 0.0001);
    std.debug.print("PASS barter-scale: buy 0.9x sell 1.1x at level 2\n", .{});
}
