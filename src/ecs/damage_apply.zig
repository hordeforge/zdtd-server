//! Deferred damage: gravity integrate, fixed-point accumulator apply.
//!
//! Split out of ecs/systems.zig (same code, moved verbatim);
//! re-exported so existing `systems.*` call sites keep working.

const std = @import("std");
const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const max_entities = @import("world.zig").max_entities;
const c = @import("components.zig");
const systemZombieAi = @import("ai_tasks.zig").systemZombieAi;
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

test "zombie melee marks the victim hp dirty so replication can see it" {
    // Regression: applyDeferredDamage used to subtract hp and set nothing, so the
    // replicate pass had no way to know a player had been hit and the client was
    // never told. Stock raises Stat.Changed on every stat write and the entity
    // tick turns that into a stat-change package (asm.il:199393).
    var w: World = .{};
    defer w.deinit();
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    _ = w.spawnZombie(1, 70, 0, 40).?;
    const ps = w.slotOfNetId(p).?;
    w.dirty[ps] = .{};
    var t: f32 = 0;
    while (t < 3.0 and w.health[ps].hp >= 100) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(w.health[ps].hp < 100);
    try std.testing.expect(w.dirty[ps].hp);
}
test "class PhysicalDamageResist halves server-computed damage" {
    // entityclasses `PhysicalDamageResist` (passive 41): zombieSoldier 50,
    // zombieDemolition 60. This deferred accumulator and the turret apply loop
    // scale their damage by (1 - resist/100); every immediate hit (C2S claims,
    // explosions, bots, traps) resolves the same stat inside World.damageFrom
    // instead, because neither of these two paths goes through it.
    var w: World = .{};
    defer w.deinit();
    var zk: [max_entities]u16 = .{std.math.maxInt(Slot)} ** max_entities;
    const z = w.spawnZombie(0, 70, 0, 200).?;
    const zs = w.slotOfNetId(z).?;
    w.class_id[zs].phys_resist = 50;
    var dmg_fp: [max_entities]u32 = .{0} ** max_entities;
    dmg_fp[zs] = 1000; // 10.0 hp -> 5.0 after 50%
    try std.testing.expectEqual(@as(u32, 1), applyDeferredDamage(&w, dmg_fp[0..], zk[0..]));
    try std.testing.expectEqual(@as(f32, 195.0), w.health[zs].hp);
    // The class_table row is the fallback when the per-entity stat is unset
    // (a classe spawned through the plain path).
    const z2 = w.spawnZombie(2, 70, 2, 200).?;
    const zs2 = w.slotOfNetId(z2).?;
    w.class_id[zs2] = .{ .id = 1 }; // zombie kind slot
    w.class_table[1].phys_resist = 60;
    dmg_fp[zs] = 0;
    dmg_fp[zs2] = 1000; // 10.0 -> 4.0
    _ = applyDeferredDamage(&w, dmg_fp[0..], zk[0..]);
    try std.testing.expectEqual(@as(f32, 196.0), w.health[zs2].hp);
    // A plain class (no rows) is unchanged: clear the row the case above set,
    // since a plain zombie resolves the kind's class_table entry.
    w.class_table[1].phys_resist = 0;
    const z3 = w.spawnZombie(4, 70, 4, 200).?;
    const zs3 = w.slotOfNetId(z3).?;
    dmg_fp[zs2] = 0;
    dmg_fp[zs3] = 1000;
    _ = applyDeferredDamage(&w, dmg_fp[0..], zk[0..]);
    try std.testing.expectEqual(@as(f32, 190.0), w.health[zs3].hp);
}
test "deferred damage that kills a player leaves a dirty corpse at hp 0" {
    // Death must stay replicable: the hp=0 write is what drives the client death
    // screen, so the dirty bit has to survive the kill branch.
    var w: World = .{};
    defer w.deinit();
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    w.health[ps].hp = 1;
    w.dirty[ps] = .{};
    var dmg_fp: [max_entities]u32 = .{0} ** max_entities;
    var zk: [max_entities]u16 = .{std.math.maxInt(Slot)} ** max_entities;
    dmg_fp[ps] = 500; // 5.0 hp
    try std.testing.expectEqual(@as(u32, 1), applyDeferredDamage(&w, dmg_fp[0..], zk[0..]));
    try std.testing.expectEqual(@as(f32, 0), w.health[ps].hp);
    try std.testing.expect(w.alive[ps]);
    try std.testing.expect(w.dirty[ps].hp);
    // A corpse takes no further hits, so nothing re-dirties it.
    w.dirty[ps].hp = false;
    try std.testing.expectEqual(@as(u32, 0), applyDeferredDamage(&w, dmg_fp[0..], zk[0..]));
    try std.testing.expect(!w.dirty[ps].hp);
}
test "GameDifficulty damage scale: AI->player x IncomingDamage at the deferred choke" {
    // RE `ItemActionAttack.difficultyModifier` (combat-damage.md): a server
    // (AI) attacker vs a client entity scales by IncomingDamageModifier,
    // `round(strength x modifier)`; PvP and AI-vs-AI leave strength
    // unchanged. The default world is Adventurer (difficulty 1 - the stock
    // default game: the shipped serverconfig SandboxCode is the Adventurer
    // preset and a live dedi reports GameDifficulty stat = 1, whose
    // IncomingDamage decodes to 0.75 from the embedded preset XML).
    var w: World = .{};
    defer w.deinit();
    try std.testing.expectEqual(@as(u8, 1), w.director.difficulty);
    // Same-control pairs unchanged; mixed pairs read the config ladders.
    try std.testing.expectEqual(@as(f32, 1.0), w.director.damageScale(false, false, &w.rules.difficulty));
    try std.testing.expectEqual(@as(f32, 1.0), w.director.damageScale(true, true, &w.rules.difficulty));
    try std.testing.expectEqual(@as(f32, 0.75), w.director.damageScale(false, true, &w.rules.difficulty));
    try std.testing.expectEqual(@as(f32, 1.0), w.director.damageScale(true, false, &w.rules.difficulty));
    // AI -> player: round(8.0 x 0.75) = 6.0.
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    w.health[ps].hp = 100;
    var dmg_fp: [max_entities]u32 = .{0} ** max_entities;
    var zk: [max_entities]u16 = .{std.math.maxInt(Slot)} ** max_entities;
    dmg_fp[ps] = 800; // 8.0 hp
    try std.testing.expectEqual(@as(u32, 1), applyDeferredDamage(&w, dmg_fp[0..], zk[0..]));
    try std.testing.expectEqual(@as(f32, 94.0), w.health[ps].hp);
    // Config wins: an operator raising the Adventurer incoming scale lifts it.
    w.rules.difficulty.incoming_damage_1 = 1.25; // difficulty 1 = Adventurer
    w.health[ps].hp = 100;
    try std.testing.expectEqual(@as(u32, 1), applyDeferredDamage(&w, dmg_fp[0..], zk[0..]));
    try std.testing.expectEqual(@as(f32, 90.0), w.health[ps].hp); // 8 x 1.25 = 10
    // AI -> AI (turret fire on a zombie) is unchanged by the difficulty scale.
    const z = w.spawnZombie(1, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    w.health[zs].hp = 100;
    var zfp: [max_entities]u32 = .{0} ** max_entities;
    zfp[zs] = 800;
    try std.testing.expectEqual(@as(u32, 1), applyDeferredDamage(&w, zfp[0..], zk[0..]));
    try std.testing.expectEqual(@as(f32, 92.0), w.health[zs].hp); // 8.0 flat
}
test "deferred AI damage passes GeneralDamageResist and the armor leg" {
    // Stock EntityAlive::DamageEntity order: GeneralDamageResist (passive 40,
    // every damage type) then the physical armor rating (Equipment::CalcDamage).
    // Before this the deferred choke (zombie melee) applied neither, so armor
    // and GDR perks did nothing against the most common damage in the game.
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    w.health[ps].hp = 100;
    var fp: [max_entities]u32 = .{0} ** max_entities;
    fp[ps] = 800; // 8.0 hp
    // Bare: no armor, no VM fold -> 8.0 x Adventurer 0.75 = 6.0.
    var zk: [max_entities]u16 = .{std.math.maxInt(Slot)} ** max_entities;
    try std.testing.expectEqual(@as(u32, 1), applyDeferredDamage(&w, fp[0..], zk[0..]));
    try std.testing.expectEqual(@as(f32, 94.0), w.health[ps].hp);
    // GeneralDamageResist .25 (perkPainTolerance 5): 6.0 x 0.75 = 4.5.
    w.buff_general_resist[ps] = 0.25;
    w.health[ps].hp = 100;
    try std.testing.expectEqual(@as(u32, 1), applyDeferredDamage(&w, fp[0..], zk[0..]));
    try std.testing.expectEqual(@as(f32, 95.5), w.health[ps].hp);
    // A full resist clamps at 1 (stock min(1, value)): the hit is negated.
    w.buff_general_resist[ps] = 5;
    w.health[ps].hp = 100;
    try std.testing.expectEqual(@as(u32, 0), applyDeferredDamage(&w, fp[0..], zk[0..]));
    try std.testing.expectEqual(@as(f32, 100.0), w.health[ps].hp);
    // Negative totals are kept: stock does not clamp at 0, so a vulnerability
    // row raises the damage taken (6.0 x 1.5 = 9.0).
    w.buff_general_resist[ps] = -0.5;
    w.health[ps].hp = 100;
    try std.testing.expectEqual(@as(u32, 1), applyDeferredDamage(&w, fp[0..], zk[0..]));
    try std.testing.expectEqual(@as(f32, 91.0), w.health[ps].hp);
    // Worn armor joins the same choke (offline pieces-rate floor: one piece =
    // 0.1), so 8.0 x 0.75 = 6.0 -> x 0.9 = 5.4.
    w.buff_general_resist[ps] = 0;
    w.health[ps].hp = 100;
    try std.testing.expect(inventory.give(&w, 0, 11, 1)); // armor
    var armor_slot: u16 = 0;
    for (w.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == 11) {
            armor_slot = @intCast(i);
            break;
        }
    }
    try std.testing.expect(inventory.equip(&w, 0, armor_slot, 0));
    try std.testing.expect(inventory.armorMitigation(&w, 0) >= 0.09);
    try std.testing.expectEqual(@as(u32, 1), applyDeferredDamage(&w, fp[0..], zk[0..]));
    try std.testing.expectApproxEqAbs(@as(f32, 94.6), w.health[ps].hp, 0.001);
}
