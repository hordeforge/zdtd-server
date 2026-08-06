//! ECS systems: pure functions over World SoA columns + resources.
//! Hot loops (zombie AI, turrets) run multi-threaded over disjoint slots.

const std = @import("std");
const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const max_entities = @import("world.zig").max_entities;
const c = @import("components.zig");
const quest = @import("quest.zig");
const poi_lock = @import("poi_lock.zig");
const buff = @import("buff.zig");
const path_mod = @import("path.zig");
const query = @import("query.zig");
const parallel = @import("../util/parallel.zig");
const rng_util = @import("../util/rng.zig");

pub const full_ai_dist_sq: f32 = 64.0 * 64.0;
pub const mid_ai_dist_sq: f32 = 225.0;
pub const sense_dist_sq: f32 = 48.0 * 48.0;
pub const attack_range_sq: f32 = 2.0 * 2.0;
/// Offline / class_table field==0 floors only. Prefer EntityClass from entityclasses
/// (MoveSpeedAggro, MoveSpeed, HandItem→items DamageEntity) when non-zero.
pub const attack_damage: f32 = 8.0;
pub const chase_speed: f32 = 2.2;
pub const wander_speed: f32 = 0.8;
/// No entityclasses field; always this cadence (stock melee interval approx).
pub const attack_cooldown_s: f32 = 1.2;
/// Replan grid A* at most this often while chasing (keeps 20 TPS budget).
const path_replan_interval_s: f32 = 0.35;
/// Max A* node expansions per replan (coarse local grid).
const path_max_expand: usize = 96;
/// Snap to next waypoint within this distance (blocks).
const path_wp_arrive: f32 = 0.55;
/// Manhattan cells the goal may drift from the one the buffer was planned for
/// before the path is re-solved. One cell of drift leaves the buffered route
/// pointing the same way, so chasing a walking player does not re-solve on
/// every block boundary it crosses.
const path_goal_slack: u32 = 2;

/// Fixed-point damage unit (1.0 hp = 100).
const dmg_scale: u32 = 100;

fn lodScale(d2: f32) f32 {
    if (d2 < mid_ai_dist_sq) return 1.0;
    if (d2 < full_ai_dist_sq) return 0.3;
    return 0.1;
}

const PlayerSnap = struct {
    id: i32,
    slot: Slot,
    x: f32,
    z: f32,
};

fn snapshotPlayers(w: *const World, out: *[64]PlayerSnap) usize {
    var n: usize = 0;
    // Cached player group instead of a 512-slot scan; it is slot-ascending, so
    // the first 64 entries are the same 64 in the same order (nearest-player
    // tie-breaks depend on it). Nothing here spawns or destroys.
    for (query.groupSlice(w, .player)) |j| {
        if (n >= out.len) break;
        if (!w.mask[j].player or !w.mask[j].transform) continue;
        out[n] = .{
            .id = w.network_id[j].id,
            .slot = j,
            .x = w.transform[j].x,
            .z = w.transform[j].z,
        };
        n += 1;
    }
    return n;
}

/// Winner of the AITarget pass: the entity the AITask list treats as "the
/// player" for this tick (nearest sensed, or the attacker via revenge).
const TargetSnap = struct { id: i32, slot: Slot, d2: f32, px: f32, pz: f32 };

fn nearestPlayerSnap(snaps: []const PlayerSnap, zx: f32, zz: f32) TargetSnap {
    var best_id: i32 = -1;
    var best_slot: Slot = 0;
    var best_d: f32 = sense_dist_sq;
    var px: f32 = zx;
    var pz: f32 = zz;
    for (snaps) |p| {
        const dx = p.x - zx;
        const dz = p.z - zz;
        const d = dx * dx + dz * dz;
        if (d < best_d and d > 0.0001) {
            best_d = d;
            best_id = p.id;
            best_slot = p.slot;
            px = p.x;
            pz = p.z;
        }
    }
    return .{ .id = best_id, .slot = best_slot, .d2 = best_d, .px = px, .pz = pz };
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
fn applyRevengeTarget(w: *const World, s: Slot, ai: *c.ZombieAi, np: TargetSnap, dt: f32) TargetSnap {
    if (ai.revenge_time > 0) ai.revenge_time -= dt;
    if (ai.revenge_time <= 0 or ai.revenge_target < 0) {
        ai.revenge_target = -1;
        ai.revenge_time = 0;
        return np;
    }
    const ts = w.slotOfNetId(ai.revenge_target) orelse {
        ai.revenge_target = -1;
        ai.revenge_time = 0;
        return np;
    };
    if (!w.alive[ts] or !w.mask[ts].transform) {
        ai.revenge_target = -1;
        ai.revenge_time = 0;
        return np;
    }
    if (w.mask[ts].kind and w.mask[s].kind and w.kind[ts] == w.kind[s]) return np;
    if (ai.revenge_target == np.id) return np;
    const dx = w.transform[ts].x - w.transform[s].x;
    const dz = w.transform[ts].z - w.transform[s].z;
    // Stock's SetAttackTarget bypasses the sense check for the whole window, so
    // aggro must latch here too or the far-attacker case falls back to wander.
    ai.alert = true;
    ai.target_id = ai.revenge_target;
    return .{
        .id = ai.revenge_target,
        .slot = ts,
        .d2 = dx * dx + dz * dz,
        .px = w.transform[ts].x,
        .pz = w.transform[ts].z,
    };
}

fn stepToward(w: *World, s: Slot, tx: f32, tz: f32, speed: f32, dt: f32) void {
    const dx = tx - w.transform[s].x;
    const dz = tz - w.transform[s].z;
    const d2 = dx * dx + dz * dz;
    if (d2 < 0.04) return;
    const inv = 1.0 / @sqrt(d2);
    w.transform[s].x += dx * inv * speed * dt;
    w.transform[s].z += dz * inv * speed * dt;
    w.transform[s].yaw = std.math.atan2(dx, dz) * (180.0 / std.math.pi);
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
        w.health[i].hp -= amount;
        applied += 1;
        // Stock's Stat setter raises Stat.Changed and EntityStats::TickWait
        // turns that into a stat-change package (asm.il:199393). dirty.hp is
        // that flag here: without it the victim's client never sees the hit.
        if (w.mask[i].dirty) w.dirty[i].hp = true;
        if (w.health[i].hp <= 0) {
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
    if (w.catalog.byId(s.def_id)) |d| {
        if (w.mask[ps].wallet) {
            w.wallet[ps].coins +|= d.reward_coin;
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
    }
}

/// Current phase objective satisfied: advance to the next actionable phase, or
/// finish at the highest phase. Mirrors Quest.AdvancePhase (asm.il 982816).
fn advancePhaseGraph(w: *World, ps: Slot, s: *c.QuestProgress, d: quest.QuestDef) void {
    if (s.phase >= d.highest_phase) {
        finishPhaseGraph(w, ps, s, d);
        return;
    }
    s.phase += 1;
    s.progress = 0;
    skipAutoPhases(w, ps, s, d);
}

/// Advance the current phase iff its objective kind matches `kind`; add `n`
/// toward the phase's required count and advance when it is reached.
fn bumpPhase(w: *World, ps: Slot, s: *c.QuestProgress, d: quest.QuestDef, kind: quest.PhaseKind, n: u16) void {
    const spec = currentPhaseSpec(d, s) orelse return;
    if (spec.kind != kind) return;
    s.progress +|= n;
    if (s.progress >= spec.required) advancePhaseGraph(w, ps, s, d);
}

pub fn questAccept(w: *World, peer_slot: usize, def_id: u16) bool {
    const ps = w.playerByPeer(peer_slot) orelse return false;
    if (!w.mask[ps].journal) return false;
    if (w.catalog.byId(def_id) == null) return false;
    var j = &w.journal[ps];
    if (j.hasActive(def_id)) return false;
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
    // have a real rect (stock picks the POI when the quest is handed out).
    if (w.poiAt(d.tx, d.tz)) |rect| s.poi = rect;
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
    return questAccept(w, peer_slot, w.catalog.starter_id);
}

pub fn questOnZombieKilled(w: *World, peer_slot: usize) void {
    const ps = w.playerByPeer(peer_slot) orelse return;
    if (!w.mask[ps].journal) return;
    var j = &w.journal[ps];
    for (&j.slots) |*s| {
        if (!s.active or s.completed or s.ready_turn_in) continue;
        const d = w.catalog.byId(s.def_id) orelse continue;
        if (d.phases.len > 0) {
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
                if (spec.kind == .trader_interact and !s.ready_turn_in) {
                    bumpPhase(w, ps, s, d, .trader_interact, spec.required);
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
                if (spec.kind == .craft) bumpPhase(w, ps, s, d, .craft, 1);
            }
            continue;
        }
        if (d.kind != .craft) continue;
        // Optional: def.name is recipe id or contains it.
        if (d.name.len > 0 and recipe_name.len > 0) {
            if (std.mem.indexOf(u8, recipe_name, d.name) == null and std.mem.indexOf(u8, d.name, recipe_name) == null)
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
    // Stock exempts party members; zdtd tracks no parties, so every other
    // player inside the POI blocks the reset.
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        if (!w.alive[i] or !w.mask[i].player or !w.mask[i].transform) continue;
        if (w.mask[i].network_id and w.network_id[i].id == entity_id) continue;
        if (rect.containsXZ(w.transform[i].x, w.transform[i].z)) {
            return .{ .reason = .player_inside };
        }
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
            if (spec.kind == .rally) bumpPhase(w, ps, s, d, .rally, spec.required);
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
                if (spec.kind != .stay_within) continue;
                break :blk @max(8, @as(f32, @floatFromInt(spec.required)));
            }
            if (d.kind != .stay_within) continue;
            break :blk @max(8, @as(f32, @floatFromInt(d.target_count)));
        };
        const dx = px - d.tx;
        const dz = pz - d.tz;
        const r2 = radius * radius;
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
        if (d.phases.len > 0) {
            const spec = currentPhaseSpec(d, s) orelse continue;
            if (spec.kind != .goto_point) continue;
            const dx = px - d.tx;
            const dz = pz - d.tz;
            if (dx * dx + dz * dz < 16.0) bumpPhase(w, ps, s, d, .goto_point, spec.required);
            continue;
        }
        // fetch_trader starter uses Goto trader as phase 1.
        if (d.kind != .goto_point and !(d.kind == .fetch_trader and s.phase == 1)) continue;
        const dx = px - d.tx;
        const dz = pz - d.tz;
        if (dx * dx + dz * dz < 16.0) {
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

pub fn questWriteJournalBody(w: *const World, peer_slot: usize, buf: []u8) ![]u8 {
    const ps = w.playerByPeer(peer_slot) orelse return error.BadSlot;
    if (!w.mask[ps].journal) return error.BadSlot;
    var pos: usize = 2;
    var count: u16 = 0;
    for (w.journal[ps].slots) |s| {
        if (!s.active and !s.completed) continue;
        if (pos + 6 > buf.len) break;
        const d = w.catalog.byId(s.def_id) orelse continue;
        std.mem.writeInt(u16, buf[pos..][0..2], s.def_id, .little);
        std.mem.writeInt(u16, buf[pos + 2 ..][0..2], s.progress, .little);
        std.mem.writeInt(u16, buf[pos + 4 ..][0..2], d.target_count, .little);
        pos += 6;
        count += 1;
    }
    std.mem.writeInt(u16, buf[0..2], count, .little);
    const coins: u32 = if (w.mask[ps].wallet) w.wallet[ps].coins else 0;
    if (pos + 4 <= buf.len) {
        std.mem.writeInt(u32, buf[pos..][0..4], coins, .little);
        pos += 4;
    }
    return buf[0..pos];
}

pub fn questCoins(w: *const World, peer_slot: usize) u32 {
    const ps = w.playerByPeer(peer_slot) orelse return 0;
    if (!w.mask[ps].wallet) return 0;
    return w.wallet[ps].coins;
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
        if (w.mask[i].inventory) {
            const inventory_before = w.inventory[ps];
            var transferred = true;
            for (w.inventory[i].slots) |slot| {
                if (slot.count == 0) continue;
                if (!w.depositItem(ps, slot.item_id, slot.count)) {
                    transferred = false;
                    break;
                }
            }
            if (!transferred) {
                w.inventory[ps] = inventory_before;
                continue;
            }
            // Ledger after full transfer succeeds (no partial loot credit).
            for (w.inventory[i].slots) |slot| {
                if (slot.count == 0) continue;
                const d: i16 = @intCast(@min(slot.count, std.math.maxInt(i16)));
                const p: u16 = if (peer_slot > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(peer_slot);
                w.inv_ledger.record(p, slot.item_id, d, .loot);
            }
        }
        w.destroy(i);
        n += 1;
    }
    if (n > 0) w.markDirty(ps, .{ .inv = true });
    return n;
}

/// Buy (side=0) or sell (side=1) against trader stock + wallet and/or casinoCoin stacks.
/// `coin_item_id` = ECS id for casinoCoin from items table (ecsIdByName). 0 = fail closed.
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
    while (e < stock.n) : (e += 1) {
        if (stock.entries[e].item != item) continue;
        if (side == 0) {
            if (stock.entries[e].count < qty) return false;
            const unit: u32 = @max(1, @as(u32, stock.entries[e].price));
            const cost: u32 = unit * qty;
            if (cost > std.math.maxInt(u16)) return false;
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
            stock.entries[e].count -= qty;
            w.wallet[ps].coins -= cost;
        } else {
            const gain: u32 = @as(u32, stock.entries[e].sell) * qty;
            if (gain > std.math.maxInt(u16)) return false;
            if (w.wallet[ps].coins > std.math.maxInt(u32) - gain) return false;
            if (stock.entries[e].count > std.math.maxInt(u16) - qty) return false;
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
            stock.entries[e].count += qty;
            w.wallet[ps].coins += gain;
        }
        return true;
    }
    return false;
}

/// Restock trader inventories toward default counts (daily).
pub fn traderRestock(w: *World) void {
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        if (!w.alive[i] or !w.mask[i].trader_stock) continue;
        var stock = &w.trader_stock[i];
        var e: usize = 0;
        while (e < stock.n) : (e += 1) {
            // Grow toward a soft cap of 50 for stackables.
            if (stock.entries[e].count < 50) {
                stock.entries[e].count +%= @min(10, 50 - stock.entries[e].count);
            }
        }
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
// Six real tasks: BreakBlock, DestroyArea, ApproachAndAttackTarget, Territorial,
// ApproachSpot, Wander. Rest of stock EAI (Look, Dodge, Leap, RangedAttack, ...)
// remains a gap (docs/MISSING_FEATURES.md). BreakBlock/DestroyArea use mutex 0
// so isBestTask allows them while Approach executes when path_blocked; movement
// tasks still share bit 0. Collapsing executingTasks to one TaskId stays exact
// for this set.
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
    // continuous so approach_attack can preempt via isBestTask continuous yield.
    .{ .id = .territorial, .priority = 2, .mutex = 0b01, .execute_delay = 0.2, .continuous = true },
    .{ .id = .approach_spot, .priority = 2, .mutex = 0b01, .execute_delay = 0.2, .continuous = true },
    // EAILook: MutexBits=1 (.ctor, asm.il:429876); no Init override so
    // executeDelay is the EAIBase::Init default 0.5 and IsContinuous the
    // EAIBase default true (asm.il:424579).
    .{ .id = .look, .priority = 2, .mutex = 0b01, .execute_delay = 0.5, .continuous = true },
    .{ .id = .wander, .priority = 2, .mutex = 0b01, .execute_delay = 0.5, .continuous = true },
};

/// Arrive radius (m) for EAIApproachSpot; clears has_spot.
const spot_arrive: f32 = 0.75;

/// EAITerritorial leash radius (m). Beyond this, walk back to home.
const territorial_radius: f32 = 32.0;
const territorial_radius_sq: f32 = territorial_radius * territorial_radius;

/// Sparse random gate for DestroyArea while chasing (wander_rng % N == 1).
const destroy_area_rng_mod: u32 = 16;

/// EAITaskList.executeDelayScale base (asm.il:437541, IL_0028 ldc.r4 0.85).
/// The stock GameRandom jitter blended on top is dropped (simplification).
const execute_delay_scale: f32 = 0.85;

/// EAILook::Continue re-picks a yaw every 14 ticks at 20 Hz (asm.il:429984).
const look_turn_interval_s: f32 = 14.0 / 20.0;
/// SeekYaw target = rotation.y + RandomFloat*120 - 60 (asm.il:429995-430000).
const look_yaw_range_deg: f32 = 120.0;
/// Entity::SeekYaw yawSlowAt argument passed by EAILook (asm.il:430000).
const look_yaw_slow_at_deg: f32 = 35.0;
/// EntityClass.MaxTurnSpeed for zombieTemplateMale (entityclasses.xml:668).
/// Pinned: World.EntityClass carries no per-class turn speed yet.
const look_turn_speed_deg: f32 = 250.0;
/// Utils::FastMax floor inside SeekYaw's slowdown branch (asm.il:399597).
const look_turn_speed_min_deg: f32 = 20.0;
/// EAIWander lookMin/lookMax defaults (asm.il:438410 / :438413).
const wander_look_min_s: f32 = 0.5;
const wander_look_max_s: f32 = 5.0;
/// EAIApproachSpot::Reset lookTime = 5 + RandomFloat*3 (asm.il:424395/424401).
const spot_look_base_s: f32 = 5.0;
const spot_look_rand_s: f32 = 3.0;
/// EAIWander::Continue bails once time > 30 s (asm.il:438343).
const wander_time_max_s: f32 = 30.0;
/// Stock's Continue also bails on navigator.noPathAndNotPlanningOne() (path
/// finished, asm.il:438347). zdtd has no navigator on wander, so "arrived"
/// is the stepToward no-op radius (d2 < 0.04) expressed as a distance.
const wander_arrive: f32 = 0.2;

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
fn approachCanExecute(w: *const World, ai: *const c.ZombieAi, np_id: i32, np_d2: f32) bool {
    if (np_id >= 0 and np_d2 < sense_dist_sq) return true;
    return ai.alert and ai.target_id >= 0 and w.slotOfNetId(ai.target_id) != null;
}

/// EAIApproachSpot::CanExecute (asm.il:424093): director/AI set a spot to walk to.
fn approachSpotCanExecute(ai: *const c.ZombieAi) bool {
    return ai.has_spot;
}

/// EAIWander::CanExecute (asm.il:438161) does NOT test for a target; here it is
/// the pure fallback: wander whenever no player is sensed. It yields to chase
/// only through priority + MutexBits, never through this gate. Spot also wins
/// over wander via table order when has_spot (same priority/mutex).
fn wanderCanExecute(ai: *const c.ZombieAi, np_id: i32, np_d2: f32) bool {
    // EAIWander::CanExecute returns false while lookTime > 0 (asm.il:438181):
    // Look and Wander are mutually exclusive by data, not only by MutexBits.
    if (ai.look_time > 0) return false;
    return !(np_id >= 0 and np_d2 < sense_dist_sq);
}

/// EAIWander::Continue (asm.il:438318) is a real override distinct from
/// CanExecute: stop on the 30 s cap and when the path is finished. The stun and
/// moveHelper.BlockedTime bails have no zdtd equivalent.
fn wanderContinue(w: *const World, s: Slot, ai: *const c.ZombieAi, np_id: i32, np_d2: f32) bool {
    if (!wanderCanExecute(ai, np_id, np_d2)) return false;
    if (ai.wander_time > wander_time_max_s) return false;
    const dx = ai.wander_tx - w.transform[s].x;
    const dz = ai.wander_tz - w.transform[s].z;
    return dx * dx + dz * dz > wander_arrive * wander_arrive;
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
fn seekYawStep(cur_deg: f32, target_deg: f32, max_turn_deg: f32, slow_at_deg: f32, dt: f32) f32 {
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
        speed = @max(max_turn_deg * f * f, look_turn_speed_min_deg);
    }
    const step = @min(speed * dt, mag);
    return wrap360(cur + std.math.sign(delta) * step);
}

const AiCtx = struct {
    w: *World,
    dt: f32,
    players: []const PlayerSnap,
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
            // Sleepers: stay sleep until player in volume.
            if (ctx.w.mask[s].sleeper and !ctx.w.sleeper[s].awake) {
                const sl = ctx.w.sleeper[s];
                var near = false;
                for (ctx.players) |pl| {
                    const dx = pl.x - sl.home_x;
                    const dz = pl.z - sl.home_z;
                    if (dx * dx + dz * dz <= sl.volume_r * sl.volume_r) {
                        near = true;
                        break;
                    }
                }
                if (!near) {
                    ai.state = .sleep;
                    continue;
                }
                ctx.w.sleeper[s].awake = true;
                ai.state = .chase;
            }
            if (ai.attack_cd > 0) ai.attack_cd -= ctx.dt;

            // AITarget list before AITask list: a fresh attacker outranks the
            // nearest sensed player for the revenge window.
            const np = applyRevengeTarget(ctx.w, s, ai, nearestPlayerSnap(ctx.players, ctx.w.transform[s].x, ctx.w.transform[s].z), ctx.dt);
            ai.active_scale = if (np.id >= 0) lodScale(np.d2) else 0.1;

            // Ultra-far sleep: player exists but beyond 4× full AI range → slow wander
            // only (no A*/task scan) unless chewing a blocked path. No-player still
            // runs the normal table (wander / territorial / spot).
            if (np.id >= 0 and np.d2 > full_ai_dist_sq * 4.0 and !ai.path_blocked and
                ai.active_task != .break_block and ai.active_task != .destroy_area)
            {
                if (ai.attack_cd > 0) ai.attack_cd -= ctx.dt;
                ai.decision_cd -= ctx.dt * 0.05;
                if (ai.decision_cd > 0) continue;
                const sscale = ctx.zombie_speed_scale;
                const ct = &ctx.w.class_table[ctx.w.class_id[s].id];
                const wspd: f32 = (if (ct.wander_speed > 0) ct.wander_speed * 10.0 else wander_speed) * sscale;
                ai.active_task = .wander;
                ai.decision_cd = 1.0;
                wanderUpdate(ctx.w, s, ai, wspd * 0.5, ctx.dt);
                continue;
            }

            // A11: class_table from entityclasses (0 field → module floor only).
            // MoveSpeed ~0.08 shamble → x10; MoveSpeedAggro max ~1.35 → x1.6.
            // Pointer, not copy: EntityClass is ~56 bytes and only three scalar
            // fields are read here (per alive zombie, every tick).
            const ct = &ctx.w.class_table[ctx.w.class_id[s].id];
            const sscale = ctx.zombie_speed_scale;
            const wspd: f32 = (if (ct.wander_speed > 0) ct.wander_speed * 10.0 else wander_speed) * sscale;
            const cspd: f32 = (if (ct.chase_speed > 0) ct.chase_speed * 1.6 else chase_speed) * sscale;

            // EAITaskList::OnUpdateTasks step 1 (asm.il:437713): stop the
            // executing task when it is no longer best or its Continue() fails.
            if (ai.active_task != .none) {
                const t = taskById(ai.active_task).?;
                if (!(isBestTask(t, ai.active_task) and canContinue(ctx.w, s, ai.active_task, ai, np))) {
                    ai.decision_cd = t.execute_delay * execute_delay_scale;
                    // EAIBase::Reset fires on this exact path (asm.il:437713,
                    // IL_006F): a finished Wander / ApproachSpot seeds lookTime.
                    resetTask(ai.active_task, ai, ctx.w.network_id[s].id);
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
                if (chosen != ai.active_task) resetTask(ai.active_task, ai, ctx.w.network_id[s].id);
                ai.active_task = chosen;
                ai.decision_cd = (taskById(chosen) orelse zombie_tasks[0]).execute_delay * execute_delay_scale;
                startTask(chosen, ctx.w, s, ai);
            }

            // Steps 3/4: run the winning task's Update and project it onto the
            // coarse ZombieAi.state enum for downstream replication parity.
            switch (ai.active_task) {
                .break_block => breakBlockUpdate(ctx.w, s, ai, np, ctx.dt),
                .destroy_area => destroyAreaUpdate(ctx.w, s, ai, np, ctx.dt),
                .runaway => runawayUpdate(ctx.w, s, ai, cspd, ctx.dt),
                .approach_attack => approachUpdate(ctx, s, ai, np, cspd, ct),
                .territorial => territorialUpdate(ctx.w, s, ai, cspd, ctx.dt),
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
                ctx.w.flags[s].bits |= 64;
            } else {
                ctx.w.flags[s].bits &= ~@as(u16, 64);
            }
        }
    }
};

/// Dispatch to a task's CanExecute gate (selection pass, step 2).
fn canExecute(w: *const World, s: Slot, id: c.TaskId, ai: *const c.ZombieAi, np: anytype) bool {
    return switch (id) {
        .break_block => breakBlockCanExecute(ai, np.id, np.d2),
        .destroy_area => destroyAreaCanExecute(ai, np.id, np.d2),
        .runaway => runawayCanExecute(w, s, ai),
        .approach_attack => approachCanExecute(w, ai, np.id, np.d2),
        .territorial => territorialCanExecute(w, s, ai, np.id, np.d2),
        .approach_spot => approachSpotCanExecute(ai),
        .look => lookCanExecute(ai),
        .wander => wanderCanExecute(ai, np.id, np.d2),
        .none => false,
    };
}

/// Dispatch to a task's Continue() gate (stop pass, step 1). EAIBase::Continue
/// defaults to CanExecute (asm.il:424569); Wander and Look are the two tasks
/// with real overrides, and they are exactly the two whose start state must be
/// allowed to run down instead of being re-tested against the start condition.
fn canContinue(w: *const World, s: Slot, id: c.TaskId, ai: *const c.ZombieAi, np: anytype) bool {
    return switch (id) {
        .wander => wanderContinue(w, s, ai, np.id, np.d2),
        .look => lookContinue(ai),
        else => canExecute(w, s, id, ai, np),
    };
}

/// EAIBase::Reset, invoked by EAITaskList::OnUpdateTasks on the same path that
/// clears isExecuting and reloads executeTime (asm.il:437713, IL_006F). Only
/// four sites in the whole assembly write EAIManager::lookTime; two of them are
/// the Reset hooks below, and they are what produce the wander/look-around
/// cycle. Every other task inherits the empty EAIBase::Reset.
fn resetTask(id: c.TaskId, ai: *c.ZombieAi, rng_seed: i32) void {
    switch (id) {
        .wander => {
            // EAIWander::Reset (asm.il:438383): lookTime = RandomRange(0.5, 5).
            ai.look_time = wander_look_min_s + rngFrac(ai, rng_seed) * (wander_look_max_s - wander_look_min_s);
            ai.wander_time = 0;
        },
        // EAIApproachSpot::Reset (asm.il:424395): lookTime = 5 + rand*3.
        .approach_spot => ai.look_time = spot_look_base_s + rngFrac(ai, rng_seed) * spot_look_rand_s,
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

/// EAIBreakBlock::CanExecute (asm.il:425121): alert chase with a sensed player
/// and a solid cell directly toward the goal (set by chaseAlongPath).
fn breakBlockCanExecute(ai: *const c.ZombieAi, np_id: i32, np_d2: f32) bool {
    if (!ai.path_blocked) return false;
    if (!(np_id >= 0 and np_d2 < sense_dist_sq)) return false;
    // Melee range: approach owns the bite; do not stick on break.
    if (np_d2 <= attack_range_sq) return false;
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
    replanPath(w, s, ai, @intFromFloat(@floor(ai.path_goal_x)), @intFromFloat(@floor(ai.path_goal_z)));
}

/// EAIDestroyArea::CanExecute: alert/target chase with path stuck, or sparse
/// random while chasing (same block-damage feed as BreakBlock).
fn destroyAreaCanExecute(ai: *const c.ZombieAi, np_id: i32, np_d2: f32) bool {
    const chasing = (np_id >= 0 and np_d2 < sense_dist_sq) or (ai.alert and ai.target_id >= 0);
    if (!chasing) return false;
    if (np_id >= 0 and np_d2 <= attack_range_sq) return false;
    if (ai.path_blocked) return true;
    // Random chew while chase: only when rng already seeded and hits the gate.
    if (ai.wander_rng != 0 and (ai.wander_rng % destroy_area_rng_mod) == 1) return true;
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

/// EAIRunAway::.ctor fleeDistance = 20 (asm.il:434801).
const flee_distance: f32 = 20.0;

/// EAIRunawayWhenHurt::CanExecute (asm.il:435706): a revenge target is
/// required, and with the default lowHealthPercent of 1 (.ctor, asm.il:435622)
/// the health fraction gate is skipped entirely. EAIRunAway::CanExecute then
/// asks FindFleePos to produce somewhere to run; here that is always the cell
/// fleeDistance directly away from the attacker, so the gate reduces to "was
/// hurt recently". Only passive animals carry this task in stock XML
/// (entityclasses AITask-1 on the animal templates), so kind gates it.
fn runawayCanExecute(w: *const World, s: Slot, ai: *const c.ZombieAi) bool {
    if (!w.mask[s].kind or w.kind[s] != .animal) return false;
    if (ai.revenge_target < 0 or ai.revenge_time <= 0) return false;
    return w.slotOfNetId(ai.revenge_target) != null;
}

/// EAIRunAway::Update: path to the flee position, dropping the task once the
/// attacker is further than fleeDistance. The stock stuck/retry bookkeeping
/// (pathTicks, checkedPath, FindRandomPos) has no zdtd equivalent.
fn runawayUpdate(w: *World, s: Slot, ai: *c.ZombieAi, cspd: f32, dt: f32) void {
    const ts = w.slotOfNetId(ai.revenge_target) orelse {
        ai.revenge_time = 0;
        ai.state = .idle;
        return;
    };
    ai.state = .wander;
    ai.alert = false;
    ai.target_id = -1;
    const dx = w.transform[s].x - w.transform[ts].x;
    const dz = w.transform[s].z - w.transform[ts].z;
    const d2 = dx * dx + dz * dz;
    if (d2 >= flee_distance * flee_distance) {
        // Out of range: the fright is over, release the mutex.
        ai.revenge_time = 0;
        ai.clearPath();
        ai.has_path = false;
        return;
    }
    // Away from the attacker; a body exactly on top of it picks +x arbitrarily
    // rather than dividing by zero.
    const inv: f32 = if (d2 > 0.0001) 1.0 / @sqrt(d2) else 0;
    const fx = w.transform[s].x + (if (inv > 0) dx * inv else 1) * flee_distance;
    const fz = w.transform[s].z + (if (inv > 0) dz * inv else 0) * flee_distance;
    ai.path_goal_x = fx;
    ai.path_goal_z = fz;
    ai.has_path = true;
    chaseAlongPath(w, s, ai, fx, fz, cspd * ai.active_scale, dt);
}

/// EAITerritorial::CanExecute: has home and outside leash; yields to sensed player.
fn territorialCanExecute(w: *const World, s: Slot, ai: *const c.ZombieAi, np_id: i32, np_d2: f32) bool {
    if (!ai.has_home) return false;
    // Sensed player: approach owns movement; do not leash mid-fight.
    if (np_id >= 0 and np_d2 < sense_dist_sq) return false;
    if (!w.mask[s].transform) return false;
    const dx = w.transform[s].x - ai.home_x;
    const dz = w.transform[s].z - ai.home_z;
    return dx * dx + dz * dz > territorial_radius_sq;
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
    if (dx * dx + dz * dz <= spot_arrive * spot_arrive) {
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
        ai.look_turn_cd = look_turn_interval_s;
        const f = rngFrac(ai, w.network_id[s].id);
        ai.look_yaw = w.transform[s].yaw + f * look_yaw_range_deg - look_yaw_range_deg * 0.5;
    }
    w.transform[s].yaw = seekYawStep(w.transform[s].yaw, ai.look_yaw, look_turn_speed_deg, look_yaw_slow_at_deg, dt);
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
    if (np.d2 <= attack_range_sq) {
        ai.state = .attack;
        ai.clearPath();
        if (ai.attack_cd <= 0 and ctx.w.alive[np.slot] and ctx.w.mask[np.slot].player) {
            // A11: HandItem DamageEntity on class_table; module const if 0.
            const adm: f32 = if (ct.attack_damage > 0) ct.attack_damage else attack_damage;
            const add: u32 = @intFromFloat(adm * @as(f32, @floatFromInt(dmg_scale)));
            _ = @atomicRmw(u32, &ctx.dmg_fp[np.slot], .Add, add, .monotonic);
            _ = ctx.hits.fetchAdd(1, .monotonic);
            ai.attack_cd = attack_cooldown_s;
            ctx.w.flags[s].bits |= 1;
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
    const cur: i32 = @intFromFloat(@floor(w.transform[s].y));
    if (w.stepTo(sx, sz, cur, sx, sz)) |y| return y;
    if (w.groundY(w.transform[s].x, w.transform[s].z)) |gy| return @intFromFloat(@floor(gy));
    return cur;
}

/// One A* solve, refilling the whole waypoint buffer. Sets path_blocked when
/// the solve could not reach the goal cell (sealed cover → BreakBlock).
fn replanPath(w: *World, s: Slot, ai: *c.ZombieAi, gxi: i32, gzi: i32) void {
    const sx: i32 = @intFromFloat(@floor(w.transform[s].x));
    const sz: i32 = @intFromFloat(@floor(w.transform[s].z));
    const sy = footingY(w, s, sx, sz);
    w.transform[s].y = @floatFromInt(sy);
    _ = w.path_replans.fetchAdd(1, .monotonic);
    var p: path_mod.Path = .{};
    _ = path_mod.aStarToward(&p, sx, sz, sy, gxi, gzi, path_max_expand, w, pathStepCb);
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
    ai.path_replan_cd = path_replan_interval_s;
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
    const gxi: i32 = @intFromFloat(@floor(gx));
    const gzi: i32 = @intFromFloat(@floor(gz));
    // Reasons to solve again: the buffer is walked out, the goal left the cell
    // it was planned for, or the path is blocked and destroyed cover may have
    // opened a route. All of them wait for the throttle, including the spent
    // buffer: a body boxed in on all four sides gets an empty path every time,
    // and re-solving that on every tick is exactly what the budget exists to
    // prevent.
    const goal_drift = @abs(ai.path_goal_cx - gxi) + @abs(ai.path_goal_cz - gzi);
    const want = ai.currentWp() == null or goal_drift >= path_goal_slack or ai.path_blocked;
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
    // Consume every waypoint already reached, adopting its feet height so the
    // body follows terrain up and down instead of floating at spawn height.
    while (ai.currentWp()) |wp| {
        const tx = @as(f32, @floatFromInt(wp.x)) + 0.5;
        const tz = @as(f32, @floatFromInt(wp.z)) + 0.5;
        const dx = tx - w.transform[s].x;
        const dz = tz - w.transform[s].z;
        if (dx * dx + dz * dz >= path_wp_arrive * path_wp_arrive) break;
        w.transform[s].y = @floatFromInt(wp.y);
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
    if (dx * dx + dz * dz <= spot_arrive * spot_arrive) {
        ai.has_spot = false;
        ai.has_path = false;
        ai.clearPath();
        ai.path_blocked = false;
        ai.state = .idle;
        return;
    }
    chaseAlongPath(w, s, ai, ai.spot_x, ai.spot_z, cspd * ai.active_scale, dt);
}

/// EAIWander::Update: drift toward the Start-picked destination.
fn wanderUpdate(w: *World, s: Slot, ai: *c.ZombieAi, wspd: f32, dt: f32) void {
    ai.state = .wander;
    ai.alert = false;
    ai.target_id = -1;
    ai.has_path = false;
    ai.clearPath();
    ai.path_blocked = false;
    // EAIWander::Update (asm.il:438366): accumulate run time for the 30 s cap.
    ai.wander_time += dt;
    stepToward(w, s, ai.wander_tx, ai.wander_tz, wspd * ai.active_scale, dt);
}

pub fn systemZombieAi(w: *World, dt: f32) u32 {
    // Zombie AI also drives animal wander (kind.animal reuses zombie_ai mask).
    if (w.countKind(.zombie) == 0 and w.countKind(.animal) == 0) return 0;
    var snaps: [64]PlayerSnap = undefined;
    const pn = snapshotPlayers(w, &snaps);
    var dmg_fp: [max_entities]u32 = .{0} ** max_entities;
    var hits_a: std.atomic.Value(u32) = .init(0);
    const ctx = AiCtx{
        .w = w,
        .dt = dt,
        .players = snaps[0..pn],
        .dmg_fp = dmg_fp[0..],
        .hits = &hits_a,
        .zombie_speed_scale = w.zombie_speed_scale,
    };
    // Slot count is the constant 512, so forRanges always pays the pool
    // broadcast/wait round-trip; skip it while the live population is small
    // enough that one worker's share would finish before the wakeup does.
    if (w.entity_count < 64) AiCtx.work(ctx, 0, max_entities) else parallel.forRanges(max_entities, ctx, AiCtx.work);
    _ = applyDeferredDamage(w, dmg_fp[0..]);
    return hits_a.load(.monotonic);
}

pub fn systemDirector(w: *World, dt: f32) struct { spawned: u32, world_time: u64 } {
    const r = w.director.tick(w, dt);
    return .{ .spawned = r.spawned, .world_time = r.world_time };
}

/// EntityVehicle::cGravity static literal, asm.il:536018. Vertical acceleration
/// applied to server-simulated vehicles (distinct from World::Gravity 0.08).
const gravity_accel: f32 = -9.81;

pub fn systemVehicles(w: *World, dt: f32) void {
    if (w.countKind(.vehicle) == 0) return;
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        if (!w.alive[i] or !w.mask[i].vehicle or !w.mask[i].transform) continue;
        var v = &w.vehicle[i];

        // Vertical physics: gravity accumulator + terrain-top clamp. Runs for
        // every vehicle (parked included). Skipped when no terrain hook is set.
        const t = &w.transform[i];
        if (w.groundY(t.x, t.z)) |gy| {
            if (t.y > gy) {
                v.vy += gravity_accel * dt;
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

        if (v.driver_net_id < 0) continue;
        if (w.slotOfNetId(v.driver_net_id)) |pi| {
            if (w.mask[pi].transform) {
                w.transform[pi].x = w.transform[i].x;
                w.transform[pi].y = w.transform[i].y + 1;
                w.transform[pi].z = w.transform[i].z;
                w.transform[pi].yaw = w.transform[i].yaw;
            }
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
    if (w.vehicle[slot].driver_net_id < 0) return;
    var v = &w.vehicle[slot];
    v.throttle = throttle;
    v.steer = steer;
    const max_spd: f32 = if (v.max_speed > 0.1) v.max_speed else vehicleKindDefaultSpeed(v.kind);
    // Stronger accel so a short C2S drive pulse still moves (playtest ≥0.4 m).
    v.speed += throttle * 14.0 * dt;
    if (v.speed > max_spd) v.speed = max_spd;
    if (v.speed < -max_spd * 0.3) v.speed = -max_spd * 0.3;
    // Coast decay only when no throttle input.
    if (@abs(throttle) < 0.05) v.speed *= 1.0 - 0.8 * dt;
    const spd_frac = if (max_spd > 0.01) @abs(v.speed) / max_spd else 0;
    w.transform[slot].yaw += steer * 100.0 * dt * @max(spd_frac, 0.15);
    const rad = w.transform[slot].yaw * (std.math.pi / 180.0);
    w.transform[slot].x += @sin(rad) * v.speed * dt;
    w.transform[slot].z += @cos(rad) * v.speed * dt;
    if (v.kind != .bicycle) {
        if (v.fuel <= 0) {
            v.speed = 0;
            return;
        }
        v.fuel -= @abs(v.speed) * 0.02 * dt;
        if (v.fuel < 0) v.fuel = 0;
    }
}

/// Apply held throttle/steer every sim tick (stock client may send sparse drive pkgs).
pub fn vehicleTickHeld(w: *World, dt: f32) void {
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        if (!w.alive[i] or !w.mask[i].vehicle) continue;
        if (w.vehicle[i].driver_net_id < 0) continue;
        const v = w.vehicle[i];
        // Re-apply held input; zero throttle still coasts via vehicleControl.
        vehicleControl(w, i, v.throttle, v.steer, dt);
    }
}

pub fn vehicleEnter(w: *World, vslot: Slot, player_net: i32) bool {
    if (!w.alive[vslot] or !w.mask[vslot].vehicle) return false;
    if (w.vehicle[vslot].driver_net_id >= 0) return false;
    const ps = w.slotOfNetId(player_net) orelse return false;
    if (!w.mask[ps].transform or !w.mask[vslot].transform) return false;
    const dx = w.transform[ps].x - w.transform[vslot].x;
    const dz = w.transform[ps].z - w.transform[vslot].z;
    if (dx * dx + dz * dz > 64.0) return false;
    w.vehicle[vslot].driver_net_id = player_net;
    return true;
}

pub fn vehicleExit(w: *World, player_net: i32) bool {
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        if (w.alive[i] and w.mask[i].vehicle and w.vehicle[i].driver_net_id == player_net) {
            w.vehicle[i].driver_net_id = -1;
            w.vehicle[i].speed = 0;
            w.vehicle[i].throttle = 0;
            w.vehicle[i].steer = 0;
            return true;
        }
    }
    return false;
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
                const add: u32 = @intFromFloat(t.damage * @as(f32, @floatFromInt(dmg_scale)));
                _ = @atomicRmw(u32, &ctx.dmg_fp[zi], .Add, add, .monotonic);
            }
        }
    }
};

pub const TurretTick = struct {
    kills: u32 = 0,
    /// Dead zombie net ids (for S2C EntityRemove).
    killed_ids: [16]i32 = .{-1} ** 16,
    killed_n: u8 = 0,
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
    const ctx = TurretCtx{ .w = w, .dt = dt, .dmg_fp = dmg_fp[0..], .zombies = zombie_slots[0..zn], .powered = &powered };
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
            w.destroy(i);
            out.kills += 1;
            if (zid > 0 and out.killed_n < out.killed_ids.len) {
                out.killed_ids[out.killed_n] = zid;
                out.killed_n += 1;
            }
            if (w.spawnLootBag(x, y, z, 1, 5)) |lid| {
                if (out.loot_n < out.loot_bag_ids.len) {
                    out.loot_bag_ids[out.loot_n] = lid;
                    out.loot_n += 1;
                }
            }
        }
    }
    return out;
}

pub fn systemPower(w: *World) void {
    w.power.resolve();
}

/// Despawn range for director-spawned zombies (stock unloads far spawned zeds).
pub const despawn_dist_sq: f32 = 200.0 * 200.0;

/// Remove idle/wandering zombies far from every player. Returns removed ids
/// (caller broadcasts EntityRemove with Despawned reason).
pub fn systemDespawnFar(w: *World, out_ids: []i32) u8 {
    if (w.countKind(.zombie) == 0) return 0;
    var snaps: [64]PlayerSnap = undefined;
    const pn = snapshotPlayers(w, &snaps);
    var n: u8 = 0;
    // This loop destroys, so it walks a snapshot of the zombie group rather
    // than the live group (same ascending order, so the capped out_ids picks
    // the same ids as the old open scan).
    var zombies: [max_entities]Slot = undefined;
    const zn = query.copyKindInto(w, .zombie, &zombies);
    for (zombies[0..zn]) |i| {
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
    try std.testing.expect(vehicleEnter(&w, vs, pid));
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
    const a = seekYawStep(0, 180, 250, 35, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), a, 0.001);
    // Shortest arc across the 0/360 seam: 350 -> 60 turns +70, not -290, and
    // the 12.5 deg step wraps the result back into [0,360).
    const b = seekYawStep(350, 60, 250, 35, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), b, 0.001);
    // And the other way: 10 -> 300 turns -70, wrapping below zero.
    const cc = seekYawStep(10, 300, 250, 35, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 357.5), cc, 0.001);
    // Negative input yaw (stepToward writes atan2 in [-180,180]) normalizes.
    try std.testing.expectApproxEqAbs(@as(f32, 350.0), seekYawStep(-10, -10, 250, 35, 0.05), 0.001);
    // Inside slow_at the speed is max_turn*(d/slow_at)^2: d=17.5 -> 250*0.25=62.5.
    const d = seekYawStep(0, 17.5, 250, 35, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 3.125), d, 0.001);
    // Deep inside slow_at the 20 deg/s floor takes over: d=1 -> 250*(1/35)^2
    // = 0.204 < 20, so speed 20 and a 0.05 s step of 1.0 exactly reaches it.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), seekYawStep(0, 1, 250, 35, 0.05), 0.001);
    // Never overshoot: a step larger than the remaining delta snaps exactly.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), seekYawStep(0, 0.5, 250, 35, 1.0), 0.001);
    // Zero delta is a no-op, not an oscillation.
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), seekYawStep(90, 90, 250, 35, 0.05), 0.001);
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
    try std.testing.expect(w.zombie_ai[zs].look_time >= wander_look_min_s);
    try std.testing.expect(w.zombie_ai[zs].look_time <= wander_look_max_s);
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
    try std.testing.expect(w.zombie_ai[zs].look_time >= spot_look_base_s);
    try std.testing.expect(w.zombie_ai[zs].look_time <= spot_look_base_s + spot_look_rand_s);
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

test "chase reuses one solve for many steps instead of replanning per metre" {
    var w: World = .{};
    defer w.deinit();
    w.step_fn = path_mod.openStep;
    w.step_ctx = null;
    const z = w.spawnZombie(0, 70, 0, 40).?;
    _ = w.spawnPlayer(10, 70, 0, 0);
    const zs = w.slotOfNetId(z).?;
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
    w.step_fn = path_mod.openStep;
    w.step_ctx = null;
    const z = w.spawnZombie(0, 70, 0, 40).?;
    // Far enough that the buffer runs dry while still chasing (a body that
    // reaches melee range clears its path instead of asking for a new one).
    _ = w.spawnPlayer(14, 70, 0, 0);
    const zs = w.slotOfNetId(z).?;
    // Prime the buffer, then close the budget on this slot.
    _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(w.zombie_ai[zs].currentWp() != null);
    w.path_stride = 2;
    w.path_tick = if (zs % 2 == 0) 1 else 0; // (slot + tick) % 2 != 0
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
    var admitted: u32 = 0;
    var s: Slot = 0;
    while (s < 30) : (s += 1) {
        if (w.pathBudgetAdmits(s)) admitted += 1;
        try std.testing.expectEqual(w.pathBudgetAdmits(s), w.pathBudgetAdmits(s));
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
    // Shot from behind by the far player: EAISetAsTargetIfHurt retargets.
    _ = w.damageFrom(z, 5, far);
    _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(far, w.zombie_ai[zs].target_id);
    try std.testing.expect(w.zombie_ai[zs].alert);
    // Walks away from the near player, toward the attacker.
    t = 0;
    while (t < 2.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(w.transform[zs].x < -0.2);
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
    const p = w.spawnPlayer(2, 70, 0, 0).?;
    _ = w.damageFrom(a, 5, p);
    var t: f32 = 0;
    while (t < 2.0) : (t += 0.05) _ = systemZombieAi(&w, 0.05);
    try std.testing.expectEqual(c.TaskId.runaway, w.zombie_ai[as].active_task);
    // Fleeing means putting distance between itself and the player at x=2.
    try std.testing.expect(w.transform[as].x < -0.5);
    try std.testing.expect(!w.zombie_ai[as].alert);
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
    w.class_table[1].chase_speed = 1.0; // XML-scale; sim uses *1.6
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
        if (dx * dx + dz * dz <= territorial_radius_sq) break;
    }
    const dx = w.transform[zs].x - w.zombie_ai[zs].home_x;
    const dz = w.transform[zs].z - w.zombie_ai[zs].home_z;
    try std.testing.expect(dx * dx + dz * dz <= territorial_radius_sq);
}

test "quest kill complete on journal component" {
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(questAccept(&w, 0, 1));
    try std.testing.expect(questHasActive(&w, 0, 1));
    questOnZombieKilled(&w, 0);
    questOnZombieKilled(&w, 0);
    questOnZombieKilled(&w, 0);
    try std.testing.expect(!questHasActive(&w, 0, 1));
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
    questOnZombieKilled(&w, 0);
    try std.testing.expectEqual(@as(u8, 1), s.phase);

    // Reach the goto point → advance to the kill phase.
    questTickGoto(&w, 0, 10, 70, 10);
    try std.testing.expectEqual(@as(u8, 2), s.phase);

    // Three kills complete the kill phase → trader phase, not yet ready.
    questOnZombieKilled(&w, 0);
    questOnZombieKilled(&w, 0);
    questOnZombieKilled(&w, 0);
    try std.testing.expectEqual(@as(u8, 3), s.phase);
    try std.testing.expect(!s.ready_turn_in);
    try std.testing.expect(questHasActive(&w, 0, 20));

    // Interacting at the trader satisfies the highest phase and turns in.
    questOnTraderOpen(&w, 0);
    try std.testing.expect(!questHasActive(&w, 0, 20));
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
    questOnZombieKilled(&w, 0);
    questOnZombieKilled(&w, 0);
    try std.testing.expect(!questHasActive(&w, 0, 21));
    try std.testing.expectEqual(@as(u32, 30), questCoins(&w, 0));
}

/// Fixed POI covering the quest target used by the rally tests.
fn testPoiRect(_: ?*anyopaque, x: f32, z: f32) ?c.PoiRect {
    const rect: c.PoiRect = .{ .x = 0, .y = 60, .z = 0, .size_x = 64, .size_y = 20, .size_z = 64 };
    return if (rect.containsXZ(x, z)) rect else null;
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
    questOnZombieKilled(&w, 0);
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
    questOnZombieKilled(&w, 0);
    questOnZombieKilled(&w, 0);
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
    questOnZombieKilled(&w, 0);
    questOnZombieKilled(&w, 0);
    try std.testing.expect(questHasActive(&w, 0, 9));
    try std.testing.expect(questFindActive(&w, 0, 9).?.ready_turn_in);
    questOnTraderOpen(&w, 0);
    try std.testing.expect(!questHasActive(&w, 0, 9));
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

test "failed trader buy leaves wallet stock and inventory unchanged" {
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    const trader_id = w.spawnTrader("Trader", 1, 70, 1).?;
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
