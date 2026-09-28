//! C2S damage arm: kill claims, XP awards, score updates.
//!
//! Split out of c2s/misc.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const invsys = @import("../../ecs/inventory.zig");
const protocol = @import("../../protocol.zig");
const plugin_compose = @import("../game/plugin_compose.zig");
const systems = @import("../../ecs/systems.zig");
const log = @import("../../util/log.zig");

/// Honored-`fatal` kill amount vs NPC kinds (zombies/animals). Stock fatal
/// damage is client-computed; the server honors the flag only against NPCs
/// and sends a kill amount far above any sim NPC class HP (max class hp
/// 1600; the 9999-HP trader class is excluded by the zombie/animal gate).
pub const fatal_kill_amount: f32 = 9999;

/// Push the killer's AddScoreClient. Stock's NetPackageEntityAddScoreClient
/// carries the *increment* for this event, not a running total: the client's
/// ProcessPackage (IL=25) calls EntityAlive.AddScore(0, zombieKills,
/// playerKills, ...), and AddScore (IL=97) adds every argument to the entity's
/// counters. EntityAlive.AwardKill (IL=66) therefore sends 0/1 deltas. Sending
/// the totals made each receiving client re-add the whole count: after three
/// kills it showed 1+2+3 = 6.
pub fn sendScoreUpdate(self: *Game, c: *Client, zombie_delta: u16, player_delta: u16) void {
    const kpeer = c.peer orelse return;
    if (packages.stock_xp.buildAddScoreBody(self.body_buf[32..48], .{
        .entity_id = c.entity_id,
        .zombie_kills = zombie_delta,
        .player_kills = player_delta,
    })) |ab| {
        self.sendGame(kpeer, "NetPackageEntityAddScoreClient", ab) catch |err| {
            self.harness.counters.inc(.net_send_errors);
            log.err("send AddScoreClient failed: {s}\n", .{@errorName(err)});
        };
    } else |_| {}
}

/// True when `name` is a damage package and was handled.
pub fn handleDamage(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageDamageEntity")) {
        const d = packages.parseDamageHead(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        if (self.quarantineDenies(c, .damage)) return true;
        if (!self.takeDamageToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        // Damage is a client claim, so require both actor and target to be
        // in the server's current interest range. This blocks forged net
        // ids from damaging players or AI elsewhere in the world.
        const actor_slot = self.sim.playerByPeer(c.slot) orelse return true;
        if (!self.sim.alive[actor_slot] or self.sim.health[actor_slot].hp <= 0) {
            self.harness.counters.inc(.bounds_rejects);
            self.noteEvidence(c, peer.local_id, d.entity_id, .bounds, .strong, .damage, 0, 1);
            return true;
        }
        const target_slot = if (self.sim.slotOfNetId(d.entity_id)) |ts| ts else {
            // Host-side bot target (ADR 0026): bots are not ECS slots, so the
            // ECS damage path cannot see them. Players may fight bots with the
            // same trust gates as ECS targets: the actor is validated above,
            // the claimed strength is capped, and a forged far-away id is
            // range-gated to interest. No PvP gate (bots are NPCs), no armor
            // mitigation, and no `fatal` honor (same as players).
            if (self.bots.find(d.entity_id)) |bs| {
                const b = &self.bots.bots[bs];
                if (!self.sim.mask[actor_slot].transform) return true;
                const ap = self.sim.transform[actor_slot];
                const bdx = b.x - ap.x;
                const bdz = b.z - ap.z;
                if (bdx * bdx + bdz * bdz > self.interest_range * self.interest_range) {
                    self.harness.counters.inc(.bounds_rejects);
                    return true;
                }
                const bamount: f32 = @floatFromInt(@min(d.strength, self.max_claimed_damage));
                // Attributed damage: the guest sees the event in its next sense
                // pass and retaliates (clanker OnDamaged parity). Death / knock-
                // back / unspawn: BotManager owns hp; the replicate pass
                // unspawns dead bots and the population floor self-heals.
                _ = self.bots.damageFrom(d.entity_id, bamount, self.sim.network_id[actor_slot].id);
            }
            return true;
        };
        if (!self.sim.alive[target_slot]) {
            self.harness.counters.inc(.bounds_rejects);
            self.noteEvidence(c, peer.local_id, d.entity_id, .bounds, .strong, .damage, 0, 1);
            return true;
        }
        if (!self.sim.mask[actor_slot].transform or !self.sim.mask[target_slot].transform) return true;
        const actor_pos = self.sim.transform[actor_slot];
        const target_pos = self.sim.transform[target_slot];
        const damage_dx = target_pos.x - actor_pos.x;
        const damage_dy = target_pos.y - actor_pos.y;
        const damage_dz = target_pos.z - actor_pos.z;
        const damage_d2 = damage_dx * damage_dx + damage_dy * damage_dy + damage_dz * damage_dz;
        if (damage_d2 > self.interest_range * self.interest_range) {
            self.harness.counters.inc(.bounds_rejects);
            self.noteEvidence(c, peer.local_id, d.entity_id, .bounds, .strong, .damage, @sqrt(damage_d2), self.interest_range);
            return true;
        }
        const was_zombie = self.sim.kind[target_slot] == .zombie or self.sim.kind[target_slot] == .animal;
        // Client strength is a claim: cap it, and honor `fatal` only against
        // NPC kinds (a spoofed fatal must not one-shot another player).
        var amount: f32 = @floatFromInt(@min(d.strength, self.max_claimed_damage));
        if (d.fatal and was_zombie) amount = fatal_kill_amount;
        // PvP gate + resist legs when damaging a player, in stock
        // EntityAlive::DamageEntity order: GeneralDamageResist (passive 40, all
        // damage types, every source) then the armor branch of
        // Equipment.CalcDamage (IL=83), which stock only reaches when
        // DamageSource::AffectedByArmor (IL=5) holds - that is External (0)
        // damage. An Internal claim (starvation, dehydration, blood loss)
        // therefore keeps its GDR but takes no armour branch at all. On the
        // armour branch, physical types take the physical armor rating and
        // every other EnumDamageTypes member takes passive 43
        // ElementalDamageResist scaled by the damage type's tag
        // (combat-damage.md 2.1).
        var foreign_resist: f32 = 0;
        if (self.sim.slotOfNetId(d.entity_id)) |ei| {
            if (self.sim.mask[ei].player) {
                if (self.pvp_mode == 0 and self.sim.player[ei].peer_slot >= 0 and
                    self.sim.player[ei].peer_slot != @as(i32, @intCast(c.slot))) return true;
                amount *= 1.0 - invsys.generalDamageResist(&self.sim, ei);
                // Spectral Grace (perkAgilityMastery): the victim's
                // foreign-gated GDR rows evaluate here, where the attacker
                // (`other`) is known. The per-tick fold refuses them (no
                // other in scope), so a passing row lands only on this hit.
                // A passing Grace also starts the 60 s recharge buff, whose
                // own start row sets the cvar that closes the gate.
                foreign_resist = self.foreignGatedResist(ei, actor_slot);
                amount *= 1.0 - foreign_resist;
                if (self.sim.player[ei].peer_slot >= 0) {
                    if (protocol.damageSourceAffectedByArmor(d.source)) {
                        if (protocol.damageTypeIsPhysical(d.dtype)) {
                            // Armor mitigation, less the attacker's held-item
                            // TargetArmor penetration (RE
                            // GetTotalPhysicalArmorRating IL=47).
                            const mit = invsys.armorMitigationVs(&self.sim, @intCast(self.sim.player[ei].peer_slot), actor_slot);
                            amount *= (1.0 - mit);
                        } else {
                            // ElementalDamageResist is a percentage on the
                            // victim; no penetration leg exists for it in stock.
                            amount *= (1.0 - self.elementalDamageResist(ei, protocol.damageTypeName(d.dtype)));
                        }
                    }
                }
                // HealthLoss (passive 107) scales the applied loss (stock
                // `Stat.Tick`: `value = clamp(lastValue - GetValue(107), 0,
                // BaseMax)`); fatigued takes +10%.
                amount *= self.healthGainLossMult(@intCast(self.sim.player[ei].peer_slot), "HealthLoss");
            }
        }
        // Non-player victims carry no leg in this function: a victim-side class
        // PhysicalDamageResist (passive 41) belongs in World.damageFrom, which
        // is where stock's NetPackageDamageEntity ends up (the victim's
        // EntityAlive.DamageEntity), so an armoured zombie (soldier 50,
        // demolition 60) takes half whatever the attacker claimed. Only the
        // *attacker*-side numbers ride the claim verbatim.
        // Wasm-first (AGENTS rule 29): damage directed at a player passes the
        // on_player_damage plugin verdict after the native gate, so plugins
        // express PvP/friendly-fire and damage-scaling policy. <0 deny, 0
        // keep, >0 scale by percent. The native pvp_mode floor still wins.
        if (self.sim.slotOfNetId(d.entity_id)) |ei| {
            if (self.sim.mask[ei].player) {
                const atk = self.sim.network_id[actor_slot].id;
                const v = plugin_compose.playerDamage(self, atk, d.entity_id, @trunc(amount));
                if (v < 0) return true;
                if (v > 0) amount = amount * @as(f32, @floatFromInt(v)) / 100.0;
                if (foreign_resist > 0) {
                    _ = self.addCatalogBuff(d.entity_id, ei, "buffSpectersGrace", d.entity_id);
                }
                self.fireAttackedSelf(ei, actor_slot, d.body_part);
                // A self-fall claim (failing dtype, victim == the actor's own
                // player) is the landing impact: fire the check buff's
                // onSelfFallImpact leg-injury rows with the claimed amount as
                // the `_fallSpeed` proxy (stock records the impact velocity).
                if (d.dtype == 15 and ei == actor_slot) {
                    self.fireFallImpact(ei, @floatFromInt(d.strength));
                }
            }
        }
        // Attacker hit rows fire on every landed hit regardless of victim
        // kind (stock runs the attacker's MinEvents on EntityAlive hit):
        // Gunslinger combo, cripple/burn procs, DeepCuts bleeds. Victim-side
        // rows stay in the player block above. The damage claim does not say
        // melee-vs-ranged: the held weapon's `ranged` tag picks the
        // onSelfPrimaryActionRayHit path over onSelfAttackedOther.
        if (self.sim.slotOfNetId(d.entity_id)) |ei| {
            if (self.heldWeaponIsRanged(actor_slot)) {
                self.fireRayHit(actor_slot, ei, d.body_part);
            } else {
                self.fireAttackedOther(actor_slot, ei, d.body_part);
            }
            // Victim entity-class rows (radiated regen on damaged): the
            // class's own MinEvents with target=self. Players carry no such
            // rows (their buffs cover it); zombies/animals do.
            if (!self.sim.mask[ei].player) {
                self.fireClassRows(ei, .other_damaged_self);
            }
        }
        // Attribute the hit: stock's NetPackageDamageEntity carries
        // attackerEntityId (::read, asm.il:810693) and EAISetAsTargetIfHurt
        // turns it into the victim's attack target. The actor is already
        // validated above, so use its net id rather than the claimed field.
        // A damage-killed supply crate must take its MapObject and NavObject
        // markers back (EntitySupplyCrate.OnEntityDeath IL=30 +
        // OnEntityUnload/RemoveSupplyCrate IL=54). damageFrom destroys the
        // non-Alive entity, so read the flag before the call.
        const target_was_crate = if (self.sim.slotOfNetId(d.entity_id)) |ts|
            self.sim.mask[ts].loot_bag and self.sim.loot_bag[ts].supply_crate
        else
            false;
        const dmg = self.sim.damageFrom(d.entity_id, amount, self.sim.network_id[actor_slot].id);
        // Dismember roll (RE CheckDismember IL=125): the claimed body part
        // feeds the region/leg gates; the weapon chance comes off the
        // actor's held item, 0 when it carries no DismemberChance passive;
        // the attacker's DismemberSelfChance (143) perk/buff fold adds onto
        // the region multiplier (GetDismemberChance IL=128). The roll sets
        // crawler/cripple state on the victim and its outcome bits ride the
        // S2C damage body below.
        var dismember_bits: u8 = 0;
        if (self.sim.slotOfNetId(d.entity_id)) |vs| {
            if (self.sim.mask[vs].health) {
                // `heldItem()` guards the no-holding sentinel (0xFFFF, a legal
                // state after the held slot empties): indexing `holding`
                // directly panicked on a hit that arrived before the attacker
                // ever selected a toolbelt slot.
                const held_id = if (self.sim.mask[actor_slot].inventory)
                    self.sim.inventory[actor_slot].heldItem().item_id
                else
                    0;
                const weapon_chance = if (self.items.byId(held_id)) |idef| idef.dismember_chance else 0;
                const self_bonus = self.dismemberSelfChance(c.slot, actor_slot);
                dismember_bits = self.sim.rollDismember(vs, d.body_part, dmg.applied, self.sim.health[vs].max_hp, weapon_chance, self_bonus, d.fatal);
            }
        }
        // HealthSteal (passive 167): the attacker's ProcessDamageResponse
        // heals damage x GetValue(167) on the attacker (NightStalker +.5 at
        // night, gated sleeping victim). Clamped like the AddHealth leg.
        {
            const steal = self.healthGainLossMult(c.slot, "HealthSteal");
            if (steal > 0 and dmg.applied > 0 and self.sim.mask[actor_slot].health) {
                const ah = &self.sim.health[actor_slot];
                if (ah.hp > 0) {
                    ah.hp = @min(ah.max_hp, ah.hp + dmg.applied * steal);
                    self.sim.markDirty(actor_slot, .{ .hp = true });
                }
            }
        }
        // Item durability (GAP "Item durability"): the held tool wears with
        // each landed hit (stock ItemValue.UseTimes; the client shows the
        // durability bar). Zero keeps a broken, repairable stack.
        if (self.sim.mask[actor_slot].inventory) {
            _ = invsys.degradeUse(&self.sim, c.slot, self.sim.inventory[actor_slot].holding, 1.0);
            // Per-attack stamina (RE ItemActionMelee IL: the swing drains
            // `StaminaLoss x StaminaUsageMultiplier` via AddStamina(-cost)).
            // The item's StaminaLoss passive is the cost; the survival pass
            // picks the deduction up on its next stamina sync.
            if (self.sim.mask[actor_slot].health and self.sim.mask[actor_slot].player) {
                const held = self.sim.inventory[actor_slot].heldItem();
                if (self.items.byId(held.item_id)) |item_def| {
                    if (item_def.stamina_loss > 0) {
                        const cost = item_def.stamina_loss * self.sim.rules.combat.stamina_usage_multiplier;
                        if (cost > 0) self.sim.health[actor_slot].stamina = @max(0, self.sim.health[actor_slot].stamina - cost);
                    }
                }
            }
        }
        // Combat noise (stock NotifyNoise): a landed ranged hit alerts zombies
        // and wakes sleepers around the shooter (group-AI PARTIAL).
        if (self.sim.mask[actor_slot].transform) {
            const pt = self.sim.transform[actor_slot];
            self.sim.pushNoise(pt.x, pt.y, pt.z, self.sim.rules.ai.combat_noise_radius);
        }
        // Hit shove: the victim's knockback impulse animates on every peer
        // that sees it (stock EntityAlive.AddMotion -> NetPackageEntityVelocity).
        // One builder for the package (packages.buildEntityVelocityBody applies
        // stock's Setup clamp to [-8, 8] per axis).
        if (dmg.knocked) {
            if (self.sim.slotOfNetId(d.entity_id)) |vslot| {
                const kb = self.sim.zombie_ai[vslot];
                const kb_vx: f32 = kb.kb_dx * self.sim.rules.combat.knockback_speed;
                const kb_vz: f32 = kb.kb_dz * self.sim.rules.combat.knockback_speed;
                if (packages.buildEntityVelocityBody(self.body_buf[48..72], d.entity_id, true, kb_vx, 0, kb_vz)) |vb| {
                    const vt = self.sim.transform[vslot];
                    for (&self.clients) |*cl| {
                        if (!cl.joined or cl.peer == null) continue;
                        if (self.clientObserves(cl, vt.x, vt.z)) {
                            if (cl.peer) |p| self.sendGame(p, "NetPackageEntityVelocity", vb) catch {
                                self.harness.counters.inc(.net_send_errors);
                            };
                        }
                    }
                } else |_| {}
            }
        }
        // Hit reaction: stock fans the applied damage to the victim's trackers
        // (EntityAlive.ProcessDamageResponse IL=86: Setup(entityId, response)
        // via SendPacketToTrackedPlayers for remote-player hits, buff-sourced
        // damage and the general path). The client plays the hit reaction and
        // reads the dismember/cripple/crawler bits off it, so without this
        // send nothing the server computes about a hit is visible.
        if (self.sim.slotOfNetId(d.entity_id)) |vslot| {
            if (self.sim.mask[vslot].transform) {
                const vt = self.sim.transform[vslot];
                const applied: u16 = @intCast(@min(@as(u32, @trunc(@max(0, dmg.applied))), 65535));
                if (packages.buildDamageBody(self.body_buf[288..544], d.entity_id, d.source, d.dtype, applied, dmg.killed, self.sim.network_id[actor_slot].id)) |db| {
                    // The roll's outcome rides the stock flag bits
                    // (Setup IL=235: CrippleLegs -> 0x2, Dismember -> 0x8,
                    // TurnIntoCrawler -> 0x200). Flags sit at bytes 4..8 of
                    // the pinned body layout (entityId 0..4 first).
                    if (dismember_bits != 0) {
                        var fl = std.mem.readInt(u32, db[4..8], .little);
                        if (dismember_bits & 1 != 0) fl |= packages.dmg_dismember;
                        if (dismember_bits & 2 != 0) fl |= packages.dmg_turn_into_crawler;
                        if (dismember_bits & 4 != 0) fl |= packages.dmg_cripple_legs;
                        std.mem.writeInt(u32, self.body_buf[288 + 4 ..][0..4], fl, .little);
                    }
                    self.broadcastNear("NetPackageDamageEntity", db, vt.x, vt.z, self.interest_range) catch {};
                } else |_| {}
            }
        }
        if (dmg.killed) {
            // A victim `damageFrom` destroyed outright (vehicle, turret, bag)
            // owes its observers a removal: it leaves no corpse for the sweep
            // to expire, and a freed slot is dropped from the known set
            // without a word, so the client would render the wreck forever.
            if (dmg.destroyed_slot) |ds| self.announceDestroyedEntity(ds, d.entity_id);
            // The crate is destroyed inside damageFrom, so its marker teardown
            // runs here on the captured flag (a killed non-Alive entity never
            // reaches the corpse sweep).
            if (target_was_crate) self.broadcastSupplyCrateMarkerRemove(d.entity_id);
            // Dead players keep the entity (client runs its own death →
            // respawn flow); EntityRemove would delete the local player.
            const target_is_player = if (self.sim.slotOfNetId(d.entity_id)) |ti| self.sim.mask[ti].player else false;
            if (!target_is_player) {
                // Corpse dwell (EntityAlive::OnDeathUpdate): the body stays
                // in world for TimeStayAfterDeath (30 s zombies, 300 s
                // animals) so the client's ragdoll is not yanked mid
                // animation; the tick sweep broadcasts EntityRemove when
                // the dwell expires. The loot bag below still spawns now.
            } else {
                // The death screen spawn list (NetPackageWorldSpawnPoints) is
                // sent from the hp-replicate pass on any player death (C2S and
                // AI kills alike); the client runs its own death screen.
                // DropOnDeath: 0 nothing, 1 all, 2 toolbelt, 3 backpack, 4 delete.
                // Modes 1..3 drop a loot bag at the death position holding the
                // victim's real inventory range; 0/4 drop nothing.
                if (self.drop_on_death >= 1 and self.drop_on_death <= 3) {
                    if (self.sim.slotOfNetId(d.entity_id)) |ti| {
                        self.spawnDeathBag(ti);
                    }
                }
            }
            if (was_zombie) {
                // The victim position rides the kill event so ClearSleepers
                // phases can gate kills to the quest's bound POI.
                const vs_opt = self.sim.slotOfNetId(d.entity_id);
                const vx: f32 = if (vs_opt) |vs| self.sim.transform[vs].x else 0;
                const vz: f32 = if (vs_opt) |vs| self.sim.transform[vs].z else 0;
                systems.questOnZombieKilled(&self.sim, c.slot, vx, vz);
                // Stock SharedKillServer -> SharedKillClient: in-range party
                // mates' EntityKilled quest events fire for the same kill
                // (their shared quest copies advance).
                self.questKillForParty(c.slot, vx, vz);
                // XPMultiplier + party split: award scaled server-side XP for
                // the kill, sharing it with in-range party mates (§2.3).
                self.killXpAward(c.slot, self.xpGainFor(d.entity_id), dmg.kill_scale_pct, d.trap_kill_xp, d.entity_id);
                // Killer's `onSelfKilledOther` buff + perk rows (DeadEye /
                // Berserker adds, stamina/health ModifyStats refunds).
                if (self.sim.playerByPeer(c.slot)) |kps| {
                    if (self.sim.slotOfNetId(d.entity_id)) |vs| {
                        self.fireKilledOther(kps, vs);
                    }
                }
                // Stock GameManager.AwardKill: tell the killer's client so its
                // local EntityKill event fires (kill challenges hang off it).
                self.awardKillNotify(c.slot, d.entity_id);
                // AddScoreClient: the character-sheet zombie-kill counter.
                // Stock EntityAlive.AddScore fires on every zombie kill.
                if (c.zombie_kills < std.math.maxInt(u16)) c.zombie_kills += 1;
                sendScoreUpdate(self, c, 1, 0);
            } else if (target_is_player) {
                // PvP kill (PlayerKillingMode != 0): the killer's playerKills
                // counter, stock EntityAlive.AddScore.
                if (c.player_kills < std.math.maxInt(u16)) c.player_kills += 1;
                sendScoreUpdate(self, c, 0, 1);
            }
            // Stock DroppedLootContainer ECD + bag; refill from loot.xml when known.
            if (dmg.loot_bag_id > 0) {
                self.fillLootBagFromTable(dmg.loot_bag_id, dmg.loot_list, @intCast(d.entity_id), self.lootStageForPlayer(c.slot));
                try self.broadcastLootSpawn(dmg.loot_bag_id);
            }
        }
        return true;
    }
    return false;
}
