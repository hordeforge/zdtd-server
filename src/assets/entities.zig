//! entityclasses.xml loader: name → Unity Mono hash, kind, HP, death loot list.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const unity_hash = @import("unity_hash.zig");
const components = @import("../ecs/components.zig");
const buffs = @import("buffs.zig");
const requirements = @import("requirements.zig");
const paths = @import("paths.zig");

/// Storage cap on parsed entity classes, a zdtd bound rather than a stock rule.
/// Measured against V3.2.0 `Data/Config` (2026-09-04): stock entityclasses.xml
/// defines **293**, so this holds stock plus a substantial modlet set.
pub const max_entities_defs: usize = 512;

/// Stock `<property class="Explosion">` blast params (RE entity-ai.md §9.x):
/// RadiusBlocks / RadiusEntities / BlockDamage / EntityDamage plus the
/// DamageBonus material multipliers (materials.xml damage_category keys, e.g.
/// `earth → 0`: terrain survives the cop blast). 0 = unset, which leaves the
/// blast on the Rules floor (rule 11: per-entity stock data wins where present).
pub const ExplosionDef = struct {
    radius_blocks: f32 = 0,
    radius_entities: f32 = 0,
    block_damage: f32 = 0,
    entity_damage: f32 = 0,
    /// DamageBonus category multipliers; parallel arrays, first body carrying
    /// a DamageBonus wins (stock ships it on the base class only).
    bonus_cat: [4][]const u8 = .{ "", "", "", "" },
    bonus_mult: [4]f32 = .{ 1, 1, 1, 1 },
    bonus_n: u8 = 0,
};

pub const EntityDef = struct {
    name: []const u8 = "",
    /// Unity Mono string.GetHashCode (EntityClass.list key).
    hash: i32 = 0,
    /// The class `Tags` property (`EntityClass::PropTags`, read from the
    /// resolved DynamicProperties at EntityClass.il IL_111F). Inherited through
    /// `extends` exactly like `EntityClass::CopyFrom` IL=171, which copies the
    /// parent's property map. Read by `EntityTagCompare` (requirements.zig) and
    /// by `inferKind` below.
    tags: []const u8 = "",
    max_hp: f32 = 40,
    kind: components.Kind = .zombie,
    /// Loot.xml container name for the death bag (LootDropEntityClass resolved
    /// through the bag class's own LootList, e.g. zombieBoe → zPackReg); empty
    /// if none.
    loot_list: []const u8 = "",
    /// LootDropProb: chance a death drops the loot bag (stock regular zombie
    /// .04). 1.0 when unset.
    loot_drop_prob: f32 = 1.0,
    /// UserSpawnType != None (Menu/Console).
    spawnable: bool = false,
    is_enemy: bool = true,
    /// Inherited AITask-* list contains an attack task (see resolvedAiAttacks):
    /// false only for classes whose task list exists without one (timid
    /// animals), true otherwise so brainless classes keep the zombie default.
    ai_attack: bool = true,
    /// Inherited AITask list as TaskId bits. 0 = no XML list (native table).
    /// Bit 15 (`ai_task_list_set`) means a list was parsed.
    ai_tasks: u16 = 0,
    /// EAIRangedAttackTarget SetData params from the class AITask entry
    /// (stock ctor/Init defaults when the class omits them): the between-shot
    /// cooldown, the aim+telegraph sequence length, the release delay after
    /// the telegraph anim, the in-range window plus its unreachable extension
    /// (not modelled: zdtd has no moveHelper unreachable flags, so the window
    /// stays [min, max]), and the telegraph AnimType the task plays through
    /// `StartAnimAction(3000 + start_anim + 1)`.
    ranged_cooldown_s: f32 = 3,
    ranged_duration_s: f32 = 20,
    ranged_release_delay_s: f32 = 0.5,
    ranged_min_dist: f32 = 4,
    ranged_max_dist: f32 = 25,
    ranged_unreachable_dist: f32 = 0,
    ranged_start_anim: i32 = -1,
    /// entityclasses MoveSpeedAggro max = night chase speed (m/s scale); the
    /// stock XML comment on the prop ("min/max (like day or night)") pins the
    /// split, matching GetMoveSpeedAggro dark → aggroMax (passive 134). 0 =
    /// unset.
    chase_speed: f32 = 0,
    /// MoveSpeedAggro min = day chase speed (GetMoveSpeedAggro day branch,
    /// passive 133). A single-value prop applies to both. 0 = unset (falls to
    /// chase_speed).
    chase_speed_day: f32 = 0,
    /// MoveSpeed = day wander shamble (GetMoveSpeed day branch, passive 135).
    /// 0 = unset.
    wander_speed: f32 = 0,
    /// MoveSpeedNight = night wander shamble (GetMoveSpeed dark branch,
    /// passive 133); stock seeds moveSpeedNight from moveSpeed when the prop
    /// is absent (entity-ai.md 3312). 0 = unset (falls to wander_speed).
    wander_speed_night: f32 = 0,
    /// entityclasses MoveSpeedRand "min,max" (stock zombieTemplateMale
    /// "-.2, .25"): the per-entity roll ADDED to the day chase speed when
    /// moveSpeedAggro < 1 (clamped min 0.1, capped at the aggro max; RE
    /// entity-ai.md 3318-3320). 0,0 = unset (no roll).
    move_speed_rand_min: f32 = 0,
    move_speed_rand_max: f32 = 0,
    /// entityclasses JumpMaxDistance "min,max" (stock zombieTemplateMale
    /// "2.8, 3.9", zombieSpider "7, 9", animalMountainLion "6, 7"; EntityClass
    /// cctor default (1.9, 2.1), entity-ai.md 3363): EAILeap's jumpMaxDistance
    /// range bound, rolled per spawn into ClassId.jump_max.
    jump_max_min: f32 = 1.9,
    jump_max_max: f32 = 2.1,
    /// TimeStayAfterDeath seconds a corpse lingers (30 zombies, 300 animals).
    time_stay: f32 = 0,
    /// HandItem name (items.xml melee hand); empty = unset.
    hand_item: []const u8 = "",
    /// Resolved Action0 DamageEntity for hand_item (0 = unresolved).
    attack_damage: f32 = 0,
    /// entityclasses SightRange in metres (stock ships 27, 30, 40 per class).
    /// 0 = unset, which leaves the sim on the Rules floor.
    sight_range: f32 = 0,
    /// `SetNearestEntityAsTarget class=` player entry (type, hearDistMax,
    /// seeDistMax triples; `EAISetNearestEntityAsTarget` targetClasses parse
    /// IL). hear 0 reads 50 stock-side; see 0 = unset here (the sense path
    /// falls back to sight_range). 0,0 = no player entry parsed.
    target_player_hear: f32 = 0,
    target_player_see: f32 = 0,
    /// `SetAsTargetIfHurt class=` victim-class filter (comma names;
    /// `EAISetAsTargetIfHurt` SetData IL splits on comma). Bit 0 = a
    /// class-filtered entry exists, bit 1 = EntityPlayer named, bit 2 =
    /// EntityBandit named, bit 3 = EntityEnemyAnimal named. 0 = no
    /// SetAsTargetIfHurt entry (bare entries without class= keep the legacy
    /// always-retarget path); nonzero with bit 0 set gates revenge on the
    /// named classes.
    hurt_target_classes: u8 = 0,
    /// `BlockIf` target-list condition (`EAIBlockIf` SetData IL: `data=`
    /// "condition=<type> <op> <value>" triples stepped by 3, `eType` =
    /// None/Alert/Investigate, `eOp` = None/e/ne). Only the alert arm has a
    /// sim state (`ai.alert`); an investigate arm has no model (zdtd
    /// investigate spots are one-shot paths, not latched positions), so a
    /// class whose BlockIf names only investigate reads as unset (0). Bit 0 =
    /// a BlockIf entry exists, bit 1 = its conditions gate sense acquisition
    /// while the entity is unalerted (the stock row is `alert e 0` on the
    /// hostile-animal template: the executing BlockIf holds MutexBits=1 over
    /// SetNearestEntityAsTarget). 0 = no BlockIf entry.
    block_if_alert_only: u8 = 0,
    /// entityclasses SightLightThreshold "min,max" (stock zombieTemplateMale
    /// "-2,150": "how well lit you have to be for the zombie to see you at
    /// min,max range"; the EntityClass cctor default is 30/100). The pair
    /// spans FastLerp over dist/sightRange in CanSeeStealth. 0,0 = unset →
    /// Rules floor.
    sight_light_min: f32 = 0,
    sight_light_max: f32 = 0,
    /// entityclasses SleeperSightToWakeMin/Max "min,max" roll ranges (stock
    /// zombieTemplateMale "-40,5" / "340,480"): each sleeping zombie rolls
    /// its GetSleeperDisturbedLevel wake-threshold pair from these at spawn.
    /// 0 = unset → the stock default ranges (world.spawnSleeperDef).
    sleeper_wake_near_min: f32 = 0,
    sleeper_wake_near_max: f32 = 0,
    sleeper_wake_far_min: f32 = 0,
    sleeper_wake_far_max: f32 = 0,
    /// entityclasses MaxViewAngle in degrees, full cone angle (stock default
    /// 180 = only excludes targets strictly behind; the sense gate halves it
    /// like EntityAlive.IsInFrontOfMe). 0 = unset → Rules floor.
    view_angle_deg: f32 = 0,
    /// entityclasses ExplodeHealthThreshold (Demolition): the cop primes when
    /// health drops below max*threshold. 0 = no explosion (the class has no
    /// ExplosionData). RE entity-ai.md EntityZombieCop.
    explode_threshold: f32 = 0,
    /// entityclasses ExplodeDelay seconds (Demolition prime-to-explode
    /// delay). 0.5 stock default when unset.
    explode_delay_s: f32 = 0.5,
    /// entityclasses DismemberMultiplierHead/Arms/Legs (stock per-template
    /// values, e.g. feral .7, radiated .4; the EntityClass cctor default is 1
    /// for all three, RE EntityClass Init IL=0xBBF/0xBE0/0xC01). They scale the
    /// dismember chance per body region in EntityAlive.GetDismemberChance.
    /// 0 = unset (class inherits the template through resolveProp; a literal
    /// stock 0 would also read as unset, which matches the cctor).
    dismember_head: f32 = 0,
    dismember_arms: f32 = 0,
    dismember_legs: f32 = 0,
    /// entityclasses LegCrippleScale (stock zombieTemplate 2): "scales chance
    /// to cripple (percent of health that a hit does is the chance)". The
    /// struct default 0 matches stock's implicit default (no ParseFloat
    /// fallback in EntityClass Init), so 0 = unset.
    leg_cripple_scale: f32 = 0,
    /// entityclasses LegCrawlerThreshold (stock zombieTemplate 0, "at like
    /// .175 nearly every zombie knocked down from a leg hit turns into a
    /// crawler"): damage fraction above which a leg hit crawlers the zombie.
    /// 0 = unset, same implicit default as stock.
    leg_crawler_threshold: f32 = 0,
    /// <property class="Explosion"> blast params (radius/damages/bonuses),
    /// Extends-resolved per field. Unset fields stay 0 -> Rules floor.
    explosion: ExplosionDef = .{},
    /// entityclasses `Buffs="a,b"`: buffs stock applies to every instance of the
    /// class when it enters the game (`EntityClass` ctor + the class's
    /// onSelfEnteredGame rows). The player class carries the status checks.
    buffs: []const []const u8 = &.{},
    /// The class's `<triggered_effect>` rows (own effect_groups plus Extends
    /// ancestors'): radiated regen on damaged, spawn heal, hazard timers.
    triggered: []const buffs.Triggered = &.{},
    /// entityclasses `PhysicalDamageResist` (passive 41) percent: the stock
    /// armoured classes (zombieSoldier 50, zombieDemolition 60, the swarms 20)
    /// take that much less damage from every source. Applied where the SERVER
    /// computes the damage (turret fire and the deferred accumulator); a C2S
    /// claim already carries the client's own resist-adjusted strength, so the
    /// claim path must not reduce it again. 0 = no row (unarmoured).
    phys_resist: f32 = 0,
    /// ExperienceGain kill XP (stock ships 130 rabbit .. 2500 zombieBear;
    /// most zombies resolve through the `^xpNormal01`-style replace_properties
    /// ladder). 0 = unset, which leaves the award at the caller's flat floor.
    xp_gain: f32 = 0,
};

pub const EntityTable = struct {
    defs: []const EntityDef = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    source: enum { builtin, xml } = .builtin,

    pub fn deinit(self: *EntityTable) void {
        arena_util.destroyHolder(&self.arena_ptr);
        self.* = builtin();
    }

    pub fn builtin() EntityTable {
        return .{ .defs = &builtin_defs, .source = .builtin };
    }

    /// The class whose Unity name hash matches (the PlayerId/EntityClass wire
    /// keys are these hashes; see unity_hash.zig).
    pub fn byHash(self: *const EntityTable, hash: i32) ?EntityDef {
        if (hash == 0) return null;
        for (self.defs) |d| {
            if (d.hash == hash) return d;
        }
        return null;
    }

    pub fn byName(self: *const EntityTable, name: []const u8) ?EntityDef {
        for (self.defs) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    /// Default spawnable walker (zombieBoe or first zombie).
    pub fn defaultZombie(self: *const EntityTable) EntityDef {
        if (self.byName("zombieBoe")) |d| return d;
        for (self.defs) |d| {
            if (d.kind == .zombie and d.spawnable) return d;
        }
        // XML catalog: no silent builtin HP/speed row (wrong class worse than none).
        if (self.source != .builtin) return .{ .name = "", .kind = .zombie, .spawnable = false, .max_hp = 0 };
        return builtin_defs[1];
    }

    pub fn defaultAnimal(self: *const EntityTable) EntityDef {
        if (self.byName("animalStag")) |d| return d;
        for (self.defs) |d| {
            if (d.kind == .animal and d.spawnable) return d;
        }
        if (self.source != .builtin) return .{ .name = "", .kind = .animal, .spawnable = false, .max_hp = 0, .is_enemy = false };
        return builtin_defs[2];
    }

    /// Default trader NPC (npcTraderJen or the first trader def). Null when the
    /// loaded entityclasses have no trader at all; callers keep the offline
    /// placeholder then, since no trader POI spawns without a real game-dir.
    pub fn defaultTrader(self: *const EntityTable) ?EntityDef {
        if (self.byName("npcTraderJen")) |d| return d;
        for (self.defs) |d| {
            if (d.kind == .trader) return d;
        }
        return null;
    }
};

pub const builtin_defs = [_]EntityDef{
    .{
        .name = "playerMale",
        .hash = unity_hash.class_player_male,
        // Stock entityclasses.xml playerMale `Tags` (the builtin catalog is the
        // no-game-dir floor; the XML value wins when data loads).
        .tags = "entity,player,human",
        .max_hp = 100,
        .kind = .player,
        .spawnable = false,
        .is_enemy = false,
    },
    .{
        .name = "zombieBoe",
        .hash = unity_hash.class_zombie_boe,
        .tags = "entity,zombie,walker",
        .max_hp = 40,
        .kind = .zombie,
        .loot_list = "EntityLootContainerRegular",
        .spawnable = true,
        .is_enemy = true,
    },
    .{
        .name = "animalStag",
        .hash = 0, // filled when xml loads; builtin hash computed at test time
        .max_hp = 30,
        .kind = .animal,
        .spawnable = true,
        .is_enemy = false,
    },
    .{
        .name = "npcTraderJen",
        .hash = unity_hash.class_npc_trader_jen,
        .max_hp = 9999,
        .kind = .trader,
        .spawnable = true,
        .is_enemy = false,
    },
};

const RawClass = struct {
    name: []const u8,
    extends: ?[]const u8,
    props: std.StringHashMapUnmanaged([]const u8),
    /// Inner rows of the nested `<property class="Explosion">` block
    /// (arena-owned; captured whole so Extends resolution can read per-field
    /// overrides). Null = the class never explodes.
    explosion: ?[]const u8 = null,
    /// The class's own `<effect_group>` inner bodies (arena-owned slices),
    /// for triggered_effect rows (radiated regen, spawn heal, hazard
    /// timers). Extends ancestors contribute theirs at assembly.
    effect_groups: []const []const u8 = &.{},
};

/// Collect a class body's top-level `<effect_group>` inners (arena-owned).
/// Triggered rows scan from these at EntityDef assembly (own groups plus
/// Extends ancestors').
fn collectEffectGroups(arena: std.mem.Allocator, body: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var ij: usize = 0;
    while (ij < body.len) {
        const lt = std.mem.findPos(u8, body, ij, "<effect_group") orelse break;
        const gt = std.mem.findPos(u8, body, lt, ">") orelse break;
        if (gt > lt and body[gt - 1] == '/') {
            ij = gt + 1;
            continue;
        }
        const close = std.mem.findPos(u8, body, gt, "</effect_group>") orelse break;
        try out.append(arena, body[gt + 1 .. close]);
        ij = close + "</effect_group>".len;
    }
    return out.items;
}

/// Scan one class's effect_group inners (own + Extends ancestors, own
/// first) for triggered_effect rows through the shared scanner. Stock merges
/// MinEvents down the EntityClass chain; ancestors contribute after the
/// child's own rows.
fn scanClassTriggered(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    classes: *const std.StringHashMapUnmanaged(RawClass),
    name: []const u8,
    pool: *std.ArrayList(buffs.Triggered),
    reqs: *std.ArrayList(requirements.Requirement),
    ranges: *std.ArrayList(struct { usize, usize }),
) !void {
    var cur: ?[]const u8 = name;
    var hops: usize = 0;
    while (cur != null and hops < 8) : (hops += 1) {
        const rc = classes.get(cur.?) orelse break;
        for (rc.effect_groups) |ginner| {
            var group_reqs: std.ArrayList(requirements.Requirement) = .empty;
            defer group_reqs.deinit(allocator);
            try requirements.scanChildren(allocator, arena, ginner, 0, ginner.len, &group_reqs);
            var seen: usize = pool.items.len;
            try buffs.scanTriggeredRows(
                allocator,
                arena,
                ginner,
                0,
                ginner.len,
                group_reqs.items,
                pool,
                reqs,
                ranges,
                std.math.maxInt(usize),
                &seen,
            );
        }
        cur = rc.extends;
    }
}

fn resolveProp(
    classes: *const std.StringHashMapUnmanaged(RawClass),
    name: []const u8,
    key: []const u8,
    depth: u8,
) ?[]const u8 {
    if (depth > max_extends_depth) return null;
    const rc = classes.get(name) orelse return null;
    if (rc.props.get(key)) |v| return v;
    if (rc.extends) |ex| return resolveProp(classes, ex, key, depth + 1);
    return null;
}

/// Inner `<property name=K value=V>` lookup inside a captured Explosion body.
fn explosionField(body: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.findPos(u8, body, i, "<property")) |ptag| {
        i = ptag + 9;
        const pname = xml.attr(body, ptag, "name") orelse continue;
        if (!std.mem.eql(u8, pname, key)) continue;
        return xml.attr(body, ptag, "value");
    }
    return null;
}

/// DamageBonus children of an Explosion body (`<property class="DamageBonus">`
/// with `<property name="<category>" value="<mult>">` rows; categories are
/// materials.xml damage_category keys). Stock ships at most one entry.
fn explosionBonuses(body: []const u8, out: *ExplosionDef) void {
    const bt = std.mem.findPos(u8, body, 0, "<property class=\"DamageBonus\"") orelse return;
    const gt = std.mem.findPos(u8, body, bt, ">") orelse return;
    const close = std.mem.findPos(u8, body, gt, "</property>") orelse return;
    const bbody = body[gt + 1 .. close];
    var i: usize = 0;
    while (std.mem.findPos(u8, bbody, i, "<property")) |ptag| {
        i = ptag + 9;
        const pname = xml.attr(bbody, ptag, "name") orelse continue;
        const pval = xml.attr(bbody, ptag, "value") orelse continue;
        if (out.bonus_n >= out.bonus_cat.len) break;
        if (xml.parseF32(pval)) |f| {
            // A crafted negative/oversized value must not heal blocks or
            // insta-clear the map; clamp to [0, 100].
            if (f >= 0 and f <= 100) {
                out.bonus_cat[out.bonus_n] = pname;
                out.bonus_mult[out.bonus_n] = f;
                out.bonus_n += 1;
            }
        }
    }
}

/// Extends-resolved `<property class="Explosion">` block: walk the chain from
/// the class up, first non-empty per field wins (the feral/radiated/infernal
/// tiers override only BlockDamage/EntityDamage). Bonuses come from the first
/// body carrying a DamageBonus. Null when no class in the chain explodes.
fn resolveExplosion(
    classes: *const std.StringHashMapUnmanaged(RawClass),
    name: []const u8,
) ?ExplosionDef {
    var out: ExplosionDef = .{};
    var found = false;
    var cur: ?[]const u8 = name;
    var depth: u8 = 0;
    while (cur) |cn| : (depth += 1) {
        if (depth > max_extends_depth) break;
        const rc = classes.get(cn) orelse break;
        const eb = rc.explosion orelse {
            cur = rc.extends;
            continue;
        };
        found = true;
        if (out.radius_blocks == 0) if (explosionField(eb, "RadiusBlocks")) |v| {
            if (xml.parseF32(v)) |f| {
                if (f > 0 and f <= 64) out.radius_blocks = f;
            }
        };
        if (out.radius_entities == 0) if (explosionField(eb, "RadiusEntities")) |v| {
            if (xml.parseF32(v)) |f| {
                if (f > 0 and f <= 64) out.radius_entities = f;
            }
        };
        if (out.block_damage == 0) if (explosionField(eb, "BlockDamage")) |v| {
            if (xml.parseF32(v)) |f| {
                if (f > 0 and f <= 1_000_000) out.block_damage = f;
            }
        };
        if (out.entity_damage == 0) if (explosionField(eb, "EntityDamage")) |v| {
            if (xml.parseF32(v)) |f| {
                if (f > 0 and f <= 1_000_000) out.entity_damage = f;
            }
        };
        if (out.bonus_n == 0) explosionBonuses(eb, &out);
        cur = rc.extends;
    }
    return if (found) out else null;
}

fn parseBoolLoose(s: []const u8) bool {
    return std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "True") or std.mem.eql(u8, s, "1");
}

/// First token of one AITask list entry (pipe form carries `class=` / `data=`
/// after the name). Empty / RangedAttackTarget stay unmapped:
/// RangedAttackTarget has no native task yet (measured 2026-09-22, entity-ai.md
/// census: five acid-spitter zombies; its delivery contract is RE-closed but
/// the task and its projectile flight are not wired). Leap ships: EAILeap on
/// zombieSpider (pounce) and animalMountainLion (AITask-1, legs=4).
fn taskNameToId(name: []const u8) ?components.TaskId {
    if (std.mem.eql(u8, name, "BreakBlock")) return .break_block;
    if (std.mem.eql(u8, name, "DestroyArea")) return .destroy_area;
    if (std.mem.eql(u8, name, "ApproachAndAttackTarget")) return .approach_attack;
    if (std.mem.eql(u8, name, "Territorial")) return .territorial;
    if (std.mem.eql(u8, name, "ApproachDistraction")) return .approach_distraction;
    if (std.mem.eql(u8, name, "ApproachSpot")) return .approach_spot;
    if (std.mem.eql(u8, name, "Leap")) return .leap;
    if (std.mem.eql(u8, name, "RangedAttackTarget")) return .ranged_attack_target;
    if (std.mem.eql(u8, name, "RunawayWhenHurt")) return .runaway;
    if (std.mem.eql(u8, name, "RunawayFromEntity")) return .runaway;
    if (std.mem.eql(u8, name, "Look")) return .look;
    if (std.mem.eql(u8, name, "Wander")) return .wander;
    return null;
}

fn orTaskName(mask: *u16, raw: []const u8) void {
    const tok = std.mem.trim(u8, raw, " \t\r\n");
    if (tok.len == 0) return;
    var name = tok;
    if (std.mem.findScalar(u8, tok, ' ')) |sp| name = tok[0..sp];
    if (std.mem.findScalar(u8, name, '|')) |bar| name = name[0..bar];
    if (name.len == 0) return;
    if (taskNameToId(name)) |id| {
        mask.* |= components.aiTaskBit(id);
    }
}

/// One parsed `SetNearestEntityAsTarget class=` player triple (hear/see
/// distances in metres; hear 0 reads 50 stock-side per the targetClasses
/// parse IL, see 0 = unset).
/// Extends-chain recursion limit. A cycle or a pathological template chain
/// stops the walk instead of spinning; stock chains are a handful deep.
const max_extends_depth: u8 = 24;

pub const TargetPlayerSense = struct {
    hear: f32 = 0,
    see: f32 = 0,
};

/// Walk the Extends chain like resolveProp, pulling the first `AITarget`
/// entry that `parse` accepts. `AITarget` pipe blobs and numbered
/// `AITarget-N` props both count; a child pipe blob replaces the parent list
/// (a pipe with no accepted entry stops the walk), numbered keys merge upward
/// (same rule as resolvedAiTasks). Null when no class in the chain has one.
fn resolvedAiTargetEntry(
    comptime T: type,
    comptime parse: fn ([]const u8) ?T,
    classes: *const std.StringHashMapUnmanaged(RawClass),
    name: []const u8,
) ?T {
    var cur: ?[]const u8 = name;
    var depth: u8 = 0;
    while (cur) |cn| : (depth += 1) {
        if (depth > max_extends_depth) break;
        const rc = classes.get(cn) orelse break;
        var numbered: ?T = null;
        var it = rc.props.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            const is_pipe = std.mem.eql(u8, key, "AITarget");
            const is_numbered = !is_pipe and std.mem.startsWith(u8, key, "AITarget-");
            if (!is_pipe and !is_numbered) continue;
            var rest = e.value_ptr.*;
            while (rest.len > 0) {
                const cut = std.mem.findScalar(u8, rest, '|') orelse rest.len;
                if (parse(std.mem.trim(u8, rest[0..cut], " \t\r\n"))) |v| {
                    if (is_pipe) return v;
                    if (numbered == null) numbered = v;
                }
                if (cut >= rest.len) break;
                rest = rest[cut + 1 ..];
            }
            if (is_pipe) return numbered;
        }
        if (numbered) |v| return v;
        cur = rc.extends;
    }
    return null;
}

/// First `SetNearestEntityAsTarget` EntityPlayer triple in the Extends chain.
fn resolvedTargetPlayerSense(
    classes: *const std.StringHashMapUnmanaged(RawClass),
    name: []const u8,
) ?TargetPlayerSense {
    return resolvedAiTargetEntry(TargetPlayerSense, parseTargetPlayerEntry, classes, name);
}

/// Split an AI task entry into its task name and the trimmed argument tail.
/// The tail is empty when the entry carries no arguments.
fn splitTaskEntry(entry: []const u8) struct { []const u8, []const u8 } {
    const parts = std.mem.cutScalar(u8, entry, ' ') orelse return .{ entry, "" };
    return .{ parts[0], std.mem.trim(u8, parts[1], " \t") };
}

/// Parse one `SetNearestEntityAsTarget class=...` entry for its EntityPlayer
/// triple. Grammar (targetClasses parse IL): comma-separated
/// `type,hear,see` triples stepped by 3; the player triple's hear 0 reads 50
/// stock-side. Null unless the entry names the player type.
fn parseTargetPlayerEntry(entry: []const u8) ?TargetPlayerSense {
    const name, const data = splitTaskEntry(entry);
    if (!std.mem.eql(u8, name, "SetNearestEntityAsTarget")) return null;
    const marker = "class=";
    const ci = std.mem.find(u8, data, marker) orelse return null;
    const list = data[ci + marker.len ..];
    var parts: [64][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |p| {
        if (n >= parts.len) break;
        parts[n] = std.mem.trim(u8, p, " \t");
        n += 1;
    }
    var i: usize = 0;
    while (i + 1 < n) : (i += 3) {
        if (!std.mem.eql(u8, parts[i], "EntityPlayer")) continue;
        const hear: f32 = std.fmt.parseFloat(f32, parts[i + 1]) catch 0;
        const see: f32 = if (i + 2 < n) std.fmt.parseFloat(f32, parts[i + 2]) catch 0 else 0;
        return .{ .hear = if (hear == 0) 50 else hear, .see = see };
    }
    return null;
}

/// Parse one `SetAsTargetIfHurt class=...` entry into the victim-class bit
/// set (bit 0 = filtered entry exists, bit 1 = EntityPlayer, bit 2 =
/// EntityBandit, bit 3 = EntityEnemyAnimal; `EAISetAsTargetIfHurt` SetData IL
/// splits `class` on comma). Null unless the entry is a SetAsTargetIfHurt
/// that carries a `class=` filter; a bare entry keeps the legacy
/// always-retarget path, which the resolver reports as 0 bits.
fn parseHurtTargetClasses(entry: []const u8) ?u8 {
    const name, const data = splitTaskEntry(entry);
    if (!std.mem.eql(u8, name, "SetAsTargetIfHurt")) return null;
    const marker = "class=";
    const ci = std.mem.find(u8, data, marker) orelse return null;
    var bits: u8 = 1;
    var it = std.mem.splitScalar(u8, data[ci + marker.len ..], ',');
    while (it.next()) |p| {
        const c = std.mem.trim(u8, p, " \t");
        if (std.mem.eql(u8, c, "EntityPlayer")) bits |= 2;
        if (std.mem.eql(u8, c, "EntityBandit")) bits |= 4;
        if (std.mem.eql(u8, c, "EntityEnemyAnimal")) bits |= 8;
    }
    return bits;
}

/// Parse one `BlockIf` entry's `data=` condition list into the alert-gate
/// bits (bit 0 = a BlockIf entry exists, bit 1 = an alert arm that gates
/// sense acquisition while unalerted). Grammar (`EAIBlockIf` SetData IL):
/// "condition=<type> <op> <value>" triples stepped by 3, whitespace split;
/// `eType` = None/Alert/Investigate, `eOp` = None/e/ne (eOp None warns
/// stock-side and never matches). Only the alert arm maps to sim state
/// (`ai.alert`); investigate has no latched model here (spots are one-shot
/// paths), so an investigate-only entry returns bit 0 alone, which the sense
/// gate reads as unset. Null unless the entry is BlockIf. A BlockIf without
/// `data=` returns bit 0 alone (stock parses zero conditions, so
/// CanExecute never fires and nothing is blocked).
fn parseBlockIfAlert(entry: []const u8) ?u8 {
    const name, const data = splitTaskEntry(entry);
    if (!std.mem.eql(u8, name, "BlockIf")) return null;
    const marker = "condition=";
    const ci = std.mem.find(u8, data, marker) orelse return 1;
    var bits: u8 = 1;
    // Whitespace-split tokens after `condition=`; a trailing `data=` key on a
    // numbered prop (e.g. AITarget-2's own key) never appears here because the
    // entry is already cut at the pipe.
    var toks: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitAny(u8, data[ci + marker.len ..], " \t");
    while (it.next()) |p| {
        const tok = std.mem.trim(u8, p, " \t");
        if (tok.len == 0) continue;
        if (n >= toks.len) break;
        toks[n] = tok;
        n += 1;
    }
    var i: usize = 0;
    while (i + 1 < n) : (i += 3) {
        // The stock row is `alert e 0`: unalerted evaluates true, so the
        // executing BlockIf holds the target mutex over sense acquisition.
        // Any alert arm (e or ne, any value) marks the class gated; the gate
        // itself only models the stock row's unalerted shape.
        if (std.mem.eql(u8, toks[i], "alert")) bits |= 2;
    }
    return bits;
}

/// BlockIf alert-gate bits for the class, 0 when the chain has no BlockIf.
fn resolvedBlockIfAlert(
    classes: *const std.StringHashMapUnmanaged(RawClass),
    name: []const u8,
) u8 {
    return resolvedAiTargetEntry(u8, parseBlockIfAlert, classes, name) orelse 0;
}

/// SetAsTargetIfHurt victim-class bits for the class, 0 when the chain has no
/// class-filtered entry (the legacy always-retarget path).
fn resolvedHurtTargetClasses(
    classes: *const std.StringHashMapUnmanaged(RawClass),
    name: []const u8,
) u8 {
    return resolvedAiTargetEntry(u8, parseHurtTargetClasses, classes, name) orelse 0;
}
/// EAIRangedAttackTarget SetData params read from the winning class AITask
/// entry (`RangedAttackTarget itemType=1;cooldown=...`, entityclasses.xml;
/// defaults are the stock ctor/Init values: startAnimType -1, releaseDelay
/// 0.5, minRange 4, maxRange 25, cooldown 3, attackDuration 20).
pub const RangedParams = struct {
    cooldown_s: f32 = 3,
    duration_s: f32 = 20,
    release_delay_s: f32 = 0.5,
    min_dist: f32 = 4,
    max_dist: f32 = 25,
    unreachable_dist: f32 = 0,
    start_anim: i32 = -1,
};

/// Parse the `k=v;k=v` tail of a `RangedAttackTarget` list entry into the
/// stock defaults above. `sndStart`/`sndRelease` are client audio with no
/// server emit channel yet (recorded residual); everything else numeric is
/// taken verbatim.
fn parseRangedTaskParams(entry: []const u8, rp: *RangedParams) void {
    // The list entry keeps its pipe separator's padding (" RangedAttackTarget
    // itemType=1;cooldown=6"), so trim first: taking the first space of the
    // raw entry finds the separator's own leading space and leaves the token
    // glued to the first attribute.
    const trimmed = std.mem.trim(u8, entry, " \t\r\n");
    const sp = std.mem.findScalar(u8, trimmed, ' ') orelse return;
    var rest = std.mem.trim(u8, trimmed[sp + 1 ..], " \t\r\n");
    while (rest.len > 0) {
        const semi = std.mem.findScalar(u8, rest, ';') orelse rest.len;
        const kv = std.mem.trim(u8, rest[0..semi], " \t\r\n");
        if (std.mem.findScalar(u8, kv, '=')) |eq| {
            const k = std.mem.trim(u8, kv[0..eq], " \t");
            const v = std.mem.trim(u8, kv[eq + 1 ..], " \t");
            if (std.mem.eql(u8, k, "cooldown")) {
                if (xml.parseF32(v)) |f| rp.cooldown_s = f;
            } else if (std.mem.eql(u8, k, "duration")) {
                if (xml.parseF32(v)) |f| rp.duration_s = f;
            } else if (std.mem.eql(u8, k, "releaseDelay")) {
                if (xml.parseF32(v)) |f| rp.release_delay_s = f;
            } else if (std.mem.eql(u8, k, "minRange")) {
                if (xml.parseF32(v)) |f| rp.min_dist = f;
            } else if (std.mem.eql(u8, k, "maxRange")) {
                if (xml.parseF32(v)) |f| rp.max_dist = f;
            } else if (std.mem.eql(u8, k, "unreachableRange")) {
                if (xml.parseF32(v)) |f| rp.unreachable_dist = f;
            } else if (std.mem.eql(u8, k, "startAnimType")) {
                if (xml.parseI32Prefix(v)) |n| rp.start_anim = n;
            }
        }
        if (semi >= rest.len) break;
        rest = rest[semi + 1 ..];
    }
}

fn resolvedAiTasks(
    classes: *const std.StringHashMapUnmanaged(RawClass),
    name: []const u8,
    ranged: ?*RangedParams,
) u16 {
    var mask: u16 = 0;
    var saw_list = false;
    var cur: ?[]const u8 = name;
    var depth: u8 = 0;
    while (cur) |cn| : (depth += 1) {
        if (depth > max_extends_depth) break;
        const rc = classes.get(cn) orelse break;
        var numbered: u16 = 0;
        var numbered_n: u8 = 0;
        var pipe: u16 = 0;
        var has_pipe = false;
        var it = rc.props.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            const val = e.value_ptr.*;
            if (std.mem.eql(u8, key, "AITask")) {
                has_pipe = true;
                var rest = val;
                while (rest.len > 0) {
                    const cut = std.mem.findScalar(u8, rest, '|') orelse rest.len;
                    const entry = rest[0..cut];
                    orTaskName(&pipe, entry);
                    if (ranged) |rp| {
                        // Pipe entries keep their padding (" RangedAttackTarget
                        // ..."): trim before splitting off the task name, or the
                        // separator's own leading space makes the token empty.
                        const trimmed_entry = std.mem.trim(u8, entry, " \t\r\n");
                        const tok = if (std.mem.findScalar(u8, trimmed_entry, ' ')) |sp2| std.mem.trim(u8, trimmed_entry[0..sp2], " \t") else trimmed_entry;
                        if (std.mem.eql(u8, tok, "RangedAttackTarget")) parseRangedTaskParams(trimmed_entry, rp);
                    }
                    if (cut >= rest.len) break;
                    rest = rest[cut + 1 ..];
                }
                continue;
            }
            if (!std.mem.startsWith(u8, key, "AITask-")) continue;
            numbered_n += 1;
            orTaskName(&numbered, val);
        }
        if (has_pipe) {
            mask = pipe;
            saw_list = true;
            break;
        }
        if (numbered_n > 0) {
            mask |= numbered;
            saw_list = true;
        }
        cur = rc.extends;
    }
    if (!saw_list) return 0;
    return mask | components.ai_task_list_set;
}

/// Does the class's inherited AITask list contain an attack task? Pipe
/// `AITask` (zombieTemplateMale) and numbered `AITask-N` (animals) both count.
/// No list at all reports true so brainless classes keep the zombie default.
fn resolvedAiAttacks(
    classes: *const std.StringHashMapUnmanaged(RawClass),
    name: []const u8,
) bool {
    const tasks = resolvedAiTasks(classes, name, null);
    if (tasks & components.ai_task_list_set == 0) return true;
    return components.aiTaskAllowed(tasks, .approach_attack);
}

pub fn inferKind(name: []const u8, tags: []const u8, is_animal: bool) components.Kind {
    if (std.mem.startsWith(u8, name, "player") or std.mem.find(u8, tags, "player") != null) return .player;
    if (is_animal or std.mem.startsWith(u8, name, "animal") or std.mem.find(u8, tags, "animal") != null) return .animal;
    if (std.mem.startsWith(u8, name, "npcTrader") or std.mem.find(u8, name, "trader") != null) return .trader;
    // Stock tags classify rows the name never hints at: vehicleBicycle keeps
    // `Tags="vehicle"`, junkTurretGun/Sledge `Tags="turret,..."`. Without
    // these the classes fell through to .zombie and callers needed hardcoded
    // name-sniff lists (the old admin spawnentity low_vehicle list).
    if (std.mem.find(u8, tags, "vehicle") != null) return .vehicle;
    if (std.mem.find(u8, tags, "turret") != null) return .turret;
    return .zombie;
}

/// Fail-closed HP when MaxHealth is missing or non-numeric (buff-driven templates).
/// Prefer entityclasses MaxHealth; these are last-resort kind floors only.
fn defaultHp(kind: components.Kind) f32 {
    return switch (kind) {
        .player => 100,
        .trader => 9999,
        .animal => 30,
        else => 40,
    };
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !EntityTable {
    const clean = try xml.readCleanFile(allocator, path);
    defer allocator.free(clean);

    const arena_holder = try arena_util.newArenaHolder(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var classes: std.StringHashMapUnmanaged(RawClass) = .empty;
    defer {
        var it = classes.iterator();
        while (it.next()) |e| e.value_ptr.props.deinit(allocator);
        classes.deinit(allocator);
    }

    // <replace_passive_effect> name -> value map (the stock HP list:
    // healthSlim 125 ... healthBruteInfernal 3100). passive_effect rows that
    // start with '^' reference these.
    var hp_vars: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer hp_vars.deinit(allocator);
    if (std.mem.findPos(u8, clean, 0, "<replace_passive_effect")) |rv| {
        const rv_end = std.mem.findPos(u8, clean, rv, "</replace_passive_effect>") orelse clean.len;
        var rpi: usize = rv;
        while (std.mem.findPos(u8, clean, rpi, "<property")) |ptag| {
            rpi = ptag + 9;
            if (ptag >= rv_end) break;
            const pname = xml.attr(clean, ptag, "name") orelse continue;
            const pval = xml.attr(clean, ptag, "value") orelse continue;
            try hp_vars.put(allocator, try arena.dupe(u8, pname), try arena.dupe(u8, pval));
        }
    }

    // <replace_properties> name -> value map (chargedMoveSpeedPattern, the
    // xpSlim01..xpStrongFeral03 XP ladder, ...). Plain <property> rows
    // (ExperienceGain among them) reference these with a leading '^'.
    var prop_vars: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer prop_vars.deinit(allocator);
    if (std.mem.findPos(u8, clean, 0, "<replace_properties")) |rv| {
        const rv_end = std.mem.findPos(u8, clean, rv, "</replace_properties>") orelse clean.len;
        var rpi: usize = rv;
        while (std.mem.findPos(u8, clean, rpi, "<property")) |ptag| {
            rpi = ptag + 9;
            if (ptag >= rv_end) break;
            const pname = xml.attr(clean, ptag, "name") orelse continue;
            const pval = xml.attr(clean, ptag, "value") orelse continue;
            try prop_vars.put(allocator, try arena.dupe(u8, pname), try arena.dupe(u8, pval));
        }
    }

    var i: usize = 0;
    while (i < clean.len) {
        const tag = std.mem.findPos(u8, clean, i, "<entity_class") orelse break;
        const name = xml.attr(clean, tag, "name") orelse {
            i = tag + 12;
            continue;
        };
        const extends = xml.attr(clean, tag, "extends");
        const gt = std.mem.findPos(u8, clean, tag, ">") orelse break;
        var body_end = gt + 1;
        if (!(gt > tag and clean[gt - 1] == '/')) {
            const close = std.mem.findPos(u8, clean, gt, "</entity_class>") orelse break;
            body_end = close;
        }
        const body = clean[gt + 1 .. body_end];

        var props: std.StringHashMapUnmanaged([]const u8) = .empty;
        var pi: usize = 0;
        while (pi < body.len) {
            // property rows and the HealthMax passive_effect row share the
            // same name -> value map (a stock class carries either MaxHealth
            // property or passive_effect name="HealthMax"; V3.1.0 ships the
            // passive form). perc_add rows are a spawn-time +/-15% roll that
            // zdtd pins to the base value for deterministic sims.
            const ptag_prop = std.mem.findPos(u8, body, pi, "<property");
            const ptag_pass = std.mem.findPos(u8, body, pi, "<passive_effect");
            const is_passive = ptag_pass != null and (ptag_prop == null or ptag_pass.? < ptag_prop.?);
            const ptag = if (is_passive) ptag_pass.? else ptag_prop orelse break;
            const pname = xml.attr(body, ptag, "name") orelse {
                pi = ptag + 9;
                continue;
            };
            if (xml.attr(body, ptag, "value")) |pval| {
                const keep = if (is_passive) blk: {
                    const op = xml.attr(body, ptag, "operation") orelse "";
                    // HealthMax base_set is the HP source. PhysicalDamageResist
                    // (passive 41, the armoured-class rows) is kept as a
                    // percentage; anything else that reaches this map is
                    // ignored by the resolvers below.
                    if (std.mem.eql(u8, pname, "PhysicalDamageResist")) {
                        // Only the untagged class rows are modelled. Stock also
                        // ships two tag-gated rows per insect/bee swarm
                        // (`tags="ranged"` 99, and the inverted 75) which need
                        // a damage-type query at the hit; applying one of them
                        // to every source would over-resist, so a tagged row is
                        // skipped (the swarm then takes full damage, the
                        // documented residual rather than a guessed number).
                        const row_tags = xml.attr(body, ptag, "tags") orelse "";
                        break :blk std.mem.eql(u8, op, "base_set") and row_tags.len == 0;
                    }
                    break :blk std.mem.eql(u8, pname, "HealthMax") and
                        std.mem.eql(u8, op, "base_set");
                } else true;
                if (keep) {
                    // last wins
                    const kn = try arena.dupe(u8, pname);
                    // Numbered AITarget-N props carry the task's SetData on a
                    // separate `data=` attribute (stock
                    // `<property name="AITarget-2" value="BlockIf"
                    // data="condition=alert e 0"/>`); the pipe `AITarget` blob
                    // inlines it instead. Append it so the entry resolvers see
                    // the same "Name key=val" text either way. Other resolvers
                    // match on the entry name, so the suffix is inert for them.
                    const vv = if (!is_passive and
                        (std.mem.eql(u8, pname, "AITarget") or std.mem.startsWith(u8, pname, "AITarget-")) and
                        (xml.attr(body, ptag, "data") != null))
                        try std.fmt.allocPrint(arena, "{s} {s}", .{ pval, xml.attr(body, ptag, "data").? })
                    else
                        try arena.dupe(u8, pval);
                    try props.put(allocator, kn, vv);
                }
            }
            pi = if (is_passive) ptag + 14 else ptag + 9;
        }

        const name_owned = try arena.dupe(u8, name);
        const ext_owned: ?[]const u8 = if (extends) |e| try arena.dupe(u8, e) else null;
        // Nested <property class="Explosion"> block (RE entity-ai.md §9.x):
        // the Demolition blast data. Captured whole (arena-owned inner rows)
        // so Extends resolution reads per-field overrides; a class without
        // it never explodes (fail closed). The block can itself nest a
        // <property class="DamageBonus"> child, so the matching close is the
        // </property> that returns the property depth to 0.
        var explosion_body: ?[]const u8 = null;
        if (std.mem.findPos(u8, body, 0, "<property class=\"Explosion\"")) |etag| {
            const egt = std.mem.findPos(u8, body, etag, ">") orelse break;
            if (!(egt > etag and body[egt - 1] == '/')) {
                var depth: usize = 1;
                var scan: usize = egt + 1;
                while (scan < body.len) {
                    const pc = std.mem.findPos(u8, body, scan, "</property>") orelse break;
                    var oi: usize = scan;
                    while (std.mem.findPos(u8, body, oi, "<property")) |pt3| {
                        if (pt3 >= pc) break;
                        const pgt3 = std.mem.findPos(u8, body, pt3, ">") orelse break;
                        if (!(pgt3 > pt3 and body[pgt3 - 1] == '/')) depth += 1;
                        oi = pgt3 + 1;
                    }
                    depth -= 1;
                    if (depth == 0) {
                        explosion_body = try arena.dupe(u8, body[egt + 1 .. pc]);
                        break;
                    }
                    scan = pc + 11;
                }
            }
        }
        try classes.put(allocator, name_owned, .{
            .name = name_owned,
            .extends = ext_owned,
            .props = props,
            .explosion = explosion_body,
            .effect_groups = try collectEffectGroups(arena, body),
        });
        i = if (body_end > gt) body_end + 15 else gt + 1;
        if (classes.count() >= max_entities_defs) break;
    }

    var list: std.ArrayList(EntityDef) = .empty;
    defer list.deinit(allocator);
    // Class triggered rows: one shared pool, ranges patched like items.xml.
    var trig_pool: std.ArrayList(buffs.Triggered) = .empty;
    defer trig_pool.deinit(allocator);
    var trig_reqs: std.ArrayList(requirements.Requirement) = .empty;
    defer trig_reqs.deinit(allocator);
    var trig_ranges: std.ArrayList(struct { usize, usize }) = .empty;
    defer trig_ranges.deinit(allocator);
    var trig_spans: std.ArrayList(struct { usize, usize }) = .empty;
    defer trig_spans.deinit(allocator);

    var it = classes.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const tags = resolveProp(&classes, name, "Tags", 0) orelse "";
        const is_animal = if (resolveProp(&classes, name, "IsAnimalEntity", 0)) |v| parseBoolLoose(v) else false;
        const is_enemy = if (resolveProp(&classes, name, "IsEnemyEntity", 0)) |v| parseBoolLoose(v) else true;
        var ranged_params: RangedParams = .{};
        const ai_tasks = resolvedAiTasks(&classes, name, &ranged_params);
        const ai_attack = resolvedAiAttacks(&classes, name);
        const target_sense = resolvedTargetPlayerSense(&classes, name);
        const hurt_classes = resolvedHurtTargetClasses(&classes, name);
        const block_if = resolvedBlockIfAlert(&classes, name);
        const kind = inferKind(name, tags, is_animal);
        const ust = resolveProp(&classes, name, "UserSpawnType", 0) orelse "None";
        const spawnable = !(std.mem.eql(u8, ust, "None") or std.mem.eql(u8, ust, "none"));
        var max_hp = defaultHp(kind);
        if (resolveProp(&classes, name, "MaxHealth", 0)) |mh| {
            if (xml.parseF32(mh)) |f| max_hp = f;
        } else if (resolveProp(&classes, name, "HandHealthMax", 0)) |mh| {
            if (xml.parseF32(mh)) |f| max_hp = f;
        } else if (resolveProp(&classes, name, "HealthMax", 0)) |hm| {
            // passive_effect name="HealthMax" base_set; '^' values resolve
            // through <replace_passive_effect> (stock zombie HP ladder).
            const v: []const u8 = if (hm.len > 0 and hm[0] == '^')
                (hp_vars.get(hm[1..]) orelse "")
            else
                hm;
            if (xml.parseF32(v)) |f| {
                // Bound: a crafted value must not make one entity immortal or
                // die to a stray byte; stock tops out around 1e5 (traders).
                if (f >= 1 and f <= 1_000_000) max_hp = f;
            }
        }
        // V3.x: LootDropEntityClass (bag entity class name). Older docs said LootListOnDeath.
        // The class name names a bag ENTITY CLASS whose own LootList is the
        // loot.xml container (zombieBoe → EntityLootContainerRegular → zPackReg);
        // resolve that one hop. Comma form ("A,1,B,1") takes the first candidate.
        var loot = resolveProp(&classes, name, "LootDropEntityClass", 0) orelse
            (resolveProp(&classes, name, "LootListOnDeath", 0) orelse "");
        if (loot.len > 0) {
            const bag_class = if (std.mem.findScalar(u8, loot, ',')) |ci| loot[0..ci] else loot;
            const bag_list = resolveProp(&classes, bag_class, "LootList", 0);
            if (bag_list) |bl| {
                if (bl.len > 0) loot = bl;
            }
        }
        // entityclasses `Buffs="a,b"`: the class-level buff list. Names are
        // resolved against the buff catalog by the caller (fail closed: an
        // unknown name is skipped there).
        var class_buffs: []const []const u8 = &.{};
        if (resolveProp(&classes, name, "Buffs", 0)) |bl| {
            if (bl.len > 0) class_buffs = try nameList(arena, bl);
        }
        // PhysicalDamageResist (passive 41): a percentage, resolved through
        // Extends like the other class props. Bounded 0..100 (a negative or
        // >100 resist would heal or negate the entity).
        var phys_resist: f32 = 0;
        if (resolveProp(&classes, name, "PhysicalDamageResist", 0)) |pr| {
            if (xml.parseF32(pr)) |f| {
                if (f >= 0 and f <= 100) phys_resist = f;
            }
        }
        var drop_prob: f32 = 1.0;
        if (resolveProp(&classes, name, "LootDropProb", 0)) |lp| {
            if (xml.parseF32(lp)) |f| {
                // Bounds are a kill-path invariant: the sim casts drop_prob*1000
                // to u64 (ecs/world.zig damage), so a modded negative value would
                // panic at the first kill. Out-of-range fails closed to 1.0.
                if (f >= 0 and f <= 1) drop_prob = f;
            }
        }
        // MoveSpeedAggro "min, max": the stock XML comment ("min/max (like
        // day or night)") pins day = min, night = max (entity-ai.md
        // GetMoveSpeedAggro: dark → aggroMax passive 134, else aggro passive
        // 133). A single value applies to both. MoveSpeed = day shamble;
        // MoveSpeedNight = night shamble (stock seeds it from MoveSpeed when
        // absent, entity-ai.md 3312).
        var chase_day: f32 = 0;
        var chase: f32 = 0;
        if (resolveProp(&classes, name, "MoveSpeedAggro", 0)) |msa| {
            const comma = std.mem.findScalar(u8, msa, ',');
            const lo = if (comma) |ci| std.mem.trim(u8, msa[0..ci], " ") else msa;
            const hi = if (comma) |ci| std.mem.trim(u8, msa[ci + 1 ..], " ") else msa;
            if (xml.parseF32(lo)) |f| chase_day = f;
            if (xml.parseF32(hi)) |f| chase = f;
        }
        var wander: f32 = 0;
        if (resolveProp(&classes, name, "MoveSpeed", 0)) |ms| {
            if (xml.parseF32(ms)) |f| wander = f;
        }
        var wander_night: f32 = 0;
        if (resolveProp(&classes, name, "MoveSpeedNight", 0)) |msn| {
            if (xml.parseF32(msn)) |f| wander_night = f;
        }
        // MoveSpeedRand "min,max" (stock zombieTemplateMale "-.2, .25"): the
        // per-entity roll added to the day chase when moveSpeedAggro < 1
        // (entity-ai.md 3318-3320). 0,0 = unset.
        var rand_min: f32 = 0;
        var rand_max: f32 = 0;
        if (resolveProp(&classes, name, "MoveSpeedRand", 0)) |msr| {
            const comma = std.mem.findScalar(u8, msr, ',');
            const lo = if (comma) |ci| std.mem.trim(u8, msr[0..ci], " ") else msr;
            const hi = if (comma) |ci| std.mem.trim(u8, msr[ci + 1 ..], " ") else msr;
            if (xml.parseF32(lo)) |f| rand_min = f;
            if (xml.parseF32(hi)) |f| rand_max = f;
        }
        // JumpMaxDistance "min,max" (stock zombieTemplateMale "2.8, 3.9",
        // zombieSpider "7, 9"; EntityClass default (1.9, 2.1),
        // entity-ai.md 3363): EAILeap's range bound, rolled per spawn.
        var jump_max_min: f32 = 1.9;
        var jump_max_max: f32 = 2.1;
        if (resolveProp(&classes, name, "JumpMaxDistance", 0)) |jmd| {
            const comma = std.mem.findScalar(u8, jmd, ',');
            const lo = if (comma) |ci| std.mem.trim(u8, jmd[0..ci], " ") else jmd;
            const hi = if (comma) |ci| std.mem.trim(u8, jmd[ci + 1 ..], " ") else jmd;
            if (xml.parseF32(lo)) |f| jump_max_min = f;
            if (xml.parseF32(hi)) |f| jump_max_max = f;
        }
        // SightRange is per class in stock (zombies 27-40 m). Bounded: a
        // crafted value must not make one zombie sense the whole world.
        var sight: f32 = 0;
        if (resolveProp(&classes, name, "SightRange", 0)) |sr| {
            if (xml.parseF32(sr)) |f| {
                if (f > 0 and f <= 256) sight = f;
            }
        }
        // SightLightThreshold "min,max" (RE entity-ai.md + CanSeeStealth IL:
        // "how well lit you have to be for the zombie to see you at min,max
        // range" - the stock XML comment on zombieTemplateMale "-2,150"; the
        // EntityClass cctor default is 30/100). A single value applies to
        // both. 0,0 stays "unset" → Rules floor. Negative min is legal
        // (stock -2: always seen at point blank).
        var sight_light_min: f32 = 0;
        var sight_light_max: f32 = 0;
        if (resolveProp(&classes, name, "SightLightThreshold", 0)) |slt| {
            const comma = std.mem.findScalar(u8, slt, ',');
            const lo = if (comma) |ci| std.mem.trim(u8, slt[0..ci], " ") else slt;
            const hi = if (comma) |ci| std.mem.trim(u8, slt[ci + 1 ..], " ") else slt;
            if (xml.parseF32(lo)) |f| sight_light_min = f;
            if (xml.parseF32(hi)) |f| sight_light_max = f;
        }
        // SleeperSightToWakeMin/Max: per-entity wake-threshold ROLL RANGES
        // (RE entity-ai.md D8.6 step 5 + GetSleeperDisturbedLevel IL=38):
        // each sleeping zombie rolls `wake = Lerp(roll(Min), roll(Max),
        // dist/sightRangeBase)` once at spawn. Stock zombieTemplateMale ships
        // "-40,5" (light value at point blank) / "340,480" (at SightRange).
        // Unbounded: the rolls feed a lightLevel (0..200) comparison only.
        var sw_near_min: f32 = 0;
        var sw_near_max: f32 = 0;
        var sw_far_min: f32 = 0;
        var sw_far_max: f32 = 0;
        if (resolveProp(&classes, name, "SleeperSightToWakeMin", 0)) |swn| {
            const comma = std.mem.findScalar(u8, swn, ',');
            const lo = if (comma) |ci| std.mem.trim(u8, swn[0..ci], " ") else swn;
            const hi = if (comma) |ci| std.mem.trim(u8, swn[ci + 1 ..], " ") else swn;
            if (xml.parseF32(lo)) |f| sw_near_min = f;
            if (xml.parseF32(hi)) |f| sw_near_max = f;
        }
        if (resolveProp(&classes, name, "SleeperSightToWakeMax", 0)) |swf| {
            const comma = std.mem.findScalar(u8, swf, ',');
            const lo = if (comma) |ci| std.mem.trim(u8, swf[0..ci], " ") else swf;
            const hi = if (comma) |ci| std.mem.trim(u8, swf[ci + 1 ..], " ") else swf;
            if (xml.parseF32(lo)) |f| sw_far_min = f;
            if (xml.parseF32(hi)) |f| sw_far_max = f;
        }
        // MaxViewAngle: full cone angle, stock EntityAlive cctor default 180
        // (RE entity-ai.md), per-class property overrides. Bounded: a crafted
        // value must not exceed a full 360. 0 stays "unset" → Rules floor.
        var view_angle: f32 = 0;
        if (resolveProp(&classes, name, "MaxViewAngle", 0)) |va| {
            if (xml.parseF32(va)) |f| {
                if (f > 0 and f <= 360) view_angle = f;
            }
        }
        // Demolition (RE entity-ai.md EntityZombieCop): the cop primes when
        // health drops below max*ExplodeHealthThreshold and explodes after
        // ExplodeDelay. Only classes carrying an <property class="Explosion">
        // block explode (threshold stays 0 otherwise - fail closed). Blast
        // params (radius/damages/bonuses) resolve per field through Extends.
        const expl = resolveExplosion(&classes, name);
        var explode_threshold: f32 = 0;
        var explode_delay: f32 = 0.5;
        if (expl != null) {
            if (resolveProp(&classes, name, "ExplodeHealthThreshold", 0)) |t| {
                if (xml.parseF32(t)) |f| {
                    if (f > 0 and f <= 1) explode_threshold = f;
                }
            }
            if (resolveProp(&classes, name, "ExplodeDelay", 0)) |d| {
                if (xml.parseF32(d)) |f| {
                    if (f > 0 and f <= 60) explode_delay = f;
                }
            }
        }
        // Dismember / crawler tuning (RE EntityAlive.CheckDismember IL=125 and
        // GetDismemberChance IL=128, EntityClass Init IL=0xB83+): the three
        // multipliers default to 1 in the stock cctor, so a parsed positive
        // value is stored and 0 stays "unset" (the effective 1 lands when the
        // roll reads the template-resolved value). The leg pair has no cctor
        // fallback, so 0 is the true stock default there too.
        var dis_head: f32 = 0;
        if (resolveProp(&classes, name, "DismemberMultiplierHead", 0)) |v| {
            if (xml.parseF32(v)) |f| {
                if (f >= 0 and f <= 100) dis_head = f;
            }
        }
        var dis_arms: f32 = 0;
        if (resolveProp(&classes, name, "DismemberMultiplierArms", 0)) |v| {
            if (xml.parseF32(v)) |f| {
                if (f >= 0 and f <= 100) dis_arms = f;
            }
        }
        var dis_legs: f32 = 0;
        if (resolveProp(&classes, name, "DismemberMultiplierLegs", 0)) |v| {
            if (xml.parseF32(v)) |f| {
                if (f >= 0 and f <= 100) dis_legs = f;
            }
        }
        var cripple_scale: f32 = 0;
        if (resolveProp(&classes, name, "LegCrippleScale", 0)) |v| {
            if (xml.parseF32(v)) |f| {
                if (f >= 0 and f <= 100) cripple_scale = f;
            }
        }
        var crawler_threshold: f32 = 0;
        if (resolveProp(&classes, name, "LegCrawlerThreshold", 0)) |v| {
            if (xml.parseF32(v)) |f| {
                if (f >= 0 and f <= 1) crawler_threshold = f;
            }
        }
        var time_stay: f32 = 0;
        if (resolveProp(&classes, name, "TimeStayAfterDeath", 0)) |ts| {
            if (xml.parseF32(ts)) |f| {
                // Bounds: a corpse left forever (or negative) would pin its
                // slot; clamp to [1, 3600] seconds.
                if (f >= 1 and f <= 3600) time_stay = f;
            }
        }
        const hand = resolveProp(&classes, name, "HandItem", 0) orelse "";
        // ExperienceGain: either a literal ("500") or a '^' reference into
        // <replace_properties> (the xpSlim01..xpStrongFeral03 ladder).
        // Bounded: stock tops out at 2500 (zombieBear); reject a crafted
        // value that would let one kill jump several levels.
        var xp_gain: f32 = 0;
        if (resolveProp(&classes, name, "ExperienceGain", 0)) |eg| {
            const v: []const u8 = if (eg.len > 0 and eg[0] == '^')
                (prop_vars.get(eg[1..]) orelse "")
            else
                eg;
            if (xml.parseF32(v)) |f| {
                if (f >= 0 and f <= 100_000) xp_gain = f;
            }
        }
        const t0 = trig_pool.items.len;
        try scanClassTriggered(allocator, arena, &classes, name, &trig_pool, &trig_reqs, &trig_ranges);
        try trig_spans.append(allocator, .{ t0, trig_pool.items.len - t0 });
        try list.append(allocator, .{
            .name = name,
            .hash = unity_hash.getStableHashCode(name),
            .tags = if (tags.len > 0) try arena.dupe(u8, tags) else "",
            .max_hp = max_hp,
            .kind = kind,
            .loot_list = loot,
            .loot_drop_prob = drop_prob,
            .spawnable = spawnable,
            .is_enemy = is_enemy,
            .ai_attack = ai_attack,
            .ai_tasks = ai_tasks,
            .ranged_cooldown_s = ranged_params.cooldown_s,
            .ranged_duration_s = ranged_params.duration_s,
            .ranged_release_delay_s = ranged_params.release_delay_s,
            .ranged_min_dist = ranged_params.min_dist,
            .ranged_max_dist = ranged_params.max_dist,
            .ranged_unreachable_dist = ranged_params.unreachable_dist,
            .ranged_start_anim = ranged_params.start_anim,
            .target_player_hear = if (target_sense) |s| s.hear else 0,
            .target_player_see = if (target_sense) |s| s.see else 0,
            .hurt_target_classes = hurt_classes,
            .block_if_alert_only = block_if,
            .chase_speed = chase,
            .chase_speed_day = chase_day,
            .wander_speed = wander,
            .wander_speed_night = wander_night,
            .move_speed_rand_min = rand_min,
            .move_speed_rand_max = rand_max,
            .jump_max_min = jump_max_min,
            .jump_max_max = jump_max_max,
            .time_stay = time_stay,
            .sight_range = sight,
            .sight_light_min = sight_light_min,
            .sight_light_max = sight_light_max,
            .sleeper_wake_near_min = sw_near_min,
            .sleeper_wake_near_max = sw_near_max,
            .sleeper_wake_far_min = sw_far_min,
            .sleeper_wake_far_max = sw_far_max,
            .view_angle_deg = view_angle,
            .explode_threshold = explode_threshold,
            .explode_delay_s = explode_delay,
            .dismember_head = dis_head,
            .dismember_arms = dis_arms,
            .dismember_legs = dis_legs,
            .leg_cripple_scale = cripple_scale,
            .leg_crawler_threshold = crawler_threshold,
            .explosion = expl orelse .{},
            .buffs = class_buffs,
            .xp_gain = xp_gain,
            .phys_resist = phys_resist,
            .hand_item = if (hand.len > 0) try arena.dupe(u8, hand) else "",
        });
    }

    // Freeze the triggered pool and patch gate slices + def spans (before
    // the name sort, which trig_spans is aligned with).
    const tpool = try arena.alloc(buffs.Triggered, trig_pool.items.len);
    @memcpy(tpool, trig_pool.items);
    if (trig_ranges.items.len != tpool.len) return error.MalformedEntities;
    const treq_pool = try arena.alloc(requirements.Requirement, trig_reqs.items.len);
    @memcpy(treq_pool, trig_reqs.items);
    for (tpool, trig_ranges.items) |*tr, rg| {
        tr.reqs = treq_pool[rg[0] .. rg[0] + rg[1]];
    }
    if (trig_spans.items.len != list.items.len) return error.MalformedEntities;
    for (list.items, trig_spans.items) |*d, sp| {
        d.triggered = tpool[sp[0] .. sp[0] + sp[1]];
    }

    // Stable order: name sort for deterministic indexes.
    std.mem.sort(EntityDef, list.items, {}, struct {
        fn less(_: void, a: EntityDef, b: EntityDef) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);

    const defs = try arena.alloc(EntityDef, list.items.len);
    @memcpy(defs, list.items);

    return .{
        .defs = defs,
        .arena_ptr = arena_holder,
        .source = .xml,
    };
}

/// One comma list into an arena-owned slice of trimmed names.
fn nameList(arena: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(arena);
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |seg| {
        const n = std.mem.trim(u8, seg, " \t");
        if (n.len == 0) continue;
        try out.append(arena, try arena.dupe(u8, n));
    }
    return out.toOwnedSlice(arena);
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?EntityTable {
    return paths.tryLoadConfig("entityclasses.xml", EntityTable, loadFromPath, allocator, game_dir, config_dir);
}
