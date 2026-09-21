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
const PlayerSnap = systems.PlayerSnap;
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
const dmg_scale: u32 = 100;
const protocol = @import("../protocol.zig");
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
pub fn seekYawStep(cur_deg: f32, target_deg: f32, max_turn_deg: f32, slow_at_deg: f32, min_speed_deg: f32, dt: f32) f32 {
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
                for (ctx.players) |pl| {
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
    var snaps: [64]PlayerSnap = undefined;
    const pn = snapshotPlayers(w, &snaps, true);
    var dmg_fp: [max_entities]u32 = .{0} ** max_entities;
    var dmg_attacker: [max_entities]u16 = .{std.math.maxInt(Slot)} ** max_entities;
    var hits_a: std.atomic.Value(u32) = .init(0);
    // Positions as of the phase start. Workers write only their own slots, so
    // any cross-slot position read has to come from this copy.
    const pos_snap: [max_entities]c.Transform = w.transform;
    const ctx = AiCtx{
        .w = w,
        .dt = dt,
        .players = snaps[0..pn],
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
