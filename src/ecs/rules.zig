//! Sim rule parameters (ADR 0021 decision 2): a game mode is mostly these
//! numbers. Carried on `World.rules` (read as `w.rules.<group>.<field>`), set
//! from the mode pack / zdtd.toml overlay (T13). Defaults pin the pre-move
//! file-scope constants from systems.zig and aidirector.zig; the pin test below
//! fails loudly if a default ever drifts.
//!
//! Layer rule (ADR 0021 decision 5): a value here is a **floor** where stock
//! ships per-entity data, never a replacement for it. The combat/ai values that
//! resolve entityclasses.xml first are documented as such next to the field.

const std = @import("std");
const toml_bind = @import("../util/toml_bind.zig");

/// Which sim systems run (ADR 0021: behaviour, not just numbers). Every entry
/// defaults on, so the default table is exactly the stock pipeline; a mode pack
/// turns one off with `[systems] director = false`.
///
/// A disabled system is skipped, not stubbed: its slice of `TickResult` stays
/// zero, which is what a caller already handles for "nothing happened this
/// tick". Ordering is not configurable, because the phases document a real
/// dependency (buffs before ai so movement reads this tick's buff state) and a
/// mode reordering them would break determinism, not customise it.
pub const Systems = struct {
    /// Buff expiry and stacking. Off means no buff ever ticks down.
    buffs: bool = true,
    /// Spawn director: zombie hordes, blood moon, scouts. Off stops zombie
    /// spawning but keeps the clock, blood-moon flag and trader restock.
    director: bool = true,
    /// Daytime wildlife (stock SpawnManagerBiomes, a system separate from the
    /// AIDirector, spawning.md section 2): off stops animals; independent of
    /// `director` so a no-zombie mode can keep wandering wildlife.
    animals: bool = true,
    /// Zombie AI task selection and movement.
    ai: bool = true,
    vehicles: bool = true,
    turrets: bool = true,
    /// Far-entity despawn. Off means director spawns accumulate; pair it with
    /// `director = false` or a lower spawn cap.
    despawn: bool = true,
    /// Deferred SimCommand drain (plugins, admin). Off means queued commands
    /// are never applied, so leave it on unless a mode owns the queue.
    commands: bool = true,
};

/// Melee / combat tuning read by the systems.zig attack path.
pub const Combat = struct {
    /// Damage per melee hit, in hp. **Floor**: entityclasses.xml HandItem →
    /// items.xml DamageEntity wins when non-zero (systems.zig reads
    /// `if (ct.attack_damage > 0) ct.attack_damage else <this>`).
    attack_damage: f32 = 8.0,
    /// Melee reach, squared blocks. Policy: no per-entity stock equivalent.
    attack_range_sq: f32 = 2.0 * 2.0,
    /// Strike cadence in seconds. Policy: "No entityclasses field; always this
    /// cadence (stock melee interval approx)" (pre-move comment).
    attack_cooldown_s: f32 = 1.2,
    /// Flat armor mitigation per worn armor piece and its cap (zdtd
    /// approximation; R3). Stock mitigation is the passive-effects
    /// damage/armor modifier chain (items.md ModifyValue IL=304, ItemClassArmor
    /// IL=61) - an engine feature, RE-blocked; these numbers are the zdtd
    /// approximation made operator-tunable.
    armor_mitigation_per_piece: f32 = 0.1,
    armor_mitigation_cap: f32 = 0.5,
};

/// Zombie AI tuning read by the systems.zig task table and the despawn pass.
pub const Ai = struct {
    /// Full-sim range, squared blocks (lodScale step 3).
    full_dist_sq: f32 = 64.0 * 64.0,
    /// Mid-sim range, squared blocks (lodScale step 2).
    mid_dist_sq: f32 = 225.0,
    /// Sense range, squared blocks. **Floor**: entityclasses.xml `SightRange`
    /// wins per class when present (stock ships 27, 30, 40 m on different
    /// zombie classes); see systems.senseDistSq.
    sense_dist_sq: f32 = 48.0 * 48.0,
    /// Hearing radius, blocks: a player within this range is sensed regardless
    /// of sight (stock sound passes walls; the exact movement-noise radius is
    /// not IL-pinned, default ~stock cSmellRadiusMin 10). RE entity-ai.md
    /// PlayerStealth.
    hear_range: f32 = 10.0,
    /// Sight view-cone half-angle, degrees. Stock `EntityAlive.maxViewAngle`
    /// cctor default is 180 (full cone; IsInFrontOfMe halves it → 90 half =
    /// only excludes targets strictly behind), overridden per class by
    /// entityclasses.xml `MaxViewAngle` — that per-class value wins here via
    /// `viewHalfDeg` (systems.zig). RE entity-ai.md EntityAlive cctor.
    view_cone_half_deg: f32 = 90.0,
    /// Smell radius, blocks: players within this range are sensed regardless
    /// of sight or hearing (stock `cSmellRadiusMin` 10; the smell-emit/decay
    /// simulation is not ported, only the radius gate). RE entity-ai.md
    /// PlayerStealth.
    smell_radius: f32 = 10.0,
    /// Smell radius extension while the player is bleeding (stock
    /// `cSmellRadiusBleed` 25; tied to buffInjuryBleeding in the Game hook).
    smell_bleed_radius: f32 = 25.0,
    /// Hearing multiplier while the player crouches (stealth): stock mutes
    /// tracked-player noise by the per-clip `muffledWhenCrouched` from
    /// noisysounds.xml (AIDirectorData.Noise), which is data-driven and not
    /// ported; this flat scale is the floor applied to hear_range. RE
    /// entity-ai.md NotifyNoise.
    crouch_hear_scale: f32 = 0.5,
    /// Sleeper attack-detect range, blocks, while the target crouches. Stock
    /// `PlayerStealth.CanSleeperAttackDetect` crouch branch is
    /// `FastLerp(3, 15, lightAttackPercent)` - light-based, so the light leg
    /// is RE-blocked and this flat close range is the floor (RE entity-ai.md).
    crouch_sleeper_detect_range: f32 = 5.0,
    /// Combat-noise radius, blocks: a landed melee hit or ranged damage emits
    /// a noise event that alerts zombies and wakes sleepers within it (stock
    /// NotifyNoise; per-clip volumes from noisysounds.xml are data-driven and
    /// not ported - this flat radius is the floor). Group-AI PARTIAL.
    combat_noise_radius: f32 = 24.0,
    /// Noise events the consume pass drains per tick (bursts beyond the cap
    /// are dropped; the ring holds one tick's worth).
    noise_events_per_tick: u8 = 2,
    /// Move-body half-width, blocks (stock CharacterController radius ~0.35):
    /// the AI collide-and-slide keeps this much of the body out of solid
    /// cells when walking. Policy floor; entityclasses collider data is not
    /// ported (RE entity-movement.md).
    body_radius: f32 = 0.35,
    /// Move-body height, blocks (stock zombie CC height ~1.8): the head probe
    /// so a body does not duck through 1-high gaps. Policy floor.
    body_height: f32 = 1.8,
    /// Step-up limit, blocks: a blocked horizontal move is retried with the
    /// feet lifted by this much (stock CC stepOffset; zombies climb a full
    /// block). Policy floor.
    step_height: f32 = 1.0,
    /// Vertical acceleration, blocks/s². RE: `World::Gravity` cctor default
    /// **0.08** blocks/tick (World.il.txt:96) integrated as
    /// `motion.y = (motion.y - Gravity) * 0.98` per physics tick (the 0.98 is
    /// the y-drag; EntityAlive.il.txt:6330-6355) → effective ~1.6 blocks/s²
    /// with a self-cap around -3.9 blocks/s. zdtd's accumulator mirrors the
    /// per-tick formula so falls look stock.
    gravity: f32 = -1.6,
    /// Hard terminal fall velocity, blocks/s: safety cap on the accumulator
    /// (the stock 0.98 drag already self-caps around -3.9; this bounds a
    /// pathological tick so a long drop cannot outrun the per-tick probes).
    fall_max_vy: f32 = -30.0,
    /// Despawn range for director-spawned zombies, squared blocks.
    despawn_dist_sq: f32 = 200.0 * 200.0,
    /// Chase speed, blocks/s. **Floor**: entityclasses.xml MoveSpeedAggro wins
    /// when non-zero (systems.zig `if (ct.chase_speed > 0) ct.chase_speed * 1.6
    /// else <this>`).
    chase_speed: f32 = 2.2,
    /// Wander speed, blocks/s. **Floor**: entityclasses.xml MoveSpeed wins when
    /// non-zero (systems.zig `if (ct.wander_speed > 0) ct.wander_speed * 10.0
    /// else <this>`).
    wander_speed: f32 = 0.8,
    // -------------------------------------------------------------------------
    // AI timing / radii — extracted from systems.zig file-scope consts so
    // a mode pack or zdtd.toml [rules.ai] controls them without forking.
    // -------------------------------------------------------------------------
    /// How often (s) a chasing zombie re-solves A* toward the player (20 TPS
    /// budget: one search per 0.35 s caps total A* churn).
    path_replan_interval_s: f32 = 0.35,
    /// Max A* node expansions per replan (coarse local grid).
    path_max_expand: u32 = 96,
    /// Snap to next waypoint within this distance (blocks).
    path_wp_arrive: f32 = 0.55,
    /// Manhattan cells the goal may drift before forcing a replan.
    path_goal_slack: u32 = 2,
    /// Arrive radius for EAIApproachSpot (m).
    spot_arrive: f32 = 0.75,
    /// EAITerritorial leash radius (m). Beyond this, walk back to home.
    territorial_radius: f32 = 32.0,
    /// EAITaskList.executeDelayScale base (asm.il:437541).
    execute_delay_scale: f32 = 0.85,
    /// EAILook::Continue re-pick interval (s = 14 ticks at 20 Hz).
    look_turn_interval_s: f32 = 14.0 / 20.0,
    /// SeekYaw sweep range (deg).
    look_yaw_range_deg: f32 = 120.0,
    /// Entity::SeekYaw yawSlowAt (deg).
    look_yaw_slow_at_deg: f32 = 35.0,
    /// Per-class MaxTurnSpeed for zombieTemplateMale (deg/s).
    look_turn_speed_deg: f32 = 250.0,
    /// Utils::FastMax floor inside SeekYaw's slowdown branch (deg/s).
    look_turn_speed_min_deg: f32 = 20.0,
    /// EAIWander look window [min, max] (s).
    wander_look_min_s: f32 = 0.5,
    wander_look_max_s: f32 = 5.0,
    /// EAIApproachSpot look time base + random (s).
    spot_look_base_s: f32 = 5.0,
    spot_look_rand_s: f32 = 3.0,
    /// EAIApproachDistraction look time (s).
    distraction_look_s: f32 = 2.0,
    /// cCloseDist squared (1.5 m) for EAIApproachDistraction.
    distraction_close_sq: f32 = 2.25,
    /// EntityItem.tickDistraction cadence (ticks).
    distraction_broadcast_ticks: i32 = 20,
    /// EAIApproachDistraction replan [base, +rand] (ticks).
    distraction_replan_min: i32 = 20,
    distraction_replan_rand: i32 = 20,
    /// EAIWander max duration (s).
    wander_time_max_s: f32 = 30.0,
    /// Step toward no-op radius (m).
    wander_arrive: f32 = 0.2,
    /// EAIRunawayWhenHurt / EAIApproachDistraction approach distance (m)
    /// and EAIApproachDistraction cFarDist (approach spiral radius).
    flee_distance: f32 = 20.0,
    /// Vehicle mount range squared (8 m).
    mount_range_sq: f32 = 64.0,
    /// DestroyArea random gate modulus (wander_rng % N == 1).
    destroy_area_rng_mod: u32 = 16,
    /// Revenge target window (s = 400 ticks at 20 Hz).
    revenge_window_s: f32 = 20.0,
};

/// AIDirectorBloodMoonParty tuning (asm.il 413090-413140): players within
/// `party_join_dist` share one party focus; horde zombies beyond
/// `party_teleport_dist` teleport back; waves spawn ~`party_spawn_dist` out;
/// the per-party alive ceiling is `party_enemy_max`.
pub const Bloodmoon = struct {
    party_join_dist: f32 = 80.0,
    party_teleport_dist: f32 = 150.0,
    party_spawn_dist: f32 = 40.0,
    party_enemy_max: u32 = 30,
    /// Concurrent blood-moon parties. The storage array is a compile-time cap
    /// (aidirector.bm_parties_cap); the rule is clamped to it at use.
    max_parties: u32 = 8,
};

/// Survival simulation tuning (GAP 22).
///
/// **These are invented numbers and stock ships the real ones as data.** The
/// values below reproduce the stock feel (a full Food bar drains in roughly two
/// in-game days at 60-minute days), but stock drives survival from buffs.xml:
/// `buffStatusHungry01/02/03` and `buffStatusThirsty01/02/03` carry
/// `damage_type Starvation` / `Dehydration`, threshold requirements of the form
/// `StatComparePercCurrentToMax stat="Food" operation="GT" value="0.52"`, and
/// `FoodChangeOT` / `WaterChangeOT` / `HealthChangeOT` passive effects; stamina
/// comes from `StaminaChangeOT` plus the items.xml `StaminaLoss` stats. The
/// loader already exists (`assets/buffs.zig` parses passive_effect rows and
/// `Game.buffs` holds the table), so this is wiring, not research.
///
/// Note the model differs too: `well_fed_threshold` is an absolute 0..100 value
/// where stock compares a fraction of max. Tracked as WORK_PLAN T16; until then
/// treat every field here as a placeholder, not as stock behaviour.
pub const Progression = struct {
    /// Food units lost per in-game hour (100 = full).
    food_depletion_per_hour: f32 = 2.0,
    /// Water units lost per in-game hour (100 = full).
    water_depletion_per_hour: f32 = 2.5,
    /// HP lost per in-game hour while Food or Water is exhausted
    /// (UpdatePlayerHealthOT starvation branch).
    starvation_damage_per_hour: f32 = 12.0,
    /// HP regenerated per in-game hour while Food and Water are both above
    /// the well-fed threshold (UpdatePlayerHealthOT regen branch).
    well_fed_regen_per_hour: f32 = 10.0,
    /// Food/Water above this count as well-fed for regen.
    well_fed_threshold: f32 = 80.0,
    /// Stamina drained per real second while sprinting (MovementState 3).
    stamina_drain_per_second: f32 = 12.0,
    /// Stamina regenerated per real second while not sprinting.
    stamina_regen_per_second: f32 = 8.0,
    /// Seconds without an EntitySpeeds update before the sprint state lapses.
    sprint_stale_seconds: f32 = 0.5,
    /// Seconds between survival S2C refreshes per player (EntityStats
    /// netSyncWaitTicks is 10 ticks; 2 s keeps a visible but not chatty feed).
    survival_sync_seconds: f32 = 2.0,
    /// Zombie block-bite damage before BlockDamageAI/BM scaling (every 0.5 s pass).
    /// Mirrors the prior `base_bite: u32 = 10` constant in game/tick.zig.
    block_bite_damage: f32 = 10.0,
    /// HP lost per real second while the head block is water (drowning, after
    /// the client's local O2 bar empties; stock ~2 hp/s).
    drowning_damage_per_second: f32 = 2.0,
    /// HP lost per real second inside a radiated biome (biomes.xml
    /// <biomemap name="radiated"/>; stock BiomeType.Radiated is deadly).
    radiation_damage_per_second: f32 = 8.0,
    /// Pressed-against-cover range gate for block chew (m). Anti-kite: only when
    /// the zombie is within this range of its target and facing it.
    block_damage_range: f32 = 3.0,
    /// Fraction of a turret/trap kill's XP the owner is credited (stock
    /// ItemActionAttack.Hit / ProjectileMoveScript.checkCollision read the
    /// PassiveEffects.ElectricalTrapXP passive; buffs.xml documents its
    /// default as 0, unlocked only by perkAdvancedEngineering levels 1-5
    /// at .15/.3/.45/.6/.75). zdtd has no perk/attribute system yet (planned:
    /// docs/adr/0023-perk-attribute-system.md), so this is a flat floor rather
    /// than a per-player perk lookup; 0.0 matches the stock no-perk default.
    trap_kill_xp_frac: f32 = 0.0,
};

/// Placeholder group: added as constants move; no fields invented.
pub const WorldGroup = struct {
    /// Container open/use reach in blocks (3D, squared internally). Authority
    /// reach cap like max_edit_range, but ECS-visible (openContainer has no
    /// Game handle); R7.
    container_open_range: f32 = 8.0,
};

/// Vehicle sim tuning (zdtd-owned: the stock dedicated server has no vehicle
/// physics sim, GAP 4816; these shape the server-side drive model). All
/// operator-policy, so they live on the rules surface (ADR 0021).
pub const Vehicle = struct {
    /// Throttle acceleration (blocks/s^2) per unit throttle input.
    accel_mps2: f32 = 14.0,
    /// Reverse speed cap as a fraction of max_speed.
    reverse_frac: f32 = 0.3,
    /// Coast decay per second with no throttle (1.0 = full stop instantly).
    coast_decay: f32 = 0.8,
    /// Yaw rate (deg/s) per unit steer input at speed.
    steer_deg_per_s: f32 = 100.0,
    /// Minimum turn-speed fraction (keeps steering alive near standstill).
    min_turn_speed_frac: f32 = 0.15,
    /// Fuel consumed per block travelled (non-bicycle kinds).
    fuel_per_m: f32 = 0.02,
};

/// AIDirector policy (stock values, RE-cited in aidirector.zig): the wandering
/// horde schedule (start tick + min/max gap in world ticks) and spawn
/// distance/size, plus the chunk-heat spawner constants (heat threshold,
/// check/cooldown cadence, scout distance). Only constants the code actually
/// reads are surfaced (YAGNI; `heat_feral_chance` and `heat_event_ticks` stay
/// doc-only module consts in aidirector.zig until the feral roll / event
/// duration are modelled). Provenance: PROVENANCE.md §3.7.
pub const Director = struct {
    /// Wandering hordes only start after this world tick (day 1 end ~28000).
    wander_start_after: u64 = 28_000,
    /// Horde schedule gap in world ticks (stock 12000-24000 = 12-24 game hours).
    wander_min_gap: u64 = 12_000,
    wander_max_gap: u64 = 24_000,
    wandering_horde_size: u32 = 6,
    wandering_spawn_dist: f32 = 92.0,
    heat_spawn_threshold: f32 = 25.0,
    heat_check_seconds: f32 = 5.0,
    /// Region cooldown after a heat spawn. Stock `AIDirectorChunkData`
    /// `FindBestEventAndReset` stamps `cooldownDelay = 240` s (IL=44,
    /// aidirector.md verified literals; the long form is 1320 via SetLongDelay,
    /// modelled here as the feral 2x roll). Was 120 before the A41 alignment.
    heat_cooldown_seconds: f32 = 240.0,
    /// Cooldown applied to the eight surrounding regions. Stock
    /// `StartNeighborCooldown` sets 180 s (short) / 720 s (long) via FastMax
    /// (aidirector.md verified literals). Was 60 before the A41 alignment.
    heat_neighbor_cooldown_seconds: f32 = 180.0,
    heat_scout_dist: f32 = 10.0,
    /// Enemy spawn ring around players. Stock `GetRandomSpawnPositionInAreaMinMaxToPlayers`
    /// cEnemyMin/MaxDistance = 28..54 m (spawning.md; was 18..28, on-camera).
    enemy_spawn_ring_min: f32 = 28.0,
    enemy_spawn_ring_max: f32 = 54.0,
    /// Animal spawn ring. Stock cAnimalMin/MaxDistance = 48..70 m (spawning.md;
    /// was 20..45). The periodic wildlife drip itself is a zdtd mechanic.
    animal_spawn_ring_min: f32 = 48.0,
    animal_spawn_ring_max: f32 = 70.0,
    /// Night horde drip cadence (zdtd population mechanic; stock has no
    /// periodic drip, GAP 2011-2017). 45 s normal, 8 s during a blood moon.
    horde_drip_cd: f32 = 45.0,
    bloodmoon_horde_drip_cd: f32 = 8.0,
    /// Daytime scout drip cadence (zdtd mechanic; stock scouts come from heat
    /// events only, GAP 1407).
    scout_drip_cd: f32 = 120.0,
    /// Daytime wildlife drip cadence (zdtd mechanic).
    animal_drip_cd: f32 = 60.0,
    /// Blood-moon wave cadence (zdtd approximation of the stock wave system).
    bloodmoon_wave_cd: f32 = 6.0,
    /// Blood-moon zombie HP multiplier (zdtd policy; 1.5x).
    bloodmoon_hp_mult: f32 = 1.5,
};

/// Water leveling budgets (zdtd policy, GAP "Water flow / physics" PARTIAL):
/// the stock sim is a jobified mass-flow engine (light-mesh-water.md §4); the
/// leveling approximation pours water into basins opened by block edits, and
/// these bound its per-tick cost so one player digging cannot stall the tick.
pub const Water = struct {
    /// Pending block edits drained per tick (each may pour).
    edits_per_tick: u8 = 4,
    /// Max cells one pour may fill (fills, not traversals).
    spread_cap: u16 = 128,
};

/// Full rule surface. Carried on World; the TOML overlay mirrors it field for
/// field (RulesOverlay) and mergeOverlay applies the non-null subset.
pub const Rules = struct {
    systems: Systems = .{},
    combat: Combat = .{},
    ai: Ai = .{},
    bloodmoon: Bloodmoon = .{},
    progression: Progression = .{},
    world: WorldGroup = .{},
    vehicle: Vehicle = .{},
    director: Director = .{},
    water: Water = .{},
};

pub const CombatOverlay = struct {
    attack_damage: ?f32 = null,
    attack_range_sq: ?f32 = null,
    attack_cooldown_s: ?f32 = null,
    armor_mitigation_per_piece: ?f32 = null,
    armor_mitigation_cap: ?f32 = null,
};

pub const AiOverlay = struct {
    full_dist_sq: ?f32 = null,
    mid_dist_sq: ?f32 = null,
    sense_dist_sq: ?f32 = null,
    hear_range: ?f32 = null,
    view_cone_half_deg: ?f32 = null,
    smell_radius: ?f32 = null,
    smell_bleed_radius: ?f32 = null,
    crouch_hear_scale: ?f32 = null,
    crouch_sleeper_detect_range: ?f32 = null,
    combat_noise_radius: ?f32 = null,
    noise_events_per_tick: ?u8 = null,
    body_radius: ?f32 = null,
    body_height: ?f32 = null,
    step_height: ?f32 = null,
    gravity: ?f32 = null,
    fall_max_vy: ?f32 = null,
    despawn_dist_sq: ?f32 = null,
    chase_speed: ?f32 = null,
    wander_speed: ?f32 = null,
    path_replan_interval_s: ?f32 = null,
    path_max_expand: ?u32 = null,
    path_wp_arrive: ?f32 = null,
    path_goal_slack: ?u32 = null,
    spot_arrive: ?f32 = null,
    territorial_radius: ?f32 = null,
    execute_delay_scale: ?f32 = null,
    look_turn_interval_s: ?f32 = null,
    look_yaw_range_deg: ?f32 = null,
    look_yaw_slow_at_deg: ?f32 = null,
    look_turn_speed_deg: ?f32 = null,
    look_turn_speed_min_deg: ?f32 = null,
    wander_look_min_s: ?f32 = null,
    wander_look_max_s: ?f32 = null,
    spot_look_base_s: ?f32 = null,
    spot_look_rand_s: ?f32 = null,
    distraction_look_s: ?f32 = null,
    distraction_close_sq: ?f32 = null,
    distraction_broadcast_ticks: ?i32 = null,
    distraction_replan_min: ?i32 = null,
    distraction_replan_rand: ?i32 = null,
    wander_time_max_s: ?f32 = null,
    wander_arrive: ?f32 = null,
    flee_distance: ?f32 = null,
    mount_range_sq: ?f32 = null,
    destroy_area_rng_mod: ?u32 = null,
    revenge_window_s: ?f32 = null,
};

pub const BloodmoonOverlay = struct {
    party_join_dist: ?f32 = null,
    party_teleport_dist: ?f32 = null,
    party_spawn_dist: ?f32 = null,
    party_enemy_max: ?u32 = null,
    max_parties: ?u32 = null,
};

pub const ProgressionOverlay = struct {
    food_depletion_per_hour: ?f32 = null,
    water_depletion_per_hour: ?f32 = null,
    starvation_damage_per_hour: ?f32 = null,
    well_fed_regen_per_hour: ?f32 = null,
    well_fed_threshold: ?f32 = null,
    stamina_drain_per_second: ?f32 = null,
    stamina_regen_per_second: ?f32 = null,
    sprint_stale_seconds: ?f32 = null,
    survival_sync_seconds: ?f32 = null,
    block_bite_damage: ?f32 = null,
    drowning_damage_per_second: ?f32 = null,
    radiation_damage_per_second: ?f32 = null,
    block_damage_range: ?f32 = null,
    trap_kill_xp_frac: ?f32 = null,
};

pub const WorldGroupOverlay = struct {
    container_open_range: ?f32 = null,
};

pub const VehicleOverlay = struct {
    accel_mps2: ?f32 = null,
    reverse_frac: ?f32 = null,
    coast_decay: ?f32 = null,
    steer_deg_per_s: ?f32 = null,
    min_turn_speed_frac: ?f32 = null,
    fuel_per_m: ?f32 = null,
};

/// AIDirector overlay: `[rules.director]` binds these (binder-reflected).
pub const DirectorOverlay = struct {
    wander_start_after: ?u64 = null,
    wander_min_gap: ?u64 = null,
    wander_max_gap: ?u64 = null,
    wandering_horde_size: ?u32 = null,
    wandering_spawn_dist: ?f32 = null,
    heat_spawn_threshold: ?f32 = null,
    heat_check_seconds: ?f32 = null,
    heat_cooldown_seconds: ?f32 = null,
    heat_neighbor_cooldown_seconds: ?f32 = null,
    heat_scout_dist: ?f32 = null,
    enemy_spawn_ring_min: ?f32 = null,
    enemy_spawn_ring_max: ?f32 = null,
    animal_spawn_ring_min: ?f32 = null,
    animal_spawn_ring_max: ?f32 = null,
    horde_drip_cd: ?f32 = null,
    bloodmoon_horde_drip_cd: ?f32 = null,
    scout_drip_cd: ?f32 = null,
    animal_drip_cd: ?f32 = null,
    bloodmoon_wave_cd: ?f32 = null,
    bloodmoon_hp_mult: ?f32 = null,
};

pub const SystemsOverlay = struct {
    buffs: ?bool = null,
    director: ?bool = null,
    animals: ?bool = null,
    ai: ?bool = null,
    vehicles: ?bool = null,
    turrets: ?bool = null,
    despawn: ?bool = null,
    commands: ?bool = null,
};

/// Water leveling overlay: `[rules.water]` binds these (binder-reflected).
pub const WaterOverlay = struct {
    edits_per_tick: ?u8 = null,
    spread_cap: ?u16 = null,
};

/// All-optional mirror of Rules for mode-pack / zdtd.toml `[rules.*]` sections
/// (ADR 0021 decision 3). Hand-written next to Rules because Zig 0.16's
/// `@Struct` cannot lay out a recursive anonymous overlay type; the parity test
/// below pins the two together so a new rule cannot land without its overlay.
pub const RulesOverlay = struct {
    systems: SystemsOverlay = .{},
    combat: CombatOverlay = .{},
    ai: AiOverlay = .{},
    bloodmoon: BloodmoonOverlay = .{},
    progression: ProgressionOverlay = .{},
    world: WorldGroupOverlay = .{},
    vehicle: VehicleOverlay = .{},
    director: DirectorOverlay = .{},
    water: WaterOverlay = .{},
};

/// Apply a RulesOverlay onto a concrete Rules: only non-null fields override.
/// Precedence is applied by calling in order (defaults < mode pack < zdtd.toml).
pub fn mergeOverlay(dst: *Rules, o: *const RulesOverlay) void {
    toml_bind.mergeOverlay(Rules, dst, o);
}

/// Comptime parity check: every struct field in A has a same-named field in B,
/// recursing into nested structs (leaf names must match too).
fn fieldsParity(comptime A: type, comptime B: type) bool {
    const a_fields = std.meta.fields(A);
    const b_fields = std.meta.fields(B);
    if (a_fields.len != b_fields.len) return false;
    inline for (a_fields, 0..) |af, i| {
        if (!std.mem.eql(u8, af.name, b_fields[i].name)) return false;
        const a_struct = @typeInfo(af.type) == .@"struct";
        const b_struct = @typeInfo(b_fields[i].type) == .@"struct";
        if (a_struct != b_struct) return false;
        if (a_struct) {
            if (!fieldsParity(af.type, b_fields[i].type)) return false;
        }
    }
    return true;
}

test "RulesOverlay mirrors Rules field for field" {
    try std.testing.expect(fieldsParity(Rules, RulesOverlay));
    // And the TOML binder can bind the overlay directly (sections recurse).
    var o: RulesOverlay = .{};
    try toml_bind.bind(RulesOverlay, &o,
        \\[combat]
        \\attack_damage = 12.0
        \\[ai]
        \\sense_dist_sq = 3600.0
        \\[bloodmoon]
        \\party_enemy_max = 40
        \\max_parties = 3
        \\[director]
        \\wandering_horde_size = 4
        \\wandering_spawn_dist = 60.0
        \\heat_spawn_threshold = 30.0
        \\wander_min_gap = 1000
        \\wander_start_after = 5000
    , std.testing.allocator);
    try std.testing.expectEqual(@as(?f32, 12.0), o.combat.attack_damage);
    try std.testing.expectEqual(@as(?f32, null), o.combat.attack_range_sq);
    try std.testing.expectEqual(@as(?f32, 3600.0), o.ai.sense_dist_sq);
    try std.testing.expectEqual(@as(?u32, 40), o.bloodmoon.party_enemy_max);
    try std.testing.expectEqual(@as(?u32, 3), o.bloodmoon.max_parties);
    try std.testing.expectEqual(@as(?u32, 4), o.director.wandering_horde_size);
    try std.testing.expectEqual(@as(?f32, 60.0), o.director.wandering_spawn_dist);
    try std.testing.expectEqual(@as(?f32, 30.0), o.director.heat_spawn_threshold);
    try std.testing.expectEqual(@as(?u64, 1000), o.director.wander_min_gap);
    try std.testing.expectEqual(@as(?u64, 5000), o.director.wander_start_after);
}

test "mergeOverlay applies non-null subset in precedence order" {
    var r: Rules = .{};
    var pack: RulesOverlay = .{ .combat = .{ .attack_damage = 12.0 }, .ai = .{ .sense_dist_sq = 100.0 } };
    mergeOverlay(&r, &pack);
    try std.testing.expectEqual(@as(f32, 12.0), r.combat.attack_damage);
    try std.testing.expectEqual(@as(f32, 100.0), r.ai.sense_dist_sq);
    // zdtd.toml wins: only its keys override the pack's.
    var toml: RulesOverlay = .{ .combat = .{ .attack_damage = 20.0 } };
    mergeOverlay(&r, &toml);
    try std.testing.expectEqual(@as(f32, 20.0), r.combat.attack_damage);
    try std.testing.expectEqual(@as(f32, 100.0), r.ai.sense_dist_sq);
    // Untouched defaults survive both overlays.
    try std.testing.expectEqual(@as(u32, 8), r.bloodmoon.max_parties);
    try std.testing.expectEqual(@as(u32, 30), r.bloodmoon.party_enemy_max);
    try std.testing.expectEqual(@as(f32, 1.2), r.combat.attack_cooldown_s);
}

// Pin every default to the pre-move constant literal, so a later accidental
// retune fails loudly instead of silently changing the game (WORK_PLAN T12).
test "Rules defaults pin pre-move constants" {
    const r: Rules = .{};
    try std.testing.expectEqual(@as(f32, 8.0), r.combat.attack_damage);
    try std.testing.expectEqual(@as(f32, 2.0 * 2.0), r.combat.attack_range_sq);
    try std.testing.expectEqual(@as(f32, 1.2), r.combat.attack_cooldown_s);
    try std.testing.expectEqual(@as(f32, 64.0 * 64.0), r.ai.full_dist_sq);
    try std.testing.expectEqual(@as(f32, 225.0), r.ai.mid_dist_sq);
    try std.testing.expectEqual(@as(f32, 48.0 * 48.0), r.ai.sense_dist_sq);
    try std.testing.expectEqual(@as(f32, 200.0 * 200.0), r.ai.despawn_dist_sq);
    try std.testing.expectEqual(@as(f32, 2.2), r.ai.chase_speed);
    try std.testing.expectEqual(@as(f32, 0.8), r.ai.wander_speed);
    try std.testing.expectEqual(@as(f32, 0.35), r.ai.path_replan_interval_s);
    try std.testing.expectEqual(@as(u32, 96), r.ai.path_max_expand);
    try std.testing.expectEqual(@as(f32, 0.55), r.ai.path_wp_arrive);
    try std.testing.expectEqual(@as(u32, 2), r.ai.path_goal_slack);
    try std.testing.expectEqual(@as(f32, 0.75), r.ai.spot_arrive);
    try std.testing.expectEqual(@as(f32, 32.0), r.ai.territorial_radius);
    try std.testing.expectEqual(@as(f32, 0.85), r.ai.execute_delay_scale);
    try std.testing.expectEqual(@as(f32, 14.0 / 20.0), r.ai.look_turn_interval_s);
    try std.testing.expectEqual(@as(f32, 120.0), r.ai.look_yaw_range_deg);
    try std.testing.expectEqual(@as(f32, 35.0), r.ai.look_yaw_slow_at_deg);
    try std.testing.expectEqual(@as(f32, 250.0), r.ai.look_turn_speed_deg);
    try std.testing.expectEqual(@as(f32, 20.0), r.ai.look_turn_speed_min_deg);
    try std.testing.expectEqual(@as(f32, 0.5), r.ai.wander_look_min_s);
    try std.testing.expectEqual(@as(f32, 5.0), r.ai.wander_look_max_s);
    try std.testing.expectEqual(@as(f32, 5.0), r.ai.spot_look_base_s);
    try std.testing.expectEqual(@as(f32, 3.0), r.ai.spot_look_rand_s);
    try std.testing.expectEqual(@as(f32, 2.0), r.ai.distraction_look_s);
    try std.testing.expectEqual(@as(f32, 2.25), r.ai.distraction_close_sq);
    try std.testing.expectEqual(@as(i32, 20), r.ai.distraction_broadcast_ticks);
    try std.testing.expectEqual(@as(i32, 20), r.ai.distraction_replan_min);
    try std.testing.expectEqual(@as(i32, 20), r.ai.distraction_replan_rand);
    try std.testing.expectEqual(@as(f32, 30.0), r.ai.wander_time_max_s);
    try std.testing.expectEqual(@as(f32, 0.2), r.ai.wander_arrive);
    try std.testing.expectEqual(@as(f32, 20.0), r.ai.flee_distance);
    try std.testing.expectEqual(@as(f32, 64.0), r.ai.mount_range_sq);
    try std.testing.expectEqual(@as(u32, 16), r.ai.destroy_area_rng_mod);
    try std.testing.expectEqual(@as(f32, 20.0), r.ai.revenge_window_s);
    try std.testing.expectEqual(@as(f32, 80.0), r.bloodmoon.party_join_dist);
    try std.testing.expectEqual(@as(f32, 150.0), r.bloodmoon.party_teleport_dist);
    try std.testing.expectEqual(@as(f32, 40.0), r.bloodmoon.party_spawn_dist);
    try std.testing.expectEqual(@as(u32, 30), r.bloodmoon.party_enemy_max);
    try std.testing.expectEqual(@as(u32, 8), r.bloodmoon.max_parties);
    // Director heat cooldowns: stock-aligned (A41, aidirector.md verified
    // literals: FindBestEventAndReset 240 s, StartNeighborCooldown 180 s).
    try std.testing.expectEqual(@as(f32, 240.0), r.director.heat_cooldown_seconds);
    try std.testing.expectEqual(@as(f32, 180.0), r.director.heat_neighbor_cooldown_seconds);
}
