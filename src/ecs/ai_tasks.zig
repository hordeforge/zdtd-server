//! Combat AI: stock EAITask prioritized task graph, parallel over slots.
//!
//! Split out of ecs/systems.zig (same code, moved verbatim);
//! re-exported so existing `systems.*` call sites keep working.

const std = @import("std");
const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const EntityClass = @import("world.zig").EntityClass;
const max_entities = @import("world.zig").max_entities;
const c = @import("components.zig");
const systems = @import("systems.zig");
const TargetSnap = systems.TargetSnap;
const PlayerScan = systems.PlayerScan;
const snapshotPlayers = systems.snapshotPlayers;
const nearestPlayerSnap = systems.nearestPlayerSnap;
const applyRevengeTarget = systems.applyRevengeTarget;
const stealthLightAttackPercent = systems.stealthLightAttackPercent;
const targetLive = systems.targetLive;
const targetExternal = systems.targetExternal;
const nearestBotSnap = systems.nearestBotSnap;
const stepToward = systems.stepToward;
const consumeCombatNoise = systems.consumeCombatNoise;
const systemStealth = systems.systemStealth;
const applyGravity = systems.applyGravity;
const lodScale = systems.lodScale;
const applyDeferredDamage = systems.applyDeferredDamage;
const systemDigUpdate = systems.systemDigUpdate;
/// Fixed-point damage unit (1.0 hp = 100). Mirrors systems.zig.
const dmg_scale: u32 = 100;
const protocol = @import("../protocol.zig");
const builtin = @import("builtin");
const systemDespawnFar = @import("despawn.zig").systemDespawnFar;
const path_mod = @import("path.zig");
const query = @import("query.zig");
const parallel = @import("../util/parallel.zig");
const rng_util = @import("../util/rng.zig");

// --- Combat AI: stock EAITask prioritized task graph (parallel over slots) ---
//
// Faithful port of EAITaskList::OnUpdateTasks + isBestTask (asm.il:437713,
// :437874). Each zombie's AI is an ordered task list; every tick the winning
// task is (re)selected by priority + MutexBits and projected back onto the
// coarse ZombieAi.state enum so downstream replication (game.zig EntitySpeeds/
// AliveFlags, block-damage, despawn) keeps working unchanged.
//
// Eleven real tasks: BreakBlock, DestroyArea, RunawayWhenHurt, ApproachAndAttackTarget,
// ApproachDistraction, Territorial, ApproachSpot, Look, Wander, Leap (the EAILeap
// pounce, 2026-09-22: zombieSpider/animalMountainLion), and RangedAttackTarget
// (the acid spit, 2026-09-22: the five spitter classes, vomit config from
// items.xml). Every task name stock assigns to a class now maps; the census
// lives in ../7dtd-engine-research/docs/entities/entity-ai.md. Dodge is
// client-animator only and unreferenced by stock XML.
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
    // EAILeap (EAILeap.il.txt): MutexBits=3, first in the zombieSpider /
    // animalMountainLion AITask lists, so it sits ahead of approach_attack and
    // shares its exclusive movement mutex. continuous stays false for the same
    // reason approach_attack's does: a continuous priority-1 task lets the
    // wander fallback steal the walk through isBestTask's continuous yield.
    .{ .id = .leap, .priority = 1, .mutex = 0b11, .execute_delay = 0.1, .continuous = false },
    // EAIRangedAttackTarget (full-v3.2.0 EAIRangedAttackTarget.il.txt Init:
    // MutexBits 0b1011, cooldown 3 s / attackDuration 20 s defaults that the
    // class AITask entry overrides; EAIBase executeDelay 0.5, IsContinuous
    // default true, unread at priority 1). Before ApproachAndAttackTarget the
    // way every spitter class lists it (BreakBlock|ApproachDistraction|
    // RangedAttackTarget|ApproachAndAttackTarget|...), so the scan reaches the
    // spit first when the target sits in the range window; the 0b1011 mutex
    // shares only with the block-chew tasks, exactly like stock's bits.
    .{ .id = .ranged_attack_target, .priority = 1, .mutex = 0b1011, .execute_delay = 0.5, .continuous = true },
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

/// EAILeap::CanExecute (EAILeap.il.txt): a sensed target sitting between the
/// stock 2.8 m floor and the class's rolled `jumpMaxDistance`, with the body
/// grounded and off jump cooldown. A class whose `jump_max` never clears the
/// floor (the 1.9-2.1 cctor default, i.e. no `JumpMaxDistance` row) can never
/// pass, so only zombieSpider / animalMountainLion pounce. Stock then takes
/// two more legs: the leapV.y window [-5, 0.5 + 0.5*jumpMaxDistance]
/// (refuses deep falls and high climbs) and the physics ray from feet + 1.5
/// along the corridor for leapDist - 0.5 (IL_0134-017B), so a wall between
/// zombie and player is walked around, never vaulted. The parsed-list gate
/// keeps zdtd's shared native table (a class with no XML AITask list) from
/// gaining a pounce stock zombieTemplateMale never had.
fn leapCanExecute(w: *const World, s: Slot, ai: *const c.ZombieAi, np: TargetSnap, sense_d2: f32) bool {
    // Already airborne: the flight owns the entity until it lands, so the
    // selection pass must keep re-electing the task (stock's jump state does
    // the same by holding the mutex).
    if (ai.leaping) return true;
    if (w.class_id[s].ai_tasks == 0) return false;
    const max_d = w.class_id[s].jump_max;
    const min_d = w.rules.ai.leap_min_dist;
    if (max_d < min_d) return false;
    if (ai.jumping or ai.jump_cd > 0) return false;
    if (!(np.id >= 0 and np.d2 < sense_d2)) return false;
    if (!(np.d2 >= min_d * min_d and np.d2 <= max_d * max_d)) return false;
    const t = &w.transform[s];
    const tgt = w.transform[np.slot];
    const dy = tgt.y - t.y;
    if (dy < leap_dy_min or dy > 0.5 + 0.5 * max_d) return false;
    const dx = np.px - t.x;
    const dz = np.pz - t.z;
    const dist = @sqrt(dx * dx + dz * dz);
    if (dist < 0.001) return false;
    const scale = (dist - 0.5) / dist;
    return leapRayClear(w, t.x, t.y + 1.5, t.z, t.x + dx * scale, t.y + 1.5 + dy * scale, t.z + dz * scale);
}

/// Stock EAILeap.CanExecute's lower leapV.y bound (IL_00BF): a path end more
/// than 5 m below the body refuses the pounce.
const leap_dy_min: f32 = -5;

/// The physics ray from EAILeap.CanExecute (IL_0134-017B): origin feet + 1.5
/// along the leap vector for leapDist - 0.5, any solid cell refuses. Solid
/// probe with solid_fn, not the sight oracle: stock raycasts the physics
/// layers, so a transparent block still refuses. Unset solid_fn (headless /
/// flat tests) counts as clear.
fn leapRayClear(w: *const World, ox: f32, oy: f32, oz: f32, tx: f32, ty: f32, tz: f32) bool {
    const solid_fn = w.solid_fn orelse return true;
    const ctx = w.solid_ctx;
    const dx = tx - ox;
    const dy = ty - oy;
    const dz = tz - oz;
    const dist = @sqrt(dx * dx + dy * dy + dz * dz);
    if (dist < 0.001) return true;
    const step: f32 = 0.5;
    var i: f32 = step;
    while (i < dist) : (i += step) {
        const f = i / dist;
        if (solid_fn(ctx, @floor(ox + dx * f), @floor(oy + dy * f), @floor(oz + dz * f))) return false;
    }
    return true;
}

/// EAILeap::Continue: the aim budget or the flight, not the start condition.
/// Once launched the arc must run to the landing even though the target has by
/// then moved out of the launch window.
fn leapContinue(ai: *const c.ZombieAi) bool {
    return ai.leaping or ai.leap_time > 0;
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

const ai_steer = @import("ai_steer.zig");
const wrap360 = ai_steer.wrap360;
pub const seekYawStep = ai_steer.seekYawStep;

const AiCtx = struct {
    w: *World,
    dt: f32,
    /// This tick's player snapshot. Read-only for every worker: `slice()` for
    /// the AoS gates, the packed x/z columns for the vectorized distance
    /// prefilter in `nearestPlayerSnap`.
    scan: *const PlayerScan,
    /// Tick-start copy of `w.transform`. A worker owns only its own entries in
    /// `slots`, so every cross-slot position read (fear scan, revenge target)
    /// must come from here: reading `w.transform[other]` races the worker writing it.
    pos: *const [max_entities]c.Transform,
    /// Live zombie+animal slots, slot-ascending snapshot. Workers index this
    /// rather than the 512-slot table so idle capacity is not scanned.
    slots: []const Slot,
    /// Fixed-point damage accumulators, one per entity slot (atomic adds).
    dmg_fp: []u32,
    /// Attacker slot per victim slot, written alongside dmg_fp
    /// (max_entities = unset; zombie melee writes its own slot, turret fire
    /// leaves unset since turrets match no victim filter). Lets the apply
    /// pass resolve victim-side foreign-gated rows (Spectral Grace's
    /// other=zombie,animal filter) against the attacker's real class tags.
    dmg_attacker: []u16,
    hits: *std.atomic.Value(u32),
    /// Snapshotted before forRanges so workers never reread a field the
    /// director (or another tick phase) may rewrite on the main thread.
    zombie_speed_scale: f32,

    fn work(ctx: AiCtx, begin: usize, end: usize) void {
        var i: usize = begin;
        while (i < end) : (i += 1) {
            const s = ctx.slots[i];
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
                for (ctx.scan.slice()) |pl| {
                    const dx = pl.x - sl.home_x;
                    const dz = pl.z - sl.home_z;
                    const dist = @sqrt(dx * dx + dz * dz);
                    if (dist > sl.volume_r) continue; // out of the volume entirely
                    // lightAttackPercent: selfLight < 0.1 → the passive-89
                    // always, a held light (torch/flashlight) raises it to 1,
                    // so the crouch range FastLerp(3, 15, t) stretches to the
                    // full 15.
                    const lap = stealthLightAttackPercent(pl.self_light, ctx.w.stealth_light_mult[pl.slot]);
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
                            ai.explode_ticks = @trunc(delay / 5.0 * 1.5 * 20.0);
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
                    ai.prime_ticks = @trunc(delay * 20.0);
                }
            }

            // EAIRunawayFromEntity (AITask-2): passive animals scan for feared
            // classes (players, zombies, other animals) within fleeDistance on
            // a 0.5 s cadence; the runaway task then flees the nearest one.
            if (ctx.w.kind[s] == .animal) refreshFearSource(ctx.w, ctx.pos, s, ai, ctx.dt);

            // AITarget list before AITask list: a fresh attacker outranks the
            // nearest sensed player for the revenge window.
            var np = applyRevengeTarget(ctx.w, ctx.pos, s, ai, nearestPlayerSnap(ctx.w, ctx.scan, s, ctx.w.transform[s].x, ctx.w.transform[s].y, ctx.w.transform[s].z, ctx.w.transform[s].yaw), ctx.dt);
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
                    resetTask(ctx.w, s, ai.active_task, ai, ctx.w.network_id[s].id);
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
                    if (c.aiTaskAllowed(ctx.w.class_id[s].ai_tasks, t.id) and
                        isBestTask(t, ai.active_task) and
                        canExecute(ctx.w, s, t.id, ai, np))
                    {
                        chosen = t.id;
                        break;
                    }
                }
                // Preemption: stock removes the loser from executingTasks via the
                // same Reset path, so a Wander cut short by Approach still seeds
                // the look-around that plays once the chase ends.
                if (chosen != ai.active_task) resetTask(ctx.w, s, ai.active_task, ai, ctx.w.network_id[s].id);
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
                .leap => leapUpdate(ctx.w, s, ai, np, ctx.dt),
                .ranged_attack_target => rangedUpdate(ctx.w, s, ai, np, ctx.dt),
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
            // A launched leap owns y for the whole arc (advanceLeap is the
            // integrator); the snap resumes on the landing tick.
            if (!ai.leaping) applyGravity(ctx.w, s, ctx.dt);
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
pub fn senseDistSq(w: *const World, s: Slot) f32 {
    // A35 per-entity layer first: the def spawns carry SightRange onto the
    // entity, so a class outside the fixed class_table senses as itself too.
    // The AITarget player see distance wins over SightRange when set (stock
    // `EAISetNearestEntityAsTarget` targetClasses): a zombie whose row says
    // see 20 senses players at 20, not at its 27-40 SightRange. A negative
    // stock value (never target this class) yields a negative square and
    // denies every range check below.
    const tp = w.class_id[s].target_player_see;
    if (tp != 0) return tp * tp;
    const pe = w.class_id[s].sight_range;
    if (pe > 0) return pe * pe;
    const sr = w.class_table[w.class_id[s].id].sight_range;
    if (sr > 0) return sr * sr;
    return w.rules.ai.sense_dist_sq;
}

/// The vomit telegraph window: ItemActionVomit.ReadFrom sets
/// `warningDelay = 1.2` before parsing (ldc.r4 1.2 at IL_0019) and none of
/// the five stock spitter items override it with WarningDelay, so the server
/// waits one fixed window before the burst (stock randomizes the warning
/// count inside it; zdtd fires after the single window - recorded).
const vomit_warning_s: f32 = 1.2;

/// EAIRangedAttackTarget::CanExecute (IL=69-107): not dancing (AI never
/// dances in zdtd); a live sensed target (`np` refresh carries the CanSee
/// stealth/sense result stock tests here); not already leaping, jumping or
/// spitting; InRange = 3D distance inside the class AITask window
/// [minRange, maxRange] (ctor defaults 4..25; the unreachableRange arm needs
/// moveHelper unreachable flags zdtd does not model, so it stays out -
/// recorded). Stock's cooldown drain (IL=02A mutates cooldown inside
/// CanExecute) becomes the absolute ready-tick gate so the gate stays
/// read-only like the others, and the missing-limb leg has no per-limb body
/// damage to read (open, recorded). Fail closed without a vomit config: the
/// task must not aim at a shot it cannot fire.
fn rangedAttackCanExecute(w: *const World, s: Slot, ai: *const c.ZombieAi, np: TargetSnap, sense_d2: f32) bool {
    if (w.class_id[s].ai_tasks == 0) return false;
    if (w.class_id[s].vomit_anim_type < 0) return false;
    if (w.sim_tick < ai.ranged_ready_tick) return false;
    if (ai.leaping or ai.jumping or ai.spit.active or ai.vy != 0) return false;
    if (!(np.id >= 0 and np.d2 < sense_d2)) return false;
    const ct = &w.class_id[s];
    const min2 = ct.ranged_min_dist * ct.ranged_min_dist;
    const max2 = ct.ranged_max_dist * ct.ranged_max_dist;
    return np.d2 >= min2 and np.d2 <= max2;
}

/// EAIRangedAttackTarget::Continue (IL=205): a living target (stock keeps its
/// cached entityTarget without re-checking the range, so a target that steps
/// out of the window mid-aim is still shot at; zdtd requires it to stay
/// sensed, a recorded conservative difference), elapsed < attackDuration, no
/// stun/electrocute (n/a), limbs (n/a) and no pain spike (no pain accumulator
/// in zdtd - recorded). Update sets elapsed to +inf once the vomit action
/// goes idle (IL=012F), i.e. right after the single shot: `ranged_fired` is
/// that condition.
fn rangedContinue(w: *const World, s: Slot, ai: *const c.ZombieAi, np: TargetSnap, sense_d2: f32) bool {
    if (ai.ranged_fired) return false;
    const elapsed = @as(f32, @floatFromInt(w.sim_tick -% ai.ranged_start_tick)) / 20.0;
    if (elapsed >= w.class_id[s].ranged_duration_s) return false;
    if (!((np.id >= 0 and np.d2 < sense_d2) or (ai.alert and ai.target_id >= 0 and targetLive(w, ai.target_id)))) return false;
    return true;
}

/// Spawn the vomit projectile (ItemActionVomit.ItemActionEffects ->
/// instantiateProjectile + ProjectileMoveScript.Fire, entity-ai.md delivery
/// contract step 2: mouth origin, aimed at the target chest by
/// GetActionEffectsValues when it is in front, IL=99). Stock's shot is a
/// client GameObject, never a replicated entity, so this is server-only sim
/// state; every client spawns its own visual from the replicated anim action.
fn fireVomit(w: *World, s: Slot, ai: *c.ZombieAi, np: TargetSnap, ct: *const c.ClassId) void {
    const t = &w.transform[s];
    const tgt = w.transform[np.slot];
    const ox = t.x;
    const oy = t.y + 1.5;
    const oz = t.z;
    const dx = tgt.x - ox;
    const dy = (tgt.y + 1.0) - oy;
    const dz = tgt.z - oz;
    const dist = @sqrt(dx * dx + dy * dy + dz * dz);
    if (dist < 0.001) return;
    ai.spit = .{
        .active = true,
        .t = 0,
        .age = 0,
        .straight_s = ct.projectile_fly_time,
        .ox = ox,
        .oy = oy,
        .oz = oz,
        .dx = dx / dist,
        .dy = dy / dist,
        .dz = dz / dist,
        .target_net = w.network_id[np.slot].id,
    };
}

/// One frame of the vomit projectile (stock ProjectileMoveScript.FixedUpdate,
/// RE items.md section 4): straight at ammo speed for FlyTime seconds, gravity
/// after (stock vomit FlyTime is positive, so the ballistic Fire branch is
/// unused), retiring on the target body, a solid cell, or the ground. A hit
/// feeds the same deferred accumulator the melee choke uses, so the victim
/// folds (armor/GDR) and the attacker's held-item rows (infection counter,
/// abrasion) run through applyDeferredDamage exactly like a landed punch.
/// A solid cell retires the shot and pushes a block impact; the Game drain
/// applies the ammo's DamageBlock (stock vomit 120). Not modelled: the 4 s
/// LifeTime, the lingering acid pool, and the ammo's tagged DamageModifier
/// rows (earth 0, stone 0.5). Gravity terminates a miss.
fn advanceSpit(w: *World, s: Slot, dt: f32, dmg_fp: []u32, dmg_attacker: []u16, hits: *std.atomic.Value(u32)) void {
    if (!w.mask[s].zombie_ai) return;
    const ai = &w.zombie_ai[s];
    if (!ai.spit.active) return;
    const sp = &ai.spit;
    sp.t += dt;
    sp.age += dt;
    const ct = &w.class_id[s];
    const speed = ct.projectile_speed;
    const straight = @min(sp.t, sp.straight_s);
    const px = sp.ox + sp.dx * speed * straight;
    const pz = sp.oz + sp.dz * speed * straight;
    var py = sp.oy + sp.dy * speed * straight;
    if (sp.t > sp.straight_s) {
        const g = sp.t - sp.straight_s;
        py += (sp.dy * speed) * g + 0.5 * w.rules.ai.gravity * g * g;
    }
    // Target-body hit: the shot was aimed at the chest, so entering the
    // cylinder around the (live) target lands it; a strafed target misses and
    // the shot keeps flying until gravity grounds it. Approximates stock's
    // capsule ray with radius + 0.4 horizontal and feet..head vertically.
    if (w.slotOfNetId(sp.target_net)) |ts| {
        if (w.alive[ts] and w.mask[ts].transform and w.mask[ts].health) {
            const tg = &w.transform[ts];
            const hx = px - tg.x;
            const hz = pz - tg.z;
            const rad = ct.projectile_radius + 0.4;
            if (hx * hx + hz * hz <= rad * rad and py >= tg.y and py <= tg.y + 1.9) {
                const add: u32 = @trunc(ct.projectile_damage * @as(f32, @floatFromInt(dmg_scale)));
                _ = @atomicRmw(u32, &dmg_fp[ts], .Add, add, .monotonic);
                @atomicStore(u16, &dmg_attacker[ts], s, .monotonic);
                _ = hits.fetchAdd(1, .monotonic);
                sp.active = false;
                return;
            }
        }
    }
    if (w.solid_fn) |solid| {
        const bx: i32 = @floor(px);
        const by: i32 = @floor(py);
        const bz: i32 = @floor(pz);
        if (solid(w.solid_ctx, bx, by, bz)) {
            // Stock ItemActionProjectile applies DamageBlock to the hit cell
            // (vomit 120). The Game drains the request; the shot still retires.
            if (ct.projectile_block_damage > 0) w.pushSpitHit(s, bx, by, bz);
            sp.active = false;
        }
    }
}

/// Dispatch to a task's CanExecute gate (selection pass, step 2).
fn canExecute(w: *const World, s: Slot, id: c.TaskId, ai: *const c.ZombieAi, np: TargetSnap) bool {
    if (!c.aiTaskAllowed(w.class_id[s].ai_tasks, id)) return false;
    const sense_d2 = senseDistSq(w, s);
    return switch (id) {
        .break_block => breakBlockCanExecute(w, s, ai, np.id, np.d2, sense_d2),
        .destroy_area => destroyAreaCanExecute(w, s, ai, np.id, np.d2, sense_d2),
        .runaway => runawayCanExecute(w, s, ai),
        .approach_attack => w.class_id[s].ai_attack and approachCanExecute(w, ai, np.id, np.d2, sense_d2),
        .territorial => territorialCanExecute(w, s, ai, np.id, np.d2, sense_d2),
        .approach_distraction => approachDistractionCanExecute(w, ai, np.id, np.d2, sense_d2),
        .leap => leapCanExecute(w, s, ai, np, sense_d2),
        .ranged_attack_target => rangedAttackCanExecute(w, s, ai, np, sense_d2),
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
fn canContinue(w: *const World, s: Slot, id: c.TaskId, ai: *const c.ZombieAi, np: TargetSnap) bool {
    return switch (id) {
        .wander => wanderContinue(w, s, ai, np.id, np.d2, senseDistSq(w, s)),
        .look => lookContinue(ai),
        .leap => leapContinue(ai),
        .ranged_attack_target => rangedContinue(w, s, ai, np, senseDistSq(w, s)),
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
fn resetTask(w: *const World, s: Slot, id: c.TaskId, ai: *c.ZombieAi, rng_seed: i32) void {
    const ai_rules = w.rules.ai;
    switch (id) {
        .wander => {
            // EAIWander::Reset (asm.il:438383): lookTime = RandomRange(0.5, 5).
            ai.look_time = ai_rules.wander_look_min_s + rngFrac(ai, rng_seed) * (ai_rules.wander_look_max_s - ai_rules.wander_look_min_s);
            ai.wander_time = 0;
        },
        // EAILeap::Reset: drop the aim budget and any arc state. A task cut
        // short mid-flight lands via the normal gravity path next tick.
        .leap => {
            ai.leaping = false;
            ai.leap_time = 0;
            ai.leap_t = 0;
        },
        // EAIRangedAttackTarget::Reset (IL=41): stock re-arms
        // cooldown = base + 0..0.5 x base jitter on every stop (shot done or
        // aborted); zdtd stores the absolute ready tick so the CanExecute
        // gate stays read-only, and clears the sequence milestones.
        .ranged_attack_target => {
            const cd = w.class_id[s].ranged_cooldown_s;
            ai.ranged_ready_tick = w.sim_tick + @as(u64, @intFromFloat(cd * 20.0 * (1.0 + 0.5 * rngFrac(ai, rng_seed))));
            ai.ranged_running = false;
            ai.ranged_released = false;
            ai.ranged_fired = false;
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
fn breakBlockUpdate(w: *World, s: Slot, ai: *c.ZombieAi, np: TargetSnap, dt: f32) void {
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
fn destroyAreaUpdate(w: *World, s: Slot, ai: *c.ZombieAi, np: TargetSnap, dt: f32) void {
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

/// Combined gate: RunawayWhenHurt (fresh revenge target) or RunawayFromEntity
/// (fresh fear source). Timid templates carry both; wolves also list
/// RunawayWhenHurt, but is_enemy keeps predators hunting instead of fleeing
/// unprovoked. Kind still gates: zombies never pick this even when the mask
/// would allow it (no stock zombie list includes it).
fn runawayCanExecute(w: *const World, s: Slot, ai: *const c.ZombieAi) bool {
    if (!w.mask[s].kind or w.kind[s] != .animal) return false;
    // Predators (wolf, bear, coyote, snake, boar) hunt; only passive wildlife
    // flees. The XML mask may still list RunawayWhenHurt on a predator.
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
    // rather than dividing by zero. How far to run is its own knob: the
    // give-up radius above answers "is the fright over", `flee_distance`
    // answers "how far away is the goal" (equal at the stock defaults).
    const run_to = w.rules.ai.flee_distance;
    const inv: f32 = if (d2 > 0.0001) 1.0 / @sqrt(d2) else 0;
    const fx = w.transform[s].x + (if (inv > 0) dx * inv else 1) * run_to;
    const fz = w.transform[s].z + (if (inv > 0) dz * inv else 0) * run_to;
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
        // EAILeap::Start: latch the abortTime aim budget. Start re-runs on every
        // re-eval that keeps the task, so neither the budget nor an in-flight
        // arc may be restarted here.
        .leap => {
            if (!ai.leaping and ai.leap_time <= 0) ai.leap_time = w.rules.ai.leap_abort_s;
        },
        // EAIRangedAttackTarget::Start (IL=46): elapsed resets and, when the
        // class carries a task-level telegraph (startAnimType >= 0, chuck),
        // the first anim action goes out immediately (3000 + startAnimType).
        // The shot leaves at aim-half + releaseDelay + the vomit warning
        // window for those classes; a class without the task anim (cop,
        // rancher, mutated: startAnimType -1) runs the vomit's own warning
        // window from tick 0, because Update calls UseHoldingItem
        // unconditionally (IL=0109).
        //
        // The selection pass re-runs Start on every re-eval (startTask's
        // contract, how wander keeps drifting), so the sequence latches:
        // re-Start on a live sequence would reset elapsed forever and the
        // shot could never leave (leap's accumulator condition gives it the
        // same idempotence).
        .ranged_attack_target => {
            if (ai.ranged_running) return;
            ai.ranged_running = true;
            ai.ranged_start_tick = w.sim_tick;
            ai.ranged_released = false;
            ai.ranged_fired = false;
            const rct = &w.class_id[s];
            const delay_s: f32 = if (rct.ranged_start_anim >= 0)
                0.5 * rct.ranged_duration_s + rct.ranged_release_delay_s + vomit_warning_s
            else
                vomit_warning_s;
            ai.ranged_fire_tick = w.sim_tick + @as(u64, @intFromFloat(delay_s * 20.0));
            if (rct.ranged_start_anim >= 0) ai.pending_anim_action = 3000 + rct.ranged_start_anim;
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
fn approachUpdate(ctx: AiCtx, s: Slot, ai: *c.ZombieAi, np: TargetSnap, cspd: f32, ct: *const EntityClass) void {
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
                // Attacker slot for the foreign-gated victim rows. Parallel
                // workers may share a victim: atomic publish so the apply
                // pass never reads a torn slot (same-tick last store wins).
                @atomicStore(u16, &ctx.dmg_attacker[np.slot], s, .monotonic);
            }
            _ = ctx.hits.fetchAdd(1, .monotonic);
            ai.attack_cd = ctx.w.rules.combat.attack_cooldown_s;
            // Stock AvatarZombieController::StartAnimationAttack fires on the
            // landed strike; replicate flushes it as NetPackageEntityAnimationData
            // (entity-ai.md 2026-09-22). Zombie avatars only: the animal
            // controller's attack params are not RE'd, so a biting wolf keeps
            // its current client-local animation. 0 = the melee variant
            // (StartAnimationAttack writes Attack int + blend + trigger).
            if (ctx.w.kind[s] == .zombie) ai.pending_anim_action = 0;
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

/// Shortest signed difference between two yaws, degrees, in (-180, 180].
fn yawDelta(from: f32, to: f32) f32 {
    var d = @mod(to - from + 180.0, 360.0) - 180.0;
    if (d <= -180.0) d += 360.0;
    return d;
}

/// Advance one frame of the launched arc. Closed form on (leap_ox, leap_oy,
/// leap_oz): horizontal is linear along `leap_yaw` over `leap_dist`, vertical
/// is the straight launch-to-landing line plus a `leap_arc_height` parabola, so
/// the body lands exactly on the aimed cell. Clears `leaping` at t == dur and
/// hands the entity back to the normal ground snap.
fn advanceLeap(w: *World, s: Slot, ai: *c.ZombieAi, dt: f32) void {
    ai.leap_t += dt;
    const u = @min(ai.leap_t / ai.leap_dur, 1.0);
    const rad = ai.leap_yaw * (std.math.pi / 180.0);
    const t = &w.transform[s];
    t.x = ai.leap_ox + @sin(rad) * ai.leap_dist * u;
    t.z = ai.leap_oz + @cos(rad) * ai.leap_dist * u;
    const arc = w.rules.ai.leap_arc_height * 4.0 * u * (1.0 - u);
    const prev_y = t.y;
    t.y = ai.leap_oy + ai.leap_dy * u + arc;
    ai.vy = (t.y - prev_y) / dt;
    if (u >= 1.0) {
        ai.leaping = false;
        ai.leap_t = 0;
        ai.vy = 0;
        ai.jump_cd = w.rules.ai.jump_delay_s;
    }
}

/// EAILeap::Update: turn toward the target within the abort budget, then launch
/// the arc; once airborne, fly it. Aborting (budget spent, target lost) leaves
/// the entity grounded and idle so the next re-eval picks another task.
fn leapUpdate(w: *World, s: Slot, ai: *c.ZombieAi, np: TargetSnap, dt: f32) void {
    if (ai.leaping) {
        ai.state = .chase;
        ai.alert = true;
        advanceLeap(w, s, ai, dt);
        return;
    }
    if (np.id < 0) {
        ai.leap_time = 0;
        ai.state = .idle;
        return;
    }
    ai.state = .chase;
    ai.alert = true;
    ai.target_id = np.id;
    // moveHelper is stopped for the whole aim phase: stock turns in place.
    ai.has_path = false;
    ai.clearPath();
    ai.path_blocked = false;

    const t = &w.transform[s];
    const dx = np.px - t.x;
    const dz = np.pz - t.z;
    const want_yaw = std.math.atan2(dx, dz) * (180.0 / std.math.pi);
    const delta = yawDelta(t.yaw, want_yaw);
    const step = w.rules.ai.leap_turn_deg_s * dt;
    t.yaw += std.math.clamp(delta, -step, step);

    ai.leap_time -= dt;
    if (@abs(delta) > w.rules.ai.leap_aim_tol_deg) {
        if (ai.leap_time <= 0) ai.state = .idle; // abortTime spent; give up
        return;
    }

    const dist = @sqrt(dx * dx + dz * dz);
    const max_d = w.class_id[s].jump_max;
    ai.leap_yaw = want_yaw;
    ai.leap_ox = t.x;
    ai.leap_oy = t.y;
    ai.leap_oz = t.z;
    ai.leap_dist = @min(dist, max_d);
    ai.leap_dy = w.transform[np.slot].y - t.y;
    ai.leap_dur = @max(ai.leap_dist / w.rules.ai.leap_speed, dt);
    ai.leap_t = 0;
    // Zeroed at launch so Continue fails once the arc ends and the task is not
    // re-elected straight into a second pounce.
    ai.leap_time = 0;
    ai.leaping = true;
}

/// EAIRangedAttackTarget::Update (IL=107-013A) as a task-local sequence:
/// chase-stance + SeekYawToPos(target, 30) through the first half of
/// attackDuration, the release anim once past it (state 0/1 wait on the
/// server avatar's action phase, which zdtd does not run - approximated by
/// the aim half), then the shot at the computed fire tick (releaseDelay +
/// ItemActionVomit's 1.2 s warning window on top, or just the warning for a
/// class without a task anim). Firing emits the burst anim action and spawns
/// the projectile; `ranged_fired` ends the sequence the way stock's
/// `elapsedTime = +inf` does when the vomit action goes idle (IL=012F).
fn rangedUpdate(w: *World, s: Slot, ai: *c.ZombieAi, np: TargetSnap, dt: f32) void {
    if (np.id < 0) return; // Continue fails next pass and the task stops
    const ct = &w.class_id[s];
    const t = &w.transform[s];
    ai.state = .chase;
    ai.alert = true;
    ai.target_id = np.id;
    const elapsed = @as(f32, @floatFromInt(w.sim_tick -% ai.ranged_start_tick)) / 20.0;
    if (elapsed < 0.5 * ct.ranged_duration_s) {
        const want_yaw = std.math.atan2(np.px - t.x, np.pz - t.z) * (180.0 / std.math.pi);
        // SeekYawToPos(..., 30): 30 degrees per AI tick = 600/s.
        t.yaw = seekYawStep(t.yaw, want_yaw, 600, 60, 60, dt);
    }
    if (ct.ranged_start_anim >= 0 and !ai.ranged_released and elapsed >= 0.5 * ct.ranged_duration_s) {
        ai.ranged_released = true;
        // ContinueAnimAction(startAnimType + 1 + 3000), Update IL=00A4.
        ai.pending_anim_action = 3000 + ct.ranged_start_anim + 1;
    }
    if (ai.ranged_fired or w.sim_tick < ai.ranged_fire_tick) return;
    // The burst anim (StartAnimAction(3000 + X), ItemActionVomit IL=00D6)
    // then the shot; replicate drains the edge on this or the next tick.
    ai.pending_anim_action = 3000 + ct.vomit_anim_type;
    fireVomit(w, s, ai, np, ct);
    ai.ranged_fired = true;
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
    // EAIApproachDistraction::updatePath recalculates on its own cadence
    // (pathRecalculateTicks = 20 + rand(20), asm.il updatePath IL_0019/IL_001C),
    // not the generic chase throttle. Re-arm the cooldown after the shared
    // follow step so the next distraction solve waits the task's own interval.
    if (ai.path_replan_cd <= 0) {
        const base: f32 = @floatFromInt(@max(0, w.rules.ai.distraction_replan_min));
        const rand_span: f32 = @floatFromInt(@max(0, w.rules.ai.distraction_replan_rand));
        const ticks = base + rngFrac(ai, ai.distraction) * rand_span;
        ai.path_replan_cd = ticks / @as(f32, @floatFromInt(protocol.ticks_per_second));
    }
}

pub fn decrementIfPositive(value: *i32) void {
    var current = @atomicLoad(i32, value, .monotonic);
    while (current > 0) {
        current = @cmpxchgWeak(i32, value, current, current - 1, .monotonic, .monotonic) orelse return;
    }
}

/// EAIWander::Update: drift toward the Start-picked destination.
pub fn wanderUpdate(w: *World, s: Slot, ai: *c.ZombieAi, wspd: f32, dt: f32) void {
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
        const ai_kinds = [_]c.Kind{ .zombie, .animal };
        for (ai_kinds) |kind| {
            for (query.groupSlice(w, kind)) |j| {
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
        }
        bag.distraction_lifetime -= 1;
    }
}

pub fn systemZombieAi(w: *World, dt: f32) u32 {
    // Zombie AI also drives animal wander (kind.animal reuses zombie_ai mask).
    // mask.zombie_ai is set at spawn for both kinds and never cleared while
    // alive, so the merged kind groups are the live AI set.
    var ai_slots: [max_entities]Slot = undefined;
    const ai_n = query.copyKindsInto(w, &.{ .zombie, .animal }, &ai_slots);
    if (ai_n == 0) return 0;
    // Dropped-item distraction broadcast runs before task selection so a
    // zombie can react to a fresh decoy on the same tick it lands.
    tickItemDistractions(w);
    var scan: PlayerScan = .{};
    _ = snapshotPlayers(w, &scan, true);
    var dmg_fp: [max_entities]u32 = .{0} ** max_entities;
    var dmg_attacker: [max_entities]u16 = .{std.math.maxInt(Slot)} ** max_entities;
    var hits_a: std.atomic.Value(u32) = .init(0);
    // The vomit projectile is per-shooter sim state (stock's is a client
    // GameObject, never a replicated entity): step it serially before the
    // parallel AI phase so an impact lands in the same deferred accumulator
    // the melee choke fills and applyDeferredDamage folds both once.
    for (ai_slots[0..ai_n]) |sl| advanceSpit(w, sl, dt, dmg_fp[0..], dmg_attacker[0..], &hits_a);
    // Positions as of the phase start. Workers write only their own slots, so
    // any cross-slot position read has to come from this copy.
    const pos_snap: [max_entities]c.Transform = w.transform;
    const ctx = AiCtx{
        .w = w,
        .dt = dt,
        .scan = &scan,
        .pos = &pos_snap,
        .slots = ai_slots[0..ai_n],
        .dmg_fp = dmg_fp[0..],
        .dmg_attacker = dmg_attacker[0..],
        .hits = &hits_a,
        .zombie_speed_scale = w.zombie_speed_scale,
    };
    // Split the live AI list, not the 512-slot table: idle capacity is not
    // scanned, and the pool wakeup is skipped while the population is small.
    if (ai_n < 64) AiCtx.work(ctx, 0, ai_n) else parallel.forRanges(ai_n, ctx, AiCtx.work);
    consumeCombatNoise(w);
    _ = applyDeferredDamage(w, dmg_fp[0..], dmg_attacker[0..]);
    return hits_a.load(.monotonic);
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
test "flee_distance sets how far the runaway goal is placed" {
    // The knob is an operator rule (GAME_OPTIONS "flee_distance"): raising it
    // must push the flee goal further from the fear source, independently of
    // timid_safe_distance, which only decides when the fright ends.
    var w: World = .{};
    defer w.deinit();
    w.rules.ai.flee_distance = 60.0;
    const a = w.spawnAnimal(0, 70, 0, 100, 0, "").?;
    const as = w.slotOfNetId(a).?;
    w.class_id[as].is_enemy = false;
    _ = w.spawnZombie(10, 70, 0, 40).?;
    var t: f32 = 0;
    while (t < 1.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(c.TaskId.runaway, w.zombie_ai[as].active_task);
    // Source at +x, animal at origin: the goal is placed `flee_distance` along
    // -x, so a 60 m knob must not leave it at the 20 m default.
    try std.testing.expect(w.zombie_ai[as].path_goal_x < -50.0);
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
test "BlockIf animal does not sense while unalerted; hurt removes the block" {
    // Stock animalTemplateHostile AITarget-2 `BlockIf condition=alert e 0`:
    // while unalerted the executing BlockIf holds MutexBits=1 over
    // SetNearestEntityAsTarget, so a wolf next to a player keeps wandering.
    // Hurting it sets alert via the revenge path, which drops the gate and
    // the next sense acquires the attacker.
    var w: World = .{};
    defer w.deinit();
    const a = w.spawnAnimal(0, 70, 0, 100, 0, "").?;
    const as = w.slotOfNetId(a).?;
    w.class_id[as].is_enemy = true;
    w.class_id[as].ai_attack = true;
    w.class_id[as].block_if_alert_only = 3;
    w.class_id[as].sight_light_min = -2.0;
    w.class_id[as].sight_light_max = 150.0;
    w.ambient_light = 0.5;
    const p = w.spawnPlayer(0, 70, 8, 0).?;
    var t: f32 = 0;
    while (t < 1.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(!w.zombie_ai[as].alert);
    try std.testing.expect(w.zombie_ai[as].active_task != c.TaskId.approach_attack);
    // Hurt it: revenge sets alert, the block drops, sense acquires. The
    // wander task from the blocked phase holds a decision cooldown, so run
    // past its expiry (the stop pass drops wander to .none on the first
    // post-hurt tick, then the re-eval picks the chase).
    _ = w.damageFrom(a, 5, p);
    t = 0;
    while (t < 2.0 and w.zombie_ai[as].active_task != c.TaskId.approach_attack) : (t += 0.05) {
        _ = systemZombieAi(&w, 0.05);
    }
    try std.testing.expect(w.zombie_ai[as].alert);
    try std.testing.expectEqual(p, w.zombie_ai[as].target_id);
}
test "class without Territorial in its AITask list does not leash home" {
    // Stock zombieRancher overrides the template AITask blob and drops Territorial
    // (and DestroyArea). The shared native table used to leash every zombie.
    var w: World = .{};
    defer w.deinit();
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    w.class_id[zs].ai_tasks = c.ai_task_list_set |
        c.aiTaskBit(.break_block) |
        c.aiTaskBit(.approach_attack) |
        c.aiTaskBit(.approach_spot) |
        c.aiTaskBit(.look) |
        c.aiTaskBit(.wander);
    w.transform[zs].x = 40;
    w.transform[zs].z = 0;
    var t: f32 = 0;
    while (t < 3.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(w.zombie_ai[zs].active_task != c.TaskId.territorial);
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
    // Horde members stay however far they roam: stock pins them with
    // bIsChunkObserver and the recount/teleport pass owns their lifecycle.
    const hz = w.spawnZombie(400, 70, 4, 40).?;
    w.zombie_ai[w.slotOfNetId(hz).?].is_horde = true;
    var ids: [8]i32 = undefined;
    const n = systemDespawnFar(&w, &ids, null);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(far, ids[0]);
    try std.testing.expectEqual(@as(?u16, null), w.slotOfNetId(far));
    try std.testing.expect(w.slotOfNetId(near) != null);
    try std.testing.expect(w.slotOfNetId(alert) != null);
    try std.testing.expect(w.slotOfNetId(hz) != null);
}
test "horde kills gib 3x faster than ordinary kills" {
    // Stock SpawnZombie cuts timeStayAfterDeath /= 3 on horde spawns
    // (AIDirectorBloodMoonParty + AIWanderingHordeSpawner): the night's
    // corpses clear instead of piling up. Both kill paths (player damage in
    // world.zig, turret accumulator in systems.zig) divide the dwell.
    var w: World = .{};
    defer w.deinit();
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    w.class_id[ps].time_stay = 30;
    const hz = w.spawnZombie(10, 70, 0, 40).?;
    const hs = w.slotOfNetId(hz).?;
    w.class_id[hs].time_stay = 30;
    w.zombie_ai[hs].is_horde = true;
    const z = w.spawnZombie(20, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    w.class_id[zs].time_stay = 30;
    _ = w.damageFrom(w.network_id[hs].id, 1000, w.network_id[ps].id);
    _ = w.damageFrom(w.network_id[zs].id, 1000, w.network_id[ps].id);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), w.health[hs].corpse_seconds, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 30.0), w.health[zs].corpse_seconds, 0.001);
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
test "distraction replan cadence follows its own rule, not the chase throttle" {
    // EAIApproachDistraction::updatePath owns its recalculate interval
    // (20 + rand(20) ticks); the operator rules distraction_replan_min /
    // _rand must reach it. A large min must cut solves below what the generic
    // path_replan_interval_s throttle alone would allow.
    const cd = struct {
        /// Run one distraction approach and report the replan cooldown the task
        /// left armed, in seconds.
        fn armedFor(min_ticks: i32) !f32 {
            var w: World = .{};
            defer w.deinit();
            w.step_fn = path_mod.openStep;
            w.step_ctx = null;
            w.rules.ai.distraction_replan_min = min_ticks;
            w.rules.ai.distraction_replan_rand = 0; // pin the jitter for the compare
            const bag = seedDecoy(&w, 40, 0, 10_000);
            const z = w.spawnZombie(0, 70, 0, 40).?;
            const zs = w.slotOfNetId(z).?;
            w.zombie_ai[zs].pending_distraction = bag;
            w.zombie_ai[zs].pending_distraction_dsq = 1600;
            w.zombie_ai[zs].active_task = .none;
            w.zombie_ai[zs].decision_cd = 0;
            var t: f32 = 0;
            while (t < 1.0) : (t += 0.05) {
                w.beginTick();
                _ = systemZombieAi(&w, 0.05);
            }
            try std.testing.expectEqual(c.TaskId.approach_distraction, w.zombie_ai[zs].active_task);
            return w.zombie_ai[zs].path_replan_cd;
        }
    };
    // The knob is in ticks at 20 TPS, so 300 ticks must arm a cooldown near
    // 15 s, far past the 0.35 s generic path_replan_interval_s that the task
    // used to inherit. Anything much shorter means the rule never reached it.
    const slow = try cd.armedFor(300);
    try std.testing.expect(slow > 10.0);
    // A short cadence must stay short: the value tracks the rule, not a constant.
    const fast = try cd.armedFor(20);
    try std.testing.expect(fast < 1.5);
    try std.testing.expect(fast < slow);
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

test "system zombie leaps at a target inside its JumpMaxDistance window" {
    // EAILeap: only a class whose rolled jump_max clears the 2.8 m floor
    // pounces, and the arc lands on the aimed cell.
    var w: World = .{};
    defer w.deinit();
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    _ = w.spawnPlayer(4, 70, 0, 0);

    // Stock cctor default (1.9, 2.1) is under the floor: no leap.
    try std.testing.expect(w.class_id[zs].jump_max < w.rules.ai.leap_min_dist);
    var t: f32 = 0;
    while (t < 1.0) : (t += 0.05) {
        _ = systemZombieAi(&w, 0.05);
        try std.testing.expect(w.zombie_ai[zs].active_task != .leap);
    }

    // A zombieSpider-shaped JumpMaxDistance opens the window, and the class
    // must carry the parsed-list Leap bit (stock tasks come from XML only).
    w.transform[zs].x = 0;
    w.transform[zs].z = 0;
    w.class_id[zs].jump_max = 6.0;
    w.class_id[zs].ai_tasks = c.ai_task_list_set | c.aiTaskBit(.leap);
    var saw_flight = false;
    t = 0;
    while (t < 3.0) : (t += 0.05) {
        _ = systemZombieAi(&w, 0.05);
        if (w.zombie_ai[zs].leaping) saw_flight = true;
        if (saw_flight and !w.zombie_ai[zs].leaping) break;
    }
    try std.testing.expect(saw_flight);
    try std.testing.expect(!w.zombie_ai[zs].leaping);
    // Landed on the aimed cell, not short and not past it.
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), w.transform[zs].x, 0.35);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), w.transform[zs].z, 0.35);
    // The landing arms the jump cooldown so it cannot pounce again at once.
    try std.testing.expect(w.zombie_ai[zs].jump_cd > 0);
}

/// Sight predicate that never blocks: the leap-refusal test needs vision
/// across the wall so only the physics ray (solid_fn) can refuse, exactly
/// the stock split between CanSee and EAILeap's physics ray.
fn leapTestSightOpen(_: ?*anyopaque, _: i32, _: i32, _: i32) bool {
    return false;
}

/// One-cell-thick wall across the pounce corridor at x == 2 (y 71 band,
/// where the feet + 1.5 ray travels; z wide enough to block a detour aim).
fn leapTestWallSolid(_: ?*anyopaque, x: i32, y: i32, z: i32) bool {
    return x == 2 and y == 71 and z >= -4 and z <= 4;
}

test "leap refuses a walled corridor and an out-of-window leapV.y" {
    // Stock EAILeap.CanExecute takes two legs the distance window alone does
    // not cover: the physics ray from feet + 1.5 along the corridor (a wall
    // between zombie and player is walked around, never vaulted) and the
    // leapV.y window [-5, 0.5 + 0.5*jumpMaxDistance] (a deep fall or a high
    // climb is refused).
    var w: World = .{};
    defer w.deinit();
    // Vision crosses the wall; only solid_fn blocks, so a refusal pins the
    // leap ray itself rather than the sight gate.
    w.sight_fn = leapTestSightOpen;
    w.sight_ctx = null;
    w.solid_fn = leapTestWallSolid;
    w.solid_ctx = null;
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    _ = w.spawnPlayer(4, 70, 0, 0);
    w.class_id[zs].jump_max = 6.0;
    w.class_id[zs].ai_tasks = c.ai_task_list_set | c.aiTaskBit(.leap);
    var t: f32 = 0;
    while (t < 1.5) : (t += 0.05) {
        _ = systemZombieAi(&w, 0.05);
        try std.testing.expect(w.zombie_ai[zs].active_task != .leap);
        try std.testing.expect(!w.zombie_ai[zs].leaping);
    }

    // Same distance window, open air: only the leapV.y legs can refuse. The
    // player sits 6 m below (-6 < -5) and then 6 m above (> 0.5 + 0.5*8),
    // while jump_max 8 keeps the 3D sense distance (4^2 + 6^2 = 52) inside
    // the window, so the y bound is the deciding gate both ways.
    var w2: World = .{};
    defer w2.deinit();
    const z2 = w2.spawnZombie(0, 70, 0, 40).?;
    const s2 = w2.slotOfNetId(z2).?;
    const pid = w2.spawnPlayer(4, 64, 0, 0).?;
    const ps = w2.slotOfNetId(pid).?;
    w2.class_id[s2].jump_max = 8.0;
    w2.class_id[s2].ai_tasks = c.ai_task_list_set | c.aiTaskBit(.leap);
    for ([_]f32{ 64.0, 76.0 }) |py| {
        w2.transform[ps].y = py;
        w2.transform[s2].x = 0;
        w2.transform[s2].z = 0;
        var t2: f32 = 0;
        while (t2 < 0.8) : (t2 += 0.05) {
            _ = systemZombieAi(&w2, 0.05);
            try std.testing.expect(w2.zombie_ai[s2].active_task != .leap);
            try std.testing.expect(!w2.zombie_ai[s2].leaping);
        }
    }
}

/// Fill a spawn's ClassId with the spitter list bit and a resolved vomit
/// config, the way entityClassOf + spitConfigFor do for the real classes.
fn seedSpitter(w: *World, zs: Slot) void {
    w.class_id[zs].ai_tasks = c.ai_task_list_set | c.aiTaskBit(.ranged_attack_target);
    w.class_id[zs].vomit_anim_type = 0;
    w.class_id[zs].projectile_speed = 18;
    w.class_id[zs].projectile_fly_time = 2;
    w.class_id[zs].projectile_radius = 0.24;
    w.class_id[zs].projectile_damage = 10;
    w.class_id[zs].projectile_block_damage = 120;
    w.class_id[zs].ranged_min_dist = 4;
    w.class_id[zs].ranged_max_dist = 25;
    w.class_id[zs].ranged_duration_s = 4.0; // covers half + release + warning (3.7 s)
    w.class_id[zs].ranged_start_anim = 0; // exercise the task telegraph path
}

test "system zombie spits at a target in its range window and the shot lands" {
    // EAIRangedAttackTarget sequence: aim half -> release anim (3000 + 1 for
    // startAnimType 0) -> releaseDelay + the 1.2 s vomit warning -> burst anim
    // (3000 + item AnimType 0) + the projectile, which flies 18 m/s to the
    // chest and lands its damage through the same deferred accumulator the
    // melee choke uses.
    var w: World = .{};
    defer w.deinit();
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    const pid = w.spawnPlayer(5, 70, 0, 0).?;
    const ps = w.slotOfNetId(pid).?;
    seedSpitter(&w, zs);
    w.transform[zs].yaw = 90; // face +x: no wasted seek time

    // Phase 1: the release anim goes out past the aim half, before the shot.
    var t: f32 = 0;
    while (t < 5 and !w.zombie_ai[zs].ranged_released) : (t += 0.05) {
        w.beginTick(); // the sequence advances on sim_tick, one tick per step
        _ = systemZombieAi(&w, 0.05);
    }
    try std.testing.expect(w.zombie_ai[zs].ranged_released);
    try std.testing.expectEqual(@as(i32, 3001), w.zombie_ai[zs].pending_anim_action);

    // Phase 2: fire at aim half + releaseDelay (0.5) + vomit warning (1.2).
    while (t < 10 and !w.zombie_ai[zs].spit.active) : (t += 0.05) {
        w.beginTick();
        _ = systemZombieAi(&w, 0.05);
    }
    try std.testing.expect(w.zombie_ai[zs].spit.active);
    try std.testing.expectEqual(@as(i32, 3000), w.zombie_ai[zs].pending_anim_action);
    const hp_before = w.health[ps].hp;

    // Phase 3: the flight steps serially inside systemZombieAi; 5 m at 18 m/s
    // is under a third of a second, and the impact folds through
    // applyDeferredDamage in the same call.
    while (t < 12 and w.zombie_ai[zs].spit.active) : (t += 0.05) {
        w.beginTick();
        _ = systemZombieAi(&w, 0.05);
    }
    try std.testing.expect(!w.zombie_ai[zs].spit.active);
    try std.testing.expect(w.health[ps].hp < hp_before);

    // Phase 4: the reset re-armed stock's cooldown (base 3 s + 0..0.5 jitter),
    // so no second telegraph leaves inside that window.
    var t2: f32 = 0;
    while (t2 < 2.0) : (t2 += 0.05) {
        w.beginTick();
        _ = systemZombieAi(&w, 0.05);
        try std.testing.expect(!w.zombie_ai[zs].ranged_released);
        try std.testing.expect(!w.zombie_ai[zs].spit.active);
    }
}

test "a spit that hits a solid cell pushes a block impact" {
    // ItemActionProjectile.DamageBlock: the shot retires on the first solid
    // cell and the Game drain applies the ammo's DamageBlock (stock vomit
    // 120). The push is the sim's half; the drain lives on the Game.
    var w: World = .{};
    defer w.deinit();
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    const pid = w.spawnPlayer(5, 70, 0, 0).?;
    const ps = w.slotOfNetId(pid).?;
    seedSpitter(&w, zs);
    w.transform[zs].yaw = 90;
    // The wall sits past the player, so the aim and the sight ray stay clear.
    // Once the shot is in the air the player steps aside and the wall catches
    // it. The mouth is at y+1.5, so the cell the wall occupies is y 71.
    const Wall = struct {
        fn solid(_: ?*anyopaque, x: i32, y: i32, _: i32) bool {
            // Floor under the fight, plus a wall past the player. The shot
            // flies above the floor and meets the wall.
            return y <= 69 or x == 12;
        }
    };
    w.solid_fn = &Wall.solid;
    var t: f32 = 0;
    while (t < 10 and !w.zombie_ai[zs].spit.active) : (t += 0.05) {
        w.beginTick();
        _ = systemZombieAi(&w, 0.05);
    }
    try std.testing.expect(w.zombie_ai[zs].spit.active);
    w.transform[ps].z = 40;
    while (t < 12 and w.zombie_ai[zs].spit.active) : (t += 0.05) {
        w.beginTick();
        _ = systemZombieAi(&w, 0.05);
    }
    try std.testing.expect(!w.zombie_ai[zs].spit.active);
    try std.testing.expectEqual(@as(usize, 1), w.spit_hit_n);
    try std.testing.expectEqual(@as(i32, 12), w.spit_hit_reqs[0].x);
}

test "ranged attack refuses without a vomit config and outside the range window" {
    var w: World = .{};
    defer w.deinit();
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    const pid = w.spawnPlayer(2, 70, 0, 0).?; // sensed, but under minRange 4
    const ps = w.slotOfNetId(pid).?;
    seedSpitter(&w, zs);
    var t: f32 = 0;
    while (t < 2.0) : (t += 0.05) {
        w.beginTick();
        _ = systemZombieAi(&w, 0.05);
        try std.testing.expect(!w.zombie_ai[zs].ranged_released);
        try std.testing.expect(!w.zombie_ai[zs].spit.active);
    }
    // In the window now (the melee-stopped zombie sits ~1.6 m out, so 8 m is
    // comfortably inside [4, 25] at t0), but the class resolves no vomit
    // action: fail closed instead of aiming at a shot it cannot fire.
    w.class_id[zs].vomit_anim_type = -1;
    w.transform[ps].x = 8;
    t = 0;
    while (t < 2.0) : (t += 0.05) {
        w.beginTick();
        _ = systemZombieAi(&w, 0.05);
        try std.testing.expect(!w.zombie_ai[zs].ranged_released);
        try std.testing.expect(!w.zombie_ai[zs].spit.active);
    }
}
