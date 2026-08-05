//! ECS world: dense SoA columns, resources, O(1) net id map, spawn helpers.

const std = @import("std");
const ent = @import("entity.zig");
const c = @import("components.zig");
const electric = @import("electric.zig");
const quest = @import("quest.zig");
const director = @import("aidirector.zig");
const command = @import("command.zig");
const inv_ledger = @import("inv_ledger.zig");
const locals_mod = @import("locals.zig");
const observers_mod = @import("observers.zig");
const group = @import("group.zig");

pub const max_entities = ent.max_entities;
/// Soft capacity warning threshold (fraction of max_entities).
pub const warn_ratio: f32 = 0.8;
const entity_warn_at: usize = @intFromFloat(@as(f32, @floatFromInt(max_entities)) * warn_ratio);
pub const InvLedger = inv_ledger.Ledger;
pub const InvCause = inv_ledger.Cause;
pub const Slot = ent.Slot;
pub const NetId = ent.NetId;
pub const Kind = c.Kind;
pub const Mask = c.Mask;
pub const CommandBuffer = command.Buffer;
pub const CommandOp = command.Op;
pub const TickLocals = locals_mod.TickLocals;
pub const ObserverRegistry = observers_mod.Registry;

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
    const no_player_slot = std.math.maxInt(Slot);

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

    /// Peer slots are bounded by the server's fixed client table. Keeping the
    /// reverse index here avoids a full entity scan in every C2S inventory,
    /// quest, movement, and replication lookup.
    peer_to_player: [max_entities]Slot = .{no_player_slot} ** max_entities,

    next_net_id: i32 = 100,
    /// Live entity slots (spawnBase ++, destroy --). Soft-warn path only.
    entity_count: u16 = 0,
    /// Per-slot reincarnation counter (generation-counted handles).
    slot_gen: [max_entities]u32 = .{0} ** max_entities,
    /// Cached per-kind dense slot lists (spawnBase inserts, destroy removes),
    /// kept slot-ascending so group iteration equals the open View scan. Owns
    /// the per-kind live count too, so countKind is O(1) off the same fact.
    kind_groups: group.Groups = .{},
    /// Once: soft warning when entity_count crosses entity_warn_at.
    entity_cap_warned: bool = false,
    /// Slots freed since the last beginTick. allocSlot avoids these so a slot
    /// is never recycled within one tick: per-client known_entities is keyed
    /// by slot and only reconciled against alive[] once per tick, so same-tick
    /// reuse (destroy then spawnLootBag) would suppress the EntitySpawn.
    freed_this_tick: [max_entities]bool = .{false} ** max_entities,
    /// True when any destroy() ran since beginTick. Replicate skips the
    /// known_entities reconcile when no slots were freed this tick.
    any_freed_this_tick: bool = false,
    /// O(1) NetId → Slot (0xFFFF = empty).
    net_to_slot: std.AutoHashMap(i32, Slot) = undefined,
    net_map_init: bool = false,
    /// Set when a net_to_slot insert failed (OOM): the map may be missing
    /// entries, so slotOfNetId must fall back to the SoA scan on miss.
    net_map_degraded: bool = false,

    catalog: quest.Catalog = quest.Catalog.builtin(),
    power: electric.PowerGrid = .{},
    director: director.Director = .{},
    /// Deferred ops drained once per tick (end of tickAll / Game.step). Cap 64.
    commands: CommandBuffer = .{},
    /// Named tick scratch (interest ids, despawn lists). Cleared in beginTick.
    locals: TickLocals = .{},
    /// on_spawn / on_death listeners (cap 4). No heap.
    observers: ObserverRegistry = .{},
    /// P4 inv cause ring (last N mutations). Hot path: fixed, no heap.
    inv_ledger: InvLedger = .{},
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
    /// A* replans issued this tick. Atomic: the AI phase runs on parallel
    /// workers. Cleared by beginTick and surfaced as TickResult.path_replans
    /// (ecs must not import apm; see the note on commands_applied).
    path_replans: std.atomic.Value(u32) = .init(0),
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

    // A10: offline defaults use stock loot container name (not item "scrap").
    // Game.setClassDef overwrites from entityclasses when game-dir loads.
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

    /// Catalog stack cap: `stack_fn` (items.xml Stacknumber) or offline builtins.
    /// Single source for deposit paths; do not hardcode 60000 at call sites.
    pub fn maxStack(self: *const World, item_id: u16) u16 {
        if (self.stack_fn) |f| return f(self.stack_ctx, item_id);
        return c.maxStackOffline(item_id);
    }

    /// Deposit into an entity inventory slot respecting catalog stack caps.
    pub fn depositItem(self: *World, s: Slot, item_id: u16, count: u16) bool {
        if (!self.mask[s].inventory) return false;
        return self.inventory[s].addItemStacked(item_id, count, self.maxStack(item_id));
    }

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
        if (peer_slot < self.peer_to_player.len) {
            const slot = self.peer_to_player[peer_slot];
            if (slot != no_player_slot and self.alive[slot] and self.mask[slot].player and
                self.player[slot].peer_slot == @as(i32, @intCast(peer_slot)))
            {
                return slot;
            }
            // In-range index is maintained by spawnPlayer/destroy and is
            // authoritative: a miss means no player for this peer. The full
            // scan below is reserved for out-of-range synthetic peer ids;
            // running it on every miss cost O(max_entities) per call on the
            // per-tick packet/quest paths.
            return null;
        }
        // Preserve the standalone ECS API for callers using an out-of-range
        // synthetic peer id.
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
            if (!self.alive[i] and !self.freed_this_tick[i]) return i;
        }
        // At capacity: fall back to just-freed slots rather than failing the spawn.
        i = 0;
        while (i < max_entities) : (i += 1) {
            if (!self.alive[i]) return i;
        }
        return null;
    }

    pub fn destroy(self: *World, slot: Slot) void {
        if (slot >= max_entities or !self.alive[slot]) return;
        const death_id: NetId = if (self.mask[slot].network_id) self.network_id[slot].id else 0;
        // Capture kind before mask clear for the kind group.
        const had_kind = self.mask[slot].kind;
        const kind_val = self.kind[slot];
        // Mark dead before notifying: a listener that cascades into destroy()
        // on this same slot would otherwise recurse without bound.
        self.alive[slot] = false;
        self.freed_this_tick[slot] = true;
        self.any_freed_this_tick = true;
        // Drop from the group here too, so a death listener iterating a group
        // sees exactly what alive[] already tells it: this slot is gone.
        if (had_kind) self.kind_groups.remove(kind_val, slot);
        self.observers.fireDeath(self, slot, death_id);
        if (self.mask[slot].player) {
            const peer_slot = self.player[slot].peer_slot;
            if (peer_slot >= 0 and peer_slot < @as(i32, @intCast(self.peer_to_player.len)) and
                self.peer_to_player[@intCast(peer_slot)] == slot)
            {
                self.peer_to_player[@intCast(peer_slot)] = no_player_slot;
            }
        }
        if (self.mask[slot].network_id and self.net_map_init) {
            _ = self.net_to_slot.remove(self.network_id[slot].id);
        }
        // Turrets own a consumer power node; drop it or it draws load forever.
        // By id: two turrets can share a cell, and removeAt would take the wrong one.
        if (self.mask[slot].turret) _ = self.power.removeById(self.turret[slot].power_node);
        self.alive[slot] = false;
        self.freed_this_tick[slot] = true;
        self.mask[slot] = .{};
        self.dirty[slot] = .{};
        if (self.entity_count > 0) self.entity_count -= 1;
    }

    /// Un-kill a slot that is still populated (respawn of a dead player whose
    /// entity was never destroyed). The single sanctioned way to set alive[]
    /// back to true: raw writes would drift the kind group. Idempotent.
    pub fn reviveSlot(self: *World, slot: Slot) void {
        if (slot >= max_entities or !self.mask[slot].kind) return;
        if (!self.alive[slot]) {
            self.alive[slot] = true;
            self.entity_count +%= 1;
        }
        self.kind_groups.insert(self.kind[slot], slot);
    }

    /// Clear tick locals at the start of each sim frame (schedule / tickAll).
    pub fn beginTick(self: *World) void {
        @memset(&self.freed_this_tick, false);
        self.path_replans.store(0, .monotonic);
        // any_freed_this_tick stays set until replicate reconciles known_entities:
        // net poll / admin may destroy before beginTick, sim after it.
        self.locals.clear();
    }

    fn notifySpawn(self: *World, slot: Slot) void {
        if (!self.alive[slot] or !self.mask[slot].network_id) return;
        self.observers.fireSpawn(self, slot, self.network_id[slot].id);
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

    /// True when handle still points at the same reincarnation of this slot.
    pub fn handleAlive(self: *const World, h: ent.EntityHandle) bool {
        if (h.slot >= max_entities or !self.alive[h.slot]) return false;
        if (!self.mask[h.slot].network_id) return false;
        return self.network_id[h.slot].gen == h.gen;
    }

    pub fn handleOfSlot(self: *const World, slot: Slot) ent.EntityHandle {
        if (slot >= max_entities or !self.alive[slot] or !self.mask[slot].network_id)
            return .invalid();
        return .{ .slot = slot, .gen = self.network_id[slot].gen };
    }

    pub fn slotOfNetId(self: *const World, id: NetId) ?Slot {
        if (self.net_map_init) {
            if (self.net_to_slot.get(id)) |slot| return slot;
            // A healthy map is authoritative: a miss means the id is gone.
            // Stale-target lookups are the common case on the per-tick AI
            // path, and the full scan below made every miss O(max_entities).
            if (!self.net_map_degraded) return null;
        }
        // The SoA columns are authoritative. The map is a derived index and
        // may miss after a failed insertion, so preserve correctness with the
        // bounded scan promised by registerNet's failure path.
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
        self.net_to_slot.put(id, slot) catch {
            self.net_map_degraded = true;
            std.debug.print(
                "zdtd: net_to_slot put failed id={d} slot={d} (OOM? using linear lookup)\n",
                .{ id, slot },
            );
        };
    }

    fn spawnBase(self: *World, kind: Kind, x: f32, y: f32, z: f32, hp: f32) ?Slot {
        const s = self.allocSlot() orelse return null;
        const nid = self.next_net_id;
        self.next_net_id += 1;
        self.alive[s] = true;
        self.entity_count +%= 1;
        self.kind_groups.insert(kind, s);
        if (!self.entity_cap_warned and self.entity_count >= entity_warn_at) {
            self.entity_cap_warned = true;
            std.debug.print(
                "zdtd: entity slots near capacity n={d}/{d} (warn>={d})\n",
                .{ self.entity_count, max_entities, entity_warn_at },
            );
        }
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
        self.slot_gen[s] +%= 1;
        self.network_id[s] = .{ .id = nid, .gen = self.slot_gen[s] };
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

    /// Lookup class_table index by name (first match). Null if missing.
    pub fn findClassByName(self: *const World, class_name: []const u8) ?u16 {
        var i: u16 = 0;
        while (i < self.class_table.len) : (i += 1) {
            if (self.class_table[i].name.len == 0) continue;
            if (std.mem.eql(u8, self.class_table[i].name, class_name)) return i;
        }
        return null;
    }

    /// Prefab spawn: fill zombie from class_table[class_id] (hp/hash/loot).
    pub fn spawnZombieFromClassId(self: *World, class_id: u16, x: f32, y: f32, z: f32) ?NetId {
        if (class_id >= self.class_table.len) return null;
        const ct = self.class_table[class_id];
        if (ct.kind != .zombie) return null;
        const hp = if (ct.max_hp > 0) ct.max_hp else 40;
        const id = self.spawnZombie(x, y, z, hp) orelse return null;
        if (self.slotOfNetId(id)) |s| {
            self.class_id[s] = .{
                .id = class_id,
                .hash = ct.hash,
                .loot_list = ct.loot_list,
            };
        }
        return id;
    }

    /// Prefab spawn by entityclasses name (class_table scan).
    pub fn spawnZombieFromClass(self: *World, class_name: []const u8, x: f32, y: f32, z: f32) ?NetId {
        const idx = self.findClassByName(class_name) orelse return null;
        return self.spawnZombieFromClassId(idx, x, y, z);
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
        self.notifySpawn(s);
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
        if (peer_slot >= 0 and peer_slot < @as(i32, @intCast(self.peer_to_player.len))) {
            self.peer_to_player[@intCast(peer_slot)] = s;
        }
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
        for (starter) |it| _ = self.depositItem(s, it[0], it[1]);
        self.notifySpawn(s);
        return self.network_id[s].id;
    }

    pub fn spawnZombie(self: *World, x: f32, y: f32, z: f32, hp: f32) ?NetId {
        const s = self.spawnBase(.zombie, x, y, z, hp) orelse return null;
        self.mask[s].zombie_ai = true;
        self.zombie_ai[s] = .{
            .state = .wander,
            .wander_tx = x,
            .wander_tz = z,
            .home_x = x,
            .home_z = z,
            .has_home = true,
        };
        self.notifySpawn(s);
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
        _ = self.depositItem(s, item_id, count);
        self.notifySpawn(s);
        return self.network_id[s].id;
    }

    pub fn spawnTrader(self: *World, name: []const u8, x: f32, y: f32, z: f32) ?NetId {
        const s = self.spawnBase(.trader, x, y, z, 9999) orelse return null;
        self.mask[s].trader = true;
        self.mask[s].trader_stock = true;
        self.trader_stock[s] = .{ .name = name };
        self.notifySpawn(s);
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
        self.notifySpawn(s);
        return self.network_id[s].id;
    }

    pub fn spawnTurret(self: *World, x: f32, y: f32, z: f32) ?NetId {
        const s = self.spawnBase(.turret, x, y, z, 150) orelse return null;
        const nid = self.power.addNode(.consumer, @intFromFloat(@floor(x)), @intFromFloat(@floor(y)), @intFromFloat(@floor(z)), 25) orelse {
            self.destroy(s);
            return null;
        };
        if (self.power.indexOfId(nid)) |ni| {
            self.power.nodes[ni].entity_id = self.network_id[s].id;
        }
        self.mask[s].turret = true;
        self.turret[s] = .{ .power_node = nid };
        self.power.resolve();
        self.notifySpawn(s);
        return self.network_id[s].id;
    }

    pub const DamageResult = struct {
        killed: bool = false,
        /// DroppedLootContainer net id when a zombie drops a loot bag; -1 if none.
        loot_bag_id: i32 = -1,
        /// entityclasses LootListOnDeath name (valid for bag fill after kill).
        loot_list: []const u8 = "",
    };

    pub fn damage(self: *World, net_id: NetId, amount: f32) DamageResult {
        const s = self.slotOfNetId(net_id) orelse return .{};
        if (self.kind[s] == .trader) return .{};
        if (!self.mask[s].health) return .{};
        // Non-positive / NaN must not heal, mark dirty, or re-fire kill side effects.
        if (!(amount > 0)) return .{};
        // Already dead (hp<=0): players stay in-world; a second hit must not
        // report killed again (double DropOnDeath bags / quest XP / loot).
        if (self.health[s].hp <= 0) return .{};
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
                self.reviveSlot(s); // no-op here (slot was never removed), but
                // keeps every alive[] = true in the repo on one path.
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
                _ = self.depositItem(s, stacks[i].item_id, stacks[i].count);
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
        return self.kind_groups.count(kind);
    }

    /// Enqueue a deferred sim op (spawn/despawn/damage). Drops when full.
    pub fn pushCommand(self: *World, op: CommandOp) bool {
        return self.commands.push(op);
    }

    /// Apply and clear the ops queued at entry; ops pushed during drain stay for the next tick.
    pub fn drainCommands(self: *World) command.DrainResult {
        return self.commands.drain(self);
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

test "damage ignores non-positive amount and already-dead players" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    try std.testing.expect(!w.damage(p, 0).killed);
    try std.testing.expect(!w.damage(p, -10).killed);
    try std.testing.expect(w.damage(p, 9999).killed);
    // Second kill must not re-fire (DropOnDeath / quest side effects).
    try std.testing.expect(!w.damage(p, 1).killed);
    const ps = w.slotOfNetId(p).?;
    try std.testing.expectEqual(@as(f32, 0), w.health[ps].hp);
    try std.testing.expect(w.alive[ps]);
}

test "net id lookup falls back to authoritative columns when index misses" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const id = w.spawnZombie(1, 2, 3, 40).?;
    const expected = w.slotOfNetId(id).?;
    try std.testing.expect(w.net_to_slot.remove(id));
    // Healthy map: a miss is authoritative (no per-miss full scan).
    try std.testing.expectEqual(null, w.slotOfNetId(id));
    // Degraded map (failed insert): the SoA scan recovers the entry.
    w.net_map_degraded = true;
    try std.testing.expectEqual(expected, w.slotOfNetId(id).?);
}

test "player peer index follows replacement and destroy" {
    var w: World = .{};
    defer w.deinit();
    const first_id = w.spawnPlayer(0, 70, 0, 3).?;
    const first = w.slotOfNetId(first_id).?;
    try std.testing.expectEqual(first, w.playerByPeer(3).?);

    const second_id = w.spawnPlayer(1, 70, 0, 4).?;
    const second = w.slotOfNetId(second_id).?;
    try std.testing.expectEqual(second, w.playerByPeer(4).?);

    w.destroy(second);
    try std.testing.expect(w.playerByPeer(4) == null);
    try std.testing.expectEqual(first, w.playerByPeer(3).?);
}

test "entity_count tracks spawn destroy and soft warn flag" {
    var w: World = .{};
    defer w.deinit();
    try std.testing.expectEqual(@as(u16, 0), w.entity_count);
    try std.testing.expectEqual(@as(u32, 0), w.countKind(.zombie));
    const z = w.spawnZombie(0, 70, 0, 40).?;
    try std.testing.expectEqual(@as(u16, 1), w.entity_count);
    try std.testing.expectEqual(@as(u32, 1), w.countKind(.zombie));
    const zs = w.slotOfNetId(z).?;
    w.destroy(zs);
    try std.testing.expectEqual(@as(u16, 0), w.entity_count);
    try std.testing.expectEqual(@as(u32, 0), w.countKind(.zombie));
    try std.testing.expect(w.any_freed_this_tick);
    // Fill to soft threshold without allocating beyond max.
    var n: usize = 0;
    while (n < entity_warn_at) : (n += 1) {
        _ = w.spawnZombie(@floatFromInt(n), 70, 0, 40) orelse break;
    }
    try std.testing.expect(w.entity_count >= entity_warn_at);
    try std.testing.expect(w.entity_cap_warned);
    try std.testing.expectEqual(@as(u32, w.entity_count), w.countKind(.zombie));
}

test "spawnZombieFromClass fills from class_table" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    w.class_table[1].max_hp = 55;
    w.class_table[1].hash = 12345;
    w.class_table[1].loot_list = "EntityLootContainerStrong";
    const id = w.spawnZombieFromClass("zombie", 3, 70, 4).?;
    const s = w.slotOfNetId(id).?;
    try std.testing.expectEqual(@as(f32, 55), w.health[s].max_hp);
    try std.testing.expectEqual(@as(i32, 12345), w.class_id[s].hash);
    try std.testing.expectEqualStrings("EntityLootContainerStrong", w.class_id[s].loot_list);
    try std.testing.expect(w.spawnZombieFromClass("nope", 0, 0, 0) == null);
}

test "beginTick clears locals" {
    var w: World = .{};
    w.locals.interest_n = 9;
    w.beginTick();
    try std.testing.expectEqual(@as(u8, 0), w.locals.interest_n);
}

test "generation-counted handle invalidates after destroy" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const id = w.spawnZombie(0, 70, 0, 40).?;
    const s = w.slotOfNetId(id).?;
    const h = w.handleOfSlot(s);
    try std.testing.expect(w.handleAlive(h));
    w.destroy(s);
    try std.testing.expect(!w.handleAlive(h));
    // Reuse slot: new gen must not match old handle.
    _ = w.spawnZombie(1, 70, 1, 40);
    try std.testing.expect(!w.handleAlive(h));
}
