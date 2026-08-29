//! All sim component types (plain data; no behavior). SoA columns live on World.

const std = @import("std");

pub const Kind = enum(u8) {
    player,
    zombie,
    trader,
    vehicle,
    turret,
    loot_bag,
    animal,
    /// Stability-collapse group entity (RE entity-ai.md LetBlocksFall):
    /// carries the fallen cells as one EntityFallingBlock, falls under
    /// gravity, dies on landing (no re-placement).
    falling_block,
};

pub const Transform = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    yaw: f32 = 0,
};

/// Stock item quality tiers: 1..6 (ItemValue.Quality; items.md). Armor
/// resist curves scale their first/last value to Q1/Q6.
pub const max_quality_tiers: u8 = 6;

pub const Health = struct {
    hp: f32 = 0,
    max_hp: f32 = 0,
    /// The spawn max (players 100, class-resolved otherwise): the passive-
    /// effects VM recomputes `max_hp = base_max_hp + deltas` revertibly
    /// every survival tick, so removing a perk/buff restores the base.
    base_max_hp: f32 = 0,
    /// PlayerEntityStats Food/Water (0..max). Zombies leave at 0.
    food: f32 = 0,
    food_max: f32 = 100,
    water: f32 = 0,
    water_max: f32 = 100,
    /// PlayerEntityStats Stamina (0..max); drained by sprinting, regens idle.
    stamina: f32 = 100,
    stamina_max: f32 = 100,
    /// Corpse dwell seconds left (TimeStayAfterDeath: 30 zombies, 300 animals).
    /// > 0 means dead-but-in-world: the corpse stays replicated until the sweep
    /// destroys it, so the client's ragdoll is not yanked mid-animation.
    corpse_seconds: f32 = 0,
};

pub const NetworkId = struct {
    id: i32 = 0,
    /// Slot reincarnation counter (generation-counted handle helper).
    gen: u32 = 0,
};

pub const Player = struct {
    peer_slot: i32 = -1,
    /// Stock EntityPlayer.IsBloodMoonDead: set when the player dies during an
    /// active blood moon, cleared on respawn. Horde zombies skip these players
    /// as targets (EAISetNearestEntityAsTarget), so they hunt the living.
    is_blood_moon_dead: bool = false,
    /// Stock `EntityPlayer.Crouching` (EntityFlags bit 512): muffles the
    /// player's movement noise for the AI hearing gate and shrinks sleeper
    /// attack-detect (RE entity-ai.md PlayerStealth).
    crouching: bool = false,
    /// Glide flag (ADR 0037 parachute): while `glide_until_tick > world tick`
    /// the movement envelope allows a sustained fall up to
    /// `[authority] glide_vy_cap_mps`. Set by the `glide` plugin verb;
    /// `glide_src` is the issuing plugin (paper 3.1 attribution) so a
    /// withdrawn module's applied glide is cleared.
    glide_until_tick: u64 = 0,
    glide_src: i16 = 0,
};

pub const ClassId = struct {
    /// Index into World.class_table (fallback only when the per-entity stat
    /// fields below are 0).
    id: u16 = 0,
    /// Unity Mono name hash for ECD EntitySpawn (0 = use table/default).
    hash: i32 = 0,
    /// Loot container name (LootDropEntityClass / LootListOnDeath); empty → fill path default.
    /// Must point to static/indefinite-lifetime data (comptime literal or
    /// binary-embedded table). Never assign an arena/allocator-owned slice.
    loot_list: []const u8 = "",
    /// LootDropProb chance a death drops the bag; 1.0 default.
    drop_prob: f32 = 1.0,
    /// TimeStayAfterDeath seconds the corpse lingers (30 zombies, 300 animals).
    time_stay: f32 = 0,
    /// Resolved per-entity class stats (XML chase/wander/damage). 0 = fall
    /// back to class_table[id] then the Rules floor, so a class that was not
    /// preloaded into the 16-slot table still behaves like itself.
    chase_speed: f32 = 0,
    /// MoveSpeedAggro min (day chase; stock GetMoveSpeedAggro day branch).
    /// 0 = class_table then the Rules floor.
    chase_speed_day: f32 = 0,
    wander_speed: f32 = 0,
    /// MoveSpeedNight (night shamble; stock GetMoveSpeed dark branch).
    /// 0 = falls to wander_speed then the floor.
    wander_speed_night: f32 = 0,
    /// entityclasses MoveSpeedRand "min,max" roll range; 0,0 = no roll.
    move_speed_rand_min: f32 = 0,
    move_speed_rand_max: f32 = 0,
    attack_damage: f32 = 0,
    /// HandItem DamageBlock from items.xml (per-class block chew: zombie 8,
    /// feral 24); 0 = class_table[id] then the Rules chew floor.
    block_chew: f32 = 0,
    /// HandItem melee reach (items.xml Range/MaxRange: zombie hand 1.6,
    /// club/axe 2.4); 0 = class_table[id] then the Rules attack-range floor.
    melee_range: f32 = 0,
    /// entityclasses SightRange in metres; 0 = class_table[id] then the Rules
    /// sense floor (systems.senseDistSq).
    sight_range: f32 = 0,
    /// entityclasses SightLightThreshold "min,max" (stock "-2,150" on the
    /// zombie template; cctor default 30/100). 0,0 = class_table[id] then the
    /// Rules floor (systems.sightLightThreshold).
    sight_light_min: f32 = 0,
    sight_light_max: f32 = 0,
    /// entityclasses SleeperSightToWakeMin/Max "min,max" roll ranges
    /// (stock zombieTemplateMale "-40,5" / "340,480"): each sleeping zombie
    /// rolls its wake threshold pair from these at spawn. 0 = unset (falls to
    /// the stock default ranges in world.spawnSleeperDef).
    sleeper_wake_near_min: f32 = 0,
    sleeper_wake_near_max: f32 = 0,
    sleeper_wake_far_min: f32 = 0,
    sleeper_wake_far_max: f32 = 0,
    /// entityclasses MaxViewAngle in degrees, full cone; 0 = class_table[id]
    /// then the Rules cone floor (systems.viewHalfDeg).
    view_angle_deg: f32 = 0,
    /// Demolition (RE entity-ai.md): prime threshold (0 = no explosion) and
    /// explode delay seconds; 0 = class_table[id].
    explode_threshold: f32 = 0,
    explode_delay_s: f32 = 0,
    /// <property class="Explosion"> blast params (radius/damages) and the
    /// DamageBonus material multipliers; 0 / empty = class_table[id], then
    /// the Rules floor (drainExplosions reads these so a cop spawned through
    /// spawnZombieDef - whose class_table index stays the kind default -
    /// still blasts with its own ExplosionData).
    explosion_radius: f32 = 0,
    explosion_radius_e: f32 = 0,
    explosion_block_dmg: f32 = 0,
    explosion_entity_dmg: f32 = 0,
    explosion_bonus_cat: [4][]const u8 = .{ "", "", "", "" },
    explosion_bonus_mult: [4]f32 = .{ 1, 1, 1, 1 },
    explosion_bonus_n: u8 = 0,
    /// IsEnemyEntity: false on passive wildlife, so only predators chase.
    is_enemy: bool = true,
    /// Inherited AITask-* list contains an attack task (ApproachAndAttackTarget
    /// in V3.1.0 b14): timid animals (stag/doe/rabbit/chicken/pig) carry
    /// RunawayWhenHurt/RunawayFromEntity/Look/Wander only and never attack;
    /// predators and zombies carry the attack task. Defaults true so classes
    /// without a task list keep the zombie-brain behavior.
    ai_attack: bool = true,
    /// entityclasses ExperienceGain kill XP; 0 = fall back to class_table[id]
    /// then the caller's flat floor.
    xp_gain: f32 = 0,
};

pub const AiState = enum(u8) {
    idle,
    wander,
    chase,
    attack,
    alert,
    sleep,
};

/// Currently-executing EAITask (stock EAITaskList.executingTasks collapsed to a
/// single cell). Mutex-conflicting movement tasks share one slot; BreakBlock /
/// DestroyArea use mutex 0 so they can preempt approach when path_blocked.
/// See zombie_tasks.
pub const TaskId = enum(u8) {
    none,
    break_block,
    destroy_area,
    approach_attack,
    territorial,
    /// EAIApproachDistraction (asm.il:423700, MutexBits 3): walk to the dropped
    /// EntityItem that tickDistraction registered as pendingDistraction. Sits
    /// between Territorial and ApproachSpot in the stock zombie AITask list
    /// (entityclasses.xml:562-571), behind ApproachAndAttackTarget.
    approach_distraction,
    approach_spot,
    /// EAIRunawayWhenHurt (asm.il:435616). Passive animals flee the entity that
    /// hurt them; not in the zombie AITask list, so it is gated on kind.animal.
    runaway,
    /// EAILook (asm.il:429858). Stand still and turn body yaw for the seconds
    /// Wander/ApproachSpot Reset() owed. Sits between ApproachSpot and Wander
    /// exactly as in the stock zombie AITask list (entityclasses.xml:562-571).
    look,
    wander,
};

/// Waypoints buffered from one A* solve. Eight cells is roughly the distance a
/// chasing zombie covers in one replan interval, so the buffer empties about
/// when the cooldown expires.
pub const path_wp_max: usize = 8;

/// One planned cell: world block XZ plus the feet Y the body stands at there.
pub const PathWp = struct { x: i32 = 0, z: i32 = 0, y: i16 = 0 };

/// EAISetAsTargetIfHurt::Start passes 400 ticks to SetAttackTarget
/// (asm.il:436155, ldc.i4 0x190), i.e. 20 s at the stock 20 Hz AI tick.
/// Read via w.rules.ai.revenge_window_s (mode/zdtd.toml overlay); the
/// knockback impulse (rules.combat.knockback_speed / knockback_seconds) also
/// lives on the rules surface.
pub const ZombieAi = struct {
    state: AiState = .idle,
    target_id: i32 = -1,
    /// spawning.xml rule index that spawned this zombie (0xffff = none), for
    /// the ambient per-rule budget release on destroy (aidirector.releaseRule).
    spawn_rule: u16 = 0xffff,
    /// Stock EAITaskEntry.executeTime: per-task re-evaluation timer.
    decision_cd: f32 = 0,
    /// Winning task from the last selection pass (EAITaskList executing set).
    active_task: TaskId = .none,
    attack_cd: f32 = 0,
    wander_tx: f32 = 0,
    wander_tz: f32 = 0,
    /// Director/AI Investigate-style spot (EAIApproachSpot). Cleared on arrive.
    spot_x: f32 = 0,
    spot_z: f32 = 0,
    has_spot: bool = false,
    /// EAITerritorial home (spawn pos). When has_home and far, walk back.
    home_x: f32 = 0,
    home_z: f32 = 0,
    has_home: bool = false,
    alert: bool = false,
    /// Blood-moon horde zombie (stock EntityAlive.IsHordeZombie): teleported
    /// back to the party focus when it drifts past cTeleportDist, cleared at dawn.
    is_horde: bool = false,
    /// EAIRunawayFromEntity fear source (AITask-2): the nearest feared entity
    /// (player / zombie / other animal) within fleeDistance, refreshed on a
    /// 0.5 s cadence for passive animals. -1 = no fear.
    fear_target: i32 = -1,
    fear_cd: f32 = 0,
    active_scale: f32 = 1,
    /// Cooldown after a MoveHelper-style jump (stock jumpDelay); prevents
    /// bunny-hop against a sealed wall.
    jump_cd: f32 = 0,
    /// True while the jump arc is rising (stock JumpState moving): the ground
    /// snap is suppressed so the impulse is not zeroed on its own tick; the
    /// flag clears at the apex (vy < 0) and the fall lands normally.
    jumping: bool = false,
    /// MoveHelper dig state (RE entity-ai.md DigStart/DigUpdate): a fully
    /// blocked, grounded, non-jumping AI digs the block in its move direction.
    /// dig_for_ticks is the remaining dig budget (DigStop at 0), dig_ticks the
    /// windup/attack cadence (stock: 18 windup, then damage every 18 ticks).
    digging: bool = false,
    dig_x: i32 = 0,
    dig_y: i32 = 0,
    dig_z: i32 = 0,
    dig_for_ticks: u8 = 0,
    dig_ticks: u8 = 0,
    path_goal_x: f32 = 0,
    path_goal_z: f32 = 0,
    has_path: bool = false,
    /// Seconds until next A* replan (chase only).
    path_replan_cd: f32 = 0,
    /// Cells of the last solve not yet walked. One search feeds up to
    /// path_wp_max steps, so a chase pays one A* per ~8 m of travel instead of
    /// per metre, and a tick refused by the node budget still has somewhere to
    /// walk.
    path_wp: [path_wp_max]PathWp = [_]PathWp{.{}} ** path_wp_max,
    path_wp_n: u8 = 0,
    path_wp_i: u8 = 0,
    /// Goal cell the buffer was planned for; a goal that moves off it forces a
    /// replan even mid-buffer.
    path_goal_cx: i32 = 0,
    path_goal_cz: i32 = 0,
    /// True when chase replan found no detour and the cell toward the goal is solid.
    /// Feeds EAIBreakBlock / DestroyArea; Game.tickZombieBlockDamage keys on chase/attack.
    path_blocked: bool = false,
    /// Per-entity xorshift state for wander decisions (0 = unseeded; first
    /// decision seeds from net id so streams differ per entity).
    wander_rng: u32 = 0,
    /// EAIManager.lookTime (asm.il:429886): seconds of look-around owed, seeded
    /// by EAIWander::Reset (asm.il:438383) and EAIApproachSpot::Reset (:424395).
    look_time: f32 = 0,
    /// EAILook.waitTicks / 20 (asm.il:429903): seconds left in the active look.
    look_wait: f32 = 0,
    /// EAILook.turnTicks / 20 (asm.il:429984): seconds until the next yaw pick.
    look_turn_cd: f32 = 0,
    /// Entity::SeekYaw target angle in degrees (asm.il:429995).
    look_yaw: f32 = 0,
    /// EAIWander.time (asm.il:438366): seconds the current wander has run.
    wander_time: f32 = 0,
    /// Vertical velocity (blocks/s) for gravity integration (RE
    /// entity-movement.md): the body falls under gravity when its feet cell is
    /// air, and lands on the first solid cell below. 0 when grounded.
    vy: f32 = 0,
    /// Demolition (zombieCop) prime state (RE entity-ai.md EntityZombieCop):
    /// primed when health drops below max*explode_threshold; the two
    /// countdowns then explode (a request ring drains the Game's AoE).
    primed: bool = false,
    prime_ticks: i32 = 0,
    explode_ticks: i32 = 0,
    /// EntityAlive.revengeTarget net id (-1 = none), set by World.damageFrom.
    /// EAISetAsTargetIfHurt (asm.il:435831) promotes it to the attack target.
    revenge_target: i32 = -1,
    /// Seconds the revenge target stays valid. Stock's SetAttackTarget window
    /// is 400 ticks (asm.il:436155 ldc.i4 0x190) = 20 s at 20 Hz.
    revenge_time: f32 = 0,
    /// Hit knockback (melee/gun hits): remaining seconds of displacement plus
    /// the unit push direction. Applied before the AI move each tick, so the
    /// shove wins the tick and the AI re-approaches from the pushed spot.
    /// Set by World.damageFrom on zombie/animal hits; the Game broadcasts the
    /// matching NetPackageEntityVelocity so the client animates the stagger.
    kb_time: f32 = 0,
    kb_dx: f32 = 0,
    kb_dz: f32 = 0,
    /// EntityAlive.pendingDistraction: the nearest dropped EntityItem that
    /// broadcast itself into this entity's 25 m (distractionRadius) window
    /// (EntityItem.tickDistraction). Net id of the loot-bag entity, -1 = none.
    pending_distraction: i32 = -1,
    /// EntityAlive.pendingDistractionDistanceSq (tickDistraction only replaces
    /// a closer item).
    pending_distraction_dsq: f32 = 0,
    /// EntityAlive.distraction: the item the winning EAIApproachDistraction
    /// task is walking to / eating (EAIApproachDistraction.Start, asm.il:423700).
    /// Net id of the loot-bag entity, -1 = none.
    distraction: i32 = -1,
    /// EntityAlive.IsEating (EAIApproachDistraction.Update sets it while within
    /// cCloseDist and the item is an eat distraction).
    is_eating: bool = false,

    /// Drop any buffered path (arrive, preempt, mover stop).
    pub fn clearPath(self: *ZombieAi) void {
        self.path_wp_n = 0;
        self.path_wp_i = 0;
    }

    /// Next unwalked waypoint, or null when the buffer is spent.
    pub fn currentWp(self: *const ZombieAi) ?PathWp {
        if (self.path_wp_i >= self.path_wp_n) return null;
        return self.path_wp[self.path_wp_i];
    }
};

/// Per-bot skill parameters, ported from the Q3 / Doom 3 / 7dtd-fps-bots skill model
/// (BotCharacter, BotAimAtEnemy, BotCheckAttack). The guest Wasm brain reads
/// these (via the sense view where relevant) and answers back with intent; the
/// host owns the bot. The `skill` 0..4 floor is a Rules value; per-bot
/// overrides (bot cfg) land here and win. Aesop: the host never decides *what*
/// to do, only whether the ask is legal.
pub const BotDef = struct {
    /// Display name (static/indefinite-lifetime slice; never an
    /// arena/allocator-owned slice).
    name: []const u8 = "Bot",
    /// Difficulty 0..4 (0 bot, 1 easy, 2 normal, 3 hard, 4 nightmare).
    skill: u8 = 2,
    /// Seconds before the bot reacts to a newly seen threat (Q3 reaction gate).
    reaction_s: f32 = 0.4,
    /// Vision cone: metres of detection range.
    vision_range: f32 = 40,
    /// Vision cone: full angle (degrees) centered on facing.
    vision_angle: f32 = 120,
    /// Seconds between fire decisions (Q3 firethrottle).
    fire_throttle_s: f32 = 0.3,
    /// Chance (0..1) to strafe while attacking.
    strafe_chance: f32 = 0.4,
    /// Chance (0..1) to dodge on being hit.
    dodge_chance: f32 = 0.3,
    /// Aggression / self-preservation (0..1), as in BotCharacter.
    aggression: f32 = 0.6,
    self_preservation: f32 = 0.5,
    /// The bot's current commanded/host-authorised target net id (-1 = none).
    /// The guest passes targets via bot_shoot; the host records the last legal
    /// one here so the sense view and admin listing can report it.
    target_id: i32 = -1,
};

/// Default BotDef used by BotManager.spawn (a Rules floor; per-bot overrides win).
pub const BotDefDefault = BotDef{};

/// Apply the Q3/Doom 3 skill preset (0 bot .. 4 nightmare) to a BotDef:
/// reaction shrinks, vision and dodge grow with skill. Mirrors the reference
/// Difficulty presets; does not touch aggression/self-preservation (left for
/// the addon). Called at spawn; `bot cfg` overrides fields directly after.
pub fn applySkillFloor(d: *BotDef) void {
    d.skill = @min(d.skill, 4);
    d.reaction_s = @max(0.08, 0.6 - 0.11 * @as(f32, @floatFromInt(d.skill)));
    d.vision_range = 25 + 8 * @as(f32, @floatFromInt(d.skill));
    d.dodge_chance = 0.2 + 0.11 * @as(f32, @floatFromInt(d.skill));
}

/// Placed-turret combat stats from the block (blocks.xml autoTurret family:
/// MaxDistance, EntityDamage, BurstFireRate, BurstRoundCount). Zero fields
/// stay unset - callers fall back to the component defaults. Pure shape
/// shared by the assets loader (assets→ecs allowed) and the world hook.
pub const TurretBlockStats = struct {
    max_distance: f32 = 0,
    entity_damage: f32 = 0,
    burst_fire_rate: f32 = 0,
    burst_rounds: u16 = 0,
};

pub const VehicleKind = enum(u8) {
    bicycle = 0,
    minibike = 1,
    motorcycle = 2,
    four_by_four = 3,
    gyrocopter = 4,
};

/// Stock ceiling: Truck4x4 declares seat0..seat5 in vehicles.xml, the widest
/// seat block any stock vehicle has (Vehicle::SetSeats, asm.il:1344168).
pub const max_seats: usize = 6;

/// Vehicle basket slot cap. Stock VehicleInventory is PUBLIC_SLOTS + 1
/// (10 + 1 = 11); the storage window cap in stock is 8 rows. Fixed array so
/// the C2S Bag blob parse has a hard bound (rule 20).
pub const max_basket_slots: usize = 8;

/// Seat 0 is the driver: EntityVehicle::AttachEntityToSelf sets hasDriver only
/// when the resolved slot is 0 (asm.il:542176 IL_008a).
pub const driver_seat: u8 = 0;

pub const Vehicle = struct {
    kind: VehicleKind = .minibike,
    speed: f32 = 0,
    fuel: f32 = 100,
    /// Rider net id per seat, -1 when free. Index is the wire slot carried by
    /// NetPackageEntityAttach (asm.il:844620).
    seats: [max_seats]i32 = [_]i32{-1} ** max_seats,
    /// Usable seats, always clamped to 1..max_seats on spawn.
    seat_count: u8 = 1,
    /// Vertical velocity accumulator for gravity integration (systemVehicles).
    vy: f32 = 0,
    /// Cap from vehicles.xml velocityMax; 0 → kind default in vehicleControl.
    max_speed: f32 = 0,
    /// Last drive input (held until exit or new op=2). Applied each sim tick.
    throttle: f32 = 0,
    steer: f32 = 0,
    /// Basket contents (RE NetPackageBag, research dedicated-misc-systems.md
    /// vehicle storage pin v2): the basket is Entity.bag, synced as a Bag blob.
    /// A packed fixed array, like the player inventory; empty slots hold id 0.
    basket: [max_basket_slots]InvSlot = [_]InvSlot{.{}} ** max_basket_slots,
    basket_n: u8 = 0,

    pub fn driverNetId(self: *const Vehicle) i32 {
        return self.seats[driver_seat];
    }

    /// Legal seat indices, guarded against a corrupt seat_count.
    pub fn usableSeats(self: *const Vehicle) u8 {
        return @max(1, @min(self.seat_count, @as(u8, max_seats)));
    }

    pub fn freeSeats(self: *const Vehicle) u8 {
        var n: u8 = 0;
        for (self.seats[0..self.usableSeats()]) |r| {
            if (r < 0) n += 1;
        }
        return n;
    }
};

/// zdtd sim defaults for the Turret component. Stock turret stats ship in
/// blocks.xml (autoTurret family: MaxDistance, EntityDamage, BurstFireRate,
/// BurstRoundCount); the Game hook (World.turret_stats_fn) overlays them at
/// spawn - these are the no-game-dir fallback only (rule 15).
pub const Turret = struct {
    range: f32 = 24,
    damage: f32 = 12,
    fire_cd: f32 = 0,
    fire_interval: f32 = 0.4,
    ammo: u16 = 200,
    target_id: i32 = -1,
    power_node: u16 = 0,
    /// Client slot that placed the turret; -1 = unowned (demo). Trap kills
    /// credit this owner with quest progress, XP and the kill counter.
    owner_slot: i16 = -1,
};

pub const max_journal: usize = 8;
/// Max flat objectives per quest (indexes QuestProgress.obj_progress; kept in
/// lockstep with quest.max_phases — a phase has at most one objective per
/// flat slot, and there are at most max_phases phases).
pub const max_quest_objectives: usize = 32;
/// Stock TraderInfo.MaxItems (50): the trader window holds up to 50 stacks.
pub const max_stock: usize = 50;
/// Toolbelt 0..9, bag 10..54, equipment 55..66 (armor slots), total 67 -
/// the full stock wire layout (toolbelt 10, bag 45, equip 12). The earlier
/// 32-bag subset (ADR 0007) dropped client bag slots 33..45 and equipment
/// 5..11 on the C2S apply, losing items on relog; resolved 2026-08-22.
pub const inv_toolbelt: usize = 10;
pub const inv_bag_start: usize = 10;
pub const inv_bag_count: usize = 45;
pub const inv_equip_start: usize = 55;
pub const inv_equip_count: usize = 12;
pub const max_inv_slots: usize = inv_equip_start + inv_equip_count; // 67
pub const inv_no_holding: u16 = 0xFFFF;

// Layout invariants: bag contiguous after toolbelt; equip starts after bag.
// Stock wire sizes live in wire/stock_inv.zig; must stay ≥ these ECS widths.
comptime {
    if (inv_bag_start != inv_toolbelt) @compileError("inv_bag_start must equal inv_toolbelt");
    if (inv_bag_start + inv_bag_count != inv_equip_start)
        @compileError("bag range must be contiguous before equip");
    if (max_inv_slots != inv_equip_start + inv_equip_count)
        @compileError("max_inv_slots must equal equip end");
}

/// POI footprint assigned to a quest, mirroring stock PrefabInstance
/// boundingBoxPosition/boundingBoxSize. Goes on the wire as the Quest
/// PositionData POIPosition/POISize pair; the client scans exactly this rect
/// for the "Rally" indexed block (ObjectiveRallyPoint.GetRallyPosition,
/// asm.il 973195-973344). A zero XZ size means "no POI resolved".
pub const PoiRect = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    size_x: f32 = 0,
    size_y: f32 = 0,
    size_z: f32 = 0,

    pub fn valid(self: PoiRect) bool {
        return self.size_x > 0 and self.size_z > 0;
    }

    /// Stock Rect.Contains: min inclusive, max exclusive.
    pub fn containsXZ(self: PoiRect, x: f32, z: f32) bool {
        return x >= self.x and x < self.x + self.size_x and
            z >= self.z and z < self.z + self.size_z;
    }
};

pub const QuestProgress = struct {
    def_id: u16 = 0,
    /// Stock Quest.QuestCode (distinct from catalog def_id when possible).
    quest_code: i32 = 0,
    active: bool = false,
    completed: bool = false,
    ready_turn_in: bool = false,
    /// Failed by a ForcePhaseFinish objective left incomplete (stock
    /// Quest.CloseQuest(Failed)): the slot stays visible to the client as a
    /// failed quest and is never re-offered while present.
    failed: bool = false,
    progress: u16 = 0,
    /// 1-based phase matching stock quest objective phase attributes.
    phase: u8 = 1,
    /// Per-flat-objective progress (index == flat objective order; only the
    /// XML-parsed quests with `def.objectives` use it — legacy defs use
    /// `progress`). Stock refreshQuestCompletion reads each objective's
    /// CurrentValue.
    obj_progress: [max_quest_objectives]u16 = [_]u16{0} ** max_quest_objectives,
    /// Stock Quest.RallyMarkerActivated (asm.il 989046): the marker block is
    /// spent for this quest and BlockRallyMarker stops offering activation.
    rally_activated: bool = false,
    /// POI this quest instance runs in; unset (zero size) for quests the server
    /// could not place, which keeps their rally objectives as scaffolding.
    poi: PoiRect = .{},
    /// Stock shared quest: the server shared this quest with the owner's party
    /// (ShareAllQuestsWithParty). Cleared/removed when the owner leaves the
    /// party or disconnects.
    is_shared: bool = false,
    /// Quest giver position (PositionDataTypes.QuestGiver=0): the trader/NPC
    /// that offered the quest, for the client's return-to-giver marker.
    /// Unset (0,0,0) for quests accepted without a giver (starter quests).
    giver_x: f32 = 0,
    giver_y: f32 = 0,
    giver_z: f32 = 0,
};

pub const Journal = struct {
    slots: [max_journal]QuestProgress = [_]QuestProgress{.{}} ** max_journal,

    pub fn findActive(self: *Journal, def_id: u16) ?*QuestProgress {
        for (&self.slots) |*s| {
            if (s.active and !s.completed and s.def_id == def_id) return s;
        }
        return null;
    }

    pub fn findFree(self: *Journal) ?*QuestProgress {
        for (&self.slots) |*s| {
            if (!s.active and !s.completed) return s;
        }
        for (&self.slots) |*s| {
            if (!s.active) return s;
        }
        return null;
    }

    pub fn hasActive(self: *const Journal, def_id: u16) bool {
        for (self.slots) |s| {
            if (s.active and !s.completed and s.def_id == def_id) return true;
        }
        return false;
    }

    /// True when the journal holds a failed entry for `def_id`: stock
    /// FindQuest matches any state, so a failed quest is neither re-offered
    /// nor re-accepted while its journal entry exists.
    pub fn hasFailed(self: *const Journal, def_id: u16) bool {
        for (self.slots) |s| {
            if (s.failed and s.def_id == def_id) return true;
        }
        return false;
    }

    pub fn anyActive(self: *const Journal) bool {
        for (self.slots) |s| {
            if (s.active and !s.completed) return true;
        }
        return false;
    }
};

pub const Wallet = struct {
    coins: u32 = 0,
};

pub const InvSlot = struct {
    item_id: u16 = 0,
    count: u16 = 0,
    quality: u8 = 0,
    meta: u16 = 0, // durability / flags
    /// Stock ItemValue.UseTimes (remaining uses; f32 on the wire). Tools wear
    /// down to 0 and stay present (broken) until repaired; persisted since
    /// players.zsv ZPV7.
    use_times: f32 = 0,
    /// Stock ItemValue.Seed (u16): the per-item random seed seed-items carry
    /// so the same planted seed grows the same way (meta is durability/flags,
    /// not the seed).
    seed: u16 = 0,
    /// Attached mod item ids (stock ItemValue.Modifications; 4 covers the
    /// stock slot counts). The mods' stat effects are client-side; the ids
    /// persist so a modded weapon survives a relog. 0 = empty slot.
    mods: [4]u16 = .{0} ** 4,
    /// Active mod count (<= mods.len).
    mod_n: u8 = 0,
};

/// Offline stack caps when `World.stack_fn` is null. Must match
/// `assets/items.builtin_defs` (stack 0 → 1). Production wires `stack_fn` from
/// items.xml Stacknumber; never invent parallel caps for production deposits.
pub fn maxStackOffline(item_id: u16) u16 {
    return switch (item_id) {
        0 => 1,
        1 => 60000,
        2 => 50,
        3 => 150,
        4 => 10,
        5 => 1,
        6 => 60000,
        7 => 60000,
        8 => 1,
        9 => 1,
        10 => 50,
        11 => 1,
        12 => 20,
        else => 60000,
    };
}

pub const Inventory = struct {
    slots: [max_inv_slots]InvSlot = [_]InvSlot{.{}} ** max_inv_slots,
    /// Held toolbelt index 0..inv_toolbelt-1, or inv_no_holding.
    holding: u16 = 0,
    /// Open container entity net id (-1 = none).
    open_container: i32 = -1,

    pub fn clear(self: *Inventory) void {
        self.* = .{};
    }

    pub fn heldItem(self: *const Inventory) InvSlot {
        if (self.holding >= inv_toolbelt) return .{};
        return self.slots[self.holding];
    }

    pub fn setHolding(self: *Inventory, slot: u16) bool {
        if (slot != inv_no_holding and slot >= inv_toolbelt) return false;
        if (slot != inv_no_holding and self.slots[slot].count == 0) {
            self.holding = inv_no_holding;
            return true;
        }
        self.holding = slot;
        return true;
    }

    /// Deposit with offline default cap only (no catalog). Prefer
    /// `World.depositItem` / `addItemStacked(..., World.maxStack)` when a World
    /// is available so items.xml Stacknumber is honored.
    pub fn addItem(self: *Inventory, item_id: u16, count: u16) bool {
        return self.addItemStacked(item_id, count, maxStackOffline(item_id));
    }

    /// Deposit with default quality=1 / meta=0 (admin give, craft output, loot fill).
    pub fn addItemStacked(self: *Inventory, item_id: u16, count: u16, max_stack: u16) bool {
        return self.addSlotStacked(.{ .item_id = item_id, .count = count, .quality = 1, .meta = 0 }, max_stack);
    }

    /// Deposit a full slot value. Only merges stacks with matching quality and meta.
    /// All-or-nothing: a partial deposit followed by `false` makes callers that
    /// refund on failure (container take/put, craft) duplicate items.
    pub fn addSlotStacked(self: *Inventory, item: InvSlot, max_stack: u16) bool {
        if (item.item_id == 0 or item.count == 0) return false;
        var room_total: u32 = 0;
        for (self.slots[0..inv_equip_start]) |s| {
            if (s.count == 0) {
                room_total += max_stack;
            } else if (s.item_id == item.item_id and s.quality == item.quality and s.meta == item.meta and s.count < max_stack) {
                room_total += max_stack - s.count;
            }
        }
        if (room_total < item.count) return false;
        var left = item.count;
        // stack into existing (toolbelt first, then bag)
        var i: usize = 0;
        while (i < inv_equip_start and left > 0) : (i += 1) {
            const s = &self.slots[i];
            if (s.item_id != item.item_id or s.quality != item.quality or s.meta != item.meta or s.count == 0) continue;
            const room: u16 = if (s.count >= max_stack) 0 else max_stack - s.count;
            if (room == 0) continue;
            const put: u16 = @min(room, left);
            s.count += put;
            left -= put;
        }
        // empty slots toolbelt then bag
        i = 0;
        while (i < inv_equip_start and left > 0) : (i += 1) {
            const s = &self.slots[i];
            if (s.item_id != 0 and s.count != 0) continue;
            const put: u16 = @min(max_stack, left);
            s.* = .{ .item_id = item.item_id, .count = put, .quality = item.quality, .meta = item.meta };
            left -= put;
        }
        return left == 0;
    }

    pub fn removeItem(self: *Inventory, item_id: u16, count: u16) bool {
        if (self.countItem(item_id) < count) return false;
        var left = count;
        // remove from bag end then toolbelt (consume bag first)
        var i: isize = @intCast(inv_equip_start - 1);
        while (i >= 0 and left > 0) : (i -= 1) {
            const s = &self.slots[@intCast(i)];
            if (s.item_id != item_id or s.count == 0) continue;
            const take: u16 = @min(s.count, left);
            s.count -= take;
            left -= take;
            if (s.count == 0) s.* = .{};
        }
        return left == 0;
    }

    pub fn countItem(self: *const Inventory, item_id: u16) u32 {
        var n: u32 = 0;
        for (self.slots[0..inv_equip_start]) |s| {
            if (s.item_id == item_id) n += s.count;
        }
        return n;
    }

    pub fn takeFromSlot(self: *Inventory, slot: u16, qty: u16) ?InvSlot {
        if (slot >= max_inv_slots or qty == 0) return null;
        const s = &self.slots[slot];
        if (s.count == 0 or s.item_id == 0 or s.count < qty) return null;
        const out = InvSlot{ .item_id = s.item_id, .count = qty, .quality = s.quality, .meta = s.meta };
        s.count -= qty;
        if (s.count == 0) s.* = .{};
        if (self.holding == slot and s.count == 0) self.holding = inv_no_holding;
        return out;
    }

    pub fn putInSlot(self: *Inventory, slot: u16, item: InvSlot, max_stack: u16) bool {
        if (slot >= max_inv_slots or item.item_id == 0 or item.count == 0) return false;
        const s = &self.slots[slot];
        if (s.count == 0 or s.item_id == 0) {
            if (item.count > max_stack) return false;
            s.* = item;
            return true;
        }
        // Same type only; quality/meta must match (tools, durability).
        if (s.item_id != item.item_id or s.quality != item.quality or s.meta != item.meta) return false;
        if (s.count >= max_stack or item.count > max_stack - s.count) return false;
        s.count += item.count;
        return true;
    }

    /// Swap or merge from→to. Returns false if illegal.
    pub fn moveSlot(self: *Inventory, from: u16, to: u16, qty: u16, max_stack: u16) bool {
        if (from == to or from >= max_inv_slots or to >= max_inv_slots) return false;
        const src = self.slots[from];
        if (src.count == 0) return false;
        const n = if (qty == 0 or qty > src.count) src.count else qty;
        const dst = self.slots[to];
        if (dst.count == 0 or dst.item_id == 0) {
            // place
            const taken = self.takeFromSlot(from, n) orelse return false;
            self.slots[to] = taken;
            if (self.holding == from and self.slots[from].count == 0) self.holding = inv_no_holding;
            return true;
        }
        // Merge only when quality and meta match (do not blend tool tiers/durability).
        if (dst.item_id == src.item_id and dst.quality == src.quality and dst.meta == src.meta) {
            const room: u16 = if (dst.count >= max_stack) 0 else max_stack - dst.count;
            if (room == 0) return false;
            const put: u16 = @min(room, n);
            _ = self.takeFromSlot(from, put) orelse return false;
            self.slots[to].count += put;
            return true;
        }
        // swap whole stacks only
        if (n != src.count) return false;
        self.slots[from] = dst;
        self.slots[to] = src;
        if (self.holding == from) self.holding = to else if (self.holding == to) self.holding = from;
        return true;
    }
};

pub const StockEntry = struct {
    item: u16 = 0,
    count: u16 = 0,
    /// Rolled ItemValue quality (traders.xml quality="lo,hi"); 1 for
    /// stackables without a quality range.
    quality: u8 = 1,
    price: u16 = 0,
    sell: u16 = 0,
    /// TraderData.Entry.Markup (sbyte demand delta). Stock raises it to +100 on
    /// a buy and steps it down by 4 on a sell (asm.il 856828-856866); the wire
    /// TraderData carries it so the client shows the demand arrows and (for
    /// player-owned/rentable machines) prices from 1 + Markup*0.2. Fresh stock
    /// and restocks reset it to 0.
    markup: i8 = 0,
};

fn defaultStock() [max_stock]StockEntry {
    return [_]StockEntry{
        .{ .item = 2, .count = 20, .price = 5, .sell = 2 },
        .{ .item = 3, .count = 50, .price = 3, .sell = 1 },
        .{ .item = 4, .count = 10, .price = 12, .sell = 4 },
        .{ .item = 5, .count = 3, .price = 40, .sell = 15 },
        .{ .item = 1, .count = 100, .price = 1, .sell = 1 },
    } ++ [_]StockEntry{.{}} ** (max_stock - 5);
}

pub const TraderStock = struct {
    /// Trader display name. Must point to static/indefinite-lifetime data
    /// (comptime literal or binary-embedded table). Never assign an
    /// arena/allocator-owned slice.
    name: []const u8 = "Trader",
    /// traders.xml `<trader_info>` id for this trader (0 = generic/default).
    trader_info_id: u16 = 0,
    /// Live AvailableMoney (stock debits it when buying from the player and
    /// credits it when selling to them; the wire TraderData shows this).
    wallet: i32 = 0,
    /// Restock target the wallet regrows toward (initial spawn amount).
    wallet_default: i32 = 0,
    /// traders.xml `<trader_info>` ResetInterval: -1 = never restock, 0 =
    /// daily (spawn default), >0 = days between restocks. The timer row
    /// (systems.traderRestock) owns the math.
    reset_interval: i32 = 0,
    /// Game day of the last restock; traderRestock skips a trader until
    /// day >= last_restock_day + reset_interval (0 interval always restocks).
    last_restock_day: u32 = 0,
    /// Edge latch for the open/close cycle (EntityTrader::OnUpdateLive):
    /// true = the area currently shows closed (gates locked, window denied).
    is_closed: bool = false,
    entries: [max_stock]StockEntry = defaultStock(),
    n: usize = 5,
};

pub const LootBag = struct {
    /// Simple loot: first inv slots.
    open: bool = false,
    /// EntityItem distraction state (RE EntityItem::SetupDistraction). Tags bit
    /// 1 = eat, 2 = requires_contact, 4 = zombie; 0 = plain loot bag, no
    /// attraction. `radius_sq` is DistractionRadius squared (stock compares
    /// against the squared value, asm.il EntityItem:1381-1385).
    distraction_tags: u8 = 0,
    distraction_radius_sq: f32 = 0,
    distraction_lifetime: i32 = 0,
    distraction_strength: f32 = 0,
    /// Stock EntityItem.distractionEatTicks: ticks an eating zombie chews the
    /// item before it dies (PassiveEffects 69; stock decoy = 0, no eating).
    distraction_eat_ticks: i32 = 0,
    /// Stock EntityItem.nextDistractionTick: 20-tick broadcast cadence
    /// (tickDistraction, asm.il EntityItem:1341-1349).
    next_distraction_tick: i32 = 0,
};

pub const Sleeper = struct {
    awake: bool = false,
    volume_r: f32 = 16,
    home_x: f32 = 0,
    home_z: f32 = 0,
    /// One-shot: the sleeper already stirred (SetSleeperActive) for an
    /// in-volume player that did not wake it, and the PassiveChange wire was
    /// sent. RE EntityAlive.SetSleeperActive (IL=26).
    groan_sent: bool = false,
    /// RE UpdateSleeper wake scan (entity-ai.md GetSleeperDisturbedLevel
    /// IL=38): the per-entity rolled wake-threshold pair - wake =
    /// Lerp(wake_light_near, wake_light_far, dist/sightRangeBase), the
    /// sleeper wakes the nearest player with lightLevel > wake. Rolled at
    /// spawn from the class SleeperSightToWakeMin/Max ranges (stock
    /// zombieTemplateMale "-40,5" / "340,480"); these defaults sit at the
    /// stock roll midpoints for direct-constructed test sleepers.
    wake_light_near: f32 = -17.5,
    wake_light_far: f32 = 410.0,
};

/// A combat-noise event (melee hit / ranged damage): alerts nearby zombies
/// and wakes sleepers within radius (stock NotifyNoise, group-AI PARTIAL).
pub const NoiseEvent = struct {
    x: f32,
    y: f32,
    z: f32,
    radius: f32,
};

/// One tick's noise ring cap: a busy fight cannot grow it (events beyond the
/// cap are dropped; the per-tick consume budget already throttles).
pub const noise_events_cap: usize = 8;

/// One entry in a player's stealth-noise list (RE PlayerStealth.noises:
/// `(volume, ticks)` sorted descending by volume; AddNoise inserts by rank).
pub const StealthNoise = struct {
    volume: f32 = 0,
    /// Remaining ticks before the entry expires (NoiseCleanup decrements).
    ticks: i32 = 0,
};

/// Per-player stealth-noise state (RE entity-ai.md PlayerStealth TickServer).
pub const stealth_noise_cap: usize = 8;

pub const Stealth = struct {
    /// Active noise entries (descending by volume; cap bounds the list).
    noises: [stealth_noise_cap]StealthNoise = undefined,
    noise_n: u8 = 0,
    /// RE PlayerStealth CalcVolume: geometric-decay sum × 2.35^0.86 × 1.5 ×
    /// Noise passive. Drives the per-enemy hearing test (attraction).
    noise_volume: f32 = 0,
    /// RE PlayerStealth.sleeperNoiseVolume: accumulated stealth noise feeding
    /// sleeper wake (NotifyNoise returns true at the 360 cap, then the caller
    /// wakes sleeper volumes at the noise position). Decays 2.5/tick after
    /// sleeperNoiseWaitTicks elapses.
    sleeper_noise_volume: f32 = 0,
    /// Ticks to hold before the sleeperNoiseVolume decay resumes (stock sets
    /// 20 when a loud noise (volume ≥ 11) lands).
    sleeper_noise_wait_ticks: i32 = 0,
    /// RE PlayerStealth.TickServer speedAverage (step 1): lerps toward the
    /// per-tick horizontal speed at 0.2 when moving, decays x0.5 when idle.
    /// The stealth light fold `x (1 + speedAverage x 0.15)` (IL_00CD).
    prev_x: f32 = 0,
    prev_z: f32 = 0,
    speed_average: f32 = 0,
};

/// One player-attributed stealth-noise event (movement noise, stock
/// AIDirector.NotifyNoise): the net thread resolves the relayed clip in the
/// sounds.xml noise table and pushes the row + the package volumeScale; the
/// sim applies the crouch muffle, accumulates the player's stealth list,
/// wakes sleepers at the volume cap, and feeds the heat map. Cap bounds the
/// ring like combat noise; beyond-cap events are dropped.
pub const stealth_events_cap: usize = 8;

pub const StealthNoiseEvent = struct {
    /// Owning player entity slot (u16: components.zig cannot see world.zig's Slot).
    slot: u16,
    x: f32,
    y: f32,
    z: f32,
    /// `noise` × package volumeScale (the client's NoiseScale already rides
    /// the package, stock GameManager.PlaySoundAtPositionServer).
    volume: f32,
    /// `time` × 20 (stock NotifyNoise converts seconds to ticks).
    duration_ticks: i32,
    /// `muffled_when_crouched` — applied when the owner is crouching.
    muffled_when_crouched: f32,
    /// `heat_map_strength` (> 0 feeds NotifyActivity, the noise-to-heat leg).
    heat_map_strength: f32,
    /// `heat_map_time` seconds (stock ×10 ticks).
    heat_map_time: f32,
};

/// One cell carried by a falling-blocks group entity (world coords + the
/// block's raw value so the client renders the right block falling).
pub const FallingCell = struct {
    x: i32,
    y: i32,
    z: i32,
    raw: u32,
};

/// One pending Demolition explosion (RE entity-ai.md EntityZombieCop): the
/// sim counts down and pushes the request; the Game drains it (single
/// thread) and applies the entity + block AoE. Cap bounds the ring so a
/// pack of primed cops cannot stall the tick.
pub const explode_cap: usize = 8;

pub const ExplodeRequest = struct {
    /// Entity slot (u16: components.zig cannot see world.zig's Slot type).
    slot: u16,
};

/// One pending MoveHelper dig (RE entity-ai.md DigStart/DigUpdate): the sim
/// runs the windup/attack cadence and pushes a damage request per attack; the
/// Game drains it (single thread) and damages the block like the chase chew.
pub const dig_cap: usize = 16;

pub const DigRequest = struct {
    slot: u16,
    x: i32,
    y: i32,
    z: i32,
};

/// One pending sleeper wake (RE entity-ai.md / EntityAlive
/// ConditionalTriggerSleeperWakeUp): the sim flips a sleeper to awake and
/// pushes the request; the Game drains it (single thread) and broadcasts
/// NetPackageSleeperWakeup so the client plays the wake animation. Cap bounds
/// the ring so a POI full of sleepers cannot stall the tick.
pub const sleeper_wake_cap: usize = 16;

pub const SleeperWakeRequest = struct {
    /// Entity slot (u16: components.zig cannot see world.zig's Slot type).
    slot: u16,
    /// True = the sleeper STIRRED (SetSleeperActive, NetPackageSleeperPassiveChange
    /// wire) instead of fully waking; false = the wakeup broadcast.
    groan: bool = false,
};

/// Group cap for one falling-blocks entity. Stock `GroupBounds.IsWithinSize`
/// clamps falling groups (stability.md) but the bound value is not IL-pinned;
/// 32 is a zdtd policy cap (a collapse rarely exceeds it; larger groups keep
/// their first 32 cells - the rest still air out via the collapse).
pub const falling_group_cap: usize = 32;

/// Stability-collapse group state: the cells that lost support, falling as
/// one EntityFallingBlock (RE entity-ai.md LetBlocksFall / landing: no
/// re-placement, die on ground contact).
pub const FallingBlocks = struct {
    cells: [falling_group_cap]FallingCell = undefined,
    n: u8 = 0,
    /// Vertical velocity, blocks/s (stock gravity integrator).
    vy: f32 = 0,
    /// Horizontal drift, blocks/s (stock singular spawns carry "random motion"
    /// - entity-ai.md LetBlocksFall 1262; a small deterministic impulse so
    /// falling blocks scatter like stock).
    vx: f32 = 0,
    vz: f32 = 0,
    /// fallTimeInTicks (stock EntityFallingBlock.OnUpdateEntity); the damage
    /// pass runs every other tick.
    tick: u16 = 0,
    /// Crush mass (RE IL=232-250): FastMin(hardness*mass, 10) * 8 via
    /// materials.xml; 0 = no crush damage. Raw damage caps at
    /// FastMin(massKg * |vy| * 0.05, 40).
    mass_kg: f32 = 0,
    /// Per-entity hit counts (stock cMaxHitsPerEntity 3, Dictionary keyed by
    /// entity id): a bounded fixed array so one falling block cannot damage an
    /// entity every tick forever.
    hit_ids: [falling_hits_tracked]i32 = undefined,
    hit_counts: [falling_hits_tracked]u8 = undefined,
    hit_n: u8 = 0,
};

/// Per-entity hit-count cap (stock cMaxHitsPerEntity = 3).
pub const falling_hit_cap: usize = 3;
/// Entities tracked per falling block (a collapse column crushes few victims).
pub const falling_hits_tracked: usize = 8;

/// Stock EntityAliveFlags bit values (protocol-packages.md 5.5.6 /
/// protocol-frames.md 9, bit 0 = LSB). The sim flags word mirrors the stock
/// wire word; ecs owns the canonical values and wire/packages.zig aliases its
/// cF_* consts here, so there is one source of truth for the bit numbers.
pub const flag_approaching_enemy: u16 = 0x0001;
pub const flag_approaching_player: u16 = 0x0002;
pub const flag_aiming_gun: u16 = 0x0004;
pub const flag_spawned: u16 = 0x0008;
pub const flag_jumping: u16 = 0x0010;
pub const flag_breaking_blocks: u16 = 0x0020;
pub const flag_is_alert: u16 = 0x0040;
pub const flag_flashlight_on: u16 = 0x0080;
pub const flag_god_mode: u16 = 0x0100;
pub const flag_crouching: u16 = 0x0200;

pub const Flags = struct {
    bits: u16 = flag_spawned,
};

/// Replication dirty bits.
pub const Dirty = packed struct(u8) {
    pos: bool = false,
    rot: bool = false,
    flags: bool = false,
    hp: bool = false,
    spawn: bool = false,
    remove: bool = false,
    inv: bool = false,
    _pad: bool = false,

    pub fn any(self: Dirty) bool {
        return self.pos or self.rot or self.flags or self.hp or self.spawn or self.remove or self.inv;
    }
};

/// Stock buff ticks per second: BuffValue::get_DurationInSeconds divides
/// durationTicks by a hardcoded 20 (asm.il 733359), independent of any server
/// tick-rate config. Deviating makes HUD timers expire at the wrong moment.
pub const buff_ticks_per_second: f32 = 20;
/// Concurrent buffs per entity. Stock's ActiveBuffs list is unbounded; a fixed
/// set keeps the component POD and bounds what one client can push at us.
pub const max_buffs_per_entity: usize = 8;

/// BuffEffectStackTypes (asm.il 738358): what a repeat application of an
/// already-active buff does. Absent stack_type in buffs.xml means Ignore
/// (BuffClass::.ctor, asm.il 732691), never Replace.
pub const StackType = enum(u8) { ignore = 0, duration = 1, effect = 2, replace = 3 };

/// BuffValue/BuffFlags (asm.il 733040). Bit positions are wire-visible:
/// BuffValue::Write emits this byte verbatim (asm.il 733588).
pub const BuffFlags = packed struct(u8) {
    started: bool = false,
    finished: bool = false,
    remove: bool = false,
    update: bool = false,
    invalid: bool = false,
    paused: bool = false,
    _pad: u2 = 0,
};

/// One entry of stock's EntityBuffs::ActiveBuffs (BuffValue, asm.il 733040).
/// The BuffClass fields the tick needs (duration, update rate, remove-on-death)
/// are copied in at add time: stock reads them off a shared BuffClass that
/// set_DurationMax mutates process-wide (asm.il 732658), which we refuse to model.
pub const BuffInstance = struct {
    active: bool = false,
    /// Index into the buffs.xml catalog (assets/buffs.Table.byId).
    def_id: u16 = 0,
    /// BuffValue::.ctor starts at 1; Effect stacking increments (asm.il 733486).
    stack_mult: u8 = 1,
    flags: BuffFlags = .{},
    duration_ticks: u32 = 0,
    update_ticks: u16 = 0,
    update_rate_ticks: i32 = 20,
    /// BuffClass::DurationMax in seconds; <= 0 never expires (asm.il 732754).
    duration_max: f32 = 0,
    remove_on_death: bool = true,
    instigator_id: i32 = -1,
    instigator_x: i32 = 0,
    instigator_y: i32 = 0,
    instigator_z: i32 = 0,

    /// BuffValue::get_DurationInSeconds (asm.il 733359).
    pub fn durationSeconds(self: *const BuffInstance) f32 {
        return @as(f32, @floatFromInt(self.duration_ticks)) / buff_ticks_per_second;
    }
};

pub const BuffSet = struct {
    slots: [max_buffs_per_entity]BuffInstance = [_]BuffInstance{.{}} ** max_buffs_per_entity,

    pub fn find(self: *BuffSet, def_id: u16) ?*BuffInstance {
        for (&self.slots) |*s| {
            if (s.active and s.def_id == def_id) return s;
        }
        return null;
    }

    pub fn findFree(self: *BuffSet) ?*BuffInstance {
        for (&self.slots) |*s| {
            if (!s.active) return s;
        }
        return null;
    }

    pub fn count(self: *const BuffSet) u8 {
        var n: u8 = 0;
        for (self.slots) |s| {
            if (s.active) n += 1;
        }
        return n;
    }
};

pub const Mask = packed struct(u32) {
    transform: bool = false,
    health: bool = false,
    network_id: bool = false,
    kind: bool = false,
    player: bool = false,
    zombie_ai: bool = false,
    vehicle: bool = false,
    turret: bool = false,
    trader: bool = false,
    flags: bool = false,
    journal: bool = false,
    wallet: bool = false,
    trader_stock: bool = false,
    inventory: bool = false,
    class_id: bool = false,
    loot_bag: bool = false,
    sleeper: bool = false,
    bot: bool = false,
    dirty: bool = false,
    buffs: bool = false,
    falling: bool = false,
    _pad: u11 = 0,
};

test "putInSlot rejects overflowing stack counts" {
    var inv: Inventory = .{};
    inv.slots[0] = .{ .item_id = 1, .count = std.math.maxInt(u16) };
    try std.testing.expect(!inv.putInSlot(0, .{ .item_id = 1, .count = 1 }, std.math.maxInt(u16)));
    try std.testing.expectEqual(std.math.maxInt(u16), inv.slots[0].count);
}

test "putInSlot and moveSlot refuse mismatched quality or meta merge" {
    var inv: Inventory = .{};
    inv.slots[0] = .{ .item_id = 5, .count = 2, .quality = 6, .meta = 10 };
    inv.slots[1] = .{ .item_id = 5, .count = 2, .quality = 1, .meta = 10 };
    try std.testing.expect(!inv.putInSlot(0, .{ .item_id = 5, .count = 1, .quality = 1, .meta = 10 }, 64));
    // Partial move onto a different-quality stack must not merge (and cannot swap).
    try std.testing.expect(!inv.moveSlot(1, 0, 1, 64));
    try std.testing.expectEqual(@as(u16, 2), inv.slots[0].count);
    try std.testing.expectEqual(@as(u8, 6), inv.slots[0].quality);
    // Matching quality+meta still merges.
    inv.slots[2] = .{ .item_id = 5, .count = 1, .quality = 6, .meta = 10 };
    try std.testing.expect(inv.moveSlot(2, 0, 1, 64));
    try std.testing.expectEqual(@as(u16, 3), inv.slots[0].count);
    try std.testing.expectEqual(@as(u16, 0), inv.slots[2].count);
}

test "addSlotStacked preserves quality and meta" {
    var inv: Inventory = .{};
    try std.testing.expect(inv.addSlotStacked(.{ .item_id = 11, .count = 2, .quality = 4, .meta = 99 }, 64));
    try std.testing.expectEqual(InvSlot{ .item_id = 11, .count = 2, .quality = 4, .meta = 99 }, inv.slots[0]);
    // Different quality does not merge into the q4 stack.
    try std.testing.expect(inv.addSlotStacked(.{ .item_id = 11, .count = 1, .quality = 1, .meta = 0 }, 64));
    try std.testing.expectEqual(@as(u16, 2), inv.slots[0].count);
    try std.testing.expectEqual(@as(u8, 4), inv.slots[0].quality);
    try std.testing.expectEqual(InvSlot{ .item_id = 11, .count = 1, .quality = 1, .meta = 0 }, inv.slots[1]);
}

test "BuffFlags bit layout matches stock BuffValue.BuffFlags" {
    // asm.il 733040: Started 1, Finished 2, Remove 4, Update 8, Invalid 0x10, Paused 0x20.
    try std.testing.expectEqual(@as(u8, 0x01), @as(u8, @bitCast(BuffFlags{ .started = true })));
    try std.testing.expectEqual(@as(u8, 0x02), @as(u8, @bitCast(BuffFlags{ .finished = true })));
    try std.testing.expectEqual(@as(u8, 0x04), @as(u8, @bitCast(BuffFlags{ .remove = true })));
    try std.testing.expectEqual(@as(u8, 0x08), @as(u8, @bitCast(BuffFlags{ .update = true })));
    try std.testing.expectEqual(@as(u8, 0x10), @as(u8, @bitCast(BuffFlags{ .invalid = true })));
    try std.testing.expectEqual(@as(u8, 0x20), @as(u8, @bitCast(BuffFlags{ .paused = true })));
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(BuffFlags{})));
}

test "BuffSet find and findFree handle empty and full sets" {
    var set: BuffSet = .{};
    try std.testing.expect(set.find(3) == null);
    try std.testing.expectEqual(@as(u8, 0), set.count());

    for (&set.slots, 0..) |*s, i| {
        const free = set.findFree() orelse return error.NoFreeSlot;
        free.* = .{ .active = true, .def_id = @intCast(i) };
        _ = s;
    }
    try std.testing.expectEqual(@as(u8, max_buffs_per_entity), set.count());
    try std.testing.expect(set.findFree() == null);
    try std.testing.expectEqual(@as(u16, 3), set.find(3).?.def_id);
    // Freeing a middle slot makes it reusable without disturbing the others.
    set.slots[3] = .{};
    try std.testing.expect(set.find(3) == null);
    try std.testing.expect(set.findFree() != null);
    try std.testing.expectEqual(@as(u8, max_buffs_per_entity - 1), set.count());
}

test "durationSeconds divides by the stock 20 Hz buff clock" {
    var b: BuffInstance = .{ .duration_ticks = 0 };
    try std.testing.expectEqual(@as(f32, 0), b.durationSeconds());
    b.duration_ticks = 20;
    try std.testing.expectEqual(@as(f32, 1), b.durationSeconds());
    b.duration_ticks = 90;
    try std.testing.expectEqual(@as(f32, 4.5), b.durationSeconds());
}
