//! Turret system: parallel target scan, fire, kill reports.
//!
//! Split out of ecs/systems.zig (same code, moved verbatim);
//! re-exported so existing `systems.*` call sites keep working.

const std = @import("std");
const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const max_entities = @import("world.zig").max_entities;
const query = @import("query.zig");
const parallel = @import("../util/parallel.zig");
const sensing = @import("sensing.zig");
const builtin = @import("builtin");

/// Fixed-point damage unit (1.0 hp = 100). Mirrors systems.zig.
const dmg_scale: u32 = 100;

/// Torso height the turret line-of-sight query runs at, the same offset the AI
/// sight query uses (`sensing.losClear`). Stock traces muzzle-to-entity
/// transform; zdtd has no separate muzzle transform, so both ends sit at torso.
const turret_sight_height: f32 = 1.6;

fn fpDamage(fp: u32) f32 {
    return @as(f32, @floatFromInt(fp)) / @as(f32, @floatFromInt(dmg_scale));
}

const TurretCtx = struct {
    w: *World,
    dt: f32,
    dmg_fp: []u32,
    /// Alive zombie slots with transform, snapshotted once per tick so each
    /// turret does not rescan all entity slots.
    zombies: []const Slot,
    /// Live turret slots, slot-ascending snapshot. Workers index this rather
    /// than the 512-slot table.
    turrets: []const Slot,
    /// Per-slot powered flags, resolved once per tick from the power grid so
    /// each turret skips the O(node_n) isEntityPowered scan.
    powered: *const [max_entities]bool,
    /// Deterministic last-hit token per zombie (parallel to dmg_fp). The high
    /// half is turret slot + 1 and the low half is its owner client slot.
    owner_hit: []u32,

    fn work(ctx: TurretCtx, begin: usize, end: usize) void {
        var i: usize = begin;
        while (i < end) : (i += 1) {
            const s = ctx.turrets[i];
            if (!ctx.w.alive[s] or !ctx.w.mask[s].turret or !ctx.w.mask[s].transform) continue;
            var t = &ctx.w.turret[s];
            if (t.fire_cd > 0) t.fire_cd -= ctx.dt;
            const powered = ctx.powered[s];
            if (!powered or t.ammo == 0) {
                t.target_id = -1;
                continue;
            }
            var best_id: i32 = -1;
            var best_slot: ?Slot = null;
            var best_d: f32 = t.range * t.range;
            // Hoisted: workers only write other slots' transforms, so the
            // compiler cannot prove these loads invariant across the loop.
            const tx = ctx.w.transform[s].x;
            const tz = ctx.w.transform[s].z;
            // Stock acquires through a clear voxel line only:
            // `AutoTurretFireController` raycasts from the muzzle to the
            // candidate (IL_0165, mask -538750989, 0.05 thickness) and the hit
            // must resolve to that candidate, so a nearer one behind a wall is
            // skipped rather than shot through it. Same block oracle the AI
            // sight uses; the 1.6 torso offset matches that query.
            const ty = ctx.w.transform[s].y + turret_sight_height;
            for (ctx.zombies) |j| {
                const dx = ctx.w.transform[j].x - tx;
                const dz = ctx.w.transform[j].z - tz;
                const d = dx * dx + dz * dz;
                if (d >= best_d) continue;
                if (!sensing.rayClear(
                    ctx.w,
                    tx,
                    ty,
                    tz,
                    ctx.w.transform[j].x,
                    ctx.w.transform[j].y + turret_sight_height,
                    ctx.w.transform[j].z,
                )) continue;
                best_d = d;
                best_id = ctx.w.network_id[j].id;
                best_slot = j;
            }
            t.target_id = best_id;
            const zi = best_slot orelse continue;
            const dx = ctx.w.transform[zi].x - tx;
            const dz = ctx.w.transform[zi].z - tz;
            ctx.w.transform[s].yaw = std.math.atan2(dx, dz) * (180.0 / std.math.pi);
            if (t.fire_cd <= 0) {
                t.fire_cd = t.fire_interval;
                t.ammo -%= 1;
                const add: u32 = @trunc(t.damage * @as(f32, @floatFromInt(dmg_scale)));
                _ = @atomicRmw(u32, &ctx.dmg_fp[zi], .Add, add, .monotonic);
                // Turret fire leaves dmg_attacker unset (matches no filter).
                recordTurretOwner(&ctx.owner_hit[zi], s, t.owner_slot);
            }
        }
    }
};

pub fn recordTurretOwner(value: *u32, turret_slot: Slot, owner_slot: i16) void {
    // Parallel execution has no meaningful wall-clock "last" worker. Match
    // the serial ascending-slot pass instead: the highest firing turret slot
    // wins, with owner packed into the same atomic value so it cannot tear
    // away from the winning source.
    const token = (@as(u32, turret_slot) + 1) << 16 | @as(u16, @bitCast(owner_slot));
    _ = @atomicRmw(u32, value, .Max, token, .monotonic);
}

pub fn turretOwner(value: u32) i16 {
    if (value == 0) return -1;
    return @bitCast(@as(u16, @truncate(value)));
}

pub const TurretTick = struct {
    kills: u32 = 0,
    /// Dead zombie net ids (for S2C EntityRemove).
    killed_ids: [16]i32 = .{-1} ** 16,
    killed_n: u8 = 0,
    /// Owner client slot per kill (parallel to killed_ids; -1 unowned).
    owner_slots: [16]i16 = .{-1} ** 16,
    loot_bag_ids: [16]i32 = .{-1} ** 16,
    loot_n: u8 = 0,
};

pub fn systemTurrets(w: *World, dt: f32) TurretTick {
    if (w.countKind(.turret) == 0) return .{};
    var dmg_fp: [max_entities]u32 = .{0} ** max_entities;
    // Filtered copy of the cached zombie group (ascending, so target selection
    // ties break identically to the old full scan). The parallel workers below
    // never spawn or destroy, so the slice stays valid for the whole phase.
    var zombie_slots: [max_entities]Slot = undefined;
    var zn: usize = 0;
    for (query.groupSlice(w, .zombie)) |zj| {
        if (!w.mask[zj].transform) continue;
        zombie_slots[zn] = zj;
        zn += 1;
    }
    // One O(node_n) pass here replaces an O(node_n) scan per turret per tick.
    var powered: [max_entities]bool = .{false} ** max_entities;
    var ni: usize = 0;
    while (ni < w.power.node_n) : (ni += 1) {
        const node = &w.power.nodes[ni];
        if (!node.powered or node.entity_id < 0) continue;
        if (w.slotOfNetId(node.entity_id)) |ps| powered[ps] = true;
    }
    var owner_hit: [max_entities]u32 = .{0} ** max_entities;
    var turret_slots: [max_entities]Slot = undefined;
    const tn = query.copyKindInto(w, .turret, &turret_slots);
    const ctx = TurretCtx{ .w = w, .dt = dt, .dmg_fp = dmg_fp[0..], .zombies = zombie_slots[0..zn], .turrets = turret_slots[0..tn], .powered = &powered, .owner_hit = owner_hit[0..] };
    // Split the live turret list, not the 512-slot table.
    if (tn < 64) TurretCtx.work(ctx, 0, tn) else parallel.forRanges(tn, ctx, TurretCtx.work);
    var out: TurretTick = .{};
    // Workers only wrote zombie slots (ascending), so apply in that order
    // instead of probing the full slot table. Same kill-list tie-break as the
    // open scan: first 16 deaths in slot order fill the report.
    for (zombie_slots[0..zn]) |i| {
        const fp = dmg_fp[i];
        if (fp == 0) continue;
        if (!w.alive[i] or !w.mask[i].health) continue;
        if (w.kind[i] != .zombie) continue;
        const amount = fpDamage(fp);
        // Class PhysicalDamageResist (passive 41): turret fire is
        // server-computed, so the zombie's own class row reduces it here.
        const pr = w.classPhysResist(i);
        const applied: f32 = if (pr > 0) amount * (1.0 - @min(pr, 100.0) / 100.0) else amount;
        // Report lists full: stop before a kill nobody would be told about
        // (destroy without EntityRemove leaves a permanent client ghost).
        // Remaining damage re-accumulates next tick, like systemDespawnFar.
        const would_kill = w.health[i].hp - applied <= 0;
        if (would_kill and (out.killed_n >= out.killed_ids.len or out.loot_n >= out.loot_bag_ids.len)) break;
        w.health[i].hp -= applied;
        // Stock's Stat setter raises Stat.Changed and the entity tick turns
        // that into a stat-change package (asm.il:199393). Without the dirty
        // bit the replicate pass had no way to know a turret had shot this
        // zombie, so viewers saw it at full health until it died.
        w.markDirty(i, .{ .hp = true });
        if (w.health[i].hp <= 0) {
            const x = if (w.mask[i].transform) w.transform[i].x else 0;
            const y = if (w.mask[i].transform) w.transform[i].y else 0;
            const z = if (w.mask[i].transform) w.transform[i].z else 0;
            const zid: i32 = if (w.mask[i].network_id) w.network_id[i].id else -1;
            // Kill verdict (T15): the same death-cancel contract as
            // World.damageFrom and applyDeferredDamage - a <0 verdict leaves
            // the victim alive at 1 hp and the kill bookkeeping below never
            // runs. This third death choke used to skip both the deny and the
            // on_entity_killed notification, so a peaceful/immortal gate was
            // bypassed by turret fire and kill observers stayed silent on trap
            // kills. Attacker id reads -1 like the deferred choke (the owner
            // pairing rides the report below, not the verdict parameter). Trap
            // XP carries no verdict SCALE (step.zig, stock V3.2.0 4.3); only
            // the deny applies here.
            if (w.kill_verdict_fn) |vf| {
                if (vf(w.kill_verdict_ctx, w.kind[i], zid, -1) < 0) {
                    w.health[i].hp = 1;
                    continue;
                }
            }
            // Same drop_prob roll as player kills (class_id LootDropProb);
            // read before the corpse marking, which keeps the slot.
            const drop_prob = if (w.mask[i].class_id) w.class_id[i].drop_prob else 1.0;
            // Same corpse funnel as every other kill path (World.markCorpse):
            // the body stays at hp 0 for TimeStayAfterDeath and the tick sweep
            // destroys it, pairing the removal with its EntityRemove.
            w.markCorpse(i);
            out.kills += 1;
            if (zid > 0 and out.killed_n < out.killed_ids.len) {
                out.killed_ids[out.killed_n] = zid;
                out.owner_slots[out.killed_n] = turretOwner(owner_hit[i]);
                out.killed_n += 1;
            }
            if (w.rollLootDrop(zid, drop_prob)) {
                if (w.spawnLootBag(x, y, z, 1, 5)) |lid| {
                    if (out.loot_n < out.loot_bag_ids.len) {
                        out.loot_bag_ids[out.loot_n] = lid;
                        out.loot_n += 1;
                    }
                }
            }
        }
    }
    return out;
}

test "concurrent turret owner follows deterministic slot order" {
    if (builtin.single_threaded) return;
    var value: u32 = 0;
    const Worker = struct {
        fn run(v: *u32, source: Slot) void {
            recordTurretOwner(v, source, @intCast(source));
        }
    };
    var threads: [8]std.Thread = undefined;
    var spawned: usize = 0;
    for (&threads, 0..) |*thread, i| {
        thread.* = std.Thread.spawn(.{}, Worker.run, .{ &value, @as(Slot, @intCast(i)) }) catch |err| {
            for (threads[0..spawned]) |*started| started.join();
            return err;
        };
        spawned += 1;
    }
    for (&threads) |*thread| thread.join();
    try std.testing.expectEqual(@as(i16, threads.len - 1), turretOwner(value));
}

test "turret kills honour the kill verdict (T15)" {
    // The turret fold is the third death choke; without the verdict call a
    // peaceful/immortal gate was bypassed by turret fire and on_entity_killed
    // observers (killfeed) stayed silent on trap kills. Deny first, then keep:
    // the same call carries both the cancellation and the notification, like
    // damageFrom and applyDeferredDamage.
    const Kind = @import("world.zig").Kind;
    const Cap = struct {
        var calls: i32 = 0;
        var verdict: i32 = 0;
        fn killVerdict(_: ?*anyopaque, kind: Kind, victim: i32, killer: i32) i32 {
            _ = kind;
            _ = victim;
            _ = killer;
            calls += 1;
            return verdict;
        }
    };
    Cap.calls = 0;
    Cap.verdict = -1;
    var w: World = .{};
    defer w.deinit();
    const tid = w.spawnTurret(0, 70, 0).?;
    const ts = w.slotOfNetId(tid).?;
    // The bare world has no generator, so the consumer node resolves
    // unpowered; flip it directly (systemTurrets does not re-resolve).
    if (w.power.indexOfId(w.turret[ts].power_node)) |ni| w.power.nodes[ni].powered = true;
    w.turret[ts].fire_cd = 0;
    const zid = w.spawnZombie(4, 70, 0, 5).?;
    const zs = w.slotOfNetId(zid).?;
    w.kill_verdict_fn = &Cap.killVerdict;
    w.kill_verdict_ctx = null;

    const r1 = systemTurrets(&w, 0.05);
    try std.testing.expectEqual(@as(i32, 1), Cap.calls);
    try std.testing.expectEqual(@as(f32, 1), w.health[zs].hp); // survives at 1
    try std.testing.expectEqual(@as(u32, 0), r1.kills);
    try std.testing.expectEqual(@as(u8, 0), r1.killed_n);
    try std.testing.expect(w.alive[zs]);

    // A keep verdict lets the same choke record the kill on the next burst.
    Cap.verdict = 0;
    var last: TurretTick = .{};
    var t: f32 = 0;
    while (t < 5 and w.alive[zs]) : (t += 0.05) {
        w.turret[ts].fire_cd = 0; // skip the 0.4 s cadence between assertions
        last = systemTurrets(&w, 0.05);
    }
    try std.testing.expect(w.health[zs].hp <= 0);
    try std.testing.expectEqual(@as(u32, 1), last.kills);
    try std.testing.expectEqual(@as(u8, 1), last.killed_n);
    try std.testing.expect(zid == last.killed_ids[0]);
    try std.testing.expect(Cap.calls >= 2);
}
