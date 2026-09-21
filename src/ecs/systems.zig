//! ECS systems: pure functions over World SoA columns + resources.
//! Hot loops (zombie AI, turrets) run multi-threaded over disjoint slots.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("../protocol.zig");
const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const EntityClass = @import("world.zig").EntityClass;
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

/// Fixed-point damage unit (1.0 hp = 100). zdtd-owned structural scale.
const dmg_scale: u32 = 100;

pub const sensing = @import("sensing.zig");
pub const lodScale = sensing.lodScale;
pub const TargetSnap = sensing.TargetSnap;
pub const PlayerSnap = sensing.PlayerSnap;
pub const snapshotPlayers = sensing.snapshotPlayers;
pub const stealthLightAttackPercent = sensing.stealthLightAttackPercent;
pub const stealthLightPreBlend = sensing.stealthLightPreBlend;
pub const stealthLightLevel = sensing.stealthLightLevel;
pub const nearestPlayerSnap = sensing.nearestPlayerSnap;
pub const targetExternal = sensing.targetExternal;
pub const targetLive = sensing.targetLive;
pub const nearestBotSnap = sensing.nearestBotSnap;
pub const applyRevengeTarget = sensing.applyRevengeTarget;
pub const stepToward = sensing.stepToward;
const canSensePlayer = sensing.canSensePlayer;

pub const dig = @import("dig.zig");
pub const systemDigUpdate = dig.systemDigUpdate;

pub const damage_apply = @import("damage_apply.zig");
pub const applyGravity = damage_apply.applyGravity;
pub const fpDamage = damage_apply.fpDamage;
pub const applyDeferredDamage = damage_apply.applyDeferredDamage;

// Quest + trader systems live in quest_trade.zig (same functions, moved
// verbatim); the public names below re-export them so existing
// `systems.quest*` / `systems.trade` call sites keep working.
const quest_trade = @import("quest_trade.zig");
pub const PoiLockout = quest_trade.PoiLockout;
pub const questAccept = quest_trade.questAccept;
pub const questAcceptWithCode = quest_trade.questAcceptWithCode;
pub const questFindByCode = quest_trade.questFindByCode;
pub const questAcceptStarter = quest_trade.questAcceptStarter;
pub const questOnZombieKilled = quest_trade.questOnZombieKilled;
pub const questOnTraderOpen = quest_trade.questOnTraderOpen;
pub const questOnFetchItem = quest_trade.questOnFetchItem;
pub const questOnCraft = quest_trade.questOnCraft;
pub const questCheckPoiLockout = quest_trade.questCheckPoiLockout;
pub const questPoiLock = quest_trade.questPoiLock;
pub const questPoiUnlock = quest_trade.questPoiUnlock;
pub const questOnRallyActivated = quest_trade.questOnRallyActivated;
pub const questTickStayWithin = quest_trade.questTickStayWithin;
pub const questTickGoto = quest_trade.questTickGoto;
pub const questCoins = quest_trade.questCoins;
pub const drainQuestCoins = quest_trade.drainQuestCoins;
pub const questHasActive = quest_trade.questHasActive;
pub const questFindActive = quest_trade.questFindActive;
pub const collectLootNear = quest_trade.collectLootNear;
pub const qualityPriceMod = quest_trade.qualityPriceMod;
pub const clampDukesUnitPrice = quest_trade.clampDukesUnitPrice;
pub const trade = quest_trade.trade;
pub const traderRestock = quest_trade.traderRestock;
pub const questObjectiveEvent = quest_trade.questObjectiveEvent;


pub const ai_tasks = @import("ai_tasks.zig");
const stealth = @import("stealth.zig");
pub const systemZombieAi = ai_tasks.systemZombieAi;
const taskById = ai_tasks.taskById;
const senseDistSq = ai_tasks.senseDistSq;
const seekYawStep = ai_tasks.seekYawStep;
const decrementIfPositive = ai_tasks.decrementIfPositive;
const wanderUpdate = ai_tasks.wanderUpdate;
pub const systemStealth = stealth.systemStealth;

/// Group-AI consume pass (stock NotifyNoise, entity-ai.md): combat-noise
/// events alert zombies within radius (they investigate the spot) and wake
/// sleepers. Runs single-threaded after the parallel AI join; events were
/// pushed atomically during the pass (parallel workers + the net thread).
/// The ring is drained here - NOT beginTick - because direct system calls
/// (tests) and the net-poll-then-sim ordering both rely on consume-owns-drain.
pub fn consumeCombatNoise(w: *World) void {
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

pub const falling = @import("falling.zig");
pub const systemFallingBlocks = falling.systemFallingBlocks;

pub const systemVehicles = vehicle.systemVehicles;
pub const vehicle = @import("vehicle.zig");
pub const vehicleKindDefaultSpeed = vehicle.vehicleKindDefaultSpeed;
pub const vehicleControl = vehicle.vehicleControl;
pub const vehicleTickHeld = vehicle.vehicleTickHeld;
pub const vehicleFindSeat = vehicle.vehicleFindSeat;
pub const vehicleOfRider = vehicle.vehicleOfRider;
pub const vehicleAttach = vehicle.vehicleAttach;
pub const Dismount = vehicle.Dismount;
pub const vehicleDetach = vehicle.vehicleDetach;
pub const seat_any: i16 = vehicle.seat_any;
const vehicleStop = vehicle.vehicleStop;

pub const turrets = @import("turrets.zig");
pub const TurretTick = turrets.TurretTick;
pub const systemTurrets = turrets.systemTurrets;
const recordTurretOwner = turrets.recordTurretOwner;
const turretOwner = turrets.turretOwner;

pub const despawn = @import("despawn.zig");
pub const systemDespawnFar = despawn.systemDespawnFar;

pub const buff_tick = @import("buff_tick.zig");
pub const systemBuffs = buff_tick.systemBuffs;


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
    questTickGoto(&w, 0, 10, 10);
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
    questTickGoto(&w, 0, 0, 0);
    try std.testing.expect(questHasActive(&w, 0, 40));
    // Arriving at the POI center completes the goto quest.
    questTickGoto(&w, 0, 120, 220);
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
    questTickGoto(&w, 0, 10, -1);
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
    questTickGoto(&w, 0, 32, 32);
    try std.testing.expectEqual(@as(u8, 1), s.phase);
    // The def spot advances phase 1 -> phase 2 (ready to turn in).
    questTickGoto(&w, 0, 0, 0);
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

test "questObjectiveEvent redelivery does not re-finish a completed phase" {
    // Client NetPackageQuestObjectiveUpdate can arrive twice for the same
    // activation; the second must not re-run finishPhaseGraph / completeQuest.
    const phases = [_]quest.PhaseSpec{
        .{ .kind = .block_activate, .required = 1 },
    };
    const defs = [_]quest.QuestDef{.{
        .id = 55,
        .kind = .block_activate,
        .title = "Activate",
        .target_count = 1,
        .reward_coin = 10,
        .phases = &phases,
        .highest_phase = 1,
        .turn_in = true,
    }};
    var w: World = .{};
    defer w.deinit();
    w.catalog = .{ .defs = &defs, .starter_id = 55, .source = .builtin };
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(questAccept(&w, 0, 55));
    const s = questFindActive(&w, 0, 55).?;
    try std.testing.expectEqual(@as(u8, 1), s.phase);
    try std.testing.expect(questObjectiveEvent(&w, 0, s.quest_code, .block_activate));
    try std.testing.expect(s.ready_turn_in);
    try std.testing.expectEqual(@as(u16, 1), s.progress);
    // Redelivery: progress already met required, so bumpPhase returns without
    // touching the ring or re-entering finishPhaseGraph.
    const completed_before = w.completed_quests_n;
    try std.testing.expect(questObjectiveEvent(&w, 0, s.quest_code, .block_activate));
    try std.testing.expectEqual(completed_before, w.completed_quests_n);
    try std.testing.expect(s.ready_turn_in);
    try std.testing.expectEqual(@as(u16, 1), s.progress);
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

test "trade leaves entry markup alone; restock resets" {
    // Stock's IncreaseMarkup/DecreaseMarkup run only from the client
    // vending-machine +/- UI actions (ItemActionEntryMarkup/Markdown), never
    // from buy/sell transactions - and NPC-trader buy price ignores entry
    // markup (GetBuyPrice applies it only on the PlayerOwned/Rentable path).
    // So neither side of a trade may move the entry's markup.
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
    // A buy leaves markup at neutral.
    try std.testing.expect(trade(&w, 0, trader_id, item, 1, 0, 6));
    try std.testing.expectEqual(@as(i8, 0), w.trader_stock[ts].entries[0].markup);
    // A sell leaves markup at neutral too.
    try std.testing.expect(trade(&w, 0, trader_id, item, 1, 1, 6));
    try std.testing.expectEqual(@as(i8, 0), w.trader_stock[ts].entries[0].markup);
    // A restock rebuilds fresh entries: markup back to neutral.
    traderRestock(&w);
    try std.testing.expectEqual(@as(i8, 0), w.trader_stock[ts].entries[0].markup);
}

test "clampDukesUnitPrice fails closed on Inf and saturates past u16" {
    // EconomicValue="inf" / 1e20 previously trapped @as(u64, @trunc(...))
    // before the 65535 min; clamp in float space first.
    try std.testing.expectEqual(@as(u16, 5), clampDukesUnitPrice(std.math.inf(f64), 5));
    try std.testing.expectEqual(@as(u16, 5), clampDukesUnitPrice(std.math.nan(f64), 5));
    try std.testing.expectEqual(@as(u16, 5), clampDukesUnitPrice(-3.0, 5));
    try std.testing.expectEqual(@as(u16, 5), clampDukesUnitPrice(0.0, 5));
    try std.testing.expectEqual(@as(u16, 65535), clampDukesUnitPrice(1e20, 5));
    try std.testing.expectEqual(@as(u16, 42), clampDukesUnitPrice(42.9, 5));
}

test "trade applies barter hook scales to buy cost and sell gain" {
    // Hooked scales stand in for a perked buyer/seller: 0.9x buy, 1.1x sell.
    // Entry price is edited to 20 so the discount is visible above the
    // unit-1 floor: ceil(20*0.9)=18 buys, ceil(20*1.1)=22 sells.
    const S = struct {
        fn buy(_: ?*anyopaque, _: usize) f32 {
            return 0.9;
        }
        fn sell(_: ?*anyopaque, _: usize) f32 {
            return 1.1;
        }
    };
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    const trader_id = w.spawnTrader("Trader", 1, 70, 1, 0, 500).?;
    const ps = w.playerByPeer(0).?;
    const ts = w.slotOfNetId(trader_id).?;
    const item = w.trader_stock[ts].entries[0].item;
    w.trader_stock[ts].entries[0].price = 20;
    w.trader_stock[ts].entries[0].sell = 20;
    w.wallet[ps].coins = 1000;
    // Unhooked (null hooks): full price. Buy 20, wallet 1000 -> 980.
    try std.testing.expect(trade(&w, 0, trader_id, item, 1, 0, 6));
    try std.testing.expectEqual(@as(u32, 980), w.wallet[ps].coins);
    // Hooked buy: 18, wallet 980 -> 962.
    w.barter_buy_fn = &S.buy;
    try std.testing.expect(trade(&w, 0, trader_id, item, 1, 0, 6));
    try std.testing.expectEqual(@as(u32, 962), w.wallet[ps].coins);
    // Hooked sell: gain 23, not 22 - f32 arithmetic like stock's: 0.1f32 is
    // 0.10000000149, so 20 + 20*0.1f32 = 22.00000003 and CeilToInt gives 23.
    // Stock computes the same way (GetSellPrice IL=217), so the +1 rides
    // along rather than being rounded away.
    w.inventory[ps].slots[0] = .{ .item_id = item, .count = 5, .quality = 1 };
    w.barter_sell_fn = &S.sell;
    const before = w.wallet[ps].coins;
    try std.testing.expect(trade(&w, 0, trader_id, item, 1, 1, 6));
    try std.testing.expectEqual(before + 23, w.wallet[ps].coins);
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

test "falling blocks: two groups landing the same tick both destroy" {
    // destroy() shifts the live kind group; iterating the slice would skip
    // the second faller. copyKindInto keeps both in this tick's pass.
    var w: World = .{ .rules = .{ .ai = .{ .gravity = -1.6 } } };
    defer w.deinit();
    const Ground = struct {
        fn solid(_: ?*anyopaque, _: i32, y: i32, _: i32) bool {
            return y <= 70;
        }
    };
    w.solid_fn = &Ground.solid;
    const a = w.spawnFallingBlocks(&.{.{ .x = 5, .y = 71, .z = 5, .raw = 700 }}).?;
    const b = w.spawnFallingBlocks(&.{.{ .x = 8, .y = 71, .z = 8, .raw = 701 }}).?;
    systemFallingBlocks(&w, 0.05);
    try std.testing.expect(w.slotOfNetId(a) == null);
    try std.testing.expect(w.slotOfNetId(b) == null);
    try std.testing.expectEqual(@as(u32, 0), w.countKind(.falling_block));
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
    // the player's spot, same tick - stealth runs before the AI pass).
    var w: World = .{ .rules = .{ .ai = .{ .sense_dist_sq = 4 * 4 } } };
    defer w.deinit();
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    const z = w.spawnZombie(10, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    try std.testing.expect(!w.zombie_ai[zs].alert);
    // pipe_pistol_fire (stock V3.1.4): volume 62, 2 s = 40 ticks, muffle 0.8.
    w.pushStealthNoise(ps, 0, 70, 0, 62, 40, 0.8, 0);
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
    w.pushStealthNoise(ps, 0, 70, 0, 5, 20, 0.507, 0);
    systemStealth(&w);
    const standing = w.stealth[ps].noise_volume;
    // The entry itself is unfolded (5); the muffle scales the fold.
    try std.testing.expectApproxEqAbs(@as(f32, 5), w.stealth[ps].noises[0].volume, 0.001);
    w.stealth[ps] = .{};
    w.player[ps].crouching = true;
    w.pushStealthNoise(ps, 0, 70, 0, 5, 20, 0.507, 0);
    systemStealth(&w);
    const crouched = w.stealth[ps].noise_volume;
    try std.testing.expect(crouched < standing);
    // Entry volume carries the muffle: 5 x 0.507.
    try std.testing.expectApproxEqAbs(@as(f32, 5 * 0.507), w.stealth[ps].noises[0].volume, 0.001);
}

test "stealth light: pre-blend feeds the _lightlevel cvar" {
    // RE PlayerStealth TickServer IL_0078-00B9: ambient + held-light blend
    // (ratio clamped 0.5..3.2), crouch x0.6, then `_lightlevel = light x 100`
    // before the speed scale and passive blend.
    try std.testing.expectApproxEqAbs(@as(f32, 0), stealthLightPreBlend(0, 0, false), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), stealthLightPreBlend(0, 0, true), 0.0001);
    // Torch .35 on dark 0.05: ratio .35/.1 = 3.5 -> clamped 3.2.
    try std.testing.expectApproxEqAbs(@as(f32, 0.05 + 0.35 * 3.2), stealthLightPreBlend(0.05, 0.35, false), 0.0001);
    // Crouch x0.6 on the blended value.
    try std.testing.expectApproxEqAbs(@as(f32, (0.5 + 0.0) * 0.6), stealthLightPreBlend(0.5, 0, true), 0.0001);
    // The full level still matches the old inline math at passive 1.
    try std.testing.expectApproxEqAbs(stealthLightLevel(0.5, 0, false, 1.0, 0), (0.32 + 0.68) * 0.5 * 100.0, 0.001);
}

test "stealth noise: cached NoiseMultiplier scales both volumes" {
    // RE PlayerStealth CalcVolume/NotifyNoise: each multiplies by GetValue(88
    // NoiseMultiplier). The survival tick caches the buff/perk/item fold in
    // stealth_noise_mult; the legs read the column, defaulting to the neutral
    // base 1.0 offline.
    var w: World = .{};
    defer w.deinit();
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    // Volume 20 >= the loud threshold (11), so the decay window pauses and the
    // accumulated posts are exact on both runs (CalcVolume never decays).
    w.pushStealthNoise(ps, 0, 70, 0, 20, 20, 1.0, 0);
    systemStealth(&w);
    const base_vol = w.stealth[ps].noise_volume;
    const base_sleep = w.stealth[ps].sleeper_noise_volume;
    try std.testing.expect(base_vol > 0);
    try std.testing.expect(base_sleep > 0);
    w.stealth[ps] = .{};
    w.stealth_noise_mult[ps] = 0.5;
    w.pushStealthNoise(ps, 0, 70, 0, 20, 20, 1.0, 0);
    systemStealth(&w);
    try std.testing.expectApproxEqAbs(base_vol * 0.5, w.stealth[ps].noise_volume, 0.001);
    try std.testing.expectApproxEqAbs(base_sleep * 0.5, w.stealth[ps].sleeper_noise_volume, 0.001);
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
    w.pushStealthNoise(ps, 0, 70, 0, 120, 80, 1.0, 0);
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
    w.pushStealthNoise(ps, 0, 70, 0, 3, 20, 1.0, 0);
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
    // stepbush (V3.1.4): volume 11 - radius 6.6 covers 5 m, heard ~ 7 >= 1.
    w.pushStealthNoise(ps, 0, 70, 0, 11, 60, 0.507, 0);
    systemStealth(&w);
    try std.testing.expect(w.sleeper[zs].awake);
    try std.testing.expectEqual(@as(usize, 1), w.sleeper_wake_n);
    try std.testing.expectEqual(zs, w.sleeper_wake_reqs[0].slot);
}

test "stealth noise: heat rows feed the activity map" {
    // RE AIDirector.NotifyNoise: heat_map_strength > 0 adds activity to the
    // heat map for the region, held for the fixed 240 s window NotifyNoise
    // passes (the row's heat_map_time is not read by stock at all).
    var w: World = .{};
    defer w.deinit();
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    // Auger_Fire_Start (V3.1.4): volume 60, 2 s, heat 1.0.
    w.pushStealthNoise(ps, 0, 70, 0, 60, 40, 1.0, 1.0);
    systemStealth(&w);
    try std.testing.expectEqual(@as(usize, 1), w.director.heat_n);
    // notifyActivity: activity = value, decay = value / (duration_ticks / 20)
    // per second - 240 s = 4800 ticks → 1.0 / 240 s.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), w.director.heat[0].activity, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 240.0), w.director.heat[0].decay, 0.0001);
}
