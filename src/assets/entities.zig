//! entityclasses.xml loader: name → Unity Mono hash, kind, HP, death loot list.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const unity_hash = @import("unity_hash.zig");
const components = @import("../ecs/components.zig");

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
    /// TimeStayAfterDeath seconds a corpse lingers (30 zombies, 300 animals).
    time_stay: f32 = 0,
    /// HandItem name (items.xml melee hand); empty = unset.
    hand_item: []const u8 = "",
    /// Resolved Action0 DamageEntity for hand_item (0 = unresolved).
    attack_damage: f32 = 0,
    /// entityclasses SightRange in metres (stock ships 27, 30, 40 per class).
    /// 0 = unset, which leaves the sim on the Rules floor.
    sight_range: f32 = 0,
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
    /// <property class="Explosion"> blast params (radius/damages/bonuses),
    /// Extends-resolved per field. Unset fields stay 0 -> Rules floor.
    explosion: ExplosionDef = .{},
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
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = builtin();
    }

    pub fn builtin() EntityTable {
        return .{ .defs = &builtin_defs, .source = .builtin };
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
        return builtin_defs[1];
    }

    pub fn defaultAnimal(self: *const EntityTable) EntityDef {
        if (self.byName("animalStag")) |d| return d;
        for (self.defs) |d| {
            if (d.kind == .animal and d.spawnable) return d;
        }
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
        .max_hp = 100,
        .kind = .player,
        .spawnable = false,
        .is_enemy = false,
    },
    .{
        .name = "zombieBoe",
        .hash = unity_hash.class_zombie_boe,
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
};

fn resolveProp(
    classes: *const std.StringHashMapUnmanaged(RawClass),
    name: []const u8,
    key: []const u8,
    depth: u8,
) ?[]const u8 {
    if (depth > 24) return null;
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
        if (depth > 24) break;
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

/// Stock AITask-* task names that make an entity attack. V3.1.0 b14
/// entityclasses.xml ships only ApproachAndAttackTarget (the AI task enum's
/// attack-capable task; every hostile animal and zombie template carries it,
/// timid animals never do). A new attack task name lands here as RE evidence,
/// not in per-class data.
const attack_task_names = [_][]const u8{"ApproachAndAttackTarget"};

/// Does the class's inherited AITask-* list contain an attack task? Walks the
/// extends chain like resolveProp. A class with no AITask-* at all reports
/// true (the sim drives those with the zombie brain and they keep attacking);
/// a class whose list exists without an attack task (timid animal template)
/// reports false, so it never picks approach_attack.
fn resolvedAiAttacks(
    classes: *const std.StringHashMapUnmanaged(RawClass),
    name: []const u8,
) bool {
    var has_any_task = false;
    var cur: ?[]const u8 = name;
    var depth: u8 = 0;
    while (cur) |cn| : (depth += 1) {
        if (depth > 24) break;
        const rc = classes.get(cn) orelse break;
        var it = rc.props.iterator();
        while (it.next()) |e| {
            if (!std.mem.startsWith(u8, e.key_ptr.*, "AITask-")) continue;
            has_any_task = true;
            for (attack_task_names) |att| {
                if (std.mem.eql(u8, e.value_ptr.*, att)) return true;
            }
        }
        cur = rc.extends;
    }
    return !has_any_task;
}

fn inferKind(name: []const u8, tags: []const u8, is_animal: bool) components.Kind {
    if (std.mem.startsWith(u8, name, "player") or std.mem.find(u8, tags, "player") != null) return .player;
    if (is_animal or std.mem.startsWith(u8, name, "animal") or std.mem.find(u8, tags, "animal") != null) return .animal;
    if (std.mem.startsWith(u8, name, "npcTrader") or std.mem.find(u8, name, "trader") != null) return .trader;
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

    var classes: std.StringHashMapUnmanaged(RawClass) = .{};
    defer {
        var it = classes.iterator();
        while (it.next()) |e| e.value_ptr.props.deinit(allocator);
        classes.deinit(allocator);
    }

    // <replace_passive_effect> name -> value map (the stock HP list:
    // healthSlim 125 ... healthBruteInfernal 3100). passive_effect rows that
    // start with '^' reference these.
    var hp_vars: std.StringHashMapUnmanaged([]const u8) = .{};
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
    var prop_vars: std.StringHashMapUnmanaged([]const u8) = .{};
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
        // self-closing?
        var body_end = gt + 1;
        if (gt > tag and clean[gt - 1] == '/') {
            // empty
        } else {
            const close = std.mem.findPos(u8, clean, gt, "</entity_class>") orelse break;
            body_end = close;
        }
        const body = clean[gt + 1 .. body_end];

        var props: std.StringHashMapUnmanaged([]const u8) = .{};
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
                    // HealthMax base_set is the HP source; anything else that
                    // reaches this map is ignored by the resolvers below.
                    break :blk std.mem.eql(u8, pname, "HealthMax") and
                        std.mem.eql(u8, op, "base_set");
                } else true;
                if (keep) {
                    // last wins
                    const kn = try arena.dupe(u8, pname);
                    const vv = try arena.dupe(u8, pval);
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
        });
        i = if (body_end > gt) body_end + 15 else gt + 1;
        if (classes.count() >= max_entities_defs) break;
    }

    var list: std.ArrayList(EntityDef) = .empty;
    defer list.deinit(allocator);

    var it = classes.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const tags = resolveProp(&classes, name, "Tags", 0) orelse "";
        const is_animal = if (resolveProp(&classes, name, "IsAnimalEntity", 0)) |v| parseBoolLoose(v) else false;
        const is_enemy = if (resolveProp(&classes, name, "IsEnemyEntity", 0)) |v| parseBoolLoose(v) else true;
        const ai_attack = resolvedAiAttacks(&classes, name);
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
        try list.append(allocator, .{
            .name = name,
            .hash = unity_hash.unityStringHash(name),
            .max_hp = max_hp,
            .kind = kind,
            .loot_list = loot,
            .loot_drop_prob = drop_prob,
            .spawnable = spawnable,
            .is_enemy = is_enemy,
            .ai_attack = ai_attack,
            .chase_speed = chase,
            .chase_speed_day = chase_day,
            .wander_speed = wander,
            .wander_speed_night = wander_night,
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
            .explosion = expl orelse .{},
            .xp_gain = xp_gain,
            .hand_item = if (hand.len > 0) try arena.dupe(u8, hand) else "",
        });
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

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?EntityTable {
    const paths = @import("paths.zig");
    return paths.tryLoadConfig("entityclasses.xml", EntityTable, loadFromPath, allocator, game_dir, config_dir);
}

test "builtin entities" {
    const t = EntityTable.builtin();
    try std.testing.expectEqualStrings("zombieBoe", t.defaultZombie().name);
    try std.testing.expectEqual(unity_hash.class_zombie_boe, t.defaultZombie().hash);
}

test "unity hash matches known playerMale" {
    try std.testing.expectEqual(unity_hash.class_player_male, unity_hash.unityStringHash("playerMale"));
    try std.testing.expectEqual(unity_hash.class_zombie_boe, unity_hash.unityStringHash("zombieBoe"));
}

test "load stock entityclasses when present" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/entityclasses.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.defs.len > 100);
    const boe = t.byName("zombieBoe") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(unity_hash.class_zombie_boe, boe.hash);
    try std.testing.expect(boe.spawnable);
    try std.testing.expectEqual(components.Kind.zombie, boe.kind);
    // LootDropEntityClass "EntityLootContainerRegular" resolves one hop through
    // that class's LootList to the real loot.xml container.
    try std.testing.expectEqualStrings("zPackReg", boe.loot_list);
    try std.testing.expectEqual(@as(f32, 0.04), boe.loot_drop_prob);
    // ExperienceGain resolves the '^xpNormal01' replace_properties reference
    // (entityclasses.xml XP_ZOMBIE_TEMPLATE -> zombieTemplateMale -> zombieBoe).
    try std.testing.expectEqual(@as(f32, 500), boe.xp_gain);
    // A34: HP comes from the HealthMax passive_effect chain, not the 40 builtin
    // floor. Ground truth = the V3.1.0 b14 stock file: zombieBoe's own body
    // declares `value="^healthNormal"` = 200 (the earlier audit guess of 125
    // was wrong for this file). No perc_add on the row; rolls would be pinned
    // to base for deterministic sims either way (documented).
    try std.testing.expectEqual(@as(f32, 200), boe.max_hp);
    // Day/night speeds (V3.1.0 b14 ground truth): zombieBoe inherits
    // zombieTemplateMale's MoveSpeed 0.08 (day shamble) and MoveSpeedAggro
    // "0.2, 1.25" (day chase min / night chase max; the stock XML comment
    // "min/max (like day or night)"), with no MoveSpeedNight (night shamble
    // seeds from MoveSpeed, entity-ai.md 3312).
    try std.testing.expectEqual(@as(f32, 0.08), boe.wander_speed);
    try std.testing.expectEqual(@as(f32, 0), boe.wander_speed_night);
    try std.testing.expectEqual(@as(f32, 1.25), boe.chase_speed);
    try std.testing.expectEqual(@as(f32, 0.2), boe.chase_speed_day);
    const dog = t.byName("animalZombieDog") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 0.45), dog.wander_speed);
    try std.testing.expectEqual(@as(f32, 0.3), dog.wander_speed_night);
    try std.testing.expectEqual(@as(f32, 1.3), dog.chase_speed);
    try std.testing.expectEqual(@as(f32, 1.2), dog.chase_speed_day);
    // SightLightThreshold: zombieTemplateMale pins "-2,150" (the stock XML
    // comment "how well lit you have to be for the zombie to see you at
    // min,max range") and zombieBoe inherits it; a class with no prop keeps
    // 0,0 → the Rules (30,100) cctor-default floor.
    try std.testing.expectEqual(@as(f32, -2.0), boe.sight_light_min);
    try std.testing.expectEqual(@as(f32, 150.0), boe.sight_light_max);
    // SleeperSightToWakeMin/Max (the sleeping zombie's wake-threshold ROLL
    // ranges, RE entity-ai.md D8.6 step 5): zombieBoe inherits the template's
    // "-40,5" / "340,480".
    try std.testing.expectEqual(@as(f32, -40.0), boe.sleeper_wake_near_min);
    try std.testing.expectEqual(@as(f32, 5.0), boe.sleeper_wake_near_max);
    try std.testing.expectEqual(@as(f32, 340.0), boe.sleeper_wake_far_min);
    try std.testing.expectEqual(@as(f32, 480.0), boe.sleeper_wake_far_max);
    const stag = t.byName("animalStag") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(components.Kind.animal, stag.kind);
    try std.testing.expect(stag.spawnable);
    // A34 on animals: the stag's own HealthMax base_set=100 wins over the 30
    // builtin animal floor (the 10 row in the file is inside an XML comment).
    try std.testing.expectEqual(@as(f32, 100), stag.max_hp);
    const fer = t.byName("zombieBoeFeral") orelse return error.TestExpectedEqual;
    // A34 on the feral ladder: zombieBoeFeral overrides zombieBoe's HealthMax
    // with ^healthNormalFeral = 550 (Extends-chain override + variable lookup).
    try std.testing.expectEqual(@as(f32, 550), fer.max_hp);
    // AITask-* attack gating (timid animals never attack): the stag's inherited
    // task list is RunawayWhenHurt/RunawayFromEntity/Look/Wander (no attack
    // task), wolves carry ApproachAndAttackTarget, and the boar keeps its
    // hostile template's attack task even though it overrides IsEnemyEntity
    // to false for safe-zone spawning.
    const stag2 = t.byName("animalStag").?;
    try std.testing.expect(!stag2.ai_attack);
    const rabbit = t.byName("animalRabbit").?;
    try std.testing.expect(!rabbit.ai_attack);
    const wolf = t.byName("animalWolf").?;
    try std.testing.expect(wolf.ai_attack);
    const boar = t.byName("animalBoar").?;
    try std.testing.expect(boar.ai_attack);
    try std.testing.expect(boe.ai_attack); // zombieTemplate has the attack task
}

test "day/night speeds parse from entityclasses XML" {
    // Offline parse: MoveSpeedAggro "min, max" splits into day (min) / night
    // (max) chase (the stock XML comment "min/max (like day or night)");
    // MoveSpeedNight is the night shamble; a single aggro value applies to
    // both, and a class without MoveSpeedNight keeps 0 (falls to day at night
    // per entity-ai.md 3312 moveSpeedNight seeds from moveSpeed).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/ec2.xml", .{dir});
    try io_fs.writeFile(path,
        \\<entity_classes>
        \\  <entity_class name="ZombieBase">
        \\    <property name="MoveSpeed" value="0.08"/>
        \\    <property name="MoveSpeedAggro" value="0.2, 1.25"/>
        \\    <property name="SightLightThreshold" value="-2,150"/>
        \\    <property name="SleeperSightToWakeMin" value="-40,5"/>
        \\    <property name="SleeperSightToWakeMax" value="340,480"/>
        \\  </entity_class>
        \\  <entity_class name="zombieBoe" extends="ZombieBase">
        \\  </entity_class>
        \\  <entity_class name="animalZombieDog" extends="ZombieBase">
        \\    <property name="MoveSpeed" value=".45"/>
        \\    <property name="MoveSpeedNight" value=".3"/>
        \\    <property name="MoveSpeedAggro" value="1.2, 1.3"/>
        \\    <property name="SightLightThreshold" value="0,200"/>
        \\  </entity_class>
        \\  <entity_class name="zombieFlat">
        \\    <property name="MoveSpeed" value="0.1"/>
        \\    <property name="MoveSpeedAggro" value="0.5"/>
        \\  </entity_class>
        \\</entity_classes>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const boe = t.byName("zombieBoe").?;
    try std.testing.expectEqual(@as(f32, 0.08), boe.wander_speed);
    try std.testing.expectEqual(@as(f32, 0), boe.wander_speed_night); // seeded from MoveSpeed at night
    try std.testing.expectEqual(@as(f32, 1.25), boe.chase_speed); // aggro max = night chase
    try std.testing.expectEqual(@as(f32, 0.2), boe.chase_speed_day); // aggro min = day chase
    // SightLightThreshold inherits through extends (stock "-2,150").
    try std.testing.expectEqual(@as(f32, -2.0), boe.sight_light_min);
    try std.testing.expectEqual(@as(f32, 150.0), boe.sight_light_max);
    // SleeperSightToWakeMin/Max roll ranges (stock "-40,5" / "340,480").
    try std.testing.expectEqual(@as(f32, -40.0), boe.sleeper_wake_near_min);
    try std.testing.expectEqual(@as(f32, 5.0), boe.sleeper_wake_near_max);
    try std.testing.expectEqual(@as(f32, 340.0), boe.sleeper_wake_far_min);
    try std.testing.expectEqual(@as(f32, 480.0), boe.sleeper_wake_far_max);
    const dog = t.byName("animalZombieDog").?;
    try std.testing.expectEqual(@as(f32, 0.45), dog.wander_speed);
    try std.testing.expectEqual(@as(f32, 0.3), dog.wander_speed_night);
    try std.testing.expectEqual(@as(f32, 1.3), dog.chase_speed);
    try std.testing.expectEqual(@as(f32, 1.2), dog.chase_speed_day);
    try std.testing.expectEqual(@as(f32, 0.0), dog.sight_light_min);
    try std.testing.expectEqual(@as(f32, 200.0), dog.sight_light_max);
    const flat = t.byName("zombieFlat").?;
    try std.testing.expectEqual(@as(f32, 0.5), flat.chase_speed); // single value -> both
    try std.testing.expectEqual(@as(f32, 0.5), flat.chase_speed_day);
    try std.testing.expectEqual(@as(f32, 0.0), flat.sight_light_min); // no prop -> 0,0 -> Rules floor
    try std.testing.expectEqual(@as(f32, 0.0), flat.sight_light_max);
}

test "AITask attack gating parses from entityclasses XML" {
    // Offline parse: attack-task presence is inherited through extends, and a
    // class with no AITask-* at all keeps the zombie-brain default (true).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/ec.xml", .{dir});
    try io_fs.writeFile(path,
        \\<entity_classes>
        \\  <entity_class name="TimidBase">
        \\    <property name="AITask-1" value="RunawayWhenHurt"/>
        \\    <property name="AITask-2" value="Look"/>
        \\  </entity_class>
        \\  <entity_class name="animalDeer" extends="TimidBase">
        \\    <property name="AITask-3" value="Wander"/>
        \\  </entity_class>
        \\  <entity_class name="animalTemplateHostile">
        \\    <property name="AITask-1" value="BreakBlock"/>
        \\    <property name="AITask-2" value="ApproachAndAttackTarget"/>
        \\  </entity_class>
        \\  <entity_class name="animalWolf" extends="animalTemplateHostile">
        \\    <property name="MaxHealth" value="200"/>
        \\  </entity_class>
        \\  <entity_class name="mysteryNoTasks">
        \\    <property name="MaxHealth" value="50"/>
        \\  </entity_class>
        \\</entity_classes>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(!t.byName("animalDeer").?.ai_attack); // inherited timid list
    try std.testing.expect(t.byName("animalWolf").?.ai_attack); // hostile template
    try std.testing.expect(t.byName("mysteryNoTasks").?.ai_attack); // no list -> default
}

test "stock Demolition Explosion class parses (zombieFatCop tiers)" {
    // Ground truth = the V3.1.0 b14 stock file: the cop's <property
    // class="Explosion"> ships RadiusBlocks 5 / RadiusEntities 6 / BlockDamage
    // 500 / EntityDamage 150 with DamageBonus earth -> 0; the feral and
    // radiated tiers override only the damages.
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/entityclasses.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const cop = t.byName("zombieFatCop") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 5), cop.explosion.radius_blocks);
    try std.testing.expectEqual(@as(f32, 6), cop.explosion.radius_entities);
    try std.testing.expectEqual(@as(f32, 500), cop.explosion.block_damage);
    try std.testing.expectEqual(@as(f32, 150), cop.explosion.entity_damage);
    try std.testing.expect(cop.explosion.bonus_n >= 1);
    var earth_mult: f32 = 1;
    var bi: u8 = 0;
    while (bi < cop.explosion.bonus_n) : (bi += 1) {
        if (std.mem.eql(u8, cop.explosion.bonus_cat[bi], "earth")) earth_mult = cop.explosion.bonus_mult[bi];
    }
    try std.testing.expectEqual(@as(f32, 0), earth_mult);
    const feral = t.byName("zombieFatCopFeral") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 5), feral.explosion.radius_blocks);
    try std.testing.expectEqual(@as(f32, 650), feral.explosion.block_damage);
    try std.testing.expectEqual(@as(f32, 200), feral.explosion.entity_damage);
}

test "Explosion class resolves per field through Extends with DamageBonus" {
    // RE entity-ai.md §9.x: the Demolition blast comes from the nested
    // <property class="Explosion"> block; feral/radiated tiers override only
    // the damages and inherit radius + DamageBonus from the base class.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/ec.xml", .{dir});
    try io_fs.writeFile(path,
        \\<entity_classes>
        \\  <entity_class name="zombieFatCop">
        \\    <property name="ExplodeHealthThreshold" value=".5"/>
        \\    <property class="Explosion">
        \\      <property name="RadiusBlocks" value="5"/>
        \\      <property name="RadiusEntities" value="6"/>
        \\      <property name="BlockDamage" value="500"/>
        \\      <property name="EntityDamage" value="150"/>
        \\      <property class="DamageBonus">
        \\        <property name="earth" value="0"/>
        \\        <property name="stone" value=".5"/>
        \\      </property>
        \\    </property>
        \\  </entity_class>
        \\  <entity_class name="zombieFatCopFeral" extends="zombieFatCop">
        \\    <property class="Explosion">
        \\      <property name="BlockDamage" value="650"/>
        \\      <property name="EntityDamage" value="200"/>
        \\    </property>
        \\  </entity_class>
        \\  <entity_class name="plainWalker">
        \\    <property name="MaxHealth" value="50"/>
        \\  </entity_class>
        \\</entity_classes>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();

    const base = t.byName("zombieFatCop").?;
    try std.testing.expectEqual(@as(f32, 0.5), base.explode_threshold);
    try std.testing.expectEqual(@as(f32, 5), base.explosion.radius_blocks);
    try std.testing.expectEqual(@as(f32, 6), base.explosion.radius_entities);
    try std.testing.expectEqual(@as(f32, 500), base.explosion.block_damage);
    try std.testing.expectEqual(@as(f32, 150), base.explosion.entity_damage);
    try std.testing.expectEqual(@as(u8, 2), base.explosion.bonus_n);
    try std.testing.expectEqualStrings("earth", base.explosion.bonus_cat[0]);
    try std.testing.expectEqual(@as(f32, 0), base.explosion.bonus_mult[0]);
    try std.testing.expectEqualStrings("stone", base.explosion.bonus_cat[1]);
    try std.testing.expectEqual(@as(f32, 0.5), base.explosion.bonus_mult[1]);

    // Feral overrides the damages; radius and bonuses inherit from the base.
    const feral = t.byName("zombieFatCopFeral").?;
    try std.testing.expectEqual(@as(f32, 5), feral.explosion.radius_blocks);
    try std.testing.expectEqual(@as(f32, 650), feral.explosion.block_damage);
    try std.testing.expectEqual(@as(f32, 200), feral.explosion.entity_damage);
    try std.testing.expectEqual(@as(u8, 2), feral.explosion.bonus_n);
    try std.testing.expectEqualStrings("earth", feral.explosion.bonus_cat[0]);

    // A class without the Explosion block never explodes (threshold stays 0)
    // and its blast params stay unset (Rules floor applies).
    const plain = t.byName("plainWalker").?;
    try std.testing.expectEqual(@as(f32, 0), plain.explode_threshold);
    try std.testing.expectEqual(@as(f32, 0), plain.explosion.radius_blocks);
    try std.testing.expectEqual(@as(f32, 0), plain.explosion.block_damage);
}
