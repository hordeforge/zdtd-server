//! ECS systems: pure functions over World SoA columns + resources.
//! Hot loops (zombie AI, turrets) run multi-threaded over disjoint slots.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("../protocol.zig");
const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const max_entities = @import("world.zig").max_entities;
const c = @import("components.zig");
const quest = @import("quest.zig");
const poi_lock = @import("poi_lock.zig");
const buff = @import("buff.zig");
const path_mod = @import("path.zig");
const query = @import("query.zig");
const inventory = @import("inventory.zig");
const parallel = @import("../util/parallel.zig");
const rng_util = @import("../util/rng.zig");

/// Fixed-point damage unit (1.0 hp = 100).
const dmg_scale: u32 = 100;

fn lodScale(w: *const World, d2: f32) f32 {
    if (d2 < w.rules.ai.mid_dist_sq) return 1.0;
    if (d2 < w.rules.ai.full_dist_sq) return 0.3;
    return 0.1;
}

const PlayerSnap = struct {
    id: i32,
    slot: Slot,
    x: f32,
    y: f32,
    z: f32,
    /// Stock EntityPlayer.Crouching: muffles the hearing gate and shrinks
    /// sleeper attack-detect (RE entity-ai.md PlayerStealth).
    crouching: bool = false,
    /// Stock PlayerStealth.TickServer lightLevel (0..200, see
    /// stealthLightLevel): consumed by the CanSeeStealth sight gate. 0 =
    /// darkest night (the World ambient default).
    light_level: f32 = 0,
    /// Held-item light (items.xml LightValue): the TickServer selfLight out
    /// param. Drives the lightAttackPercent switch (selfLight < 0.1 -> the
    /// passive-89 crouch reach; else 1) and the stealth light blend.
    self_light: f32 = 0,
};

/// Player positions for AI targeting / despawn. When `skip_blood_moon_dead` is
/// set, players who died during the active blood moon are excluded (stock
/// EAISetNearestEntityAsTarget skips IsBloodMoonDead players, so the horde
/// hunts the living); the despawn pass keeps them so a corpse still pins
/// distant zombies.
fn snapshotPlayers(w: *const World, out: *[64]PlayerSnap, skip_blood_moon_dead: bool) usize {
    var n: usize = 0;
    // Cached player group instead of a 512-slot scan; it is slot-ascending, so
    // the first 64 entries are the same 64 in the same order (nearest-player
    // tie-breaks depend on it). Nothing here spawns or destroys.
    for (query.groupSlice(w, .player)) |j| {
        if (n >= out.len) break;
        if (!w.mask[j].player or !w.mask[j].transform) continue;
        if (skip_blood_moon_dead and w.player[j].is_blood_moon_dead) continue;
        out[n] = .{
            .id = w.network_id[j].id,
            .slot = j,
            .x = w.transform[j].x,
            .y = w.transform[j].y,
            .z = w.transform[j].z,
            .crouching = w.player[j].crouching,
            .light_level = stealthLightLevel(w.ambient_light, w.heldLightFor(j), w.player[j].crouching, w.rules.ai.stealth_light_passive, w.stealth[j].speed_average),
            .self_light = w.heldLightFor(j),
        };
        n += 1;
    }
    return n;
}

/// Winner of the AITarget pass: the entity the AITask list treats as "the
/// player" for this tick (nearest sensed, or the attacker via revenge).
const TargetSnap = struct { id: i32, slot: Slot, d2: f32, px: f32, pz: f32 };

/// Block-LOS between the zombie head (y+1.6) and the target head (y+1.6),
/// stepping the segment in ~0.8 block increments (stock CanSee's
/// `Voxel.Raycast`, entity-ai.md). A solid cell anywhere between blocks sight;
/// an unloaded/missing chunk counts as clear (nothing to hide behind yet).
fn losClear(w: *const World, zx: f32, zy: f32, zz: f32, px: f32, py: f32, pz: f32) bool {
    const solid_fn = w.solid_fn orelse return true; // no terrain hook: sight unblocked
    const solid_ctx = w.solid_ctx;
    const zy2 = zy + 1.6;
    const py2 = py + 1.6;
    const dx = px - zx;
    const dy = py2 - zy2;
    const dz = pz - zz;
    const dist = @sqrt(dx * dx + dy * dy + dz * dz);
    if (dist < 0.001) return true;
    const steps: usize = @intCast(@min(@as(u32, @intFromFloat(dist / 0.8)), 64));
    var i: usize = 1;
    while (i < steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) * 0.8 / dist;
        const sx = zx + dx * t;
        const sy = zy2 + dy * t;
        const sz = zz + dz * t;
        if (solid_fn(solid_ctx, @floor(sx), @floor(sy), @floor(sz))) return false;
    }
    return true;
}

/// Stock `PlayerStealth.TickServer` (IL=432, full-v3.1.0 dump): the
/// `lightAttackPercent` fed to `CanSleeperAttackDetect`'s `FastLerp(3, 15,
/// t)` crouch range. The IL check is on the **selfLight** out param of
/// GetStealthLightLevel (the held-item light, IL_010B: `selfLight < 0.1` →
/// passive-89 else 1) - not the day/night ambient. Wired 2026-08-27: the
/// held item's items.xml LightValue (torch .35, flashlight .55) raises the
/// crouch reach to the full 15 when held.
fn stealthLightAttackPercent(self_light: f32, passive: f32) f32 {
    return if (self_light < stealth_self_light_dark) passive else 1.0;
}

/// Stock `PlayerStealth.TickServer` lightLevel (IL=0131-014F): the stealth
/// light byte consumed by both the NetPackageEntityStealth S2C (Setup IL=26
/// conv.u1 of lightLevel) and the CanSeeStealth sight gate. Chain: light =
/// GetStealthLightLevel (slice-1 ambient + the selfLight held-item blend,
/// RE entity-ai.md: ratio = FastClamp(selfLight / (light + 0.05), 0.5, 3.2),
/// light += selfLight x ratio; selfLight = the AlwaysActive held item's
/// items.xml LightValue, Inventory.GetLightLevel IL=76), crouch ×0.6
/// (IL_00A6), the speedAverage visibility scale (1 + speed×0.15, IL_00CD) is
/// 0 for a standing player, then `lightLevel = clamp(light × (0.32 + 0.68 ×
/// passive89) × 100, 0, 200)`. passive89 = rules.ai.stealth_light_passive.
pub fn stealthLightLevel(ambient_light: f32, self_light: f32, crouching: bool, passive: f32, speed_average: f32) f32 {
    var light = ambient_light;
    if (self_light > 0) {
        const ratio = std.math.clamp(self_light / (light + 0.05), 0.5, 3.2);
        light += self_light * ratio;
    }
    light *= if (crouching) stealth_crouch_light_scale else 1.0;
    // IL_00CD-00E0: movement visibility `x (1 + speedAverage x 0.15)`.
    light *= 1.0 + speed_average * stealth_speed_visibility_scale;
    const folded = light * (stealth_light_passive_blend_a + stealth_light_passive_blend_b * passive) * 100.0;
    return @min(folded, stealth_light_level_max);
}

/// RE PlayerStealth.TickServer constants (IL=432): crouch light ×0.6; the
/// lightLevel fold (0.32 + 0.68 × passive89) × 100; clamp 0..200; the
/// selfLight < 0.1 → passive89 lightAttackPercent threshold.
const stealth_crouch_light_scale: f32 = 0.6;
const stealth_light_passive_blend_a: f32 = 0.32;
const stealth_speed_visibility_scale: f32 = 0.15; // IL_00CD speedAverage x 0.15
const stealth_light_passive_blend_b: f32 = 0.68;
const stealth_light_level_max: f32 = 200.0;
const stealth_self_light_dark: f32 = 0.1;

/// Stock sense gate (RE entity-ai.md CanEntityBeSeen + PlayerStealth): a
/// player is sensed when heard (within `hear`; sound passes walls) or
/// seen (within sense range, inside the view cone, block-LOS clear). Replaces
/// the old distance-only check so zombies stop seeing through solid geometry.
/// `zslot` is the sensing zombie, for its per-class cone (entityclasses
/// MaxViewAngle); stock EntityAlive cctor defaults the full angle to 180.
/// `hear` is the effective hearing radius, already stealth-scaled by the
/// caller (crouched players are muffled). `light_level` is the TARGET player's
/// TickServer lightLevel (0..200): EAITarget.check (IL=71) requires a player
/// target to pass BOTH CanSee AND CanSeeStealth (EntityAlive IL=21:
/// lightLevel > FastLerp(sightLightThreshold.x, .y, dist/sightRange)).
fn canSensePlayer(
    w: *const World,
    zslot: Slot,
    zx: f32,
    zy: f32,
    zz: f32,
    zyaw: f32,
    px: f32,
    py: f32,
    pz: f32,
    hear: f32,
    light_level: f32,
) bool {
    const dx = px - zx;
    const dy = py - zy;
    const dz = pz - zz;
    const d2 = dx * dx + dy * dy + dz * dz;
    if (d2 >= w.rules.ai.sense_dist_sq) return false;
    if (d2 < hear * hear) return true;
    // Sight: view cone (yaw = atan2(dx, dz) degrees; forward = (sin, cos)),
    // then the CanSeeStealth light gate, then LOS.
    const half = viewHalfDeg(w, zslot) * (std.math.pi / 180.0);
    const yaw_r = zyaw * (std.math.pi / 180.0);
    const hd = @sqrt(dx * dx + dz * dz);
    if (hd > 0.001) {
        const dot = (dx * @sin(yaw_r) + dz * @cos(yaw_r)) / hd;
        if (dot < @cos(half)) return false;
    }
    // CanSeeStealth (EntityAlive IL=21): t = dist/sightRange (FastLerp clamps
    // t), threshold = Lerp(sightLightThreshold.x, .y, t); seen iff
    // lightLevel > threshold. The stock zombie threshold (-2, 150) sees at
    // point blank even at night (lightLevel 0 > -2); the (30, 100) cctor
    // default blinds night sight entirely. Hearing/smell are untouched.
    const srange = @sqrt(senseDistSq(w, zslot));
    const t = if (srange > 0.001) @min(@sqrt(d2) / srange, 1.0) else 0.0;
    const th = sightLightThreshold(w, zslot);
    if (light_level <= th[0] + (th[1] - th[0]) * t) return false;
    return losClear(w, zx, zy, zz, px, py, pz);
}

/// Per-zombie CanSeeStealth light threshold pair (RE entity-ai.md + IL):
/// entityclasses `SightLightThreshold` "min,max" (stock zombieTemplateMale
/// "-2,150"; the EntityClass cctor default 30/100), the x/y pair spanning
/// FastLerp over dist/sightRange. Per-entity first (A35), then class_table,
/// then the Rules floor.
fn sightLightThreshold(w: *const World, s: Slot) [2]f32 {
    const pe = w.class_id[s];
    if (pe.sight_light_min != 0 or pe.sight_light_max != 0) return .{ pe.sight_light_min, pe.sight_light_max };
    const ct = w.class_table[w.class_id[s].id];
    if (ct.sight_light_min != 0 or ct.sight_light_max != 0) return .{ ct.sight_light_min, ct.sight_light_max };
    return .{ w.rules.ai.sight_light_threshold_min, w.rules.ai.sight_light_threshold_max };
}

/// View-cone half-angle for one entity, degrees. **Per-class first**:
/// entityclasses.xml `MaxViewAngle` (full angle, stock default 180) is halved
/// like EntityAlive.IsInFrontOfMe; the `Rules` value is the floor for a class
/// with no MaxViewAngle, or when no entityclasses.xml loaded (ADR 0021 d5).
fn viewHalfDeg(w: *const World, s: Slot) f32 {
    const pe = w.class_id[s].view_angle_deg;
    if (pe > 0) return pe / 2.0;
    const ct = w.class_table[w.class_id[s].id].view_angle_deg;
    if (ct > 0) return ct / 2.0;
    return w.rules.ai.view_cone_half_deg;
}

/// Effective smell radius for a player snap: the per-player hook (bleeding /
/// dysentery extend it, RE PlayerStealth cSmellRadius*) or the Rules base.
fn smellRadiusFor(w: *const World, slot: Slot) f32 {
    if (w.smell_fn) |f| return f(w.smell_ctx, slot);
    return w.rules.ai.smell_radius;
}

fn nearestPlayerSnap(w: *const World, snaps: []const PlayerSnap, zslot: Slot, zx: f32, zy: f32, zz: f32, zyaw: f32) TargetSnap {
    var best_id: i32 = -1;
    var best_slot: Slot = 0;
    var best_d: f32 = w.rules.ai.sense_dist_sq;
    var px: f32 = zx;
    var pz: f32 = zz;
    for (snaps) |p| {
        const dx = p.x - zx;
        const dz = p.z - zz;
        const d = dx * dx + dz * dz;
        if (d < best_d and d > 0.0001) {
            // Smell passes walls (RE PlayerStealth cSmellRadius*): within the
            // player's effective smell radius the zombie senses regardless of
            // sight or hearing (a bleeding player reeks from further away).
            const smell = smellRadiusFor(w, p.slot);
            // Stealth (RE PlayerStealth NotifyNoise): a crouched player's
            // movement noise is muffled, so the hearing gate shrinks by
            // crouch_hear_scale.
            const hear = if (p.crouching) w.rules.ai.hear_range * w.rules.ai.crouch_hear_scale else w.rules.ai.hear_range;
            if (d >= smell * smell and !canSensePlayer(w, zslot, zx, zy, zz, zyaw, p.x, p.y, p.z, hear, p.light_level)) continue;
            best_d = d;
            best_id = p.id;
            best_slot = p.slot;
            px = p.x;
            pz = p.z;
        }
    }
    return .{ .id = best_id, .slot = best_slot, .d2 = best_d, .px = px, .pz = pz };
}

/// A target snap whose `slot` is the sentinel `max_entities` is a host-side
/// bot (ADR 0026): bots are not ECS entities, so the zombie AI reaches them
/// through the World's `bot_snap_fn` / `bot_damage_fn` hooks instead of a slot.
fn targetExternal(np: TargetSnap) bool {
    return np.slot >= max_entities;
}

/// Resolve a target net id to a live ECS slot, or to a live host-side bot via
/// the bot hook (ADR 0026). Aggro-persistence gates use this so a bot target
/// keeps the chase alive exactly like an ECS entity target.
fn targetLive(w: *const World, net_id: i32) bool {
    if (net_id < 0) return false;
    if (w.slotOfNetId(net_id) != null) return true;
    const f = w.bot_snap_fn orelse return false;
    const b = f(w.bot_snap_ctx, 0, 0, 0, net_id);
    return b.net_id == net_id;
}

/// Nearest live bot within `range_sq` of (zx, zz), or an empty snap (id -1).
/// `exact >= 0` resolves that one net id instead (any range — revenge); the
/// World's `bot_snap_fn` (Game side, BotManager) answers both. A null hook
/// means no bots exist. Read-only against the BotManager, which is quiescent
/// during the parallel AI pass (bots integrate after it in the tick).
fn nearestBotSnap(w: *const World, zx: f32, zz: f32, range_sq: f32, exact: i32) TargetSnap {
    const f = w.bot_snap_fn orelse return .{ .id = -1, .slot = max_entities, .d2 = 0, .px = zx, .pz = zz };
    const b = f(w.bot_snap_ctx, zx, zz, range_sq, exact);
    if (b.net_id < 0) return .{ .id = -1, .slot = max_entities, .d2 = 0, .px = zx, .pz = zz };
    return .{ .id = b.net_id, .slot = max_entities, .d2 = b.d2, .px = b.x, .pz = b.z };
}

/// EAISetAsTargetIfHurt (asm.il:435831; CanExecute ends :436139, Start ends
/// :436169) reduced to a target-selection override. Stock runs it as the head of
/// the AITarget list, which resolves before the AITask list every tick; zdtd
/// collapses that list into `nearestPlayerSnap`, so the revenge target is
/// applied here instead of as a second task table. Kept from CanExecute: the
/// attacker must still exist and must not share the victim's entity type (a
/// zombie clawed by another zombie does not retarget). The class= filter
/// (entityclasses AITarget-1 `class=EntityPlayer`) is not modeled: zdtd damage
/// attribution only ever carries a player or turret attacker.
/// `pos` is the tick-start transform snapshot: the target's slot is owned by
/// another parallel AI worker, so its live transform must not be read here.
fn applyRevengeTarget(w: *const World, pos: *const [max_entities]c.Transform, s: Slot, ai: *c.ZombieAi, np: TargetSnap, dt: f32) TargetSnap {
    if (ai.revenge_time > 0) ai.revenge_time -= dt;
    if (ai.revenge_time <= 0 or ai.revenge_target < 0) {
        ai.revenge_target = -1;
        ai.revenge_time = 0;
        return np;
    }
    const ts = w.slotOfNetId(ai.revenge_target) orelse {
        // Host-side bot attacker (ADR 0026): bots are not ECS slots, so the
        // revenge target resolves through the bot hook instead of dropping it.
        // Stock's SetAttackTarget bypasses the sense check for the whole
        // window, so a bot that shot the zombie is hunted regardless of range.
        const bs = nearestBotSnap(w, w.transform[s].x, w.transform[s].z, 0, ai.revenge_target);
        if (bs.id != ai.revenge_target) {
            ai.revenge_target = -1;
            ai.revenge_time = 0;
            return np;
        }
        ai.alert = true;
        ai.target_id = ai.revenge_target;
        return bs;
    };
    if (!w.alive[ts] or !w.mask[ts].transform) {
        ai.revenge_target = -1;
        ai.revenge_time = 0;
        return np;
    }
    if (w.mask[ts].kind and w.mask[s].kind and w.kind[ts] == w.kind[s]) return np;
    if (ai.revenge_target == np.id) return np;
    const dx = pos[ts].x - w.transform[s].x;
    const dz = pos[ts].z - w.transform[s].z;
    // Stock's SetAttackTarget bypasses the sense check for the whole window, so
    // aggro must latch here too or the far-attacker case falls back to wander.
    ai.alert = true;
    ai.target_id = ai.revenge_target;
    return .{
        .id = ai.revenge_target,
        .slot = ts,
        .d2 = dx * dx + dz * dz,
        .px = pos[ts].x,
        .pz = pos[ts].z,
    };
}

/// True when the body column at (x, z) with feet y fits: the four corners at
/// ±body_radius are probed at mid-body and head heights (the stock
/// CharacterController capsule ~(0.35, 1.8); RE entity-movement.md). A solid
/// cell anywhere in the column blocks the move.
///
/// Corners are inset by 1 mm so a body exactly tangent to a cell face (edge
/// at the boundary) counts as clear: that is what lets the capsule slide
/// along a wall instead of gluing to it (the Unity CC resolves the contact
/// as zero penetration; a cell-membership probe would block every move).
fn bodyClearAt(
    solid_ctx: ?*anyopaque,
    solid_fn: *const fn (?*anyopaque, i32, i32, i32) bool,
    x: f32,
    z: f32,
    y: f32,
    h: f32,
    r: f32,
) bool {
    const inset: f32 = 0.001;
    const mid: i32 = @floor(y + 0.5);
    const head: i32 = @floor(y + h - 0.1);
    const cx: i32 = @floor(x);
    const cz: i32 = @floor(z);
    for ([_]f32{ -1.0, 1.0 }) |sx| {
        for ([_]f32{ -1.0, 1.0 }) |sz| {
            const px: i32 = @floor(x + sx * (r - inset));
            const pz: i32 = @floor(z + sz * (r - inset));
            // Degenerate corner inside the center cell: probing it at mid/head
            // would block standing on a 1-wide ledge.
            if (px == cx and pz == cz) continue;
            if (solid_fn(solid_ctx, px, mid, pz)) return false;
            if (solid_fn(solid_ctx, px, head, pz)) return false;
        }
    }
    return true;
}

/// Horizontal move with stock MoveHelper surface (RE entity-movement.md):
/// axis-separated collide-and-slide (the Unity CharacterController Move the
/// stock server calls from ccMove) and step-up of `step_height`. Vertical
/// physics (gravity + ground snap) is `applyGravity`, run once per AI tick so
/// an idle body still falls. With no `solid_fn` hook (offline/tests) this
/// degenerates to the old straight-line step so grid-only worlds keep their
/// behavior.
fn stepToward(w: *World, s: Slot, tx: f32, tz: f32, speed: f32, dt: f32) void {
    const t = &w.transform[s];
    const dx = tx - t.x;
    const dz = tz - t.z;
    const d2 = dx * dx + dz * dz;
    if (d2 < w.rules.ai.move_arrive * w.rules.ai.move_arrive) return;
    const inv = 1.0 / @sqrt(d2);
    // Swimming halves the horizontal speed (stock swimSpeed < moveSpeed).
    const swim = w.water_fn != null and
        w.water_fn.?(w.water_ctx, @floor(t.x), @floor(t.y + 0.5), @floor(t.z));
    const spd: f32 = if (swim) speed * w.rules.ai.swim_speed_frac else speed;
    const mx = dx * inv * spd * dt;
    const mz = dz * inv * spd * dt;
    t.yaw = std.math.atan2(dx, dz) * (180.0 / std.math.pi);
    const solid_fn = w.solid_fn orelse {
        t.x += mx;
        t.z += mz;
        return;
    };
    const r = w.rules.ai.body_radius;
    const h = w.rules.ai.body_height;
    const step = w.rules.ai.step_height;
    const ctx = w.solid_ctx;
    const ox = t.x;
    const oz = t.z;
    // Axis-separated slide: try X, then Z, so a wall blocks only the axis it
    // faces and the body runs along it (stock CC Move semantics).
    var nx = t.x;
    var nz = t.z;
    const jumping = w.mask[s].zombie_ai and w.zombie_ai[s].vy > 0;
    // While rising from a jump the body probes at its ACTUAL height (the arc
    // carries it over obstacles it genuinely clears); the step-up only applies
    // on the ground. A probe at y + jump_height would let the body clip walls
    // up to apex + jump_height tall.
    const probe_h: f32 = t.y;
    if (bodyClearAt(ctx, solid_fn, t.x + mx, t.z, probe_h, h, r)) {
        nx = t.x + mx;
    } else if (!jumping and step > 0 and bodyClearAt(ctx, solid_fn, t.x + mx, t.z, t.y + step, h, r)) {
        // Step-up: a ledge up to step_height is climbed, not blocked.
        nx = t.x + mx;
        t.y += step;
    }
    if (bodyClearAt(ctx, solid_fn, nx, t.z + mz, probe_h, h, r)) {
        nz = t.z + mz;
    } else if (!jumping and step > 0 and bodyClearAt(ctx, solid_fn, nx, t.z + mz, t.y + step, h, r)) {
        nz = t.z + mz;
        t.y += step;
    }
    // "Moved" means a real position change: a zero-length axis (mz == 0)
    // must not count as a successful move, or the jump gate below would never
    // fire for a body walking straight into a wall. Computed BEFORE the
    // assignment (nx != t.x after t.x = nx is always false).
    const moved = nx != t.x or nz != t.z;
    t.x = nx;
    t.z = nz;
    // Entity push (RE entity-ai.md AttackPush): an entity occupying the move
    // destination (cell probes cannot see entities) stops the move and gets
    // shoved along the push direction, so crowds part instead of overlapping.
    if (moved and w.mask[s].zombie_ai) {
        const dest_x = nx;
        const dest_z = nz;
        const dest_y = t.y + 0.5;
        const kinds = [_]c.Kind{ .player, .zombie, .animal };
        outer: for (kinds) |kind| {
            for (w.kind_groups.slice(kind)) |t2| {
                if (t2 == s or !w.alive[t2] or !w.mask[t2].transform) continue;
                const e = &w.transform[t2];
                if (@abs(e.x - dest_x) > w.rules.ai.push_range or @abs(e.z - dest_z) > w.rules.ai.push_range) continue;
                if (@abs(e.y - dest_y) > w.rules.ai.push_y_tol) continue;
                // Do not step into the entity; shove it along the push dir.
                t.x = ox;
                t.z = oz;
                var pdx = e.x - t.x;
                var pdz = e.z - t.z;
                const plen = @sqrt(pdx * pdx + pdz * pdz);
                if (plen < 0.001) {
                    pdx = dx * inv;
                    pdz = dz * inv;
                } else {
                    pdx /= plen;
                    pdz /= plen;
                }
                const target_x = e.x + pdx * w.rules.ai.push_shove;
                const target_z = e.z + pdz * w.rules.ai.push_shove;
                if (bodyClearAt(ctx, solid_fn, target_x, target_z, e.y, h, r)) {
                    e.x = target_x;
                    e.z = target_z;
                }
                break :outer;
            }
        }
    }
    // Stock MoveHelper StartJump / DigStart (entity-ai.md 2030-2034, 2327): a
    // fully blocked, grounded AI hops when the obstacle's full height fits
    // under the jump apex (the impulse is sized so feet clear jump_height),
    // otherwise it digs the first solid cell in the move direction. The dig
    // cadence (systemDigUpdate) pushes damage requests the Game drains like
    // the chase chew.
    if (!moved and w.mask[s].zombie_ai) {
        const ai = &w.zombie_ai[s];
        if (ai.vy != 0) return;
        const bx: i32 = @floor(t.x + dx * inv);
        const bz: i32 = @floor(t.z + dz * inv);
        const by_mid: i32 = @floor(t.y + 0.5);
        const by: i32 = if (solid_fn(w.solid_ctx, bx, by_mid, bz))
            by_mid
        else
            @floor(t.y + 1);
        const blocking = solid_fn(w.solid_ctx, bx, by, bz);
        if (blocking) {
            // Top of the contiguous solid run above the blocking cell: the
            // body's feet must clear it at the jump apex, or the hop fails.
            var top: i32 = by;
            while (solid_fn(w.solid_ctx, bx, top + 1, bz)) top += 1;
            const feet_at_apex = t.y + w.rules.ai.jump_height;
            if (ai.jump_cd <= 0 and @as(f32, @floatFromInt(top + 1)) <= feet_at_apex) {
                const g: f32 = -w.rules.ai.gravity;
                ai.vy = @sqrt(2.0 * g * w.rules.ai.jump_height);
                ai.jump_cd = w.rules.ai.jump_delay_s;
                ai.jumping = true;
            } else if (!ai.digging and w.solid_fn != null) {
                ai.digging = true;
                ai.dig_x = bx;
                ai.dig_y = by;
                ai.dig_z = bz;
                ai.dig_for_ticks = w.rules.ai.dig_budget_ticks;
                ai.dig_ticks = 0;
            }
        }
    }
}

/// MoveHelper dig cadence (RE entity-ai.md DigUpdate IL=261): each digging AI
/// counts windup/attack ticks and pushes a DigRequest every `dig_windup_ticks`
/// (stock fires the attack after the 18-tick windup, then every 4+14 = 18);
/// the budget runs down to DigStop. A dug block that is already gone ends the
/// dig so the zombie walks on. Both values are `rules.ai` (dig_windup_ticks /
/// dig_budget_ticks) so a mode can pace zombie block-chew.
pub fn systemDigUpdate(w: *World) void {
    const solid_fn = w.solid_fn;
    for (query.groupSlice(w, .zombie)) |s| {
        if (!w.alive[s] or !w.mask[s].zombie_ai) continue;
        const ai = &w.zombie_ai[s];
        if (!ai.digging) continue;
        if (ai.dig_for_ticks == 0) {
            ai.digging = false;
            continue;
        }
        if (solid_fn) |sf| {
            if (!sf(w.solid_ctx, ai.dig_x, ai.dig_y, ai.dig_z)) {
                ai.digging = false;
                continue;
            }
        }
        ai.dig_for_ticks -= 1;
        ai.dig_ticks +%= 1;
        if (ai.dig_ticks >= w.rules.ai.dig_windup_ticks) {
            ai.dig_ticks = 0;
            w.pushDig(s, ai.dig_x, ai.dig_y, ai.dig_z);
        }
    }
}

/// Vertical physics for one AI body (RE entity-movement.md): the feet cell
/// below decides. Solid → grounded (snap onto the block top, clear vy). Air
/// → fall under gravity like the stock physics tick (DefaultMoveEntity
/// friction + gravity in Entity::ccMove); the accumulator is capped so a
/// long drop cannot outrun the per-tick probe. Runs once per AI tick so an
/// idle or attacking body still settles.
fn applyGravity(w: *World, s: Slot, dt: f32) void {
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
        const g_eff: f32 = if (swimming) w.rules.ai.gravity * w.rules.ai.swim_gravity_per else w.rules.ai.gravity;
        const drag: f32 = if (swimming) w.rules.ai.swim_drag_y else 0.98;
        ai.vy = (ai.vy + g_eff * dt) * drag;
        if (ai.vy < w.rules.ai.fall_max_vy) ai.vy = w.rules.ai.fall_max_vy;
        t.y += ai.vy * dt;
    }
}

/// Deferred damage accumulates as fixed-point (dmg_scale) to stay atomic-friendly.
fn fpDamage(fp: u32) f32 {
    return @as(f32, @floatFromInt(fp)) / @as(f32, @floatFromInt(dmg_scale));
}

fn applyDeferredDamage(w: *World, dmg_fp: []const u32) u32 {
    var applied: u32 = 0;
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
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

// --- Quest systems (journal + wallet components) ---

fn completeQuest(w: *World, ps: Slot, s: *c.QuestProgress) void {
    if (s.completed) return;
    s.completed = true;
    s.active = false;
    s.ready_turn_in = false;
    if (w.catalog.byId(s.def_id) != null) {
        // reward_coin pays at the tick-end payout (step.zig), through the
        // on_quest_complete verdict like items/exp — paying here would let a
        // deny/scaling plugin never touch the coin leg.
        if (w.completed_quests_n < w.completed_quests_ring.len) {
            w.completed_quests_ring[w.completed_quests_n] = .{ .slot = ps, .def_id = s.def_id };
            w.completed_quests_n += 1;
        }
    }
    w.completed_quests +%= 1;
}

fn markProgress(w: *World, ps: Slot, s: *c.QuestProgress, d: quest.QuestDef) void {
    if (s.progress >= d.target_count) {
        if (d.turn_in) {
            s.ready_turn_in = true;
        } else {
            completeQuest(w, ps, s);
        }
    }
}

// --- Phase-graph execution (stock Quest.refreshQuestCompletion / AdvancePhase) ---

/// Spec of the phase the quest is currently on (null for legacy phase-less defs).
fn currentPhaseSpec(d: quest.QuestDef, s: *const c.QuestProgress) ?quest.PhaseSpec {
    if (d.phases.len == 0) return null;
    const idx: usize = if (s.phase == 0) 0 else s.phase - 1;
    if (idx >= d.phases.len) return null;
    return d.phases[idx];
}

/// Finalize the highest phase: TurnIn quests go ready-turn-in, Auto complete.
/// Mirrors refreshQuestCompletion's CurrentPhase>=HighestPhase branch.
fn finishPhaseGraph(w: *World, ps: Slot, s: *c.QuestProgress, d: quest.QuestDef) void {
    if (d.turn_in) {
        s.ready_turn_in = true;
    } else {
        completeQuest(w, ps, s);
    }
}

/// A phase the sim cannot drive to completion, so it must not block the quest.
/// A rally phase only blocks once the quest has a POI rect: without one the
/// client never finds a rally marker (QuestJournal.HasQuestAtRallyPosition,
/// asm.il 1006297) and would leave the quest stuck forever.
fn phaseIsScaffolding(spec: quest.PhaseSpec, s: *const c.QuestProgress) bool {
    return switch (spec.kind) {
        .auto => true,
        .rally => !s.poi.valid(),
        else => false,
    };
}

/// Auto-complete leading scaffolding phases starting at the current phase;
/// finishes the quest if the highest phase is scaffolding.
fn skipAutoPhases(w: *World, ps: Slot, s: *c.QuestProgress, d: quest.QuestDef) void {
    while (currentPhaseSpec(d, s)) |spec| {
        if (!phaseIsScaffolding(spec, s)) return;
        if (s.phase >= d.highest_phase) {
            finishPhaseGraph(w, ps, s, d);
            return;
        }
        s.phase += 1;
        s.progress = 0;
        firePhaseActions(w, ps, s, d);
    }
}

/// Fire quest actions for the phase the quest just entered. Only UnlockPOI is
/// server-side: it releases the quest's POI lock (stock QuestActionUnlockPOI,
/// asm.il 1390421-1390429), which is why the phase-4 action on turn-in quests
/// must not sit ignored. The other kinds run on the owning client (SetCVar,
/// ShowMessageWindow) or need a subsystem zdtd does not have (SpawnGSEnemy,
/// GameEvent), so they are parsed and recorded but not fired here.
fn firePhaseActions(w: *World, ps: Slot, s: *c.QuestProgress, d: quest.QuestDef) void {
    var i: usize = 0;
    while (i < @min(@as(usize, d.action_n), quest.max_actions)) : (i += 1) {
        const a = d.actions[i];
        if (a.phase != 0 and a.phase != s.phase) continue;
        switch (a.kind) {
            .unlock_poi => {
                if (!s.poi.valid()) continue;
                const eid: i32 = if (w.mask[ps].network_id) w.network_id[ps].id else -1;
                questPoiUnlock(w, eid, s.poi.x, s.poi.z);
            },
            // Stock QuestActionSpawnGSEnemy: gamestage-scaled enemies around
            // the player on phase entry. The Game hook owns the spawn
            // (gamestage resolution + entity classes); unset = the action is
            // parsed but not fired (test worlds).
            .spawn_gs_enemy => {
                if (!s.poi.valid()) continue;
                if (w.quest_spawn_fn) |f| {
                    f(
                        w.quest_spawn_ctx,
                        s.poi,
                        a.name,
                        a.count_min,
                        a.count_max,
                        w.transform[ps].x,
                        w.transform[ps].z,
                    );
                }
            },
            // SetCVar / ShowMessageWindow run on the owning player's client in
            // stock; GameEvent actions have no stock quest uses. Parsed and
            // recorded; nothing to fire server-side.
            else => {},
        }
    }
}

/// Current phase objective satisfied: advance to the next actionable phase, or
/// finish at the highest phase. Mirrors Quest.AdvancePhase (asm.il 982816).
fn advancePhaseGraph(w: *World, ps: Slot, s: *c.QuestProgress, d: quest.QuestDef) void {
    // A completed ClearSleepers phase suppresses the quest POI's sleeper
    // volumes (stock QuestEvent_SleepersCleared removes the POI's sleeper
    // data). The Game hook marks the persistent store; unset = no
    // suppression (test worlds without sleeper data).
    if (currentPhaseSpec(d, s)) |done_spec| {
        if (done_spec.kind == .kill_zombies and done_spec.poi_gated and s.poi.valid()) {
            if (w.quest_clear_fn) |f| f(w.quest_clear_ctx, s.poi);
        }
    }
    if (s.phase >= d.highest_phase) {
        finishPhaseGraph(w, ps, s, d);
        return;
    }
    s.phase += 1;
    s.progress = 0;
    firePhaseActions(w, ps, s, d);
    skipAutoPhases(w, ps, s, d);
}

/// Advance the current phase: add `n` to every current-phase (and always-active
/// phase-0) objective whose kind matches, then advance when ALL non-optional
/// objectives of the phase are complete (stock Quest.refreshQuestCompletion
/// requires the whole phase, asm.il 983645-983904). Legacy phase-less defs
/// keep the single `progress` counter.
fn bumpPhase(w: *World, ps: Slot, s: *c.QuestProgress, d: quest.QuestDef, kind: quest.PhaseKind, n: u16) void {
    if (d.objectives.len > 0) {
        var advanced = false;
        for (d.objectives, 0..) |o, i| {
            if (o.kind != kind) continue;
            if (o.phase != s.phase and o.phase != 0) continue;
            if (i >= s.obj_progress.len) continue;
            // ClearSleepers (poi_gated kill): the target is the bound POI's
            // live sleeper population, not the def's policy floor (stock
            // ObjectiveClearSleepers counts the volume spawns; audit B25).
            // The Game hook sums the volumes in the rect; 0/unset keeps the
            // def required.
            var req: u16 = @max(1, o.required);
            if (o.poi_gated and s.poi.valid()) {
                if (w.quest_sleeper_count_fn) |f| {
                    const live = f(w.quest_sleeper_count_ctx, s.poi);
                    if (live > 0) req = live;
                }
            }
            s.obj_progress[i] = @min(@as(u16, s.obj_progress[i]) +| n, req);
            advanced = true;
        }
        if (!advanced) return;
        // Mirror the old single-progress semantics for the wire/tests: the
        // advancing phase objective's progress.
        var max_p: u16 = 0;
        for (d.objectives, 0..) |o, i| {
            if (o.kind != kind or (o.phase != s.phase and o.phase != 0)) continue;
            if (i < s.obj_progress.len and s.obj_progress[i] > max_p) max_p = s.obj_progress[i];
        }
        if (max_p > 0) s.progress = max_p;
        const phase_done = phaseObjectivesComplete(w, d, s);
        if (phase_done) {
            advancePhaseGraph(w, ps, s, d);
            return;
        }
        // ForcePhaseFinish: with the phase incomplete, any objective carrying
        // the flag fails the quest (refreshQuestCompletion IL_00CB-0104).
        var any_force = false;
        for (d.objectives) |o| {
            if (o.phase != s.phase and o.phase != 0) continue;
            if (o.force) {
                any_force = true;
                break;
            }
        }
        if (any_force) failQuest(w, ps, s);
        return;
    }
    const spec = currentPhaseSpec(d, s) orelse return;
    if (spec.kind != kind) return;
    s.progress +|= n;
    if (s.progress >= spec.required) advancePhaseGraph(w, ps, s, d);
}

/// Stock refreshQuestCompletion's per-phase gate: every non-optional objective
/// of the current phase (plus always-active phase-0 objectives) is complete.
/// `.auto` scaffolding objectives never block (unmodelled objective types
/// auto-complete on entry).
fn phaseObjectivesComplete(w: *World, d: quest.QuestDef, s: *const c.QuestProgress) bool {
    for (d.objectives, 0..) |o, i| {
        if (o.optional or o.kind == .auto) continue;
        if (o.phase != s.phase and o.phase != 0) continue;
        if (i >= s.obj_progress.len) return false;
        // Same live-sleeper override as bumpPhase (audit B25).
        var req: u16 = @max(1, o.required);
        if (o.poi_gated and s.poi.valid()) {
            if (w.quest_sleeper_count_fn) |f| {
                const live = f(w.quest_sleeper_count_ctx, s.poi);
                if (live > 0) req = live;
            }
        }
        if (s.obj_progress[i] < req) return false;
    }
    return true;
}

/// True when the current phase (or an always-active phase-0 objective) has an
/// objective of `kind`. Objective-tracked quests use this for the per-kind
/// event gates instead of the single advancing spec kind, so mixed phases
/// (e.g. ClearSleepers + POIStayWithin) receive all their events.
fn phaseHasKind(d: quest.QuestDef, s: *const c.QuestProgress, kind: quest.PhaseKind) bool {
    if (d.objectives.len == 0) return false;
    for (d.objectives) |o| {
        if (o.kind == kind and (o.phase == s.phase or o.phase == 0)) return true;
    }
    return false;
}

/// Close a quest as failed (stock Quest.CloseQuest(Failed, null)): the slot
/// leaves the active set but stays visible to the client as a failed quest
/// (QuestState.failed), and the POI lock is released.
fn failQuest(w: *World, ps: Slot, s: *c.QuestProgress) void {
    if (s.poi.valid()) {
        questPoiUnlock(w, if (w.mask[ps].network_id) w.network_id[ps].id else -1, s.poi.x, s.poi.z);
    }
    s.active = false;
    s.completed = false;
    s.ready_turn_in = false;
    s.failed = true;
}

pub fn questAccept(w: *World, peer_slot: usize, def_id: u16) bool {
    const ps = w.playerByPeer(peer_slot) orelse return false;
    if (!w.mask[ps].journal) return false;
    if (w.catalog.byId(def_id) == null) return false;
    // Wasm-first (AGENTS rule 29): every quest acceptance passes the
    // on_quest_accept plugin verdict (World hook wired by Game). <0 denies
    // the accept (no slot allocated); 0 keeps. Plugins gate which quests a
    // player may take (class/level/whitelist policies) instead of native code.
    if (w.quest_accept_fn) |qf| {
        if (qf(w.quest_accept_ctx, @intCast(peer_slot), def_id) < 0) return false;
    }
    var j = &w.journal[ps];
    if (j.hasActive(def_id) or j.hasFailed(def_id)) return false;
    const s = j.findFree() orelse return false;
    const code = w.next_quest_code;
    w.next_quest_code +%= 1;
    s.* = .{
        .def_id = def_id,
        .quest_code = code,
        .active = true,
        .completed = false,
        .ready_turn_in = false,
        .progress = 0,
        .phase = 1,
    };
    const d = w.catalog.byId(def_id).?;
    // Place the quest in a POI so rally objectives and the client's POI marker
    // have a real rect. Stock picks the POI when the quest is handed out
    // (Quest.SetupPosition → ObjectiveRandomPOIGoto/ObjectiveGoto.GetPosition):
    // RandomPOIGoto selects a random tier/tag/biome/distance-qualified POI
    // near the player, Goto/ClosestPOIGoto the closest one (RE: 7dtd-engine-research
    // docs/quests-challenges.md "Quest POI selection"). The Game hook does the
    // selection (prefab index + biome map + lockouts); unset (test worlds) or
    // nothing qualified → fall back to static def position / nearest POI.
    if (d.poi_select != .none) {
        const sel = w.questSelectPoi(.{
            .kind = d.poi_select,
            .anchor_x = w.transform[ps].x,
            .anchor_z = w.transform[ps].z,
            .tags_mask = d.quest_tags,
            .tier = d.difficulty_tier,
            .biome_type = d.biome_filter_type,
            .biome_filter = d.biome_filter,
            .allow_current_poi = d.allow_current_poi,
            .entity_id = if (w.mask[ps].network_id) w.network_id[ps].id else -1,
        });
        if (sel) |sel2| s.poi = sel2.rect;
    }
    if (!s.poi.valid()) {
        if (w.poiAt(d.tx, d.tz)) |rect| {
            s.poi = rect;
        } else if (d.kind == .goto_point or d.kind == .stay_within or d.kind == .craft) {
            // No selector result (POI-less test world / nothing qualified):
            // bind the nearest real POI so the goto check and NavObject marker
            // point somewhere reachable instead of an invented FNV spot
            // (audit B26). No POI data → poi stays unset, def marker wins.
            if (w.nearestPoi(w.transform[ps].x, w.transform[ps].z)) |rect| s.poi = rect;
        }
    }
    // Phase graph: land the player on the first actionable (non-auto) phase.
    if (d.phases.len > 0) skipAutoPhases(w, ps, s, d);
    return true;
}

/// Find active journal slot by stock quest_code.
pub fn questFindByCode(w: *World, peer_slot: usize, quest_code: i32) ?*c.QuestProgress {
    const ps = w.playerByPeer(peer_slot) orelse return null;
    if (!w.mask[ps].journal) return null;
    for (&w.journal[ps].slots) |*s| {
        if (s.active and s.quest_code == quest_code) return s;
    }
    return null;
}

pub fn questAcceptStarter(w: *World, peer_slot: usize) bool {
    const ps = w.playerByPeer(peer_slot) orelse return false;
    if (!w.mask[ps].journal) return false;
    // A starter completed (or still active) in an earlier session must not be
    // granted again on the next login: hasActive only matches active slots,
    // and findFree reuses non-active ones, so the guard has to scan every
    // slot (GAP starter-quest row).
    const starter = w.catalog.starter_id;
    for (w.journal[ps].slots) |s| {
        if (s.def_id == starter and (s.active or s.completed or s.failed)) return false;
    }
    return questAccept(w, peer_slot, starter);
}

pub fn questOnZombieKilled(w: *World, peer_slot: usize, x: f32, z: f32) void {
    const ps = w.playerByPeer(peer_slot) orelse return;
    if (!w.mask[ps].journal) return;
    var j = &w.journal[ps];
    for (&j.slots) |*s| {
        if (!s.active or s.completed or s.ready_turn_in) continue;
        const d = w.catalog.byId(s.def_id) orelse continue;
        if (d.phases.len > 0) {
            // ClearSleepers phases (stock QuestEvent_SleepersCleared) only
            // count kills inside the quest's bound POI: a clear quest must be
            // cleared in its POI, not farmed anywhere on the map. Quests
            // without a bound rect keep the ungated behaviour (test worlds).
            const spec = currentPhaseSpec(d, s) orelse continue;
            if (spec.kind == .kill_zombies and spec.poi_gated and s.poi.valid()) {
                if (!s.poi.containsXZ(x, z)) continue;
            }
            bumpPhase(w, ps, s, d, .kill_zombies, 1);
            continue;
        }
        if (d.kind != .kill_zombies) continue;
        s.progress +|= 1;
        markProgress(w, ps, s, d);
    }
}

pub fn questOnTraderOpen(w: *World, peer_slot: usize) void {
    const ps = w.playerByPeer(peer_slot) orelse return;
    if (!w.mask[ps].journal) return;
    var j = &w.journal[ps];
    for (&j.slots) |*s| {
        if (!s.active or s.completed) continue;
        const d = w.catalog.byId(s.def_id) orelse continue;
        if (d.phases.len > 0) {
            if (currentPhaseSpec(d, s)) |spec| {
                if (!s.ready_turn_in) {
                    if (d.objectives.len > 0) {
                        if (phaseHasKind(d, s, .trader_interact)) bumpPhase(w, ps, s, d, .trader_interact, 1);
                    } else if (spec.kind == .trader_interact) {
                        bumpPhase(w, ps, s, d, .trader_interact, spec.required);
                    }
                }
            }
            // Turning in at the trader completes a ready quest.
            if (s.ready_turn_in) completeQuest(w, ps, s);
            continue;
        }
        if (d.kind == .fetch_trader) {
            // Multi-phase starter: phase1 Goto → phase2 Interact; complete on next open.
            if (d.objective_count >= 2 and s.phase == 1 and !s.ready_turn_in) {
                s.phase = 2;
                s.progress = 0;
                s.ready_turn_in = true;
                continue;
            }
            s.progress = 1;
            completeQuest(w, ps, s);
            continue;
        }
        if (d.turn_in and (s.ready_turn_in or s.progress >= d.target_count)) {
            completeQuest(w, ps, s);
        }
    }
}

pub fn questOnFetchItem(w: *World, peer_slot: usize, count: u16) void {
    const ps = w.playerByPeer(peer_slot) orelse return;
    if (!w.mask[ps].journal) return;
    var j = &w.journal[ps];
    for (&j.slots) |*s| {
        if (!s.active or s.completed or s.ready_turn_in) continue;
        const d = w.catalog.byId(s.def_id) orelse continue;
        if (d.phases.len > 0) {
            bumpPhase(w, ps, s, d, .fetch_item, count);
            continue;
        }
        if (d.kind != .fetch_item) continue;
        s.progress +|= count;
        markProgress(w, ps, s, d);
    }
}

/// Craft progress: phase craft or legacy QuestKind.craft. recipe_name matched via def.name contains.
pub fn questOnCraft(w: *World, peer_slot: usize, recipe_name: []const u8) void {
    const ps = w.playerByPeer(peer_slot) orelse return;
    if (!w.mask[ps].journal) return;
    var j = &w.journal[ps];
    for (&j.slots) |*s| {
        if (!s.active or s.completed or s.ready_turn_in) continue;
        const d = w.catalog.byId(s.def_id) orelse continue;
        if (d.phases.len > 0) {
            if (currentPhaseSpec(d, s)) |spec| {
                if (d.objectives.len > 0) {
                    if (phaseHasKind(d, s, .craft)) bumpPhase(w, ps, s, d, .craft, 1);
                } else if (spec.kind == .craft) {
                    bumpPhase(w, ps, s, d, .craft, 1);
                }
            }
            continue;
        }
        if (d.kind != .craft) continue;
        // Optional: def.name is recipe id or contains it.
        if (d.name.len > 0 and recipe_name.len > 0) {
            if (std.mem.find(u8, recipe_name, d.name) == null and std.mem.find(u8, d.name, recipe_name) == null)
                continue;
        }
        s.progress +|= 1;
        markProgress(w, ps, s, d);
    }
}

// --- Rally marker / POI lockout (NetPackageQuestEvent server half) ---

/// Outcome of a rally-marker request: reason 0 means the marker may be armed.
pub const PoiLockout = struct {
    reason: poi_lock.LockReason = .none,
    /// QuestLockInstance.LockedOutUntil, only meaningful for `quest_lock`.
    extra_data: u64 = 0,
};

/// Server half of QuestEventManager.CheckForPOILockouts (asm.il 998957-999155).
/// Only the reasons this server can observe are reported: an active quest lock
/// on the POI, or another player standing inside it. Bedroll and land-claim
/// lockouts need home/claim tracking the server does not have yet, so they
/// never fire rather than being guessed.
pub fn questCheckPoiLockout(w: *World, entity_id: i32, x: f32, z: f32) PoiLockout {
    if (w.poi_locks.check(x, z, w.director.clock.worldTimeBits())) |until| {
        return .{ .reason = .quest_lock, .extra_data = until };
    }
    const rect = w.poiAt(x, z) orelse return .{};
    // Stock exempts party members (CheckForPOILockouts, asm.il 998957): a
    // party member inside the POI does not block the rally.
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        if (!w.alive[i] or !w.mask[i].player or !w.mask[i].transform) continue;
        if (w.mask[i].network_id and w.network_id[i].id == entity_id) continue;
        if (rect.containsXZ(w.transform[i].x, w.transform[i].z)) {
            if (w.party_same_fn) |f| {
                if (w.mask[i].network_id and f(w.party_same_ctx, entity_id, w.network_id[i].id)) continue;
            }
            return .{ .reason = .player_inside };
        }
    }
    // Bedroll / land-claim lockouts (stock CheckForPOILockouts): a quest
    // cannot reset a POI that holds the player's respawn bed or a land claim.
    // The Game wires `home_fn` (client bed + claims store); unset = neither
    // reason ever fires (offline/test worlds).
    if (w.home_fn) |f| {
        const bits = f(w.home_ctx, entity_id, rect.x + rect.size_x * 0.5, rect.z + rect.size_z * 0.5);
        if ((bits & 1) != 0) return .{ .reason = .bedroll };
        if ((bits & 2) != 0) return .{ .reason = .land_claim };
    }
    return .{};
}

/// Take the POI at (x,z) for `entity_id` (stock QuestLockPOI, asm.il 998898).
pub fn questPoiLock(w: *World, entity_id: i32, x: f32, z: f32) void {
    const rect = w.poiAt(x, z) orelse return;
    _ = w.poi_locks.lock(rect, entity_id, w.director.clock.worldTimeBits());
}

/// Release the POI at (x,z) for `entity_id` (stock QuestUnlockPOI, asm.il 998930).
pub fn questPoiUnlock(w: *World, entity_id: i32, x: f32, z: f32) void {
    w.poi_locks.unlock(x, z, entity_id, w.director.clock.worldTimeBits());
}

/// The client activated the rally marker of quest `quest_code`. Marks the quest
/// (stock Quest.RallyMarkerActivated) and advances a rally phase exactly once.
/// False = no such active quest for this peer, or the marker was already spent.
pub fn questOnRallyActivated(w: *World, peer_slot: usize, quest_code: i32) bool {
    const ps = w.playerByPeer(peer_slot) orelse return false;
    const s = questFindByCode(w, peer_slot, quest_code) orelse return false;
    if (s.completed or s.rally_activated) return false;
    s.rally_activated = true;
    const d = w.catalog.byId(s.def_id) orelse return true;
    if (d.phases.len > 0) {
        if (currentPhaseSpec(d, s)) |spec| {
            if (d.objectives.len > 0) {
                if (phaseHasKind(d, s, .rally)) bumpPhase(w, ps, s, d, .rally, 1);
            } else if (spec.kind == .rally) {
                bumpPhase(w, ps, s, d, .rally, spec.required);
            }
        }
    }
    return true;
}

/// StayWithin: player must remain near def.tx/tz (radius from target_count as blocks, min 8).
pub fn questTickStayWithin(w: *World, peer_slot: usize, px: f32, pz: f32) void {
    const ps = w.playerByPeer(peer_slot) orelse return;
    if (!w.mask[ps].journal) return;
    var j = &w.journal[ps];
    for (&j.slots) |*s| {
        if (!s.active or s.completed or s.ready_turn_in) continue;
        const d = w.catalog.byId(s.def_id) orelse continue;
        const radius: f32 = blk: {
            if (d.phases.len > 0) {
                const spec = currentPhaseSpec(d, s) orelse continue;
                if (d.objectives.len > 0) {
                    if (!phaseHasKind(d, s, .stay_within)) continue;
                } else if (spec.kind != .stay_within) {
                    continue;
                }
                // The objective's parsed distance in metres wins; the
                // `[quests]` policy stay_radius is the fallback (ADR 0021).
                break :blk if (spec.radius > 0) spec.radius else @max(w.catalog.policy.stay_radius, @as(f32, @floatFromInt(spec.required)));
            }
            if (d.kind != .stay_within) continue;
            break :blk @max(w.catalog.policy.stay_radius, @as(f32, @floatFromInt(d.target_count)));
        };
        // POIStayWithin bounds the zone to the quest's POI rect (bound at
        // accept via nearestPoi): the player must be inside the building's
        // footprint, not just near a point. Plain StayWithin keeps the
        // def-position radius.
        const cx: f32 = if (s.poi.valid()) s.poi.x + s.poi.size_x * 0.5 else d.tx;
        const cz: f32 = if (s.poi.valid()) s.poi.z + s.poi.size_z * 0.5 else d.tz;
        const eff_radius: f32 = if (s.poi.valid())
            @max(radius, @min(s.poi.size_x, s.poi.size_z) * 0.5)
        else
            radius;
        const dx = px - cx;
        const dz = pz - cz;
        const r2 = eff_radius * eff_radius;
        if (dx * dx + dz * dz <= r2) {
            if (d.phases.len > 0) {
                bumpPhase(w, ps, s, d, .stay_within, 1);
            } else {
                s.progress +|= 1;
                markProgress(w, ps, s, d);
            }
        }
    }
}

pub fn questTickGoto(w: *World, peer_slot: usize, px: f32, py: f32, pz: f32) void {
    _ = py;
    const ps = w.playerByPeer(peer_slot) orelse return;
    if (!w.mask[ps].journal) return;
    var j = &w.journal[ps];
    for (&j.slots) |*s| {
        if (!s.active or s.completed or s.ready_turn_in) continue;
        const d = w.catalog.byId(s.def_id) orelse continue;
        // Goto target: the quest's bound POI center when one was placed on
        // accept (audit B26), else the def marker position. Only POI-goto
        // kinds use the bound rect; a fetch_trader phase-1 "go to trader"
        // target is the trader spot, never a covering prefab center.
        const use_poi = d.kind == .goto_point and s.poi.valid();
        const gx: f32 = if (use_poi) s.poi.x + s.poi.size_x * 0.5 else d.tx;
        const gz: f32 = if (use_poi) s.poi.z + s.poi.size_z * 0.5 else d.tz;
        if (d.phases.len > 0) {
            const spec = currentPhaseSpec(d, s) orelse continue;
            if (d.objectives.len > 0) {
                if (!phaseHasKind(d, s, .goto_point)) continue;
            } else if (spec.kind != .goto_point) {
                continue;
            }
            // Arrival radius: the objective's parsed distance in metres (stock
            // ObjectiveGoto::distance); the `[quests]` policy goto_radius is
            // the fallback (ADR 0021).
            const radius: f32 = if (spec.radius > 0) spec.radius else w.catalog.policy.goto_radius;
            const dx = px - gx;
            const dz = pz - gz;
            if (dx * dx + dz * dz < radius * radius) bumpPhase(w, ps, s, d, .goto_point, spec.required);
            continue;
        }
        // fetch_trader starter uses Goto trader as phase 1.
        if (d.kind != .goto_point and !(d.kind == .fetch_trader and s.phase == 1)) continue;
        const dx = px - gx;
        const dz = pz - gz;
        const r_legacy = w.catalog.policy.goto_radius;
        if (dx * dx + dz * dz < r_legacy * r_legacy) {
            if (d.kind == .fetch_trader and d.objective_count >= 2) {
                s.phase = 2;
                s.progress = 0;
                s.ready_turn_in = true;
            } else {
                s.progress = 1;
                markProgress(w, ps, s, d);
            }
        }
    }
}

pub fn questCoins(w: *const World, peer_slot: usize) u32 {
    const ps = w.playerByPeer(peer_slot) orelse return 0;
    if (!w.mask[ps].wallet) return 0;
    return w.wallet[ps].coins;
}

/// Test-only: drain the completed-quest ring's coin rewards into the wallet.
/// The Game's tick-end payout (step.zig) does this with the on_quest_complete
/// verdict; ECS-level tests have no Game, so they drain the ring directly.
pub fn drainQuestCoins(w: *World, peer_slot: usize) void {
    const ps = w.playerByPeer(peer_slot) orelse return;
    var i: usize = 0;
    while (i < w.completed_quests_n) : (i += 1) {
        const cq = w.completed_quests_ring[i];
        if (cq.slot != ps) continue;
        if (w.catalog.byId(cq.def_id)) |d| {
            if (w.mask[ps].wallet) w.wallet[ps].coins +|= d.reward_coin;
        }
    }
    w.completed_quests_n = 0;
}

pub fn questHasActive(w: *const World, peer_slot: usize, def_id: u16) bool {
    const ps = w.playerByPeer(peer_slot) orelse return false;
    if (!w.mask[ps].journal) return false;
    return w.journal[ps].hasActive(def_id);
}

pub fn questFindActive(w: *World, peer_slot: usize, def_id: u16) ?*c.QuestProgress {
    const ps = w.playerByPeer(peer_slot) orelse return null;
    if (!w.mask[ps].journal) return null;
    return w.journal[ps].findActive(def_id);
}

/// Pick up nearby loot bags into player inventory (returns bags collected).
pub fn collectLootNear(w: *World, peer_slot: usize, radius: f32) u32 {
    const ps = w.playerByPeer(peer_slot) orelse return 0;
    if (!w.mask[ps].transform or !w.mask[ps].inventory) return 0;
    const px = w.transform[ps].x;
    const pz = w.transform[ps].z;
    const r2 = radius * radius;
    var n: u32 = 0;
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        if (!w.alive[i] or !w.mask[i].loot_bag or !w.mask[i].transform) continue;
        const dx = w.transform[i].x - px;
        const dz = w.transform[i].z - pz;
        if (dx * dx + dz * dz > r2) continue;
        // Transfer rule is inventory.collectBagFull: a partial deposit keeps
        // the bag alive so the rest is not silently deleted.
        if (!inventory.collectBagFull(w, peer_slot, i)) continue;
        w.destroy(i);
        n += 1;
    }
    if (n > 0) w.markDirty(ps, .{ .inv = true });
    return n;
}

/// Buy (side=0) or sell (side=1) against trader stock + wallet and/or casinoCoin stacks.
/// `coin_item_id` = ECS id for casinoCoin from items table (ecsIdByName). 0 = fail closed.
/// Stock quality price lerp: Lerp(min, max, (quality-1)/5), quality 1..6
/// (GetBuyPrice/GetSellPrice, asm.il 1830625-1830948; traders.xml quality_mod
/// comment: QL1 -> min, QL6 -> max).
pub fn qualityPriceMod(min_mod: f32, max_mod: f32, quality: u8) f32 {
    const q: f32 = @floatFromInt(@max(1, @min(quality, 6)));
    const t: f32 = (q - 1.0) / 5.0;
    return min_mod + (max_mod - min_mod) * t;
}

pub fn trade(w: *World, player_peer: usize, trader_net: i32, item: u16, qty: u16, side: u8, coin_item_id: u16) bool {
    if (qty == 0) return false;
    if (coin_item_id == 0) return false;
    const coin_id: u16 = coin_item_id;
    const ps = w.playerByPeer(player_peer) orelse return false;
    if (!w.mask[ps].wallet) return false;
    const ts = w.slotOfNetId(trader_net) orelse return false;
    if (!w.mask[ts].trader or !w.mask[ts].trader_stock) return false;
    // Sync wallet from inventory coins when inv has more (client-authoritative stacks).
    if (w.mask[ps].inventory) {
        const inv_coins = w.inventory[ps].countItem(coin_id);
        if (inv_coins > w.wallet[ps].coins) w.wallet[ps].coins = inv_coins;
    }
    var stock = &w.trader_stock[ts];
    var e: usize = 0;
    while (e < stock.n and stock.entries[e].item != item) : (e += 1) {}
    const entry = if (e < stock.n) &stock.entries[e] else null;
    if (side == 0) {
        // Buy: the item must be stocked.
        const en = entry orelse return false;
        if (en.count < qty) return false;
        // Pre-trade price verdict (on_trade_price): <0 denies the trade, 0
        // keeps the price, >0 scales the unit price by percent. The attacker
        // (buyer) is the player's net id; `item` is the ECS item id.
        var unit: u32 = @max(1, @as(u32, en.price));
        if (w.trade_price_verdict_fn) |vf| {
            const v = vf(w.trade_price_verdict_ctx, w.network_id[ps].id, item, unit);
            if (v < 0) return false;
            if (v > 0) {
                const scaled: u64 = @as(u64, unit) * @as(u64, @intCast(v)) / 100;
                unit = @intCast(@max(1, @min(scaled, std.math.maxInt(u32))));
            }
        }
        // Widen before the multiply: a verdict-scaled unit can sit at u32 max,
        // so unit * qty in u32 wraps (free purchase) or traps on the check.
        const cost_wide: u64 = @as(u64, unit) * @as(u64, qty);
        if (cost_wide > std.math.maxInt(u16)) return false;
        const cost: u32 = @intCast(cost_wide);
        if (w.wallet[ps].coins < cost) return false;
        // Spend coins from the client bag first so it matches the wallet;
        // only the remainder draws on server-side balance (quest rewards).
        // Removing min(have, cost) keeps wallet >= inv coins, so the sync
        // above can never re-mint what a buy already spent.
        if (w.mask[ps].inventory) {
            const inventory_before = w.inventory[ps];
            const have = w.inventory[ps].countItem(coin_id);
            const from_inv: u32 = @min(have, cost);
            if (from_inv > 0) {
                if (!w.inventory[ps].removeItem(coin_id, @intCast(from_inv))) {
                    w.inventory[ps] = inventory_before;
                    return false;
                }
            }
            if (!w.depositItem(ps, item, qty)) {
                w.inventory[ps] = inventory_before;
                return false;
            }
            w.markDirty(ps, .{ .inv = true });
        }
        en.count -= qty;
        w.wallet[ps].coins -= cost;
        // Stock credits the trader's AvailableMoney with the sale (the
        // wire TraderData shows the live balance). Clamp at i32 max.
        stock.wallet = @intCast(@min(@as(i64, stock.wallet) + cost, std.math.maxInt(i32)));
        // Demand spike: a buy raises the entry's markup to +100
        // (TraderData/Entry::IncreaseMarkup, asm.il 856828-856866).
        en.markup = 100;
        return true;
    } else {
        // Sell: stock GetSellPrice (XUiM_Trader IL=217) prices the SOLD
        // ItemValue - base EconomicValue x EconomicSellScale x SellMarkdown
        // (the hook; stocked entries use the same base, their en.sell bakes
        // the entry's own fresh quality) scaled by the sold stack's quality
        // lerp (quality_mod) and PercentUsesLeft (worn items sell for less,
        // RE ItemValue IL=17 / items.md §7). Without a hook (pure-ECS tests)
        // the entry's sell stands.
        var sold_quality: u8 = 1;
        var sold_use_times: f32 = 0;
        if (w.mask[ps].inventory) {
            for (w.inventory[ps].slots) |s| {
                if (s.item_id == item and s.count > 0) {
                    sold_quality = s.quality;
                    sold_use_times = s.use_times;
                    break;
                }
            }
        }
        var unit: u32 = if (w.sell_price_fn) |f|
            f(w.sell_price_ctx, item, ts)
        else if (entry) |en|
            @as(u32, en.sell)
        else
            return false;
        if (unit == 0) return false;
        const qmod = qualityPriceMod(w.trader_quality_min_mod, w.trader_quality_max_mod, sold_quality);
        var scaled: f64 = @as(f64, @floatFromInt(unit)) * qmod;
        if (w.percent_uses_left_fn) |p| {
            scaled *= @as(f64, p(w.percent_uses_left_ctx, item, sold_quality, sold_use_times));
        }
        // Clamp before the cast: a hostile sell hook or modded quality_mod can
        // exceed u32 range (or go non-finite), which traps in @intFromFloat;
        // fail closed at 1 instead of crashing the tick.
        if (!std.math.isFinite(scaled) or scaled <= 1.0) {
            unit = 1;
        } else {
            unit = @intFromFloat(@min(scaled, @as(f64, std.math.maxInt(u32))));
        }
        if (unit == 0) return false;
        // Same widening as the buy cost above.
        const gain_wide: u64 = @as(u64, unit) * @as(u64, qty);
        if (gain_wide > std.math.maxInt(u16)) return false;
        const gain: u32 = @intCast(gain_wide);
        if (w.wallet[ps].coins > std.math.maxInt(u32) - gain) return false;
        if (entry) |en| {
            if (en.count > std.math.maxInt(u16) - qty) return false;
        }
        // Stock debits the trader's AvailableMoney when buying from the
        // player and refuses the sale once the money runs out
        // (TraderInfo money pool; TraderBuyLimit is a separate row).
        if (stock.wallet < 0 or gain > @as(u32, @intCast(stock.wallet))) return false;
        // Take goods from inv when selling.
        if (w.mask[ps].inventory) {
            const inventory_before = w.inventory[ps];
            if (w.inventory[ps].countItem(item) < qty) return false;
            if (!w.inventory[ps].removeItem(item, qty)) return false;
            if (!w.depositItem(ps, coin_id, @intCast(gain))) {
                w.inventory[ps] = inventory_before;
                return false;
            }
            w.markDirty(ps, .{ .inv = true });
        }
        if (entry) |en| {
            en.count += qty;
            // A sell eases demand: step the entry's markup down by 4
            // (DecreaseMarkup, asm.il 856828-856866), saturating at i8 min.
            en.markup -|= 4;
        }
        w.wallet[ps].coins += gain;
        stock.wallet -= @intCast(gain);
        return true;
    }
    return false;
}

/// Restock trader inventories toward default counts, gated per trader by the
/// traders.xml `<trader_info>` ResetInterval (fillTraderFromXml copies it into
/// TraderStock.reset_interval): -1 never restocks, 0 restocks every day roll,
/// N > 0 restocks when day >= last_restock_day + N.
pub fn traderRestock(w: *World) void {
    const day = w.director.clock.day;
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        if (!w.alive[i] or !w.mask[i].trader_stock) continue;
        var stock = &w.trader_stock[i];
        if (stock.reset_interval < 0) continue;
        if (stock.reset_interval > 0) {
            // Wrapping-safe window test: day - last < interval, never a
            // last + interval u32 add that could wrap in ReleaseFast.
            if (day -| stock.last_restock_day < @as(u32, @intCast(stock.reset_interval))) continue;
        }
        stock.last_restock_day = day;
        var e: usize = 0;
        while (e < stock.n) : (e += 1) {
            // Grow toward the configured soft cap for stackables
            // (zdtd.toml [sim] trader_restock_cap / trader_restock_refill).
            if (stock.entries[e].count < w.trader_restock_cap) {
                stock.entries[e].count +%= @min(w.trader_restock_refill, w.trader_restock_cap -| stock.entries[e].count);
            }
            // Fresh entries: demand resets (stock HandleFullReset rebuilds the
            // inventory, which drops the old markups).
            stock.entries[e].markup = 0;
        }
        // The money pool regenerates toward its spawn default each restock.
        if (stock.wallet < stock.wallet_default) stock.wallet = stock.wallet_default;
    }
}

// --- Combat AI: stock EAITask prioritized task graph (parallel over slots) ---
//
// Faithful port of EAITaskList::OnUpdateTasks + isBestTask (asm.il:437713,
// :437874). Each zombie's AI is an ordered task list; every tick the winning
// task is (re)selected by priority + MutexBits and projected back onto the
// coarse ZombieAi.state enum so downstream replication (game.zig EntitySpeeds/
// AliveFlags, block-damage, despawn) keeps working unchanged.
//
// Nine real tasks: BreakBlock, DestroyArea, RunawayWhenHurt, ApproachAndAttackTarget,
// ApproachDistraction, Territorial, ApproachSpot, Look, Wander. Rest of stock EAI
// (Dodge, Leap, RangedAttack, ...) remains a gap (docs/GAP_ANALYSIS.md).
// BreakBlock/DestroyArea use mutex 0 so isBestTask allows them while Approach
// executes when path_blocked; movement tasks still share bit 0. Collapsing
// executingTasks to one TaskId stays exact for this set.
//
/// Comptime task table. Priority ascending == array order == stock XML AITask
/// order == EAIManager::ParseTasks insertion order (asm.il:430620). Values
/// mirror EAIBreakBlock (asm.il:425121; light chew when path stuck),
/// EAIDestroyArea (chew cover while chase / path stuck),
/// EAIApproachAndAttackTarget::Init (MutexBits=3, executeDelay=0.1,
/// non-continuous; asm.il:421798), EAITerritorial (return home when far),
/// EAIApproachSpot (asm.il:424093; below chase, above wander), and
/// EAIWander::Init (MutexBits=1, continuous default; asm.il:438104,424579).
const Task = struct { id: c.TaskId, priority: u8, mutex: u8, execute_delay: f32, continuous: bool };
const zombie_tasks = [_]Task{
    // mutex 0: compatible with approach so table order can switch when stuck.
    .{ .id = .break_block, .priority = 1, .mutex = 0b00, .execute_delay = 0.2, .continuous = false },
    .{ .id = .destroy_area, .priority = 1, .mutex = 0b00, .execute_delay = 0.25, .continuous = false },
    // EAIRunawayWhenHurt (asm.il:435616): MutexBits=1 in .ctor (:435629), no
    // Init override so executeDelay/IsContinuous stay the EAIBase defaults.
    // Ahead of Approach the way AITask-1 sits ahead of it in a passive-animal
    // class; its kind gate keeps it out of the zombie list.
    .{ .id = .runaway, .priority = 1, .mutex = 0b01, .execute_delay = 0.5, .continuous = true },
    .{ .id = .approach_attack, .priority = 1, .mutex = 0b11, .execute_delay = 0.1, .continuous = false },
    // EAIApproachDistraction (asm.il:423700): MutexBits=3, no Init override so
    // executeDelay/continuous are the EAIBase defaults (0.5 / true). Priority 1
    // mirrors stock order (AITask-4, ahead of ApproachAndAttack-5 and far ahead
    // of Wander-8); the CanExecute gate (no attack target) keeps it below chase,
    // and the 0b11 mutex keeps it exclusive with approach_attack. continuous is
    // forced false like approach_attack: a continuous priority-1 task would let
    // the wander fallback (always CanExecute when no player is sensed) steal the
    // walk every decision window via isBestTask's continuous yield.
    .{ .id = .approach_distraction, .priority = 1, .mutex = 0b11, .execute_delay = 0.5, .continuous = false },
    .{ .id = .territorial, .priority = 2, .mutex = 0b01, .execute_delay = 0.2, .continuous = true },
    .{ .id = .approach_spot, .priority = 2, .mutex = 0b01, .execute_delay = 0.2, .continuous = true },
    // EAILook: MutexBits=1 (.ctor, asm.il:429876); no Init override so
    // executeDelay is the EAIBase::Init default 0.5 and IsContinuous the
    // EAIBase default true (asm.il:424579).
    .{ .id = .look, .priority = 2, .mutex = 0b01, .execute_delay = 0.5, .continuous = true },
    .{ .id = .wander, .priority = 2, .mutex = 0b01, .execute_delay = 0.5, .continuous = true },
};

fn taskById(id: c.TaskId) ?Task {
    for (zombie_tasks) |t| {
        if (t.id == id) return t;
    }
    return null;
}

/// EAITaskList::isBestTask (asm.il:437874) reduced to a single executing task.
/// `self` is best unless the executing task (a) has a higher priority number
/// and is non-continuous, or (b) has priority <= self and its MutexBits overlap
/// (areTasksCompatible, asm.il:437930: `(a.MutexBits & b.MutexBits) == 0`).
fn isBestTask(self: Task, executing: c.TaskId) bool {
    if (executing == .none or executing == self.id) return true;
    const other = taskById(executing).?;
    if (other.priority > self.priority) return other.continuous;
    return (self.mutex & other.mutex) == 0;
}

/// EAIApproachAndAttackTarget::CanExecute (asm.il:421936) gate, reduced to
/// "has a valid attack target and can move". A freshly sensed player OR
/// director-seeded aggro (`alert && target_id>=0`) both count. Stock returns
/// false when GetAttackTarget()==null, so the persistence branch holds only
/// while the seeded target entity still exists (its removal releases the mutex
/// so Wander resumes). The chaseTimeMax aggro-timeout countdown is not modeled
/// (coarse `alert` flag only). Continue() defaults to CanExecute (asm.il:424569).
fn approachCanExecute(w: *const World, ai: *const c.ZombieAi, np_id: i32, np_d2: f32, sense_d2: f32) bool {
    if (np_id >= 0 and np_d2 < sense_d2) return true;
    return ai.alert and ai.target_id >= 0 and targetLive(w, ai.target_id);
}

/// EAIApproachSpot::CanExecute (asm.il:424093): director/AI set a spot to walk to.
fn approachSpotCanExecute(ai: *const c.ZombieAi) bool {
    return ai.has_spot;
}

/// EAIApproachDistraction::CanExecute (asm.il:423700): a dropped EntityItem
/// registered itself as pendingDistraction (EntityItem.tickDistraction), or the
/// task is already walking one (Start moved pending → distraction), and the
/// entity has no attack target. Stock also bails at close range on non-eat
/// items and clears the pending slot there; zdtd clears in the Update instead
/// (CanExecute stays read-only, matching the other gates).
fn approachDistractionCanExecute(w: *const World, ai: *const c.ZombieAi, np_id: i32, np_d2: f32, sense_d2: f32) bool {
    const live = ai.pending_distraction >= 0 or ai.distraction >= 0;
    if (!live) return false;
    const latch = if (ai.distraction >= 0) ai.distraction else ai.pending_distraction;
    if (w.slotOfNetId(latch) == null) return false;
    // GetAttackTarget()!=null → false (asm.il CanExecute IL_001E-002E), and the
    // persistent aggro branch (alert + live target) counts as one too.
    const has_target = (np_id >= 0 and np_d2 < sense_d2) or
        (ai.alert and ai.target_id >= 0 and targetLive(w, ai.target_id));
    if (has_target) return false;
    return true;
}

/// EAIApproachDistraction::Continue (asm.il:423700): the latched `distraction`
/// is still a live dropped item, and either the zombie is still walking to it
/// or it is an active eat item it is allowed to keep chewing.
fn approachDistractionContinue(w: *const World, s: Slot, ai: *const c.ZombieAi) bool {
    if (ai.distraction < 0) return false;
    const ds = w.slotOfNetId(ai.distraction) orelse return false;
    if (!w.alive[ds] or !w.mask[ds].loot_bag) return false;
    const dx = w.transform[ds].x - w.transform[s].x;
    const dz = w.transform[ds].z - w.transform[s].z;
    if (dx * dx + dz * dz > w.rules.ai.distraction_close_sq) return true;
    return (w.loot_bag[ds].distraction_tags & 1) != 0;
}

/// EAIWander::CanExecute (asm.il:438161) does NOT test for a target; here it is
/// the pure fallback: wander whenever no player is sensed. It yields to chase
/// only through priority + MutexBits, never through this gate. Spot also wins
/// over wander via table order when has_spot (same priority/mutex).
fn wanderCanExecute(_: *const World, ai: *const c.ZombieAi, np_id: i32, np_d2: f32, sense_d2: f32) bool {
    // EAIWander::CanExecute returns false while lookTime > 0 (asm.il:438181):
    // Look and Wander are mutually exclusive by data, not only by MutexBits.
    if (ai.look_time > 0) return false;
    return !(np_id >= 0 and np_d2 < sense_d2);
}

/// EAIWander::Continue (asm.il:438318) is a real override distinct from
/// CanExecute: stop on the 30 s cap and when the path is finished. The stun and
/// moveHelper.BlockedTime bails have no zdtd equivalent.
fn wanderContinue(w: *const World, s: Slot, ai: *const c.ZombieAi, np_id: i32, np_d2: f32, sense_d2: f32) bool {
    if (!wanderCanExecute(w, ai, np_id, np_d2, sense_d2)) return false;
    if (ai.wander_time > w.rules.ai.wander_time_max_s) return false;
    const dx = ai.wander_tx - w.transform[s].x;
    const dz = ai.wander_tz - w.transform[s].z;
    const wa = w.rules.ai.wander_arrive;
    return dx * dx + dz * dz > wa * wa;
}

/// EAILook::CanExecute (asm.il:429881): `lookTime > 0 && !Jumping`. zdtd has no
/// jumping, so the gate reduces to the owed-time test.
fn lookCanExecute(ai: *const c.ZombieAi) bool {
    return ai.look_time > 0;
}

/// EAILook::Continue (asm.il:430007): false once waitTicks runs out. The stun
/// bail and the IsAlert double-drain are not modeled (no stun; Approach always
/// preempts Look before it could be alert).
fn lookContinue(ai: *const c.ZombieAi) bool {
    return ai.look_wait > 0;
}

fn wrap360(deg: f32) f32 {
    const r = @mod(deg, 360.0);
    return if (r < 0) r + 360.0 else r;
}

/// Entity::SeekYaw (asm.il:399475) speed law, applied per tick instead of via
/// stock's yawSeekAngle/yawSeekTimeMax slew: normalize both angles, wrap the
/// delta into [-180,180], and slow quadratically inside `slow_at` with a
/// 20 deg/s floor. Returns the new yaw in [0,360).
fn seekYawStep(cur_deg: f32, target_deg: f32, max_turn_deg: f32, slow_at_deg: f32, min_speed_deg: f32, dt: f32) f32 {
    const cur = wrap360(cur_deg);
    const tgt = wrap360(target_deg);
    var delta = tgt - cur;
    if (delta < -180.0) delta += 360.0;
    if (delta > 180.0) delta -= 360.0;
    const mag = @abs(delta);
    if (mag == 0) return tgt;
    var speed = max_turn_deg;
    if (mag < slow_at_deg and slow_at_deg > 0) {
        const f = mag / slow_at_deg;
        speed = @max(max_turn_deg * f * f, min_speed_deg);
    }
    const step = @min(speed * dt, mag);
    return wrap360(cur + std.math.sign(delta) * step);
}

const AiCtx = struct {
    w: *World,
    dt: f32,
    players: []const PlayerSnap,
    /// Tick-start copy of `w.transform`. A worker owns only its own slot range,
    /// so every cross-slot position read (fear scan, revenge target) must come
    /// from here: reading `w.transform[other]` races the worker writing it.
    pos: *const [max_entities]c.Transform,
    /// Fixed-point damage accumulators, one per entity slot (atomic adds).
    dmg_fp: []u32,
    hits: *std.atomic.Value(u32),
    /// Snapshotted before forRanges so workers never reread a field the
    /// director (or another tick phase) may rewrite on the main thread.
    zombie_speed_scale: f32,

    fn work(ctx: AiCtx, begin: usize, end: usize) void {
        var i: usize = begin;
        while (i < end) : (i += 1) {
            const s: Slot = @intCast(i);
            if (!ctx.w.alive[s] or !ctx.w.mask[s].zombie_ai or !ctx.w.mask[s].transform) continue;
            var ai = &ctx.w.zombie_ai[s];
            // Knockback shove: displace before the AI step so the push wins
            // the tick and the entity re-approaches from the pushed spot.
            if (ai.kb_time > 0) {
                const w2 = ctx.w;
                w2.transform[s].x += ai.kb_dx * ctx.w.rules.combat.knockback_speed * ctx.dt;
                w2.transform[s].z += ai.kb_dz * ctx.w.rules.combat.knockback_speed * ctx.dt;
                ai.kb_time -= ctx.dt;
                if (ai.kb_time <= 0) {
                    ai.kb_time = 0;
                    ai.kb_dx = 0;
                    ai.kb_dz = 0;
                }
                w2.markDirty(s, .{ .pos = true });
            }
            // Sleepers: stay sleep until player in volume. Stealth (RE
            // entity-ai.md CanSleeperAttackDetect): a crouched player only
            // disturbs sleepers within FastLerp(3, 15, lightAttackPercent)
            // (lightAttackPercent = passive-89: selfLight < 0.1 per TickServer
            // IL_010B, no item-light model → 13.68); standing players wake at
            // the volume radius. RE UpdateSleeper adds the disturbed-level
            // light gate: wake = Lerp(rolledWakeNear, rolledWakeFar,
            // dist/sightRangeBase), woken iff the player's lightLevel > wake
            // (GetSleeperDisturbedLevel IL=38, level >= 2).
            if (ctx.w.mask[s].sleeper and !ctx.w.sleeper[s].awake) {
                const sl = ctx.w.sleeper[s];
                const ar = ctx.w.rules.ai;
                const sr = @sqrt(senseDistSq(ctx.w, s)); // sightRangeBase
                var near = false;
                for (ctx.players) |pl| {
                    const dx = pl.x - sl.home_x;
                    const dz = pl.z - sl.home_z;
                    const dist = @sqrt(dx * dx + dz * dz);
                    if (dist > sl.volume_r) continue; // out of the volume entirely
                    // lightAttackPercent: selfLight < 0.1 → the passive-89
                    // always, a held light (torch/flashlight) raises it to 1,
                    // so the crouch range FastLerp(3, 15, t) stretches to the
                    // full 15.
                    const lap = stealthLightAttackPercent(pl.self_light, ar.stealth_light_passive);
                    const crouch_reach = ar.crouch_sleeper_detect_min +
                        (ar.crouch_sleeper_detect_max - ar.crouch_sleeper_detect_min) * lap;
                    const wake_reach = if (pl.crouching) @min(sl.volume_r, crouch_reach) else sl.volume_r;
                    if (dist <= wake_reach) {
                        if (sr > 0.001) {
                            const pct = dist / sr;
                            if (pct <= 1.0) { // GetSleeperDisturbedLevel: pct > 1 → 0
                                const wake = sl.wake_light_near + (sl.wake_light_far - sl.wake_light_near) * pct;
                                if (pl.light_level > wake) {
                                    near = true;
                                    break;
                                }
                            }
                        } else {
                            near = true; // no sightRangeBase: gate open (fallback)
                            break;
                        }
                    }
                    // In the volume but not waking (dark/crouched beyond the
                    // wake reach): the sleeper STIRS - RE EntityAlive.
                    // SetSleeperActive (IL=26) clears IsSleeperPassive and
                    // broadcasts NetPackageSleeperPassiveChange so the client
                    // plays the groan. One-shot per sleeper.
                    if (!sl.groan_sent) {
                        ctx.w.sleeper[s].groan_sent = true;
                        ctx.w.pushSleeperGroan(s);
                    }
                }
                if (!near) {
                    ai.state = .sleep;
                    continue;
                }
                ctx.w.sleeper[s].awake = true;
                ai.state = .chase;
                // Stock EntityAlive.ConditionalTriggerSleeperWakeUp broadcasts
                // NetPackageSleeperWakeup so the client plays the wake; the
                // Game drains the ring in step (RE entity-ai.md sleeper wake).
                ctx.w.pushSleeperWake(s);
            }
            if (ai.attack_cd > 0) ai.attack_cd -= ctx.dt;

            // Demolition (RE entity-ai.md EntityZombieCop.OnUpdateEntity):
            // when health drops below max*explode_threshold the cop primes,
            // then ticks down explodeDelay*20; at zero it readies the blast
            // ((explodeDelay/5)*1.5*20 ticks) and pushes an explode request
            // the Game drains (entity + block AoE). Class data gates it: a
            // class without ExplosionData never primes (threshold 0).
            const ctd = ctx.w.class_table[ctx.w.class_id[s].id].explode_threshold;
            const ptd = ctx.w.class_id[s].explode_threshold;
            const threshold: f32 = if (ptd > 0) ptd else ctd;
            if (threshold > 0 and ctx.w.mask[s].health) {
                const health = ctx.w.health[s];
                const delay: f32 = if (ctx.w.class_id[s].explode_delay_s > 0)
                    ctx.w.class_id[s].explode_delay_s
                else
                    ctx.w.class_table[ctx.w.class_id[s].id].explode_delay_s;
                if (ai.primed) {
                    if (ai.prime_ticks > 0) {
                        ai.prime_ticks -= 1;
                        if (ai.prime_ticks == 0) {
                            ai.explode_ticks = @intFromFloat(delay / 5.0 * 1.5 * 20.0);
                        }
                    }
                    if (ai.explode_ticks > 0) {
                        ai.explode_ticks -= 1;
                        if (ai.explode_ticks == 0) {
                            ctx.w.pushExplode(s);
                            ai.explode_ticks = -1; // once per prime
                        }
                    }
                } else if (health.max_hp > 0 and health.hp < health.max_hp * threshold and
                    !ctx.w.mask[s].sleeper)
                {
                    ai.primed = true;
                    ai.prime_ticks = @intFromFloat(delay * 20.0);
                }
            }

            // EAIRunawayFromEntity (AITask-2): passive animals scan for feared
            // classes (players, zombies, other animals) within fleeDistance on
            // a 0.5 s cadence; the runaway task then flees the nearest one.
            if (ctx.w.kind[s] == .animal) refreshFearSource(ctx.w, ctx.pos, s, ai, ctx.dt);

            // AITarget list before AITask list: a fresh attacker outranks the
            // nearest sensed player for the revenge window.
            var np = applyRevengeTarget(ctx.w, ctx.pos, s, ai, nearestPlayerSnap(ctx.w, ctx.players, s, ctx.w.transform[s].x, ctx.w.transform[s].y, ctx.w.transform[s].z, ctx.w.transform[s].yaw), ctx.dt);
            // Host-side bot as a secondary target (ADR 0026): with no player
            // sensed (and no revenge latched), a zombie senses the nearest
            // live bot within its own sight range and chases it. Bots are not
            // ECS entities; the Game-side bot hook answers this.
            if (np.id < 0) {
                np = nearestBotSnap(ctx.w, ctx.w.transform[s].x, ctx.w.transform[s].z, senseDistSq(ctx.w, s), -1);
            }
            ai.active_scale = if (np.id >= 0) lodScale(ctx.w, np.d2) else ctx.w.rules.ai.no_target_scale;

            // Ultra-far sleep: player exists but beyond `sleep_dist_mult` x full
            // AI range → slow wander only (no A*/task scan) unless chewing a
            // blocked path. No-player still runs the normal table.
            if (np.id >= 0 and np.d2 > ctx.w.rules.ai.full_dist_sq * ctx.w.rules.ai.sleep_dist_mult and !ai.path_blocked and
                ai.active_task != .break_block and ai.active_task != .destroy_area)
            {
                if (ai.attack_cd > 0) ai.attack_cd -= ctx.dt;
                ai.decision_cd -= ctx.dt * ctx.w.rules.ai.sleep_decision_scale;
                if (ai.decision_cd > 0) continue;
                const sscale = ctx.zombie_speed_scale;
                const ct = &ctx.w.class_table[ctx.w.class_id[s].id];
                const pws = ctx.w.class_id[s].wander_speed;
                const pwsn = ctx.w.class_id[s].wander_speed_night;
                // Stock GetMoveSpeed (entity-ai.md): dark → MoveSpeedNight
                // (passive 133) else MoveSpeed (passive 135); a class without
                // MoveSpeedNight seeds it from MoveSpeed (entity-ai.md 3312).
                const night = ctx.w.director.clock.isNight();
                const wspd: f32 = (if (night and pwsn > 0) pwsn * 10.0 else if (pws > 0) pws * 10.0 else if (night and ct.wander_speed_night > 0) ct.wander_speed_night * 10.0 else if (ct.wander_speed > 0) ct.wander_speed * 10.0 else ctx.w.rules.ai.wander_speed) * sscale;
                ai.active_task = .wander;
                ai.decision_cd = ctx.w.rules.ai.sleep_wander_interval_s;
                wanderUpdate(ctx.w, s, ai, wspd * ctx.w.rules.ai.sleep_wander_speed_frac, ctx.dt);
                applyGravity(ctx.w, s, ctx.dt);
                continue;
            }

            // A11/A35: per-entity class stats win (the resolver carries the
            // full entityclasses row for classes not in the fixed table); the
            // class_table row is the fallback, then the Rules floor.
            // MoveSpeed ~0.08 shamble → x10; MoveSpeedAggro max ~1.35 → x1.6.
            // Day/night split (entity-ai.md GetMoveSpeed/GetMoveSpeedAggro):
            // dark → MoveSpeedNight + MoveSpeedAggro max (passives 133/134),
            // day → MoveSpeed + MoveSpeedAggro min (passives 135/133); the
            // stock XML comment on MoveSpeedAggro ("min/max (like day or
            // night)") pins the split. A class without MoveSpeedNight seeds
            // it from MoveSpeed (entity-ai.md 3312).
            const ct = &ctx.w.class_table[ctx.w.class_id[s].id];
            const pws = ctx.w.class_id[s].wander_speed;
            const pwsn = ctx.w.class_id[s].wander_speed_night;
            const pcs = ctx.w.class_id[s].chase_speed;
            const pcsd = ctx.w.class_id[s].chase_speed_day;
            const sscale = ctx.zombie_speed_scale;
            const night = ctx.w.director.clock.isNight();
            const wspd: f32 = (if (night and pwsn > 0) pwsn * 10.0 else if (pws > 0) pws * 10.0 else if (night and ct.wander_speed_night > 0) ct.wander_speed_night * 10.0 else if (ct.wander_speed > 0) ct.wander_speed * 10.0 else ctx.w.rules.ai.wander_speed) * sscale;
            const cspd: f32 = (if (night)
                (if (pcs > 0) pcs * 1.6 else if (ct.chase_speed > 0) ct.chase_speed * 1.6 else ctx.w.rules.ai.chase_speed)
            else
                (if (pcsd > 0) pcsd * 1.6 else if (ct.chase_speed_day > 0) ct.chase_speed_day * 1.6 else ctx.w.rules.ai.chase_speed)) * sscale;

            // EAITaskList::OnUpdateTasks step 1 (asm.il:437713): stop the
            // executing task when it is no longer best or its Continue() fails.
            if (ai.active_task != .none) {
                const t = taskById(ai.active_task).?;
                if (!(isBestTask(t, ai.active_task) and canContinue(ctx.w, s, ai.active_task, ai, np))) {
                    ai.decision_cd = t.execute_delay * ctx.w.rules.ai.execute_delay_scale;
                    // EAIBase::Reset fires on this exact path (asm.il:437713,
                    // IL_006F): a finished Wander / ApproachSpot seeds lookTime.
                    resetTask(ctx.w, ai.active_task, ai, ctx.w.network_id[s].id);
                    ai.active_task = .none;
                }
            }

            // Re-eval timer: stock's fixed 0.05s/20Hz AI tick is replaced by
            // zdtd's variable dt*active_scale LOD throttle. Step 2: on expiry,
            // start the first table task that is best and CanExecute (== stock
            // priority-ascending scan), then run its Start hook.
            ai.decision_cd -= ctx.dt * ai.active_scale;
            if (ai.decision_cd <= 0) {
                var chosen: c.TaskId = .none;
                for (zombie_tasks) |t| {
                    if (isBestTask(t, ai.active_task) and canExecute(ctx.w, s, t.id, ai, np)) {
                        chosen = t.id;
                        break;
                    }
                }
                // Preemption: stock removes the loser from executingTasks via the
                // same Reset path, so a Wander cut short by Approach still seeds
                // the look-around that plays once the chase ends.
                if (chosen != ai.active_task) resetTask(ctx.w, ai.active_task, ai, ctx.w.network_id[s].id);
                ai.active_task = chosen;
                ai.decision_cd = (taskById(chosen) orelse zombie_tasks[0]).execute_delay * ctx.w.rules.ai.execute_delay_scale;
                startTask(chosen, ctx.w, s, ai);
            }

            // Steps 3/4: run the winning task's Update and project it onto the
            // coarse ZombieAi.state enum for downstream replication parity.
            switch (ai.active_task) {
                .break_block => breakBlockUpdate(ctx.w, s, ai, np, ctx.dt),
                .destroy_area => destroyAreaUpdate(ctx.w, s, ai, np, ctx.dt),
                .runaway => runawayUpdate(ctx.w, ctx.pos, s, ai, cspd, ctx.dt),
                .approach_attack => approachUpdate(ctx, s, ai, np, cspd, ct),
                .territorial => territorialUpdate(ctx.w, s, ai, cspd, ctx.dt),
                .approach_distraction => approachDistractionUpdate(ctx.w, s, ai, cspd, ctx.dt),
                .approach_spot => approachSpotUpdate(ctx.w, s, ai, cspd, ctx.dt),
                .look => lookUpdate(ctx.w, s, ai, ctx.dt),
                .wander => wanderUpdate(ctx.w, s, ai, wspd, ctx.dt),
                .none => {
                    if (ai.state != .sleep) ai.state = .idle;
                    ai.alert = false;
                    ai.path_blocked = false;
                },
            }

            if (ai.alert or ai.state == .chase or ai.state == .attack) {
                ctx.w.flags[s].bits |= c.flag_is_alert;
            } else {
                ctx.w.flags[s].bits &= ~c.flag_is_alert;
            }

            // Vertical settle once per tick (gravity + ground snap), so the
            // body falls and lands even when its task never moves horizontally.
            applyGravity(ctx.w, s, ctx.dt);
        }
    }
};

/// Sense range for one entity, squared blocks. **Per-class first**:
/// entityclasses.xml ships `SightRange` per class (stock zombies 27-40 m), so a
/// feral does not sense at the same distance as a crawler. The `Rules` value is
/// the floor for a class with no SightRange, or when no entityclasses.xml
/// loaded (ADR 0021 decision 5).
///
/// Note the search bound in `nearestPlayerSnap` stays on the Rules value: it is
/// an outer bound over every entity, not a per-entity gate, and every stock
/// SightRange sits under it.
fn senseDistSq(w: *const World, s: Slot) f32 {
    // A35 per-entity layer first: the def spawns carry SightRange onto the
    // entity, so a class outside the fixed class_table senses as itself too.
    const pe = w.class_id[s].sight_range;
    if (pe > 0) return pe * pe;
    const sr = w.class_table[w.class_id[s].id].sight_range;
    if (sr > 0) return sr * sr;
    return w.rules.ai.sense_dist_sq;
}

/// Dispatch to a task's CanExecute gate (selection pass, step 2).
fn canExecute(w: *const World, s: Slot, id: c.TaskId, ai: *const c.ZombieAi, np: anytype) bool {
    const sense_d2 = senseDistSq(w, s);
    return switch (id) {
        .break_block => breakBlockCanExecute(w, s, ai, np.id, np.d2, sense_d2),
        .destroy_area => destroyAreaCanExecute(w, s, ai, np.id, np.d2, sense_d2),
        .runaway => runawayCanExecute(w, s, ai),
        .approach_attack => w.class_id[s].ai_attack and approachCanExecute(w, ai, np.id, np.d2, sense_d2),
        .territorial => territorialCanExecute(w, s, ai, np.id, np.d2, sense_d2),
        .approach_distraction => approachDistractionCanExecute(w, ai, np.id, np.d2, sense_d2),
        .approach_spot => approachSpotCanExecute(ai),
        .look => lookCanExecute(ai),
        .wander => wanderCanExecute(w, ai, np.id, np.d2, sense_d2),
        .none => false,
    };
}

/// Dispatch to a task's Continue() gate (stop pass, step 1). EAIBase::Continue
/// defaults to CanExecute (asm.il:424569); Wander and Look are the two tasks
/// with real overrides, and they are exactly the two whose start state must be
/// allowed to run down instead of being re-tested against the start condition.
fn canContinue(w: *const World, s: Slot, id: c.TaskId, ai: *const c.ZombieAi, np: anytype) bool {
    return switch (id) {
        .wander => wanderContinue(w, s, ai, np.id, np.d2, senseDistSq(w, s)),
        .look => lookContinue(ai),
        // EAIApproachDistraction overrides Continue to read `distraction`
        // (Start moved pending there), not the pending slot.
        .approach_distraction => approachDistractionContinue(w, s, ai),
        else => canExecute(w, s, id, ai, np),
    };
}

/// EAIBase::Reset, invoked by EAITaskList::OnUpdateTasks on the same path that
/// clears isExecuting and reloads executeTime (asm.il:437713, IL_006F). Only
/// four sites in the whole assembly write EAIManager::lookTime; two of them are
/// the Reset hooks below, and they are what produce the wander/look-around
/// cycle. Every other task inherits the empty EAIBase::Reset.
fn resetTask(w: *const World, id: c.TaskId, ai: *c.ZombieAi, rng_seed: i32) void {
    const ai_rules = w.rules.ai;
    switch (id) {
        .wander => {
            // EAIWander::Reset (asm.il:438383): lookTime = RandomRange(0.5, 5).
            ai.look_time = ai_rules.wander_look_min_s + rngFrac(ai, rng_seed) * (ai_rules.wander_look_max_s - ai_rules.wander_look_min_s);
            ai.wander_time = 0;
        },
        // EAIApproachSpot::Reset (asm.il:424395): lookTime = 5 + rand*3.
        .approach_spot => ai.look_time = ai_rules.spot_look_base_s + rngFrac(ai, rng_seed) * ai_rules.spot_look_rand_s,
        // EAIApproachDistraction::Reset (asm.il:423700): moveHelper.Stop,
        // IsEating=false, distraction=null, manager.lookTime = 2.
        .approach_distraction => {
            ai.distraction = -1;
            ai.pending_distraction = -1;
            ai.pending_distraction_dsq = 0;
            ai.is_eating = false;
            ai.look_time = ai_rules.distraction_look_s;
            ai.clearPath();
            ai.has_path = false;
            ai.path_blocked = false;
        },
        else => {},
    }
}

/// Advance the per-entity xorshift stream and return a value in [0,1). Stock's
/// EAIBase::get_Random is the entity's single shared GameRandom, so reusing the
/// one wander stream for every task draw matches it.
fn rngFrac(ai: *c.ZombieAi, rng_seed: i32) f32 {
    if (ai.wander_rng == 0) ai.wander_rng = rng_util.XorShift32.initFromNetId(rng_seed).state;
    ai.wander_rng = rng_util.xorshift32Step(ai.wander_rng);
    return @as(f32, @floatFromInt(ai.wander_rng % 10000)) / 10000.0;
}

/// Per-class melee reach, squared: the hand item's items.xml Range (zombie
/// hand 1.6) or passive MaxRange (club/axe 2.4); 0 → the combat floor.
fn meleeRangeSq(w: *const World, s: Slot) f32 {
    const pe = w.class_id[s].melee_range;
    if (pe > 0) return pe * pe;
    return w.rules.combat.attack_range_sq;
}

/// EAIBreakBlock::CanExecute (asm.il:425121): alert chase with a sensed player
/// and a solid cell directly toward the goal (set by chaseAlongPath).
fn breakBlockCanExecute(w: *const World, s: Slot, ai: *const c.ZombieAi, np_id: i32, np_d2: f32, sense_d2: f32) bool {
    if (!ai.path_blocked) return false;
    if (!(np_id >= 0 and np_d2 < sense_d2)) return false;
    // Melee range: approach owns the bite; do not stick on break.
    if (np_d2 <= meleeRangeSq(w, s)) return false;
    return true;
}

/// Hold chase projection so Game.tickZombieBlockDamage keeps chewing the cover
/// block. Throttled A* replan clears path_blocked when a detour opens.
fn breakBlockUpdate(w: *World, s: Slot, ai: *c.ZombieAi, np: anytype, dt: f32) void {
    ai.alert = true;
    if (np.id >= 0) {
        ai.target_id = np.id;
        ai.path_goal_x = np.px;
        ai.path_goal_z = np.pz;
    }
    ai.state = .chase;
    ai.has_path = true;
    if (w.step_fn == null) {
        ai.path_blocked = false;
        return;
    }
    // Replan on the same cadence as chase so destroyed cover resumes approach.
    if (ai.path_replan_cd > 0) {
        ai.path_replan_cd -= dt;
        return;
    }
    if (!w.pathBudgetAdmits(s)) {
        _ = w.path_replans_denied.fetchAdd(1, .monotonic);
        return;
    }
    replanPath(w, s, ai, @floor(ai.path_goal_x), @floor(ai.path_goal_z));
}

/// EAIDestroyArea::CanExecute: alert/target chase with path stuck, or sparse
/// random while chasing (same block-damage feed as BreakBlock).
fn destroyAreaCanExecute(w: *const World, s: Slot, ai: *const c.ZombieAi, np_id: i32, np_d2: f32, sense_d2: f32) bool {
    const chasing = (np_id >= 0 and np_d2 < sense_d2) or (ai.alert and ai.target_id >= 0);
    if (!chasing) return false;
    if (np_id >= 0 and np_d2 <= meleeRangeSq(w, s)) return false;
    if (ai.path_blocked) return true;
    // Random chew while chase: only when rng already seeded and hits the gate.
    if (ai.wander_rng != 0 and (ai.wander_rng % w.rules.ai.destroy_area_rng_mod) == 1) return true;
    return false;
}

/// Same hold as BreakBlock: keep path_blocked and chase state so block damage runs.
fn destroyAreaUpdate(w: *World, s: Slot, ai: *c.ZombieAi, np: anytype, dt: f32) void {
    // Arm chew once; breakBlockUpdate owns path_blocked after replan (do not re-force).
    if (!ai.path_blocked) ai.path_blocked = true;
    breakBlockUpdate(w, s, ai, np, dt);
    // Path open: advance rng so random CanExecute gate is not sticky forever.
    if (!ai.path_blocked and ai.wander_rng != 0) ai.wander_rng +%= 1;
}

/// EAIRunawayWhenHurt::CanExecute (asm.il:435706): a revenge target is
/// required, and with the default lowHealthPercent of 1 (.ctor, asm.il:435622)
/// the health fraction gate is skipped entirely. EAIRunAway::CanExecute then
/// asks FindFleePos to produce somewhere to run; here that is always the cell
/// fleeDistance directly away from the attacker, so the gate reduces to "was
/// hurt recently". Only passive animals carry this task in stock XML
/// (entityclasses AITask-1 on the animal templates), so kind gates it.
/// EAIRunawayFromEntity fear scan: the nearest entity whose kind is in the
/// stock AITask-2 filter (`class=EntityPlayer,EntityZombie,EntityEnemyAnimal`,
/// entityclasses.xml, e.g. the animal templates at :4755) within fleeDistance.
/// Bounded to a 0.5 s cadence so the O(live) scan is not per-tick.
/// `pos` is the tick-start transform snapshot: the scanned slots belong to other
/// parallel AI workers, so their live transforms must not be read here.
fn refreshFearSource(w: *World, pos: *const [max_entities]c.Transform, s: Slot, ai: *c.ZombieAi, dt: f32) void {
    if (ai.fear_cd > 0) {
        ai.fear_cd -= dt;
        return;
    }
    ai.fear_cd = w.rules.ai.fear_scan_cd_s;
    const x = w.transform[s].x;
    const z = w.transform[s].z;
    var best: i32 = -1;
    // V3.2.0 danger radius (changelog-3.2.0 §4.4): a threat within this
    // distance becomes the fear source.
    const flee = w.rules.ai.timid_danger_distance;
    var best_d2: f32 = flee * flee;
    const kinds = [_]c.Kind{ .player, .zombie, .animal };
    for (kinds) |kind| {
        for (query.groupSlice(w, kind)) |t| {
            if (t == s) continue;
            if (!w.alive[t] or !w.mask[t].transform) continue;
            const dx = pos[t].x - x;
            const dz = pos[t].z - z;
            const d2 = dx * dx + dz * dz;
            if (d2 < best_d2) {
                best_d2 = d2;
                best = w.network_id[t].id;
            }
        }
    }
    ai.fear_target = best;
}

/// Combined gate: AITask-1 RunawayWhenHurt (fresh revenge target) or AITask-2
/// RunawayFromEntity (fresh fear source). Only passive animals carry either in
/// stock XML (the animal templates' AITask-1/2), so kind gates the task.
fn runawayCanExecute(w: *const World, s: Slot, ai: *const c.ZombieAi) bool {
    if (!w.mask[s].kind or w.kind[s] != .animal) return false;
    // Predators (wolf, bear, coyote, snake, boar) hunt; only passive wildlife
    // carries the flee tasks (stock animal templates' AITask-1/2).
    if (w.class_id[s].is_enemy) return false;
    if (ai.revenge_target >= 0 and ai.revenge_time > 0 and w.slotOfNetId(ai.revenge_target) != null) return true;
    return ai.fear_target >= 0 and w.slotOfNetId(ai.fear_target) != null;
}

/// EAIRunAway::Update: path to the flee position, dropping the task once the
/// source is further than fleeDistance. The stock stuck/retry bookkeeping
/// (pathTicks, checkedPath, FindRandomPos) has no zdtd equivalent.
/// `pos` is the tick-start transform snapshot: the flee source's slot is owned
/// by another parallel AI worker, so its live transform must not be read here
/// (same rule as refreshFearSource / applyRevengeTarget).
fn runawayUpdate(w: *World, pos: *const [max_entities]c.Transform, s: Slot, ai: *c.ZombieAi, cspd: f32, dt: f32) void {
    const ts = blk: {
        if (ai.revenge_target >= 0 and ai.revenge_time > 0) {
            if (w.slotOfNetId(ai.revenge_target)) |t| break :blk t;
        }
        if (ai.fear_target >= 0) {
            if (w.slotOfNetId(ai.fear_target)) |t| break :blk t;
        }
        break :blk null;
    } orelse {
        ai.revenge_time = 0;
        ai.fear_target = -1;
        ai.state = .idle;
        return;
    };
    ai.state = .wander;
    ai.alert = false;
    ai.target_id = -1;
    const dx = w.transform[s].x - pos[ts].x;
    const dz = w.transform[s].z - pos[ts].z;
    const d2 = dx * dx + dz * dz;
    // V3.2.0 safe radius (changelog-3.2.0 §4.4): the fright ends once the
    // source is beyond it.
    const flee = w.rules.ai.timid_safe_distance;
    if (d2 >= flee * flee) {
        // Out of range: the fright is over, release the mutex.
        ai.revenge_time = 0;
        ai.fear_target = -1;
        ai.clearPath();
        ai.has_path = false;
        return;
    }
    // Away from the attacker; a body exactly on top of it picks +x arbitrarily
    // rather than dividing by zero.
    const inv: f32 = if (d2 > 0.0001) 1.0 / @sqrt(d2) else 0;
    const fx = w.transform[s].x + (if (inv > 0) dx * inv else 1) * flee;
    const fz = w.transform[s].z + (if (inv > 0) dz * inv else 0) * flee;
    ai.path_goal_x = fx;
    ai.path_goal_z = fz;
    ai.has_path = true;
    chaseAlongPath(w, s, ai, fx, fz, cspd * ai.active_scale, dt);
}

/// EAITerritorial::CanExecute: has home and outside leash; yields to sensed player.
fn territorialCanExecute(w: *const World, s: Slot, ai: *const c.ZombieAi, np_id: i32, np_d2: f32, sense_d2: f32) bool {
    if (!ai.has_home) return false;
    // Sensed player: approach owns movement; do not leash mid-fight.
    if (np_id >= 0 and np_d2 < sense_d2) return false;
    if (!w.mask[s].transform) return false;
    const dx = w.transform[s].x - ai.home_x;
    const dz = w.transform[s].z - ai.home_z;
    const terr = w.rules.ai.territorial_radius;
    return dx * dx + dz * dz > terr * terr;
}

/// Walk back to home when outside the leash. Projects .wander (not chase) so
/// replication/despawn treat the zombie as non-aggro.
fn territorialUpdate(w: *World, s: Slot, ai: *c.ZombieAi, cspd: f32, dt: f32) void {
    if (!ai.has_home) {
        ai.state = .idle;
        return;
    }
    ai.alert = false;
    ai.target_id = -1;
    const dx = w.transform[s].x - ai.home_x;
    const dz = w.transform[s].z - ai.home_z;
    const sa = w.rules.ai.spot_arrive;
    if (dx * dx + dz * dz <= sa * sa) {
        ai.has_path = false;
        ai.clearPath();
        ai.path_blocked = false;
        ai.state = .idle;
        return;
    }
    ai.state = .wander;
    ai.path_goal_x = ai.home_x;
    ai.path_goal_z = ai.home_z;
    ai.has_path = true;
    chaseAlongPath(w, s, ai, ai.home_x, ai.home_z, cspd * ai.active_scale, dt);
}

/// EAIBase::Start hook. Wander picks a fresh destination and zeroes its run
/// timer (EAIWander::Start, asm.il:438289); Look latches the owed seconds and
/// stops the mover (EAILook::Start, asm.il:429903). Runs on every re-eval that
/// selects the task so a continuously-wandering zombie keeps drifting.
fn startTask(id: c.TaskId, w: *World, s: Slot, ai: *c.ZombieAi) void {
    switch (id) {
        .wander => {
            // Deterministic per-entity xorshift32 so streams differ per entity and
            // the direction varies each pass (a constant hash would drift one way).
            if (ai.wander_rng == 0) ai.wander_rng = rng_util.XorShift32.initFromNetId(w.network_id[s].id).state;
            const r = rng_util.xorshift32Step(ai.wander_rng);
            ai.wander_rng = r;
            const ox: f32 = @floatFromInt(@as(i32, @intCast(r % 17)) - 8);
            const oz: f32 = @floatFromInt(@as(i32, @intCast((r / 17) % 17)) - 8);
            ai.wander_tx = w.transform[s].x + ox;
            ai.wander_tz = w.transform[s].z + oz;
            ai.wander_time = 0;
        },
        .look => {
            ai.look_wait = ai.look_time;
            ai.look_time = 0;
            ai.look_turn_cd = 0;
            ai.look_yaw = w.transform[s].yaw;
            // moveHelper.Stop().
            ai.has_path = false;
            ai.clearPath();
            ai.path_blocked = false;
        },
        // EAIApproachDistraction::Start (asm.il:423700): SetAttackTarget(null),
        // IsEating=false, distraction = pendingDistraction, pendingDistraction
        // = null, then updatePath(). zdtd re-runs Start on every decision
        // re-eval, so the pending→distraction migration is guarded: a re-win
        // keeps the latch already in flight.
        .approach_distraction => {
            ai.target_id = -1;
            ai.alert = false;
            ai.is_eating = false;
            if (ai.pending_distraction >= 0) {
                ai.distraction = ai.pending_distraction;
                ai.pending_distraction = -1;
                ai.pending_distraction_dsq = 0;
            }
        },
        else => {},
    }
}

/// EAILook::Continue turn branch (asm.il:429975-430001): stand still and slew
/// body yaw toward a fresh +/-60 deg pick every 0.7 s, draining the owed time.
/// The lookAtTicks / SetLookPosition head-aim half is not ported: zdtd
/// replicates body yaw only (NetPackageEntityPosAndRot).
fn lookUpdate(w: *World, s: Slot, ai: *c.ZombieAi, dt: f32) void {
    ai.state = .idle;
    ai.alert = false;
    ai.target_id = -1;
    ai.look_wait -= dt;
    ai.look_turn_cd -= dt;
    if (ai.look_turn_cd <= 0) {
        ai.look_turn_cd = w.rules.ai.look_turn_interval_s;
        const f = rngFrac(ai, w.network_id[s].id);
        ai.look_yaw = w.transform[s].yaw + f * w.rules.ai.look_yaw_range_deg - w.rules.ai.look_yaw_range_deg * 0.5;
    }
    w.transform[s].yaw = seekYawStep(w.transform[s].yaw, ai.look_yaw, w.rules.ai.look_turn_speed_deg, w.rules.ai.look_yaw_slow_at_deg, w.rules.ai.look_turn_speed_min_deg, dt);
}

/// EAIApproachAndAttackTarget::Update: grid A* toward the sensed player when a
/// solid hook is set (else straight-line), melee on contact. Projects .attack
/// in range else .chase. Aggro persists with no fresh target (np.id<0).
fn approachUpdate(ctx: AiCtx, s: Slot, ai: *c.ZombieAi, np: anytype, cspd: f32, ct: anytype) void {
    ai.alert = true;
    if (np.id < 0) {
        // Director-seeded aggro / target briefly out of sense range: hold the
        // chase state (replication + despawn stay correct); no goal to path to.
        ai.state = .chase;
        return;
    }
    ai.target_id = np.id;
    ai.path_goal_x = np.px;
    ai.path_goal_z = np.pz;
    ai.has_path = true;
    if (np.d2 <= meleeRangeSq(ctx.w, s)) {
        ai.state = .attack;
        ai.clearPath();
        const pad: f32 = ctx.w.class_id[s].attack_damage;
        const adm: f32 = if (pad > 0) pad else if (ct.attack_damage > 0) ct.attack_damage else ctx.w.rules.combat.attack_damage;
        if (ai.attack_cd <= 0 and (targetExternal(np) or (ctx.w.alive[np.slot] and ctx.w.mask[np.slot].player))) {
            if (targetExternal(np)) {
                // Host-side bot victim (ADR 0026): melee resolves through the
                // bot damage hook so the bot records the zombie as attacker and
                // emits a damage event for the guest's retaliation/dodge.
                if (ctx.w.bot_damage_fn) |df| {
                    _ = df(ctx.w.bot_damage_ctx, np.id, ctx.w.network_id[s].id, adm);
                }
            } else {
                const add: u32 = @trunc(adm * @as(f32, @floatFromInt(dmg_scale)));
                _ = @atomicRmw(u32, &ctx.dmg_fp[np.slot], .Add, add, .monotonic);
            }
            _ = ctx.hits.fetchAdd(1, .monotonic);
            ai.attack_cd = ctx.w.rules.combat.attack_cooldown_s;
            ctx.w.flags[s].bits |= c.flag_approaching_enemy;
            // Combat noise (stock NotifyNoise): the landed hit alerts zombies
            // and wakes sleepers within radius (group-AI PARTIAL).
            ctx.w.pushNoise(ctx.w.transform[s].x, ctx.w.transform[s].y, ctx.w.transform[s].z, ctx.w.rules.ai.combat_noise_radius);
        }
    } else {
        ai.state = .chase;
        chaseAlongPath(ctx.w, s, ai, np.px, np.pz, cspd * ai.active_scale, ctx.dt);
    }
}

fn pathStepCb(ctx: ?*anyopaque, fx: i32, fz: i32, fy: i32, tx: i32, tz: i32) ?i32 {
    const w: *const World = @ptrCast(@alignCast(ctx.?));
    return w.stepTo(fx, fz, fy, tx, tz);
}

/// Feet cell the body actually stands in, before searching from it. A zombie
/// spawned or nudged off its footing would otherwise start the search from a
/// height with no support and conclude the whole world is sealed. The self-step
/// probe resolves it inside the same step/drop band the search uses; the ground
/// hook is the fallback for a body further off than one step.
fn footingY(w: *World, s: Slot, sx: i32, sz: i32) i32 {
    const cur: i32 = @floor(w.transform[s].y);
    if (w.stepTo(sx, sz, cur, sx, sz)) |y| return y;
    if (w.groundY(w.transform[s].x, w.transform[s].z)) |gy| return @floor(gy);
    return cur;
}

/// One A* solve, refilling the whole waypoint buffer. Sets path_blocked when
/// the solve could not reach the goal cell (sealed cover → BreakBlock).
fn replanPath(w: *World, s: Slot, ai: *c.ZombieAi, gxi: i32, gzi: i32) void {
    const sx: i32 = @floor(w.transform[s].x);
    const sz: i32 = @floor(w.transform[s].z);
    const sy = footingY(w, s, sx, sz);
    w.transform[s].y = @floatFromInt(sy);
    _ = w.path_replans.fetchAdd(1, .monotonic);
    var p: path_mod.Path = .{};
    _ = path_mod.aStarToward(&p, sx, sz, sy, gxi, gzi, w.rules.ai.path_max_expand, w, pathStepCb);
    // Greedy fallback may fill waypoints along a wall without reaching the goal.
    const reaches = p.len > 0 and p.points[p.len - 1].x == gxi and p.points[p.len - 1].z == gzi;
    ai.clearPath();
    var n: usize = 0;
    while (n < c.path_wp_max) {
        const wp = p.next() orelse break;
        ai.path_wp[n] = .{ .x = wp.x, .z = wp.z, .y = @intCast(std.math.clamp(wp.y, 0, 255)) };
        n += 1;
    }
    ai.path_wp_n = @intCast(n);
    ai.path_goal_cx = gxi;
    ai.path_goal_cz = gzi;
    // BreakBlock when no path to goal (sealed / infinite wall); clear when A* reaches.
    ai.path_blocked = !reaches and (gxi != sx or gzi != sz);
    ai.path_replan_cd = w.rules.ai.path_replan_interval_s;
}

/// Follow the buffered path, replanning only when it runs dry, the goal cell
/// moved, or a blocked path is due for a retry. When no step hook is wired,
/// degenerates to straight-line stepToward.
fn chaseAlongPath(w: *World, s: Slot, ai: *c.ZombieAi, gx: f32, gz: f32, speed: f32, dt: f32) void {
    if (w.step_fn == null) {
        ai.path_blocked = false;
        stepToward(w, s, gx, gz, speed, dt);
        return;
    }
    if (ai.path_replan_cd > 0) ai.path_replan_cd -= dt;
    const gxi: i32 = @floor(gx);
    const gzi: i32 = @floor(gz);
    // Reasons to solve again: the buffer is walked out, the goal left the cell
    // it was planned for, or the path is blocked and destroyed cover may have
    // opened a route. All of them wait for the throttle, including the spent
    // buffer: a body boxed in on all four sides gets an empty path every time,
    // and re-solving that on every tick is exactly what the budget exists to
    // prevent.
    const goal_drift = @abs(ai.path_goal_cx - gxi) + @abs(ai.path_goal_cz - gzi);
    const want = ai.currentWp() == null or goal_drift >= w.rules.ai.path_goal_slack or ai.path_blocked;
    if (want and ai.path_replan_cd <= 0) {
        // Over budget: keep walking the stored path instead of solving. Only a
        // body whose buffer is also spent falls back to the direct line, so the
        // budget degrades gracefully rather than snapping every chase straight.
        if (w.pathBudgetAdmits(s)) {
            replanPath(w, s, ai, gxi, gzi);
        } else {
            _ = w.path_replans_denied.fetchAdd(1, .monotonic);
        }
    }
    // Consume every waypoint already reached. With collision active the body
    // settles its own height (gravity + ground snap in stepToward), so the
    // waypoint feet height is only adopted on the hook-less grid where nothing
    // else tracks terrain. Offline paths keep following terrain up and down.
    while (ai.currentWp()) |wp| {
        const tx = @as(f32, @floatFromInt(wp.x)) + 0.5;
        const tz = @as(f32, @floatFromInt(wp.z)) + 0.5;
        const dx = tx - w.transform[s].x;
        const dz = tz - w.transform[s].z;
        const wp_arr = w.rules.ai.path_wp_arrive;
        if (dx * dx + dz * dz >= wp_arr * wp_arr) break;
        if (w.solid_fn == null) w.transform[s].y = @floatFromInt(wp.y);
        ai.path_wp_i += 1;
    }
    if (ai.currentWp()) |wp| {
        stepToward(w, s, @as(f32, @floatFromInt(wp.x)) + 0.5, @as(f32, @floatFromInt(wp.z)) + 0.5, speed, dt);
    } else {
        stepToward(w, s, gx, gz, speed, dt);
    }
}

/// EAIApproachSpot::Update: path/step toward director spot; clear has_spot on arrive.
fn approachSpotUpdate(w: *World, s: Slot, ai: *c.ZombieAi, cspd: f32, dt: f32) void {
    if (!ai.has_spot) {
        ai.state = .idle;
        return;
    }
    ai.state = .chase;
    ai.alert = true;
    ai.target_id = -1;
    ai.path_goal_x = ai.spot_x;
    ai.path_goal_z = ai.spot_z;
    ai.has_path = true;
    const dx = ai.spot_x - w.transform[s].x;
    const dz = ai.spot_z - w.transform[s].z;
    const sa2 = w.rules.ai.spot_arrive;
    if (dx * dx + dz * dz <= sa2 * sa2) {
        ai.has_spot = false;
        ai.has_path = false;
        ai.clearPath();
        ai.path_blocked = false;
        ai.state = .idle;
        return;
    }
    chaseAlongPath(w, s, ai, ai.spot_x, ai.spot_z, cspd * ai.active_scale, dt);
}

/// EAIApproachDistraction::Update (asm.il:423700): walk to the dropped item the
/// Start step latched as `distraction`, chew it within cCloseDist (1.5 m) when
/// it is an eat distraction (IsEating + distractionEatTicks--), and clear the
/// latch when a non-eat item is reached or the item disappears.
fn approachDistractionUpdate(w: *World, s: Slot, ai: *c.ZombieAi, cspd: f32, dt: f32) void {
    // `distraction` is a net id (same namespace as pending_distraction);
    // resolve it to a slot for the SoA reads.
    const bag_slot = if (ai.distraction >= 0) w.slotOfNetId(ai.distraction) else null;
    if (bag_slot == null or !w.alive[bag_slot.?] or !w.mask[bag_slot.?].loot_bag) {
        ai.distraction = -1;
        ai.is_eating = false;
        ai.state = .idle;
        return;
    }
    const bs = bag_slot.?;
    const dx = w.transform[bs].x - w.transform[s].x;
    const dz = w.transform[bs].z - w.transform[s].z;
    const d2 = dx * dx + dz * dz;
    if (d2 <= w.rules.ai.distraction_close_sq) {
        if ((w.loot_bag[bs].distraction_tags & 1) == 0) {
            // Non-eat item reached (stock decoy): the approach is done; the
            // zombie loses interest (CanExecute/Continue clear path, asm.il).
            ai.distraction = -1;
            ai.is_eating = false;
            ai.clearPath();
            ai.has_path = false;
            ai.path_blocked = false;
            ai.state = .idle;
            return;
        }
        // Eat distraction: chew one tick (EntityItem.distractionEatTicks--,
        // asm.il Update IL_00C4-00DE). The sim side consumes the item when the
        // counter hits zero (tickItemDistractions); Game removes the entity.
        // The bag slot is shared: two zombies on different parallel workers can
        // chew the same item in one tick, so the countdown is an atomic RMW.
        ai.is_eating = true;
        decrementIfPositive(&w.loot_bag[bs].distraction_eat_ticks);
        ai.state = .idle;
        return;
    }
    ai.is_eating = false;
    ai.state = .chase;
    ai.target_id = -1;
    ai.path_goal_x = w.transform[bs].x;
    ai.path_goal_z = w.transform[bs].z;
    ai.has_path = true;
    chaseAlongPath(w, s, ai, ai.path_goal_x, ai.path_goal_z, cspd * ai.active_scale, dt);
}

fn decrementIfPositive(value: *i32) void {
    var current = @atomicLoad(i32, value, .monotonic);
    while (current > 0) {
        current = @cmpxchgWeak(i32, value, current, current - 1, .monotonic, .monotonic) orelse return;
    }
}

/// EAIWander::Update: drift toward the Start-picked destination.
fn wanderUpdate(w: *World, s: Slot, ai: *c.ZombieAi, wspd: f32, dt: f32) void {
    ai.state = .wander;
    ai.alert = false;
    ai.target_id = -1;
    ai.has_path = false;
    ai.path_blocked = false;
    // EAIWander::Update (asm.il:438366): accumulate run time for the 30 s cap.
    ai.wander_time += dt;
    // Stock EAIWander paths to the spot on the navmesh; zdtd routes the same
    // A* chase machinery (replan + waypoint follow, step_fn-gated), so a
    // wanderer detours around obstacles instead of sliding straight into
    // them. Without a step hook chaseAlongPath degenerates to the direct line.
    chaseAlongPath(w, s, ai, ai.wander_tx, ai.wander_tz, wspd * ai.active_scale, dt);
}

/// EntityItem.tickDistraction (asm.il EntityItem:1341): dropped items carrying
/// DistractionTags broadcast themselves to nearby EntityAlive every 20 ticks
/// while distractionLifetime lasts, and eat items die once chewed up. zdtd
/// drops settle instantly, so the stock `!isCollided && requires_contact`
/// gate is a no-op here (documented simplification: no per-drop physics).
fn tickItemDistractions(w: *World) void {
    // This pass never spawns or destroys, so use the maintained dense group.
    // The common no-drop tick becomes O(1) instead of scanning every slot.
    for (query.groupSlice(w, .loot_bag)) |i| {
        if (!w.mask[i].loot_bag or !w.mask[i].transform) continue;
        const tags = w.loot_bag[i].distraction_tags;
        if (tags == 0) continue;
        var bag = &w.loot_bag[i];
        if (bag.distraction_lifetime <= 0) continue;
        // Eat items die once chewed up (EntityItem.OnUpdateEntity SetDead,
        // asm.il EntityItem:0100-0113); Game broadcasts EntityRemove on its
        // own sweep when distraction_eat_ticks hits 0, so the sim only drops
        // the slot there and keeps the latch consistent.
        bag.next_distraction_tick += 1;
        if (bag.next_distraction_tick <= w.rules.ai.distraction_broadcast_ticks) continue;
        bag.next_distraction_tick = 0;
        const bx = w.transform[i].x;
        const bz = w.transform[i].z;
        const r2 = bag.distraction_radius_sq;
        var j: Slot = 0;
        while (j < max_entities) : (j += 1) {
            if (!w.alive[j] or !w.mask[j].zombie_ai or !w.mask[j].transform) continue;
            if (w.mask[j].sleeper and !w.sleeper[j].awake) continue;
            // EntityAlive.distraction != null → already eating one (IL_00C0).
            if (w.zombie_ai[j].distraction >= 0) continue;
            // DistractionTags filter: tag 4 ("zombie") requires the target's
            // EntityClass tags to overlap (IL_00E5-010E).
            if ((tags & 4) != 0 and w.kind[j] != .zombie) continue;
            const dx = w.transform[j].x - bx;
            const dz = w.transform[j].z - bz;
            const d2 = dx * dx + dz * dz;
            if (d2 > r2) continue;
            // A closer pending item wins (IL_0124-013D).
            const ai = &w.zombie_ai[j];
            if (ai.pending_distraction >= 0) {
                if (w.slotOfNetId(ai.pending_distraction)) |_| {
                    if (d2 >= ai.pending_distraction_dsq) continue;
                } else {
                    // Stale latch (item collected/destroyed): drop it.
                    ai.pending_distraction = -1;
                    ai.pending_distraction_dsq = 0;
                }
            }
            // distractionResistance - strength gate (IL_013E-016B): zdtd has
            // no per-entity resistance state, so a non-positive strength (no
            // DistractionStrength effect) never registers. Decoy ships 100.
            if (bag.distraction_strength <= 0) continue;
            ai.pending_distraction = w.network_id[i].id;
            ai.pending_distraction_dsq = d2;
        }
        bag.distraction_lifetime -= 1;
    }
}

/// Player movement-noise model (RE entity-ai.md PlayerStealth): consumes the
/// stealth-noise ring pushed by the sound relay, folds each event into the
/// owning player's stealth state (stock PlayerStealth.NotifyNoise), then runs
/// the per-player noise decay/CalcVolume + attraction pass (stock TickServer).
/// Single-threaded (players are few); runs before the parallel AI pass so
/// zombies react to this tick's noise the same tick (stock entity update
/// order: players before enemies). Ring consume-owns-drain like combat noise.
pub fn systemStealth(w: *World) void {
    const take = @min(w.stealth_noise_n, c.stealth_events_cap);
    var i: usize = 0;
    while (i < take) : (i += 1) {
        const ev = w.stealth_noise_events[i];
        const s: Slot = @intCast(ev.slot);
        if (!w.alive[s] or !w.mask[s].player or !w.mask[s].transform) continue;
        stealthNotifyNoise(w, s, ev);
    }
    w.stealth_noise_n = 0;
    for (query.groupSlice(w, .player)) |s| {
        if (!w.alive[s] or !w.mask[s].player or !w.mask[s].transform) continue;
        stealthTick(w, s);
    }
}

/// Stock AIDirector.NotifyNoise (IL=84) + PlayerStealth.NotifyNoise (IL=71):
/// a relayed sound with a sounds.xml `<Noise>` row folds into the owning
/// player's stealth list, sleeper-noise volume (wake at the cap) and heat map.
fn stealthNotifyNoise(w: *World, s: Slot, ev: c.StealthNoiseEvent) void {
    const r = w.rules.ai;
    // The crouched instigator's volumeScale is muffled by the clip's
    // muffled_when_crouched (stock IL_0074-008A); the same scaled factor
    // rides the heat leg below (stock re-reads the overwritten arg).
    var scale: f32 = 1.0;
    if (w.player[s].crouching) scale = ev.muffled_when_crouched;
    const volume = ev.volume * scale;
    if (volume <= 0) return;
    const st = &w.stealth[s];
    // PlayerStealth.AddNoise: insert (volume, ticks) descending by volume.
    var idx: u8 = 0;
    while (idx < st.noise_n and st.noises[idx].volume >= volume) : (idx += 1) {}
    if (idx < c.stealth_noise_cap) {
        var j = @min(st.noise_n, c.stealth_noise_cap - 1);
        while (j > idx) : (j -= 1) st.noises[j] = st.noises[j - 1];
        st.noises[idx] = .{ .volume = volume, .ticks = ev.duration_ticks };
        if (st.noise_n < c.stealth_noise_cap) st.noise_n += 1;
    }
    // A loud noise (volume >= 11) pauses the sleeper-volume decay window.
    if (volume >= r.stealth_loud_volume) st.sleeper_noise_wait_ticks = r.stealth_loud_wait_ticks;
    // NotifyNoise curve: > 60 becomes 60 + (v-60)^1.4, then the Noise passive.
    var eff = volume;
    if (volume > 60) eff = 60 + std.math.pow(f32, volume - 60, 1.4);
    eff *= r.stealth_noise_passive;
    st.sleeper_noise_volume += eff;
    if (st.sleeper_noise_volume >= r.stealth_sleeper_wake_volume) {
        st.sleeper_noise_volume = r.stealth_sleeper_wake_volume;
        // Stock World.CheckSleeperVolumeNoise(pos): the Game wakes volumes
        // whose AABB contains the point (post-tick drain of this ring).
        w.pushSleeperVolumeNoise(ev.x, ev.y, ev.z);
    }
    // Heat map (stock AIDirector.NotifyActivity): heatMapStrength x the
    // (muffled) volumeScale, held for heat_map_time x 10 ticks.
    if (ev.heat_map_strength > 0) {
        w.director.notifyActivity(ev.x, ev.z, ev.heat_map_strength * scale, ev.heat_map_time * 10.0);
    }
}

/// Stock PlayerStealth.TickServer (IL=430): per-tick noise decay (NoiseCleanup
/// + CalcVolume), sleeper-volume decay, and the attraction pass — a zombie
/// hears when `noiseVolume x (1+feralSense) / (dist x 0.6 + 0.4) x
/// detectUsScale >= 1` inside the attraction radius.
fn stealthTick(w: *World, s: Slot) void {
    const r = w.rules.ai;
    const st = &w.stealth[s];
    // RE PlayerStealth.TickServer speedAverage (step 1): lerp toward the
    // per-tick horizontal speed (blocks/s) at 0.2 when moving, decay x0.5
    // when idle. Feeds the light fold `x (1 + speedAverage x 0.15)`.
    const sdx = w.transform[s].x - st.prev_x;
    const sdz = w.transform[s].z - st.prev_z;
    const speed = @sqrt(sdx * sdx + sdz * sdz) * @as(f32, @floatFromInt(protocol.ticks_per_second));
    st.prev_x = w.transform[s].x;
    st.prev_z = w.transform[s].z;
    st.speed_average = if (speed > 0.01)
        st.speed_average + (speed - st.speed_average) * 0.2
    else
        st.speed_average * 0.5;
    // NoiseCleanup: decrement ticks, drop expired entries.
    var i: u8 = 0;
    while (i < st.noise_n) {
        if (st.noises[i].ticks <= 1) {
            var j = i;
            while (j + 1 < st.noise_n) : (j += 1) st.noises[j] = st.noises[j + 1];
            st.noise_n -= 1;
        } else {
            st.noises[i].ticks -= 1;
            i += 1;
        }
    }
    // CalcVolume: geometric-decay sum (0.6^i), then (sum x 2.35)^0.86 x 1.5
    // x the Noise passive.
    var sum: f32 = 0;
    var wgt: f32 = 1;
    for (st.noises[0..st.noise_n]) |n| {
        sum += n.volume * wgt;
        wgt *= r.stealth_noise_decay;
    }
    const vol = std.math.pow(f32, sum * r.stealth_noise_curve_a, r.stealth_noise_curve_b) *
        r.stealth_noise_scale * r.stealth_noise_passive;
    st.noise_volume = vol;
    // Sleeper-volume decay: 2.5/tick once the loud-noise wait window elapses.
    if (st.sleeper_noise_wait_ticks > 0) {
        st.sleeper_noise_wait_ticks -= 1;
    } else if (st.sleeper_noise_volume > 0) {
        st.sleeper_noise_volume -= r.stealth_sleeper_volume_decay;
        if (st.sleeper_noise_volume < 0) st.sleeper_noise_volume = 0;
    }
    // Attraction (stock TickServer IL_01BF+): while the raw sum is non-zero,
    // scan the attraction radius around the player for hearing zombies.
    if (sum <= 0) return;
    const sense = r.stealth_attract_sense_scale;
    var radius = sum * r.stealth_noise_decay * (1 + sense * 1.6);
    radius = @min(radius, r.stealth_attract_radius_cap_a + r.stealth_attract_radius_cap_b * sense);
    if (radius <= 0) return;
    const px = w.transform[s].x;
    const pz = w.transform[s].z;
    const r2 = radius * radius;
    for (query.groupSlice(w, .zombie)) |zs| {
        if (!w.alive[zs] or !w.mask[zs].zombie_ai or !w.mask[zs].transform) continue;
        const dx = w.transform[zs].x - px;
        const dz = w.transform[zs].z - pz;
        const d2 = dx * dx + dz * dz;
        if (d2 > r2) continue;
        const dist = @sqrt(d2);
        // Stock heard test (TickServer IL_0254-02B4): noiseVolume x
        // (1 + feralSense) / (dist x 0.6 + 0.4) x detectUsScale >= 1.
        const heard = vol * (1 + r.stealth_hear_feral_sense) /
            (dist * 0.6 + 0.4) * r.stealth_hear_detect_us;
        if (heard < 1) continue;
        const ai = &w.zombie_ai[zs];
        if (w.mask[zs].sleeper and !w.sleeper[zs].awake) {
            // A sleeping zombie that hears wakes and investigates (stock
            // sleeper wake; the 360-cap volume wake is the separate
            // CheckSleeperVolumeNoise leg).
            w.sleeper[zs].awake = true;
            ai.state = .chase;
            ai.alert = true;
            w.pushSleeperWake(zs);
        }
        if (ai.state == .idle or ai.state == .wander) {
            ai.alert = true;
            ai.state = .chase;
            ai.target_id = -1;
            ai.spot_x = px;
            ai.spot_z = pz;
            ai.has_spot = true;
        }
    }
}

pub fn systemZombieAi(w: *World, dt: f32) u32 {
    // Zombie AI also drives animal wander (kind.animal reuses zombie_ai mask).
    if (w.countKind(.zombie) == 0 and w.countKind(.animal) == 0) return 0;
    // Dropped-item distraction broadcast runs before task selection so a
    // zombie can react to a fresh decoy on the same tick it lands.
    tickItemDistractions(w);
    var snaps: [64]PlayerSnap = undefined;
    const pn = snapshotPlayers(w, &snaps, true);
    var dmg_fp: [max_entities]u32 = .{0} ** max_entities;
    var hits_a: std.atomic.Value(u32) = .init(0);
    // Positions as of the phase start. Workers write only their own slots, so
    // any cross-slot position read has to come from this copy.
    const pos_snap: [max_entities]c.Transform = w.transform;
    const ctx = AiCtx{
        .w = w,
        .dt = dt,
        .players = snaps[0..pn],
        .pos = &pos_snap,
        .dmg_fp = dmg_fp[0..],
        .hits = &hits_a,
        .zombie_speed_scale = w.zombie_speed_scale,
    };
    // Slot count is the constant 512, so forRanges always pays the pool
    // broadcast/wait round-trip; skip it while the live population is small
    // enough that one worker's share would finish before the wakeup does.
    if (w.entity_count < 64) AiCtx.work(ctx, 0, max_entities) else parallel.forRanges(max_entities, ctx, AiCtx.work);
    consumeCombatNoise(w);
    _ = applyDeferredDamage(w, dmg_fp[0..]);
    return hits_a.load(.monotonic);
}

/// Group-AI consume pass (stock NotifyNoise, entity-ai.md): combat-noise
/// events alert zombies within radius (they investigate the spot) and wake
/// sleepers. Runs single-threaded after the parallel AI join; events were
/// pushed atomically during the pass (parallel workers + the net thread).
/// The ring is drained here - NOT beginTick - because direct system calls
/// (tests) and the net-poll-then-sim ordering both rely on consume-owns-drain.
fn consumeCombatNoise(w: *World) void {
    const take = @min(@min(w.noise_n, c.noise_events_cap), w.rules.ai.noise_events_per_tick);
    var i: usize = 0;
    while (i < take) : (i += 1) {
        const ev = w.noise_events[i];
        const r2 = ev.radius * ev.radius;
        for (query.groupSlice(w, .zombie)) |s| {
            if (!w.alive[s] or !w.mask[s].zombie_ai or !w.mask[s].transform) continue;
            const dx = w.transform[s].x - ev.x;
            const dz = w.transform[s].z - ev.z;
            if (dx * dx + dz * dz > r2) continue;
            const ai = &w.zombie_ai[s];
            if (w.mask[s].sleeper and !w.sleeper[s].awake) {
                // Wake and investigate the noise (stock sleeper wake).
                w.sleeper[s].awake = true;
                ai.state = .chase;
                ai.alert = true;
                ai.spot_x = ev.x;
                ai.spot_z = ev.z;
                ai.has_spot = true;
                // Stock wakes broadcast NetPackageSleeperWakeup (the Game
                // drains the ring in step).
                w.pushSleeperWake(s);
                continue;
            }
            if (ai.state == .idle or ai.state == .wander) {
                ai.alert = true;
                ai.state = .chase;
                ai.target_id = -1;
                ai.spot_x = ev.x;
                ai.spot_z = ev.z;
                ai.has_spot = true;
            }
        }
    }
    // Drain (budget-excess events are dropped, never re-alerted next tick).
    w.noise_n = 0;
}

pub fn systemDirector(w: *World, dt: f32) struct { spawned: u32, world_time: u64 } {
    const r = w.director.tick(w, dt);
    return .{ .spawned = r.spawned, .world_time = r.world_time };
}

/// Stability-collapse groups (RE entity-ai.md EntityFallingBlock landing):
/// the group falls under the stock gravity integrator and dies on ground
/// contact - cells are never re-placed (the collapse already aired them).
/// The land probe reuses the solid_fn hook (same chunk reads as the AI LOS).
///
/// Crush damage (RE entity-ai.md EntityFallingBlock.OnUpdateEntity IL=344):
/// every other tick, entities inside the block's bounds take
/// FastMin(massKg * |vy| * 0.05, 40) reduced by the target's armor
/// mitigation (passive 164 analog), up to 3 hits per entity.
pub fn systemFallingBlocks(w: *World, dt: f32) void {
    const solid_fn = w.solid_fn orelse return;
    const g = w.rules.ai.gravity;
    // Stock getHeadPosition() offsets (entityclasses heights are not parsed;
    // the skip gate is "faller center below the target's head").
    const head_y = [_]f32{ 1.7, 1.8, 1.0 };
    const kinds = [_]c.Kind{ .player, .zombie, .animal };
    for (query.groupSlice(w, .falling_block)) |s| {
        if (!w.alive[s] or !w.mask[s].falling or !w.mask[s].transform) continue;
        const f = &w.falling[s];
        f.tick +%= 1;
        // Crush pass every other tick while falling fast enough
        // (stock skips when vel.y >= -0.8).
        if (f.mass_kg > 0 and f.vy < -0.8 and (f.tick & 1) == 0) {
            var minx: i32 = std.math.maxInt(i32);
            var maxx: i32 = std.math.minInt(i32);
            var miny: i32 = std.math.maxInt(i32);
            var maxy: i32 = std.math.minInt(i32);
            var minz: i32 = std.math.maxInt(i32);
            var maxz: i32 = std.math.minInt(i32);
            for (f.cells[0..f.n]) |cell| {
                minx = @min(minx, cell.x);
                maxx = @max(maxx, cell.x);
                miny = @min(miny, cell.y);
                maxy = @max(maxy, cell.y);
                minz = @min(minz, cell.z);
                maxz = @max(maxz, cell.z);
            }
            const faller_y = w.transform[s].y;
            const b_bot: f32 = @as(f32, @floatFromInt(miny)) - 0.5;
            const b_top: f32 = @as(f32, @floatFromInt(maxy)) + 0.2;
            // Bounds mirror stock ExpandBounds(box, 0, 0.2, 0) around the
            // carried cells; the victim's box [feet, head] must overlap.
            for (kinds, head_y) |kind, hh| {
                for (w.kind_groups.slice(kind)) |t| {
                    if (!w.alive[t] or !w.mask[t].transform or !w.mask[t].network_id) continue;
                    const tp = w.transform[t];
                    const vx = tp.x;
                    const vy = tp.y;
                    const vz = tp.z;
                    if (vx < @as(f32, @floatFromInt(minx)) - 0.5 or vx > @as(f32, @floatFromInt(maxx)) + 0.5) continue;
                    if (vz < @as(f32, @floatFromInt(minz)) - 0.5 or vz > @as(f32, @floatFromInt(maxz)) + 0.5) continue;
                    if (vy + hh < b_bot or vy > b_top) continue;
                    // Skip when the faller has sunk below the target's head.
                    if (faller_y < vy + hh) continue;
                    const nid = w.network_id[t].id;
                    if (hitCount(f, nid) >= c.falling_hit_cap) continue;
                    // FastMin(massKg * |vy| * 0.05, 40), int-truncated like
                    // the stock conv.i4; players reduce it by armor
                    // mitigation (passive 164 is the armor reduction path).
                    const raw: f32 = @min(f.mass_kg * -f.vy * 0.05, 40.0);
                    var dmg: f32 = @floatFromInt(@as(i32, @intFromFloat(raw)));
                    if (kind == .player) {
                        const mit = inventory.armorMitigation(w, @intCast(w.player[t].peer_slot));
                        dmg *= 1.0 - mit;
                    }
                    if (dmg <= 0) continue;
                    const dr = w.damageFrom(nid, dmg, -1);
                    _ = dr;
                    recordHit(f, nid);
                }
            }
        }
        // Lowest cell decides contact: when the cell directly below any cell
        // is solid, the group has landed.
        var landed = false;
        for (f.cells[0..f.n]) |cell| {
            if (solid_fn(w.solid_ctx, cell.x, cell.y - 1, cell.z)) {
                landed = true;
                break;
            }
        }
        if (landed) {
            // Fall-event debris drops (RE EntityFallingBlock landing
            // DropItemsOnEvent IL): the Game rolls each carried cell's
            // `<drop event="Fall">` rows at the landing position before the
            // entity is destroyed.
            if (w.fall_land_fn) |hook| hook(w.fall_land_ctx, f.cells[0..f.n]);
            w.destroy(s);
            continue;
        }
        f.vy = (f.vy + g * dt) * 0.98;
        if (f.vy < w.rules.ai.fall_max_vy) f.vy = w.rules.ai.fall_max_vy;
        const t = &w.transform[s];
        const dy: f32 = f.vy * dt;
        t.y += dy;
        t.x += f.vx * dt;
        t.z += f.vz * dt;
        // The carried cells ride the entity: keep them in sync so the next
        // tick's land probe reads the updated heights. A singular block's
        // cell is the floor of its transform (the spawn dy0 offset must not
        // leak into the fall pace); a group's cells each move by the entity
        // delta from their own positions.
        if (f.n == 1) {
            f.cells[0].x = @floor(t.x);
            f.cells[0].y = @floor(t.y);
            f.cells[0].z = @floor(t.z);
        } else {
            for (f.cells[0..f.n]) |*cell| {
                cell.x = @floor(@as(f32, @floatFromInt(cell.x)) + f.vx * dt);
                cell.z = @floor(@as(f32, @floatFromInt(cell.z)) + f.vz * dt);
                cell.y = @floor(@as(f32, @floatFromInt(cell.y)) + dy);
            }
        }
    }
}

/// Stock entityHits lookup (capped at falling_hit_cap per entity).
fn hitCount(f: *const c.FallingBlocks, nid: i32) u8 {
    var i: usize = 0;
    while (i < f.hit_n) : (i += 1) {
        if (f.hit_ids[i] == nid) return f.hit_counts[i];
    }
    return 0;
}

/// Record a crush hit; evict the oldest entry when the fixed table is full.
fn recordHit(f: *c.FallingBlocks, nid: i32) void {
    var i: usize = 0;
    while (i < f.hit_n) : (i += 1) {
        if (f.hit_ids[i] == nid) {
            f.hit_counts[i] +%= 1;
            return;
        }
    }
    if (f.hit_n < c.falling_hits_tracked) {
        f.hit_ids[f.hit_n] = nid;
        f.hit_counts[f.hit_n] = 1;
        f.hit_n += 1;
    } else {
        // Table full: drop the oldest so a new victim can still be counted.
        std.mem.copyForwards(i32, f.hit_ids[0 .. f.hit_n - 1], f.hit_ids[1..f.hit_n]);
        std.mem.copyForwards(u8, f.hit_counts[0 .. f.hit_n - 1], f.hit_counts[1..f.hit_n]);
        f.hit_ids[f.hit_n - 1] = nid;
        f.hit_counts[f.hit_n - 1] = 1;
    }
}

pub fn systemVehicles(w: *World, dt: f32) void {
    // Vehicle physics does not change entity membership, so the dense group
    // avoids a full-capacity scan on every tick, especially for parked fleets.
    for (query.groupSlice(w, .vehicle)) |i| {
        if (!w.mask[i].vehicle or !w.mask[i].transform) continue;
        var v = &w.vehicle[i];

        // Vertical physics: gravity accumulator + terrain-top clamp. Runs for
        // every vehicle (parked included). Skipped when no terrain hook is set.
        // rules.vehicle.gravity (RE EntityVehicle::cGravity, asm.il:536018;
        // distinct from World::Gravity 0.08) is the config surface (ADR 0021).
        const t = &w.transform[i];
        if (w.groundY(t.x, t.z)) |gy| {
            if (t.y > gy) {
                v.vy += w.rules.vehicle.gravity * dt;
                t.y += v.vy * dt;
                if (t.y <= gy) { // landed / no-fly
                    t.y = gy;
                    v.vy = 0;
                }
            } else { // no-sink: snap up to surface, kill downward velocity
                t.y = gy;
                if (v.vy < 0) v.vy = 0;
            }
        }

        // Every occupied seat rides the hull. The client parents the rider to
        // the seat transform itself (EntityVehicle::GetAttachedToInfo,
        // asm.il:542503), so the server only owns the hull-relative position.
        for (&v.seats, 0..) |*rider, s| {
            if (rider.* < 0) continue;
            const pi = w.slotOfNetId(rider.*) orelse {
                // The rider entity is gone (death, despawn): free the seat, or
                // the hull stays occupied and, for seat 0, undriveable forever.
                rider.* = -1;
                if (s == c.driver_seat) vehicleStop(v);
                continue;
            };
            if (!w.mask[pi].transform) continue;
            w.transform[pi].x = w.transform[i].x;
            w.transform[pi].y = w.transform[i].y + 1;
            w.transform[pi].z = w.transform[i].z;
            w.transform[pi].yaw = w.transform[i].yaw;
        }
    }
}

/// Kind defaults when vehicles.xml velocityMax missing (A12: XML first, then this).
pub fn vehicleKindDefaultSpeed(kind: c.VehicleKind) f32 {
    return switch (kind) {
        .bicycle => 6,
        .minibike => 12,
        .motorcycle => 18,
        .four_by_four => 14,
        .gyrocopter => 20,
    };
}

pub fn vehicleControl(w: *World, slot: Slot, throttle: f32, steer: f32, dt: f32) void {
    if (!w.alive[slot] or !w.mask[slot].vehicle or !w.mask[slot].transform) return;
    if (w.vehicle[slot].driverNetId() < 0) return;
    var v = &w.vehicle[slot];
    v.throttle = throttle;
    v.steer = steer;
    const max_spd: f32 = if (v.max_speed > 0.1) v.max_speed else vehicleKindDefaultSpeed(v.kind);
    const vr = &w.rules.vehicle;
    // Stronger accel so a short C2S drive pulse still moves (playtest >=0.4 m).
    v.speed += throttle * vr.accel_mps2 * dt;
    if (v.speed > max_spd) v.speed = max_spd;
    if (v.speed < -max_spd * vr.reverse_frac) v.speed = -max_spd * vr.reverse_frac;
    // Coast decay only when no throttle input.
    if (@abs(throttle) < 0.05) v.speed *= 1.0 - vr.coast_decay * dt;
    const spd_frac = if (max_spd > 0.01) @abs(v.speed) / max_spd else 0;
    w.transform[slot].yaw += steer * vr.steer_deg_per_s * dt * @max(spd_frac, vr.min_turn_speed_frac);
    const rad = w.transform[slot].yaw * (std.math.pi / 180.0);
    w.transform[slot].x += @sin(rad) * v.speed * dt;
    w.transform[slot].z += @cos(rad) * v.speed * dt;
    if (v.kind != .bicycle) {
        if (v.fuel <= 0) {
            v.speed = 0;
            return;
        }
        v.fuel -= @abs(v.speed) * vr.fuel_per_m * dt;
        if (v.fuel < 0) v.fuel = 0;
    }
}

/// Apply held throttle/steer every sim tick (stock client may send sparse drive pkgs).
pub fn vehicleTickHeld(w: *World, dt: f32) void {
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        if (!w.alive[i] or !w.mask[i].vehicle) continue;
        if (w.vehicle[i].driverNetId() < 0) continue;
        const v = w.vehicle[i];
        // Re-apply held input; zero throttle still coasts via vehicleControl.
        vehicleControl(w, i, v.throttle, v.steer, dt);
    }
}

/// Wire sentinel for "any free seat": the stock client always mounts with -1
/// (EntityVehicle::EnterVehicle → StartAttachToEntity(this, -1), asm.il:541872).
pub const seat_any: i16 = -1;

/// Seat this rider already holds on this vehicle, mirroring
/// Entity::FindAttachSlot (asm.il:406478).
pub fn vehicleFindSeat(w: *const World, vslot: Slot, player_net: i32) ?u8 {
    if (player_net < 0) return null; // -1 marks a free seat, never a rider
    if (!w.alive[vslot] or !w.mask[vslot].vehicle) return null;
    for (w.vehicle[vslot].seats, 0..) |rider, s| {
        if (rider == player_net) return @intCast(s);
    }
    return null;
}

/// Vehicle slot this rider occupies, whichever vehicle that is.
pub fn vehicleOfRider(w: *const World, player_net: i32) ?Slot {
    if (player_net < 0) return null;
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        if (!w.alive[i] or !w.mask[i].vehicle) continue;
        for (w.vehicle[i].seats) |rider| {
            if (rider == player_net) return i;
        }
    }
    return null;
}

/// Seat a rider, returning the resolved seat index, mirroring
/// Entity::AttachEntityToSelf (asm.il:406554): a negative request takes the
/// first free seat, re-requesting the held seat (or -1 while held) is a no-op,
/// and an out-of-range request fails. Unlike stock, an explicit request for an
/// occupied seat is refused instead of evicting the sitting rider: the request
/// comes off the wire and must not be able to unseat someone else.
pub fn vehicleAttach(w: *World, vslot: Slot, player_net: i32, requested: i16) ?u8 {
    if (player_net < 0) return null;
    if (!w.alive[vslot] or !w.mask[vslot].vehicle) return null;
    const n: i16 = w.vehicle[vslot].usableSeats();
    if (requested >= n) return null;

    const held = vehicleFindSeat(w, vslot, player_net);
    if (held) |h| {
        if (requested < 0 or requested == h) return h;
    } else {
        // Fresh mount: proximity gate, and vacate any other vehicle first so a
        // rider can never occupy two hulls at once.
        const ps = w.slotOfNetId(player_net) orelse return null;
        if (!w.mask[ps].transform or !w.mask[vslot].transform) return null;
        const dx = w.transform[ps].x - w.transform[vslot].x;
        const dz = w.transform[ps].z - w.transform[vslot].z;
        if (dx * dx + dz * dz > w.rules.ai.mount_range_sq) return null;
        _ = vehicleDetach(w, player_net);
    }

    const v = &w.vehicle[vslot];
    const seat: u8 = if (requested >= 0) @intCast(requested) else blk: {
        for (v.seats[0..v.usableSeats()], 0..) |rider, s| {
            if (rider < 0) break :blk @intCast(s);
        }
        return null; // full: FindAttachSlot(null) == -1
    };
    if (v.seats[seat] >= 0) return null;
    if (held) |h| { // seat change on the same vehicle
        v.seats[h] = -1;
        if (h == c.driver_seat) vehicleStop(v);
    }
    v.seats[seat] = player_net;
    return seat;
}

pub const Dismount = struct {
    vehicle_net: i32,
    seat: u8,
};

/// Unseat a rider from whatever vehicle holds it. The stock detach package
/// carries vehicleId = -1 (Entity::SendDetach, asm.il:406816), so the server
/// must resolve the hull from its own occupancy state.
pub fn vehicleDetach(w: *World, player_net: i32) ?Dismount {
    const vslot = vehicleOfRider(w, player_net) orelse return null;
    const seat = vehicleFindSeat(w, vslot, player_net).?;
    const v = &w.vehicle[vslot];
    v.seats[seat] = -1;
    // Only losing the driver stops the hull; passengers leaving change nothing.
    if (seat == c.driver_seat) vehicleStop(v);
    return .{ .vehicle_net = w.network_id[vslot].id, .seat = seat };
}

fn vehicleStop(v: *c.Vehicle) void {
    v.speed = 0;
    v.throttle = 0;
    v.steer = 0;
}

const TurretCtx = struct {
    w: *World,
    dt: f32,
    dmg_fp: []u32,
    /// Alive zombie slots with transform, snapshotted once per tick so each
    /// turret does not rescan all entity slots.
    zombies: []const Slot,
    /// Per-slot powered flags, resolved once per tick from the power grid so
    /// each turret skips the O(node_n) isEntityPowered scan.
    powered: *const [max_entities]bool,
    /// Deterministic last-hit token per zombie (parallel to dmg_fp). The high
    /// half is turret slot + 1 and the low half is its owner client slot.
    owner_hit: []u32,

    fn work(ctx: TurretCtx, begin: usize, end: usize) void {
        var i: usize = begin;
        while (i < end) : (i += 1) {
            const s: Slot = @intCast(i);
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
            for (ctx.zombies) |j| {
                const dx = ctx.w.transform[j].x - tx;
                const dz = ctx.w.transform[j].z - tz;
                const d = dx * dx + dz * dz;
                if (d < best_d) {
                    best_d = d;
                    best_id = ctx.w.network_id[j].id;
                    best_slot = j;
                }
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
                recordTurretOwner(&ctx.owner_hit[zi], s, t.owner_slot);
            }
        }
    }
};

fn recordTurretOwner(value: *u32, turret_slot: Slot, owner_slot: i16) void {
    // Parallel execution has no meaningful wall-clock "last" worker. Match
    // the serial ascending-slot pass instead: the highest firing turret slot
    // wins, with owner packed into the same atomic value so it cannot tear
    // away from the winning source.
    const token = (@as(u32, turret_slot) + 1) << 16 | @as(u16, @bitCast(owner_slot));
    _ = @atomicRmw(u32, value, .Max, token, .monotonic);
}

fn turretOwner(value: u32) i16 {
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
    const ctx = TurretCtx{ .w = w, .dt = dt, .dmg_fp = dmg_fp[0..], .zombies = zombie_slots[0..zn], .powered = &powered, .owner_hit = owner_hit[0..] };
    // Same small-population gate as systemZombieAi: pool sync costs more than
    // a serial sweep of 512 slots when few entities are alive.
    if (w.entity_count < 64) TurretCtx.work(ctx, 0, max_entities) else parallel.forRanges(max_entities, ctx, TurretCtx.work);
    var out: TurretTick = .{};
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        const fp = dmg_fp[i];
        if (fp == 0) continue;
        if (!w.alive[i] or !w.mask[i].health) continue;
        if (w.kind[i] != .zombie) continue;
        const amount = fpDamage(fp);
        // Report lists full: stop before a kill nobody would be told about
        // (destroy without EntityRemove leaves a permanent client ghost).
        // Remaining damage re-accumulates next tick, like systemDespawnFar.
        const would_kill = w.health[i].hp - amount <= 0;
        if (would_kill and (out.killed_n >= out.killed_ids.len or out.loot_n >= out.loot_bag_ids.len)) break;
        w.health[i].hp -= amount;
        if (w.health[i].hp <= 0) {
            const x = if (w.mask[i].transform) w.transform[i].x else 0;
            const y = if (w.mask[i].transform) w.transform[i].y else 0;
            const z = if (w.mask[i].transform) w.transform[i].z else 0;
            const zid: i32 = if (w.mask[i].network_id) w.network_id[i].id else -1;
            // Same drop_prob roll as player kills (class_id LootDropProb);
            // read before the corpse marking, which keeps the slot.
            const drop_prob = if (w.mask[i].class_id) w.class_id[i].drop_prob else 1.0;
            // Corpse dwell like player kills: the body stays at hp 0 for
            // TimeStayAfterDeath; the tick sweep destroys it later. Fallback
            // is the stock EntityAlive default 5 s (RE entity-ai.md); the XML
            // values 30/300 flow via class_id.time_stay when declared.
            const dwell: f32 = if (w.mask[i].class_id and w.class_id[i].time_stay > 0)
                w.class_id[i].time_stay
            else
                5.0;
            w.health[i].hp = 0;
            w.health[i].corpse_seconds = dwell;
            if (w.mask[i].zombie_ai) {
                w.zombie_ai[i].state = .idle;
                w.zombie_ai[i].target_id = -1;
                w.zombie_ai[i].alert = false;
            }
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

/// Remove idle/wandering zombies far from every player. Returns removed ids
/// (caller broadcasts EntityRemove with Despawned reason).
pub fn systemDespawnFar(w: *World, out_ids: []i32) u8 {
    const despawn_dist_sq = w.rules.ai.despawn_dist_sq;
    if (w.countKind(.zombie) == 0 and w.countKind(.animal) == 0) return 0;
    var snaps: [64]PlayerSnap = undefined;
    const pn = snapshotPlayers(w, &snaps, false);
    var n: u8 = 0;
    // This loop destroys, so it walks snapshots of the mob kind groups rather
    // than the live groups (same ascending order, so the capped out_ids picks
    // the same ids as the old open scan). Animals despawn like zombies: stock
    // despawns far entities regardless of kind, otherwise wildlife accumulates
    // to MaxSpawnedAnimals and holds slots + known_entities bits forever.
    var slots: [max_entities]Slot = undefined;
    const mob_kinds = [_]c.Kind{ .zombie, .animal };
    for (mob_kinds) |k| {
        const kn = query.copyKindInto(w, k, &slots);
        for (slots[0..kn]) |i| {
            if (n >= out_ids.len) break;
            if (!w.alive[i] or !w.mask[i].transform) continue;
            // Sleepers stay (POI volumes re-trigger on approach otherwise).
            if (w.mask[i].sleeper) continue;
            if (w.mask[i].zombie_ai and w.zombie_ai[i].alert) continue;
            var near = false;
            for (snaps[0..pn]) |p| {
                const dx = p.x - w.transform[i].x;
                const dz = p.z - w.transform[i].z;
                if (dx * dx + dz * dz < despawn_dist_sq) {
                    near = true;
                    break;
                }
            }
            if (near) continue;
            if (w.mask[i].network_id) {
                out_ids[n] = w.network_id[i].id;
                n += 1;
            }
            w.destroy(i);
        }
    }
    return n;
}

/// Tick every buff set in the world. Stock ticks buffs on every entity the
/// client simulates (EntityAlive::OnUpdateEntity, asm.il 445737), so the server
/// must run the same rule on every entity it owns or the two drift.
/// Returns the number of removals written into `out` (saturating).
pub fn systemBuffs(w: *World, out: []buff.Expiry) u8 {
    var n: u8 = 0;
    var removed: [c.max_buffs_per_entity]buff.Removed = undefined;
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        if (!w.alive[i] or !w.mask[i].buffs) continue;
        // Entity::bDead skips the started/duration half of the tick (asm.il 735832).
        const dead = w.mask[i].health and w.health[i].hp <= 0;
        const rn = buff.tick(&w.buffs[i], dead, &removed);
        var r: u8 = 0;
        while (r < rn and n < out.len) : (r += 1) {
            out[n] = .{ .entity_id = w.network_id[i].id, .def_id = removed[r].def_id };
            n += 1;
        }
    }
    return n;
}

/// Thin wrapper over schedule.run (explicit phases). Prefer schedule for new code.
pub fn tickAll(w: *World, dt: f32) @import("schedule.zig").TickResult {
    return @import("schedule.zig").run(w, dt);
}

fn testGround(_: ?*anyopaque, _: i32, _: i32) f32 {
    return 65;
}

test "vehicle falls under gravity and settles on terrain" {
    var w: World = .{};
    defer w.deinit();
    w.ground_fn = &testGround;
    const id = w.spawnVehicle(.minibike, 0, 100, 0).?;
    const s = w.slotOfNetId(id).?;
    var t: f32 = 0;
    while (t < 20.0) : (t += 0.05) {
        systemVehicles(&w, 0.05);
        try std.testing.expect(w.transform[s].y >= 65); // never sinks past ground
    }
    try std.testing.expectApproxEqAbs(@as(f32, 65), w.transform[s].y, 0.001);
    try std.testing.expectEqual(@as(f32, 0), w.vehicle[s].vy);
}

test "vehicle below ground pops up in one tick, no-sink" {
    var w: World = .{};
    defer w.deinit();
    w.ground_fn = &testGround;
    const id = w.spawnVehicle(.four_by_four, 0, 40, 0).?;
    const s = w.slotOfNetId(id).?;
    systemVehicles(&w, 0.05);
    try std.testing.expectEqual(@as(f32, 65), w.transform[s].y);
    try std.testing.expect(w.vehicle[s].vy >= 0);
}

test "vehicle physics skipped without ground hook (headless invariant)" {
    var w: World = .{};
    defer w.deinit();
    const id = w.spawnVehicle(.bicycle, 0, 100, 0).?;
    const s = w.slotOfNetId(id).?;
    systemVehicles(&w, 0.05);
    try std.testing.expectEqual(@as(f32, 100), w.transform[s].y);
}

test "driver seat tracks clamped vehicle y+1" {
    var w: World = .{};
    defer w.deinit();
    w.ground_fn = &testGround;
    const vid = w.spawnVehicle(.motorcycle, 0, 100, 0).?;
    const vs = w.slotOfNetId(vid).?;
    const pid = w.spawnPlayer(0, 100, 0, 0).?;
    const ps = w.slotOfNetId(pid).?;
    try std.testing.expectEqual(@as(?u8, 0), vehicleAttach(&w, vs, pid, seat_any));
    var t: f32 = 0;
    while (t < 20.0) : (t += 0.05) {
        systemVehicles(&w, 0.05);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 65), w.transform[vs].y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 66), w.transform[ps].y, 0.001);
}

test "isBestTask: approach preempts wander, wander cannot preempt approach" {
    const brk = taskById(.break_block).?;
    const approach = taskById(.approach_attack).?;
    const spot = taskById(.approach_spot).?;
    const wander = taskById(.wander).?;
    const territorial = taskById(.territorial).?;
    // Approach (priority 1, mutex 0b11) is best while Wander (continuous,
    // priority 2) executes: higher-priority continuous never blocks.
    try std.testing.expect(isBestTask(approach, .wander));
    try std.testing.expect(isBestTask(approach, .approach_spot));
    try std.testing.expect(isBestTask(approach, .territorial));
    // Wander is NOT best while Approach executes: priority 1 <= 2 and
    // MutexBits overlap (0b11 & 0b01 == 0b01 != 0) makes them incompatible.
    try std.testing.expect(!isBestTask(wander, .approach_attack));
    try std.testing.expect(!isBestTask(spot, .approach_attack));
    try std.testing.expect(!isBestTask(territorial, .approach_attack));
    // BreakBlock / DestroyArea mutex 0 is compatible with approach (overlap == 0).
    const destroy = taskById(.destroy_area).?;
    try std.testing.expect(isBestTask(brk, .approach_attack));
    try std.testing.expect(isBestTask(destroy, .approach_attack));
    try std.testing.expect(isBestTask(approach, .break_block));
    try std.testing.expect(isBestTask(approach, .destroy_area));
    // No executing task, or self as the executor, is always best.
    try std.testing.expect(isBestTask(approach, .none));
    try std.testing.expect(isBestTask(wander, .none));
    try std.testing.expect(isBestTask(wander, .wander));
    try std.testing.expect(isBestTask(spot, .approach_spot));
    try std.testing.expect(isBestTask(territorial, .territorial));
    // Look (priority 2, mutex 0b01, continuous) sits with the movement group:
    // Approach preempts it (higher-priority continuous yields), it cannot
    // preempt Approach, and it is incompatible with Wander/Spot both ways.
    const look = taskById(.look).?;
    try std.testing.expect(isBestTask(approach, .look));
    try std.testing.expect(!isBestTask(look, .approach_attack));
    try std.testing.expect(!isBestTask(wander, .look));
    try std.testing.expect(!isBestTask(look, .wander));
    try std.testing.expect(!isBestTask(look, .approach_spot));
    try std.testing.expect(isBestTask(look, .none));
    try std.testing.expect(isBestTask(look, .look));
}

test "seekYawStep: wrap, per-tick clamp, slowdown floor, exact snap" {
    // Far from target: full MaxTurnSpeed, clamped to speed*dt per tick.
    const a = seekYawStep(0, 180, 250, 35, 20.0, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), a, 0.001);
    // Shortest arc across the 0/360 seam: 350 -> 60 turns +70, not -290, and
    // the 12.5 deg step wraps the result back into [0,360).
    const b = seekYawStep(350, 60, 250, 35, 20.0, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), b, 0.001);
    // And the other way: 10 -> 300 turns -70, wrapping below zero.
    const cc = seekYawStep(10, 300, 250, 35, 20.0, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 357.5), cc, 0.001);
    // Negative input yaw (stepToward writes atan2 in [-180,180]) normalizes.
    try std.testing.expectApproxEqAbs(@as(f32, 350.0), seekYawStep(-10, -10, 250, 35, 20.0, 0.05), 0.001);
    // Inside slow_at the speed is max_turn*(d/slow_at)^2: d=17.5 -> 250*0.25=62.5.
    const d = seekYawStep(0, 17.5, 250, 35, 20.0, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 3.125), d, 0.001);
    // Deep inside slow_at the 20 deg/s floor takes over: d=1 -> 250*(1/35)^2
    // = 0.204 < 20, so speed 20 and a 0.05 s step of 1.0 exactly reaches it.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), seekYawStep(0, 1, 250, 35, 20.0, 0.05), 0.001);
    // Never overshoot: a step larger than the remaining delta snaps exactly.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), seekYawStep(0, 0.5, 250, 35, 20.0, 1.0), 0.001);
    // Zero delta is a no-op, not an oscillation.
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), seekYawStep(90, 90, 250, 35, 20.0, 0.05), 0.001);
}

test "system zombie looks around after reaching its wander destination" {
    var w: World = .{};
    defer w.deinit();
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(c.TaskId.wander, w.zombie_ai[zs].active_task);
    // Snap the destination onto the entity: stock's noPathAndNotPlanningOne
    // (path finished) branch of EAIWander::Continue.
    w.zombie_ai[zs].wander_tx = w.transform[zs].x;
    w.zombie_ai[zs].wander_tz = w.transform[zs].z;
    _ = systemZombieAi(&w, 0.05);
    // Continue() failed -> task stopped -> EAIWander::Reset seeded lookTime.
    try std.testing.expectEqual(c.TaskId.none, w.zombie_ai[zs].active_task);
    try std.testing.expect(w.zombie_ai[zs].look_time >= w.rules.ai.wander_look_min_s);
    try std.testing.expect(w.zombie_ai[zs].look_time <= w.rules.ai.wander_look_max_s);
    // Wander is data-blocked while lookTime > 0, so the next pass picks Look.
    var t: f32 = 0;
    while (t < 8.0 and w.zombie_ai[zs].active_task != .look) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(c.TaskId.look, w.zombie_ai[zs].active_task);
    try std.testing.expectEqual(@as(f32, 0), w.zombie_ai[zs].look_time);
    try std.testing.expect(w.zombie_ai[zs].look_wait > 0);
}

test "system zombie look holds position, turns yaw, then wander resumes" {
    var w: World = .{};
    defer w.deinit();
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    // Seed the look directly (what Wander/ApproachSpot Reset does).
    w.zombie_ai[zs].look_time = 3.0;
    _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(c.TaskId.look, w.zombie_ai[zs].active_task);
    const x0 = w.transform[zs].x;
    const z0 = w.transform[zs].z;
    var yaw_prev = w.transform[zs].yaw;
    var yaw_moved = false;
    var t: f32 = 0;
    while (t < 3.0 and w.zombie_ai[zs].active_task == .look) : (t += 0.05) {
        _ = systemZombieAi(&w, 0.05);
        if (@abs(w.transform[zs].yaw - yaw_prev) > 0.001) yaw_moved = true;
        yaw_prev = w.transform[zs].yaw;
    }
    try std.testing.expect(yaw_moved);
    // Look does not move the entity (moveHelper.Stop()).
    try std.testing.expectEqual(x0, w.transform[zs].x);
    try std.testing.expectEqual(z0, w.transform[zs].z);
    try std.testing.expectEqual(c.AiState.idle, w.zombie_ai[zs].state);
    try std.testing.expect(!w.zombie_ai[zs].alert);
    // Owed time spent -> Continue() fails -> Wander is selectable again.
    t = 0;
    while (t < 10.0 and w.zombie_ai[zs].active_task != .wander) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(c.TaskId.wander, w.zombie_ai[zs].active_task);
    try std.testing.expectEqual(c.AiState.wander, w.zombie_ai[zs].state);
}

test "system zombie approach_spot arrival seeds a 5-8 s look" {
    var w: World = .{};
    defer w.deinit();
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    w.zombie_ai[zs].has_spot = true;
    w.zombie_ai[zs].spot_x = 0.5;
    w.zombie_ai[zs].spot_z = 0;
    var t: f32 = 0;
    while (t < 5.0 and w.zombie_ai[zs].has_spot) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(!w.zombie_ai[zs].has_spot);
    // One more pass: CanExecute fails, EAIApproachSpot::Reset runs.
    _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(w.zombie_ai[zs].look_time >= w.rules.ai.spot_look_base_s);
    try std.testing.expect(w.zombie_ai[zs].look_time <= w.rules.ai.spot_look_base_s + w.rules.ai.spot_look_rand_s);
}

test "system zombie chases" {
    var w: World = .{};
    defer w.deinit();
    const z = w.spawnZombie(0, 70, 0, 40).?;
    _ = w.spawnPlayer(3, 70, 0, 0);
    const zs = w.slotOfNetId(z).?;
    var t: f32 = 0;
    while (t < 3.0) : (t += 0.05) {
        _ = systemZombieAi(&w, 0.05);
    }
    try std.testing.expect(w.transform[zs].x > 0.3);
    // Task graph: a sensed player selects approach_attack and closes to melee.
    try std.testing.expectEqual(c.TaskId.approach_attack, w.zombie_ai[zs].active_task);
    try std.testing.expectEqual(c.AiState.attack, w.zombie_ai[zs].state);
    try std.testing.expect(w.zombie_ai[zs].alert);
}

test "zombies chase faster at night (stock GetMoveSpeedAggro day/night split)" {
    // RE entity-ai.md GetMoveSpeedAggro: dark → MoveSpeedAggro max (passive
    // 134) else min (passive 133); the stock XML comment on the prop ("min/max
    // (like day or night)") pins the split. A zombie with aggro 0.2/1.25
    // closes on a far player faster at night (hour 1, dark) than at day
    // (hour 12); World.IsDark IL=31 bounds night as hour < dawn || hour > dusk.
    var day_x: f32 = 0;
    var night_x: f32 = 0;
    {
        var w: World = .{};
        defer w.deinit();
        w.director.clock.hours = 12;
        const z = w.spawnZombieDef(0, 70, 0, 40, .{
            .name = "zombieBoe",
            .hash = 1,
            .kind = .zombie,
            .chase_speed = 1.25,
            .chase_speed_day = 0.2,
            .wander_speed = 0.08,
        }).?;
        _ = w.spawnPlayer(8, 70, 0, 0);
        const zs = w.slotOfNetId(z).?;
        var t: f32 = 0;
        while (t < 2.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
        day_x = w.transform[zs].x;
    }
    {
        var w: World = .{};
        defer w.deinit();
        w.director.clock.hours = 1;
        const z = w.spawnZombieDef(0, 70, 0, 40, .{
            .name = "zombieBoe",
            .hash = 1,
            .kind = .zombie,
            .chase_speed = 1.25,
            .chase_speed_day = 0.2,
            .wander_speed = 0.08,
        }).?;
        _ = w.spawnPlayer(8, 70, 0, 0);
        const zs = w.slotOfNetId(z).?;
        var t: f32 = 0;
        while (t < 2.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
        night_x = w.transform[zs].x;
    }
    // Night chase (aggro max 1.25 ×1.6 ≈ 2 m/s) outpaces day chase (aggro min
    // 0.2 ×1.6 ≈ 0.32 m/s) by a wide margin over the same 2 s window; day
    // still closes (the chase task is active, not frozen).
    try std.testing.expect(night_x > day_x * 2.0);
    try std.testing.expect(day_x > 0.1);
}

/// Wall at x=2, z=-2..2: passable everywhere else at the caller's own height.
fn testWallStep(_: ?*anyopaque, _: i32, _: i32, from_y: i32, x: i32, z: i32) ?i32 {
    if (x == 2 and z >= -2 and z <= 2) return null;
    return from_y;
}

/// Infinite wall at x=2: nothing gets past it.
fn testSealedStep(_: ?*anyopaque, _: i32, _: i32, from_y: i32, x: i32, _: i32) ?i32 {
    if (x == 2) return null;
    return from_y;
}

test "system zombie paths around solid wall via A*" {
    // Zombie at 0, player at 4: the straight line is blocked.
    var w: World = .{};
    defer w.deinit();
    w.step_fn = testWallStep;
    w.step_ctx = null;
    const z = w.spawnZombie(0, 70, 0, 40).?;
    _ = w.spawnPlayer(4, 70, 0, 0);
    const zs = w.slotOfNetId(z).?;
    var t: f32 = 0;
    while (t < 8.0) : (t += 0.05) {
        _ = systemZombieAi(&w, 0.05);
    }
    // Should have progressed toward the player (around the wall), not stuck at x~1.
    try std.testing.expect(w.transform[zs].x > 2.0);
    try std.testing.expectEqual(c.TaskId.approach_attack, w.zombie_ai[zs].active_task);
}

test "wandering zombie paths around a wall via A*" {
    // Stock EAIWander walks to the spot on the navmesh; the straight-line
    // stepToward slid a wanderer into the obstacle. With step_fn wired, the
    // wander uses the same A* chase machinery and detours around the wall.
    // (startTask(.wander) re-seeds the wander spot, so this drives
    // wanderUpdate directly with a fixed target.)
    var w: World = .{};
    defer w.deinit();
    w.step_fn = testWallStep; // wall at x=2, z=-2..2
    w.step_ctx = null;
    const z = w.spawnZombie(0, 70, 0, 0).?;
    const zs = w.slotOfNetId(z).?;
    const ai = &w.zombie_ai[zs];
    // Wander target beyond the wall.
    ai.wander_tx = 6;
    ai.wander_tz = 0;
    var t: f32 = 0;
    while (t < 10.0) : (t += 0.05) {
        wanderUpdate(&w, zs, ai, 2.0, 0.05);
        applyGravity(&w, zs, 0.05);
    }
    // Detoured around the z=-2..2 wall segment instead of sliding against it.
    try std.testing.expect(w.transform[zs].x > 2.0);
    try std.testing.expectEqual(c.AiState.wander, ai.state);
}

test "chase reuses one solve for many steps instead of replanning per metre" {
    var w: World = .{};
    defer w.deinit();
    w.ambient_light = 0.5; // daylight: the CanSeeStealth sight gate stays open
    w.class_table[1].sight_light_min = -2.0; // stock zombie threshold (noon reach)
    w.class_table[1].sight_light_max = 150.0;
    w.step_fn = path_mod.openStep;
    w.step_ctx = null;
    const z = w.spawnZombie(0, 70, 0, 40).?;
    _ = w.spawnPlayer(10, 70, 0, 0);
    const zs = w.slotOfNetId(z).?;
    w.transform[zs].yaw = 90.0; // face the player at +x (sense gate: view cone)
    var replans: u32 = 0;
    var t: f32 = 0;
    while (t < 4.0) : (t += 0.05) {
        w.beginTick();
        _ = systemZombieAi(&w, 0.05);
        replans += w.path_replans.load(.monotonic);
    }
    // ~9 m of open-field chase: one solve buffers 8 cells, so a handful of
    // replans, not one per waypoint arrival (which used to reset the throttle).
    try std.testing.expect(w.transform[zs].x > 7.0);
    try std.testing.expect(replans <= 4);
}

test "chase of a walking target stays under the replan throttle" {
    var w: World = .{};
    defer w.deinit();
    w.step_fn = path_mod.openStep;
    w.step_ctx = null;
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const p = w.spawnPlayer(6, 70, 0, 0).?;
    const zs = w.slotOfNetId(z).?;
    const ps = w.slotOfNetId(p).?;
    var replans: u32 = 0;
    var ticks: u32 = 0;
    var t: f32 = 0;
    while (t < 4.0) : (t += 0.05) {
        // Player walks away faster than the zombie closes, so the goal cell
        // moves on most ticks.
        w.transform[ps].x += 0.15;
        w.beginTick();
        _ = systemZombieAi(&w, 0.05);
        replans += w.path_replans.load(.monotonic);
        ticks += 1;
    }
    try std.testing.expect(w.transform[zs].x > 4.0);
    // The throttle is 0.35 s, so 4 s of chase can afford about a dozen solves;
    // one per tick (80) is what the old waypoint-arrival reset produced.
    try std.testing.expect(replans <= 14);
}

test "budget-denied tick still walks the buffered path" {
    var w: World = .{};
    defer w.deinit();
    w.ambient_light = 0.5; // daylight: the CanSeeStealth sight gate stays open
    w.class_table[1].sight_light_min = -2.0; // stock zombie threshold (noon reach)
    w.class_table[1].sight_light_max = 150.0;
    w.step_fn = path_mod.openStep;
    w.step_ctx = null;
    const z = w.spawnZombie(0, 70, 0, 40).?;
    // Far enough that the buffer runs dry while still chasing (a body that
    // reaches melee range clears its path instead of asking for a new one).
    _ = w.spawnPlayer(14, 70, 0, 0);
    const zs = w.slotOfNetId(z).?;
    w.transform[zs].yaw = 90.0; // face the player at +x (sense gate: view cone)
    // Prime the buffer, then close the budget on this slot.
    _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(w.zombie_ai[zs].currentWp() != null);
    w.path_stride = 2;
    w.path_tick = @intFromBool(zs % 2 == 0); // (slot + tick) % 2 != 0
    try std.testing.expect(!w.pathBudgetAdmits(zs));
    const x0 = w.transform[zs].x;
    const before = w.path_replans.load(.monotonic);
    // Long enough to walk the whole buffer dry, so a replan is really wanted.
    var t: f32 = 0;
    while (t < 5.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(before, w.path_replans.load(.monotonic));
    try std.testing.expect(w.path_replans_denied.load(.monotonic) > 0);
    try std.testing.expect(w.transform[zs].x > x0 + 0.5);
}

test "path budget stride spreads replans once demand exceeds the cap" {
    var w: World = .{};
    defer w.deinit();
    // No demand: everyone is admitted.
    w.beginTick();
    try std.testing.expectEqual(@as(u32, 1), w.path_stride);
    w.path_replans.store(World.path_replans_per_tick * 3, .monotonic);
    w.beginTick();
    try std.testing.expectEqual(@as(u32, 3), w.path_stride);
    // Admission is a pure function of slot and tick, never of worker order.
    // With stride 3 exactly one slot in three is admitted over a full cycle.
    var admitted: u32 = 0;
    var s: Slot = 0;
    while (s < 30) : (s += 1) {
        if (w.pathBudgetAdmits(s)) admitted += 1;
    }
    try std.testing.expectEqual(@as(u32, 10), admitted);
    // The stride never grows past the delay cap, whatever the demand.
    w.path_replans.store(100000, .monotonic);
    w.beginTick();
    try std.testing.expectEqual(World.path_stride_max, w.path_stride);
}

test "zombie follows the path height instead of floating at spawn y" {
    // Terrain rising one block per cell east; zombie spawned well above it.
    const Ramp = struct {
        fn step(_: ?*anyopaque, _: i32, _: i32, from_y: i32, x: i32, _: i32) ?i32 {
            const h: i32 = 60 + @max(x, 0);
            if (h - from_y > 1) return null;
            return h;
        }
    };
    var w: World = .{};
    defer w.deinit();
    w.step_fn = Ramp.step;
    w.step_ctx = null;
    const z = w.spawnZombie(0, 70, 0, 40).?;
    _ = w.spawnPlayer(5, 70, 0, 0);
    const zs = w.slotOfNetId(z).?;
    var t: f32 = 0;
    while (t < 4.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    // Snapped onto the ramp on the first solve, then climbed with it.
    try std.testing.expect(w.transform[zs].x > 2.0);
    try std.testing.expect(w.transform[zs].y >= 61);
    try std.testing.expect(w.transform[zs].y <= 65);
}

test "zombie sealed in a box stays inside it" {
    // 5x5 walled room around the origin, player outside.
    const Box = struct {
        fn step(_: ?*anyopaque, _: i32, _: i32, from_y: i32, x: i32, z: i32) ?i32 {
            if (x <= -3 or x >= 3 or z <= -3 or z >= 3) return null;
            return from_y;
        }
    };
    var w: World = .{};
    defer w.deinit();
    w.step_fn = Box.step;
    w.step_ctx = null;
    const z = w.spawnZombie(0, 70, 0, 40).?;
    _ = w.spawnPlayer(8, 70, 0, 0);
    const zs = w.slotOfNetId(z).?;
    var t: f32 = 0;
    while (t < 6.0) : (t += 0.05) {
        _ = systemZombieAi(&w, 0.05);
        try std.testing.expect(w.transform[zs].x < 3.0);
        try std.testing.expect(w.transform[zs].x > -3.0);
    }
    // Sealed in: the AI must ask for the wall to come down, not walk through it.
    try std.testing.expect(w.zombie_ai[zs].path_blocked);
}

test "hurt zombie chases its attacker over the nearer player" {
    var w: World = .{};
    defer w.deinit();
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    _ = w.spawnPlayer(3, 70, 0, 0); // near
    const far = w.spawnPlayer(-20, 70, 0, 1).?;
    var t: f32 = 0;
    while (t < 0.5) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(w.zombie_ai[zs].target_id != far);
    // Shot from behind by the far player: EAISetAsTargetIfHurt retargets,
    // and the hit shoves the zombie away from the attacker (+x, toward the
    // near player) with the knockback impulse.
    const x_before = w.transform[zs].x;
    _ = w.damageFrom(z, 5, far);
    try std.testing.expect(w.zombie_ai[zs].kb_time > 0);
    _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(far, w.zombie_ai[zs].target_id);
    try std.testing.expect(w.zombie_ai[zs].alert);
    try std.testing.expect(w.transform[zs].x > x_before + 0.2); // shove applied
    // Let the shove finish, then verify the chase walks back toward the
    // attacker: the 2 s run must move the body left of the shove endpoint.
    while (w.zombie_ai[zs].kb_time > 0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    const x_after_shove = w.transform[zs].x;
    t = 0;
    while (t < 2.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(w.transform[zs].x < x_after_shove - 0.2);
    // The window expires and the nearest-player sense takes over again.
    w.zombie_ai[zs].revenge_time = 0.04;
    _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(@as(i32, -1), w.zombie_ai[zs].revenge_target);
}

test "revenge target ignores a same-kind attacker and a dead one" {
    var w: World = .{};
    defer w.deinit();
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const other = w.spawnZombie(6, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    // Zombie-on-zombie: CanExecute's entityType gate rejects it.
    _ = w.damageFrom(z, 5, other);
    _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(w.zombie_ai[zs].target_id != other);
    // Attacker gone: the revenge slot is released instead of chasing a ghost.
    const p = w.spawnPlayer(30, 70, 0, 0).?;
    _ = w.damageFrom(z, 5, p);
    w.destroy(w.slotOfNetId(p).?);
    _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(@as(i32, -1), w.zombie_ai[zs].revenge_target);
}

test "hurt animal runs away from its attacker" {
    var w: World = .{};
    defer w.deinit();
    const a = w.spawnAnimal(0, 70, 0, 30, 0, "").?;
    const as = w.slotOfNetId(a).?;
    w.class_id[as].is_enemy = false; // passive wildlife flees; predators hunt
    const p = w.spawnPlayer(2, 70, 0, 0).?;
    _ = w.damageFrom(a, 5, p);
    var t: f32 = 0;
    while (t < 2.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(c.TaskId.runaway, w.zombie_ai[as].active_task);
    // Fleeing means putting distance between itself and the player at x=2.
    try std.testing.expect(w.transform[as].x < -0.5);
    try std.testing.expect(!w.zombie_ai[as].alert);
}

test "passive animal flees a feared entity within fleeDistance (RunawayFromEntity)" {
    // AITask-2 RunawayFromEntity: an animal within fleeDistance (20) of a
    // player / zombie / other animal picks the runaway task and moves away.
    var w: World = .{};
    defer w.deinit();
    const a = w.spawnAnimal(0, 70, 0, 100, 0, "").?;
    const as = w.slotOfNetId(a).?;
    w.class_id[as].is_enemy = false; // passive wildlife flees; predators hunt
    const z = w.spawnZombie(10, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    var t: f32 = 0;
    while (t < 1.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    // Fear scan found the zombie; the runaway task is active and the animal
    // is walking away from it (-x).
    try std.testing.expectEqual(w.network_id[zs].id, w.zombie_ai[as].fear_target);
    try std.testing.expectEqual(c.TaskId.runaway, w.zombie_ai[as].active_task);
    const x0 = w.transform[as].x;
    while (t < 2.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    // No player is sensed, so the LOD active_scale throttles movement to 0.1x;
    // the flee still walks away from the zombie (-x).
    try std.testing.expect(w.transform[as].x < x0 - 0.1);
}

test "passive animal does not flee an entity beyond fleeDistance" {
    var w: World = .{};
    defer w.deinit();
    const a = w.spawnAnimal(0, 70, 0, 100, 0, "").?;
    const as = w.slotOfNetId(a).?;
    w.class_id[as].is_enemy = false; // passive wildlife flees; predators hunt
    _ = w.spawnZombie(30, 70, 0, 40).?; // beyond 20 -> no fear
    var t: f32 = 0;
    while (t < 1.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(@as(i32, -1), w.zombie_ai[as].fear_target);
    try std.testing.expect(w.zombie_ai[as].active_task != c.TaskId.runaway);
}

test "timid animal near a player never attacks; a predator does" {
    // GAP timid-animals row: stock animalTemplateTimid carries no attack task
    // (RunawayWhenHurt/RunawayFromEntity/Look/Wander), so an unprovoked stag
    // near a player must not sprint at it and melee. The class task list gates
    // approach_attack via ai_attack (parsed from entityclasses AITask-*); the
    // predator keeps its ApproachAndAttackTarget task.
    var w: World = .{};
    defer w.deinit();
    const stag = w.spawnAnimal(0, 70, 2, 100, 0, "").?;
    const ss = w.slotOfNetId(stag).?;
    w.class_id[ss].is_enemy = false; // passive wildlife
    w.class_id[ss].ai_attack = false; // timid template: no attack task
    const wolf = w.spawnAnimal(0, 70, -2, 100, 0, "").?;
    const ws = w.slotOfNetId(wolf).?;
    w.class_id[ws].is_enemy = true; // predator hunts
    w.class_id[ws].ai_attack = true; // hostile template: ApproachAndAttackTarget
    w.class_id[ws].sight_light_min = -2.0; // stock predator threshold: lit-reachable
    w.class_id[ws].sight_light_max = 150.0;
    w.ambient_light = 0.5; // daylight: the CanSeeStealth sight gate is open
    _ = w.spawnPlayer(0, 70, 10, 0).?; // 8-12 m from both, inside sense
    var t: f32 = 0;
    while (t < 1.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    // The timid animal flees (player is a RunawayFromEntity fear source) or
    // wanders, but never picks the attack task.
    try std.testing.expect(w.zombie_ai[ss].active_task != c.TaskId.approach_attack);
    // The predator, same distance, picks approach_attack and moves in.
    try std.testing.expectEqual(c.TaskId.approach_attack, w.zombie_ai[ws].active_task);
}

test "far animals despawn like zombies; near animals stay" {
    // GAP animals-never-despawn row: systemDespawnFar copied only the zombie
    // kind group, so wildlife accumulated to MaxSpawnedAnimals and held slots
    // forever. Animals now despawn beyond despawn_dist_sq with the same rules
    // (sleepers and alerted mobs stay).
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    const far = w.spawnAnimal(400, 70, 0, 30, 0, "").?;
    const near = w.spawnAnimal(10, 70, 0, 30, 0, "").?;
    const alert = w.spawnAnimal(400, 70, 2, 30, 0, "").?;
    const as = w.slotOfNetId(alert).?;
    w.zombie_ai[as].alert = true; // alerted mobs stay (like zombies)
    var ids: [8]i32 = undefined;
    const n = systemDespawnFar(&w, &ids);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(far, ids[0]);
    try std.testing.expectEqual(@as(?u16, null), w.slotOfNetId(far));
    try std.testing.expect(w.slotOfNetId(near) != null);
    try std.testing.expect(w.slotOfNetId(alert) != null);
}

/// Stock decoy distraction state (items.xml resourceRockDecoy): tags
/// zombie+requires_contact, radius 25, lifetime broadcast count, strength 100.
fn seedDecoy(w: *World, x: f32, z: f32, lifetime: i32) i32 {
    const bag = w.spawnLootBag(x, 70, z, 1, 1).?;
    const bs = w.slotOfNetId(bag).?;
    w.loot_bag[bs] = .{
        .distraction_tags = 2 | 4,
        .distraction_radius_sq = 25 * 25,
        .distraction_lifetime = lifetime,
        .distraction_strength = 100,
    };
    return bag;
}

test "dropped decoy registers as pending within 25 m (tickDistraction)" {
    var w: World = .{};
    defer w.deinit();
    const bag = seedDecoy(&w, 10, 0, 10);
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    // 20-tick broadcast cadence: the first broadcast fires on AI tick 21.
    var t: f32 = 0;
    while (t < 1.05) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(bag, w.zombie_ai[zs].pending_distraction);
}

test "approach_distraction walks a decoy across decision re-evals" {
    var w: World = .{};
    defer w.deinit();
    const bag = seedDecoy(&w, 4, 0, 10);
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    // Pre-latch the broadcast result so the task selection is deterministic
    // (the 20-tick cadence itself is covered by the test above).
    w.zombie_ai[zs].pending_distraction = bag;
    w.zombie_ai[zs].pending_distraction_dsq = 16;
    w.zombie_ai[zs].active_task = .none;
    w.zombie_ai[zs].decision_cd = 0;
    var t: f32 = 0;
    while (t < 0.1) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(c.TaskId.approach_distraction, w.zombie_ai[zs].active_task);
    const x0 = w.transform[zs].x;
    // Outlast one decision window (0.425 s / 0.005 s/tick at the 0.1 LOD
    // active_scale with no player sensed = 85 ticks); the task must re-win on
    // `distraction` and keep walking toward the decoy (+x).
    while (t < 6.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(c.TaskId.approach_distraction, w.zombie_ai[zs].active_task);
    try std.testing.expect(w.transform[zs].x > x0);
}

test "zombie reaches a non-eat decoy and loses interest (clears the latch)" {
    var w: World = .{};
    defer w.deinit();
    const bag = w.spawnLootBag(1, 70, 0, 1, 1).?;
    const bs = w.slotOfNetId(bag).?;
    w.loot_bag[bs] = .{
        .distraction_tags = 2 | 4,
        .distraction_radius_sq = 25 * 25,
        .distraction_lifetime = 10,
        .distraction_strength = 100,
    };
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    w.zombie_ai[zs].pending_distraction = bag;
    w.zombie_ai[zs].pending_distraction_dsq = 1;
    w.zombie_ai[zs].active_task = .none;
    w.zombie_ai[zs].decision_cd = 0;
    var t: f32 = 0;
    while (t < 0.2) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    // Within cCloseDist (1.5 m) of a non-eat item the task clears itself and
    // the zombie falls back to the movement fallback (wander).
    try std.testing.expectEqual(@as(i32, -1), w.zombie_ai[zs].distraction);
    try std.testing.expect(w.zombie_ai[zs].active_task != c.TaskId.approach_distraction);
}

test "zombie chews an eat distraction until the item is eaten up" {
    var w: World = .{};
    defer w.deinit();
    const bag = w.spawnLootBag(1, 70, 0, 1, 1).?;
    const bs = w.slotOfNetId(bag).?;
    w.loot_bag[bs] = .{
        .distraction_tags = 1 | 4, // eat + zombie
        .distraction_radius_sq = 25 * 25,
        .distraction_lifetime = 100,
        .distraction_strength = 100,
        .distraction_eat_ticks = 5,
    };
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    w.zombie_ai[zs].pending_distraction = bag;
    w.zombie_ai[zs].pending_distraction_dsq = 1;
    w.zombie_ai[zs].active_task = .none;
    w.zombie_ai[zs].decision_cd = 0;
    var t: f32 = 0;
    while (t < 0.6) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    // Close enough to chew: IsEating latched, eat ticks drained to 0. The sim
    // keeps the bag alive (Game removes + broadcasts EntityRemove).
    try std.testing.expect(w.zombie_ai[zs].is_eating);
    try std.testing.expectEqual(@as(i32, 0), w.loot_bag[bs].distraction_eat_ticks);
    try std.testing.expect(w.alive[bs]);
}

test "concurrent eat countdown saturates at zero" {
    if (builtin.single_threaded) return;
    var value: i32 = 1;
    var ready: std.atomic.Value(u8) = .init(0);
    var go: std.atomic.Value(bool) = .init(false);
    const Worker = struct {
        fn run(v: *i32, r: *std.atomic.Value(u8), start: *std.atomic.Value(bool)) void {
            _ = r.fetchAdd(1, .release);
            while (!start.load(.acquire)) std.Thread.yield() catch {};
            decrementIfPositive(v);
        }
    };
    var threads: [8]std.Thread = undefined;
    var spawned: usize = 0;
    for (&threads) |*thread| {
        thread.* = std.Thread.spawn(.{}, Worker.run, .{ &value, &ready, &go }) catch |err| {
            go.store(true, .release);
            for (threads[0..spawned]) |*started| started.join();
            return err;
        };
        spawned += 1;
    }
    while (ready.load(.acquire) != threads.len) std.Thread.yield() catch {};
    go.store(true, .release);
    for (&threads) |*thread| thread.join();
    try std.testing.expectEqual(@as(i32, 0), @atomicLoad(i32, &value, .monotonic));
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

test "system zombie wanders when no player sensed" {
    var w: World = .{};
    defer w.deinit();
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    const x0 = w.transform[zs].x;
    const z0 = w.transform[zs].z;
    var t: f32 = 0;
    while (t < 3.0) : (t += 0.05) {
        _ = systemZombieAi(&w, 0.05);
    }
    try std.testing.expectEqual(c.TaskId.wander, w.zombie_ai[zs].active_task);
    try std.testing.expectEqual(c.AiState.wander, w.zombie_ai[zs].state);
    try std.testing.expect(!w.zombie_ai[zs].alert);
    // Drifted somewhere (xorshift destination is off-origin).
    const moved = @abs(w.transform[zs].x - x0) + @abs(w.transform[zs].z - z0);
    try std.testing.expect(moved > 0.1);
}

test "system zombie falls back to wander when target removed (mutex release)" {
    var w: World = .{};
    defer w.deinit();
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const p = w.spawnPlayer(3, 70, 0, 0).?;
    const zs = w.slotOfNetId(z).?;
    // Sense the player: approach wins.
    var t: f32 = 0;
    while (t < 1.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(c.TaskId.approach_attack, w.zombie_ai[zs].active_task);
    // Remove the target entity: approach.CanExecute fails, mutex frees, wander
    // resumes on the next selection pass.
    const ps = w.slotOfNetId(p).?;
    w.destroy(ps);
    t = 0;
    while (t < 3.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(c.TaskId.wander, w.zombie_ai[zs].active_task);
    try std.testing.expectEqual(c.AiState.wander, w.zombie_ai[zs].state);
    try std.testing.expect(!w.zombie_ai[zs].alert);
}

test "class_table attack/chase floors only when field is zero" {
    var w: World = .{};
    defer w.deinit();
    w.class_table[1].attack_damage = 20;
    w.class_table[1].chase_speed_day = 1.0; // XML-scale day chase (aggro min); sim *1.6
    w.class_table[1].chase_speed = 1.0; // XML-scale night chase (aggro max); sim *1.6
    w.class_table[1].wander_speed = 0.2;
    const z = w.spawnZombie(0, 70, 0, 40).?;
    _ = w.spawnPlayer(1.2, 70, 0, 0);
    const zs = w.slotOfNetId(z).?;
    const ps = w.playerByPeer(0).?;
    const hp0 = w.health[ps].hp;
    var t: f32 = 0;
    while (t < 2.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    // Melee used class attack_damage (20), not module floor 8.
    try std.testing.expect(w.health[ps].hp <= hp0 - 15);
    // Class chase applied (non-zero table field).
    try std.testing.expectEqual(c.TaskId.approach_attack, w.zombie_ai[zs].active_task);
}

// T14 (WORK_PLAN): a configured Rules floor is a floor, never a replacement
// for per-entity stock data (ADR 0021 decision 5). These three tests set a
// Rules value and a conflicting entityclasses value and assert the loaded
// class table wins, exactly as the production resolve order does.

test "per-entity attack_damage beats the class_table row and the Rules floor" {
    var w: World = .{ .rules = .{ .combat = .{ .attack_damage = 100.0 } } };
    defer w.deinit();
    w.class_table[1].attack_damage = 20; // items.xml DamageEntity (via HandItem)
    // spawnZombieDef carries the full resolved row (A35): the per-entity 5
    // must win over the class_table 20 and the Rules 100 floor.
    const z = w.spawnZombieDef(0, 70, 0, 40, .{
        .name = "zombieFeral",
        .max_hp = 60,
        .kind = .zombie,
        .hash = 123,
        .attack_damage = 5,
    }).?;
    _ = w.spawnPlayer(1.2, 70, 0, 0);
    const zs = w.slotOfNetId(z).?;
    const ps = w.playerByPeer(0).?;
    const hp0 = w.health[ps].hp;
    var t: f32 = 0;
    while (t < 2.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    const lost = hp0 - w.health[ps].hp;
    // Per-entity 5 x ~2 bites ~= 10. A class_table-only read would have dealt
    // 20 (40+), and a Rules-only read 100 (death at 100).
    try std.testing.expect(lost >= 5);
    try std.testing.expect(lost < 25);
    try std.testing.expectEqual(c.TaskId.approach_attack, w.zombie_ai[zs].active_task);
}

test "configured attack floor never beats the entityclasses value" {
    var w: World = .{ .rules = .{ .combat = .{ .attack_damage = 100.0 } } };
    defer w.deinit();
    w.class_table[1].attack_damage = 20; // items.xml DamageEntity (via HandItem)
    const z = w.spawnZombie(0, 70, 0, 40).?;
    _ = w.spawnPlayer(1.2, 70, 0, 0);
    const zs = w.slotOfNetId(z).?;
    const ps = w.playerByPeer(0).?;
    const hp0 = w.health[ps].hp;
    var t: f32 = 0;
    while (t < 2.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    const lost = hp0 - w.health[ps].hp;
    // Class 20 x 2 bites ~= 40. The 100 floor must NOT apply (that would be 200).
    try std.testing.expect(lost >= 20);
    try std.testing.expect(lost < 80);
    try std.testing.expectEqual(c.TaskId.approach_attack, w.zombie_ai[zs].active_task);
}

test "configured chase floor never beats the entityclasses MoveSpeedAggro" {
    var w: World = .{ .rules = .{ .ai = .{ .chase_speed = 100.0 } } };
    defer w.deinit();
    w.ambient_light = 0.5; // daylight: the CanSeeStealth sight gate is open
    // XML-scale aggro pair: min (day) 1.0 / max (night) 1.0 → sim ×1.6.
    // The stock pair always carries both (entity-ai.md 3313-3314 ParseVec).
    w.class_table[1].chase_speed_day = 1.0;
    w.class_table[1].chase_speed = 1.0;
    // Stock zombie sight-light threshold so the 12 m player is seen at noon
    // (the (30,100) floor would blind the gate beyond ~11 m).
    w.class_table[1].sight_light_min = -2.0;
    w.class_table[1].sight_light_max = 150.0;
    const z = w.spawnZombie(0, 70, 0, 40).?;
    _ = w.spawnPlayer(12, 70, 0, 0);
    const zs = w.slotOfNetId(z).?;
    w.transform[zs].yaw = 90.0; // face the player at +x (sense gate: view cone)
    var t: f32 = 0;
    while (t < 4.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    // Class 1.0 -> 1.6 blocks/s; 4 s closes only a few blocks. A 100 floor would
    // have crossed 12 in under a second (160 blocks/s), so this bounds it.
    try std.testing.expect(w.transform[zs].x < 25);
    try std.testing.expectEqual(c.TaskId.approach_attack, w.zombie_ai[zs].active_task);
}

test "configured wander floor never beats the entityclasses MoveSpeed" {
    var w: World = .{ .rules = .{ .ai = .{ .wander_speed = 50.0 } } };
    defer w.deinit();
    w.class_table[1].wander_speed = 0.2; // XML-scale; sim uses *10.0
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    const x0 = w.transform[zs].x;
    const z0 = w.transform[zs].z;
    var t: f32 = 0;
    while (t < 3.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(c.TaskId.wander, w.zombie_ai[zs].active_task);
    const moved = @abs(w.transform[zs].x - x0) + @abs(w.transform[zs].z - z0);
    // Class 0.2 -> 2.0 blocks/s with look pauses; a 50 floor would be 500/s.
    try std.testing.expect(moved > 0.1);
    try std.testing.expect(moved < 25);
}

test "spawn zombie loot_list comes from class_table not scrap" {
    var w: World = .{};
    defer w.deinit();
    try std.testing.expectEqualStrings("EntityLootContainerRegular", w.class_table[1].loot_list);
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    try std.testing.expectEqualStrings("EntityLootContainerRegular", w.class_id[zs].loot_list);
    w.class_table[1].loot_list = "EntityLootContainerStrong";
    const z2 = w.spawnZombieClass(1, 70, 1, 40, 1, w.class_table[1].loot_list).?;
    const zs2 = w.slotOfNetId(z2).?;
    try std.testing.expectEqualStrings("EntityLootContainerStrong", w.class_id[zs2].loot_list);
}

test "system zombie break_block when path fully blocked" {
    // Impassable wall sealing zombie from player; A* fails → path_blocked → BreakBlock.
    var w: World = .{};
    defer w.deinit();
    w.step_fn = testSealedStep;
    w.step_ctx = null;
    const z = w.spawnZombie(0, 70, 0, 40).?;
    _ = w.spawnPlayer(4, 70, 0, 0);
    const zs = w.slotOfNetId(z).?;
    var t: f32 = 0;
    while (t < 3.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(w.zombie_ai[zs].path_blocked);
    try std.testing.expectEqual(c.TaskId.break_block, w.zombie_ai[zs].active_task);
    try std.testing.expectEqual(c.AiState.chase, w.zombie_ai[zs].state);
    try std.testing.expect(w.zombie_ai[zs].alert);
}

test "system zombie approaches spot and clears on arrive" {
    // No player → active_scale 0.1; short spot so arrive fits the budget.
    var w: World = .{};
    defer w.deinit();
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    w.zombie_ai[zs].has_spot = true;
    w.zombie_ai[zs].spot_x = 2.5;
    w.zombie_ai[zs].spot_z = 0;
    const x0 = w.transform[zs].x;
    var t: f32 = 0;
    while (t < 2.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(c.TaskId.approach_spot, w.zombie_ai[zs].active_task);
    try std.testing.expect(w.transform[zs].x > x0 + 0.2);
    // ~2.5 m at chase*0.1 ≈ 0.22 m/s → clear within ~20 s.
    t = 0;
    while (t < 25.0 and w.zombie_ai[zs].has_spot) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(!w.zombie_ai[zs].has_spot);
    try std.testing.expect(w.transform[zs].x > 1.5);
}

test "system zombie destroy_area when rng gate hits while chase" {
    // wander_rng % 16 == 1 arms DestroyArea at least once while player is sensed.
    var w: World = .{};
    defer w.deinit();
    const z = w.spawnZombie(0, 70, 0, 40).?;
    _ = w.spawnPlayer(5, 70, 0, 0);
    const zs = w.slotOfNetId(z).?;
    w.zombie_ai[zs].wander_rng = 1;
    var saw_destroy = false;
    var t: f32 = 0;
    while (t < 2.0) : (t += 0.05) {
        _ = systemZombieAi(&w, 0.05);
        if (w.zombie_ai[zs].active_task == .destroy_area) saw_destroy = true;
    }
    try std.testing.expect(saw_destroy);
    // May end in chase or attack once in range; alert must latch.
    try std.testing.expect(w.zombie_ai[zs].alert);
    try std.testing.expect(w.zombie_ai[zs].state == .chase or w.zombie_ai[zs].state == .attack);
}

test "system zombie territorial walks home when far" {
    // Spawn home at origin; drag entity past leash with no player.
    var w: World = .{};
    defer w.deinit();
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    try std.testing.expect(w.zombie_ai[zs].has_home);
    w.transform[zs].x = 40;
    w.transform[zs].z = 0;
    const x0 = w.transform[zs].x;
    var t: f32 = 0;
    while (t < 3.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(c.TaskId.territorial, w.zombie_ai[zs].active_task);
    try std.testing.expect(w.transform[zs].x < x0 - 0.2);
    // Keep walking until inside leash (active_scale 0.1 without player).
    t = 0;
    while (t < 80.0) : (t += 0.05) {
        _ = systemZombieAi(&w, 0.05);
        const dx = w.transform[zs].x - w.zombie_ai[zs].home_x;
        const dz = w.transform[zs].z - w.zombie_ai[zs].home_z;
        const terr2 = w.rules.ai.territorial_radius;
        if (dx * dx + dz * dz <= terr2 * terr2) break;
    }
    const dx = w.transform[zs].x - w.zombie_ai[zs].home_x;
    const dz = w.transform[zs].z - w.zombie_ai[zs].home_z;
    const terr3 = w.rules.ai.territorial_radius;
    try std.testing.expect(dx * dx + dz * dz <= terr3 * terr3);
}

test "quest kill complete on journal component" {
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(questAccept(&w, 0, 1));
    try std.testing.expect(questHasActive(&w, 0, 1));
    questOnZombieKilled(&w, 0, 0, 0);
    questOnZombieKilled(&w, 0, 0, 0);
    questOnZombieKilled(&w, 0, 0, 0);
    try std.testing.expect(!questHasActive(&w, 0, 1));
    drainQuestCoins(&w, 0);
    try std.testing.expectEqual(@as(u32, 25), questCoins(&w, 0));
}

test "quest progress and coin rewards saturate instead of wrapping" {
    var w: World = .{};
    defer w.deinit();
    const defs = [_]quest.QuestDef{.{
        .id = 22,
        .kind = .fetch_item,
        .title = "Large fetch",
        .target_count = std.math.maxInt(u16),
        .reward_coin = 10,
    }};
    w.catalog = .{ .defs = &defs, .starter_id = 22, .source = .builtin };
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(questAccept(&w, 0, 22));
    const ps = w.playerByPeer(0).?;
    w.wallet[ps].coins = std.math.maxInt(u32) - 5;
    questFindActive(&w, 0, 22).?.progress = std.math.maxInt(u16) - 5;

    questOnFetchItem(&w, 0, 10);

    try std.testing.expect(!questHasActive(&w, 0, 22));
    drainQuestCoins(&w, 0);
    try std.testing.expectEqual(std.math.maxInt(u32), questCoins(&w, 0));
}

test "quest phase graph goto then kill then turn-in at trader" {
    var w: World = .{};
    defer w.deinit();
    const phases = [_]quest.PhaseSpec{
        .{ .kind = .goto_point, .required = 1 },
        .{ .kind = .kill_zombies, .required = 3 },
        .{ .kind = .trader_interact, .required = 1 },
    };
    const defs = [_]quest.QuestDef{.{
        .id = 20,
        .kind = .kill_zombies,
        .name = "pg",
        .title = "PG",
        .target_count = 3,
        .reward_coin = 50,
        .turn_in = true,
        .tx = 10,
        .ty = 70,
        .tz = 10,
        .objective_count = 3,
        .phases = &phases,
        .highest_phase = 3,
        .objective_phases = &[_]u8{ 1, 2, 3 },
    }};
    w.catalog = .{ .defs = &defs, .starter_id = 20, .source = .builtin };
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(questAccept(&w, 0, 20));
    const s = questFindActive(&w, 0, 20).?;
    try std.testing.expectEqual(@as(u8, 1), s.phase);

    // Kills on the goto phase must not advance it.
    questOnZombieKilled(&w, 0, 0, 0);
    try std.testing.expectEqual(@as(u8, 1), s.phase);

    // Reach the goto point → advance to the kill phase.
    questTickGoto(&w, 0, 10, 70, 10);
    try std.testing.expectEqual(@as(u8, 2), s.phase);

    // Three kills complete the kill phase → trader phase, not yet ready.
    questOnZombieKilled(&w, 0, 0, 0);
    questOnZombieKilled(&w, 0, 0, 0);
    questOnZombieKilled(&w, 0, 0, 0);
    try std.testing.expectEqual(@as(u8, 3), s.phase);
    try std.testing.expect(!s.ready_turn_in);
    try std.testing.expect(questHasActive(&w, 0, 20));

    // Interacting at the trader satisfies the highest phase and turns in.
    questOnTraderOpen(&w, 0);
    try std.testing.expect(!questHasActive(&w, 0, 20));
    drainQuestCoins(&w, 0);
    try std.testing.expectEqual(@as(u32, 50), questCoins(&w, 0));
}

test "quest phase graph auto-skips leading scaffolding on accept" {
    var w: World = .{};
    defer w.deinit();
    const phases = [_]quest.PhaseSpec{
        .{ .kind = .auto, .required = 1 },
        .{ .kind = .kill_zombies, .required = 2 },
    };
    const defs = [_]quest.QuestDef{.{
        .id = 21,
        .kind = .kill_zombies,
        .name = "sk",
        .title = "SK",
        .target_count = 2,
        .reward_coin = 30,
        .objective_count = 2,
        .phases = &phases,
        .highest_phase = 2,
        .objective_phases = &[_]u8{ 1, 2 },
    }};
    w.catalog = .{ .defs = &defs, .starter_id = 21, .source = .builtin };
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(questAccept(&w, 0, 21));
    // Leading auto phase auto-completes on accept: land on the kill phase.
    try std.testing.expectEqual(@as(u8, 2), questFindActive(&w, 0, 21).?.phase);
    questOnZombieKilled(&w, 0, 0, 0);
    questOnZombieKilled(&w, 0, 0, 0);
    try std.testing.expect(!questHasActive(&w, 0, 21));
    drainQuestCoins(&w, 0);
    try std.testing.expectEqual(@as(u32, 30), questCoins(&w, 0));
}

/// Fixed POI covering the quest target used by the rally tests.
fn testPoiRect(_: ?*anyopaque, x: f32, z: f32) ?c.PoiRect {
    const rect: c.PoiRect = .{ .x = 0, .y = 60, .z = 0, .size_x = 64, .size_y = 20, .size_z = 64 };
    return if (rect.containsXZ(x, z)) rect else null;
}

/// Nearest-POI hook for the B26 goto placement test.
fn testNearestPoi(_: ?*anyopaque, _: f32, _: f32) ?c.PoiRect {
    return .{ .x = 100, .y = 60, .z = 200, .size_x = 40, .size_y = 20, .size_z = 40 };
}

test "goto quest binds the nearest real POI instead of an invented spot" {
    var w: World = .{};
    defer w.deinit();
    const phases = [_]quest.PhaseSpec{.{ .kind = .goto_point, .required = 1 }};
    const defs = [_]quest.QuestDef{.{
        .id = 40,
        .kind = .goto_point,
        .name = "gp",
        .title = "GP",
        .target_count = 1,
        .reward_coin = 10,
        .tx = 0, // no static position; the bound POI must win
        .ty = 70,
        .tz = 0,
        .objective_count = 1,
        .phases = &phases,
        .highest_phase = 1,
        .objective_phases = &[_]u8{1},
    }};
    w.catalog = .{ .defs = &defs, .starter_id = 40, .source = .builtin };
    w.nearest_poi_fn = &testNearestPoi;
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(questAccept(&w, 0, 40));
    const s = questFindActive(&w, 0, 40).?;
    // Accept bound the nearest real POI (100,200) with its 40x40 footprint.
    try std.testing.expect(s.poi.valid());
    try std.testing.expectEqual(@as(f32, 100), s.poi.x);
    try std.testing.expectEqual(@as(f32, 200), s.poi.z);
    // The def marker (0,0) is not the target: standing there does nothing.
    questTickGoto(&w, 0, 0, 70, 0);
    try std.testing.expect(questHasActive(&w, 0, 40));
    // Arriving at the POI center completes the goto quest.
    questTickGoto(&w, 0, 120, 70, 220);
    try std.testing.expect(!questHasActive(&w, 0, 40));
    drainQuestCoins(&w, 0);
    try std.testing.expectEqual(@as(u32, 10), questCoins(&w, 0));
}

test "goto/stay default radii come from catalog.policy (ADR 0021)" {
    var w: World = .{};
    defer w.deinit();
    const phases = [_]quest.PhaseSpec{.{ .kind = .goto_point, .required = 1 }};
    const defs = [_]quest.QuestDef{.{
        .id = 42,
        .kind = .goto_point,
        .name = "gr",
        .title = "GR",
        .tx = 10,
        .ty = 70,
        .tz = 10,
        .objective_count = 1,
        .phases = &phases,
        .highest_phase = 1,
    }};
    // Policy radius 12 m (no poi_fn: the goto target is the def spot 10,10).
    w.catalog = .{ .defs = &defs, .starter_id = 42, .policy = .{ .goto_radius = 12 } };
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(questAccept(&w, 0, 42));
    // 11 m from (10,10): inside the 12 m policy radius -> completes; the
    // builtin 4 m default would not have.
    questTickGoto(&w, 0, 10, 70, -1);
    try std.testing.expect(!questHasActive(&w, 0, 42));

    // stay_within: the policy radius is the floor when no distance is parsed.
    const stay_phases = [_]quest.PhaseSpec{.{ .kind = .stay_within, .required = 1 }};
    const stay_defs = [_]quest.QuestDef{.{
        .id = 43,
        .kind = .stay_within,
        .name = "sw",
        .title = "SW",
        .tx = 0,
        .ty = 70,
        .tz = 0,
        .objective_count = 1,
        .phases = &stay_phases,
        .highest_phase = 1,
    }};
    w.catalog = .{ .defs = &stay_defs, .starter_id = 43, .policy = .{ .stay_radius = 12 } };
    try std.testing.expect(questAccept(&w, 0, 43));
    questTickStayWithin(&w, 0, 10, 0); // 10 m from the target: inside 12 m
    try std.testing.expect(!questHasActive(&w, 0, 43));
}

test "ClearSleepers kills gate to the bound POI and suppress its sleepers" {
    var w: World = .{};
    defer w.deinit();
    const phases = [_]quest.PhaseSpec{.{ .kind = .kill_zombies, .required = 2, .poi_gated = true }};
    const defs = [_]quest.QuestDef{.{
        .id = 50,
        .kind = .kill_zombies,
        .name = "cs",
        .title = "CS",
        .target_count = 2,
        .reward_coin = 10,
        .objective_count = 1,
        .phases = &phases,
        .highest_phase = 1,
        .objective_phases = &[_]u8{1},
    }};
    w.catalog = .{ .defs = &defs, .starter_id = 50, .source = .builtin };
    w.poi_fn = &testPoiRect; // POI covering (0,0)..(64,64)
    // Spy: completing the clear phase fires the sleeper-suppression hook.
    var cleared_n: u32 = 0;
    const spy = struct {
        fn f(ctx: ?*anyopaque, _: c.PoiRect) void {
            const p: *u32 = @ptrCast(@alignCast(ctx.?));
            p.* += 1;
        }
    }.f;
    w.quest_clear_ctx = &cleared_n;
    w.quest_clear_fn = spy;
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(questAccept(&w, 0, 50));
    try std.testing.expect(questFindActive(&w, 0, 50).?.poi.valid());
    // A kill outside the bound POI must not advance a ClearSleepers phase
    // (stock QuestEvent_SleepersCleared only counts the POI's own sleepers).
    questOnZombieKilled(&w, 0, 1000, 1000);
    try std.testing.expect(questHasActive(&w, 0, 50));
    try std.testing.expectEqual(@as(u32, 0), cleared_n);
    // Kills inside the POI count; completing the phase suppresses sleepers.
    questOnZombieKilled(&w, 0, 10, 10);
    try std.testing.expect(questHasActive(&w, 0, 50));
    questOnZombieKilled(&w, 0, 20, 20);
    try std.testing.expect(!questHasActive(&w, 0, 50));
    try std.testing.expectEqual(@as(u32, 1), cleared_n);
}

test "ClearSleepers target uses the POI's live sleeper count (B25)" {
    // Stock ObjectiveClearSleepers counts the bound POI's sleeper volume
    // spawns as the kill target; the Game hook supplies that count and the
    // def's policy floor is not used (audit B25).
    var w: World = .{};
    defer w.deinit();
    const objs = [_]quest.FlatObjective{.{
        .phase = 1,
        .kind = .kill_zombies,
        .required = 1, // policy floor; the hook overrides it to 4
        .poi_gated = true,
    }};
    const phases = [_]quest.PhaseSpec{.{ .kind = .kill_zombies, .required = 1, .poi_gated = true }};
    const defs = [_]quest.QuestDef{.{
        .id = 51,
        .kind = .kill_zombies,
        .name = "cs_live",
        .title = "CS live",
        .target_count = 1,
        .reward_coin = 10,
        .objective_count = 1,
        .phases = &phases,
        .highest_phase = 1,
        .objective_phases = &[_]u8{1},
        .objectives = &objs,
    }};
    w.catalog = .{ .defs = &defs, .starter_id = 51, .source = .builtin };
    w.poi_fn = &testPoiRect; // POI covering (0,0)..(64,64)
    const Spy = struct {
        fn f(_: ?*anyopaque, _: c.PoiRect) u16 {
            return 4; // the POI holds 4 sleepers
        }
    };
    w.quest_sleeper_count_ctx = null;
    w.quest_sleeper_count_fn = &Spy.f;
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(questAccept(&w, 0, 51));
    try std.testing.expect(questFindActive(&w, 0, 51).?.poi.valid());
    // 1-3 kills: still active (target 4, not the def floor of 1).
    questOnZombieKilled(&w, 0, 10, 10);
    questOnZombieKilled(&w, 0, 20, 20);
    questOnZombieKilled(&w, 0, 30, 30);
    try std.testing.expect(questHasActive(&w, 0, 51));
    // The 4th kill completes the phase.
    questOnZombieKilled(&w, 0, 40, 40);
    try std.testing.expect(!questHasActive(&w, 0, 51));
    // Unset hook keeps the def floor.
    w.quest_sleeper_count_fn = null;
    try std.testing.expect(questAccept(&w, 0, 51));
    questOnZombieKilled(&w, 0, 10, 10);
    try std.testing.expect(!questHasActive(&w, 0, 51));
}

test "phase advances only when all its objectives complete (shared phase)" {
    // Stock refreshQuestCompletion requires ALL non-optional objectives of the
    // phase (here ClearSleepers-style kills + a stay constraint). Killing the
    // zombies alone must not advance while the stay objective is incomplete.
    var w: World = .{};
    defer w.deinit();
    const objs = [_]quest.FlatObjective{
        .{ .phase = 1, .kind = .kill_zombies, .required = 2 },
        .{ .phase = 1, .kind = .stay_within, .required = 1 },
        .{ .phase = 2, .kind = .trader_interact, .required = 1 },
    };
    const phases = [_]quest.PhaseSpec{
        .{ .kind = .kill_zombies, .required = 2 },
        .{ .kind = .trader_interact, .required = 1 },
    };
    const defs = [_]quest.QuestDef{.{
        .id = 60,
        .kind = .kill_zombies,
        .name = "sh",
        .title = "SH",
        .target_count = 2,
        .reward_coin = 10,
        .objective_count = 3,
        .phases = &phases,
        .highest_phase = 2,
        .objectives = &objs,
    }};
    w.catalog = .{ .defs = &defs, .starter_id = 60, .source = .builtin };
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(questAccept(&w, 0, 60));
    // Both kills land, but the stay objective is still incomplete: the phase
    // holds (the old single-objective model would have advanced here).
    questOnZombieKilled(&w, 0, 10, 10);
    questOnZombieKilled(&w, 0, 20, 20);
    try std.testing.expectEqual(@as(u8, 1), questFindActive(&w, 0, 60).?.phase);
    try std.testing.expect(questHasActive(&w, 0, 60));
    // Satisfying the stay constraint completes the shared phase (def spot
    // (0,0); the def has no POI so the plain-radius check applies).
    questTickStayWithin(&w, 0, 0, 0);
    try std.testing.expectEqual(@as(u8, 2), questFindActive(&w, 0, 60).?.phase);
}

test "optional objectives never block the phase" {
    var w: World = .{};
    defer w.deinit();
    const objs = [_]quest.FlatObjective{
        .{ .phase = 1, .kind = .kill_zombies, .required = 1 },
        .{ .phase = 1, .kind = .fetch_item, .required = 5, .optional = true },
    };
    const phases = [_]quest.PhaseSpec{.{ .kind = .kill_zombies, .required = 1 }};
    const defs = [_]quest.QuestDef{.{
        .id = 61,
        .kind = .kill_zombies,
        .name = "op",
        .title = "OP",
        .target_count = 1,
        .reward_coin = 10,
        .objective_count = 2,
        .phases = &phases,
        .highest_phase = 1,
        .objectives = &objs,
    }};
    w.catalog = .{ .defs = &defs, .starter_id = 61, .source = .builtin };
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(questAccept(&w, 0, 61));
    // The optional fetch objective is untouched, yet the kill completes the quest.
    questOnZombieKilled(&w, 0, 10, 10);
    try std.testing.expect(!questHasActive(&w, 0, 61));
}

test "phase-0 objectives gate every phase" {
    var w: World = .{};
    defer w.deinit();
    const objs = [_]quest.FlatObjective{
        .{ .phase = 0, .kind = .craft, .required = 1 }, // always-active
        .{ .phase = 1, .kind = .kill_zombies, .required = 1 },
        .{ .phase = 2, .kind = .trader_interact, .required = 1 },
    };
    const phases = [_]quest.PhaseSpec{
        .{ .kind = .kill_zombies, .required = 1 },
        .{ .kind = .trader_interact, .required = 1 },
    };
    const defs = [_]quest.QuestDef{.{
        .id = 62,
        .kind = .kill_zombies,
        .name = "", // empty name: the craft hook's recipe-name filter must not
        // reject the event before it reaches the phase-0 craft objective
        .title = "P0",
        .target_count = 1,
        .reward_coin = 10,
        .objective_count = 3,
        .phases = &phases,
        .highest_phase = 2,
        .objectives = &objs,
    }};
    w.catalog = .{ .defs = &defs, .starter_id = 62, .source = .builtin };
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(questAccept(&w, 0, 62));
    // Phase 1's kill completes, but the always-active craft objective (phase 0)
    // is still incomplete: the phase must not advance.
    questOnZombieKilled(&w, 0, 10, 10);
    try std.testing.expectEqual(@as(u8, 1), questFindActive(&w, 0, 62).?.phase);
    // Crafting satisfies the always-active objective and the phase advances.
    questOnCraft(&w, 0, "sweep");
    try std.testing.expectEqual(@as(u8, 2), questFindActive(&w, 0, 62).?.phase);
}

test "ForcePhaseFinish objective fails the quest while incomplete" {
    var w: World = .{};
    defer w.deinit();
    const objs = [_]quest.FlatObjective{
        .{ .phase = 1, .kind = .kill_zombies, .required = 2 },
        .{ .phase = 1, .kind = .fetch_item, .required = 1, .force = true },
    };
    const phases = [_]quest.PhaseSpec{.{ .kind = .kill_zombies, .required = 2 }};
    const defs = [_]quest.QuestDef{.{
        .id = 63,
        .kind = .kill_zombies,
        .name = "fp",
        .title = "FP",
        .target_count = 2,
        .reward_coin = 10,
        .objective_count = 2,
        .phases = &phases,
        .highest_phase = 1,
        .objectives = &objs,
    }};
    w.catalog = .{ .defs = &defs, .starter_id = 63, .source = .builtin };
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(questAccept(&w, 0, 63));
    // The phase stays incomplete (fetch objective untouched) and a phase
    // objective carries ForcePhaseFinish: the quest fails (stock
    // refreshQuestCompletion IL_00F8-0104 CloseQuest(Failed)).
    questOnZombieKilled(&w, 0, 10, 10);
    var found_failed = false;
    for (&w.journal[0].slots) |*s2| {
        if (s2.def_id == 63 and s2.failed) found_failed = true;
    }
    try std.testing.expect(found_failed);
    try std.testing.expect(!questHasActive(&w, 0, 63));
}

test "SpawnGSEnemy action fires gamestage-scaled spawns on phase entry" {
    var w: World = .{};
    defer w.deinit();
    const phases = [_]quest.PhaseSpec{
        .{ .kind = .kill_zombies, .required = 1 },
        .{ .kind = .trader_interact, .required = 1 },
    };
    const actions = [_]quest.QuestActionSpec{.{ .kind = .spawn_gs_enemy, .phase = 2, .name = "SleeperGSList", .count_min = 1, .count_max = 2 }} ** quest.max_actions;
    const defs = [_]quest.QuestDef{.{
        .id = 64,
        .kind = .kill_zombies,
        .name = "gs",
        .title = "GS",
        .target_count = 1,
        .reward_coin = 10,
        .objective_count = 2,
        .phases = &phases,
        .highest_phase = 2,
        .objective_phases = &[_]u8{ 1, 2 },
        .actions = actions,
        .action_n = 1,
    }};
    w.catalog = .{ .defs = &defs, .starter_id = 64, .source = .builtin };
    w.poi_fn = &testPoiRect;
    // Spy: capture the fired spawn request.
    const Call = struct { fired: bool = false, list: []const u8 = "", min: u8 = 0, max: u8 = 0, px: f32 = 0, pz: f32 = 0 };
    var call = Call{};
    const spy = struct {
        fn f(ctx: ?*anyopaque, _: c.PoiRect, list: []const u8, min: u8, max: u8, px: f32, pz: f32) void {
            const c2: *Call = @ptrCast(@alignCast(ctx.?));
            c2.fired = true;
            c2.list = list;
            c2.min = min;
            c2.max = max;
            c2.px = px;
            c2.pz = pz;
        }
    }.f;
    w.quest_spawn_ctx = &call;
    w.quest_spawn_fn = spy;
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(questAccept(&w, 0, 64));
    try std.testing.expect(!call.fired); // phase 1 has no spawn action
    // Completing phase 1 enters phase 2, firing the phase-2 SpawnGSEnemy.
    questOnZombieKilled(&w, 0, 10, 10);
    try std.testing.expect(call.fired);
    try std.testing.expectEqualStrings("SleeperGSList", call.list);
    try std.testing.expectEqual(@as(u8, 1), call.min);
    try std.testing.expectEqual(@as(u8, 2), call.max);
    try std.testing.expectEqual(@as(f32, 0), call.px); // player spawn (0,0)
    try std.testing.expectEqual(@as(f32, 0), call.pz);
}

test "fetch_trader goto target stays the def spot, not a covering POI center" {
    var w: World = .{};
    defer w.deinit();
    const defs = [_]quest.QuestDef{.{
        .id = 41,
        .kind = .fetch_trader,
        .name = "ft",
        .title = "FT",
        .target_count = 1,
        .reward_coin = 20,
        .tx = 0,
        .ty = 70,
        .tz = 0,
        .objective_count = 2,
    }};
    w.catalog = .{ .defs = &defs, .starter_id = 41, .source = .builtin };
    // testPoiRect covers (0,0)-(64,64), so accept binds it even for a
    // fetch_trader (poiAt(d.tx, d.tz) runs for every kind).
    w.poi_fn = &testPoiRect;
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(questAccept(&w, 0, 41));
    const s = questFindActive(&w, 0, 41).?;
    try std.testing.expect(s.poi.valid());
    // Standing at the POI center (32,32) must not advance phase 1: the "go to
    // trader" target is the def spot, never a covering prefab center.
    questTickGoto(&w, 0, 32, 70, 32);
    try std.testing.expectEqual(@as(u8, 1), s.phase);
    // The def spot advances phase 1 -> phase 2 (ready to turn in).
    questTickGoto(&w, 0, 0, 70, 0);
    try std.testing.expectEqual(@as(u8, 2), s.phase);
    try std.testing.expect(s.ready_turn_in);
}

const rally_phases = [_]quest.PhaseSpec{
    .{ .kind = .rally, .required = 1 },
    .{ .kind = .kill_zombies, .required = 2 },
};

const rally_defs = [_]quest.QuestDef{.{
    .id = 22,
    .kind = .kill_zombies,
    .name = "rp",
    .title = "RP",
    .target_count = 2,
    .reward_coin = 30,
    .tx = 10,
    .ty = 70,
    .tz = 10,
    .objective_count = 2,
    .phases = &rally_phases,
    .highest_phase = 2,
    .objective_phases = &[_]u8{ 1, 2 },
}};

test "rally phase blocks until the marker is activated" {
    var w: World = .{};
    defer w.deinit();
    w.catalog = .{ .defs = &rally_defs, .starter_id = 22, .source = .builtin };
    w.poi_fn = &testPoiRect;
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(questAccept(&w, 0, 22));
    const s = questFindActive(&w, 0, 22).?;
    // With a POI rect the rally phase is real work: it must not be skipped.
    try std.testing.expectEqual(@as(u8, 1), s.phase);
    try std.testing.expect(s.poi.valid());
    // Kills on the rally phase do not advance it.
    questOnZombieKilled(&w, 0, 0, 0);
    try std.testing.expectEqual(@as(u8, 1), s.phase);
    // A foreign quest code is ignored.
    try std.testing.expect(!questOnRallyActivated(&w, 0, s.quest_code + 1));
    try std.testing.expectEqual(@as(u8, 1), s.phase);

    try std.testing.expect(questOnRallyActivated(&w, 0, s.quest_code));
    try std.testing.expect(s.rally_activated);
    try std.testing.expectEqual(@as(u8, 2), s.phase);
    // A repeat activation is refused and must not advance the kill phase.
    try std.testing.expect(!questOnRallyActivated(&w, 0, s.quest_code));
    try std.testing.expectEqual(@as(u8, 2), s.phase);
    try std.testing.expectEqual(@as(u16, 0), s.progress);
}

test "rally phase stays scaffolding without a poi rect" {
    var w: World = .{};
    defer w.deinit();
    w.catalog = .{ .defs = &rally_defs, .starter_id = 22, .source = .builtin };
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(questAccept(&w, 0, 22));
    const s = questFindActive(&w, 0, 22).?;
    // No POI hook → the client can never find a rally marker, so the phase
    // auto-completes exactly as it did before rally objectives existed.
    try std.testing.expectEqual(@as(u8, 2), s.phase);
    try std.testing.expect(!s.poi.valid());
    questOnZombieKilled(&w, 0, 0, 0);
    questOnZombieKilled(&w, 0, 0, 0);
    try std.testing.expect(!questHasActive(&w, 0, 22));
}

test "poi lockout reports quest lock and other players inside" {
    var w: World = .{};
    defer w.deinit();
    w.catalog = .{ .defs = &rally_defs, .starter_id = 22, .source = .builtin };
    w.poi_fn = &testPoiRect;
    const a_id = w.spawnPlayer(5, 70, 5, 0).?;
    try std.testing.expectEqual(poi_lock.LockReason.none, questCheckPoiLockout(&w, a_id, 10, 10).reason);

    // Another player standing in the POI blocks the reset.
    const b_id = w.spawnPlayer(20, 70, 20, 1).?;
    const b = w.slotOfNetId(b_id).?;
    try std.testing.expectEqual(poi_lock.LockReason.player_inside, questCheckPoiLockout(&w, a_id, 10, 10).reason);
    w.transform[b].x = 500;
    w.transform[b].z = 500;
    try std.testing.expectEqual(poi_lock.LockReason.none, questCheckPoiLockout(&w, a_id, 10, 10).reason);

    // A live quest lock wins over everything and carries LockedOutUntil.
    questPoiLock(&w, b_id, 10, 10);
    const locked = questCheckPoiLockout(&w, a_id, 10, 10);
    try std.testing.expectEqual(poi_lock.LockReason.quest_lock, locked.reason);
    try std.testing.expectEqual(@as(u64, 0), locked.extra_data);
    questPoiUnlock(&w, b_id, 10, 10);
    // Still inside the unlock grace window.
    try std.testing.expectEqual(poi_lock.LockReason.quest_lock, questCheckPoiLockout(&w, a_id, 10, 10).reason);
}

test "poi lockout exempts a party member inside the POI" {
    var w: World = .{};
    defer w.deinit();
    w.catalog = .{ .defs = &rally_defs, .starter_id = 22, .source = .builtin };
    w.poi_fn = &testPoiRect;
    // Hook: entity ids 100 and 101 are in one party; everyone else is not.
    const Ctx = struct {
        fn same(ctx: ?*anyopaque, a: i32, b: i32) bool {
            _ = ctx;
            const in_party = (a == 100 or a == 101) and (b == 100 or b == 101);
            return a != b and in_party;
        }
    };
    w.party_same_ctx = null;
    w.party_same_fn = &Ctx.same;
    const a_id = w.spawnPlayer(5, 70, 5, 0).?;
    w.network_id[w.slotOfNetId(a_id).?].id = 100;
    // Party mate inside the POI does not block A's rally.
    const b_id = w.spawnPlayer(20, 70, 20, 1).?;
    w.network_id[w.slotOfNetId(b_id).?].id = 101;
    try std.testing.expectEqual(poi_lock.LockReason.none, questCheckPoiLockout(&w, a_id, 10, 10).reason);
    // A non-party player (fresh id 102) still blocks.
    const c_id = w.spawnPlayer(20, 70, 20, 2).?;
    w.network_id[w.slotOfNetId(c_id).?].id = 102;
    try std.testing.expectEqual(poi_lock.LockReason.player_inside, questCheckPoiLockout(&w, a_id, 10, 10).reason);
}

test "quest turn_in needs trader open" {
    var w: World = .{};
    defer w.deinit();
    const defs = [_]quest.QuestDef{.{
        .id = 9,
        .kind = .kill_zombies,
        .name = "t1",
        .title = "T",
        .target_count = 2,
        .reward_coin = 40,
        .turn_in = true,
    }};
    w.catalog = .{ .defs = &defs, .starter_id = 9, .source = .builtin };
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(questAccept(&w, 0, 9));
    questOnZombieKilled(&w, 0, 0, 0);
    questOnZombieKilled(&w, 0, 0, 0);
    try std.testing.expect(questHasActive(&w, 0, 9));
    try std.testing.expect(questFindActive(&w, 0, 9).?.ready_turn_in);
    questOnTraderOpen(&w, 0);
    try std.testing.expect(!questHasActive(&w, 0, 9));
    drainQuestCoins(&w, 0);
    try std.testing.expectEqual(@as(u32, 40), questCoins(&w, 0));
}

test "full inventory preserves nearby loot bag" {
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.playerByPeer(0).?;
    for (w.inventory[ps].slots[0..c.inv_equip_start], 0..) |*slot, i| {
        slot.* = .{ .item_id = @intCast(i + 100), .count = 60000 };
    }
    const bag_id = w.spawnLootBag(1, 70, 1, 1, 5).?;

    try std.testing.expectEqual(@as(u32, 0), collectLootNear(&w, 0, 8));
    try std.testing.expect(w.slotOfNetId(bag_id) != null);
}

test "verdict-scaled buy price cannot wrap the u32 cost into a free purchase" {
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    const trader_id = w.spawnTrader("Trader", 1, 70, 1, 0, 50_000).?;
    const ps = w.playerByPeer(0).?;
    const ts = w.slotOfNetId(trader_id).?;
    w.wallet[ps].coins = 100_000;
    w.trader_stock[ts].entries[0] = .{ .item = 99, .count = 10, .price = 65535 };
    // Percent 3276851 scales the unit price to 65535*3276851/100 =
    // 2147484302; times qty 2 that is 4294968604, which overflows u32 into
    // a wrapped "cost" of 1308 dukes. The widened math must refuse the buy.
    w.trade_price_verdict_fn = struct {
        fn f(_: ?*anyopaque, _: i32, _: u16, _: u32) i32 {
            return 3_276_851;
        }
    }.f;
    const wallet_before = w.wallet[ps].coins;
    try std.testing.expect(!trade(&w, 0, trader_id, 99, 2, 0, 6));
    try std.testing.expectEqual(wallet_before, w.wallet[ps].coins);
    try std.testing.expectEqual(@as(u16, 10), w.trader_stock[ts].entries[0].count);

    // A moderate percent still prices normally: 65535 * 200% = 131070, over
    // the u16 wire bound, so refused; 100 * 200% = 200/unit sells fine.
    w.trade_price_verdict_fn = struct {
        fn f(_: ?*anyopaque, _: i32, _: u16, _: u32) i32 {
            return 200;
        }
    }.f;
    try std.testing.expect(!trade(&w, 0, trader_id, 99, 2, 0, 6));
    w.trader_stock[ts].entries[0] = .{ .item = 99, .count = 10, .price = 100 };
    try std.testing.expect(trade(&w, 0, trader_id, 99, 2, 0, 6));
    try std.testing.expectEqual(@as(u32, 100_000 - 400), w.wallet[ps].coins);
    w.trade_price_verdict_fn = null;
}

test "huge sell hook price clamps instead of trapping the float cast or gain multiply" {
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    const trader_id = w.spawnTrader("Trader", 1, 70, 1, 0, 500).?;
    const ps = w.playerByPeer(0).?;
    const ts = w.slotOfNetId(trader_id).?;
    w.inventory[ps].slots[0] = .{ .item_id = 99, .count = 100, .quality = 1 };
    w.trader_stock[ts].entries[0] = .{ .item = 99, .count = 2, .price = 10, .sell = 100 };
    // A sell-price hook at u32 max previously overflowed the unit * qty
    // gain multiply; the widened math must fail closed as a refused sale
    // (and the cast clamp covers a modded quality_mod pushing past u32).
    w.sell_price_fn = struct {
        fn f(_: ?*anyopaque, _: u16, _: u16) u32 {
            return std.math.maxInt(u32);
        }
    }.f;
    try std.testing.expect(!trade(&w, 0, trader_id, 99, 4, 1, 6));
    try std.testing.expectEqual(@as(u16, 100), w.inventory[ps].slots[0].count);
    try std.testing.expectEqual(@as(i32, 500), w.trader_stock[ts].wallet);
    w.sell_price_fn = null;
}

test "failed trader buy leaves wallet stock and inventory unchanged" {
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    const trader_id = w.spawnTrader("Trader", 1, 70, 1, 0, 50_000).?;
    const ps = w.playerByPeer(0).?;
    const ts = w.slotOfNetId(trader_id).?;
    for (w.inventory[ps].slots[0..c.inv_equip_start], 0..) |*slot, i| {
        slot.* = .{ .item_id = @intCast(i + 100), .count = 60000 };
    }
    w.wallet[ps].coins = 100;
    w.trader_stock[ts].entries[0] = .{ .item = 99, .count = 2, .price = 10 };
    const inventory_before = w.inventory[ps];

    try std.testing.expect(!trade(&w, 0, trader_id, 99, 1, 0, 6));
    try std.testing.expectEqual(@as(u32, 100), w.wallet[ps].coins);
    try std.testing.expectEqual(@as(u16, 2), w.trader_stock[ts].entries[0].count);
    try std.testing.expectEqualSlices(c.InvSlot, &inventory_before.slots, &w.inventory[ps].slots);
}

test "trader wallet debits on sell, credits on buy and refuses overdraft" {
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    // Trader starts with 500 dukes; the stock entry buys goods at 100 each.
    const trader_id = w.spawnTrader("Trader", 1, 70, 1, 0, 500).?;
    const ps = w.playerByPeer(0).?;
    const ts = w.slotOfNetId(trader_id).?;
    for (w.inventory[ps].slots[0..c.inv_equip_start], 0..) |*slot, i| {
        slot.* = .{ .item_id = @intCast(i + 100), .count = 60000 };
    }
    w.inventory[ps].slots[0] = .{ .item_id = 99, .count = 100, .quality = 1 };
    w.inventory[ps].slots[c.inv_equip_start - 1] = .{}; // free slot for coin payout
    w.trader_stock[ts].entries[0] = .{ .item = 99, .count = 2, .price = 10, .sell = 100 };
    try std.testing.expectEqual(@as(i32, 500), w.trader_stock[ts].wallet);

    // Sell 4 at 100 each: 400 of the trader's 500 dukes go to the player.
    try std.testing.expect(trade(&w, 0, trader_id, 99, 4, 1, 6));
    try std.testing.expectEqual(@as(i32, 100), w.trader_stock[ts].wallet);
    try std.testing.expectEqual(@as(u32, 400), w.wallet[ps].coins);

    // A 5th sale spends the last 100 dukes exactly (gain == wallet is legal).
    try std.testing.expect(trade(&w, 0, trader_id, 99, 1, 1, 6));
    try std.testing.expectEqual(@as(i32, 0), w.trader_stock[ts].wallet);
    try std.testing.expectEqual(@as(u32, 500), w.wallet[ps].coins);

    // With the pool empty the trader refuses to buy: nothing moves.
    const coins_before = w.wallet[ps].coins;
    const wallet_before = w.trader_stock[ts].wallet;
    const inv_before = w.inventory[ps];
    try std.testing.expect(!trade(&w, 0, trader_id, 99, 1, 1, 6));
    try std.testing.expectEqual(wallet_before, w.trader_stock[ts].wallet);
    try std.testing.expectEqual(coins_before, w.wallet[ps].coins);
    try std.testing.expectEqualSlices(c.InvSlot, &inv_before.slots, &w.inventory[ps].slots);

    // Buying from the trader credits its money pool back up.
    try std.testing.expect(trade(&w, 0, trader_id, 99, 1, 0, 6));
    try std.testing.expectEqual(@as(i32, 10), w.trader_stock[ts].wallet);

    // Restock regenerates the pool toward the spawn default.
    w.trader_stock[ts].wallet = 0;
    traderRestock(&w);
    try std.testing.expectEqual(@as(i32, 500), w.trader_stock[ts].wallet);
}

test "trade demand markup: buy spikes +100, sell eases -4, restock resets" {
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    const trader_id = w.spawnTrader("Trader", 1, 70, 1, 0, 500).?;
    const ps = w.playerByPeer(0).?;
    const ts = w.slotOfNetId(trader_id).?;
    // Default first entry: item 2, price 5. Fund the wallet; the player's
    // inventory starts empty so deposits find a free slot.
    const item = w.trader_stock[ts].entries[0].item;
    w.wallet[ps].coins = 1000;
    try std.testing.expectEqual(@as(i8, 0), w.trader_stock[ts].entries[0].markup);
    // A buy spikes demand to +100 (Entry.IncreaseMarkup).
    try std.testing.expect(trade(&w, 0, trader_id, item, 1, 0, 6));
    try std.testing.expectEqual(@as(i8, 100), w.trader_stock[ts].entries[0].markup);
    // A sell eases demand by 4 (Entry.DecreaseMarkup), saturating at i8 min.
    try std.testing.expect(trade(&w, 0, trader_id, item, 1, 1, 6));
    try std.testing.expectEqual(@as(i8, 96), w.trader_stock[ts].entries[0].markup);
    // A restock rebuilds fresh entries: markup back to neutral.
    traderRestock(&w);
    try std.testing.expectEqual(@as(i8, 0), w.trader_stock[ts].entries[0].markup);
}

test "traderRestock honors per-trader reset_interval (never vs every N days)" {
    var w: World = .{};
    defer w.deinit();
    const never_id = w.spawnTrader("TraderNever", 100, 70, 100, 0, 1000).?;
    const three_id = w.spawnTrader("TraderThree", 200, 70, 200, 0, 1000).?;
    const sn = w.slotOfNetId(never_id).?;
    const st = w.slotOfNetId(three_id).?;
    // Counts < 50 are topped up by a restock; watch entry 0 (default 20).
    w.trader_stock[sn].entries[0].count = 1;
    w.trader_stock[st].entries[0].count = 1;
    w.trader_stock[sn].reset_interval = -1; // never
    w.trader_stock[st].reset_interval = 3; // every 3 days

    // Day 1, spawn day: neither has reached a window (never never does).
    w.director.clock.day = 1;
    w.trader_stock[sn].wallet = 0;
    w.trader_stock[st].wallet = 0;
    traderRestock(&w);
    try std.testing.expectEqual(@as(i32, 0), w.trader_stock[sn].wallet);
    try std.testing.expectEqual(@as(i32, 0), w.trader_stock[st].wallet);
    try std.testing.expectEqual(@as(u16, 1), w.trader_stock[st].entries[0].count);

    // Day 4: last=0 + 3 opens the window for the 3-day trader only.
    w.director.clock.day = 4;
    traderRestock(&w);
    try std.testing.expectEqual(@as(i32, 0), w.trader_stock[sn].wallet);
    try std.testing.expectEqual(@as(i32, 1000), w.trader_stock[st].wallet);
    try std.testing.expectEqual(@as(u16, 11), w.trader_stock[st].entries[0].count);
    try std.testing.expectEqual(@as(u32, 4), w.trader_stock[st].last_restock_day);

    // Day 5: next window is day 7, so the drained pool stays drained.
    w.trader_stock[st].wallet = 0;
    w.trader_stock[st].entries[0].count = 1;
    w.director.clock.day = 5;
    traderRestock(&w);
    try std.testing.expectEqual(@as(i32, 0), w.trader_stock[st].wallet);
    try std.testing.expectEqual(@as(u16, 1), w.trader_stock[st].entries[0].count);

    // Day 7: window reopens.
    w.director.clock.day = 7;
    traderRestock(&w);
    try std.testing.expectEqual(@as(i32, 1000), w.trader_stock[st].wallet);
}

test "traderRestock honors the configured cap and refill" {
    var w: World = .{};
    defer w.deinit();
    const tid = w.spawnTrader("TraderCfg", 100, 70, 100, 0, 1000).?;
    const ts = w.slotOfNetId(tid).?;
    w.trader_restock_cap = 200;
    w.trader_restock_refill = 25;
    w.trader_stock[ts].reset_interval = 0; // daily
    w.trader_stock[ts].entries[0].count = 1;
    w.director.clock.day = 1;
    traderRestock(&w);
    // 1 + 25 = 26, not the default +10.
    try std.testing.expectEqual(@as(u16, 26), w.trader_stock[ts].entries[0].count);
    // Near the cap the refill clamps so the count never overshoots.
    w.director.clock.day = 2;
    w.trader_stock[ts].entries[0].count = 190;
    traderRestock(&w);
    try std.testing.expectEqual(@as(u16, 200), w.trader_stock[ts].entries[0].count);
    w.director.clock.day = 3;
    traderRestock(&w);
    try std.testing.expectEqual(@as(u16, 200), w.trader_stock[ts].entries[0].count);
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
    dmg_fp[ps] = 500; // 5.0 hp
    try std.testing.expectEqual(@as(u32, 1), applyDeferredDamage(&w, dmg_fp[0..]));
    try std.testing.expectEqual(@as(f32, 0), w.health[ps].hp);
    try std.testing.expect(w.alive[ps]);
    try std.testing.expect(w.dirty[ps].hp);
    // A corpse takes no further hits, so nothing re-dirties it.
    w.dirty[ps].hp = false;
    try std.testing.expectEqual(@as(u32, 0), applyDeferredDamage(&w, dmg_fp[0..]));
    try std.testing.expect(!w.dirty[ps].hp);
}

test "GameDifficulty damage scale: AI->player x IncomingDamage at the deferred choke" {
    // RE `ItemActionAttack.difficultyModifier` (combat-damage.md): a server
    // (AI) attacker vs a client entity scales by IncomingDamageModifier,
    // `round(strength x modifier)`; PvP and AI-vs-AI leave strength
    // unchanged. The default world is Adventurer (difficulty 1 — the stock
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
    dmg_fp[ps] = 800; // 8.0 hp
    try std.testing.expectEqual(@as(u32, 1), applyDeferredDamage(&w, dmg_fp[0..]));
    try std.testing.expectEqual(@as(f32, 94.0), w.health[ps].hp);
    // Config wins: an operator raising the Adventurer incoming scale lifts it.
    w.rules.difficulty.incoming_damage_1 = 1.25; // difficulty 1 = Adventurer
    w.health[ps].hp = 100;
    try std.testing.expectEqual(@as(u32, 1), applyDeferredDamage(&w, dmg_fp[0..]));
    try std.testing.expectEqual(@as(f32, 90.0), w.health[ps].hp); // 8 x 1.25 = 10
    // AI -> AI (turret fire on a zombie) is unchanged by the difficulty scale.
    const z = w.spawnZombie(1, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    w.health[zs].hp = 100;
    var zfp: [max_entities]u32 = .{0} ** max_entities;
    zfp[zs] = 800;
    try std.testing.expectEqual(@as(u32, 1), applyDeferredDamage(&w, zfp[0..]));
    try std.testing.expectEqual(@as(f32, 92.0), w.health[zs].hp); // 8.0 flat
}
test "multi-seat: four riders fill a truck, the fifth is refused" {
    var w: World = .{};
    defer w.deinit();
    const vid = w.spawnVehicleEx(.four_by_four, 0, 70, 0, 300, 14, 4).?;
    const vs = w.slotOfNetId(vid).?;
    var riders: [5]i32 = undefined;
    for (&riders, 0..) |*r, i| r.* = w.spawnPlayer(1, 70, 0, @intCast(i)).?;
    for (riders[0..4], 0..) |r, i| {
        try std.testing.expectEqual(@as(?u8, @intCast(i)), vehicleAttach(&w, vs, r, seat_any));
    }
    try std.testing.expectEqual(@as(?u8, null), vehicleAttach(&w, vs, riders[4], seat_any));
    try std.testing.expectEqual(@as(u8, 0), w.vehicle[vs].freeSeats());
}

test "multi-seat: passenger rides the hull and cannot steer" {
    var w: World = .{};
    defer w.deinit();
    w.ground_fn = &testGround;
    const vid = w.spawnVehicleEx(.four_by_four, 0, 70, 0, 300, 14, 4).?;
    const vs = w.slotOfNetId(vid).?;
    const drv = w.spawnPlayer(0, 70, 0, 0).?;
    const pax = w.spawnPlayer(1, 70, 0, 1).?;
    try std.testing.expectEqual(@as(?u8, 0), vehicleAttach(&w, vs, drv, seat_any));
    try std.testing.expectEqual(@as(?u8, 1), vehicleAttach(&w, vs, pax, 1));
    const pax_slot = w.slotOfNetId(pax).?;

    vehicleControl(&w, vs, 1.0, 0.0, 0.05);
    var t: f32 = 0;
    while (t < 1.0) : (t += 0.05) {
        vehicleTickHeld(&w, 0.05);
        systemVehicles(&w, 0.05);
    }
    try std.testing.expect(w.vehicle[vs].speed > 0);
    try std.testing.expectApproxEqAbs(w.transform[vs].z, w.transform[pax_slot].z, 0.001);
    try std.testing.expectApproxEqAbs(w.transform[vs].y + 1, w.transform[pax_slot].y, 0.001);
    try std.testing.expectEqual(drv, w.vehicle[vs].driverNetId());
}

test "multi-seat: out-of-range seat request is refused" {
    var w: World = .{};
    defer w.deinit();
    const vid = w.spawnVehicleEx(.gyrocopter, 0, 70, 0, 250, 20, 2).?;
    const vs = w.slotOfNetId(vid).?;
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    try std.testing.expectEqual(@as(?u8, null), vehicleAttach(&w, vs, p, 3));
    try std.testing.expectEqual(@as(?u8, null), vehicleAttach(&w, vs, p, 2));
    try std.testing.expectEqual(@as(?u8, 1), vehicleAttach(&w, vs, p, 1));
}

test "multi-seat: re-attaching with -1 keeps the held seat" {
    var w: World = .{};
    defer w.deinit();
    const vid = w.spawnVehicleEx(.four_by_four, 0, 70, 0, 300, 14, 4).?;
    const vs = w.slotOfNetId(vid).?;
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    try std.testing.expectEqual(@as(?u8, 2), vehicleAttach(&w, vs, p, 2));
    try std.testing.expectEqual(@as(?u8, 2), vehicleAttach(&w, vs, p, seat_any));
    try std.testing.expectEqual(@as(?u8, 2), vehicleAttach(&w, vs, p, 2));
    try std.testing.expectEqual(@as(u8, 3), w.vehicle[vs].freeSeats());
}

test "multi-seat: an occupied seat is never stolen from its rider" {
    var w: World = .{};
    defer w.deinit();
    const vid = w.spawnVehicleEx(.four_by_four, 0, 70, 0, 300, 14, 4).?;
    const vs = w.slotOfNetId(vid).?;
    const a = w.spawnPlayer(0, 70, 0, 0).?;
    const b = w.spawnPlayer(1, 70, 0, 1).?;
    try std.testing.expectEqual(@as(?u8, 0), vehicleAttach(&w, vs, a, 0));
    try std.testing.expectEqual(@as(?u8, null), vehicleAttach(&w, vs, b, 0));
    try std.testing.expectEqual(a, w.vehicle[vs].driverNetId());
}

test "multi-seat: only the driver leaving stops the hull" {
    var w: World = .{};
    defer w.deinit();
    const vid = w.spawnVehicleEx(.four_by_four, 0, 70, 0, 300, 14, 4).?;
    const vs = w.slotOfNetId(vid).?;
    const drv = w.spawnPlayer(0, 70, 0, 0).?;
    const pax = w.spawnPlayer(1, 70, 0, 1).?;
    _ = vehicleAttach(&w, vs, drv, seat_any).?;
    _ = vehicleAttach(&w, vs, pax, 2).?;
    vehicleControl(&w, vs, 1.0, 0.0, 0.5);
    try std.testing.expect(w.vehicle[vs].speed > 0);

    const pax_out = vehicleDetach(&w, pax).?;
    try std.testing.expectEqual(vid, pax_out.vehicle_net);
    try std.testing.expectEqual(@as(u8, 2), pax_out.seat);
    try std.testing.expect(w.vehicle[vs].speed > 0);

    const drv_out = vehicleDetach(&w, drv).?;
    try std.testing.expectEqual(@as(u8, 0), drv_out.seat);
    try std.testing.expectEqual(@as(f32, 0), w.vehicle[vs].speed);
    try std.testing.expectEqual(@as(u8, 4), w.vehicle[vs].freeSeats());
}

test "multi-seat: detaching an unseated player reports nothing" {
    var w: World = .{};
    defer w.deinit();
    const vid = w.spawnVehicleEx(.minibike, 0, 70, 0, 200, 12, 1).?;
    const vs = w.slotOfNetId(vid).?;
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    try std.testing.expectEqual(@as(?Dismount, null), vehicleDetach(&w, p));
    // A free seat is -1; the sentinel must never resolve to a rider.
    try std.testing.expectEqual(@as(?Dismount, null), vehicleDetach(&w, -1));
    try std.testing.expectEqual(@as(?u8, null), vehicleFindSeat(&w, vs, -1));
}

test "multi-seat: mounting a second vehicle vacates the first" {
    var w: World = .{};
    defer w.deinit();
    const a_id = w.spawnVehicleEx(.four_by_four, 0, 70, 0, 300, 14, 4).?;
    const b_id = w.spawnVehicleEx(.four_by_four, 2, 70, 0, 300, 14, 4).?;
    const a_slot = w.slotOfNetId(a_id).?;
    const b_slot = w.slotOfNetId(b_id).?;
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    try std.testing.expectEqual(@as(?u8, 1), vehicleAttach(&w, a_slot, p, 1));
    try std.testing.expectEqual(@as(?u8, 0), vehicleAttach(&w, b_slot, p, seat_any));
    try std.testing.expectEqual(@as(u8, 4), w.vehicle[a_slot].freeSeats());
    try std.testing.expectEqual(b_slot, vehicleOfRider(&w, p).?);
}

test "multi-seat: spawn clamps a nonsense seat count into range" {
    var w: World = .{};
    defer w.deinit();
    const zero = w.spawnVehicleEx(.bicycle, 0, 70, 0, 200, 6, 0).?;
    const huge = w.spawnVehicleEx(.bicycle, 4, 70, 0, 200, 6, 255).?;
    try std.testing.expectEqual(@as(u8, 1), w.vehicle[w.slotOfNetId(zero).?].seat_count);
    try std.testing.expectEqual(@as(u8, c.max_seats), w.vehicle[w.slotOfNetId(huge).?].seat_count);
}

test "multi-seat: mounting out of reach is refused" {
    var w: World = .{};
    defer w.deinit();
    const vid = w.spawnVehicleEx(.four_by_four, 0, 70, 0, 300, 14, 4).?;
    const vs = w.slotOfNetId(vid).?;
    const p = w.spawnPlayer(40, 70, 0, 0).?;
    try std.testing.expectEqual(@as(?u8, null), vehicleAttach(&w, vs, p, seat_any));
    try std.testing.expectEqual(@as(?u8, null), vehicleAttach(&w, vs, p, 2));
}

test "multi-seat: a destroyed rider releases its seat on the next tick" {
    var w: World = .{};
    defer w.deinit();
    w.ground_fn = &testGround;
    const vid = w.spawnVehicleEx(.four_by_four, 0, 70, 0, 300, 14, 4).?;
    const vs = w.slotOfNetId(vid).?;
    const drv = w.spawnPlayer(0, 70, 0, 0).?;
    const pax = w.spawnPlayer(1, 70, 0, 1).?;
    _ = vehicleAttach(&w, vs, drv, seat_any).?;
    _ = vehicleAttach(&w, vs, pax, seat_any).?;
    vehicleControl(&w, vs, 1.0, 0.0, 0.5);

    w.destroy(w.slotOfNetId(pax).?);
    systemVehicles(&w, 0.05);
    try std.testing.expectEqual(@as(u8, 3), w.vehicle[vs].freeSeats());
    try std.testing.expect(w.vehicle[vs].speed > 0); // driver kept the hull moving

    w.destroy(w.slotOfNetId(drv).?);
    systemVehicles(&w, 0.05);
    try std.testing.expectEqual(@as(u8, 4), w.vehicle[vs].freeSeats());
    try std.testing.expectEqual(@as(f32, 0), w.vehicle[vs].speed);
}

test "unlock_poi action releases the quest POI lock on phase entry" {
    // A phase-2 UnlockPOI action (stock QuestActionUnlockPOI, asm.il
    // 1390421-1390429): locking the quest POI then advancing into phase 2 must
    // release the lock, not leave the POI reserved forever.
    const unlock_phases = [_]quest.PhaseSpec{
        .{ .kind = .kill_zombies, .required = 1 },
        .{ .kind = .kill_zombies, .required = 1 },
    };
    const unlock_actions = [_]quest.QuestActionSpec{
        .{ .kind = .unlock_poi, .phase = 2 },
        .{},
        .{},
        .{},
        .{},
        .{},
        .{},
        .{},
    };
    const defs = [_]quest.QuestDef{.{
        .id = 31,
        .kind = .kill_zombies,
        .name = "unlocker",
        .title = "U",
        .target_count = 2,
        .reward_coin = 10,
        .tx = 10,
        .ty = 70,
        .tz = 10,
        .objective_count = 2,
        .phases = &unlock_phases,
        .highest_phase = 2,
        .objective_phases = &[_]u8{ 1, 2 },
        .actions = unlock_actions,
        .action_n = 1,
    }};
    var w: World = .{};
    defer w.deinit();
    w.catalog = .{ .defs = &defs, .starter_id = 31, .source = .builtin };
    w.poi_fn = &testPoiRect;
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    try std.testing.expect(questAccept(&w, 0, 31));
    const s = questFindActive(&w, 0, 31).?;
    try std.testing.expect(s.poi.valid());
    questPoiLock(&w, p, s.poi.x, s.poi.z);
    try std.testing.expectEqual(poi_lock.LockReason.quest_lock, questCheckPoiLockout(&w, p, s.poi.x, s.poi.z).reason);
    // One kill advances to phase 2, firing the UnlockPOI action. The lock then
    // drops its quester and enters the stock grace window (last quester out
    // starts `unlock_grace`), so `check` still reports quest_lock briefly.
    questOnZombieKilled(&w, 0, 0, 0);
    try std.testing.expectEqual(@as(u8, 2), s.phase);
    var idx: ?usize = null;
    for (w.poi_locks.entries[0..w.poi_locks.n], 0..) |*e, i| {
        if (e.rect.containsXZ(s.poi.x, s.poi.z)) {
            idx = i;
            break;
        }
    }
    try std.testing.expect(idx != null);
    try std.testing.expectEqual(@as(u8, 0), w.poi_locks.entries[idx.?].quester_n);
    try std.testing.expect(!w.poi_locks.entries[idx.?].locked);
}

/// A client-raised objective event (NetPackageQuestObjectiveUpdate) advanced
/// the objective named by `kind` on the active quest with this quest code.
/// Stock: treasure finish / block activation events mirror the client's own
/// quest progress into the server journal so it can persist and coordinate.
pub fn questObjectiveEvent(w: *World, peer_slot: usize, quest_code: i32, kind: quest.PhaseKind) bool {
    const s = questFindByCode(w, peer_slot, quest_code) orelse return false;
    const ps = w.playerByPeer(peer_slot) orelse return false;
    const d = w.catalog.byId(s.def_id) orelse return false;
    bumpPhase(w, ps, s, d, kind, 1);
    return true;
}

test "blood-moon-dead players are skipped as AI targets but kept for despawn" {
    var w: World = .{};
    defer w.deinit();
    // spawnPlayer(x, y, z, peer_slot): second player must use peer 1, not peer 0
    // (peer 0 would replace the first body under the one-entity-per-peer rule).
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    _ = w.spawnPlayer(1, 70, 5, 1).?;
    const ps = w.playerByPeer(1).?;
    w.player[ps].is_blood_moon_dead = true; // died during the horde
    var snaps: [64]PlayerSnap = undefined;
    const ai_n = snapshotPlayers(&w, &snaps, true);
    try std.testing.expectEqual(@as(usize, 1), ai_n);
    const des_n = snapshotPlayers(&w, &snaps, false);
    try std.testing.expectEqual(@as(usize, 2), des_n);
}

test "completed starter quest is not granted again on the next login" {
    var w: World = .{};
    defer w.deinit();
    const defs = [_]quest.QuestDef{.{
        .id = 22,
        .kind = .fetch_item,
        .title = "Starter",
        .target_count = 1,
        .reward_coin = 10,
    }};
    w.catalog = .{ .defs = &defs, .starter_id = 22, .source = .builtin };
    _ = w.spawnPlayer(0, 70, 0, 0);
    // First login grants the starter.
    try std.testing.expect(questAcceptStarter(&w, 0));
    try std.testing.expect(questHasActive(&w, 0, 22));
    // The player completes it; a second login must not re-grant it (hasActive
    // only matches active slots, so the guard scans completed slots too).
    const ps = w.playerByPeer(0).?;
    for (&w.journal[ps].slots) |*s| {
        if (s.def_id == 22 and s.active) {
            s.completed = true;
            s.active = false;
            break;
        }
    }
    try std.testing.expect(!questAcceptStarter(&w, 0));
    // A fresh player on a different peer still gets the starter.
    _ = w.spawnPlayer(0, 70, 5, 1);
    try std.testing.expect(questAcceptStarter(&w, 1));
}

test "sense range comes from entityclasses SightRange, not the global rule" {
    var w: World = .{ .rules = .{ .ai = .{ .sense_dist_sq = 48.0 * 48.0 } } };
    // A class with no SightRange keeps the Rules floor.
    try std.testing.expectEqual(@as(f32, 48.0 * 48.0), senseDistSq(&w, 0));
    // A class that ships one uses it: stock zombies sit at 27-40 m, all well
    // under the floor, so this is a real behaviour change per class.
    w.class_table[1].sight_range = 30.0;
    w.class_id[0] = .{ .id = 1 };
    try std.testing.expectEqual(@as(f32, 900.0), senseDistSq(&w, 0));
    // The per-entity layer (A35 def spawns) beats the class_table row: a feral
    // resolved outside the table senses at its own SightRange, not the row.
    w.class_id[0].sight_range = 40.0;
    try std.testing.expectEqual(@as(f32, 1600.0), senseDistSq(&w, 0));
}

test "AI senses: LOS and view cone gate sight; hearing ignores walls" {
    // Stock CanEntityBeSeen + PlayerStealth (RE entity-ai.md): a player is
    // sensed when heard (within hear_range, walls pass sound) or seen (within
    // sense range, inside the view cone, block-LOS clear). A wall between the
    // zombie and a far player must break sight; a near player is still heard.
    var w: World = .{ .rules = .{ .ai = .{ .sense_dist_sq = 48 * 48 } } };
    defer w.deinit();
    const Wall = struct {
        fn solid(_: ?*anyopaque, x: i32, y: i32, z: i32) bool {
            return x == 10 and y >= 70 and y <= 71 and z == 0;
        }
    };
    w.solid_ctx = null;
    w.solid_fn = &Wall.solid;
    // Zombie at origin facing +x (yaw 90 = atan2(1, 0)).
    const zyaw: f32 = 90.0;
    // Far player (20 m, beyond hear 10) with a wall at x=10: not sensed.
    // light_level 200 (fully lit) so the CanSeeStealth gate stays open.
    try std.testing.expect(!canSensePlayer(&w, 0, 0, 70, 0, zyaw, 20, 70, 0, 10.0, 200.0));
    // Same distance, no wall (y shifted so the wall cell is not on the ray):
    // sensed - LOS clear, in the cone.
    try std.testing.expect(canSensePlayer(&w, 0, 0, 70, 0, zyaw, 20, 70, 4, 10.0, 200.0));
    // Near player (5 m, within hear) with a wall: still sensed (hearing).
    try std.testing.expect(canSensePlayer(&w, 0, 0, 70, 0, zyaw, 5, 70, 0, 10.0, 200.0));
    // Behind the zombie (yaw 90 faces +x; player at -x): out of the cone at
    // 20 m, not sensed even without a wall.
    try std.testing.expect(!canSensePlayer(&w, 0, 0, 70, 0, zyaw, -20, 70, 0, 10.0, 200.0));
    // Beyond the sense range: never sensed.
    try std.testing.expect(!canSensePlayer(&w, 0, 0, 70, 0, zyaw, 100, 70, 0, 10.0, 200.0));
}

test "AI senses: per-class MaxViewAngle narrows the cone" {
    // RE entity-ai.md: stock EntityAlive cctor defaults maxViewAngle to 180
    // (half 90 = only strictly-behind is out of cone); entityclasses.xml
    // MaxViewAngle narrows it per class, and the sense gate halves it like
    // IsInFrontOfMe. A 30-degree class (half 15) must not sense a target 30
    // degrees off-axis that the stock-default 180 would.
    var w: World = .{ .rules = .{ .ai = .{ .sense_dist_sq = 48 * 48 } } };
    defer w.deinit();
    const zyaw: f32 = 90.0; // faces +x.
    const off30 = std.math.pi / 6.0; // 30 degrees off-axis.
    // Default class table (rules floor 90 half): a player 30 deg off-axis at
    // 20 m IS sensed (dot 0.866 > cos 90 = 0); light_level 200 keeps the
    // CanSeeStealth gate open.
    try std.testing.expect(canSensePlayer(&w, 0, 0, 70, 0, zyaw, 20 * std.math.cos(off30), 70, 20 * std.math.sin(off30), 10.0, 200.0));
    // Per-class full angle 30 (half 15): the same target is now out of cone.
    w.class_table[0].view_angle_deg = 30.0;
    try std.testing.expect(!canSensePlayer(&w, 0, 0, 70, 0, zyaw, 20 * std.math.cos(off30), 70, 20 * std.math.sin(off30), 10.0, 200.0));
    // Per-entity layer beats the class table: class says 30 but the entity's
    // own view_angle_deg 360 (half 180) re-opens the cone.
    w.class_id[0].view_angle_deg = 360.0;
    try std.testing.expect(canSensePlayer(&w, 0, 0, 70, 0, zyaw, 20 * std.math.cos(off30), 70, 20 * std.math.sin(off30), 10.0, 200.0));
}

test "AI senses: smell radius gates through walls, bleeding extends it" {
    // RE entity-ai.md PlayerStealth: smell passes walls and is independent of
    // the sight cone; the per-player effective radius comes from the hook
    // (stock cSmellRadiusBleed 25 while bleeding, else cSmellRadiusMin 10).
    var w: World = .{ .rules = .{ .ai = .{ .sense_dist_sq = 48 * 48 } } };
    defer w.deinit();
    const Wall = struct {
        fn solid(_: ?*anyopaque, x: i32, y: i32, z: i32) bool {
            return x == 10 and y >= 70 and y <= 71 and z == 0;
        }
    };
    w.solid_ctx = null;
    w.solid_fn = &Wall.solid;
    const Smell = struct {
        fn radius(_: ?*anyopaque, slot: Slot) f32 {
            // Slot 1 = bleeding player (25), slot 0 = normal (10).
            return if (slot == 1) 25.0 else 10.0;
        }
    };
    w.smell_ctx = null;
    w.smell_fn = &Smell.radius;
    // Zombie at origin facing +x. Both players at 20 m behind the wall at
    // x=10: no sight (LOS blocked) and no hearing (20 > hear 10). Only the
    // bleeding player (smell 25) is sensed - smell ignores the wall and cone.
    const snaps = [_]PlayerSnap{
        .{ .id = 100, .slot = 0, .x = 20, .y = 70, .z = 0 },
        .{ .id = 101, .slot = 1, .x = 20, .y = 70, .z = 0 },
    };
    const t = nearestPlayerSnap(&w, &snaps, 0, 0, 70, 0, 90.0);
    try std.testing.expectEqual(@as(i32, 101), t.id);
    try std.testing.expectEqual(@as(Slot, 1), t.slot);
    // Both players at 20 m (beyond every non-bleed radius): nobody sensed.
    const far_snaps = [_]PlayerSnap{
        .{ .id = 100, .slot = 0, .x = 20, .y = 70, .z = 0 },
        .{ .id = 101, .slot = 1, .x = 20, .y = 70, .z = 0 },
    };
    var w2: World = .{ .rules = .{ .ai = .{ .sense_dist_sq = 48 * 48 } } };
    defer w2.deinit();
    // Same wall as above: without smell, the 20 m players are behind it, out
    // of hearing, so nobody is sensed (a bleeding player would reek through).
    w2.solid_ctx = null;
    w2.solid_fn = &Wall.solid;
    const FarSmell = struct {
        fn radius(_: ?*anyopaque, _: Slot) f32 {
            return 10.0;
        }
    };
    w2.smell_ctx = null;
    w2.smell_fn = &FarSmell.radius;
    const t2 = nearestPlayerSnap(&w2, &far_snaps, 0, 0, 70, 0, 90.0);
    try std.testing.expectEqual(@as(i32, -1), t2.id);
}

test "stealth: CanSeeStealth light gate gates sight by the TickServer lightLevel" {
    // EAITarget.check (IL=71): a player target must pass CanSee AND
    // CanSeeStealth (EntityAlive IL=21): lightLevel > FastLerp(min, max,
    // dist/sightRange). Stock zombieTemplateMale SightLightThreshold "-2,150":
    // noon lightLevel (46.26) sees within ~31.6% of sightRange (8 m of a
    // 30 m range, threshold 38.5); night (0) sees only point blank (threshold
    // -2 at t=0); crouching (×0.6 → 27.76) drops the noon reach below 8 m.
    // hear 0.1 keeps every assertion on the sight branch (beyond hearing).
    var w: World = .{ .rules = .{ .ai = .{
        .sense_dist_sq = 48 * 48,
        .sight_light_threshold_min = 30.0,
        .sight_light_threshold_max = 100.0,
    } } };
    defer w.deinit();
    w.class_table[0].sight_range = 30.0;
    w.class_table[0].sight_light_min = -2.0;
    w.class_table[0].sight_light_max = 150.0;
    const zyaw: f32 = 90.0; // faces +x; no walls (LOS clear).
    const hear: f32 = 0.1;
    const noon = stealthLightLevel(0.5, 0, false, 0.89, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 46.26), noon, 0.01);
    try std.testing.expect(canSensePlayer(&w, 0, 0, 70, 0, zyaw, 8, 70, 0, hear, noon));
    try std.testing.expect(!canSensePlayer(&w, 0, 0, 70, 0, zyaw, 20, 70, 0, hear, noon));
    const crouched = stealthLightLevel(0.5, 0, true, 0.89, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 27.76), crouched, 0.01);
    // Held-item light (selfLight blend, RE entity-ai.md TickServer step 2):
    // a pistol light (.45) at night adds selfLight x clamp(selfLight /
    // (light + 0.05), 0.5, 3.2).
    const gunlight = stealthLightLevel(0.1, 0.45, false, 0.89, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 134.15), gunlight, 0.05);
    const torchlight = stealthLightLevel(0.05, 0.35, false, 0.89, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 108.25), torchlight, 0.05);
    // The lightAttackPercent switch: a held light (>= 0.1) lifts the crouch
    // reach from the passive-89 value to 1 (full FastLerp(3, 15, t) range).
    try std.testing.expectApproxEqAbs(@as(f32, 0.89), stealthLightAttackPercent(0, 0.89), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), stealthLightAttackPercent(0.45, 0.89), 0.0001);
    // Movement visibility (IL_00CD): light x (1 + speedAverage x 0.15).
    // Noon 46.26 x 1.3 = 60.14 at speedAverage 2 (a jog).
    const moving = stealthLightLevel(0.5, 0, false, 0.89, 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 60.14), moving, 0.05);
    try std.testing.expect(!canSensePlayer(&w, 0, 0, 70, 0, zyaw, 8, 70, 0, hear, crouched));
    // Night: lightLevel 0 sees only inside the threshold's -2 floor (t <
    // 2/152 → < ~0.4 m); 5 m is hidden. Hearing is untouched by the light
    // gate (a night 5 m player at hear 10 is still sensed by sound).
    try std.testing.expect(canSensePlayer(&w, 0, 0, 70, 0, zyaw, 0.3, 70, 0, hear, 0.0));
    try std.testing.expect(!canSensePlayer(&w, 0, 0, 70, 0, zyaw, 5, 70, 0, hear, 0.0));
    try std.testing.expect(canSensePlayer(&w, 0, 0, 70, 0, zyaw, 5, 70, 0, 10.0, 0.0));
}

test "AI move: collide-and-slide stops at a wall and slides along it" {
    // RE entity-movement.md: the stock body is a CharacterController capsule,
    // so a wall stops only the facing axis and the body slides along the face
    // instead of clipping or gluing. Body radius 0.35, wall plane at x=5.
    var w: World = .{ .rules = .{ .ai = .{ .body_radius = 0.35, .body_height = 1.8, .step_height = 1.0 } } };
    defer w.deinit();
    const Wall = struct {
        fn solid(_: ?*anyopaque, x: i32, y: i32, z: i32) bool {
            return x == 5 and y >= 70 and y <= 72 and z >= -3 and z <= 3;
        }
    };
    w.solid_ctx = null;
    w.solid_fn = &Wall.solid;
    const zs = w.spawnZombie(0, 70, 0, 40).?;
    const s = w.slotOfNetId(zs).?;
    // Straight into the wall: the body must stop short of x=5 (edge rests at
    // the face, never entering the wall cell). ~42 ticks to cover 4.65 m.
    for (0..80) |_| stepToward(&w, s, 50, 0, 2.2, 0.05);
    try std.testing.expect(w.transform[s].x > 3.0 and w.transform[s].x < 5.0);
    const x_blocked = w.transform[s].x;
    // Diagonally (+x, +z): X stays blocked at the face while Z slides along it
    // until the body reaches the wall's end (z edge stops at ~2.65).
    const z_start = w.transform[s].z;
    for (0..60) |_| stepToward(&w, s, 50, 8, 2.2, 0.05);
    try std.testing.expectApproxEqAbs(x_blocked, w.transform[s].x, 0.02);
    try std.testing.expect(w.transform[s].z > z_start + 1.0 and w.transform[s].z < 3.0);
}

test "AI move: a 1-high ledge is stepped up, not blocked" {
    // Stock CC stepOffset: a horizontal move into a block is retried with the
    // feet lifted by step_height, so a zombie climbs a full block. Ground at
    // y=69 (top 70); the ledge block at (x=6, y=70) adds a 1-high step (top
    // 71). Without step-up the body would pin at the ledge face; with it the
    // zombie crosses and gravity re-settles it to the ground behind.
    var w: World = .{ .rules = .{ .ai = .{ .body_radius = 0.35, .body_height = 1.8, .step_height = 1.0 } } };
    defer w.deinit();
    const Ledge = struct {
        fn solid(_: ?*anyopaque, x: i32, y: i32, z: i32) bool {
            return y == 69 or (x == 6 and y == 70 and z >= -3 and z <= 3);
        }
    };
    w.solid_ctx = null;
    w.solid_fn = &Ledge.solid;
    const zs = w.spawnZombie(0, 70, 0, 40).?;
    const s = w.slotOfNetId(zs).?;
    for (0..120) |_| {
        stepToward(&w, s, 12, 0, 2.2, 0.05);
        applyGravity(&w, s, 0.05);
    }
    // Crossed the block; the body stepped up to 71 over the ledge and then
    // settled back onto the ground (top 70) behind it.
    try std.testing.expect(w.transform[s].x > 8.0);
    try std.testing.expectApproxEqAbs(@as(f32, 70.0), w.transform[s].y, 0.01);
}

test "AI move: airborne body falls under gravity and lands on the first solid cell" {
    // RE entity-movement.md: the vertical leg integrates gravity and lands on
    // the first solid cell below (block top y=71 for ground at y=70). An idle
    // body (applyGravity alone, no horizontal intent) still settles.
    var w: World = .{ .rules = .{ .ai = .{ .body_radius = 0.35, .body_height = 1.8, .step_height = 1.0 } } };
    defer w.deinit();
    const Ground = struct {
        fn solid(_: ?*anyopaque, _: i32, y: i32, _: i32) bool {
            return y == 70;
        }
    };
    w.solid_ctx = null;
    w.solid_fn = &Ground.solid;
    const zs = w.spawnZombie(0, 75, 0, 40).?;
    const s = w.slotOfNetId(zs).?;
    for (0..200) |_| applyGravity(&w, s, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 71.0), w.transform[s].y, 0.001);
    try std.testing.expectEqual(@as(f32, 0.0), w.zombie_ai[s].vy);
}

test "AI move: wander target inside a wall does not clip through it" {
    // The old wander used a straight-line step, so a wander pick inside a
    // building walked the body through the wall. The collide-and-slide stops
    // the body at the face even when the goal cell is unreachable.
    var w: World = .{ .rules = .{ .ai = .{ .body_radius = 0.35, .body_height = 1.8, .step_height = 1.0 } } };
    defer w.deinit();
    const Wall = struct {
        fn solid(_: ?*anyopaque, x: i32, y: i32, z: i32) bool {
            return x >= 5 and x <= 8 and y >= 70 and y <= 72 and z >= -3 and z <= 3;
        }
    };
    w.solid_ctx = null;
    w.solid_fn = &Wall.solid;
    const zs = w.spawnZombie(0, 70, 0, 40).?;
    const s = w.slotOfNetId(zs).?;
    // Goal inside the wall block: the body stops at the near face (x < 5).
    for (0..80) |_| stepToward(&w, s, 6, 0, 2.2, 0.05);
    try std.testing.expect(w.transform[s].x < 5.0);
}

test "stealth: crouch muffles the hearing gate through walls" {
    // RE entity-ai.md PlayerStealth NotifyNoise: a crouched player's movement
    // noise is muffled (stock per-clip muffledWhenCrouched; rules floor
    // crouch_hear_scale 0.5), so the hearing gate shrinks while sight stays
    // unchanged. Wall between zombie and player blocks sight; hearing decides.
    var w: World = .{ .rules = .{ .ai = .{ .sense_dist_sq = 48 * 48, .smell_radius = 2.0 } } };
    defer w.deinit();
    const Wall = struct {
        fn solid(_: ?*anyopaque, x: i32, y: i32, z: i32) bool {
            return x == 4 and y >= 70 and y <= 71 and z == 0;
        }
    };
    w.solid_ctx = null;
    w.solid_fn = &Wall.solid;
    var snaps = [_]PlayerSnap{
        .{ .id = 100, .slot = 0, .x = 8, .y = 70, .z = 0, .crouching = false },
    };
    // Standing at 8 m (hear 10): heard through the wall.
    const t_stand = nearestPlayerSnap(&w, &snaps, 0, 0, 70, 0, 90.0);
    try std.testing.expectEqual(@as(i32, 100), t_stand.id);
    // Crouched at 8 m (hear 10 x 0.5 = 5): muffled, sight blocked: not sensed.
    snaps[0].crouching = true;
    const t_crouch = nearestPlayerSnap(&w, &snaps, 0, 0, 70, 0, 90.0);
    try std.testing.expectEqual(@as(i32, -1), t_crouch.id);
    // Crouched but close (3 m < 5): still heard.
    snaps[0] = .{ .id = 100, .slot = 0, .x = 3, .y = 70, .z = 0, .crouching = true };
    const t_close = nearestPlayerSnap(&w, &snaps, 0, 0, 70, 0, 90.0);
    try std.testing.expectEqual(@as(i32, 100), t_close.id);
}

test "stealth: crouched players only wake sleepers within FastLerp(3,15,light)" {
    // RE entity-ai.md CanSleeperAttackDetect: crouching shrinks sleeper
    // disturbance to FastLerp(3, 15, lightAttackPercent). lightAttackPercent
    // is the passive-89 when selfLight < 0.1 (TickServer IL_010B; the sim
    // carries no held-item lights, so it always applies): crouch range
    // 3 + 12×0.89 = 13.68. A crouched player 16 m inside a volume_r 20
    // sleeper stays hidden, 12 m wakes it. Standing wakes at the volume
    // radius regardless of distance within it.
    var w: World = .{ .rules = .{ .ai = .{
        .crouch_sleeper_detect_min = 3.0,
        .crouch_sleeper_detect_max = 15.0,
        .stealth_light_passive = 0.89,
    } } };
    defer w.deinit();
    const z = w.spawnSleeperDef(0, 70, 0, .{ .name = "sl", .hash = 1, .kind = .zombie }, 0).?;
    const zs = w.slotOfNetId(z).?;
    w.sleeper[zs].volume_r = 20;
    // Open the disturbed-level light gate (this test isolates the crouch leg;
    // the light gate itself is covered by the next test).
    w.sleeper[zs].wake_light_near = -1000;
    w.sleeper[zs].wake_light_far = -500;
    const p = w.spawnPlayer(16, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    w.player[ps].crouching = true;
    for (0..3) |_| _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(!w.sleeper[zs].awake);
    // In the volume beyond the crouch wake reach: the sleeper STIRS (the
    // one-shot SetSleeperActive / PassiveChange) but stays asleep.
    try std.testing.expect(w.sleeper[zs].groan_sent);
    try std.testing.expectEqual(@as(usize, 1), w.sleeper_wake_n);
    try std.testing.expectEqual(zs, w.sleeper_wake_reqs[0].slot);
    try std.testing.expect(w.sleeper_wake_reqs[0].groan);
    // A crouched player 12 m inside the volume wakes it (13.68 > 12).
    w.transform[ps].x = 12;
    for (0..3) |_| _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(w.sleeper[zs].awake);
    try std.testing.expectEqual(@as(usize, 2), w.sleeper_wake_n);
    try std.testing.expect(!w.sleeper_wake_reqs[1].groan);
    try std.testing.expectEqual(zs, w.sleeper_wake_reqs[1].slot);
}

test "stealth: standing players wake sleepers at the full volume radius" {
    // RE entity-ai.md CanSleeperAttackDetect: not crouching → true, so the
    // volume radius gates the wake (no FastLerp shrink). The crouch leg only
    // protects beyond FastLerp(3,15,0.89) = 13.68: 16 m crouched is out,
    // uncrouching wakes the 20 m volume. The disturbed-level gate is open.
    var w: World = .{ .rules = .{ .ai = .{
        .crouch_sleeper_detect_min = 3.0,
        .crouch_sleeper_detect_max = 15.0,
        .stealth_light_passive = 0.89,
    } } };
    defer w.deinit();
    const z = w.spawnSleeperDef(0, 70, 0, .{ .name = "sl", .hash = 1, .kind = .zombie }, 0).?;
    const zs = w.slotOfNetId(z).?;
    w.sleeper[zs].volume_r = 20;
    w.sleeper[zs].wake_light_near = -1000;
    w.sleeper[zs].wake_light_far = -500;
    const p = w.spawnPlayer(16, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    w.player[ps].crouching = true;
    for (0..3) |_| _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(!w.sleeper[zs].awake);
    // In the volume beyond the crouch wake reach: the sleeper stirs once.
    try std.testing.expect(w.sleeper[zs].groan_sent);
    w.player[ps].crouching = false;
    for (0..3) |_| _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(w.sleeper[zs].awake);
    try std.testing.expectEqual(@as(usize, 2), w.sleeper_wake_n);
    try std.testing.expect(w.sleeper_wake_reqs[0].groan);
    try std.testing.expectEqual(zs, w.sleeper_wake_reqs[1].slot);
    try std.testing.expect(!w.sleeper_wake_reqs[1].groan);
}

test "stealth: sleepers wake inside the GetSleeperDisturbedLevel light gate" {
    // RE UpdateSleeper wake scan (entity-ai.md): a sleeping zombie wakes the
    // nearest player with GetSleeperDisturbedLevel(dist, lightLevel) >= 2 -
    // wake = Lerp(rolledWakeNear, rolledWakeFar, dist/sightRangeBase) and
    // lightLevel > wake. With the stock roll midpoints (-17.5 / 410) over a
    // 30 m sightRange, noon (lightLevel 46.26) wakes within ~14.8% of the
    // range (4 m wakes, wake 39.4); night (0) wakes only within ~1.2 m
    // (0.04 pct, wake -0.4); a 2 m night player stays hidden.
    var w: World = .{ .rules = .{ .ai = .{ .sense_dist_sq = 48 * 48 } } };
    defer w.deinit();
    const z = w.spawnSleeperDef(0, 70, 0, .{ .name = "sl", .hash = 1, .kind = .zombie, .sight_range = 30.0 }, 0).?;
    const zs = w.slotOfNetId(z).?;
    w.sleeper[zs].volume_r = 20;
    w.sleeper[zs].wake_light_near = -17.5;
    w.sleeper[zs].wake_light_far = 410.0;
    const p = w.spawnPlayer(4, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    // Day (ambient 0.5 → lightLevel 46.26): 4 m wakes (threshold 39.4).
    w.ambient_light = 0.5;
    for (0..3) |_| _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(w.sleeper[zs].awake);
    w.sleeper[zs].awake = false; // re-arm for the night case
    w.sleeper_wake_n = 0;
    // Night (lightLevel 0): 4 m hidden (threshold 39.4) - the sleeper STIRS
    // (SetSleeperActive one-shot) but stays asleep; 1 m wakes (-3.9).
    w.ambient_light = 0;
    w.transform[ps].x = 4;
    for (0..3) |_| _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(!w.sleeper[zs].awake);
    try std.testing.expect(w.sleeper[zs].groan_sent);
    try std.testing.expectEqual(@as(usize, 1), w.sleeper_wake_n);
    try std.testing.expect(w.sleeper_wake_reqs[0].groan);
    w.transform[ps].x = 1;
    for (0..3) |_| _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(w.sleeper[zs].awake);
    try std.testing.expectEqual(@as(usize, 2), w.sleeper_wake_n);
    try std.testing.expect(!w.sleeper_wake_reqs[1].groan);
    try std.testing.expectEqual(zs, w.sleeper_wake_reqs[1].slot);
}

test "stealth: lightAttackPercent folds the passive-89 below 0.1 selfLight" {
    // RE PlayerStealth.TickServer IL_010B: selfLight (the held-item light,
    // GetStealthLightLevel's out param) < 0.1 → passive-89, else 1.
    try std.testing.expectApproxEqAbs(@as(f32, 0.89), stealthLightAttackPercent(0.0, 0.89), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.89), stealthLightAttackPercent(0.099, 0.89), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), stealthLightAttackPercent(0.1, 0.89), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), stealthLightAttackPercent(0.5, 0.89), 0.0001);
}

test "group AI: combat noise alerts distant zombies to investigate" {
    // Stock NotifyNoise: a landed melee hit emits noise that alerts zombies
    // within radius even when they cannot sense the player directly; they
    // investigate the spot (has_spot) instead of wandering.
    var w: World = .{ .rules = .{ .ai = .{ .sense_dist_sq = 4 * 4, .combat_noise_radius = 24.0 } } };
    defer w.deinit();
    const a = w.spawnZombie(0, 70, 0, 40).?;
    const aslot = w.slotOfNetId(a).?;
    _ = w.spawnZombie(10, 70, 0, 40).?;
    const bslot = w.slotOfNetId(a).? + 1;
    const p = w.spawnPlayer(1, 70, 0, 0).?;
    _ = w.slotOfNetId(p).?;
    var hit: u32 = 0;
    var t: f32 = 0;
    while (t < 4.0 and hit == 0) : (t += 0.05) {
        hit = systemZombieAi(&w, 0.05);
    }
    try std.testing.expect(hit > 0); // A landed a hit -> noise.
    // B at 10 m cannot sense the player (sense 4) but the noise alerts it.
    try std.testing.expect(w.zombie_ai[aslot].alert);
    try std.testing.expect(w.zombie_ai[bslot].alert);
    try std.testing.expect(w.zombie_ai[bslot].has_spot);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), w.zombie_ai[bslot].spot_x, 1.0);
}

test "group AI: combat noise wakes sleepers within radius" {
    var w: World = .{ .rules = .{ .ai = .{ .sense_dist_sq = 4 * 4, .combat_noise_radius = 24.0 } } };
    defer w.deinit();
    _ = w.spawnZombie(0, 70, 0, 40).?;
    const z = w.spawnSleeperDef(12, 70, 0, .{ .name = "sl", .hash = 1, .kind = .zombie }, 0).?;
    const zs = w.slotOfNetId(z).?;
    w.sleeper[zs].volume_r = 16;
    _ = w.spawnPlayer(1, 70, 0, 0).?;
    var hit: u32 = 0;
    var t: f32 = 0;
    while (t < 4.0 and hit == 0) : (t += 0.05) {
        hit = systemZombieAi(&w, 0.05);
    }
    try std.testing.expect(hit > 0);
    // The sleeper at 12 m (volume 16 would need the player closer, but the
    // noise radius 24 covers it) wakes and investigates.
    try std.testing.expect(w.sleeper[zs].awake);
    try std.testing.expect(w.zombie_ai[zs].has_spot);
    // The noise wake also pushed the SleeperWakeup wire event; the player at
    // 11 m was in the volume (16) first, so the sleeper stirred (groan req)
    // before the noise woke it (wake req).
    try std.testing.expect(w.sleeper[zs].groan_sent);
    try std.testing.expectEqual(@as(usize, 2), w.sleeper_wake_n);
    try std.testing.expect(w.sleeper_wake_reqs[0].groan);
    try std.testing.expectEqual(zs, w.sleeper_wake_reqs[1].slot);
    try std.testing.expect(!w.sleeper_wake_reqs[1].groan);
}

test "damage wakes a sleeper and pushes the wakeup event" {
    // Stock EntityAlive.ProcessDamageResponseLocal: any damage triggers
    // ConditionalTriggerSleeperWakeUp (plus CheckSleeperVolumeNoise while
    // passive). The sim flips the sleeper awake and the Game broadcasts
    // NetPackageSleeperWakeup from the drained ring.
    var w: World = .{};
    defer w.deinit();
    const z = w.spawnSleeperDef(0, 70, 0, .{ .name = "sl", .hash = 1, .kind = .zombie }, 0).?;
    const zs = w.slotOfNetId(z).?;
    try std.testing.expect(!w.sleeper[zs].awake);
    _ = w.damageFrom(z, 10.0, -1);
    try std.testing.expect(w.sleeper[zs].awake);
    try std.testing.expectEqual(@as(usize, 1), w.sleeper_wake_n);
    try std.testing.expectEqual(zs, w.sleeper_wake_reqs[0].slot);
    // The ring is consume-owns-drain: the drainer zeroes the count; a second
    // hit on the now-awake sleeper pushes nothing new.
    w.sleeper_wake_n = 0;
    _ = w.damageFrom(z, 5.0, -1);
    try std.testing.expectEqual(@as(usize, 0), w.sleeper_wake_n);
}

test "falling blocks: group falls under gravity and dies on landing (no re-placement)" {
    // RE entity-ai.md EntityFallingBlock landing: the group falls with the
    // stock gravity integrator; ground contact kills it and the cells are
    // never written back (the collapse already aired them).
    var w: World = .{ .rules = .{ .ai = .{ .gravity = -1.6 } } };
    defer w.deinit();
    const Ground = struct {
        fn solid(_: ?*anyopaque, _: i32, y: i32, _: i32) bool {
            return y <= 70; // solid at y=70 and below; air above.
        }
    };
    w.solid_ctx = null;
    w.solid_fn = &Ground.solid;
    const id = w.spawnFallingBlocks(&.{
        .{ .x = 5, .y = 75, .z = 5, .raw = 700 },
        .{ .x = 5, .y = 76, .z = 5, .raw = 701 },
    }).?;
    const s = w.slotOfNetId(id).?;
    try std.testing.expectEqual(c.Kind.falling_block, w.kind[s]);
    try std.testing.expect(w.mask[s].falling);
    // Falls until the lowest cell (y=75) lands on the solid at 70: the group
    // is destroyed; cells stay air (no re-placement).
    var landed = false;
    for (0..600) |_| {
        systemFallingBlocks(&w, 0.05);
        if (!w.alive[s]) {
            landed = true;
            break;
        }
    }
    try std.testing.expect(landed);
    try std.testing.expect(!w.alive[s]);
}

test "falling blocks: spawn is capped at the group size and centered" {
    var w: World = .{};
    defer w.deinit();
    var cells: [40]c.FallingCell = undefined;
    for (&cells, 0..) |*cell, i| {
        cell.* = .{ .x = @intCast(i), .y = 70, .z = 0, .raw = 700 };
    }
    const id = w.spawnFallingBlocks(&cells).?;
    const s = w.slotOfNetId(id).?;
    try std.testing.expectEqual(@as(u8, c.falling_group_cap), w.falling[s].n);
}

test "falling block: singular spawn is per-cell, offset within the stock dy and drifts deterministically" {
    // Stock default path (entity-ai.md LetBlocksFall 1256-1262): one
    // fallingBlock entity per cell at the cell center with a random Y offset
    // in -0.1..0.1 and a random horizontal impulse. The jitter is seeded by
    // the cell position, so the same collapse reproduces the same scatter.
    var w: World = .{ .rules = .{ .ai = .{ .gravity = -1.6 } } };
    defer w.deinit();
    const cell = c.FallingCell{ .x = 5, .y = 75, .z = 5, .raw = 0x0002_01FF };
    const id = w.spawnFallingBlock(cell, 40.0).?;
    const s = w.slotOfNetId(id).?;
    try std.testing.expectEqual(c.Kind.falling_block, w.kind[s]);
    try std.testing.expectEqual(@as(u8, 1), w.falling[s].n);
    try std.testing.expectEqual(cell.raw, w.falling[s].cells[0].raw);
    const t = w.transform[s];
    const dy = t.y - @as(f32, @floatFromInt(cell.y));
    try std.testing.expect(dy >= -0.1001 and dy <= 0.1001);
    // Deterministic: a second spawn of the same cell lands at the same pos.
    const id2 = w.spawnFallingBlock(cell, 40.0).?;
    const s2 = w.slotOfNetId(id2).?;
    try std.testing.expectEqual(t.x, w.transform[s2].x);
    try std.testing.expectEqual(t.y, w.transform[s2].y);
    try std.testing.expectEqual(t.z, w.transform[s2].z);
    // The impulse is bounded and the entity falls under the stock integrator.
    try std.testing.expect(@abs(w.falling[s].vx) <= 0.5);
    try std.testing.expect(@abs(w.falling[s].vz) <= 0.5);
    const Ground = struct {
        fn solid(_: ?*anyopaque, _: i32, y: i32, _: i32) bool {
            return y <= 70;
        }
    };
    w.solid_fn = &Ground.solid;
    const y0 = w.transform[s].y;
    for (0..30) |_| _ = systemFallingBlocks(&w, 0.05);
    try std.testing.expect(w.transform[s].y < y0);
}

test "falling block: crush damage hits entities in the fall path, capped per entity" {
    // RE entity-ai.md EntityFallingBlock.OnUpdateEntity (IL=344): every other
    // tick the block damages entities whose box overlaps its bounds, when the
    // faller center is above the target's head and |vy| >= 0.8. Raw damage is
    // FastMin(massKg * |vy| * 0.05, 40), int-truncated, then armor-reduced
    // (passive 164 analog); at most falling_hit_cap hits per entity.
    var w: World = .{ .rules = .{ .ai = .{ .gravity = -1.6 } } };
    defer w.deinit();
    const Ground = struct {
        fn solid(_: ?*anyopaque, _: i32, y: i32, _: i32) bool {
            return y <= 70; // ground at y=70; air above.
        }
    };
    w.solid_ctx = null;
    w.solid_fn = &Ground.solid;
    // A tanky zombie standing under the fall path (head ~72.8).
    const z = w.spawnZombieClass(5, 71, 5, 200, 7, "").?;
    const zs = w.slotOfNetId(z).?;
    const hp0 = w.health[zs].hp;
    // Heavy singular block (massKg 80, like cobblestoneMaster) falls from 75.
    const id = w.spawnFallingBlock(.{ .x = 5, .y = 75, .z = 5, .raw = 0x0001_00FF }, 80.0).?;
    const s = w.slotOfNetId(id).?;
    // Keep the fall vertical so the crush path is deterministic (the drift
    // itself is covered by the singular-spawn test).
    w.falling[s].vx = 0;
    w.falling[s].vz = 0;
    for (0..600) |_| {
        systemFallingBlocks(&w, 0.05);
        if (!w.alive[s]) break;
    }
    try std.testing.expect(!w.alive[s]); // landed and destroyed
    const hp1 = w.health[zs].hp;
    try std.testing.expect(hp1 < hp0); // crushed at least once
    // Cap: 3 hits x <=40 = at most 120 of the 200 hp gone.
    try std.testing.expect(hp1 >= hp0 - 3 * 40);
    // A slow faller (vy >= -0.8) deals no crush: spawn high above an entity
    // that is out of reach instead - assert the velocity gate directly by
    // checking that a zero-mass block (no materials table) never damages.
    const z2 = w.spawnZombieClass(15, 71, 5, 200, 7, "").?;
    const zs2 = w.slotOfNetId(z2).?;
    const hp2_0 = w.health[zs2].hp;
    const id2 = w.spawnFallingBlock(.{ .x = 15, .y = 75, .z = 5, .raw = 0x0001_00FF }, 0.0).?;
    const s2 = w.slotOfNetId(id2).?;
    w.falling[s2].vx = 0;
    w.falling[s2].vz = 0;
    for (0..600) |_| {
        systemFallingBlocks(&w, 0.05);
        if (!w.alive[s2]) break;
    }
    try std.testing.expectEqual(hp2_0, w.health[zs2].hp);
}

test "move helper: a blocked grounded zombie jumps a 1-block wall" {
    // RE entity-ai.md 2030-2034: MoveHelper.StartJump triggers when both slide
    // axes are blocked and the body is grounded; the hop (heightDiff ~1.3)
    // carries the body over obstacles up to jump_height. Step-up is disabled
    // so only the jump can cross.
    var w: World = .{ .rules = .{ .ai = .{ .gravity = -1.6, .step_height = 0 } } };
    defer w.deinit();
    const Ground = struct {
        fn solid(_: ?*anyopaque, x: i32, y: i32, z: i32) bool {
            if (y <= 70) return true; // ground
            if (x == 10 and y == 71 and z == 5) return true; // 1-block wall
            return false;
        }
    };
    w.solid_ctx = null;
    w.solid_fn = &Ground.solid;
    const z = w.spawnZombieClass(5, 71, 5, 200, 7, "").?;
    const s = w.slotOfNetId(z).?;
    // Walk toward x=15; the wall at x=10 must be jumped.
    for (0..600) |_| {
        stepToward(&w, s, 15.0, 5.0, 2.2, 0.05);
        applyGravity(&w, s, 0.05);
        if (w.transform[s].x >= 14.0) break;
    }
    try std.testing.expect(w.transform[s].x >= 14.0);
    try std.testing.expectApproxEqAbs(@as(f32, 71.0), w.transform[s].y, 0.5); // settled near the ground
    // The jump cost at least one impulse (vy was set positive once).
    try std.testing.expect(w.zombie_ai[s].jump_cd <= w.rules.ai.jump_delay_s);

    // Control: with no jump height the wall is impassable.
    var w2: World = .{ .rules = .{ .ai = .{ .gravity = -1.6, .step_height = 0, .jump_height = 0 } } };
    defer w2.deinit();
    w2.solid_ctx = null;
    w2.solid_fn = &Ground.solid;
    const z2 = w2.spawnZombieClass(5, 71, 5, 200, 7, "").?;
    const s2 = w2.slotOfNetId(z2).?;
    for (0..600) |_| {
        stepToward(&w2, s2, 15.0, 5.0, 2.2, 0.05);
        applyGravity(&w2, s2, 0.05);
        if (w2.transform[s2].x >= 14.0) break;
    }
    try std.testing.expect(w2.transform[s2].x < 10.0);
}

test "move helper: a blocked grounded zombie digs the blocking block" {
    // RE entity-ai.md DigStart/DigUpdate: after the jump fails on a 3-tall
    // wall (the 1.3-block hop cannot clear it) and its cooldown lapses, the
    // blocked grounded AI digs the solid cell in its move direction; the
    // cadence pushes DigRequests the Game drains. The wall spans all z so the
    // slide cannot route around it.
    var w: World = .{ .rules = .{ .ai = .{ .gravity = -1.6, .jump_delay_s = 1.0 } } };
    defer w.deinit();
    const Ground = struct {
        fn solid(_: ?*anyopaque, x: i32, y: i32, _: i32) bool {
            if (y <= 70) return true; // ground
            if (x == 10 and (y == 71 or y == 72 or y == 73)) return true; // 3-tall wall
            return false;
        }
    };
    w.solid_ctx = null;
    w.solid_fn = &Ground.solid;
    const z = w.spawnZombieClass(5, 71, 5, 500, 7, "").?;
    const s = w.slotOfNetId(z).?;
    // Walk toward x=15: the jump fires once (fails on the 2-tall wall), then
    // during the cooldown the dig starts.
    for (0..120) |_| {
        stepToward(&w, s, 15.0, 5.0, 2.2, 0.05);
        applyGravity(&w, s, 0.05);
    }
    try std.testing.expect(w.zombie_ai[s].digging);
    try std.testing.expectEqual(@as(i32, 10), w.zombie_ai[s].dig_x);
    try std.testing.expectEqual(@as(i32, 71), w.zombie_ai[s].dig_y);
    // The cadence pushes a DigRequest after the windup (rules.ai default 18).
    var pushed = false;
    for (0..@as(usize, 18) + 4) |_| {
        systemDigUpdate(&w);
        if (w.dig_n > 0) {
            pushed = true;
            break;
        }
    }
    try std.testing.expect(pushed);
}

test "move helper: a submerged body floats instead of dropping" {
    // RE entity-ai.md cctor: cSwimGravityPer 0.025 / cSwimDragY 0.91 - a
    // submerged AI body sinks slowly (float) instead of falling to the bed,
    // and horizontal moves slow to the swim speed fraction.
    var w: World = .{ .rules = .{ .ai = .{ .gravity = -1.6 } } };
    defer w.deinit();
    const Pool = struct {
        fn solid(_: ?*anyopaque, _: i32, y: i32, _: i32) bool {
            return y <= 70; // bed at 70
        }
        fn isWater(_: ?*anyopaque, _: i32, y: i32, _: i32) bool {
            return y > 70 and y <= 78; // water column 71..78
        }
    };
    w.solid_ctx = null;
    w.solid_fn = &Pool.solid;
    w.water_ctx = null;
    w.water_fn = &Pool.isWater;
    const z = w.spawnZombieClass(5, 80, 5, 200, 7, "").?; // drop into the pool
    const s = w.slotOfNetId(z).?;
    for (0..60) |_| applyGravity(&w, s, 0.05); // enter the water
    try std.testing.expect(w.transform[s].y <= 78.5); // reached the surface
    for (0..120) |_| applyGravity(&w, s, 0.05); // 6 s submerged
    // Sank slowly: nowhere near the bed (70) - a float.
    try std.testing.expect(w.transform[s].y > 76.0);
    // Horizontal: the swim speed fraction halves the step.
    const x0 = w.transform[s].x;
    stepToward(&w, s, 20.0, 5.0, 2.2, 0.05);
    const moved = w.transform[s].x - x0;
    try std.testing.expect(moved > 0.02 and moved < 0.09); // ~0.055 (2.2*0.5*0.05)
}

test "move helper: an entity in the way is pushed, not walked through" {
    // RE entity-ai.md AttackPush: a blocked-by-entity zombie stops and shoves
    // the blocker along the push direction, so crowds part instead of overlap.
    var w: World = .{ .rules = .{ .ai = .{ .gravity = -1.6 } } };
    defer w.deinit();
    const Ground = struct {
        fn solid(_: ?*anyopaque, _: i32, y: i32, _: i32) bool {
            return y <= 70;
        }
    };
    w.solid_ctx = null;
    w.solid_fn = &Ground.solid;
    const a = w.spawnZombieClass(5, 71, 5, 200, 7, "").?;
    const b = w.spawnZombieClass(7, 71, 5, 200, 7, "").?;
    const sa = w.slotOfNetId(a).?;
    const sb = w.slotOfNetId(b).?;
    const bx0 = w.transform[sb].x;
    for (0..40) |_| {
        stepToward(&w, sa, 12, 5, 2.2, 0.05);
        applyGravity(&w, sa, 0.05);
    }
    // A never walked through B (stops just behind it) and B got shoved.
    try std.testing.expect(w.transform[sa].x < w.transform[sb].x - 0.4);
    try std.testing.expect(w.transform[sb].x > bx0 + 0.3);
}

test "demolition: primes at the health threshold, countdowns, then requests the explosion" {
    // RE entity-ai.md EntityZombieCop.OnUpdateEntity: the cop primes when
    // health drops below max*explode_threshold, counts down explodeDelay*20,
    // readies the blast ((delay/5)*1.5*20) and pushes an explode request the
    // Game drains. A class without ExplosionData never primes.
    var w: World = .{ .rules = .{ .ai = .{ .explosion_radius = 4.0 } } };
    defer w.deinit();
    w.setClassDef(1, .{ .name = "zombieCop", .kind = .zombie, .hash = 7, .explode_threshold = 0.75, .explode_delay_s = 0.5 });
    const z = w.spawnZombieClass(0, 70, 0, 40, 7, "").?;
    const s = w.slotOfNetId(z).?;
    // Full health: never primes.
    for (0..5) |_| _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(!w.zombie_ai[s].primed);
    // Damage below 75% (40 * 0.75 = 30): primes on the next AI tick.
    w.health[s].hp = 29;
    _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(w.zombie_ai[s].primed);
    try std.testing.expectEqual(@as(i32, 10), w.zombie_ai[s].prime_ticks); // 0.5 * 20
    // Countdown: 10 ticks start + (0.5/5)*1.5*20 = 3 explode ticks.
    var exploded = false;
    for (0..30) |_| {
        _ = systemZombieAi(&w, 0.05);
        if (w.explode_n > 0) {
            exploded = true;
            break;
        }
    }
    try std.testing.expect(exploded);
    // A plain zombie (no explosion data) never primes no matter how hurt.
    var w2: World = .{};
    defer w2.deinit();
    const z2 = w2.spawnZombie(0, 70, 0, 40).?;
    const s2 = w2.slotOfNetId(z2).?;
    w2.health[s2].hp = 1;
    for (0..3) |_| _ = systemZombieAi(&w2, 0.05);
    try std.testing.expect(!w2.zombie_ai[s2].primed);
}

test "trader buys an item it does not stock via the sell-price hook" {
    // Stock lets you sell anything (GetSellPrice: EconomicValue x scale x
    // markdown); the hook prices non-stocked items. 0 / unset keeps the
    // stocked-only restriction.
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    const trader_id = w.spawnTrader("Trader", 1, 70, 1, 0, 500).?;
    const ps = w.playerByPeer(0).?;
    const ts = w.slotOfNetId(trader_id).?;
    w.inventory[ps].slots[0] = .{ .item_id = 77, .count = 5, .quality = 1 };
    w.inventory[ps].slots[c.inv_equip_start - 1] = .{}; // free slot for coin payout
    w.trader_stock[ts].entries[0] = .{ .item = 99, .count = 2, .price = 10, .sell = 100 };
    const Hook = struct {
        fn price(_: ?*anyopaque, item: u16, _: u16) u32 {
            return if (item == 77) 25 else 0; // 25 dukes per non-stocked unit
        }
    };
    w.sell_price_ctx = null;
    w.sell_price_fn = &Hook.price;

    // Without a stocked entry the sale still lands at the hooked price.
    // The starter kit already carried 50 casinoCoin, so the wallet ends at
    // 50 (starter) + 50 (2 x 25 sell) = 100.
    try std.testing.expect(trade(&w, 0, trader_id, 77, 2, 1, 6));
    try std.testing.expectEqual(@as(u32, 100), w.wallet[ps].coins);
    try std.testing.expectEqual(@as(i32, 450), w.trader_stock[ts].wallet);
    // The stocked entry is untouched by a non-stocked sale.
    try std.testing.expectEqual(@as(u16, 2), w.trader_stock[ts].entries[0].count);
    // Unset hook: non-stocked sells are refused (test worlds keep the old rule).
    w.sell_price_fn = null;
    const coins_before = w.wallet[ps].coins;
    try std.testing.expect(!trade(&w, 0, trader_id, 77, 1, 1, 6));
    try std.testing.expectEqual(coins_before, w.wallet[ps].coins);
}

test "trader prices scale with item quality (quality_mod lerp)" {
    // Stock GetBuyPrice/GetSellPrice apply Lerp(qualityMinMod, qualityMaxMod,
    // (quality-1)/5); the traders.xml comment pins QL1 -> min and QL6 -> max.
    // With the stock root quality_mod="1,2" a QL6 item prices at 2x a QL1.
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    const trader_id = w.spawnTrader("Trader", 1, 70, 1, 0, 500).?;
    const ps = w.playerByPeer(0).?;
    w.trader_quality_min_mod = 1.0;
    w.trader_quality_max_mod = 2.0;
    try std.testing.expectEqual(@as(f32, 1.0), qualityPriceMod(1, 2, 1));
    try std.testing.expectEqual(@as(f32, 1.6), qualityPriceMod(1, 2, 4));
    try std.testing.expectEqual(@as(f32, 2.0), qualityPriceMod(1, 2, 6));
    try std.testing.expectEqual(@as(f32, 1.0), qualityPriceMod(1, 1, 6)); // unset = no effect

    // Non-stocked sell: a QL6 stack pays 2x the hook price, QL1 pays 1x.
    w.inventory[ps].slots[0] = .{ .item_id = 77, .count = 2, .quality = 6 };
    w.inventory[ps].slots[c.inv_equip_start - 1] = .{}; // free slot for coin payout
    const Hook = struct {
        fn price(_: ?*anyopaque, item: u16, _: u16) u32 {
            return if (item == 77) 25 else 0; // 25 dukes per non-stocked unit
        }
    };
    w.sell_price_ctx = null;
    w.sell_price_fn = &Hook.price;
    // 50 (starter) + 2 x (25 * 2.0) = 150.
    try std.testing.expect(trade(&w, 0, trader_id, 77, 2, 1, 6));
    try std.testing.expectEqual(@as(u32, 150), w.wallet[ps].coins);
}

test "worn items sell for less (PercentUsesLeft rides the sold stack)" {
    // Stock GetSellPrice multiplies the sell base by the SOLD ItemValue's
    // PercentUsesLeft (ItemValue.get_PercentUsesLeft IL=17): a half-worn
    // stone-axe-like stack pays half. The pul hook receives the sold stack's
    // quality + use_times, not the entry's.
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    const trader_id = w.spawnTrader("Trader", 1, 70, 1, 0, 5000).?;
    const ps = w.playerByPeer(0).?;
    w.inventory[ps].slots[0] = .{ .item_id = 77, .count = 2, .quality = 1, .use_times = 125 };
    w.inventory[ps].slots[c.inv_equip_start - 1] = .{}; // free slot for coin payout
    const Hook = struct {
        fn price(_: ?*anyopaque, item: u16, _: u16) u32 {
            return if (item == 77) 100 else 0; // 100 dukes per non-stocked unit
        }
    };
    const Pul = struct {
        fn pul(_: ?*anyopaque, item: u16, quality: u8, use_times: f32) f32 {
            // Stone-axe-like Q1 cap 250: 125/250 used -> half value. The
            // coin totals below verify the hook receives the sold stack's
            // quality/use_times (a wrong cap would price differently).
            _ = item;
            _ = quality;
            return 1 - @min(@max(use_times / 250.0, 0), 1);
        }
    };
    w.sell_price_ctx = null;
    w.sell_price_fn = &Hook.price;
    w.percent_uses_left_ctx = null;
    w.percent_uses_left_fn = &Pul.pul;
    // 50 (starter) + 2 x (100 x 1.0 qmod x 0.5 pul) = 150.
    try std.testing.expect(trade(&w, 0, trader_id, 77, 2, 1, 6));
    try std.testing.expectEqual(@as(u32, 150), w.wallet[ps].coins);
    // A fresh stack (use_times 0) pays full price: the wallet gains 200
    // more (2 x 100) on top of the 150 from the worn sale.
    w.inventory[ps].slots[0] = .{ .item_id = 77, .count = 2, .quality = 1 };
    try std.testing.expect(trade(&w, 0, trader_id, 77, 2, 1, 6));
    try std.testing.expectEqual(@as(u32, 350), w.wallet[ps].coins);
}

test "stealth noise: a loud clip folds into the player and alerts a zombie" {
    // RE entity-ai.md PlayerStealth: a relayed sound with a sounds.xml Noise
    // row accumulates into the player's stealth list; CalcVolume + the heard
    // test alert an idle zombie within the attraction radius (it investigates
    // the player's spot, same tick — stealth runs before the AI pass).
    var w: World = .{ .rules = .{ .ai = .{ .sense_dist_sq = 4 * 4 } } };
    defer w.deinit();
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    const z = w.spawnZombie(10, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    try std.testing.expect(!w.zombie_ai[zs].alert);
    // pipe_pistol_fire (stock V3.1.4): volume 62, 2 s = 40 ticks, muffle 0.8.
    w.pushStealthNoise(ps, 0, 70, 0, 62, 40, 0.8, 0, 0);
    systemStealth(&w);
    // Radius = min(62 x 0.6, 40) = 37.2 covers 10 m; heard = 108.8 / 6.4 >= 1.
    try std.testing.expect(w.zombie_ai[zs].alert);
    try std.testing.expect(w.zombie_ai[zs].state == .chase);
    try std.testing.expect(w.zombie_ai[zs].has_spot);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), w.zombie_ai[zs].spot_x, 0.01);
    // Ring consumed (consume-owns-drain), noise volume is the CalcVolume fold.
    try std.testing.expectEqual(@as(usize, 0), w.stealth_noise_n);
    try std.testing.expect(w.stealth[ps].noise_volume > 50.0);
}

test "stealth noise: crouch muffle scales the noise volume" {
    // RE AIDirector.NotifyNoise: a crouched instigator's volumeScale is
    // multiplied by the clip's muffled_when_crouched before the fold.
    var w: World = .{};
    defer w.deinit();
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    // stepdirt (V3.1.4): volume 5, muffle 0.507.
    w.pushStealthNoise(ps, 0, 70, 0, 5, 20, 0.507, 0, 0);
    systemStealth(&w);
    const standing = w.stealth[ps].noise_volume;
    // The entry itself is unfolded (5); the muffle scales the fold.
    try std.testing.expectApproxEqAbs(@as(f32, 5), w.stealth[ps].noises[0].volume, 0.001);
    w.stealth[ps] = .{};
    w.player[ps].crouching = true;
    w.pushStealthNoise(ps, 0, 70, 0, 5, 20, 0.507, 0, 0);
    systemStealth(&w);
    const crouched = w.stealth[ps].noise_volume;
    try std.testing.expect(crouched < standing);
    // Entry volume carries the muffle: 5 x 0.507.
    try std.testing.expectApproxEqAbs(@as(f32, 5 * 0.507), w.stealth[ps].noises[0].volume, 0.001);
}

test "stealth noise: sleeper-volume cap queues a volume wake, then decays" {
    // RE PlayerStealth.NotifyNoise: the curved volume accumulates into
    // sleeperNoiseVolume (cap 360 → World.CheckSleeperVolumeNoise) and decays
    // 2.5/tick once the loud-noise wait window elapses.
    var w: World = .{};
    defer w.deinit();
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    // Loud: volume 120 → eff = 60 + 60^1.4 ~ 368.5 > 360 → cap + wake.
    w.pushStealthNoise(ps, 0, 70, 0, 120, 80, 1.0, 0, 0);
    systemStealth(&w);
    try std.testing.expectEqual(@as(f32, 360.0), w.stealth[ps].sleeper_noise_volume);
    try std.testing.expectEqual(@as(usize, 1), w.sleeper_volume_noise_n);
    // Loud noise holds the decay for the wait window (stock 20 ticks).
    for (0..10) |_| systemStealth(&w);
    try std.testing.expectEqual(@as(f32, 360.0), w.stealth[ps].sleeper_noise_volume);
    for (0..10) |_| systemStealth(&w);
    try std.testing.expect(w.stealth[ps].sleeper_noise_volume < 360.0);
    // Quiet noise (stepcloth 3 < loud 11) decays immediately: 3 - 2.5 = 0.5.
    w.stealth[ps] = .{};
    w.pushStealthNoise(ps, 0, 70, 0, 3, 20, 1.0, 0, 0);
    systemStealth(&w);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), w.stealth[ps].sleeper_noise_volume, 0.001);
    systemStealth(&w);
    try std.testing.expectEqual(@as(f32, 0.0), w.stealth[ps].sleeper_noise_volume);
}

test "stealth noise: a sleeping zombie that hears wakes" {
    // RE PlayerStealth attraction: a sleeping zombie inside the attraction
    // radius that passes the heard test wakes and investigates (the separate
    // 360-cap volume wake covers whole volumes).
    var w: World = .{ .rules = .{ .ai = .{ .sense_dist_sq = 4 * 4 } } };
    defer w.deinit();
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    const z = w.spawnSleeperDef(5, 70, 0, .{ .name = "sl", .hash = 1, .kind = .zombie }, 0).?;
    const zs = w.slotOfNetId(z).?;
    try std.testing.expect(!w.sleeper[zs].awake);
    // stepbush (V3.1.4): volume 11 — radius 6.6 covers 5 m, heard ~ 7 >= 1.
    w.pushStealthNoise(ps, 0, 70, 0, 11, 60, 0.507, 0, 0);
    systemStealth(&w);
    try std.testing.expect(w.sleeper[zs].awake);
    try std.testing.expectEqual(@as(usize, 1), w.sleeper_wake_n);
    try std.testing.expectEqual(zs, w.sleeper_wake_reqs[0].slot);
}

test "stealth noise: heat rows feed the activity map" {
    // RE AIDirector.NotifyNoise: heat_map_strength > 0 adds activity to the
    // heat map for the region (x10 ticks, stock AddAudioData heatMapTime).
    var w: World = .{};
    defer w.deinit();
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    // Auger_Fire_Start (V3.1.4): heat 1.0 for 90 s.
    w.pushStealthNoise(ps, 0, 70, 0, 60, 40, 1.0, 1.0, 90);
    systemStealth(&w);
    try std.testing.expectEqual(@as(usize, 1), w.director.heat_n);
    // notifyActivity: activity = value, decay = value / (duration_ticks / 20)
    // per second — 90 s x 10 ticks = 900 ticks → 1.0 / 45 s.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), w.director.heat[0].activity, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 45.0), w.director.heat[0].decay, 0.0001);
}
