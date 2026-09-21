//! Quest + trader systems: journal phase graph, wallet, loot pickup,
//! trader buy/sell/restock. Pure functions over World SoA columns.
//!
//! Split out of systems.zig (same functions, moved verbatim); re-exported
//! through the systems facade so existing `systems.quest*` / `systems.trade`
//! call sites keep working.

const std = @import("std");
const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const c = @import("components.zig");
const quest = @import("quest.zig");
const poi_lock = @import("poi_lock.zig");
const query = @import("query.zig");
const inventory = @import("inventory.zig");
const max_entities = @import("world.zig").max_entities;

// --- Quest systems (journal + wallet components) ---

fn completeQuest(w: *World, ps: Slot, s: *c.QuestProgress) void {
    if (s.completed) return;
    s.completed = true;
    s.active = false;
    s.ready_turn_in = false;
    if (w.catalog.byId(s.def_id) != null) {
        // reward_coin pays at the tick-end payout (step.zig), through the
        // on_quest_complete verdict like items/exp - paying here would let a
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
/// finish at the highest phase. Mirrors Quest.AdvancePhase (asm.il 986686).
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
        var newly: bool = false;
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
            const before = s.obj_progress[i];
            s.obj_progress[i] = @min(before +| n, req);
            if (s.obj_progress[i] > before) newly = true;
            advanced = true;
        }
        if (!advanced) return;
        // Already at req for this kind: a redelivered client objective event
        // must not re-run advancePhaseGraph (phase-entry SpawnGSEnemy, etc.).
        if (!newly) return;
        // Mirror the old single-progress semantics for the wire/tests: the
        // advancing phase objective's progress.
        var max_p: u16 = 0;
        for (d.objectives, 0..) |o, i| {
            if (o.kind != kind or (o.phase != s.phase and o.phase != 0)) continue;
            if (i < s.obj_progress.len) max_p = @max(max_p, s.obj_progress[i]);
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
    // Same redelivery guard as the objective path: do not re-finish a phase
    // whose progress already met required.
    if (s.progress >= spec.required) return;
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
    return questAcceptWithCode(w, peer_slot, def_id, 0, .{});
}

/// Accept `def_id` into `peer_slot`'s journal with an explicit stock quest
/// code and POI placement.
///
/// `quest_code == 0` allocates the next code (what a first accept does);
/// nonzero adopts the caller's code, which is how a party member's copy of a
/// SHARED quest keeps the owner's code. Stock sends that code to every member
/// in `NetPackageSharedQuest` (`SharedQuestData.questCode`,
/// Quest.CodeAssignment = hash(unscaledTime, ID, owner entityId, giverId) -
/// Quest::SetupQuestCode IL=48), and stock resolves shared-quest traffic by
/// code alone: `QuestJournal.GetSharedQuest(Int32 questCode)` (IL=33) for
/// add/remove_shared_member and `RemoveSharedQuestByOwner(Int32 questCode)`
/// for the owner's remove fan-out. A member entry with a freshly allocated
/// code could never satisfy those lookups, so the member's client saw the
/// quest advance while the server journal silently stayed put.
///
/// `poi` reuses the owner's placement when valid so both copies of a shared
/// quest sit in the same POI (the owner's client sends that POI's rect in the
/// share packet); an unset rect falls through to the normal selection.
pub fn questAcceptWithCode(w: *World, peer_slot: usize, def_id: u16, quest_code: i32, poi: c.PoiRect) bool {
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
    const code = if (quest_code != 0) quest_code else blk: {
        const fresh = w.next_quest_code;
        w.next_quest_code +%= 1;
        break :blk fresh;
    };
    s.* = .{
        .def_id = def_id,
        .quest_code = code,
        .active = true,
        .completed = false,
        .ready_turn_in = false,
        .progress = 0,
        .phase = 1,
        .poi = poi,
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
    for (query.groupSlice(w, .player)) |i| {
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

pub fn questTickGoto(w: *World, peer_slot: usize, px: f32, pz: f32) void {
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
    var bags: [max_entities]Slot = undefined;
    const bn = query.copyKindInto(w, .loot_bag, &bags);
    for (bags[0..bn]) |i| {
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

/// Clamp a float dukes unit price into the u16 trader/wire slot. Non-finite
/// (Inf from EconomicValue="inf", NaN from a bad markup) or non-positive fails
/// closed to `fallback` instead of trapping `@intFromFloat` / `@as(u64, …)` on
/// values past the integer domain. Clamp in the float domain first so a
/// modded EconomicValue of 1e20 cannot overflow the cast before `@min(…, 65535)`.
pub fn clampDukesUnitPrice(scaled: f64, fallback: u16) u16 {
    if (!std.math.isFinite(scaled) or scaled <= 0) return fallback;
    return @intFromFloat(@min(@trunc(scaled), 65535.0));
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
        // Barter perk (RE GetBuyPrice IL=240): the buyer pays
        // `unit - unit * BarteringBuying(148)`, ceiled like stock's final
        // CeilToInt. Applied after the verdict so plugins see the pre-barter
        // price (verdict is zdtd-native; stock applies barter inside
        // GetBuyPrice itself). Floor at 1: stock's ceil of a positive
        // fraction never reaches 0.
        if (w.barter_buy_fn) |bf| {
            const scale = bf(w.barter_buy_ctx, player_peer);
            if (scale < 1) {
                const disc_f: f64 = @as(f64, @floatFromInt(unit)) * @as(f64, 1 - scale);
                const kept: f64 = @max(0, @as(f64, @floatFromInt(unit)) - disc_f);
                unit = @intCast(@max(1, @as(u64, @ceil(kept))));
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
            // The bought stack carries the entry's stat roll (stock's trader
            // ItemStacks are created with `AddGSStats` at fill time): deposit
            // the whole value, not the stat-less triple.
            if (!w.inventory[ps].addSlotStacked(.{
                .item_id = item,
                .count = qty,
                .quality = en.quality,
                .stats = en.stats,
                .stats_n = en.stats_n,
            }, w.maxStack(item))) {
                w.inventory[ps] = inventory_before;
                return false;
            }
        }
        en.count -= qty;
        w.wallet[ps].coins -= cost;
        // Stock credits the trader's AvailableMoney with the sale (the
        // wire TraderData shows the live balance). Clamp at i32 max.
        stock.wallet = @intCast(@min(@as(i64, stock.wallet) + cost, std.math.maxInt(i32)));
        // No markup change on buy: stock's IncreaseMarkup/DecreaseMarkup run
        // only from the client vending-machine +/- UI actions
        // (ItemActionEntryMarkup/Markdown), never from buy/sell transactions.
        // NPC-trader buy price ignores entry markup entirely (GetBuyPrice
        // applies it only on the PlayerOwned/Rentable path); the markup the
        // client shows arrives via the TraderData echo zdtd already applies.
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
        // The sold item's own TraderQualityMod pair wins over the trader's
        // (stock's GetSellPrice lerps the item's pair when declared).
        var qmin = w.trader_quality_min_mod;
        var qmax = w.trader_quality_max_mod;
        if (w.item_quality_mod_fn) |f| {
            if (f(w.item_quality_mod_ctx, item)) |pair| {
                qmin = pair[0];
                qmax = pair[1];
            }
        }
        const qmod = qualityPriceMod(qmin, qmax, sold_quality);
        var scaled: f64 = @as(f64, @floatFromInt(unit)) * qmod;
        if (w.percent_uses_left_fn) |p| {
            scaled *= @as(f64, p(w.percent_uses_left_ctx, item, sold_quality, sold_use_times));
        }
        // Clamp before the cast: a hostile sell hook or modded quality_mod can
        // exceed u32 range (or go non-finite), which traps in @trunc;
        // fail closed at 1 instead of crashing the tick.
        if (!std.math.isFinite(scaled) or scaled <= 1.0) {
            unit = 1;
        } else {
            unit = @trunc(@min(scaled, @as(f64, std.math.maxInt(u32))));
        }
        // Barter perk (RE GetSellPrice IL=217): the seller gains
        // `unit + unit * BarteringSelling(149)`. Stock skips it when the
        // trader overrides the markdown; zdtd has no override surface, so it
        // always applies - noted in the GAP row.
        if (w.barter_sell_fn) |bf| {
            const scale = bf(w.barter_sell_ctx, player_peer);
            if (scale > 1) {
                const bonus_f: f64 = @as(f64, @floatFromInt(unit)) * @as(f64, scale - 1);
                const raised: f64 = @as(f64, @floatFromInt(unit)) + bonus_f;
                if (std.math.isFinite(raised)) {
                    unit = @intCast(@max(1, @min(@as(u64, @ceil(raised)), std.math.maxInt(u32))));
                }
            }
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
        }
        if (entry) |en| {
            en.count += qty;
            // No markup change on sell either (same note as the buy path
            // above): entry markup is vending-UI state, not a demand signal.
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
    for (query.groupSlice(w, .trader)) |i| {
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
            // Fresh entries rebuild at neutral markup (stock HandleFullReset
            // rebuilds the inventory, dropping the old markups).
            stock.entries[e].markup = 0;
        }
        // The money pool regenerates toward its spawn default each restock.
        stock.wallet = @max(stock.wallet, stock.wallet_default);
    }
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
