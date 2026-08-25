//! Tick orchestration — extracted from game.zig; helpers take *Game.
//! Bodies are verbatim copies from src/server/game.zig (stock asm.il comments kept).
//! game.zig is not edited in this extraction — it retains its own methods as
//! forwarding wrappers will be added by the main swarm step.

const std = @import("std");
const apm = @import("../../apm/root.zig");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const packages = @import("../../wire/packages.zig");
const world_store = @import("../../world/store.zig");
const ecs = @import("../../ecs/root.zig");
const assets_buffs = @import("../../assets/buffs.zig");
const assets_progression = @import("../../assets/progression.zig");
const clock = @import("../../util/clock.zig");
const persist = @import("../persist.zig");
const admin_cmds = @import("../admin_cmds.zig");
const admin_xml = @import("../admin_xml.zig");
const game_social = @import("social.zig");
const io_fs = @import("../../util/io_fs.zig");

/// PlayerEntityStats survival loop (GAP 22; RE entity-stats.md §2):
/// Food/Water deplete with in-game time. Base drain is engine-driven
/// (`Rules.progression` — no XML row carries the rate, see buffs.Survival),
/// but the damage, regen and thresholds come from `buffs.xml` when `Game.buffs`
/// carries them: `buffs.survival()` resolves the stage thresholds, the
/// starvation HP loss and the stamina penalty. Runs after tickAll so the world
/// clock already advanced.
pub fn tickSurvival(self: *Game, dt: f32) void {
    // APM (P4b): the per-player effects pass (passive-effects VM + triggered
    // engine + stat application) is bounded by the client table; the section
    // timer + survival_players/vm_recomputes counters keep it inside the
    // 50 ms budget as player counts scale.
    const sc = apm.profiler.scope(&self.harness.prof, .survival);
    defer sc.end();
    const prog = self.sim.rules.progression;
    const sv = assets_buffs.survival(&self.buffs);
    const use_buff = sv.ok();
    const check01_id = assets_buffs.survivalCheckId(&self.buffs);
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
        self.harness.counters.inc(.survival_players);
        if (use_buff) self.harness.counters.add(.vm_recomputes, 3); // engine + effectTotals + perkTotals
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
                    // Wasm-first (AGENTS rule 29): environmental damage passes
                    // the on_player_damage verdict with attacker -1, so a
                    // module scales/denies drowning like any other player hit.
                    const dmg = game_mod.playerDamageVerdictAmount(self, -1, c.entity_id, prog.drowning_damage_per_second * c.drown_accum);
                    if (dmg > 0) _ = self.sim.damageFrom(c.entity_id, dmg, -1);
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
                    // Wasm-first (AGENTS rule 29): verdict with attacker -1,
                    // like drowning above.
                    const dmg = game_mod.playerDamageVerdictAmount(self, -1, c.entity_id, prog.radiation_damage_per_second * c.radiation_accum);
                    if (dmg > 0) _ = self.sim.damageFrom(c.entity_id, dmg, -1);
                    c.radiation_accum = 0;
                }
            } else {
                c.radiation_accum = 0;
            }
        }
        const food_was = h.food;
        const water_was = h.water;
        const max_hp_was = h.max_hp;
        const food_max_was = h.food_max;
        const water_max_was = h.water_max;
        const stamina_max_was = h.stamina_max;
        h.food = @max(0, h.food - prog.food_depletion_per_hour * game_hours);
        h.water = @max(0, h.water - prog.water_depletion_per_hour * game_hours);
        // Well-fed regen and starvation: when buffs.xml is present the
        // thresholds are fractions of max (StatComparePercCurrentToMax); otherwise
        // fall back to Rules. The Rules well_fed_threshold is an absolute that
        // is still parsed for offline worlds, but with stock data the regen gate
        // uses sv.hungry_frac[0] / thirsty_frac[0] (T16).
        var hp_delta: f32 = 0;
        var stamina_penalty: f32 = 0;
        var stamina_ot_bonus: f32 = 0;
        if (use_buff) {
            // Passive-effects VM (assets/buffs.zig): keep the matching
            // conditional stage buffs (buffStatusHungry/Thirsty01..03) in the
            // entity's BuffSet - the stage IS the starving/dehydrated state -
            // and drive the stamina penalty from the VM's StaminaChangeOT
            // total. Revertible: removing a stage buff recomputes the deltas
            // without it (additive deltas, recompute-from-set).
            //
            // Triggered-effect engine (P3): buffStatusCheck01's onSelfBuffUpdate
            // AddBuff rows, gated by StatComparePercCurrentToMax (fractions of
            // max), select the wanted stage buffs - the data replaces the
            // hand-rolled survivalStages selector.
            const cid = check01_id orelse continue;
            const check_res = assets_buffs.evaluateTriggered(&self.buffs, cid, .update, .{
                .food_frac = if (h.food_max > 0) h.food / h.food_max else 0,
                .water_frac = if (h.water_max > 0) h.water / h.water_max else 0,
            });
            const wanted = check_res.add_buffs[0..check_res.add_n];
            syncStageBuffs(self, c.entity_id, ps, wanted);
            const stages = assets_buffs.stagesFromWanted(wanted);
            const vm = assets_buffs.effectTotals(&self.buffs, &self.sim.buffs[ps]);
            // Perk leg (level-scaled): purchased attribute/perk passives fold
            // through the same VM surface, revertible by recompute-from-set.
            const pvm = assets_progression.perkTotals(&self.progression_table, c.skill_levels[0..c.skill_level_n]);
            // Armor: buff + perk PhysicalDamageResist join the mitigation like
            // stock GetTotalPhysicalArmorRating sums passive 41 on the wearer.
            self.sim.buff_phys_resist[ps] = vm.phys_resist + pvm.phys_resist;
            // Perk/buff max-stat deltas: unconditional recompute from the
            // bases every tick (revertible recompute-from-set - a zero delta
            // restores the spawn max; the values are stable so no churn).
            const mhp = vm.hp_max + pvm.hp_max;
            h.max_hp = @max(1, h.base_max_hp + mhp);
            if (h.hp > h.max_hp) {
                h.hp = h.max_hp;
                self.sim.markDirty(ps, .{ .hp = true });
            }
            const mfood = vm.food_max + pvm.food_max;
            h.food_max = @max(1, 100 + mfood);
            const mwater = vm.water_max + pvm.water_max;
            h.water_max = @max(1, 100 + mwater);
            const mstam = vm.stamina_max + pvm.stamina_max;
            h.stamina_max = @max(1, 100 + mstam);
            const starving = stages.hungry == 3;
            const dehydrated = stages.thirsty == 3;
            if (starving or dehydrated) {
                // HP-loss leg: stock is a triggered `ModifyStats Health
                // subtract` on the active stage-3 buff's update (not a
                // passive); the VM resolves the rate off the active stage.
                const per_s = assets_buffs.stage3HpLossPerSecond(&self.buffs, stages);
                if (per_s > 0) {
                    // Wasm-first (AGENTS rule 29): verdict with attacker -1,
                    // like drowning/radiation above.
                    hp_delta -= game_mod.playerDamageVerdictAmount(self, -1, c.entity_id, per_s * secs);
                }
            } else if (sv.hungry_frac[0] > 0 and sv.thirsty_frac[0] > 0) {
                if (h.food >= sv.hungry_frac[0] * h.food_max and h.water >= sv.thirsty_frac[0] * h.water_max) {
                    hp_delta += prog.well_fed_regen_per_hour * game_hours;
                }
            } else if (h.food >= prog.well_fed_threshold and h.water >= prog.well_fed_threshold) {
                hp_delta += prog.well_fed_regen_per_hour * game_hours;
            }
            // Perk/buff HealthChangeOT: stock applies the OT rate per second
            // (perkHealingFactor .011..16, well-rested regen), composing with
            // the starvation/regen branches above.
            const hp_ot = vm.hp_ot + pvm.hp_ot;
            if (hp_ot != 0) hp_delta += hp_ot * secs;
            // Stamina OT consumer (perk/buff StaminaChangeOT): the VM's
            // perc fraction of max per second joins the idle regen (stock
            // applies the buff's OT continuously; perkRuleOneCardio .1..3
            // adds a regen bonus, the stage-3 starvation buff drains while
            // idle too). The sprint branch keeps the stage-3 penalty.
            stamina_ot_bonus = (vm.stamina_ot + pvm.stamina_ot) * h.stamina_max / 100.0;
            // Stamina penalty: stock `StaminaChangeOT perc_subtract .1` on
            // buffStatusHungry03 while its stage holds. The gate moved from
            // "food/water <= 0" to "stage-3 buff active" (the stock 2%
            // threshold); the arithmetic is unchanged.
            if (c.sprint_speed > 0 and vm.stamina_ot != 0 and (stages.hungry == 3 or stages.thirsty == 3)) {
                stamina_penalty = @abs(vm.stamina_ot) * h.stamina_max / 100.0 * secs;
            }
        } else {
            if (h.food <= 0 or h.water <= 0) {
                // Wasm-first (AGENTS rule 29): verdict with attacker -1, like
                // drowning/radiation above.
                hp_delta -= game_mod.playerDamageVerdictAmount(self, -1, c.entity_id, prog.starvation_damage_per_hour * game_hours);
            } else if (h.food >= prog.well_fed_threshold and h.water >= prog.well_fed_threshold) {
                hp_delta += prog.well_fed_regen_per_hour * game_hours;
            }
        }
        if (hp_delta != 0 and h.hp > 0) {
            h.hp = @min(h.max_hp, @max(0, h.hp + hp_delta));
            self.sim.markDirty(ps, .{ .hp = true });
        }
        const survival_changed = h.food != food_was or h.water != water_was or hp_delta != 0 or
            h.max_hp != max_hp_was or h.food_max != food_max_was or h.water_max != water_max_was or
            h.stamina_max != stamina_max_was;
        if (c.sprint_stale_cd > 0) {
            c.sprint_stale_cd -= dt;
            if (c.sprint_stale_cd <= 0) c.sprint_speed = 0;
        }
        const stamina_was = h.stamina;
        if (c.sprint_speed > 0) {
            if (stamina_penalty > 0) {
                h.stamina = @max(0, h.stamina - stamina_penalty);
            } else {
                h.stamina = @max(0, h.stamina - prog.stamina_drain_per_second * dt);
            }
        } else {
            h.stamina = @min(h.stamina_max, h.stamina + (prog.stamina_regen_per_second + stamina_ot_bonus) * dt);
        }
        const stamina_changed = h.stamina != stamina_was;
        // Stat-changed observer (ADR 0034): one bounded call per changed
        // player per tick - plugins react/announce; the sim stays authority.
        if (survival_changed or stamina_changed) {
            self.statChangedObserver( c.entity_id, @intFromFloat(h.hp), @intFromFloat(h.food), @intFromFloat(h.water), @intFromFloat(h.stamina), c.level, @intCast(@min(c.xp, std.math.maxInt(i32))));
        }
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

/// Keep the conditional survival stage buffs (buffStatusHungry/Thirsty01..03)
/// in the entity's BuffSet matching the resolved stages, relaying adds so the
/// stock client shows the same HUD state. Revertible: a stage change removes
/// the stale buff (flagged; the buff tick relays the removal) and the VM
/// recomputes its deltas without it. No-op when the stages already match.
fn syncStageBuffs(self: *Game, entity_id: i32, ps: ecs.Slot, wanted: []const []const u8) void {
    const set = self.sim.buffsMut(ps);
    var remove_ids: [4]u16 = undefined;
    var n_rem: usize = 0;
    for (&set.slots) |*slot| {
        if (!slot.active) continue;
        const def = self.buffs.byId(slot.def_id) orelse continue;
        const is_hungry = std.mem.startsWith(u8, def.name, "buffStatusHungry");
        const is_thirsty = std.mem.startsWith(u8, def.name, "buffStatusThirsty");
        if (!is_hungry and !is_thirsty) continue;
        var is_wanted = false;
        for (wanted) |w| {
            if (std.mem.eql(u8, w, def.name)) {
                is_wanted = true;
                break;
            }
        }
        if (!is_wanted and n_rem < remove_ids.len) {
            remove_ids[n_rem] = slot.def_id;
            n_rem += 1;
        }
    }
    for (remove_ids[0..n_rem]) |id| {
        _ = ecs.buff.remove(set, id);
    }
    // The engine may select several stage buffs at once (boundary fractions
    // pass two hungry + two thirsty rows); each is added unless already
    // active (buff.zig stacking keeps repeats idempotent).
    for (wanted) |name| {
        const def_id = self.buffs.indexOfName(name) orelse continue;
        if (set.find(def_id) != null) continue;
        const def = self.buffs.byId(def_id) orelse continue;
        _ = ecs.buff.add(set, .{
            .def_id = def_id,
            .duration = def.duration,
            .stack_type = def.stack_type,
            .update_rate_ticks = def.update_rate_ticks,
            .remove_on_death = def.remove_on_death,
        }, ecs.buff.duration_from_class, -1, 0, 0, 0);
        game_social.relayBuff(self, entity_id, def.name, true, -1, null) catch {};
    }
}

/// Current whole world-hour (day*24 + hour), for time-based scheduling.
pub fn worldHour(self: *const Game) u64 {
    const clk = self.sim.director.clock;
    return @as(u64, clk.day) * 24 + @as(u64, @trunc(clk.hours));
}

/// Next scheduled airdrop as a world-hour. "interval" (default): every
/// `AirDropFrequency` game-hours from the last drop (the pre-config behavior).
/// "days" (`[sim] airdrop_schedule = "days"`): the stock-like day-count + TOD
/// schedule - `SandboxOptions.SetupAirDropTimeRanges` (IL=124) maps options
/// 52/54 to Min/MaxDayCount + Min/MaxTimeOfDay (default 3/3 days, 12:00), and
/// `calcNextAirdrop` (IL=39) picks `day + RandomRange(Min, Max+1) - 1` at that
/// TOD; zdtd replays that deterministically (same seed → same schedule) by
/// scheduling at day_min + k*(day_max - day_min + 1) days at the drop hour.
pub fn nextAirdropHour(self: *const Game, now: u64) u64 {
    if (self.airdrop_schedule == .days) {
        const span: u64 = @max(1, @as(u64, self.airdrop_day_max) -| self.airdrop_day_min + 1);
        const start: u64 = @as(u64, self.airdrop_day_min) * 24 + self.airdrop_drop_hour;
        if (now < start) return start;
        return start + ((now - start) / (span * 24) + 1) * (span * 24);
    }
    return now + self.air_drop_interval_hours;
}

/// AirDropFrequency: spawn a supply crate near a player every N game-hours.
/// DIVERGENCE (RE: aidirector.md airdrop schedule): stock schedules by
/// DAY-COUNT + fixed time-of-day - see nextAirdropHour above; `[sim]
/// airdrop_schedule = "days"` restores that. Also: stock AirDropFrequency=0
/// does NOT disable (the sandbox option default overrides the 0 pref; live
/// getgamestat reads 3); zdtd's 0 = off is a deliberate policy difference.
pub fn tickAirDrop(self: *Game) void {
    const enabled = if (self.airdrop_schedule == .days)
        self.airdrop_day_max > 0
    else
        self.air_drop_interval_hours > 0;
    if (!enabled) return;
    const now = self.worldHour();
    if (self.next_air_drop_hour == 0) {
        self.next_air_drop_hour = nextAirdropHour(self, now);
        return;
    }
    if (now < self.next_air_drop_hour) return;
    self.next_air_drop_hour = nextAirdropHour(self, now);
    // Drop above the first joined player.
    for (&self.clients) |*cl| {
        if (!cl.joined) continue;
        const ps = self.sim.playerByPeer(cl.slot) orelse continue;
        const t = self.sim.transform[ps];
        if (self.sim.spawnLootBag(t.x, t.y + 2, t.z, 1, 1)) |bag_nid| {
            // `[sim] airdrop_loot_list` (default stock "airDrop"; the old
            // "supplyCrate" name does not exist in stock loot.xml and rolled
            // empty crates - fixed here).
            self.fillLootBagFromTable(bag_nid, self.airdrop_loot_list, @intCast(bag_nid), self.lootStageForPlayer(cl.slot));
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
    // Per-class chew: the hand item's DamageBlock (zombie 8, feral 24) when
    // the class resolved one; the Rules floor otherwise.
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
        // The cell the zombie collides with sits at its body height: probe
        // the front column from feet to head and chew the first solid cell.
        // The old single head-height probe left zombies stuck against
        // 1-block-tall walls/fences (the head cell is air while the wall is
        // at feet level), so they never broke out.
        const feet_y: i32 = @floor(zt.y);
        const head_y: i32 = @floor(zt.y + 1);
        const by: i32 = blk: {
            var yi: i32 = feet_y;
            while (yi <= head_y) : (yi += 1) {
                if (self.world.isSolidWorld(bx, yi, bz) catch false) break :blk yi;
            }
            break :blk -1;
        };
        if (by < 0) continue;
        const id = self.blockIdAtWorld(bx, by, bz);
        if (id == 0) continue;
        // Zombies open unlocked doors on their path instead of chewing (RE
        // entity-ai.md CheckForDoorAndOpen: block with the door tag +
        // TEFeatureDoor, SetOpen when not open). Set the open meta bit and
        // broadcast; an already-open door is skipped (no re-broadcast). A
        // 2-tall door spans two cells, so the vertical partner gets the same
        // open bit (the probe may have landed on either half).
        if (self.blocks.byId(id)) |def| {
            if (def.is_door) {
                const door_dys = [_]i32{ 0, 1, -1 };
                for (door_dys) |dy| {
                    const yy = by + dy;
                    if (self.blockIdAtWorld(bx, yy, bz) != id) continue;
                    const raw = self.world.rawWorld(bx, yy, bz) catch continue;
                    if ((packages.blockMeta(raw) & packages.block_meta_on) != 0) continue;
                    const open_raw = packages.withBlockMeta(raw, packages.block_meta_on);
                    self.world.setBlockRawWorld(bx, yy, bz, open_raw) catch continue;
                    if (packages.buildSetBlockBodyRaw(self.body_buf[0..96], bx, yy, bz, open_raw, 0, -1, -1)) |sb| {
                        self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(bx), @floatFromInt(bz), self.interest_range) catch {};
                    } else |_| {}
                }
                continue;
            }
        }
        // Per-class chew: hand-item DamageBlock (zombie 8, feral 24) beats
        // the flat Rules floor when the class resolved one.
        const chew: u32 = if (self.sim.class_id[s].block_chew > 0)
            @trunc(self.sim.class_id[s].block_chew)
        else
            base_bite;
        const dmg: u16 = @intCast(@min(chew * mult / 100, 65535));
        const max_hp = self.maxDamageForBlock(id);
        const total = self.addBlockDamage(bx, by, bz, dmg) catch continue;
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
    // Per-class chew floor: hand-item DamageBlock beats the flat Rules value.
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
        const chew: u32 = if (self.sim.class_id[d.slot].block_chew > 0)
            @trunc(self.sim.class_id[d.slot].block_chew)
        else
            base_bite;
        const dmg: u16 = @intCast(@min(chew * mult / 100, 65535));
        const max_hp = self.maxDamageForBlock(id);
        const total = self.addBlockDamage(d.x, d.y, d.z, dmg) catch continue;
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
        // Slot recycled onto a new entity: the previous occupant's last-sent
        // target must not gate this one's first look (spawnBase bumped gen).
        if (st.gen != self.sim.network_id[s].gen) st.* = .{ .gen = self.sim.network_id[s].gen };
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

/// NetPackageClientInfo broadcast (RE ConnectionManager.updateClientInfo:
/// 5 s cadence): the per-player list (entityId, ping, admin flag) that drives
/// the player list UI and admin crowns. Ping is 0 (zdtd has no RTT
/// measurement; documented residual), admin = the name is in the permission
/// list.
/// Stock serveradmin.xml hot-reload (AdminTools.InitFileWatcher ->
/// OnFileChanged -> Load, IL=33/5): poll the file's mtime every 5 s and
/// re-apply the XML on change. The .zsv list files stay the runtime-persisted
/// form, so an operator editing serveradmin.xml while the server runs sees
/// the change without a restart (bans, whitelist and admin levels).
pub fn tickServerAdminReload(self: *Game) void {
    if (self.serveradmin_reload_timer > 0) {
        self.serveradmin_reload_timer -= 1;
        return;
    }
    self.serveradmin_reload_timer = 100; // 5 s at 20 TPS
    const path = self.serveradmin_path orelse return;
    const mtime = io_fs.fileMtimeNanos(path) orelse return;
    if (mtime == self.serveradmin_mtime) return;
    self.serveradmin_mtime = mtime;
    // Replace the XML-sourced portion (entries removed from the file must
    // disappear); runtime (.zsv) entries are untouched.
    self.admin_list.clearXml();
    self.whitelist.clearXml();
    self.ban_list.clearXml();
    admin_xml.load(self.allocator, path, &self.admin_list, &self.whitelist, &self.ban_list) catch |err| {
        var ts: [19]u8 = undefined;
        std.debug.print("zdtd: {s} warning: serveradmin.xml reload failed: {s}\n", .{ clock.wallStamp(&ts), @errorName(err) });
        return;
    };
    std.debug.print("zdtd: serveradmin.xml reloaded (mtime {d})\n", .{mtime});
}

pub fn tickClientInfo(self: *Game) void {
    if (self.client_info_timer > 0) {
        self.client_info_timer -= 1;
        return;
    }
    self.client_info_timer = 100; // 5 s at 20 TPS (stock timer value)
    var entries: [game_mod.max_clients]packages.ClientInfoEntry = undefined;
    var n: usize = 0;
    for (&self.clients) |*c| {
        if (!c.joined or c.entity_id <= 0) continue;
        if (n >= entries.len) break;
        // Admin flag: platform-id composite (serveradmin.xml / admin add on
        // an online session) or the login name (name-keyed entries).
        var is_admin = c.name_len != 0 and self.admin_list.find(c.name[0..c.name_len]) != null;
        if (!is_admin) {
            if (c.puid_primary.get()) |pid| {
                var key_buf: [admin_cmds.max_id]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ pid.platform, pid.id }) catch "";
                if (key.len != 0) is_admin = self.admin_list.find(key) != null;
            }
        }
        entries[n] = .{ .entity_id = c.entity_id, .ping_ms = 0, .admin = is_admin };
        n += 1;
    }
    if (n == 0) return;
    if (packages.buildClientInfoBody(&self.body_buf, entries[0..n])) |body| {
        self.broadcast("NetPackageClientInfo", body) catch {};
    } else |_| {}
}

test "per-slot look cache resets when the slot is recycled" {
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_lookcache", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    const aid = g.sim.spawnZombie(5, 70, 5, 40).?;
    const s = g.sim.slotOfNetId(aid).?;
    // allocSlot picks the lowest free slot, so every slot below s is occupied
    // by init entities and stays occupied: after the destroy below, s is the
    // lowest free slot again and the next spawn reuses it.
    g.sim.zombie_ai[s].alert = true;
    g.sim.zombie_ai[s].has_spot = true;
    g.sim.zombie_ai[s].spot_x = 10;
    g.sim.zombie_ai[s].spot_z = 20;
    g.tickEntityLookAt();
    try std.testing.expect(g.entity_look_sent[s].sent);
    const old_gen = g.sim.network_id[s].gen;
    try std.testing.expectEqual(old_gen, g.entity_look_sent[s].gen);

    // Recycle the slot onto a new zombie whose first look target equals the
    // previous occupant's last-sent one. The stale entry must not gate the
    // new entity's look: the gen mismatch resets the cache, so the pass
    // re-sends and re-pins to the new generation.
    g.sim.destroy(s);
    g.sim.beginTick();
    const bid = g.sim.spawnZombie(5, 70, 5, 40).?;
    const s2 = g.sim.slotOfNetId(bid).?;
    try std.testing.expectEqual(s, s2);
    g.sim.zombie_ai[s2].alert = true;
    g.sim.zombie_ai[s2].has_spot = true;
    g.sim.zombie_ai[s2].spot_x = 10;
    g.sim.zombie_ai[s2].spot_z = 20;
    g.tickEntityLookAt();
    try std.testing.expectEqual(old_gen + 1, g.entity_look_sent[s2].gen);
    try std.testing.expect(g.entity_look_sent[s2].sent);
}
