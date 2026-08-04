//! ECS systems: pure functions over World SoA columns + resources.
//! Hot loops (zombie AI, turrets) run multi-threaded over disjoint slots.

const std = @import("std");
const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const max_entities = @import("world.zig").max_entities;
const c = @import("components.zig");
const quest = @import("quest.zig");
const path_mod = @import("path.zig");
const parallel = @import("../util/parallel.zig");

pub const full_ai_dist_sq: f32 = 64.0 * 64.0;
pub const mid_ai_dist_sq: f32 = 225.0;
pub const sense_dist_sq: f32 = 48.0 * 48.0;
pub const attack_range_sq: f32 = 2.0 * 2.0;
pub const attack_damage: f32 = 8.0;
pub const chase_speed: f32 = 2.2;
pub const wander_speed: f32 = 0.8;
pub const attack_cooldown_s: f32 = 1.2;
/// Replan grid A* at most this often while chasing (keeps 20 TPS budget).
const path_replan_interval_s: f32 = 0.35;
/// Max A* node expansions per replan (coarse local grid).
const path_max_expand: usize = 96;
/// Snap to next waypoint within this distance (blocks).
const path_wp_arrive: f32 = 0.55;

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
    var j: Slot = 0;
    while (j < max_entities and n < out.len) : (j += 1) {
        if (!w.alive[j] or !w.mask[j].player or !w.mask[j].transform) continue;
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

fn nearestPlayerSnap(snaps: []const PlayerSnap, zx: f32, zz: f32) struct { id: i32, slot: Slot, d2: f32, px: f32, pz: f32 } {
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

fn applyDeferredDamage(w: *World, dmg_fp: []const u32) u32 {
    var applied: u32 = 0;
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        const fp = dmg_fp[i];
        if (fp == 0) continue;
        if (!w.alive[i] or !w.mask[i].health) continue;
        const amount: f32 = @as(f32, @floatFromInt(fp)) / @as(f32, @floatFromInt(dmg_scale));
        if (w.kind[i] == .trader) continue;
        w.health[i].hp -= amount;
        applied += 1;
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
        if (w.mask[ps].wallet) w.wallet[ps].coins +%= d.reward_coin;
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

/// Auto-complete leading `.auto` scaffolding phases (RallyPoint/StayWithin/etc.)
/// starting at the current phase; finishes the quest if the highest phase is auto.
fn skipAutoPhases(w: *World, ps: Slot, s: *c.QuestProgress, d: quest.QuestDef) void {
    while (currentPhaseSpec(d, s)) |spec| {
        if (spec.kind != .auto) return;
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
    s.progress +%= n;
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
    // Phase graph: land the player on the first actionable (non-auto) phase.
    const d = w.catalog.byId(def_id).?;
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
        s.progress +%= 1;
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
        s.progress +%= count;
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
        s.progress +%= 1;
        markProgress(w, ps, s, d);
    }
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
                s.progress +%= 1;
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
                if (!w.inventory[ps].addItem(slot.item_id, slot.count)) {
                    transferred = false;
                    break;
                }
            }
            if (!transferred) {
                w.inventory[ps] = inventory_before;
                continue;
            }
        }
        w.destroy(i);
        n += 1;
    }
    if (n > 0 and w.mask[ps].dirty) w.dirty[ps].inv = true;
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
            // Prefer removing casinoCoin items so client bag matches wallet.
            if (w.mask[ps].inventory) {
                const inventory_before = w.inventory[ps];
                const have = w.inventory[ps].countItem(coin_id);
                if (have >= cost) {
                    if (!w.inventory[ps].removeItem(coin_id, @intCast(cost))) {
                        w.inventory[ps] = inventory_before;
                        return false;
                    }
                }
                if (!w.inventory[ps].addItem(item, qty)) {
                    w.inventory[ps] = inventory_before;
                    return false;
                }
                if (w.mask[ps].dirty) w.dirty[ps].inv = true;
            }
            stock.entries[e].count -= qty;
            w.wallet[ps].coins -= cost;
            if (w.mask[ps].inventory and w.mask[ps].dirty) w.dirty[ps].inv = true;
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
                if (!w.inventory[ps].addItem(coin_id, @intCast(gain))) {
                    w.inventory[ps] = inventory_before;
                    return false;
                }
                if (w.mask[ps].dirty) w.dirty[ps].inv = true;
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
// Only two real tasks are registered (ApproachAndAttackTarget, Wander); the
// engine supports more table rows but the rest of stock's EAI catalog
// (BreakBlock, DestroyArea, Territorial, Look, Dodge, Leap, RangedAttack, ...)
// is an honest gap (docs/MISSING_FEATURES.md). Because the two tasks share
// MutexBit 0 they are mutually exclusive, so collapsing the executing set to a
// single TaskId (ZombieAi.active_task) is exact for this set; adding a
// continuous non-conflicting task later (e.g. Look) would need a task bitset.

/// Comptime task table. Priority ascending == array order == stock XML AITask
/// order == EAIManager::ParseTasks insertion order (asm.il:430620). Values
/// mirror EAIApproachAndAttackTarget::Init (MutexBits=3, executeDelay=0.1,
/// non-continuous; asm.il:421798) and EAIWander::Init (MutexBits=1, continuous
/// default; asm.il:438104,424579).
const Task = struct { id: c.TaskId, priority: u8, mutex: u8, execute_delay: f32, continuous: bool };
const zombie_tasks = [_]Task{
    .{ .id = .approach_attack, .priority = 1, .mutex = 0b11, .execute_delay = 0.1, .continuous = false },
    .{ .id = .wander, .priority = 2, .mutex = 0b01, .execute_delay = 0.5, .continuous = true },
};

/// EAITaskList.executeDelayScale base (asm.il:437541, IL_0028 ldc.r4 0.85).
/// The stock GameRandom jitter blended on top is dropped (simplification).
const execute_delay_scale: f32 = 0.85;

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

/// EAIWander::CanExecute (asm.il:438161) does NOT test for a target; here it is
/// the pure fallback: wander whenever no player is sensed. It yields to chase
/// only through priority + MutexBits, never through this gate.
fn wanderCanExecute(np_id: i32, np_d2: f32) bool {
    return !(np_id >= 0 and np_d2 < sense_dist_sq);
}

const AiCtx = struct {
    w: *World,
    dt: f32,
    players: []const PlayerSnap,
    /// Fixed-point damage accumulators, one per entity slot (atomic adds).
    dmg_fp: []u32,
    hits: *std.atomic.Value(u32),

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

            const np = nearestPlayerSnap(ctx.players, ctx.w.transform[s].x, ctx.w.transform[s].z);
            ai.active_scale = if (np.id >= 0) lodScale(np.d2) else 0.1;

            // Per-class speeds from entityclasses when set (XML MoveSpeed ~0.08
            // shamble -> sim scale x10; MoveSpeedAggro max ~1.35 -> x1.6).
            const ct = ctx.w.class_table[ctx.w.class_id[s].id];
            const sscale = ctx.w.zombie_speed_scale;
            const wspd: f32 = (if (ct.wander_speed > 0) ct.wander_speed * 10.0 else wander_speed) * sscale;
            const cspd: f32 = (if (ct.chase_speed > 0) ct.chase_speed * 1.6 else chase_speed) * sscale;

            // EAITaskList::OnUpdateTasks step 1 (asm.il:437713): stop the
            // executing task when it is no longer best or its Continue() fails.
            if (ai.active_task != .none) {
                const t = taskById(ai.active_task).?;
                if (!(isBestTask(t, ai.active_task) and canExecute(ctx.w, ai.active_task, ai, np))) {
                    ai.decision_cd = t.execute_delay * execute_delay_scale;
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
                    if (isBestTask(t, ai.active_task) and canExecute(ctx.w, t.id, ai, np)) {
                        chosen = t.id;
                        break;
                    }
                }
                ai.active_task = chosen;
                ai.decision_cd = (taskById(chosen) orelse zombie_tasks[0]).execute_delay * execute_delay_scale;
                startTask(chosen, ctx.w, s, ai);
            }

            // Steps 3/4: run the winning task's Update and project it onto the
            // coarse ZombieAi.state enum for downstream replication parity.
            switch (ai.active_task) {
                .approach_attack => approachUpdate(ctx, s, ai, np, cspd, ct),
                .wander => wanderUpdate(ctx.w, s, ai, wspd, ctx.dt),
                .none => {
                    if (ai.state != .sleep) ai.state = .idle;
                    ai.alert = false;
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

/// Dispatch to a task's CanExecute gate (Continue() == CanExecute for both).
fn canExecute(w: *const World, id: c.TaskId, ai: *const c.ZombieAi, np: anytype) bool {
    return switch (id) {
        .approach_attack => approachCanExecute(w, ai, np.id, np.d2),
        .wander => wanderCanExecute(np.id, np.d2),
        .none => false,
    };
}

/// EAIBase::Start hook. Only Wander has meaningful state to seed: it picks a
/// fresh destination (EAIWander::Start). Runs on every re-eval that selects the
/// task so a continuously-wandering zombie keeps drifting in new directions.
fn startTask(id: c.TaskId, w: *World, s: Slot, ai: *c.ZombieAi) void {
    if (id != .wander) return;
    // Deterministic per-entity xorshift32 so streams differ per entity and the
    // direction varies each pass (a constant hash would drift one way forever).
    if (ai.wander_rng == 0) ai.wander_rng = @bitCast(w.network_id[s].id | 1);
    var r = ai.wander_rng;
    r ^= r << 13;
    r ^= r >> 17;
    r ^= r << 5;
    ai.wander_rng = r;
    const ox: f32 = @floatFromInt(@as(i32, @intCast(r % 17)) - 8);
    const oz: f32 = @floatFromInt(@as(i32, @intCast((r / 17) % 17)) - 8);
    ai.wander_tx = w.transform[s].x + ox;
    ai.wander_tz = w.transform[s].z + oz;
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
        ai.path_wp_valid = false;
        if (ai.attack_cd <= 0 and ctx.w.alive[np.slot] and ctx.w.mask[np.slot].player) {
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

fn pathSolidCb(ctx: ?*anyopaque, x: i32, z: i32) bool {
    const w: *const World = @ptrCast(@alignCast(ctx.?));
    return w.isPathSolid(x, z);
}

/// Replan A* on a throttle, then step toward the next waypoint (or goal).
/// When no solid_fn is wired, degenerates to straight-line stepToward.
fn chaseAlongPath(w: *World, s: Slot, ai: *c.ZombieAi, gx: f32, gz: f32, speed: f32, dt: f32) void {
    if (w.solid_fn == null) {
        stepToward(w, s, gx, gz, speed, dt);
        return;
    }
    if (ai.path_replan_cd > 0) ai.path_replan_cd -= dt;
    const sx: i32 = @intFromFloat(@floor(w.transform[s].x));
    const sz: i32 = @intFromFloat(@floor(w.transform[s].z));
    const gxi: i32 = @intFromFloat(@floor(gx));
    const gzi: i32 = @intFromFloat(@floor(gz));
    const need_replan = ai.path_replan_cd <= 0 or !ai.path_wp_valid;
    if (need_replan) {
        var p: path_mod.Path = .{};
        path_mod.aStarToward(&p, sx, sz, gxi, gzi, path_max_expand, w, pathSolidCb);
        if (p.next()) |wp| {
            ai.path_wp_x = wp.x;
            ai.path_wp_z = wp.z;
            ai.path_wp_valid = true;
        } else {
            ai.path_wp_valid = false;
        }
        ai.path_replan_cd = path_replan_interval_s;
    }
    if (ai.path_wp_valid) {
        const tx = @as(f32, @floatFromInt(ai.path_wp_x)) + 0.5;
        const tz = @as(f32, @floatFromInt(ai.path_wp_z)) + 0.5;
        const dx = tx - w.transform[s].x;
        const dz = tz - w.transform[s].z;
        if (dx * dx + dz * dz < path_wp_arrive * path_wp_arrive) {
            ai.path_wp_valid = false;
            ai.path_replan_cd = 0;
        }
        stepToward(w, s, tx, tz, speed, dt);
    } else {
        stepToward(w, s, gx, gz, speed, dt);
    }
}

/// EAIWander::Update: drift toward the Start-picked destination.
fn wanderUpdate(w: *World, s: Slot, ai: *c.ZombieAi, wspd: f32, dt: f32) void {
    ai.state = .wander;
    ai.alert = false;
    ai.target_id = -1;
    ai.has_path = false;
    ai.path_wp_valid = false;
    stepToward(w, s, ai.wander_tx, ai.wander_tz, wspd * ai.active_scale, dt);
}

pub fn systemZombieAi(w: *World, dt: f32) u32 {
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
    };
    parallel.forRanges(max_entities, ctx, AiCtx.work);
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

pub fn vehicleControl(w: *World, slot: Slot, throttle: f32, steer: f32, dt: f32) void {
    if (!w.alive[slot] or !w.mask[slot].vehicle or !w.mask[slot].transform) return;
    if (w.vehicle[slot].driver_net_id < 0) return;
    var v = &w.vehicle[slot];
    const max_spd: f32 = if (v.max_speed > 0) v.max_speed else switch (v.kind) {
        .bicycle => 6,
        .minibike => 12,
        .motorcycle => 18,
        .four_by_four => 14,
        .gyrocopter => 20,
    };
    v.speed += throttle * 8.0 * dt;
    if (v.speed > max_spd) v.speed = max_spd;
    if (v.speed < -max_spd * 0.3) v.speed = -max_spd * 0.3;
    v.speed *= 1.0 - 0.5 * dt;
    w.transform[slot].yaw += steer * 90.0 * dt * (@abs(v.speed) / max_spd);
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
            return true;
        }
    }
    return false;
}

const TurretCtx = struct {
    w: *World,
    dt: f32,
    dmg_fp: []u32,

    fn work(ctx: TurretCtx, begin: usize, end: usize) void {
        var i: usize = begin;
        while (i < end) : (i += 1) {
            const s: Slot = @intCast(i);
            if (!ctx.w.alive[s] or !ctx.w.mask[s].turret or !ctx.w.mask[s].transform) continue;
            var t = &ctx.w.turret[s];
            if (t.fire_cd > 0) t.fire_cd -= ctx.dt;
            const powered = ctx.w.power.isEntityPowered(ctx.w.network_id[s].id);
            if (!powered or t.ammo == 0) {
                t.target_id = -1;
                continue;
            }
            var best_id: i32 = -1;
            var best_slot: ?Slot = null;
            var best_d: f32 = t.range * t.range;
            var j: Slot = 0;
            while (j < max_entities) : (j += 1) {
                if (!ctx.w.alive[j] or !ctx.w.mask[j].kind or ctx.w.kind[j] != .zombie) continue;
                if (!ctx.w.mask[j].transform) continue;
                const dx = ctx.w.transform[j].x - ctx.w.transform[s].x;
                const dz = ctx.w.transform[j].z - ctx.w.transform[s].z;
                const d = dx * dx + dz * dz;
                if (d < best_d) {
                    best_d = d;
                    best_id = ctx.w.network_id[j].id;
                    best_slot = j;
                }
            }
            t.target_id = best_id;
            const zi = best_slot orelse continue;
            const dx = ctx.w.transform[zi].x - ctx.w.transform[s].x;
            const dz = ctx.w.transform[zi].z - ctx.w.transform[s].z;
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
    var dmg_fp: [max_entities]u32 = .{0} ** max_entities;
    const ctx = TurretCtx{ .w = w, .dt = dt, .dmg_fp = dmg_fp[0..] };
    parallel.forRanges(max_entities, ctx, TurretCtx.work);
    var out: TurretTick = .{};
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        const fp = dmg_fp[i];
        if (fp == 0) continue;
        if (!w.alive[i] or !w.mask[i].health) continue;
        if (w.kind[i] != .zombie) continue;
        const amount: f32 = @as(f32, @floatFromInt(fp)) / @as(f32, @floatFromInt(dmg_scale));
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
    var snaps: [64]PlayerSnap = undefined;
    const pn = snapshotPlayers(w, &snaps);
    var n: u8 = 0;
    var i: Slot = 0;
    while (i < max_entities and n < out_ids.len) : (i += 1) {
        if (!w.alive[i] or w.kind[i] != .zombie or !w.mask[i].transform) continue;
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

pub fn tickAll(w: *World, dt: f32) struct {
    ai_hits: u32,
    director_spawned: u32,
    world_time: u64,
    turret_kills: u32,
    killed_ids: [16]i32,
    killed_n: u8,
    loot_bag_ids: [16]i32,
    loot_n: u8,
    despawned_ids: [8]i32,
    despawned_n: u8,
} {
    const dr = systemDirector(w, dt);
    const hits = systemZombieAi(w, dt);
    systemVehicles(w, dt);
    systemPower(w);
    const tk = systemTurrets(w, dt);
    var de_ids: [8]i32 = .{0} ** 8;
    const de_n = systemDespawnFar(w, de_ids[0..]);
    return .{
        .ai_hits = hits,
        .director_spawned = dr.spawned,
        .world_time = dr.world_time,
        .turret_kills = tk.kills,
        .killed_ids = tk.killed_ids,
        .killed_n = tk.killed_n,
        .loot_bag_ids = tk.loot_bag_ids,
        .loot_n = tk.loot_n,
        .despawned_ids = de_ids,
        .despawned_n = de_n,
    };
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
    const approach = zombie_tasks[0];
    const wander = zombie_tasks[1];
    // Approach (priority 1, mutex 0b11) is best while Wander (continuous,
    // priority 2) executes: higher-priority continuous never blocks.
    try std.testing.expect(isBestTask(approach, .wander));
    // Wander is NOT best while Approach executes: priority 1 <= 2 and
    // MutexBits overlap (0b11 & 0b01 == 0b01 != 0) makes them incompatible.
    try std.testing.expect(!isBestTask(wander, .approach_attack));
    // No executing task, or self as the executor, is always best.
    try std.testing.expect(isBestTask(approach, .none));
    try std.testing.expect(isBestTask(wander, .none));
    try std.testing.expect(isBestTask(wander, .wander));
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

test "system zombie paths around solid wall via A*" {
    // Wall at x=2, z=-2..2; zombie at 0, player at 4. Straight line blocked.
    const Wall = struct {
        fn solid(_: ?*anyopaque, x: i32, z: i32) bool {
            return x == 2 and z >= -2 and z <= 2;
        }
    };
    var w: World = .{};
    defer w.deinit();
    w.solid_fn = Wall.solid;
    w.solid_ctx = null;
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
