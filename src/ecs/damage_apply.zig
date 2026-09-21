//! Deferred damage: gravity integrate, fixed-point accumulator apply.
//!
//! Split out of ecs/systems.zig (same code, moved verbatim);
//! re-exported so existing `systems.*` call sites keep working.

const std = @import("std");
const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const max_entities = @import("world.zig").max_entities;
const c = @import("components.zig");
const inventory = @import("inventory.zig");

/// Fixed-point damage unit (1.0 hp = 100). Mirrors systems.zig.
const dmg_scale: u32 = 100;

/// Vertical physics for one AI body (RE entity-movement.md): the feet cell
/// below decides. Solid → grounded (snap onto the block top, clear vy). Air
/// → fall under gravity like the stock physics tick (DefaultMoveEntity
/// friction + gravity in Entity::ccMove); the accumulator is capped so a
/// long drop cannot outrun the per-tick probe. Runs once per AI tick so an
/// idle or attacking body still settles.
pub fn applyGravity(w: *World, s: Slot, dt: f32) void {
    const solid_fn = w.solid_fn orelse return;
    const t = &w.transform[s];
    const ai = &w.zombie_ai[s];
    if (ai.jump_cd > 0) ai.jump_cd -= dt;
    const below: i32 = @floor(t.y - 0.05);
    const rising = ai.jumping and ai.vy > 0;
    // Swim: a submerged body (mid cell is water) floats - gravity scaled by
    // cSwimGravityPer and the 0.91 y-drag (RE entity-ai.md cctor), so it sinks
    // slowly instead of dropping. The ground snap still applies on the bed.
    const sub_y: i32 = @floor(t.y + 0.5);
    const swimming = w.water_fn != null and
        w.water_fn.?(w.water_ctx, @floor(t.x), sub_y, @floor(t.z));
    if (!rising and solid_fn(w.solid_ctx, @floor(t.x), below, @floor(t.z))) {
        t.y = @as(f32, @floatFromInt(below)) + 1.0;
        ai.vy = 0;
    } else {
        if (ai.jumping and ai.vy <= 0) ai.jumping = false; // apex passed; fall lands normally
        // Stock per-tick integrator (RE entity-movement.md): the fall applies
        // World.Gravity then the 0.98 y-drag, so acceleration is ~1.6
        // blocks/s² and the speed self-caps around -3.9 blocks/s. Swimming
        // uses gravity*0.025 and the 0.91 drag (a slow float).
        const applied_gravity: f32 = if (swimming) w.rules.ai.gravity * w.rules.ai.swim_gravity_per else w.rules.ai.gravity;
        const drag: f32 = if (swimming) w.rules.ai.swim_drag_y else 0.98;
        ai.vy = (ai.vy + applied_gravity * dt) * drag;
        ai.vy = @max(ai.vy, w.rules.ai.fall_max_vy);
        t.y += ai.vy * dt;
    }
}

/// Deferred damage accumulates as fixed-point (dmg_scale) to stay atomic-friendly.
pub fn fpDamage(fp: u32) f32 {
    return @as(f32, @floatFromInt(fp)) / @as(f32, @floatFromInt(dmg_scale));
}

pub fn applyDeferredDamage(w: *World, dmg_fp: []const u32, dmg_attacker: []const u16) u32 {
    var applied: u32 = 0;
    // O(live) via the packed alive set. The accumulator is slot-indexed, but
    // only living entities can have been written; scanning the 512-slot table
    // paid for idle capacity every AI tick.
    var it = w.alive_bits.iterator(.{});
    while (it.next()) |idx| {
        const i: Slot = @intCast(idx);
        const fp = dmg_fp[i];
        if (fp == 0) continue;
        if (!w.alive[i] or !w.mask[i].health) continue;
        if (w.kind[i] == .trader) continue;
        // Skip corpses: players stay at hp=0 until respawn; re-applying would
        // only drive hp negative then clamp, with no gameplay purpose.
        if (w.health[i].hp <= 0) continue;
        const amount = fpDamage(fp);
        if (!(amount > 0)) continue;
        // on_player_damage verdict (T15) for the ECS path (zombie melee /
        // deferred accumulator): <0 denies the hit, >0 scales by percent.
        // The attacker is not tracked here, so it reads -1 (unknown).
        var dmg = amount;
        // Class PhysicalDamageResist (passive 41): the armoured classes
        // (zombieSoldier 50, zombieDemolition 60, the swarms 20) take that
        // percent less from every source the SERVER computes. This
        // accumulator's writers are AI melee and turret fire, so a zombie
        // victim resolves its own class row here. Immediate hits (C2S claims,
        // explosions, bots) take the same leg inside World.damageFrom, which
        // this accumulator never calls.
        if (w.kind[i] != .player) {
            const pr = w.classPhysResist(i);
            if (pr > 0) dmg *= 1.0 - @min(pr, 100.0) / 100.0;
        }
        if (w.kind[i] == .player) {
            // GameDifficulty (RE `ItemActionAttack.difficultyModifier`,
            // combat-damage.md): a server (AI) attacker hitting a client-
            // controlled entity scales by IncomingDamage,
            // `round(strength x modifier)`; PvP and AI-vs-AI are unchanged.
            // The deferred accumulator's attackers are AI (zombie melee,
            // turret fire) and only player victims reach this branch, so the
            // mixed-control condition holds by construction. The scale runs
            // before the plugin verdict, matching the C2S path's order.
            dmg = @round(dmg * w.director.damageScale(false, true, &w.rules.difficulty));
            // Resist legs, in stock `EntityAlive::DamageEntity` order: the
            // untagged GeneralDamageResist (passive 40, all damage types) then
            // the physical armor rating (Equipment::CalcDamage). The accumulated
            // attackers here are AI melee (and turret fire aimed at mobs), whose
            // HandItem damage types are all in `Equipment.physicalDamageTypes`,
            // so the armor leg applies. Without this a full-armor player took
            // exactly the naked damage from a zombie.
            dmg *= 1.0 - inventory.generalDamageResist(w, i);
            // Foreign-gated victim rows (Spectral Grace): the accumulator's
            // attacker kind resolves the `other` filter the per-tick fold
            // cannot. A passing Grace also starts its recharge buff through
            // the Game hook (the buff's own start row sets the cvar gate).
            if (w.foreign_resist_fn) |frf| {
                dmg *= 1.0 - frf(w.foreign_resist_ctx, i, dmg_attacker[i]);
            }
            // Victim-side hit trigger: the victim's `onOtherAttackedSelf`
            // rows fire with the accumulator's attacker.
            if (w.attacked_self_fn) |asf| {
                asf(w.attacked_self_ctx, i, dmg_attacker[i]);
            }
            if (w.player[i].peer_slot >= 0) {
                // Attacker-aware armor (Preacher vs zombies): the Vs form
                // folds the piece's foreign-gated rows against the
                // accumulator's attacker; unset attacker = today's armor.
                const atk: ?Slot = if (dmg_attacker[i] < max_entities) dmg_attacker[i] else null;
                dmg *= 1.0 - inventory.armorMitigationVs(w, @intCast(w.player[i].peer_slot), atk);
            }
            if (w.player_damage_verdict_fn) |vdf| {
                const v = vdf(w.player_damage_verdict_ctx, w.network_id[i].id, dmg);
                if (v < 0) continue;
                if (v > 0) dmg = dmg * @as(f32, @floatFromInt(v)) / 100.0;
            }
        }
        if (!(dmg > 0)) continue;
        w.health[i].hp -= dmg;
        applied += 1;
        // Stock's Stat setter raises Stat.Changed and EntityStats::TickWait
        // turns that into a stat-change package (asm.il:199393). dirty.hp is
        // that flag here: without it the victim's client never sees the hit.
        w.markDirty(i, .{ .hp = true });
        if (w.health[i].hp <= 0) {
            // Kill verdict (T15): a plugin may deny the death; the victim
            // survives at 1 hp and the hit is consumed. The attacker is not
            // tracked by the deferred accumulator, so it reads -1 (unknown).
            if (w.kill_verdict_fn) |vf| {
                if (vf(w.kill_verdict_ctx, w.kind[i], w.network_id[i].id, -1) < 0) {
                    w.health[i].hp = 1;
                    continue;
                }
            }
            // Dead players keep their entity (stock death → respawn flow).
            if (w.kind[i] == .player) {
                w.health[i].hp = 0;
            } else {
                w.destroy(i);
            }
        }
    }
    return applied;
}
