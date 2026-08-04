//! All sim component types (plain data; no behavior). SoA columns live on World.

pub const Kind = enum(u8) {
    player,
    zombie,
    trader,
    vehicle,
    turret,
    loot_bag,
    animal,
};

pub const Transform = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    yaw: f32 = 0,
};

pub const Health = struct {
    hp: f32 = 0,
    max_hp: f32 = 0,
};

pub const NetworkId = struct {
    id: i32 = 0,
};

pub const Player = struct {
    peer_slot: i32 = -1,
};

pub const ClassId = struct {
    /// Index into World.class_table.
    id: u16 = 0,
    /// Unity Mono name hash for ECD EntitySpawn (0 = use table/default).
    hash: i32 = 0,
    /// Loot container name from entityclasses LootListOnDeath (empty = default scrap).
    loot_list: []const u8 = "",
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
/// single cell: the two real zombie tasks are mutex-exclusive so at most one
/// runs at a time). `.none` = no task selected (fresh/sleeping). See
/// zombie_tasks in systems.zig for the ported priority/mutex table.
pub const TaskId = enum(u8) { none, approach_attack, wander };

pub const ZombieAi = struct {
    state: AiState = .idle,
    target_id: i32 = -1,
    /// Stock EAITaskEntry.executeTime: per-task re-evaluation timer.
    decision_cd: f32 = 0,
    /// Winning task from the last selection pass (EAITaskList executing set).
    active_task: TaskId = .none,
    attack_cd: f32 = 0,
    wander_tx: f32 = 0,
    wander_tz: f32 = 0,
    alert: bool = false,
    active_scale: f32 = 1,
    path_goal_x: f32 = 0,
    path_goal_z: f32 = 0,
    has_path: bool = false,
    /// Seconds until next A* replan (chase only).
    path_replan_cd: f32 = 0,
    /// Next waypoint cell (world block xz) while following a planned path.
    path_wp_x: i32 = 0,
    path_wp_z: i32 = 0,
    path_wp_valid: bool = false,
    /// Per-entity xorshift state for wander decisions (0 = unseeded; first
    /// decision seeds from net id so streams differ per entity).
    wander_rng: u32 = 0,
};

pub const VehicleKind = enum(u8) {
    bicycle = 0,
    minibike = 1,
    motorcycle = 2,
    four_by_four = 3,
    gyrocopter = 4,
};

pub const Vehicle = struct {
    kind: VehicleKind = .minibike,
    speed: f32 = 0,
    fuel: f32 = 100,
    driver_net_id: i32 = -1,
    /// Vertical velocity accumulator for gravity integration (systemVehicles).
    vy: f32 = 0,
    /// Cap from vehicles.xml velocityMax; 0 → kind default in vehicleControl.
    max_speed: f32 = 0,
};

pub const Turret = struct {
    range: f32 = 24,
    damage: f32 = 12,
    fire_cd: f32 = 0,
    fire_interval: f32 = 0.4,
    ammo: u16 = 200,
    target_id: i32 = -1,
    power_node: u16 = 0,
};

pub const max_journal: usize = 8;
pub const max_stock: usize = 12;
/// Toolbelt 0..9, bag 10..41, equipment 42..46 (armor slots), total 47.
pub const inv_toolbelt: usize = 10;
pub const inv_bag_start: usize = 10;
pub const inv_bag_count: usize = 32;
pub const inv_equip_start: usize = 42;
pub const inv_equip_count: usize = 5;
pub const max_inv_slots: usize = inv_equip_start + inv_equip_count; // 47
pub const inv_no_holding: u16 = 0xFFFF;

pub const QuestProgress = struct {
    def_id: u16 = 0,
    /// Stock Quest.QuestCode (distinct from catalog def_id when possible).
    quest_code: i32 = 0,
    active: bool = false,
    completed: bool = false,
    ready_turn_in: bool = false,
    progress: u16 = 0,
    /// 1-based phase matching stock quest objective phase attributes.
    phase: u8 = 1,
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
};

pub const Wallet = struct {
    coins: u32 = 0,
};

pub const InvSlot = struct {
    item_id: u16 = 0,
    count: u16 = 0,
    quality: u8 = 0,
    meta: u16 = 0, // durability / seed / etc.
};

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

    /// Prefer toolbelt then bag for stacking/placement. Respects max_stack.
    pub fn addItem(self: *Inventory, item_id: u16, count: u16) bool {
        return self.addItemStacked(item_id, count, 60000);
    }

    pub fn addItemStacked(self: *Inventory, item_id: u16, count: u16, max_stack: u16) bool {
        if (item_id == 0 or count == 0) return false;
        // All-or-nothing: a partial deposit followed by `false` makes callers
        // that refund on failure duplicate items (container take/put, craft).
        var room_total: u32 = 0;
        for (self.slots[0..inv_equip_start]) |s| {
            if (s.count == 0) {
                room_total += max_stack;
            } else if (s.item_id == item_id and s.count < max_stack) {
                room_total += max_stack - s.count;
            }
        }
        if (room_total < count) return false;
        var left = count;
        // stack into existing (toolbelt first, then bag)
        var i: usize = 0;
        while (i < inv_equip_start and left > 0) : (i += 1) {
            const s = &self.slots[i];
            if (s.item_id != item_id or s.count == 0) continue;
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
            s.* = .{ .item_id = item_id, .count = put, .quality = 1 };
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
        if (s.item_id != item.item_id) return false;
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
        if (dst.item_id == src.item_id) {
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

test "putInSlot rejects overflowing stack counts" {
    var inv: Inventory = .{};
    inv.slots[0] = .{ .item_id = 1, .count = std.math.maxInt(u16) };
    try std.testing.expect(!inv.putInSlot(0, .{ .item_id = 1, .count = 1 }, std.math.maxInt(u16)));
    try std.testing.expectEqual(std.math.maxInt(u16), inv.slots[0].count);
}

pub const StockEntry = struct {
    item: u16 = 0,
    count: u16 = 0,
    price: u16 = 0,
    sell: u16 = 0,
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
    name: []const u8 = "Trader",
    entries: [max_stock]StockEntry = defaultStock(),
    n: usize = 5,
};

pub const LootBag = struct {
    /// Simple loot: first inv slots.
    open: bool = false,
};

pub const Sleeper = struct {
    awake: bool = false,
    volume_r: f32 = 16,
    home_x: f32 = 0,
    home_z: f32 = 0,
};

pub const Flags = struct {
    bits: u16 = 8, // Spawned
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
    dirty: bool = false,
    _pad: u14 = 0,
};
