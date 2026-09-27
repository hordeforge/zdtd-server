//! ECS systems: pure functions over World SoA columns + resources.
//! Hot loops (zombie AI, turrets) run multi-threaded over disjoint slots.

const World = @import("world.zig").World;
const c = @import("components.zig");
const quest = @import("quest.zig");
const query = @import("query.zig");
const withinRadius = sensing.withinRadius;
const max_entities = @import("world.zig").max_entities;
const Slot = @import("world.zig").Slot;
const parallel = @import("../util/parallel.zig");

/// Fixed-point damage unit (1.0 hp = 100). zdtd-owned structural scale.
const dmg_scale: u32 = 100;

pub const sensing = @import("sensing.zig");
pub const lodScale = sensing.lodScale;
pub const TargetSnap = sensing.TargetSnap;
pub const PlayerSnap = sensing.PlayerSnap;
pub const PlayerScan = sensing.PlayerScan;
pub const max_players = sensing.max_players;
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
    if (take == 0) {
        w.noise_n = 0;
        return;
    }
    // The radius test is the same map for every event, so the group is packed
    // into x/z columns once and each event scans them eight lanes at a time.
    // Hits keep the group order the scalar walk produced, so the sleeper-wake
    // ring is drained in the same sequence.
    const group = query.groupSlice(w, .zombie);
    const gn = group.len;
    var gx: [max_entities]f32 = undefined;
    var gz: [max_entities]f32 = undefined;
    var hits: [max_entities]Slot = undefined;
    for (group, 0..) |s, i| {
        gx[i] = w.transform[s].x;
        gz[i] = w.transform[s].z;
    }
    var i: usize = 0;
    while (i < take) : (i += 1) {
        const ev = w.noise_events[i];
        const r2 = ev.radius * ev.radius;
        const hn = withinRadius(hits[0..], gx[0..gn], gz[0..gn], gn, ev.x, ev.z, r2);
        for (hits[0..hn]) |h| {
            const s = group[h];
            if (!w.alive[s] or !w.mask[s].zombie_ai or !w.mask[s].transform) continue;
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
