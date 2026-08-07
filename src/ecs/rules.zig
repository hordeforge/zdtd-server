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
};

/// Zombie AI tuning read by the systems.zig task table and the despawn pass.
pub const Ai = struct {
    /// Full-sim range, squared blocks (lodScale step 3).
    full_dist_sq: f32 = 64.0 * 64.0,
    /// Mid-sim range, squared blocks (lodScale step 2).
    mid_dist_sq: f32 = 225.0,
    /// Sense range, squared blocks. Policy: no per-entity stock equivalent.
    sense_dist_sq: f32 = 48.0 * 48.0,
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

/// Survival simulation tuning (GAP 22). The stock loop applies the
/// FoodChangeOT/WaterOT/HealthChangeOT passive effects through Stat.Tick,
/// whose per-effect defaults are not in the V3.1.0 IL corpus; these rates are
/// policy tunables (ADR 0021) that reproduce the stock feel (full Food drains
/// in ~2 in-game days at 60-min days). Eat/Drink restores on top.
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
};

/// Placeholder group: added as constants move; no fields invented.
pub const WorldGroup = struct {};

/// Full rule surface. Carried on World; the TOML overlay mirrors it field for
/// field (RulesOverlay) and mergeOverlay applies the non-null subset.
pub const Rules = struct {
    combat: Combat = .{},
    ai: Ai = .{},
    bloodmoon: Bloodmoon = .{},
    progression: Progression = .{},
    world: WorldGroup = .{},
};

pub const CombatOverlay = struct {
    attack_damage: ?f32 = null,
    attack_range_sq: ?f32 = null,
    attack_cooldown_s: ?f32 = null,
};

pub const AiOverlay = struct {
    full_dist_sq: ?f32 = null,
    mid_dist_sq: ?f32 = null,
    sense_dist_sq: ?f32 = null,
    despawn_dist_sq: ?f32 = null,
    chase_speed: ?f32 = null,
    wander_speed: ?f32 = null,
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
};

pub const WorldGroupOverlay = struct {};

/// All-optional mirror of Rules for mode-pack / zdtd.toml `[rules.*]` sections
/// (ADR 0021 decision 3). Hand-written next to Rules because Zig 0.16's
/// `@Struct` cannot lay out a recursive anonymous overlay type; the parity test
/// below pins the two together so a new rule cannot land without its overlay.
pub const RulesOverlay = struct {
    combat: CombatOverlay = .{},
    ai: AiOverlay = .{},
    bloodmoon: BloodmoonOverlay = .{},
    progression: ProgressionOverlay = .{},
    world: WorldGroupOverlay = .{},
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
    , std.testing.allocator);
    try std.testing.expectEqual(@as(?f32, 12.0), o.combat.attack_damage);
    try std.testing.expectEqual(@as(?f32, null), o.combat.attack_range_sq);
    try std.testing.expectEqual(@as(?f32, 3600.0), o.ai.sense_dist_sq);
    try std.testing.expectEqual(@as(?u32, 40), o.bloodmoon.party_enemy_max);
    try std.testing.expectEqual(@as(?u32, 3), o.bloodmoon.max_parties);
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
    try std.testing.expectEqual(@as(f32, 80.0), r.bloodmoon.party_join_dist);
    try std.testing.expectEqual(@as(f32, 150.0), r.bloodmoon.party_teleport_dist);
    try std.testing.expectEqual(@as(f32, 40.0), r.bloodmoon.party_spawn_dist);
    try std.testing.expectEqual(@as(u32, 30), r.bloodmoon.party_enemy_max);
    try std.testing.expectEqual(@as(u32, 8), r.bloodmoon.max_parties);
}
