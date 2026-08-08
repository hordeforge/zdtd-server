//! Tick orchestration — extracted from game.zig; helpers take *Game.
//! Bodies are verbatim copies from src/server/game.zig (stock asm.il comments kept).
//! game.zig is not edited in this extraction — it retains its own methods as
//! forwarding wrappers will be added by the main swarm step.

const std = @import("std");
const game_mod = @import("game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const packages = @import("../wire/packages.zig");
const world_store = @import("../world/store.zig");
const ecs = @import("../ecs/root.zig");
const clock = @import("../util/clock.zig");

/// PlayerEntityStats survival loop (GAP 22; RE entity-stats.md §2):
/// Food/Water deplete with in-game time (rates from `[sim] rules.progression`,
/// ADR 0021), starving/dehydrated players take over-time damage and
/// well-fed ones regen (UpdatePlayerHealthOT branches), and the changed
/// totals sync to the owner on a throttle. Runs after tickAll so the
/// world clock already advanced.
pub fn tickSurvival(self: *Game, dt: f32) void {
    const prog = self.sim.rules.progression;
    if (prog.food_depletion_per_hour <= 0 and prog.water_depletion_per_hour <= 0) return;
    if (self.sim.director.clock.seconds_per_hour <= 0) return;
    const game_hours = dt / self.sim.director.clock.seconds_per_hour;
    for (&self.clients) |*c| {
        if (!c.joined) continue;
        const ps = self.sim.playerByPeer(c.slot) orelse continue;
        if (!self.sim.mask[ps].health or !self.sim.mask[ps].transform) continue;
        var h = &self.sim.health[ps];
        if (h.max_hp <= 0) continue;
        const food_was = h.food;
        const water_was = h.water;
        h.food = @max(0, h.food - prog.food_depletion_per_hour * game_hours);
        h.water = @max(0, h.water - prog.water_depletion_per_hour * game_hours);
        var hp_delta: f32 = 0;
        if (h.food <= 0 or h.water <= 0) {
            hp_delta -= prog.starvation_damage_per_hour * game_hours;
        } else if (h.food >= prog.well_fed_threshold and h.water >= prog.well_fed_threshold) {
            hp_delta += prog.well_fed_regen_per_hour * game_hours;
        }
        if (hp_delta != 0 and h.hp > 0) {
            h.hp = @min(h.max_hp, @max(0, h.hp + hp_delta));
            self.sim.markDirty(ps, .{ .hp = true });
        }
        if (h.food != food_was or h.water != water_was or hp_delta != 0) {
            if (c.survival_sync_cd <= 0) {
                c.survival_sync_cd = prog.survival_sync_seconds;
                if (c.peer) |peer| {
                    self.sendSurvivalStats(peer, c.entity_id, h.hp, h.max_hp, h.food, h.food_max, h.water, h.water_max) catch |err| {
                        self.harness.counters.inc(.net_send_errors);
                        std.debug.print("zdtd: send survival stats failed: {s}\n", .{@errorName(err)});
                    };
                }
            } else {
                c.survival_sync_cd -= dt;
            }
        }
        // UpdatePlayerStaminaOT: sprinting drains, idle regens; the stale
        // timer clears the sprint latch when the client stops reporting.
        if (c.sprint_stale_cd > 0) {
            c.sprint_stale_cd -= dt;
            if (c.sprint_stale_cd <= 0) c.sprint_speed = 0;
        }
        const stamina_was = h.stamina;
        if (c.sprint_speed > 0) {
            h.stamina = @max(0, h.stamina - prog.stamina_drain_per_second * dt);
        } else {
            h.stamina = @min(h.stamina_max, h.stamina + prog.stamina_regen_per_second * dt);
        }
        if (h.stamina != stamina_was) {
            if (c.survival_sync_cd <= 0) {
                c.survival_sync_cd = prog.survival_sync_seconds;
                if (c.peer) |peer| {
                    self.sendStaminaStats(peer, c.entity_id, h.stamina, h.stamina_max) catch |err| {
                        self.harness.counters.inc(.net_send_errors);
                        std.debug.print("zdtd: send stamina stats failed: {s}\n", .{@errorName(err)});
                    };
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
    return @as(u64, clk.day) * 24 + @as(u64, @intFromFloat(clk.hours));
}

/// AirDropFrequency: spawn a supply crate near a player every N game-hours.
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
    // Damage per bite before scaling (2Hz cadence).
    const base_bite: u32 = 10;
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
        if (len < 0.1 or len > 3.0) continue; // only when pressed against cover
        dx /= len;
        dz /= len;
        const bx: i32 = @intFromFloat(@floor(zt.x + dx));
        const bz: i32 = @intFromFloat(@floor(zt.z + dz));
        const by: i32 = @intFromFloat(@floor(zt.y + 1)); // head height
        const solid = self.world.isSolidWorld(bx, by, bz) catch continue;
        if (!solid) continue;
        const id = self.blockIdAtWorld(bx, by, bz);
        if (id == 0) continue;
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
    const stale_ns: u64 = self.peer_stale_ms *% 1_000_000;
    for (&self.clients) |*c| {
        const p = c.peer orelse continue;
        if (!p.alive) {
            self.harness.counters.inc(.stale_peers_reaped);
            std.debug.print(
                "zdtd: peer reaped dead local_id={d} slot={d} entity={d}\n",
                .{ p.local_id, c.slot, c.entity_id },
            );
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
