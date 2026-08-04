//! ECS world: dense SoA columns, resources, O(1) net id map, spawn helpers.

const std = @import("std");
const ent = @import("entity.zig");
const c = @import("components.zig");
const electric = @import("electric.zig");
const quest = @import("quest.zig");
const director = @import("aidirector.zig");

pub const max_entities = ent.max_entities;
pub const Slot = ent.Slot;
pub const NetId = ent.NetId;
pub const Kind = c.Kind;
pub const Mask = c.Mask;

pub const EntityClass = struct {
    name: []const u8 = "zombie",
    max_hp: f32 = 40,
    kind: Kind = .zombie,
    /// ECD wire class (Unity Mono GetHashCode). 0 = stock zombieBoe default at encode.
    hash: i32 = 0,
    loot_list: []const u8 = "",
    /// XML MoveSpeedAggro max scaled to sim m/s; 0 = use systems default.
    chase_speed: f32 = 0,
    /// XML MoveSpeed scaled; 0 = use systems default.
    wander_speed: f32 = 0,
    /// HandItem Action0 DamageEntity from items.xml; 0 = use systems default.
    attack_damage: f32 = 0,
};

pub const World = struct {
    alive: [max_entities]bool = .{false} ** max_entities,
    mask: [max_entities]Mask = [_]Mask{.{}} ** max_entities,

    transform: [max_entities]c.Transform = [_]c.Transform{.{}} ** max_entities,
    health: [max_entities]c.Health = [_]c.Health{.{}} ** max_entities,
    network_id: [max_entities]c.NetworkId = [_]c.NetworkId{.{}} ** max_entities,
    kind: [max_entities]c.Kind = [_]c.Kind{.zombie} ** max_entities,
    player: [max_entities]c.Player = [_]c.Player{.{}} ** max_entities,
    zombie_ai: [max_entities]c.ZombieAi = [_]c.ZombieAi{.{}} ** max_entities,
    vehicle: [max_entities]c.Vehicle = [_]c.Vehicle{.{}} ** max_entities,
    turret: [max_entities]c.Turret = [_]c.Turret{.{}} ** max_entities,
    trader_stock: [max_entities]c.TraderStock = [_]c.TraderStock{.{}} ** max_entities,
    journal: [max_entities]c.Journal = [_]c.Journal{.{}} ** max_entities,
    wallet: [max_entities]c.Wallet = [_]c.Wallet{.{}} ** max_entities,
    inventory: [max_entities]c.Inventory = [_]c.Inventory{.{}} ** max_entities,
    class_id: [max_entities]c.ClassId = [_]c.ClassId{.{}} ** max_entities,
    loot_bag: [max_entities]c.LootBag = [_]c.LootBag{.{}} ** max_entities,
    sleeper: [max_entities]c.Sleeper = [_]c.Sleeper{.{}} ** max_entities,
    flags: [max_entities]c.Flags = [_]c.Flags{.{}} ** max_entities,
    dirty: [max_entities]c.Dirty = [_]c.Dirty{.{}} ** max_entities,

    next_net_id: i32 = 100,
    /// O(1) NetId → Slot (0xFFFF = empty).
    net_to_slot: std.AutoHashMap(i32, Slot) = undefined,
    net_map_init: bool = false,

    catalog: quest.Catalog = quest.Catalog.builtin(),
    power: electric.PowerGrid = .{},
    director: director.Director = .{},
    /// Zombie chase/wander speed multiplier from ZombieMove* serverconfig, set by
    /// the director each tick per day/night/blood-moon state (1.0 = sim default).
    zombie_speed_scale: f32 = 1.0,
    completed_quests: u32 = 0,
    /// Monotonic stock-like Quest.QuestCode allocator (starts above catalog ids).
    next_quest_code: i32 = 10000,

    /// Optional terrain-height hook backing vehicle physics. Game sets these to
    /// the block store; unset (null) means no terrain data (headless / tests) so
    /// physics is skipped and no fake flat floor is invented.
    ground_ctx: ?*anyopaque = null,
    ground_fn: ?*const fn (?*anyopaque, i32, i32) f32 = null,
    /// Optional solid-cell probe for AI pathing: true = blocked at feet.
    /// Unset → open grid (tests / headless). Game wires world.isSolidWorld at body y.
    solid_ctx: ?*anyopaque = null,
    solid_fn: ?*const fn (?*anyopaque, i32, i32) bool = null,
    /// Optional item_id → placeable block id (AssignIds). Null → inventory offline map.
    place_ctx: ?*anyopaque = null,
    place_fn: ?*const fn (?*anyopaque, u16) u16 = null,
    /// Optional item_id → items.xml FuelValue (0 = not fuel). Game wires ItemTable.
    fuel_value_ctx: ?*anyopaque = null,
    fuel_value_fn: ?*const fn (?*anyopaque, u16) f32 = null,
    /// Optional item_id → max stack (items.xml Stacknumber). Null → builtin_defs.
    stack_ctx: ?*anyopaque = null,
    stack_fn: ?*const fn (?*anyopaque, u16) u16 = null,
    /// Optional item_id → armor? (name prefix armor*). Null → offline pin.
    is_armor_ctx: ?*anyopaque = null,
    is_armor_fn: ?*const fn (?*anyopaque, u16) bool = null,

    class_table: [16]EntityClass = [_]EntityClass{
        .{ .name = "player", .max_hp = 100, .kind = .player, .hash = 2001454542 },
        .{ .name = "zombie", .max_hp = 40, .kind = .zombie, .hash = 948863590, .loot_list = "EntityLootContainerRegular" },
        .{ .name = "zombieFeral", .max_hp = 60, .kind = .zombie, .hash = 948863590, .loot_list = "EntityLootContainerRegular" },
        .{ .name = "trader", .max_hp = 9999, .kind = .trader },
        .{ .name = "vehicle", .max_hp = 200, .kind = .vehicle },
        .{ .name = "turret", .max_hp = 150, .kind = .turret },
        .{ .name = "lootBag", .max_hp = 1, .kind = .loot_bag },
        .{ .name = "animal", .max_hp = 30, .kind = .animal },
    } ++ [_]EntityClass{.{}} ** 8,

    pub fn ensureNetMap(self: *World, allocator: std.mem.Allocator) !void {
        if (self.net_map_init) return;
        self.net_to_slot = std.AutoHashMap(i32, Slot).init(allocator);
        try self.net_to_slot.ensureTotalCapacity(max_entities);
        self.net_map_init = true;
    }

    pub fn deinit(self: *World) void {
        self.catalog.deinit();
        if (self.net_map_init) {
            self.net_to_slot.deinit();
            self.net_map_init = false;
        }
    }

    pub fn setCatalog(self: *World, cat: quest.Catalog) void {
        self.catalog.deinit();
        self.catalog = cat;
    }

    pub fn playerByPeer(self: *const World, peer_slot: usize) ?Slot {
        var i: Slot = 0;
        while (i < max_entities) : (i += 1) {
            if (self.alive[i] and self.mask[i].player and self.player[i].peer_slot == @as(i32, @intCast(peer_slot))) {
                return i;
            }
        }
        return null;
    }

    fn allocSlot(self: *World) ?Slot {
        var i: Slot = 0;
        while (i < max_entities) : (i += 1) {
            if (!self.alive[i]) return i;
        }
        return null;
    }

    pub fn destroy(self: *World, slot: Slot) void {
        if (slot >= max_entities or !self.alive[slot]) return;
        if (self.mask[slot].network_id and self.net_map_init) {
            _ = self.net_to_slot.remove(self.network_id[slot].id);
        }
        self.alive[slot] = false;
        self.mask[slot] = .{};
        self.dirty[slot] = .{};
    }

    /// Resting terrain height at world (x,z) via the optional ground hook, or
    /// null when unset (no terrain data; caller skips physics).
    pub fn groundY(self: *const World, x: f32, z: f32) ?f32 {
        if (self.ground_fn) |f| return f(self.ground_ctx, @intFromFloat(@floor(x)), @intFromFloat(@floor(z)));
        return null;
    }

    /// True when cell (wx,wz) blocks horizontal AI movement (optional hook).
    pub fn isPathSolid(self: *const World, wx: i32, wz: i32) bool {
        if (self.solid_fn) |f| return f(self.solid_ctx, wx, wz);
        return false;
    }

    pub fn slotOfNetId(self: *const World, id: NetId) ?Slot {
        if (self.net_map_init) {
            return self.net_to_slot.get(id);
        }
        var i: Slot = 0;
        while (i < max_entities) : (i += 1) {
            if (self.alive[i] and self.mask[i].network_id and self.network_id[i].id == id) return i;
        }
        return null;
    }

    fn registerNet(self: *World, slot: Slot, id: NetId) void {
        if (!self.net_map_init) return;
        // Pre-sized at init; insert failure only if map allocator is exhausted.
        // Fall back: slotOfNetId still walks SoA when map misses.
        self.net_to_slot.put(id, slot) catch {};
    }

    fn spawnBase(self: *World, kind: Kind, x: f32, y: f32, z: f32, hp: f32) ?Slot {
        const s = self.allocSlot() orelse return null;
        const nid = self.next_net_id;
        self.next_net_id += 1;
        self.alive[s] = true;
        self.mask[s] = .{
            .transform = true,
            .health = true,
            .network_id = true,
            .kind = true,
            .flags = true,
            .dirty = true,
            .class_id = true,
        };
        self.transform[s] = .{ .x = x, .y = y, .z = z, .yaw = 0 };
        self.health[s] = .{ .hp = hp, .max_hp = hp };
        self.network_id[s] = .{ .id = nid };
        self.kind[s] = kind;
        self.flags[s] = .{ .bits = 8 };
        self.dirty[s] = .{ .spawn = true, .pos = true };
        const cid: u16 = switch (kind) {
            .player => 0,
            .zombie => 1,
            .trader => 3,
            .vehicle => 4,
            .turret => 5,
            .loot_bag => 6,
            .animal => 7,
        };
        const ct = self.class_table[cid];
        self.class_id[s] = .{
            .id = cid,
            .hash = ct.hash,
            .loot_list = ct.loot_list,
        };
        self.registerNet(s, nid);
        return s;
    }

    /// Apply entityclasses row onto class_table slot (keeps index stable for Kind).
    pub fn setClassDef(self: *World, index: u16, def: EntityClass) void {
        if (index >= self.class_table.len) return;
        self.class_table[index] = def;
    }

    pub fn spawnZombieClass(self: *World, x: f32, y: f32, z: f32, hp: f32, class_hash: i32, loot_list: []const u8) ?NetId {
        const id = self.spawnZombie(x, y, z, hp) orelse return null;
        if (self.slotOfNetId(id)) |s| {
            self.class_id[s].hash = class_hash;
            self.class_id[s].loot_list = loot_list;
        }
        return id;
    }

    pub fn spawnAnimal(self: *World, x: f32, y: f32, z: f32, hp: f32, class_hash: i32, loot_list: []const u8) ?NetId {
        const s = self.spawnBase(.animal, x, y, z, hp) orelse return null;
        self.mask[s].zombie_ai = true; // reuse wander/flee AI
        self.zombie_ai[s] = .{
            .state = .wander,
            .wander_tx = x,
            .wander_tz = z,
        };
        self.class_id[s].hash = class_hash;
        self.class_id[s].loot_list = loot_list;
        return self.network_id[s].id;
    }

    pub fn spawnSleeperClass(self: *World, x: f32, y: f32, z: f32, hp: f32, class_hash: i32, loot_list: []const u8) ?NetId {
        const id = self.spawnZombieClass(x, y, z, hp, class_hash, loot_list) orelse return null;
        if (self.slotOfNetId(id)) |s| {
            self.mask[s].sleeper = true;
            self.sleeper[s] = .{ .awake = false, .home_x = x, .home_z = z, .volume_r = 20 };
            self.zombie_ai[s].state = .sleep;
        }
        return id;
    }

    pub fn spawnPlayer(self: *World, x: f32, y: f32, z: f32, peer_slot: i32) ?NetId {
        // One live entity per peer slot. Without this a reconnect leaves the old
        // body alive and playerByPeer keeps returning it, so sim state (inventory,
        // quests) and net state (Client.entity_id) drift onto two entities.
        if (peer_slot >= 0) {
            if (self.playerByPeer(@intCast(peer_slot))) |old| self.destroy(old);
        }
        const s = self.spawnBase(.player, x, y, z, 100) orelse return null;
        self.mask[s].player = true;
        self.mask[s].journal = true;
        self.mask[s].wallet = true;
        self.mask[s].inventory = true;
        self.player[s] = .{ .peer_slot = peer_slot };
        self.journal[s] = .{};
        self.wallet[s] = .{};
        self.inventory[s] = .{};
        // PlayerEntityStats defaults (stock full bar on fresh spawn).
        self.health[s].food = 100;
        self.health[s].food_max = 100;
        self.health[s].water = 100;
        self.health[s].water_max = 100;
        // Starter kit by stock item name → ECS id (items.builtinStockName reverse).
        // Production may refill via Game after items.xml load.
        const starter = [_]struct { u16, u16 }{
            .{ 8, 1 }, // meleeToolRepairT0StoneAxe
            .{ 2, 5 }, // foodCanBeef
            .{ 7, 20 }, // resourceWood
            .{ 6, 50 }, // casinoCoin
        };
        for (starter) |it| _ = self.inventory[s].addItem(it[0], it[1]);
        return self.network_id[s].id;
    }

    pub fn spawnZombie(self: *World, x: f32, y: f32, z: f32, hp: f32) ?NetId {
        const s = self.spawnBase(.zombie, x, y, z, hp) orelse return null;
        self.mask[s].zombie_ai = true;
        self.zombie_ai[s] = .{
            .state = .wander,
            .wander_tx = x,
            .wander_tz = z,
        };
        return self.network_id[s].id;
    }

    pub fn spawnSleeper(self: *World, x: f32, y: f32, z: f32, hp: f32) ?NetId {
        const id = self.spawnZombie(x, y, z, hp) orelse return null;
        if (self.slotOfNetId(id)) |s| {
            self.mask[s].sleeper = true;
            self.sleeper[s] = .{ .awake = false, .home_x = x, .home_z = z, .volume_r = 20 };
            self.zombie_ai[s].state = .sleep;
        }
        return id;
    }

    pub fn spawnLootBag(self: *World, x: f32, y: f32, z: f32, item_id: u16, count: u16) ?NetId {
        const s = self.spawnBase(.loot_bag, x, y, z, 1) orelse return null;
        self.mask[s].loot_bag = true;
        self.mask[s].inventory = true;
        self.loot_bag[s] = .{};
        self.inventory[s] = .{};
        _ = self.inventory[s].addItem(item_id, count);
        return self.network_id[s].id;
    }

    pub fn spawnTrader(self: *World, name: []const u8, x: f32, y: f32, z: f32) ?NetId {
        const s = self.spawnBase(.trader, x, y, z, 9999) orelse return null;
        self.mask[s].trader = true;
        self.mask[s].trader_stock = true;
        self.trader_stock[s] = .{ .name = name };
        return self.network_id[s].id;
    }

    pub fn spawnVehicle(self: *World, kind: c.VehicleKind, x: f32, y: f32, z: f32) ?NetId {
        return self.spawnVehicleEx(kind, x, y, z, 200, 0);
    }

    /// max_hp / max_speed from vehicles.xml when known (0 speed → kind default).
    pub fn spawnVehicleEx(self: *World, kind: c.VehicleKind, x: f32, y: f32, z: f32, max_hp: f32, max_speed: f32) ?NetId {
        const hp = if (max_hp > 0) max_hp else 200;
        const s = self.spawnBase(.vehicle, x, y, z, hp) orelse return null;
        self.mask[s].vehicle = true;
        self.vehicle[s] = .{
            .kind = kind,
            .fuel = if (kind == .bicycle) 0 else 100,
            .max_speed = max_speed,
        };
        return self.network_id[s].id;
    }

    pub fn spawnTurret(self: *World, x: f32, y: f32, z: f32) ?NetId {
        const s = self.spawnBase(.turret, x, y, z, 150) orelse return null;
        const nid = self.power.addNode(.consumer, @intFromFloat(x), @intFromFloat(y), @intFromFloat(z), 25) orelse {
            self.destroy(s);
            return null;
        };
        if (self.power.indexOfId(nid)) |ni| {
            self.power.nodes[ni].entity_id = self.network_id[s].id;
        }
        self.mask[s].turret = true;
        self.turret[s] = .{ .power_node = nid };
        self.power.resolve();
        return self.network_id[s].id;
    }

    pub const DamageResult = struct {
        killed: bool = false,
        /// DroppedLootContainer net id when a zombie drops scrap; -1 if none.
        loot_bag_id: i32 = -1,
        /// entityclasses LootListOnDeath name (valid for bag fill after kill).
        loot_list: []const u8 = "",
    };

    pub fn damage(self: *World, net_id: NetId, amount: f32) DamageResult {
        const s = self.slotOfNetId(net_id) orelse return .{};
        if (self.kind[s] == .trader) return .{};
        if (!self.mask[s].health) return .{};
        self.health[s].hp -= amount;
        if (self.mask[s].dirty) self.dirty[s].hp = true;
        if (self.health[s].hp <= 0) {
            // Drop loot bag for zombies/animals (caller must S2C stock ECD + Bag).
            if ((self.kind[s] == .zombie or self.kind[s] == .animal) and self.mask[s].transform) {
                const x = self.transform[s].x;
                const y = self.transform[s].y;
                const z = self.transform[s].z;
                const loot_name = if (self.mask[s].class_id) self.class_id[s].loot_list else "";
                self.destroy(s);
                const loot = self.spawnLootBag(x, y, z, 1, 5);
                return .{
                    .killed = true,
                    .loot_bag_id = if (loot) |id| id else -1,
                    .loot_list = loot_name,
                };
            }
            // Players stay in the world dead (stock death → respawn flow keeps
            // the entity; destroy() here silently desyncs the client and breaks
            // every later net-id lookup: give/kill/tele all "miss").
            if (self.kind[s] == .player) {
                self.health[s].hp = 0;
                self.alive[s] = true;
                return .{ .killed = true };
            }
            self.destroy(s);
            return .{ .killed = true };
        }
        return .{};
    }

    /// Multi-stack loot bag (death / chest fill).
    pub fn spawnLootBagStacks(self: *World, x: f32, y: f32, z: f32, stacks: []const struct { item_id: u16, count: u16 }) ?NetId {
        if (stacks.len == 0) return self.spawnLootBag(x, y, z, 1, 5);
        const first = stacks[0];
        const id = self.spawnLootBag(x, y, z, first.item_id, first.count) orelse return null;
        if (self.slotOfNetId(id)) |s| {
            var i: usize = 1;
            while (i < stacks.len) : (i += 1) {
                _ = self.inventory[s].addItem(stacks[i].item_id, stacks[i].count);
            }
        }
        return id;
    }

    pub fn setPos(self: *World, net_id: NetId, x: f32, y: f32, z: f32, yaw: f32) void {
        const s = self.slotOfNetId(net_id) orelse return;
        if (!self.mask[s].transform) return;
        self.transform[s] = .{ .x = x, .y = y, .z = z, .yaw = yaw };
        if (self.mask[s].dirty) {
            self.dirty[s].pos = true;
            self.dirty[s].rot = true;
        }
    }

    pub fn countKind(self: *const World, kind: Kind) u32 {
        var n: u32 = 0;
        var i: Slot = 0;
        while (i < max_entities) : (i += 1) {
            if (self.alive[i] and self.mask[i].kind and self.kind[i] == kind) n += 1;
        }
        return n;
    }

    pub fn netId(self: *const World, slot: Slot) NetId {
        return self.network_id[slot].id;
    }

    pub fn markDirty(self: *World, slot: Slot, bits: c.Dirty) void {
        if (!self.alive[slot]) return;
        self.mask[slot].dirty = true;
        if (bits.pos) self.dirty[slot].pos = true;
        if (bits.rot) self.dirty[slot].rot = true;
        if (bits.flags) self.dirty[slot].flags = true;
        if (bits.hp) self.dirty[slot].hp = true;
        if (bits.spawn) self.dirty[slot].spawn = true;
        if (bits.remove) self.dirty[slot].remove = true;
        if (bits.inv) self.dirty[slot].inv = true;
    }
};

test "ecs spawn player zombie damage" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const z = w.spawnZombie(5, 70, 0, 50).?;
    try std.testing.expect(w.slotOfNetId(p) != null);
    try std.testing.expect(w.slotOfNetId(z) != null);
    try std.testing.expectEqual(@as(u32, 1), w.countKind(.zombie));
    const ps = w.playerByPeer(0).?;
    try std.testing.expect(w.mask[ps].inventory);
    try std.testing.expect(w.inventory[ps].countItem(8) >= 1);
    try std.testing.expect(w.damage(z, 100).killed);
    try std.testing.expect(w.slotOfNetId(z) == null);
}
