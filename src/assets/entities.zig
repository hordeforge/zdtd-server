//! entityclasses.xml loader: name → Unity Mono hash, kind, HP, death loot list.

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const unity_hash = @import("unity_hash.zig");
const components = @import("../ecs/components.zig");

pub const max_entities_defs: usize = 512;

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
    /// entityclasses MoveSpeedAggro max (chase speed, m/s scale). 0 = unset.
    chase_speed: f32 = 0,
    /// MoveSpeed (wander shamble). 0 = unset.
    wander_speed: f32 = 0,
    /// HandItem name (items.xml melee hand); empty = unset.
    hand_item: []const u8 = "",
    /// Resolved Action0 DamageEntity for hand_item (0 = unresolved).
    attack_damage: f32 = 0,
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

    pub fn byHash(self: *const EntityTable, hash: i32) ?EntityDef {
        for (self.defs) |d| {
            if (d.hash == hash) return d;
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
};

fn propOf(map: *const std.StringHashMapUnmanaged([]const u8), key: []const u8) ?[]const u8 {
    return map.get(key);
}

fn resolveProp(
    classes: *const std.StringHashMapUnmanaged(RawClass),
    name: []const u8,
    key: []const u8,
    depth: u8,
) ?[]const u8 {
    if (depth > 24) return null;
    const rc = classes.get(name) orelse return null;
    if (propOf(&rc.props, key)) |v| return v;
    if (rc.extends) |ex| return resolveProp(classes, ex, key, depth + 1);
    return null;
}

fn parseBoolLoose(s: []const u8) bool {
    return std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "True") or std.mem.eql(u8, s, "1");
}

fn inferKind(name: []const u8, tags: []const u8, is_animal: bool, is_enemy: bool) components.Kind {
    _ = is_enemy;
    if (std.mem.startsWith(u8, name, "player") or std.mem.indexOf(u8, tags, "player") != null) return .player;
    if (is_animal or std.mem.startsWith(u8, name, "animal") or std.mem.indexOf(u8, tags, "animal") != null) return .animal;
    if (std.mem.startsWith(u8, name, "npcTrader") or std.mem.indexOf(u8, name, "trader") != null) return .trader;
    return .zombie;
}

/// Fail-closed HP when MaxHealth is missing or non-numeric (buff-driven templates).
/// Prefer entityclasses MaxHealth; these are last-resort kind floors only.
fn defaultHp(kind: components.Kind, name: []const u8) f32 {
    _ = name;
    return switch (kind) {
        .player => 100,
        .trader => 9999,
        .animal => 30,
        .zombie => 40,
        else => 40,
    };
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !EntityTable {
    const raw = try io_fs.readFileAll(allocator, path);
    defer allocator.free(raw);
    const clean = try xml.stripComments(allocator, raw);
    defer allocator.free(clean);

    var arena_holder = try allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(allocator);
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

    var i: usize = 0;
    while (i < clean.len) {
        const tag = std.mem.indexOfPos(u8, clean, i, "<entity_class") orelse break;
        const name = xml.attr(clean, tag, "name") orelse {
            i = tag + 12;
            continue;
        };
        const extends = xml.attr(clean, tag, "extends");
        const gt = std.mem.indexOfPos(u8, clean, tag, ">") orelse break;
        // self-closing?
        var body_end = gt + 1;
        if (gt > tag and clean[gt - 1] == '/') {
            // empty
        } else {
            const close = std.mem.indexOfPos(u8, clean, gt, "</entity_class>") orelse break;
            body_end = close;
        }
        const body = clean[gt + 1 .. body_end];

        var props: std.StringHashMapUnmanaged([]const u8) = .{};
        var pi: usize = 0;
        while (pi < body.len) {
            const ptag = std.mem.indexOfPos(u8, body, pi, "<property") orelse break;
            const pname = xml.attr(body, ptag, "name") orelse {
                pi = ptag + 9;
                continue;
            };
            if (xml.attr(body, ptag, "value")) |pval| {
                // last wins
                const kn = try arena.dupe(u8, pname);
                const vv = try arena.dupe(u8, pval);
                try props.put(allocator, kn, vv);
            }
            pi = ptag + 9;
        }

        const name_owned = try arena.dupe(u8, name);
        const ext_owned: ?[]const u8 = if (extends) |e| try arena.dupe(u8, e) else null;
        try classes.put(allocator, name_owned, .{
            .name = name_owned,
            .extends = ext_owned,
            .props = props,
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
        const kind = inferKind(name, tags, is_animal, is_enemy);
        const ust = resolveProp(&classes, name, "UserSpawnType", 0) orelse "None";
        const spawnable = !(std.mem.eql(u8, ust, "None") or std.mem.eql(u8, ust, "none"));
        var max_hp = defaultHp(kind, name);
        if (resolveProp(&classes, name, "MaxHealth", 0)) |mh| {
            if (xml.parseF32(mh)) |f| max_hp = f;
        } else if (resolveProp(&classes, name, "HandHealthMax", 0)) |mh| {
            if (xml.parseF32(mh)) |f| max_hp = f;
        }
        // V3.x: LootDropEntityClass (bag entity class name). Older docs said LootListOnDeath.
        // The class name names a bag ENTITY CLASS whose own LootList is the
        // loot.xml container (zombieBoe → EntityLootContainerRegular → zPackReg);
        // resolve that one hop. Comma form ("A,1,B,1") takes the first candidate.
        var loot = resolveProp(&classes, name, "LootDropEntityClass", 0) orelse
            (resolveProp(&classes, name, "LootListOnDeath", 0) orelse "");
        if (loot.len > 0) {
            const bag_class = if (std.mem.indexOfScalar(u8, loot, ',')) |ci| loot[0..ci] else loot;
            const bag_list = resolveProp(&classes, bag_class, "LootList", 0);
            if (bag_list) |bl| {
                if (bl.len > 0) loot = bl;
            }
        }
        var drop_prob: f32 = 1.0;
        if (resolveProp(&classes, name, "LootDropProb", 0)) |lp| {
            if (xml.parseF32(lp)) |f| drop_prob = f;
        }
        // MoveSpeedAggro "min, max": take max (night chase). MoveSpeed = shamble.
        var chase: f32 = 0;
        if (resolveProp(&classes, name, "MoveSpeedAggro", 0)) |msa| {
            const comma = std.mem.indexOfScalar(u8, msa, ',');
            const hi = if (comma) |ci| std.mem.trim(u8, msa[ci + 1 ..], " ") else msa;
            if (xml.parseF32(hi)) |f| chase = f;
        }
        var wander: f32 = 0;
        if (resolveProp(&classes, name, "MoveSpeed", 0)) |ms| {
            if (xml.parseF32(ms)) |f| wander = f;
        }
        const hand = resolveProp(&classes, name, "HandItem", 0) orelse "";
        try list.append(allocator, .{
            .name = name,
            .hash = unity_hash.unityStringHash(name),
            .max_hp = max_hp,
            .kind = kind,
            .loot_list = loot,
            .loot_drop_prob = drop_prob,
            .spawnable = spawnable,
            .is_enemy = is_enemy,
            .chase_speed = chase,
            .wander_speed = wander,
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
    var t = loadFromPath(std.testing.allocator, path) catch return error.SkipZigTest;
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
    const stag = t.byName("animalStag") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(components.Kind.animal, stag.kind);
    try std.testing.expect(stag.spawnable);
}
