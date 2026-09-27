//! Sensing helpers: LOD scale, player snaps, LOS, stealth light,
//! sight/smell gates, revenge targets, path stepping.
//!
//! Split out of ecs/systems.zig (same code, moved verbatim);
//! re-exported so existing `systems.*` call sites keep working.

const std = @import("std");
const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const EntityClass = @import("world.zig").EntityClass;
const max_entities = @import("world.zig").max_entities;
const c = @import("components.zig");
const query = @import("query.zig");
const senseDistSq = @import("ai_tasks.zig").senseDistSq;
const applyGravity = @import("damage_apply.zig").applyGravity;

pub fn lodScale(w: *const World, d2: f32) f32 {
    if (d2 < w.rules.ai.mid_dist_sq) return 1.0;
    if (d2 < w.rules.ai.full_dist_sq) return 0.3;
    return 0.1;
}

pub const PlayerSnap = struct {
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

/// Capacity of one tick's player snapshot. A slot-ascending group walk fills
/// the first `max_players` entries; extra players are not sensed (stock
/// EAISetNearestEntityAsTarget is a bounded local search too).
pub const max_players: usize = 64;

/// One tick's player snapshot: the AoS snaps every AI gate reads, plus the
/// x/z pair packed into its own columns. The per-zombie distance scan
/// (`nearestSq`, `anyWithin`) runs over the columns eight lanes at a time
/// instead of striding the 40-byte snap, which is the inner loop of the AI
/// pass and of the despawn pass.
pub const PlayerScan = struct {
    snaps: [max_players]PlayerSnap = undefined,
    xs: [max_players]f32 = undefined,
    zs: [max_players]f32 = undefined,
    n: usize = 0,

    pub fn slice(self: *const PlayerScan) []const PlayerSnap {
        return self.snaps[0..self.n];
    }
};

/// Scalar reference for `anyWithin`. Tests only.
pub fn anyWithinRef(scan: *const PlayerScan, x: f32, z: f32, d2: f32) bool {
    for (0..scan.n) |i| {
        const dx = scan.xs[i] - x;
        const dz = scan.zs[i] - z;
        if (dx * dx + dz * dz < d2) return true;
    }
    return false;
}

/// Indices of the first `n` entries of the packed columns lying within
/// `r2` (inclusive) of (x, z), written to `out` in ascending order. The
/// combat-noise fan-out walks a whole mob group per event, so the radius test
/// is a map, not a search: eight lanes at a time, scalar tail. `out` must
/// hold `n` entries; the count returned is how many were written.
pub fn withinRadius(out: []Slot, xs: []const f32, zs: []const f32, n: usize, x: f32, z: f32, r2: f32) usize {
    std.debug.assert(out.len >= n);
    const vx: dist_v = @splat(x);
    const vz: dist_v = @splat(z);
    const vr2: dist_v = @splat(r2);
    var k: usize = 0;
    var i: usize = 0;
    while (i + dist_lanes <= n) : (i += dist_lanes) {
        const cx: dist_v = xs[i..][0..dist_lanes].*;
        const cz: dist_v = zs[i..][0..dist_lanes].*;
        const dx = cx - vx;
        const dz = cz - vz;
        const hit: @Vector(dist_lanes, bool) = (dx * dx + dz * dz) <= vr2;
        // A bool vector has no runtime lane index, so the mask becomes a bit
        // word: bit j is lane j, and clearing the low bit walks the hits in
        // ascending lane order.
        var bits: u8 = @bitCast(hit);
        while (bits != 0) {
            out[k] = @intCast(i + @ctz(bits));
            k += 1;
            bits &= bits - 1;
        }
    }
    while (i < n) : (i += 1) {
        const dx = xs[i] - x;
        const dz = zs[i] - z;
        if (dx * dx + dz * dz <= r2) {
            out[k] = @intCast(i);
            k += 1;
        }
    }
    return k;
}

/// Scalar reference for `withinRadius`. Tests only.
pub fn withinRadiusRef(out: []Slot, xs: []const f32, zs: []const f32, n: usize, x: f32, z: f32, r2: f32) usize {
    var k: usize = 0;
    for (0..n) |i| {
        const dx = xs[i] - x;
        const dz = zs[i] - z;
        if (dx * dx + dz * dz <= r2) {
            out[k] = @intCast(i);
            k += 1;
        }
    }
    return k;
}

/// Pack literal snaps into a scan. Fixtures and tests build one this way
/// instead of a world; production fills it through `snapshotPlayers`.
pub fn scanFromSnaps(out: *PlayerScan, snaps: []const PlayerSnap) void {
    out.n = @min(snaps.len, max_players);
    for (out.snaps[0..out.n], 0..) |*dst, i| {
        dst.* = snaps[i];
        out.xs[i] = snaps[i].x;
        out.zs[i] = snaps[i].z;
    }
}

/// Lanes per distance step. 8 f32 lanes is one AVX register (or two SSE
/// halves) and divides `max_players`, so the full-column path never peels.
const dist_lanes: usize = 8;
const dist_v = @Vector(dist_lanes, f32);

/// A player standing exactly on the sensed position is not a target (the
/// scalar gate's `d > 0.0001`); shared so the vector prefilter and the
/// scalar reference agree on the edge.
const min_target_d2: f32 = 0.0001;

/// Index of the nearest snap with `min_target_d2 < d2 < max_d2`, or null when
/// none qualifies. Ties go to the lowest index, matching the scalar scan's
/// strict `<` (a later player at the same distance never displaces the
/// earlier one).
pub fn nearestSq(scan: *const PlayerScan, x: f32, z: f32, max_d2: f32) ?usize {
    const vx: dist_v = @splat(x);
    const vz: dist_v = @splat(z);
    const vmin: dist_v = @splat(min_target_d2);
    const vmax: dist_v = @splat(max_d2);
    var best: f32 = max_d2;
    var best_i: usize = max_players;
    var i: usize = 0;
    while (i + dist_lanes <= scan.n) : (i += dist_lanes) {
        const xs: dist_v = scan.xs[i..][0..dist_lanes].*;
        const zs: dist_v = scan.zs[i..][0..dist_lanes].*;
        const dx = xs - vx;
        const dz = zs - vz;
        const d = dx * dx + dz * dz;
        // Lanes outside the range (or on the exact position) are pushed to
        // +inf so they cannot win the min and never become the index.
        const keep = @select(f32, (d > vmin) & (d < vmax), d, @as(dist_v, @splat(std.math.inf(f32))));
        const lane_min = @reduce(.Min, keep);
        if (lane_min >= best) continue;
        best = lane_min;
        // Lowest lane holding the min, so the tie-break is the lowest index.
        const hit: @Vector(dist_lanes, bool) = keep == @as(dist_v, @splat(lane_min));
        const bits: u8 = @bitCast(hit);
        best_i = i + @ctz(bits);
    }
    // Tail lanes (scan.n not a multiple of dist_lanes) and lanes whose
    // candidate loses on distance are settled by the scalar reference, which
    // owns the same tie-break.
    var t = (scan.n / dist_lanes) * dist_lanes;
    while (t < scan.n) : (t += 1) {
        const dx = scan.xs[t] - x;
        const dz = scan.zs[t] - z;
        const d = dx * dx + dz * dz;
        if (d > min_target_d2 and d < best) {
            best = d;
            best_i = t;
        }
    }
    if (best_i == max_players) return null;
    return best_i;
}

/// Scalar reference for `nearestSq`. Tests only.
pub fn nearestSqRef(scan: *const PlayerScan, x: f32, z: f32, max_d2: f32) ?usize {
    var best: f32 = max_d2;
    var best_i: usize = max_players;
    for (0..scan.n) |i| {
        const dx = scan.xs[i] - x;
        const dz = scan.zs[i] - z;
        const d = dx * dx + dz * dz;
        if (d < best and d > min_target_d2) {
            best = d;
            best_i = i;
        }
    }
    return if (best_i == max_players) null else best_i;
}

/// Whether any snap is strictly closer than `d2` to (x, z).
pub fn anyWithin(scan: *const PlayerScan, x: f32, z: f32, d2: f32) bool {
    const vx: dist_v = @splat(x);
    const vz: dist_v = @splat(z);
    const vmax: dist_v = @splat(d2);
    var i: usize = 0;
    while (i + dist_lanes <= scan.n) : (i += dist_lanes) {
        const xs: dist_v = scan.xs[i..][0..dist_lanes].*;
        const zs: dist_v = scan.zs[i..][0..dist_lanes].*;
        const dx = xs - vx;
        const dz = zs - vz;
        if (@reduce(.Or, (dx * dx + dz * dz) < vmax)) return true;
    }
    var t = (scan.n / dist_lanes) * dist_lanes;
    while (t < scan.n) : (t += 1) {
        const dx = scan.xs[t] - x;
        const dz = scan.zs[t] - z;
        if (dx * dx + dz * dz < d2) return true;
    }
    return false;
}

/// Player positions for AI targeting / despawn. When `skip_blood_moon_dead` is
/// set, players who died during the active blood moon are excluded (stock
/// EAISetNearestEntityAsTarget skips IsBloodMoonDead players, so the horde
/// hunts the living); the despawn pass keeps them so a corpse still pins
/// distant zombies.
pub fn snapshotPlayers(w: *const World, out: *PlayerScan, skip_blood_moon_dead: bool) usize {
    var n: usize = 0;
    // Cached player group instead of a 512-slot scan; it is slot-ascending, so
    // the first 64 entries are the same 64 in the same order (nearest-player
    // tie-breaks depend on it). Nothing here spawns or destroys.
    for (query.groupSlice(w, .player)) |j| {
        if (n >= out.snaps.len) break;
        if (!w.mask[j].player or !w.mask[j].transform) continue;
        if (skip_blood_moon_dead and w.player[j].is_blood_moon_dead) continue;
        out.xs[n] = w.transform[j].x;
        out.zs[n] = w.transform[j].z;
        out.snaps[n] = .{
            .id = w.network_id[j].id,
            .slot = j,
            .x = w.transform[j].x,
            .y = w.transform[j].y,
            .z = w.transform[j].z,
            .crouching = w.player[j].crouching,
            .light_level = stealthLightLevel(w.ambient_light, w.heldLightFor(j), w.player[j].crouching, w.stealth_light_mult[j], w.stealth[j].speed_average),
            .self_light = w.heldLightFor(j),
        };
        n += 1;
    }
    out.n = n;
    return n;
}

/// Winner of the AITarget pass: the entity the AITask list treats as "the
/// player" for this tick (nearest sensed, or the attacker via revenge).
pub const TargetSnap = struct { id: i32, slot: Slot, d2: f32, px: f32, pz: f32 };

/// Block-LOS between the zombie head (y+1.6) and the target head (y+1.6),
/// stepping the segment in ~0.8 block increments (stock CanSee's
/// `Voxel.Raycast`, entity-ai.md). A solid cell anywhere between blocks sight;
/// an unloaded/missing chunk counts as clear (nothing to hide behind yet).
fn losClear(w: *const World, zx: f32, zy: f32, zz: f32, px: f32, py: f32, pz: f32) bool {
    // Sight uses its own oracle (stock `IsSeeThrough` reads the Collide sight
    // bit and treats water as opaque); without one it keeps the old movement
    // predicate, so an offline or fixture world behaves exactly as before.
    const solid_fn = w.sight_fn orelse (w.solid_fn orelse return true);
    const solid_ctx = if (w.sight_fn != null) w.sight_ctx else w.solid_ctx;
    const zy2 = zy + 1.6;
    const py2 = py + 1.6;
    const dx = px - zx;
    const dy = py2 - zy2;
    const dz = pz - zz;
    const dist = @sqrt(dx * dx + dy * dy + dz * dz);
    if (dist < 0.001) return true;
    const steps: usize = @intCast(@min(@as(u32, @trunc(dist / 0.8)), 64));
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

/// Stock `PlayerStealth.TickServer` (IL=432, full-v3.2.0 dump): the
/// `lightAttackPercent` fed to `CanSleeperAttackDetect`'s `FastLerp(3, 15,
/// t)` crouch range. The IL check is on the **selfLight** out param of
/// GetStealthLightLevel (the held-item light, IL_010B: `selfLight < 0.1` →
/// passive-89 else 1) - not the day/night ambient. Wired 2026-08-27: the
/// held item's items.xml LightValue (torch .35, flashlight .55) raises the
/// crouch reach to the full 15 when held.
pub fn stealthLightAttackPercent(self_light: f32, passive: f32) f32 {
    return if (self_light < stealth_self_light_dark) passive else 1.0;
}

/// Stock `PlayerStealth.TickServer` pre-blend light (IL_0078-00B9):
/// GetStealthLightLevel (slice-1 ambient + the selfLight held-item blend,
/// RE entity-ai.md: ratio = FastClamp(selfLight / (light + 0.05), 0.5, 3.2),
/// light += selfLight x ratio; selfLight = the AlwaysActive held item's
/// items.xml LightValue, Inventory.GetLightLevel IL=76), crouch ×0.6
/// (IL_00A6). Stock writes this x100 into the `_lightlevel` cvar (IL_00B9)
/// before the speed scale and the passive blend below.
pub fn stealthLightPreBlend(ambient_light: f32, self_light: f32, crouching: bool) f32 {
    var light = ambient_light;
    if (self_light > 0) {
        const ratio = std.math.clamp(self_light / (light + 0.05), 0.5, 3.2);
        light += self_light * ratio;
    }
    light *= if (crouching) stealth_crouch_light_scale else 1.0;
    return light;
}

/// Stock `PlayerStealth.TickServer` lightLevel (IL=0131-014F): the stealth
/// light byte consumed by both the NetPackageEntityStealth S2C (Setup IL=26
/// conv.u1 of lightLevel) and the CanSeeStealth sight gate. Chain: the
/// pre-blend light above, the speedAverage visibility scale (1 + speed×0.15,
/// IL_00CD, 0 for a standing player), then `lightLevel = clamp(light ×
/// (0.32 + 0.68 × passive89) × 100, 0, 200)`. passive89 = the cached
/// LightMultiplier fold (1.0 offline).
pub fn stealthLightLevel(ambient_light: f32, self_light: f32, crouching: bool, passive: f32, speed_average: f32) f32 {
    var light = stealthLightPreBlend(ambient_light, self_light, crouching);
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
pub fn canSensePlayer(
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

pub fn nearestPlayerSnap(w: *const World, scan: *const PlayerScan, zslot: Slot, zx: f32, zy: f32, zz: f32, zyaw: f32) TargetSnap {
    // `BlockIf condition=alert e 0` (the hostile-animal template): while the
    // entity is unalerted the executing BlockIf holds MutexBits=1 over
    // SetNearestEntityAsTarget, so no fresh sense acquisition. Revenge and
    // the latched aggro below still run (SetAsTargetIfHurt is priority 1 and
    // hurt sets alert, which drops this gate). Bit 1 = alert arm parsed.
    const sense_d2 = w.rules.ai.sense_dist_sq;
    const none: TargetSnap = .{ .id = -1, .slot = 0, .d2 = sense_d2, .px = zx, .pz = zz };
    if (w.class_id[zslot].block_if_alert_only & 2 != 0 and !w.zombie_ai[zslot].alert) {
        return none;
    }
    // Distance prefilter: the packed columns give the nearest in-range player
    // in eight lanes at a time, which is what every zombie in the pass asks
    // for. A zombie out of earshot of everyone (the common case) returns
    // without touching the gates below.
    const near = nearestSq(scan, zx, zz, sense_d2) orelse return none;
    var best_id: i32 = -1;
    var best_slot: Slot = 0;
    var best_d: f32 = sense_d2;
    var px: f32 = zx;
    var pz: f32 = zz;
    // The winner is the global minimum over the same candidates the scalar
    // scan considers, so when it passes its gate the answer is the nearest
    // sensed player either way. A rejected winner (blocked sight, muffled
    // hearing) falls through to the full scan, which then walks the
    // remaining candidates in order.
    for (scan.slice(), 0..) |p, i| {
        const dx = p.x - zx;
        const dz = p.z - zz;
        const d = dx * dx + dz * dz;
        if (d < best_d and d > min_target_d2) {
            // Smell passes walls (RE PlayerStealth cSmellRadius*): within the
            // player's effective smell radius the zombie senses regardless of
            // sight or hearing (a bleeding player reeks from further away).
            const smell = smellRadiusFor(w, p.slot);
            // Stealth (RE PlayerStealth NotifyNoise): a crouched player's
            // movement noise is muffled, so the hearing gate shrinks by
            // crouch_hear_scale. The AITarget player hear distance wins over
            // the Rules floor when set (stock `EAISetNearestEntityAsTarget`
            // hearDistMax; hear 0 reads 50 at parse, so nonzero = declared).
            const hear_base = w.class_id[zslot].target_player_hear;
            const hear_rule = if (hear_base != 0) hear_base else w.rules.ai.hear_range;
            const hear = if (p.crouching) hear_rule * w.rules.ai.crouch_hear_scale else hear_rule;
            if (d >= smell * smell and !canSensePlayer(w, zslot, zx, zy, zz, zyaw, p.x, p.y, p.z, hear, p.light_level)) continue;
            best_d = d;
            best_id = p.id;
            best_slot = p.slot;
            px = p.x;
            pz = p.z;
            if (i == near) break;
        }
    }
    return .{ .id = best_id, .slot = best_slot, .d2 = best_d, .px = px, .pz = pz };
}

/// A target snap whose `slot` is the sentinel `max_entities` is a host-side
/// bot (ADR 0026): bots are not ECS entities, so the zombie AI reaches them
/// through the World's `bot_snap_fn` / `bot_damage_fn` hooks instead of a slot.
pub fn targetExternal(np: TargetSnap) bool {
    return np.slot >= max_entities;
}

/// Resolve a target net id to a live ECS slot, or to a live host-side bot via
/// the bot hook (ADR 0026). Aggro-persistence gates use this so a bot target
/// keeps the chase alive exactly like an ECS entity target.
pub fn targetLive(w: *const World, net_id: i32) bool {
    if (net_id < 0) return false;
    if (w.slotOfNetId(net_id) != null) return true;
    const f = w.bot_snap_fn orelse return false;
    const b = f(w.bot_snap_ctx, 0, 0, 0, net_id);
    return b.net_id == net_id;
}

/// Nearest live bot within `range_sq` of (zx, zz), or an empty snap (id -1).
/// `exact >= 0` resolves that one net id instead (any range - revenge); the
/// World's `bot_snap_fn` (Game side, BotManager) answers both. A null hook
/// means no bots exist. Read-only against the BotManager, which is quiescent
/// during the parallel AI pass (bots integrate after it in the tick).
pub fn nearestBotSnap(w: *const World, zx: f32, zz: f32, range_sq: f32, exact: i32) TargetSnap {
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
pub fn applyRevengeTarget(w: *const World, pos: *const [max_entities]c.Transform, s: Slot, ai: *c.ZombieAi, np: TargetSnap, dt: f32) TargetSnap {
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
    // `SetAsTargetIfHurt class=` filter (entityclasses AITarget-1): a
    // class-filtered entry retargets only when the attacker's kind is named.
    // Bit 1 = EntityPlayer (mask.player), bit 3 = EntityEnemyAnimal (animal
    // kind); bit 2 = EntityBandit, which has no sim entity and never matches.
    // 0 (no filtered entry, incl. bare entries) keeps the legacy
    // always-retarget path. Turret attackers have no kind and always pass
    // (legacy attribution only ever carried player/turret).
    const hb = w.class_id[s].hurt_target_classes;
    if (hb & 1 != 0) {
        const is_player = w.mask[ts].player;
        const is_enemy_animal = w.mask[ts].kind and w.kind[ts] == .animal;
        if (is_player and hb & 2 == 0) return np;
        if (is_enemy_animal and hb & 8 == 0) return np;
        if (!is_player and !is_enemy_animal) {
            // Turrets (no kind mask) pass; zombies/bandits do not match any
            // named stock class here.
            if (w.mask[ts].kind) return np;
        }
    }
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
pub fn stepToward(w: *World, s: Slot, tx: f32, tz: f32, speed: f32, dt: f32) void {
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

test "blood-moon-dead players are skipped as AI targets but kept for despawn" {
    var w: World = .{};
    defer w.deinit();
    // spawnPlayer(x, y, z, peer_slot): second player must use peer 1, not peer 0
    // (peer 0 would replace the first body under the one-entity-per-peer rule).
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    _ = w.spawnPlayer(1, 70, 5, 1).?;
    const ps = w.playerByPeer(1).?;
    w.player[ps].is_blood_moon_dead = true; // died during the horde
    var scan: PlayerScan = .{};
    const ai_n = snapshotPlayers(&w, &scan, true);
    try std.testing.expectEqual(@as(usize, 1), ai_n);
    const des_n = snapshotPlayers(&w, &scan, false);
    try std.testing.expectEqual(@as(usize, 2), des_n);
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
    var scan: PlayerScan = .{};
    scanFromSnaps(&scan, &snaps);
    const t = nearestPlayerSnap(&w, &scan, 0, 0, 70, 0, 90.0);
    try std.testing.expectEqual(@as(i32, 101), t.id);
    try std.testing.expectEqual(@as(Slot, 1), t.slot);
    // Both players at 20 m (beyond every non-bleed radius): nobody sensed.
    const far_snaps = [_]PlayerSnap{
        .{ .id = 100, .slot = 0, .x = 20, .y = 70, .z = 0 },
        .{ .id = 101, .slot = 1, .x = 20, .y = 70, .z = 0 },
    };
    var far_scan: PlayerScan = .{};
    scanFromSnaps(&far_scan, &far_snaps);
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
    const t2 = nearestPlayerSnap(&w2, &far_scan, 0, 0, 70, 0, 90.0);
    try std.testing.expectEqual(@as(i32, -1), t2.id);
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

test "player distance scan: vector prefilter matches the scalar reference" {
    // The AI and despawn passes read these columns for every mob, so the
    // eight-lane path must agree with the scalar reference on the nearest
    // index, on ties, and on the tail (scan.n need not be a lane multiple).
    var prng = std.Random.DefaultPrng.init(0x5117_2ea1);
    const rnd = prng.random();
    var scan: PlayerScan = .{};
    var round: usize = 0;
    while (round < 256) : (round += 1) {
        scan.n = rnd.intRangeAtMost(usize, 0, max_players);
        for (0..scan.n) |i| {
            scan.xs[i] = rnd.float(f32) * 200.0 - 100.0;
            scan.zs[i] = rnd.float(f32) * 200.0 - 100.0;
            scan.snaps[i] = .{ .id = @intCast(i), .slot = @intCast(i), .x = scan.xs[i], .y = 70, .z = scan.zs[i] };
        }
        const x = rnd.float(f32) * 200.0 - 100.0;
        const z = rnd.float(f32) * 200.0 - 100.0;
        const max_d2 = rnd.float(f32) * 6000.0;
        try std.testing.expectEqual(nearestSqRef(&scan, x, z, max_d2), nearestSq(&scan, x, z, max_d2));
        // anyWithin is the despawn pass's "a player pins this mob" test.
        var want = false;
        for (0..scan.n) |i| {
            const dx = scan.xs[i] - x;
            const dz = scan.zs[i] - z;
            if (dx * dx + dz * dz < max_d2) want = true;
        }
        try std.testing.expectEqual(want, anyWithin(&scan, x, z, max_d2));
    }
}

test "player distance scan: ties keep the lower index and out-of-range players drop out" {
    var snaps = [_]PlayerSnap{
        .{ .id = 10, .slot = 0, .x = 10, .y = 70, .z = 0 },
        .{ .id = 11, .slot = 1, .x = -10, .y = 70, .z = 0 },
        .{ .id = 12, .slot = 2, .x = 0, .y = 70, .z = 3 },
    };
    var scan: PlayerScan = .{};
    scanFromSnaps(&scan, &snaps);
    // p0 and p1 tie at 10 m: the scalar scan's strict `<` keeps the first,
    // and so must the vector reduce, but p2 at 3 m outranks both.
    try std.testing.expectEqual(@as(?usize, 2), nearestSq(&scan, 0, 0, 1000));
    // A range that only reaches p2.
    try std.testing.expectEqual(@as(?usize, 2), nearestSq(&scan, 0, 0, 50));
    // Nobody in range.
    try std.testing.expectEqual(@as(?usize, null), nearestSq(&scan, 0, 0, 5));
    // A player standing on the sensed position is not a target, so the scan
    // from that spot picks the next one out.
    try std.testing.expectEqual(@as(?usize, 0), nearestSq(&scan, -10, 0, 1000));
    try std.testing.expect(anyWithin(&scan, 0, 0, 101));
    try std.testing.expect(!anyWithin(&scan, 0, 0, 9));
}

test "radius fan-out: vector mask matches the scalar reference" {
    // The combat-noise pass maps every mob through one radius test, so the
    // hit set (and its order: the sleeper-wake ring is drained in it) has to
    // come out identical, tails included.
    var prng = std.Random.DefaultPrng.init(0x9a1e_5d3f);
    const rnd = prng.random();
    var xs: [64]f32 = undefined;
    var zs: [64]f32 = undefined;
    var got: [64]Slot = undefined;
    var want: [64]Slot = undefined;
    var round: usize = 0;
    while (round < 256) : (round += 1) {
        const n = rnd.intRangeAtMost(usize, 0, xs.len);
        for (0..n) |i| {
            xs[i] = rnd.float(f32) * 400.0 - 200.0;
            zs[i] = rnd.float(f32) * 400.0 - 200.0;
        }
        const x = rnd.float(f32) * 400.0 - 200.0;
        const z = rnd.float(f32) * 400.0 - 200.0;
        const r2 = rnd.float(f32) * 40000.0;
        const gn = withinRadius(got[0..], xs[0..], zs[0..], n, x, z, r2);
        const wn = withinRadiusRef(want[0..], xs[0..], zs[0..], n, x, z, r2);
        try std.testing.expectEqual(wn, gn);
        try std.testing.expectEqualSlices(Slot, want[0..wn], got[0..gn]);
    }
}
