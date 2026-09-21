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


// T14 (WORK_PLAN): a configured Rules floor is a floor, never a replacement
// for per-entity stock data (ADR 0021 decision 5). These three tests set a
// Rules value and a conflicting entityclasses value and assert the loaded
// class table wins, exactly as the production resolve order does.

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
