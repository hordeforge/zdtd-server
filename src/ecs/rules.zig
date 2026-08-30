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
const sandbox_presets = @import("../assets/sandbox_presets.zig");

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
    /// Player stealth-noise model (RE entity-ai.md PlayerStealth): consumes
    /// the movement-noise ring (sound relay), accumulates per-player noise
    /// volume, wakes sleepers at the volume cap, and feeds the AI hearing
    /// test. Off means relayed sounds never alert AI.
    stealth: bool = true,
    /// Zombie AI task selection and movement.
    ai: bool = true,
    vehicles: bool = true,
    /// Stability-collapse falling-block entities (gravity + landing + crush).
    /// Off freezes already-spawned fallers in the air; pair with no SetBlock
    /// collapses or they accumulate.
    falling: bool = true,
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
    /// Melee reach, squared blocks. **Floor**: the hand item's items.xml
    /// `Range` (meleeHandZombie01 1.6) or passive `MaxRange` (club/axe 2.4)
    /// wins per class when non-zero (systems.meleeRangeSq); this floor is
    /// the fallback for hand items without one.
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
    /// Per-attack stamina cost multiplier (stock ItemActionAttack.
    /// StaminaUsageMultiplier, sandbox option; the melee swing drains
    /// `StaminaLoss x StaminaUsageMultiplier`, RE ItemActionMelee IL). 1.0 =
    /// the stock default.
    stamina_usage_multiplier: f32 = 1.0,
    /// Melee knockback impulse: shove speed (blocks/s) and the hit window (s).
    /// 0.3 s at 8 blocks/s pushes ~2.4 blocks (stock melee shove ballpark;
    /// components.zig kb_speed/kb_seconds).
    knockback_speed: f32 = 8.0,
    knockback_seconds: f32 = 0.3,
};

/// Per-request caps on untrusted C2S push paths (AGENTS rule 20): each bounds
/// how much one client package may apply, so a single peer cannot spam a
/// multi-unit effect past the intended budget. Stock eats one unit per action
/// and spawns the quest entity per journal event; these caps bound the
/// stack-loss / multi-spawn pushes without changing the one-at-a-time default.
pub const C2s = struct {
    /// Eat effect units applied per ItemActionEat C2S push (cap on multi-unit
    /// stack loss; the client normally pushes one unit per action).
    eat_units_per_push: u8 = 4,
    /// Entities spawned per journal quest-summon C2S request (cap; the client
    /// requests one summon per journal event).
    quest_summon_per_request: u8 = 8,
};

/// Parachute glide (ADR 0037): while a player's glide flag is armed (plugin
/// verb `glide`) the server clamps the C2S vertical delta to `sink_vy_mps`
/// and broadcasts the clamped position, so the fall is slowed server-side
/// (no client mod needed; fall-damage stays client-owned, stock wire).
/// `item_tag` marks the worn armor item that reports `wearing_glider` in the
/// sense v4 record. Preset-overridable via `[rules.glide]` so a mod ships its
/// own values self-contained.
pub const Glide = struct {
    /// Sink speed while the glide flag is armed (parachute, ADR 0037).
    sink_vy_mps: f32 = 2.5,
    /// Worn armor item tag that reports `wearing_glider` in sense v4.
    item_tag: []const u8 = "parachute",
    /// Global player fall sink (blocks/s) applied WITHOUT the glide flag:
    /// > 0 clamps every player's C2S vertical delta (server-side fall
    /// slow-down; the moon_gravity mod sets this to its lunar terminal
    /// velocity). 0 = stock envelope (no clamp).
    fall_sink_vy_mps: f32 = 0,
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
    /// entityclasses.xml `MaxViewAngle` - that per-class value wins here via
    /// `viewHalfDeg` (systems.zig). RE entity-ai.md EntityAlive cctor.
    view_cone_half_deg: f32 = 90.0,
    /// CanSeeStealth light-threshold floor pair (RE entity-ai.md CanSeeStealth
    /// IL=21 + EntityClass cctor): FastLerp(x, y, dist/sightRange) vs the
    /// player's TickServer lightLevel (0..200). The stock EntityClass cctor
    /// default is (30, 100); zombieTemplateMale overrides to "-2,150" (seen at
    /// point blank even at night). Per-class entityclasses SightLightThreshold
    /// wins; this is the floor when unset.
    sight_light_threshold_min: f32 = 30.0,
    sight_light_threshold_max: f32 = 100.0,
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
    /// Sleeper attack-detect range while the target crouches (RE entity-ai.md
    /// `PlayerStealth.CanSleeperAttackDetect`): `FastLerp(min, max,
    /// lightAttackPercent)` where `lightAttackPercent` is 0.89
    /// (`stealth_light_passive`) when the player's selfLight (held-item
    /// light) < 0.1 else 1 (TickServer IL_010B; no item-light model, so the
    /// passive always applies); the stock bounds are 3..15. Consumed by the
    /// sleeper wake scan in systems.zig.
    crouch_sleeper_detect_min: f32 = 3.0,
    crouch_sleeper_detect_max: f32 = 15.0,
    /// `PlayerStealth.TickServer` passive-89 fold for `lightAttackPercent`
    /// when the player's selfLight (the held-item light, GetStealthLightLevel
    /// out) < 0.1 (stock `EffectManager.GetValue(Passive89)` with no items =
    /// 0.89; RE entity-ai.md TickServer IL_010B).
    stealth_light_passive: f32 = 0.89,
    /// Combat-noise radius, blocks: a landed melee hit or ranged damage emits
    /// a noise event that alerts zombies and wakes sleepers within it (stock
    /// NotifyNoise; per-clip volumes from noisysounds.xml are data-driven and
    /// not ported - this flat radius is the floor). Group-AI PARTIAL.
    combat_noise_radius: f32 = 24.0,
    /// Noise events the consume pass drains per tick (bursts beyond the cap
    /// are dropped; the ring holds one tick's worth).
    noise_events_per_tick: u8 = 2,
    /// --- Movement-noise volume model (RE entity-ai.md PlayerStealth) ---
    /// The per-clip volumes/decays themselves are game data (sounds.xml
    /// `<Noise>` rows, loaded by assets/noise.zig); these are the stock model
    /// constants, all configurable via mode packs.
    /// Geometric decay per stealth-list slot in CalcVolume (0.6^i weighting).
    stealth_noise_decay: f32 = 0.6,
    /// CalcVolume curve: (sum × 2.35)^0.86, then × 1.5.
    stealth_noise_curve_a: f32 = 2.35,
    stealth_noise_curve_b: f32 = 0.86,
    stealth_noise_scale: f32 = 1.5,
    /// EffectManager.GetValue(Noise) analog: the sim carries no equipment
    /// passives, so stock's value with no items is 1.0; a server can scale
    /// all player noise through this knob instead of patching data.
    stealth_noise_passive: f32 = 1.0,
    /// Attraction radius: min(sum × 0.6 × (1 + senseScale × 1.6), 40 +
    /// 15 × senseScale); EAIManager.CalcSenseScale defaults to 0 here.
    stealth_attract_sense_scale: f32 = 0.0,
    stealth_attract_radius_cap_a: f32 = 40.0,
    stealth_attract_radius_cap_b: f32 = 15.0,
    /// Per-enemy hearing test: heard when noiseVolume × (1 + feralSense) /
    /// (dist × 0.6 + 0.4) × detectUsScale ≥ 1. Stock per-entity feralSense
    /// (bloodmoon/feral) and the 0.3 POI-resident DetectUsScale are not
    /// modeled; these floors replace them.
    stealth_hear_feral_sense: f32 = 0.0,
    stealth_hear_detect_us: f32 = 1.0,
    /// Alert radius for the S2C stealth broadcast (player.zig
    /// tickStealthBroadcast): any alert zombie within this radius flags the
    /// player's packed `alert` bit. The stock client computes its own alert UI
    /// locally (no server-side radius is IL-pinned), so this is the zdtd
    /// authoritative approximation made operator-tunable. The broadcast
    /// cadence itself (every 16 ticks) is stock PlayerStealth.TickServer
    /// IL_0470 and stays pinned in code.
    stealth_alert_radius: f32 = 12.0,
    /// Sleeper wake: NotifyNoise accumulates the (curved) volume into
    /// sleeperNoiseVolume, capped at 360; reaching the cap wakes sleeper
    /// volumes at the noise position. The cap decays 2.5/tick once the
    /// wait window (20 ticks after a volume ≥ 11 noise) elapses.
    stealth_sleeper_wake_volume: f32 = 360.0,
    stealth_sleeper_volume_decay: f32 = 2.5,
    stealth_loud_volume: f32 = 11.0,
    stealth_loud_wait_ticks: i32 = 20,
    /// Demolition explosion effect floors (RE entity-ai.md EntityZombieCop:
    /// the stock values live in the class's ExplosionData value string, which
    /// is data-driven and not parsed - these floors bound the AoE). Radius in
    /// blocks, block damage per cell (vs maxDamageForBlock), entity damage at
    /// the epicentre (linear falloff).
    explosion_radius: f32 = 4.0,
    explosion_block_damage: u16 = 1000,
    explosion_entity_damage: f32 = 100.0,
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
    /// Jump hop height, blocks: when both slide axes are blocked and the body
    /// is grounded, the AI hops over the obstacle (stock MoveHelper StartJump
    /// heightDiff ~1.3 - entity-ai.md 2030-2034; the blocked-up call site
    /// passes 0.5+rand*0.4..1.3 and the entity-blocked site 0.7+rand*0.8..1.4).
    /// Policy floor.
    jump_height: f32 = 1.3,
    /// Min seconds between jumps (stock EntityAlive jumpDelay default 1 x20
    /// ticks = 1 s - entity-ai.md 3228). Prevents bunny-hop on a sealed wall.
    jump_delay_s: f32 = 1.0,
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
    /// Swim physics (RE entity-ai.md EntityAlive cctor: cSwimGravityPer 0.025,
    /// cSwimDragY 0.91): a submerged AI body falls with gravity*0.025 and the
    /// 0.91 y-drag, so it sinks slowly instead of dropping - a float.
    swim_gravity_per: f32 = 0.025,
    swim_drag_y: f32 = 0.91,
    /// Horizontal speed fraction while swimming (stock swimSpeed < moveSpeed).
    swim_speed_frac: f32 = 0.5,
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
    // AI timing / radii - extracted from systems.zig file-scope consts so
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
    /// V3.2.0 EAIRunawayFromEntity rework (changelog-3.2.0 §4.4) split the
    /// single radius into a detection radius and a flee-until radius: the
    /// animal picks a fear source within `timid_danger_distance` and keeps
    /// fleeing until the source is beyond `timid_safe_distance`. Defaults
    /// equal the legacy single-radius behavior.
    timid_danger_distance: f32 = 20.0,
    timid_safe_distance: f32 = 20.0,
    /// Vehicle mount range squared (8 m).
    mount_range_sq: f32 = 64.0,
    /// DestroyArea random gate modulus (wander_rng % N == 1).
    destroy_area_rng_mod: u32 = 16,
    /// Revenge target window (s = 400 ticks at 20 Hz).
    revenge_window_s: f32 = 20.0,
    // -------------------------------------------------------------------------
    // LOD / pacing knobs (systems.zig "ultra-far sleep" block + stragglers).
    // -------------------------------------------------------------------------
    /// AI scale when no player is sensed at all (systems.zig active_scale).
    no_target_scale: f32 = 0.1,
    /// Ultra-far gate: a player beyond `full_dist_sq * sleep_dist_mult` puts
    /// the zombie into slow-wander only (no A*/task scan) unless it is chewing
    /// a blocked path.
    sleep_dist_mult: f32 = 4.0,
    /// Decision-cooldown drain scale in the ultra-far state (dt * this).
    sleep_decision_scale: f32 = 0.05,
    /// Ultra-far re-decide cadence (s).
    sleep_wander_interval_s: f32 = 1.0,
    /// Ultra-far wander speed fraction of the normal wander speed.
    sleep_wander_speed_frac: f32 = 0.5,
    /// Passive-animal fear-source scan cadence (s).
    fear_scan_cd_s: f32 = 0.5,
    /// stepToward arrive threshold, blocks (compared squared).
    move_arrive: f32 = 0.2,
    /// Entity-push (AttackPush) proximity box half-extent (x/z, blocks), the
    /// vertical tolerance, and the shove displacement per step.
    push_range: f32 = 0.7,
    push_y_tol: f32 = 1.5,
    push_shove: f32 = 0.15,
    /// Zombie dig: windup before a bite lands (ticks, stock 18) and how long a
    /// zombie chews a block before DigStop (ticks, zdtd budget).
    dig_windup_ticks: u8 = 18,
    dig_budget_ticks: u8 = 90,
};

/// AIDirectorBloodMoonParty tuning (asm.il 413090-413140): players within
/// `party_join_dist` share one party focus; horde zombies beyond
/// `party_teleport_dist` teleport back; waves spawn ~`party_spawn_dist` out;
/// the per-party alive ceiling is `party_enemy_max`.
/// GameDifficulty 0..5 -> damage multipliers (RE `ItemActionAttack.
/// difficultyModifier`, il/full-v3.1.0/_global/ItemActionAttack.il.txt:2722;
/// call site IL_0A4A inside ItemActionAttack.Hit). The PvE scalers apply only
/// in mixed client/server matchups: a server (AI) attacker hitting a client
/// entity scales its strength by `IncomingDamageModifier`, a client hitting a
/// server entity by `EntityIncomingDamageModifier`; PvP and AI-vs-AI are
/// unchanged, and the stock server never re-scales the client's claimed
/// strength (NetPackageDamageEntity::ProcessPackage IL=172 stores it verbatim
/// into DamageResponse::Strength). The per-difficulty ladder comes from the
/// stock `Data/Sandbox/sandbox_presets` TextAsset (embedded
/// `assets/sandbox_presets.xml`, comptime-decoded in assets/sandbox_presets.
/// zig; RE evidence sandbox-options.md §3, extracted 2026-08-26): each
/// difficulty preset's SandboxCode decodes option 17 (IncomingDamage) via
/// `UpdateInGameValuesWithSandboxOptions`. Never hardcode these values - the
/// defaults below are the comptime XML decode; an operator overrides them in
/// `[rules.difficulty]` (ADR 0021).
pub const Difficulty = struct {
    /// Server (AI) attacker -> client entity damage multiplier, per difficulty.
    incoming_damage_0: f32 = sandbox_presets.difficulty[0].incoming_damage,
    incoming_damage_1: f32 = sandbox_presets.difficulty[1].incoming_damage,
    incoming_damage_2: f32 = sandbox_presets.difficulty[2].incoming_damage,
    incoming_damage_3: f32 = sandbox_presets.difficulty[3].incoming_damage,
    incoming_damage_4: f32 = sandbox_presets.difficulty[4].incoming_damage,
    incoming_damage_5: f32 = sandbox_presets.difficulty[5].incoming_damage,
    /// Client attacker -> server entity damage multiplier, per difficulty.
    /// Stock applies this client-side in the attacker's local ItemActionAttack
    /// Hit; the server trusts the claimed strength, so the server never
    /// re-applies it (double-scaling). No stock difficulty code touches
    /// option 42, so every tier decodes to the 1.0 default (comptime XML).
    entity_incoming_damage_0: f32 = sandbox_presets.difficulty[0].entity_incoming_damage,
    entity_incoming_damage_1: f32 = sandbox_presets.difficulty[1].entity_incoming_damage,
    entity_incoming_damage_2: f32 = sandbox_presets.difficulty[2].entity_incoming_damage,
    entity_incoming_damage_3: f32 = sandbox_presets.difficulty[3].entity_incoming_damage,
    entity_incoming_damage_4: f32 = sandbox_presets.difficulty[4].entity_incoming_damage,
    entity_incoming_damage_5: f32 = sandbox_presets.difficulty[5].entity_incoming_damage,
    /// Difficulty index 0..5 (clamped) -> incoming-damage multiplier.
    pub fn incomingFor(self: *const Difficulty, d: u8) f32 {
        return switch (@min(d, 5)) {
            0 => self.incoming_damage_0,
            1 => self.incoming_damage_1,
            2 => self.incoming_damage_2,
            3 => self.incoming_damage_3,
            4 => self.incoming_damage_4,
            else => self.incoming_damage_5,
        };
    }
    /// Difficulty index 0..5 (clamped) -> entity-incoming-damage multiplier.
    pub fn entityIncomingFor(self: *const Difficulty, d: u8) f32 {
        return switch (@min(d, 5)) {
            0 => self.entity_incoming_damage_0,
            1 => self.entity_incoming_damage_1,
            2 => self.entity_incoming_damage_2,
            3 => self.entity_incoming_damage_3,
            4 => self.entity_incoming_damage_4,
            else => self.entity_incoming_damage_5,
        };
    }
};

pub const Bloodmoon = struct {
    party_join_dist: f32 = 80.0,
    party_teleport_dist: f32 = 150.0,
    party_spawn_dist: f32 = 40.0,
    party_enemy_max: u32 = 30,
    /// Concurrent blood-moon parties. The storage array is a compile-time cap
    /// (aidirector.bm_parties_cap); the rule is clamped to it at use.
    max_parties: u32 = 8,
    /// Blood-moon spawn ceiling multiplier over the world MaxSpawnedZombies
    /// (RE `AIDirector::CanSpawn(1.9f)`, asm.il:413528).
    budget_scale: f32 = 1.9,
    /// Per-party horde wave size as a fraction of the blood-moon enemy count.
    wave_frac: f32 = 0.5,
};

/// Survival simulation tuning (GAP 22).
///
/// **The base depletion rates are invented numbers; stock ships the real ones
/// as data.** The values below reproduce the stock feel (a full Food bar
/// drains in roughly two in-game days at 60-minute days). The conditional
/// legs are now stock data via the passive-effects VM (assets/buffs.zig):
/// with a game-dir present, `tickSurvival` keeps the matching
/// `buffStatusHungry/Thirsty01..03` stage buffs in the entity's BuffSet
/// (revertibly; `survivalStages` resolves the `StatComparePercCurrentToMax`
/// thresholds), reads the starvation HP loss off the active stage-3 buff's
/// `ModifyStats Health` row, and applies the `StaminaChangeOT` penalty from
/// the VM's tracked deltas. These fields are the fallback floor when
/// buffs.xml is absent (offline/builtin data).
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
    /// Kill-XP floor when entityclasses.xml ExperienceGain did not resolve
    /// (offline/builtin catalog or recycled slot); stock classes resolve
    /// their own XP when a game-dir is present.
    kill_xp_fallback: f32 = 100,
    /// Fraction of a turret/trap kill's XP the owner is credited (stock
    /// ItemActionAttack.Hit / ProjectileMoveScript.checkCollision read the
    /// PassiveEffects.ElectricalTrapXP passive; buffs.xml documents its
    /// default as 0, unlocked only by perkAdvancedEngineering levels 1-5
    /// at .15/.3/.45/.6/.75). zdtd has no perk/attribute system yet (planned:
    /// docs/adr/0023-perk-attribute-system.md), so this is a flat floor rather
    /// than a per-player perk lookup; 0.0 matches the stock no-perk default.
    trap_kill_xp_frac: f32 = 0.0,
    /// V3.2.0 (changelog-3.2.0 §4.3): `EntityAlive.PartyShareKillServer`
    /// skips the party XP share when `bTrapKillXP` is set. True = depart from
    /// stock and let trap kills party-share like normal kills.
    trap_xp_party_share: bool = false,
};

/// Placeholder group: added as constants move; no fields invented.
pub const WorldGroup = struct {
    /// Container open/use reach in blocks (3D, squared internally). Authority
    /// reach cap like max_edit_range, but ECS-visible (openContainer has no
    /// Game handle); R7.
    container_open_range: f32 = 8.0,
    /// Force every column's topsoil "broken" on the wire (the pre-topsoil
    /// look: the client renders block textures instead of MicroSplat splat
    /// maps). False = stock: fresh terrain splat-renders and dig/upgrade
    /// marks the disturbed columns. Worlds without splat maps (the flat demo
    /// world) may render grey with the stock mode; set true for them.
    topsoil_all_broken: bool = false,
    /// POI quest-lock release grace after unlock (ticks; 2000 = 100 s).
    poi_unlock_grace_ticks: u32 = 2000,
};

/// World elevation/geometry policy: how a terrain source's natural elevation
/// (absolute game-Y meters, 1 block = 1 m) projects onto the chunk column.
/// Data, not code: a world can ship compressed mountains (`height_scale < 1`),
/// a sea-level model, or a custom ceiling without touching the generator.
/// Stock defaults are the identity (scale 1, offset 0, ceiling = profile max),
/// so the projection is a no-op for vanilla worlds (fast path, no plane
/// rewrite). Semantics mirror RealEarth's elevation mapping
/// (`gameY = sea + elev_m`); the sea addition lives in the source.
pub const Geometry = struct {
    /// Sea level in blocks (absolute game Y): the flat-world surface and the
    /// baked-DTM out-of-bounds fallback. zdtd default 64 (stock 62.88 tracked
    /// in the divergence register; RealEarth-style worlds set ~100).
    sea_level: f32 = 64,
    /// surface_y = clamp(height_offset + height_scale * elev_m, 0, ceiling).
    /// 1.0 = identity; < 1 compresses mountains into the column; > 1 needs a
    /// taller wire profile (ADR geometry/wire-profiles) for headroom.
    height_scale: f32 = 1.0,
    /// Vertical shift applied after scaling (lift/lower the whole world).
    height_offset: f32 = 0.0,
    /// Hard ceiling for the projected surface Y; 0 = active wire-profile max
    /// (stock 255). A world with real-Everest data sets this to the column cap.
    height_ceiling: u32 = 0,

    /// Effective ceiling for the active profile max.
    pub fn ceiling(self: Geometry, profile_max: u32) u32 {
        return if (self.height_ceiling == 0) profile_max else self.height_ceiling;
    }

    /// Project an absolute elevation (game-Y meters) onto the column.
    pub fn project(self: Geometry, elev_m: f32, profile_max: u32) u32 {
        const v = self.height_offset + self.height_scale * elev_m;
        const c = @max(0.0, @min(v, @as(f32, @floatFromInt(self.ceiling(profile_max)))));
        return @intFromFloat(c);
    }

    /// Identity projection: skip the plane rewrite entirely.
    pub fn isStock(self: Geometry) bool {
        return self.height_scale == 1.0 and self.height_offset == 0.0 and self.height_ceiling == 0;
    }

    /// Fail-closed sanity: the height plane is byte (u8) in EVERY wire
    /// profile - including tall - so a non-zero ceiling above 255 would make
    /// the plane fill's @intCast panic. A negative scale inverts the world
    /// and a negative sea level is nonsense. Validated in main.zig on the
    /// effective rules, like WorldgenGroup.
    pub fn validate(self: Geometry) ?[]const u8 {
        if (self.height_scale < 0) return "[rules.geometry] height_scale must be >= 0";
        if (self.sea_level < 0) return "[rules.geometry] sea_level must be >= 0";
        if (self.height_ceiling > 255) {
            return "[rules.geometry] height_ceiling above 255 is unrepresentable (the height plane is byte in every profile)";
        }
        return null;
    }
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
    /// Flat fuel-tank capacity on spawn (no vehicles.xml FuelMax in the port).
    fuel_cap: f32 = 100,
    /// Refuel pickup reach, blocks.
    refuel_reach: f32 = 3.0,
    /// Vehicle vertical gravity, blocks/s² (RE EntityVehicle::cGravity,
    /// asm.il:536018; distinct from the zombie ai.gravity).
    gravity: f32 = -9.81,
};

/// Procedural terrain shaping params (zdtd-owned W1/W2 no-map generator; the
/// stock DTM-backed maps override them). Defaults are the pre-lift module
/// constants, so a default `[rules.worldgen]` is byte-identical to the old
/// generator. Only the tuning surface moved to config (ADR 0021); the grid
/// cells (`cell_w`/`cell_h`), the noise recipe and the RWG water table stay
/// code (structural / RE-derived). Provenance: PROVENANCE.md §3.8.
pub const WorldgenGroup = struct {
    /// Sea / base height band for the 2D shaping stack.
    base_height: f32 = 68,
    /// Continental + ridged amplitude blend base.
    height_amp: f32 = 24,
    /// Surface band the shaping stack clamps into (columnTarget + margin).
    min_surface: u8 = 12,
    max_surface: u8 = 200,
    /// Vertical blocks over which the Y-gradient runs solid→air.
    squash: f32 = 28,
    /// Noise blend weight; must stay < 1 (hard solid-below / air-above).
    noise_weight: f32 = 0.85,
    /// Vertical stretch of the density noise.
    y_scale: f32 = 2.0,
    /// Blocks below this are forced solid (bedrock always lands).
    bedrock_h: i32 = 3,

    /// Fail-closed sanity: the shaping surface must be a non-empty band with
    /// room for the interpolation margin, and `noise_weight < 1` is load
    /// bearing (the hard solid-below / air-above guarantee depends on it).
    /// Returns a message on invalid config (validated in main.zig after the
    /// rules merge, like the wire profile).
    pub fn validate(self: WorldgenGroup) ?[]const u8 {
        if (self.min_surface >= self.max_surface) {
            return "[rules.worldgen] min_surface must be < max_surface";
        }
        if (self.squash <= 0) return "[rules.worldgen] squash must be > 0";
        if (self.noise_weight >= 1.0) {
            return "[rules.worldgen] noise_weight must be < 1 (the solid-below / air-above guarantee needs it)";
        }
        if (self.height_amp < 0) return "[rules.worldgen] height_amp must be >= 0";
        if (self.bedrock_h < 0) return "[rules.worldgen] bedrock_h must be >= 0";
        return null;
    }
};

/// AIDirector policy (stock values, RE-cited in aidirector.zig): the wandering
/// horde schedule (start tick + min/max gap in world ticks) and spawn
/// distance/size, plus the chunk-heat spawner constants (heat threshold,
/// check/cooldown cadence, scout distance/count, feral roll). Only constants
/// the code actually reads are surfaced (YAGNI; `heat_event_ticks` was doc-only
/// until craft.zig started stamping it - it now is a rule). Provenance:
/// PROVENANCE.md §3.7.
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
    /// Scouts spawned per heat event (sibling of heat_scout_dist).
    heat_scout_count: u32 = 2,
    /// Feral roll chance per heat event (0.2 = one in five); doubles the
    /// region cooldown when it lands. Now wired to the actual roll in
    /// aidirector.zig (the old note said "doc-only until modelled" - it is).
    heat_feral_chance: f32 = 0.2,
    /// Cooldown multiplier applied when the feral roll lands.
    heat_feral_cd_mult: f32 = 2.0,
    /// Heat-event duration (world ticks) stamped on heat sources (forge runs,
    /// campfire activity, ...) and by craft.zig notifyActivity.
    heat_event_ticks: f32 = 720.0,
    /// Enemy spawn ring around players. Stock `GetRandomSpawnPositionInAreaMinMaxToPlayers`
    /// cEnemyMin/MaxDistance = 28..54 m (spawning.md; was 18..28, on-camera).
    enemy_spawn_ring_min: f32 = 28.0,
    enemy_spawn_ring_max: f32 = 54.0,
    /// Animal spawn ring. Stock cAnimalMin/MaxDistance = 48..70 m (spawning.md;
    /// was 20..45). The periodic wildlife drip itself is a zdtd mechanic.
    animal_spawn_ring_min: f32 = 48.0,
    animal_spawn_ring_max: f32 = 70.0,
    /// Starter population fraction of the alive cap spawned once near players
    /// shortly after boot (stock fills loaded regions toward their maxcounts
    /// as they load; without it a fresh world stays near-empty until the
    /// first night drip). 0 disables the starter fill.
    initial_population_frac: f32 = 0.25,
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
    /// GameDifficulty 0..5 → zombie HP multiplier (Scavenger..Insane). Stock
    /// tier semantic; numbers zdtd-tuned (R9, no RE pin) - operator policy.
    /// Per-tier scalars because toml_bind is scalar-only.
    difficulty_hp_0: f32 = 0.5,
    difficulty_hp_1: f32 = 0.75,
    difficulty_hp_2: f32 = 1.0,
    difficulty_hp_3: f32 = 1.25,
    difficulty_hp_4: f32 = 1.5,
    difficulty_hp_5: f32 = 2.0,
    /// ZombieMove 0..4 → speed multiplier (walk/jog/run/sprint/nightmare).
    /// Stock tier semantic; numbers zdtd-tuned (R9).
    move_scale_0: f32 = 0.5,
    move_scale_1: f32 = 0.75,
    move_scale_2: f32 = 1.0,
    move_scale_3: f32 = 1.4,
    move_scale_4: f32 = 1.7,
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
    /// Placed-water puddle: how many cells a bucket may spread at the landing
    /// level. The stock mass model limits a pour by mass; this bounds the
    /// approximation so a big flat floor does not flood in one tick.
    puddle_cap: u8 = 8,
};

/// Power-sim tuning (zdtd power grid, R8): fallbacks and cadences where the
/// stock block data or wire facts do not pin a value.
pub const Power = struct {
    /// Battery capacity fallback scale (×MaxPower) when a battery block only
    /// exposes MaxPower.
    battery_capacity_scale: f32 = 10.0,
    /// Initial battery charge as a fraction of capacity on fresh placement.
    battery_initial_charge_frac: f32 = 0.5,
    /// Trigger-plate / tripwire pulse duration (s) when the block sets
    /// duration=Triggered.
    trigger_pulse_s: f32 = 0.5,
};

/// Full rule surface. Carried on World; the TOML overlay mirrors it field for
/// field (RulesOverlay) and mergeOverlay applies the non-null subset.
pub const Rules = struct {
    systems: Systems = .{},
    combat: Combat = .{},
    c2s: C2s = .{},
    glide: Glide = .{},
    ai: Ai = .{},
    bloodmoon: Bloodmoon = .{},
    progression: Progression = .{},
    world: WorldGroup = .{},
    geometry: Geometry = .{},
    worldgen: WorldgenGroup = .{},
    vehicle: Vehicle = .{},
    director: Director = .{},
    difficulty: Difficulty = .{},
    water: Water = .{},
    power: Power = .{},
};

pub const CombatOverlay = struct {
    attack_damage: ?f32 = null,
    attack_range_sq: ?f32 = null,
    attack_cooldown_s: ?f32 = null,
    armor_mitigation_per_piece: ?f32 = null,
    armor_mitigation_cap: ?f32 = null,
    stamina_usage_multiplier: ?f32 = null,
    knockback_speed: ?f32 = null,
    knockback_seconds: ?f32 = null,
};

pub const C2sOverlay = struct {
    eat_units_per_push: ?u8 = null,
    quest_summon_per_request: ?u8 = null,
};

pub const GlideOverlay = struct {
    sink_vy_mps: ?f32 = null,
    item_tag: ?[]const u8 = null,
    fall_sink_vy_mps: ?f32 = null,
};

pub const AiOverlay = struct {
    full_dist_sq: ?f32 = null,
    mid_dist_sq: ?f32 = null,
    sense_dist_sq: ?f32 = null,
    hear_range: ?f32 = null,
    view_cone_half_deg: ?f32 = null,
    sight_light_threshold_min: ?f32 = null,
    sight_light_threshold_max: ?f32 = null,
    smell_radius: ?f32 = null,
    smell_bleed_radius: ?f32 = null,
    crouch_hear_scale: ?f32 = null,
    crouch_sleeper_detect_min: ?f32 = null,
    crouch_sleeper_detect_max: ?f32 = null,
    stealth_light_passive: ?f32 = null,
    combat_noise_radius: ?f32 = null,
    noise_events_per_tick: ?u8 = null,
    stealth_noise_decay: ?f32 = null,
    stealth_noise_curve_a: ?f32 = null,
    stealth_noise_curve_b: ?f32 = null,
    stealth_noise_scale: ?f32 = null,
    stealth_noise_passive: ?f32 = null,
    stealth_attract_sense_scale: ?f32 = null,
    stealth_attract_radius_cap_a: ?f32 = null,
    stealth_attract_radius_cap_b: ?f32 = null,
    stealth_hear_feral_sense: ?f32 = null,
    stealth_hear_detect_us: ?f32 = null,
    stealth_alert_radius: ?f32 = null,
    stealth_sleeper_wake_volume: ?f32 = null,
    stealth_sleeper_volume_decay: ?f32 = null,
    stealth_loud_volume: ?f32 = null,
    stealth_loud_wait_ticks: ?i32 = null,
    explosion_radius: ?f32 = null,
    explosion_block_damage: ?u16 = null,
    explosion_entity_damage: ?f32 = null,
    body_radius: ?f32 = null,
    body_height: ?f32 = null,
    step_height: ?f32 = null,
    jump_height: ?f32 = null,
    jump_delay_s: ?f32 = null,
    gravity: ?f32 = null,
    fall_max_vy: ?f32 = null,
    swim_gravity_per: ?f32 = null,
    swim_drag_y: ?f32 = null,
    swim_speed_frac: ?f32 = null,
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
    timid_danger_distance: ?f32 = null,
    timid_safe_distance: ?f32 = null,
    mount_range_sq: ?f32 = null,
    destroy_area_rng_mod: ?u32 = null,
    revenge_window_s: ?f32 = null,
    no_target_scale: ?f32 = null,
    sleep_dist_mult: ?f32 = null,
    sleep_decision_scale: ?f32 = null,
    sleep_wander_interval_s: ?f32 = null,
    sleep_wander_speed_frac: ?f32 = null,
    fear_scan_cd_s: ?f32 = null,
    move_arrive: ?f32 = null,
    push_range: ?f32 = null,
    push_y_tol: ?f32 = null,
    push_shove: ?f32 = null,
    dig_windup_ticks: ?u8 = null,
    dig_budget_ticks: ?u8 = null,
};

pub const DifficultyOverlay = struct {
    incoming_damage_0: ?f32 = null,
    incoming_damage_1: ?f32 = null,
    incoming_damage_2: ?f32 = null,
    incoming_damage_3: ?f32 = null,
    incoming_damage_4: ?f32 = null,
    incoming_damage_5: ?f32 = null,
    entity_incoming_damage_0: ?f32 = null,
    entity_incoming_damage_1: ?f32 = null,
    entity_incoming_damage_2: ?f32 = null,
    entity_incoming_damage_3: ?f32 = null,
    entity_incoming_damage_4: ?f32 = null,
    entity_incoming_damage_5: ?f32 = null,
};

pub const BloodmoonOverlay = struct {
    party_join_dist: ?f32 = null,
    party_teleport_dist: ?f32 = null,
    party_spawn_dist: ?f32 = null,
    party_enemy_max: ?u32 = null,
    max_parties: ?u32 = null,
    budget_scale: ?f32 = null,
    wave_frac: ?f32 = null,
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
    kill_xp_fallback: ?f32 = null,
    trap_kill_xp_frac: ?f32 = null,
    trap_xp_party_share: ?bool = null,
};

pub const WorldGroupOverlay = struct {
    container_open_range: ?f32 = null,
    topsoil_all_broken: ?bool = null,
    poi_unlock_grace_ticks: ?u32 = null,
};

pub const GeometryOverlay = struct {
    sea_level: ?f32 = null,
    height_scale: ?f32 = null,
    height_offset: ?f32 = null,
    height_ceiling: ?u32 = null,
};

pub const WorldgenOverlay = struct {
    base_height: ?f32 = null,
    height_amp: ?f32 = null,
    min_surface: ?u8 = null,
    max_surface: ?u8 = null,
    squash: ?f32 = null,
    noise_weight: ?f32 = null,
    y_scale: ?f32 = null,
    bedrock_h: ?i32 = null,
};

pub const VehicleOverlay = struct {
    accel_mps2: ?f32 = null,
    reverse_frac: ?f32 = null,
    coast_decay: ?f32 = null,
    steer_deg_per_s: ?f32 = null,
    min_turn_speed_frac: ?f32 = null,
    fuel_per_m: ?f32 = null,
    fuel_cap: ?f32 = null,
    refuel_reach: ?f32 = null,
    gravity: ?f32 = null,
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
    heat_scout_count: ?u32 = null,
    heat_feral_chance: ?f32 = null,
    heat_feral_cd_mult: ?f32 = null,
    heat_event_ticks: ?f32 = null,
    enemy_spawn_ring_min: ?f32 = null,
    enemy_spawn_ring_max: ?f32 = null,
    animal_spawn_ring_min: ?f32 = null,
    animal_spawn_ring_max: ?f32 = null,
    initial_population_frac: ?f32 = null,
    horde_drip_cd: ?f32 = null,
    bloodmoon_horde_drip_cd: ?f32 = null,
    scout_drip_cd: ?f32 = null,
    animal_drip_cd: ?f32 = null,
    bloodmoon_wave_cd: ?f32 = null,
    bloodmoon_hp_mult: ?f32 = null,
    difficulty_hp_0: ?f32 = null,
    difficulty_hp_1: ?f32 = null,
    difficulty_hp_2: ?f32 = null,
    difficulty_hp_3: ?f32 = null,
    difficulty_hp_4: ?f32 = null,
    difficulty_hp_5: ?f32 = null,
    move_scale_0: ?f32 = null,
    move_scale_1: ?f32 = null,
    move_scale_2: ?f32 = null,
    move_scale_3: ?f32 = null,
    move_scale_4: ?f32 = null,
};

pub const SystemsOverlay = struct {
    buffs: ?bool = null,
    director: ?bool = null,
    animals: ?bool = null,
    stealth: ?bool = null,
    ai: ?bool = null,
    vehicles: ?bool = null,
    falling: ?bool = null,
    turrets: ?bool = null,
    despawn: ?bool = null,
    commands: ?bool = null,
};

/// Water leveling overlay: `[rules.water]` binds these (binder-reflected).
pub const WaterOverlay = struct {
    edits_per_tick: ?u8 = null,
    spread_cap: ?u16 = null,
    puddle_cap: ?u8 = null,
};

/// Power-sim overlay: `[rules.power]` binds these (binder-reflected).
pub const PowerOverlay = struct {
    battery_capacity_scale: ?f32 = null,
    battery_initial_charge_frac: ?f32 = null,
    trigger_pulse_s: ?f32 = null,
};

/// All-optional mirror of Rules for mode-pack / zdtd.toml `[rules.*]` sections
/// (ADR 0021 decision 3). Hand-written next to Rules because Zig 0.16's
/// `@Struct` cannot lay out a recursive anonymous overlay type; the parity test
/// below pins the two together so a new rule cannot land without its overlay.
pub const RulesOverlay = struct {
    systems: SystemsOverlay = .{},
    combat: CombatOverlay = .{},
    c2s: C2sOverlay = .{},
    glide: GlideOverlay = .{},
    ai: AiOverlay = .{},
    bloodmoon: BloodmoonOverlay = .{},
    progression: ProgressionOverlay = .{},
    world: WorldGroupOverlay = .{},
    geometry: GeometryOverlay = .{},
    worldgen: WorldgenOverlay = .{},
    vehicle: VehicleOverlay = .{},
    director: DirectorOverlay = .{},
    difficulty: DifficultyOverlay = .{},
    water: WaterOverlay = .{},
    power: PowerOverlay = .{},
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

test "Geometry projection: identity at stock defaults, clamp at extremes" {
    const g: Geometry = .{};
    try std.testing.expect(g.isStock());
    // Identity: elev passes through, ceiling = profile max.
    try std.testing.expectEqual(@as(u32, 0), g.project(0, 255));
    try std.testing.expectEqual(@as(u32, 64), g.project(64, 255));
    try std.testing.expectEqual(@as(u32, 255), g.project(255, 255));
    // Clamps above profile max and below 0.
    try std.testing.expectEqual(@as(u32, 255), g.project(300, 255));
    try std.testing.expectEqual(@as(u32, 0), g.project(-5, 255));

    // Compressed mountains: scale 0.5 halves elevation.
    const half: Geometry = .{ .height_scale = 0.5 };
    try std.testing.expect(!half.isStock());
    try std.testing.expectEqual(@as(u32, 50), half.project(100, 255));
    try std.testing.expectEqual(@as(u32, 127), half.project(255, 255));

    // Sea-level model: offset lifts a relative-elevation source (RealEarth
    // `gameY = sea + elev_m` is source-side; offset here shifts the whole map).
    const lifted: Geometry = .{ .height_offset = 20.0 };
    try std.testing.expectEqual(@as(u32, 120), lifted.project(100, 255));

    // Explicit ceiling beats profile max; sea_level only shapes flat fill.
    const capped: Geometry = .{ .height_ceiling = 100 };
    try std.testing.expectEqual(@as(u32, 100), capped.ceiling(255));
    try std.testing.expectEqual(@as(u32, 100), capped.project(200, 255));
    // 0 ceiling = profile max.
    try std.testing.expectEqual(@as(u32, 255), g.ceiling(255));
    try std.testing.expectEqual(@as(u32, 16383), g.ceiling(16383));
}

test "Geometry validate rejects crash/absurd projection config" {
    try std.testing.expect((Geometry{}).validate() == null);
    // A ceiling above 255 would panic the byte height-plane fill.
    const tall_ceil: Geometry = .{ .height_ceiling = 1000 };
    try std.testing.expect(tall_ceil.validate() != null);
    // Negative scale inverts the world; negative sea level is nonsense.
    const inverted: Geometry = .{ .height_scale = -1.0 };
    try std.testing.expect(inverted.validate() != null);
    const below: Geometry = .{ .sea_level = -5 };
    try std.testing.expect(below.validate() != null);
    // 255 is the byte-plane max and stays valid; negative offsets are legal
    // (lowering the whole world).
    const capped: Geometry = .{ .height_ceiling = 255 };
    try std.testing.expect(capped.validate() == null);
    const lowered: Geometry = .{ .height_offset = -20 };
    try std.testing.expect(lowered.validate() == null);
}

test "WorldgenGroup validate rejects degenerate shaping" {
    try std.testing.expect((WorldgenGroup{}).validate() == null);
    // Reversed band, guarantee-breaking noise weight, non-positive squash.
    const reversed: WorldgenGroup = .{ .min_surface = 200, .max_surface = 12 };
    try std.testing.expect(reversed.validate() != null);
    const heavy: WorldgenGroup = .{ .noise_weight = 1.0 };
    try std.testing.expect(heavy.validate() != null);
    const heavy2: WorldgenGroup = .{ .noise_weight = 1.5 };
    try std.testing.expect(heavy2.validate() != null);
    const flat: WorldgenGroup = .{ .squash = 0 };
    try std.testing.expect(flat.validate() != null);
    const above: WorldgenGroup = .{ .bedrock_h = -1 };
    try std.testing.expect(above.validate() != null);
    // Adjacent band (12..13) is valid; the interpolation margin keeps heights
    // inside it by construction.
    const thin: WorldgenGroup = .{ .min_surface = 12, .max_surface = 13 };
    try std.testing.expect(thin.validate() == null);
}
