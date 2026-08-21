//! Tick orchestration — extracted from game.zig; helpers take *Game.
//! Bodies are verbatim copies from src/server/game.zig (stock asm.il comments kept).
//! game.zig is not edited in this extraction — it retains its own methods as
//! forwarding wrappers will be added by the main swarm step.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const packages = @import("../../wire/packages.zig");
const world_store = @import("../../world/store.zig");
const ecs = @import("../../ecs/root.zig");
const assets_buffs = @import("../../assets/buffs.zig");
const clock = @import("../../util/clock.zig");
const persist = @import("../persist.zig");

/// PlayerEntityStats survival loop (GAP 22; RE entity-stats.md §2):
/// Food/Water deplete with in-game time. Base drain is engine-driven
/// (`Rules.progression` — no XML row carries the rate, see buffs.Survival),
/// but the damage, regen and thresholds come from `buffs.xml` when `Game.buffs`
/// carries them: `buffs.survival()` resolves the stage thresholds, the
/// starvation HP loss and the stamina penalty. Runs after tickAll so the world
/// clock already advanced.
pub fn tickSurvival(self: *Game, dt: f32) void {
    const prog = self.sim.rules.progression;
    const sv = assets_buffs.survival(&self.buffs);
    const use_buff = sv.ok();
    if (prog.food_depletion_per_hour <= 0 and prog.water_depletion_per_hour <= 0) return;
    if (self.sim.director.clock.seconds_per_hour <= 0) return;
    const game_hours = dt / self.sim.director.clock.seconds_per_hour;
    const secs = dt;
    for (&self.clients) |*c| {
        if (!c.joined) continue;
        const ps = self.sim.playerByPeer(c.slot) orelse continue;
        if (!self.sim.mask[ps].health or !self.sim.mask[ps].transform) continue;
        var h = &self.sim.health[ps];
        if (h.max_hp <= 0) continue;
        // Drowning: stock drains the client's local O2 bar first, then the
        // server is authoritative for the hp loss. The head block being water
        // is the depth gate (a submerged body at y <= water surface).
        if (prog.drowning_damage_per_second > 0) {
            const water_id = self.world.terrain_ids.water;
            if (water_id != 0 and self.world.blockWorld(
                @trunc(self.sim.transform[ps].x),
                @as(i32, @trunc(self.sim.transform[ps].y)) + 1,
                @trunc(self.sim.transform[ps].z),
            ) catch 0 == water_id) {
                c.drown_accum += secs;
                if (c.drown_accum >= 1.0) {
                    _ = self.sim.damageFrom(c.entity_id, prog.drowning_damage_per_second * c.drown_accum, -1);
                    c.drown_accum = 0;
                }
            } else {
                c.drown_accum = 0;
            }
        }
        // Radiation: stock BiomeType.Radiated (biomes.xml <biomemap
        // name="radiated"/>) deals damage while the player stands in it.
        if (prog.radiation_damage_per_second > 0) {
            if (self.isRadiatedAt(@trunc(self.sim.transform[ps].x), @trunc(self.sim.transform[ps].z))) {
                c.radiation_accum += secs;
                if (c.radiation_accum >= 1.0) {
                    _ = self.sim.damageFrom(c.entity_id, prog.radiation_damage_per_second * c.radiation_accum, -1);
                    c.radiation_accum = 0;
                }
            } else {
                c.radiation_accum = 0;
            }
        }
        const food_was = h.food;
        const water_was = h.water;
        h.food = @max(0, h.food - prog.food_depletion_per_hour * game_hours);
        h.water = @max(0, h.water - prog.water_depletion_per_hour * game_hours);
        // Well-fed regen and starvation: when buffs.xml is present the
        // thresholds are fractions of max (StatComparePercCurrentToMax); otherwise
        // fall back to Rules. The Rules well_fed_threshold is an absolute that
        // is still parsed for offline worlds, but with stock data the regen gate
        // uses sv.hungry_frac[0] / thirsty_frac[0] (T16).
        var hp_delta: f32 = 0;
        if (use_buff) {
            const starving = (sv.hungry_frac[2] > 0 and h.food <= sv.hungry_frac[2] * h.food_max) or h.food <= 0;
            const dehydrated = (sv.thirsty_frac[2] > 0 and h.water <= sv.thirsty_frac[2] * h.water_max) or h.water <= 0;
            if (starving or dehydrated) {
                const per_s = if (starving and dehydrated)
                    @max(sv.starve_hp_per_s, sv.dehydrate_hp_per_s)
                else if (starving)
                    sv.starve_hp_per_s
                else
                    sv.dehydrate_hp_per_s;
                hp_delta -= per_s * secs;
            } else if (sv.hungry_frac[0] > 0 and sv.thirsty_frac[0] > 0) {
                if (h.food >= sv.hungry_frac[0] * h.food_max and h.water >= sv.thirsty_frac[0] * h.water_max) {
                    hp_delta += prog.well_fed_regen_per_hour * game_hours;
                }
            } else if (h.food >= prog.well_fed_threshold and h.water >= prog.well_fed_threshold) {
                hp_delta += prog.well_fed_regen_per_hour * game_hours;
            }
        } else {
            if (h.food <= 0 or h.water <= 0) {
                hp_delta -= prog.starvation_damage_per_hour * game_hours;
            } else if (h.food >= prog.well_fed_threshold and h.water >= prog.well_fed_threshold) {
                hp_delta += prog.well_fed_regen_per_hour * game_hours;
            }
        }
        if (hp_delta != 0 and h.hp > 0) {
            h.hp = @min(h.max_hp, @max(0, h.hp + hp_delta));
            self.sim.markDirty(ps, .{ .hp = true });
        }
        const survival_changed = h.food != food_was or h.water != water_was or hp_delta != 0;
        if (c.sprint_stale_cd > 0) {
            c.sprint_stale_cd -= dt;
            if (c.sprint_stale_cd <= 0) c.sprint_speed = 0;
        }
        const stamina_was = h.stamina;
        if (c.sprint_speed > 0) {
            if (use_buff and sv.starve_stamina_perc != 0 and (h.food <= 0 or h.water <= 0)) {
                // Stock StaminaChangeOT perc_subtract is on the buff; apply as a
                // fraction of max per second while the relevant stage holds.
                h.stamina = @max(0, h.stamina - @abs(sv.starve_stamina_perc) * h.stamina_max / 100.0 * secs);
            } else {
                h.stamina = @max(0, h.stamina - prog.stamina_drain_per_second * dt);
            }
        } else {
            h.stamina = @min(h.stamina_max, h.stamina + prog.stamina_regen_per_second * dt);
        }
        const stamina_changed = h.stamina != stamina_was;
        if (survival_changed or stamina_changed) {
            if (c.survival_sync_cd <= 0) {
                c.survival_sync_cd = prog.survival_sync_seconds;
                if (c.peer) |peer| {
                    if (survival_changed) {
                        self.sendSurvivalStats(peer, c.entity_id, h.hp, h.max_hp, h.food, h.food_max, h.water, h.water_max) catch |err| {
                            self.harness.counters.inc(.net_send_errors);
                            const n = self.harness.counters.get(.net_send_errors);
                            if (n == 1 or n % 100 == 0) {
                                var ts: [19]u8 = undefined;
                                std.debug.print("zdtd: {s} send survival stats failed local_id={d} entity={d} n={d}: {s}\n", .{ clock.wallStamp(&ts), peer.local_id, c.entity_id, n, @errorName(err) });
                            }
                        };
                    }
                    if (stamina_changed) {
                        self.sendStaminaStats(peer, c.entity_id, h.stamina, h.stamina_max) catch |err| {
                            self.harness.counters.inc(.net_send_errors);
                            const n = self.harness.counters.get(.net_send_errors);
                            if (n == 1 or n % 100 == 0) {
                                var ts: [19]u8 = undefined;
                                std.debug.print("zdtd: {s} send stamina stats failed local_id={d} entity={d} n={d}: {s}\n", .{ clock.wallStamp(&ts), peer.local_id, c.entity_id, n, @errorName(err) });
                            }
                        };
                    }
                }
            } else {
                c.survival_sync_cd -= dt;
            }
        }
    }
}

/// Current whole world-hour (day*24 + hour), for time-based scheduling.
pub fn worldHour(self: *const Game) u64 {
    const clk = self.sim.director.clock;
    return @as(u64, clk.day) * 24 + @as(u64, @trunc(clk.hours));
}

/// AirDropFrequency: spawn a supply crate near a player every N game-hours.
/// DIVERGENCE (RE: aidirector.md airdrop schedule): stock schedules by
/// DAY-COUNT + fixed time-of-day - `SandboxOptions.SetupAirDropTimeRanges`
/// (IL=124) maps options 52/54 to Min/MaxDayCount + Min/MaxTimeOfDay (default
/// 3/3 days, 12:00), and `calcNextAirdrop` (IL=39) picks
/// `day + RandomRange(Min, Max+1) - 1` at that TOD. zdtd's "every N game-hours
/// from the last drop" is a simplification. Also: stock AirDropFrequency=0 does
/// NOT disable (the sandbox option default overrides the 0 pref; live
/// getgamestat reads 3); zdtd's 0 = off is a deliberate policy difference.
pub fn tickAirDrop(self: *Game) void {
    if (self.air_drop_interval_hours == 0) return;
    const now = self.worldHour();
    if (self.next_air_drop_hour == 0) {
        self.next_air_drop_hour = now + self.air_drop_interval_hours;
        return;
    }
    if (now < self.next_air_drop_hour) return;
    self.next_air_drop_hour = now + self.air_drop_interval_hours;
    // Drop above the first joined player.
    for (&self.clients) |*cl| {
        if (!cl.joined) continue;
        const ps = self.sim.playerByPeer(cl.slot) orelse continue;
        const t = self.sim.transform[ps];
        if (self.sim.spawnLootBag(t.x, t.y + 2, t.z, 1, 1)) |bag_nid| {
            self.fillLootBagFromTable(bag_nid, "supplyCrate", @intCast(bag_nid), self.lootStageForPlayer(cl.slot));
            self.broadcastLootSpawn(bag_nid) catch {};
            // AIDirectorAirDropComponent.RefreshCrates (map-objects.md section
            // 8): the one server-push nav marker case, everything else is
            // client-derived. nav_object_classes.xml "supply_drop" is the
            // shipped class name (map/compass/onscreen icon lookup; no display
            // name needed). entity_id ties the marker to the bag so a future
            // NetPackageEntityMapMarkerRemove on crate death has something to
            // reference; not implemented yet, so the marker outlives the loot.
            if (packages.buildNavObjectAdd(self.body_buf[8192..8704], "supply_drop", "", t.x, t.y + 2, t.z, @intCast(bag_nid))) |nb| {
                self.broadcast("NetPackageNavObject", nb) catch {};
            } else |_| {}
            std.debug.print("zdtd: air drop supply crate at ({d:.0},{d:.0}) hour={d}\n", .{ t.x, t.z, now });
        }
        return;
    }
}

/// BlockDamageAI / AIBM: attacking zombies chew through a solid block between
/// them and their target. Scaled by BlockDamageAI (BlockDamageAIBM on blood moon).
pub fn tickZombieBlockDamage(self: *Game) void {
    const mult: u32 = if (self.sim.director.bloodmoon_active) self.block_damage_ai_bm else self.block_damage_ai;
    if (mult == 0) return;
    const base_bite: u32 = @trunc(@max(0, self.sim.rules.progression.block_bite_damage));
    // Cached zombie group: this pass only damages blocks, never spawns or
    // destroys entities, so the slice stays valid for the whole loop.
    for (ecs.groupSlice(&self.sim, .zombie)) |s| {
        const ai = self.sim.zombie_ai[s];
        if (ai.state != .attack and ai.state != .chase) continue;
        const tgt = self.sim.slotOfNetId(ai.target_id) orelse continue;
        const zt = self.sim.transform[s];
        const tt = self.sim.transform[tgt];
        var dx = tt.x - zt.x;
        var dz = tt.z - zt.z;
        const len = @sqrt(dx * dx + dz * dz);
        const block_range = @max(0.1, self.sim.rules.progression.block_damage_range);
        if (len < 0.1 or len > block_range) continue; // only when pressed against cover
        dx /= len;
        dz /= len;
        const bx: i32 = @floor(zt.x + dx);
        const bz: i32 = @floor(zt.z + dz);
        const by: i32 = @floor(zt.y + 1); // head height
        const solid = self.world.isSolidWorld(bx, by, bz) catch continue;
        if (!solid) continue;
        const id = self.blockIdAtWorld(bx, by, bz);
        if (id == 0) continue;
        // Zombies open unlocked doors on their path instead of chewing (RE
        // entity-ai.md CheckForDoorAndOpen: block with the door tag +
        // TEFeatureDoor, SetOpen when not open). Set the open meta bit and
        // broadcast; an already-open door is skipped (no re-broadcast).
        if (self.blocks.byId(id)) |def| {
            if (def.is_door) {
                const raw = self.world.rawWorld(bx, by, bz) catch continue;
                if ((packages.blockMeta(raw) & packages.block_meta_on) == 0) {
                    const open_raw = packages.withBlockMeta(raw, packages.block_meta_on);
                    self.world.setBlockRawWorld(bx, by, bz, open_raw) catch continue;
                    if (packages.buildSetBlockBodyRaw(self.body_buf[0..96], bx, by, bz, open_raw, 0, -1, -1)) |sb| {
                        self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(bx), @floatFromInt(bz), self.interest_range) catch {};
                    } else |_| {}
                }
                continue;
            }
        }
        const dmg: u16 = @intCast(@min(base_bite * mult / 100, 65535));
        const max_hp = self.maxDamageForBlock(id);
        const total = self.addBlockDamage(bx, by, bz, dmg);
        if (total >= max_hp) {
            self.world.setBlockWorld(bx, by, bz, 0) catch continue;
            self.clearBlockHp(bx, by, bz);
            self.clearBlockRaw(bx, by, bz);
            if (packages.buildSetBlockBody(&self.body_buf, bx, by, bz, 0)) |sb| {
                self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(bx), @floatFromInt(bz), self.interest_range) catch {};
            } else |_| {}
        }
    }
}

/// Drop locks held longer than the lock stale window (tick path).
pub fn reapStaleLocks(self: *Game) void {
    const now = clock.monoNs();
    for (&self.lock_channel, 0..) |h, i| {
        if (h < 0) continue;
        const g = self.lock_granted_ns[i];
        if (g == 0) continue;
        if (now -% g >= self.lock_stale_ns) self.clearLockSlot(i);
    }
}

pub fn reapStalePeers(self: *Game) void {
    const now = clock.monoNs();
    const stale_ns: u64 = self.peer_stale_ms *| 1_000_000;
    for (&self.clients) |*c| {
        const p = c.peer orelse continue;
        if (!p.alive) {
            self.harness.counters.inc(.stale_peers_reaped);
            std.debug.print(
                "zdtd: peer reaped dead local_id={d} slot={d} entity={d}\n",
                .{ p.local_id, c.slot, c.entity_id },
            );
            // A hard disconnect (no NetPackagePlayerDisconnect) must not lose
            // the player's data until the next autosave: persist before the
            // slot is cleared (GAP "Save on disconnect / kick"). Pre-join
            // peers have no entity and nothing to save.
            if (c.entity_id > 0) self.savePlayers() catch |e| persist.logPersistErr(self, "save players on reap", e);
            self.clearLocksForPeer(c.slot);
            c.* = .{};
            self.refreshInfoPlayers();
            continue;
        }
        if (p.last_recv_ns == 0) continue;
        if (now -% p.last_recv_ns > stale_ns) {
            self.harness.counters.inc(.stale_peers_reaped);
            std.debug.print(
                "zdtd: peer reaped stale local_id={d} slot={d} entity={d} idle_ms={d}\n",
                .{ p.local_id, c.slot, c.entity_id, (now -% p.last_recv_ns) / 1_000_000 },
            );
            p.alive = false;
            p.authenticated = false;
            for (&p.pending) |*slot| slot.used = false;
            p.local_window_start = p.local_seq;
            if (c.entity_id > 0) self.savePlayers() catch |e| persist.logPersistErr(self, "save players on reap", e);
            self.clearLocksForPeer(c.slot);
            c.* = .{};
            self.refreshInfoPlayers();
        }
    }
}

/// Drop armed policy kicks once the stock 0.5 s grace has elapsed.
/// Bounded by max_clients per tick.
pub fn reapPolicyKicks(self: *Game) void {
    for (&self.clients, 0..) |*cl, i| {
        if (cl.guard.kick_at_tick == 0) continue;
        if (self.tick_n < cl.guard.kick_at_tick) continue;
        if (cl.peer == null) {
            cl.guard.kick_at_tick = 0;
            continue;
        }
        self.dropClientSlot(i, "guard");
    }
}

pub fn clearDeadKnownEntities(self: *Game) void {
    // Most ticks free no slots; skip the reconcile entirely.
    if (!self.sim.any_freed_this_tick) return;
    // Word-wise AND per client against the sim's live set, instead of a
    // per-slot × per-client unset sweep (512×64 every tick).
    for (&self.clients) |*kc| kc.known_entities.setIntersection(self.sim.alive_bits);
    self.sim.any_freed_this_tick = false;
}

/// Drain MoveHelper dig damage requests (RE entity-ai.md DigUpdate): each
/// request damages the sim-marked block with the chew's bite damage; a broken
/// block ends the dig so the zombie walks on.
pub fn drainDigRequests(self: *Game) void {
    const mult: u32 = if (self.sim.director.bloodmoon_active) self.block_damage_ai_bm else self.block_damage_ai;
    if (mult == 0) return;
    const base_bite: u32 = @trunc(@max(0, self.sim.rules.progression.block_bite_damage));
    const n = @min(self.sim.dig_n, self.sim.dig_reqs.len);
    self.sim.dig_n = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const d = self.sim.dig_reqs[i];
        if (!self.sim.alive[d.slot]) continue;
        const solid = self.world.isSolidWorld(d.x, d.y, d.z) catch continue;
        if (!solid) {
            self.sim.zombie_ai[d.slot].digging = false;
            continue;
        }
        const id = self.blockIdAtWorld(d.x, d.y, d.z);
        if (id == 0) continue;
        const dmg: u16 = @intCast(@min(base_bite * mult / 100, 65535));
        const max_hp = self.maxDamageForBlock(id);
        const total = self.addBlockDamage(d.x, d.y, d.z, dmg);
        if (total >= max_hp) {
            self.world.setBlockWorld(d.x, d.y, d.z, 0) catch continue;
            self.clearBlockHp(d.x, d.y, d.z);
            self.clearBlockRaw(d.x, d.y, d.z);
            self.sim.zombie_ai[d.slot].digging = false;
            if (packages.buildSetBlockBody(&self.body_buf, d.x, d.y, d.z, 0)) |sb| {
                self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(d.x), @floatFromInt(d.z), self.interest_range) catch {};
            } else |_| {}
        }
    }
}

/// Drain sleeper wake requests (RE EntityAlive.ConditionalTriggerSleeperWakeUp:
/// broadcasts NetPackageSleeperWakeup, unreliable, to every client when a
/// sleeper zombie wakes - proximity, noise or damage; protocol-packages.md
/// §6.19). Consume-owns-drain like the dig ring. Broadcast, not interest
/// gated: stock ConnectionManager.SendPackage with toEntityId=-1 reaches all
/// clients, and a distant POI waking matters for a client's minimap/audio.
pub fn drainSleeperWakeups(self: *Game) void {
    const n = @min(self.sim.sleeper_wake_n, self.sim.sleeper_wake_reqs.len);
    self.sim.sleeper_wake_n = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s: u16 = self.sim.sleeper_wake_reqs[i].slot;
        if (!self.sim.alive[s] or !self.sim.mask[s].network_id) continue;
        const nid = self.sim.network_id[s].id;
        if (packages.buildSleeperWakeupBody(&self.body_buf, nid)) |body| {
            self.broadcast("NetPackageSleeperWakeup", body) catch {};
        } else |_| {}
    }
}

/// EntityAlive look-at sync (RE protocol-packages.md §5.2.1): broadcasts
/// NetPackageEntityLookAt to tracking players when an awake zombie's look
/// target moves past the stock 0.0016 sqr-delta gate (EntityAlive
/// SetLookPosition, SendPacketToTrackedPlayers). Target = the AI's attack
/// target position, else the investigate spot. Cosmetic head-aim only; no
/// sim authority. The per-slot last-sent state skips re-sends between
/// meaningful target changes.
pub fn tickEntityLookAt(self: *Game) void {
    for (self.sim.kind_groups.slice(.zombie)) |s| {
        if (!self.sim.alive[s] or !self.sim.mask[s].network_id or !self.sim.mask[s].zombie_ai) continue;
        if (!self.sim.mask[s].transform) continue;
        const ai = self.sim.zombie_ai[s];
        if (!ai.alert and !ai.has_spot) continue;
        if (self.sim.mask[s].sleeper and !self.sim.sleeper[s].awake) continue;
        var lx: f32 = 0;
        var ly: f32 = 0;
        var lz: f32 = 0;
        var have = false;
        if (ai.target_id >= 0) {
            if (self.sim.slotOfNetId(ai.target_id)) |t| {
                if (self.sim.alive[t] and self.sim.mask[t].transform) {
                    lx = self.sim.transform[t].x;
                    ly = self.sim.transform[t].y;
                    lz = self.sim.transform[t].z;
                    have = true;
                }
            }
        }
        if (!have and ai.has_spot) {
            lx = ai.spot_x;
            ly = self.sim.transform[s].y;
            lz = ai.spot_z;
            have = true;
        }
        if (!have) continue;
        const st = &self.entity_look_sent[s];
        const dx = lx - st.x;
        const dy = ly - st.y;
        const dz = lz - st.z;
        if (st.sent and dx * dx + dy * dy + dz * dz < 0.0016) continue;
        st.x = lx;
        st.y = ly;
        st.z = lz;
        st.sent = true;
        if (packages.buildEntityLookAtBody(&self.body_buf, self.sim.network_id[s].id, lx, ly, lz)) |body| {
            self.broadcastNear("NetPackageEntityLookAt", body, self.sim.transform[s].x, self.sim.transform[s].z, self.interest_range) catch {};
        } else |_| {}
    }
}
