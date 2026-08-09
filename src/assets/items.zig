//! items.xml loader + builtin sim ids with stock name/type resolution for client UI.

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");

pub const max_items: usize = 8192;

/// Matches Block.ItemsStartHere (MAX_BLOCKS). Catalog constant; wire stock_inv
/// keeps the same pin for encode. Assets must not import wire for this alone.
pub const items_start_here: i32 = 65536;

/// First free item id after Blocks.ItemsStartHere (assignLeftOverItems pre-increments).
pub const stock_first_item_type: i32 = items_start_here + 1;

/// ItemClass.Stacknumber default when no property declares one (asm.il:749089).
pub const stock_default_stack: u16 = 0x1f4; // 500

fn typeFromBuiltinId(item_id: u16) i32 {
    if (item_id == 0) return 0;
    return items_start_here + @as(i32, item_id);
}

pub const ItemDef = struct {
    /// zdtd internal id (small, used in ECS inventory).
    id: u16 = 0,
    name: []const u8 = "",
    stack: u16 = 50,
    /// Absolute stock ItemValue.type (ItemsStartHere + …). 0 = unknown.
    stock_type: i32 = 0,
    /// items.xml EconomicValue (0 = not tradeable).
    econ: u16 = 0,
    /// items.xml Action0 DamageEntity (melee hand damage; 0 = none/unset).
    entity_damage: f32 = 0,
    /// items.xml FuelValue (generator/vehicle fuel units per item; 0 = not fuel).
    fuel_value: f32 = 0,
    /// ItemActionEat (Action0 Class=Eat) or name prefix food/drink.
    is_eat: bool = false,
    /// $foodAmountAdd from effect_group (PlayerEntityStats.Food gain).
    food_amount: f32 = 0,
    /// foodHealthAmount from effect_group (HP gain on eat).
    food_health: f32 = 0,
    /// $waterAmountAdd from effect_group (PlayerEntityStats.Water gain).
    water_amount: f32 = 0,
    /// items.xml `DistractionTags` (EntityItem distraction; RE EntityItem::SetupDistraction
    /// + ItemClass::get_IsEatDistraction). Bits: 1 = eat, 2 = requires_contact, 4 = zombie.
    /// Stock ships only decoy (`zombie,requires_contact`).
    distraction_tags: u8 = 0,
    /// items.xml effect_group `DistractionRadius` (PassiveEffects.DistractionRadius,
    /// EntityItem::SetupDistraction). 0 = not a distraction.
    distraction_radius: f32 = 0,
    /// effect_group `DistractionLifetime` (tick broadcasts before the item stops
    /// attracting; stock decoy = 1).
    distraction_lifetime: i32 = 0,
    /// effect_group `DistractionStrength` (overcomes EntityAlive.distractionResistance).
    distraction_strength: f32 = 0,
    /// effect_group `DistractionEatTicks` (PassiveEffects 69): ticks an eating
    /// zombie chews the item before it dies. Stock decoy leaves it unset (0 =
    /// no eating; approach clears at close range).
    distraction_eat_ticks: i32 = 0,
};

/// EntityItem distraction parameters (RE EntityItem::SetupDistraction):
/// DistractionRadius(66), DistractionLifetime(67), DistractionStrength(68)
/// passive effects, plus the item's `DistractionTags`.
pub const Distraction = struct {
    /// Bit 1 = eat, 2 = requires_contact, 4 = zombie (stock decoy: 2|4).
    tags: u8 = 0,
    /// DistractionRadius in meters (squared on the sim side, like stock).
    radius: f32 = 0,
    /// DistractionLifetime in broadcast ticks (stock decoy = 1).
    lifetime: i32 = 0,
    /// DistractionStrength (vs EntityAlive.distractionResistance).
    strength: f32 = 0,
    /// DistractionEatTicks (PassiveEffects 69): ticks an eating zombie chews
    /// the item (0 = not eaten, approach clears at close range).
    eat_ticks: i32 = 0,
};

pub const ItemTable = struct {
    defs: []const ItemDef = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    source: enum { builtin, xml } = .builtin,
    /// All stock items from XML (name → absolute type), for IdMapping export.
    stock_names: []const []const u8 = &.{},
    stock_types: []const i32 = &.{},
    /// Resolved Stacknumber per stock_names row (Extends chain, default 500).
    stock_stacks: []const u16 = &.{},

    pub fn deinit(self: *ItemTable) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = builtin();
    }

    pub fn builtin() ItemTable {
        return .{ .defs = builtin_defs[0..], .source = .builtin };
    }

    pub fn byId(self: *const ItemTable, id: u16) ?ItemDef {
        // defs layout: builtins at [0..13) with id == index, XML items appended
        // with sequential ids from 100. Probe the computed slot; scan on miss.
        const guess: usize = if (id < builtin_defs.len)
            id
        else if (id >= 100)
            builtin_defs.len + @as(usize, id - 100)
        else
            self.defs.len;
        if (guess < self.defs.len and self.defs[guess].id == id) return self.defs[guess];
        for (self.defs) |d| if (d.id == id) return d;
        return null;
    }

    pub fn byName(self: *const ItemTable, name: []const u8) ?ItemDef {
        for (self.defs) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        // Stock items.xml name → builtin ECS row (e.g. casinoCoin → id 6).
        var id: u16 = 1;
        while (id < 64) : (id += 1) {
            const sn = builtinStockName(id) orelse continue;
            if (!std.mem.eql(u8, sn, name)) continue;
            if (self.byId(id)) |d| return d;
        }
        return null;
    }

    /// Stock ItemValue.type → item name (reverse of stockTypeFor). Walks the
    /// defs; used off the hot path for trust-boundary checks (workstation queue
    /// validation). Builtin rows carry no stock type, so this only resolves
    /// after items.xml loads.
    pub fn nameByStockType(self: *const ItemTable, stock_type: i32) ?[]const u8 {
        for (self.defs) |d| {
            if (d.stock_type == stock_type and d.name.len > 0) return d.name;
        }
        return null;
    }

    /// ECS id for a stock or short name (0 unknown). Prefers defs after XML load.
    pub fn ecsIdByName(self: *const ItemTable, name: []const u8) u16 {
        if (self.byName(name)) |d| return d.id;
        return 0;
    }

    pub fn byStockName(self: *const ItemTable, name: []const u8) ?i32 {
        for (self.stock_names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return self.stock_types[i];
        }
        // defs may carry stock_type without full stock list (builtin)
        for (self.defs) |d| {
            if (std.mem.eql(u8, d.name, name) and d.stock_type != 0) return d.stock_type;
        }
        return null;
    }

    /// Max stack for an ECS item id (items.xml Stacknumber when loaded).
    pub fn stackFor(self: *const ItemTable, item_id: u16) u16 {
        if (self.byId(item_id)) |d| {
            if (d.stack > 0) return d.stack;
        }
        return 1;
    }

    /// FuelValue from items.xml (0 if unset / not a fuel item).
    pub fn fuelValueFor(self: *const ItemTable, item_id: u16) f32 {
        if (self.byId(item_id)) |d| {
            if (d.fuel_value > 0) return d.fuel_value;
        }
        return 0;
    }

    /// True if item is ItemActionEat consumable (or builtin food/medicine).
    /// True if absolute stock type maps to an eatable def (or food*/drink* name).
    pub fn isEatStockType(self: *const ItemTable, stock_type: i32) bool {
        if (stock_type == 0) return false;
        const eid = self.ecsIdFromStockType(stock_type);
        if (eid != 0 and self.isEat(eid)) return true;
        // Name from parallel stock arrays when reverse id is 0.
        for (self.stock_types, 0..) |st, i| {
            if (st != stock_type) continue;
            if (i >= self.stock_names.len) break;
            const n = self.stock_names[i];
            if (n.len >= 4 and (std.mem.startsWith(u8, n, "food") or std.mem.startsWith(u8, n, "drink")))
                return true;
            break;
        }
        return false;
    }

    pub fn isEat(self: *const ItemTable, item_id: u16) bool {
        if (self.byId(item_id)) |d| {
            if (d.is_eat) return true;
            if (d.food_amount > 0 or d.water_amount > 0) return true;
            // Name heuristic for stock food*/drink* without parsed Action0.
            if (d.name.len >= 4 and (std.mem.startsWith(u8, d.name, "food") or std.mem.startsWith(u8, d.name, "drink")))
                return true;
        }
        // Builtin offline ids.
        return item_id == 2 or item_id == 4;
    }

    pub fn foodAmountFor(self: *const ItemTable, item_id: u16) f32 {
        if (self.byId(item_id)) |d| {
            if (d.food_amount > 0) return d.food_amount;
            if (d.is_eat or (d.name.len >= 4 and std.mem.startsWith(u8, d.name, "food"))) return 15;
        }
        if (item_id == 2) return 15;
        return 0;
    }

    pub fn foodHealthFor(self: *const ItemTable, item_id: u16) f32 {
        if (self.byId(item_id)) |d| {
            if (d.food_health > 0) return d.food_health;
            if (item_id == 4 or std.mem.eql(u8, d.name, "medicine")) return 25;
            if (d.is_eat) return 7;
        }
        if (item_id == 2) return 7;
        if (item_id == 4) return 25;
        return 0;
    }

    pub fn waterAmountFor(self: *const ItemTable, item_id: u16) f32 {
        if (self.byId(item_id)) |d| {
            if (d.water_amount > 0) return d.water_amount;
            if (d.name.len >= 5 and std.mem.startsWith(u8, d.name, "drink")) return 20;
        }
        return 0;
    }

    /// EntityItem distraction parameters for a dropped item, or null when the
    /// item carries no DistractionTags (most items; only decoy in stock V3.1.0).
    pub fn distractionFor(self: *const ItemTable, item_id: u16) ?Distraction {
        const d = self.byId(item_id) orelse return null;
        if (d.distraction_tags == 0) return null;
        return .{
            .tags = d.distraction_tags,
            .radius = d.distraction_radius,
            .lifetime = d.distraction_lifetime,
            .strength = d.distraction_strength,
            .eat_ticks = d.distraction_eat_ticks,
        };
    }

    /// Resolve ECS item_id → absolute stock type for wire encode.
    pub fn stockTypeFor(self: *const ItemTable, item_id: u16) i32 {
        if (item_id == 0) return 0;
        if (self.byId(item_id)) |d| {
            if (d.stock_type != 0) return d.stock_type;
            // alias builtin short name → stock name
            if (builtinStockName(item_id)) |sn| {
                if (self.byStockName(sn)) |t| return t;
            }
            if (d.name.len > 0) {
                if (self.byStockName(d.name)) |t| return t;
            }
        } else if (builtinStockName(item_id)) |sn| {
            if (self.byStockName(sn)) |t| return t;
        }
        // Fallback: linear relative index (always parseable; may wrong icon).
        return typeFromBuiltinId(item_id);
    }

    /// Reverse: absolute stock type → ECS item_id (0 if unknown).
    pub fn ecsIdFromStockType(self: *const ItemTable, stock_type: i32) u16 {
        if (stock_type == 0) return 0;
        // Prefer exact stock_type on defs (builtins + xml-loaded).
        for (self.defs) |d| {
            if (d.stock_type == stock_type and d.id != 0) return d.id;
        }
        // Parallel stock_types/stock_names arrays (full XML order).
        for (self.stock_types, 0..) |st, i| {
            if (st != stock_type) continue;
            const name = if (i < self.stock_names.len) self.stock_names[i] else "";
            if (name.len > 0) {
                const eid = self.ecsIdByName(name);
                if (eid != 0) return eid;
                for (self.defs) |d| {
                    if (d.id != 0 and std.mem.eql(u8, d.name, name)) return d.id;
                }
            }
            break;
        }
        // Alias builtins via computed stockTypeFor
        var id: u16 = 1;
        while (id <= 12) : (id += 1) {
            if (self.stockTypeFor(id) == stock_type) return id;
        }
        // Fallback relative index when types were encoded as 65536+ecs_id
        if (stock_type > items_start_here) {
            const rel = stock_type - items_start_here;
            if (rel > 0 and rel < 100) return @intCast(rel);
        }
        return 0;
    }

    /// NameIdMapping payload (version 1 + count + id/name pairs).
    /// LE i32 + .NET 7-bit strings; open-coded so assets stays free of wire.
    pub fn writeNameIdMapping(self: *const ItemTable, buf: []u8) ![]u8 {
        var pos: usize = 0;
        try writeI32Le(buf, &pos, 1); // FILE_VERSION
        try writeI32Le(buf, &pos, @intCast(self.stock_names.len));
        for (self.stock_names, 0..) |name, i| {
            try writeI32Le(buf, &pos, self.stock_types[i]);
            try writeDotNetString(buf, &pos, name);
        }
        return buf[0..pos];
    }
};

fn writeI32Le(buf: []u8, pos: *usize, v: i32) error{Overflow}!void {
    if (pos.* + 4 > buf.len) return error.Overflow;
    std.mem.writeInt(i32, buf[pos.*..][0..4], v, .little);
    pos.* += 4;
}

fn writeDotNetString(buf: []u8, pos: *usize, s: []const u8) error{Overflow}!void {
    var len = s.len;
    while (true) {
        if (pos.* >= buf.len) return error.Overflow;
        const b: u8 = @truncate(len);
        if (len < 0x80) {
            buf[pos.*] = b;
            pos.* += 1;
            break;
        }
        buf[pos.*] = b | 0x80;
        pos.* += 1;
        len >>= 7;
    }
    if (pos.* + s.len > buf.len) return error.Overflow;
    @memcpy(buf[pos.* .. pos.* + s.len], s);
    pos.* += s.len;
}

/// Action0/1 Class property equals `want` (ItemActionEat → Class="Eat").
fn itemActionClassIs(body: []const u8, want: []const u8) bool {
    // Prefer nested <property class="Action0"> ... Class=Eat
    var i: usize = 0;
    while (i < body.len) {
        const pi = std.mem.findPos(u8, body, i, "<property") orelse break;
        const cn = xml.attr(body, pi, "class") orelse {
            i = pi + 9;
            continue;
        };
        if (!(std.mem.startsWith(u8, cn, "Action"))) {
            i = pi + 9;
            continue;
        }
        // Find end of this property class block: next </property> after nested props.
        const rest = body[pi..];
        // Search Class value within next 400 bytes of this Action block.
        const window = if (rest.len > 500) rest[0..500] else rest;
        if (xml.propertyValue(window, "Class")) |cls| {
            if (std.mem.eql(u8, cls, want)) return true;
        }
        i = pi + 9;
    }
    return false;
}

/// First effect_group ModifyCVar add for cvar name (e.g. $foodAmountAdd).
fn firstCvarAdd(body: []const u8, cvar: []const u8) ?f32 {
    var i: usize = 0;
    while (i < body.len) {
        const ti = std.mem.findPos(u8, body, i, "triggered_effect") orelse break;
        const end = std.mem.findPos(u8, body, ti, "/>") orelse (std.mem.findPos(u8, body, ti, ">") orelse break);
        const win = body[ti .. end + 2];
        const cv = xml.attr(win, 0, "cvar") orelse {
            i = ti + 10;
            continue;
        };
        if (!std.mem.eql(u8, cv, cvar)) {
            i = ti + 10;
            continue;
        }
        const op = xml.attr(win, 0, "operation") orelse {
            i = ti + 10;
            continue;
        };
        if (!(std.mem.eql(u8, op, "add") or std.mem.eql(u8, op, "set"))) {
            i = ti + 10;
            continue;
        }
        if (xml.attr(win, 0, "value")) |v| {
            return xml.parseF32(v);
        }
        i = ti + 10;
    }
    return null;
}

/// Builtin ECS catalog (stable small ids for sim/save).
pub const builtin_defs = [_]ItemDef{
    .{ .id = 0, .name = "none", .stack = 0 },
    .{ .id = 1, .name = "scrap", .stack = 60000, .stock_type = 0 },
    .{ .id = 2, .name = "food", .stack = 50, .is_eat = true, .food_amount = 15, .food_health = 7 },
    .{ .id = 3, .name = "ammo", .stack = 150 },
    .{ .id = 4, .name = "medicine", .stack = 10, .food_health = 25 },
    .{ .id = 5, .name = "tool", .stack = 1 },
    .{ .id = 6, .name = "dukeCoin", .stack = 60000 },
    .{ .id = 7, .name = "wood", .stack = 60000 },
    .{ .id = 8, .name = "stoneAxe", .stack = 1 },
    .{ .id = 9, .name = "meleeClub", .stack = 1 },
    .{ .id = 10, .name = "cobblePlaceable", .stack = 50 },
    .{ .id = 11, .name = "armorScrap", .stack = 1 },
    .{ .id = 12, .name = "questToken", .stack = 20 },
};

/// Map builtin ECS id → stock items.xml name (vanilla; names stable through V3.1.0 b14).
pub fn builtinStockName(item_id: u16) ?[]const u8 {
    return switch (item_id) {
        1 => "resourceScrapIron",
        2 => "foodCanBeef",
        3 => "ammo9mmBulletBall",
        4 => "medicalFirstAidBandage",
        5 => "meleeToolRepairT0StoneAxe",
        6 => "casinoCoin",
        7 => "resourceWood",
        8 => "meleeToolRepairT0StoneAxe",
        9 => "meleeWpnClubT0WoodenClub",
        10 => "resourceCobblestones",
        11 => "armorPrimitiveHelmet",
        12 => "questItem",
        else => null,
    };
}

/// Load items.xml: assign stock types like ItemClass.assignLeftOverItems
/// (first free id = ItemsStartHere+1, then sequential in document order).
pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !ItemTable {
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

    var stock_names: std.ArrayList([]const u8) = .empty;
    defer stock_names.deinit(allocator);
    var stock_types: std.ArrayList(i32) = .empty;
    defer stock_types.deinit(allocator);
    var stock_stacks: std.ArrayList(u16) = .empty;
    defer stock_stacks.deinit(allocator);
    // Stacknumber Extends resolution: own value (0 = none declared) and the
    // item's Extends target per stock_names row, resolved after the loop.
    var own_stacks: std.ArrayList(u16) = .empty;
    defer own_stacks.deinit(allocator);
    var ext_names: std.ArrayList([]const u8) = .empty;
    defer ext_names.deinit(allocator);
    var stock_econs: std.ArrayList(u16) = .empty;
    defer stock_econs.deinit(allocator);
    var stock_edmgs: std.ArrayList(f32) = .empty;
    defer stock_edmgs.deinit(allocator);
    var stock_fuels: std.ArrayList(f32) = .empty;
    defer stock_fuels.deinit(allocator);
    var stock_is_eat: std.ArrayList(bool) = .empty;
    defer stock_is_eat.deinit(allocator);
    var stock_food_amt: std.ArrayList(f32) = .empty;
    defer stock_food_amt.deinit(allocator);
    var stock_food_hp: std.ArrayList(f32) = .empty;
    defer stock_food_hp.deinit(allocator);
    var stock_water_amt: std.ArrayList(f32) = .empty;
    defer stock_water_amt.deinit(allocator);
    var stock_dtags: std.ArrayList(u8) = .empty;
    defer stock_dtags.deinit(allocator);
    var stock_dradius: std.ArrayList(f32) = .empty;
    defer stock_dradius.deinit(allocator);
    var stock_dlifetime: std.ArrayList(i32) = .empty;
    defer stock_dlifetime.deinit(allocator);
    var stock_dstrength: std.ArrayList(f32) = .empty;
    defer stock_dstrength.deinit(allocator);
    var stock_deat: std.ArrayList(i32) = .empty;
    defer stock_deat.deinit(allocator);

    var next_stock: i32 = stock_first_item_type;
    var i: usize = 0;
    while (i < clean.len and stock_names.items.len < max_items) {
        const ii = std.mem.findPos(u8, clean, i, "<item ") orelse break;
        const name = xml.attr(clean, ii, "name") orelse {
            i = ii + 6;
            continue;
        };
        var exists = false;
        for (stock_names.items) |n| {
            if (std.mem.eql(u8, n, name)) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            // Stacknumber + EconomicValue from this item's property block.
            const item_end = std.mem.findPos(u8, clean, ii + 6, "<item ") orelse clean.len;
            const stack_own = xml.propertyValue(clean[ii..item_end], "Stacknumber");
            var stack: u16 = stock_default_stack;
            if (stack_own) |v| {
                stack = xml.parseU16(v) orelse stock_default_stack;
            }
            try own_stacks.append(allocator, if (stack_own != null) stack else 0);
            const ext = xml.propertyValue(clean[ii..item_end], "Extends");
            try ext_names.append(allocator, if (ext) |e| try arena.dupe(u8, e) else "");
            var econ: u16 = 0;
            if (xml.propertyValue(clean[ii..item_end], "EconomicValue")) |v| {
                econ = xml.parseU16(v) orelse 0;
            }
            try stock_econs.append(allocator, econ);
            // Action0 DamageEntity (first hit; melee hands and weapons).
            var edmg: f32 = 0;
            if (xml.propertyValue(clean[ii..item_end], "DamageEntity")) |v| {
                edmg = xml.parseF32(v) orelse 0;
            }
            try stock_edmgs.append(allocator, edmg);
            var fuel: f32 = 0;
            if (xml.propertyValue(clean[ii..item_end], "FuelValue")) |v| {
                fuel = xml.parseF32(v) orelse 0;
            }
            try stock_fuels.append(allocator, fuel);
            // ItemActionEat: Action0 Class=Eat + effect_group cvars.
            const body = clean[ii..item_end];
            var is_eat = itemActionClassIs(body, "Eat");
            const food_amt: f32 = firstCvarAdd(body, "$foodAmountAdd") orelse 0;
            const food_hp: f32 = firstCvarAdd(body, "foodHealthAmount") orelse 0;
            const water_amt: f32 = firstCvarAdd(body, "$waterAmountAdd") orelse 0;
            if (!is_eat and (food_amt > 0 or water_amt > 0)) is_eat = true;
            if (!is_eat and (std.mem.startsWith(u8, name, "food") or std.mem.startsWith(u8, name, "drink")))
                is_eat = true;
            try stock_is_eat.append(allocator, is_eat);
            try stock_food_amt.append(allocator, food_amt);
            try stock_food_hp.append(allocator, food_hp);
            try stock_water_amt.append(allocator, water_amt);
            // EntityItem distraction (stock decoy: `zombie,requires_contact`).
            var dtags: u8 = 0;
            if (xml.propertyValue(body, "DistractionTags")) |v| {
                var t = v;
                while (t.len > 0) {
                    const comma = std.mem.findScalar(u8, t, ',') orelse t.len;
                    const tag = t[0..comma];
                    if (std.mem.eql(u8, tag, "eat")) dtags |= 1;
                    if (std.mem.eql(u8, tag, "requires_contact")) dtags |= 2;
                    if (std.mem.eql(u8, tag, "zombie")) dtags |= 4;
                    t = if (comma < t.len) t[comma + 1 ..] else "";
                }
            }
            var dradius: f32 = 0;
            if (xml.passiveEffectValue(body, "DistractionRadius")) |v| {
                dradius = xml.parseF32(v) orelse 0;
            }
            var dlifetime: i32 = 0;
            if (xml.passiveEffectValue(body, "DistractionLifetime")) |v| {
                dlifetime = std.fmt.parseInt(i32, v, 10) catch 0;
            }
            var dstrength: f32 = 0;
            if (xml.passiveEffectValue(body, "DistractionStrength")) |v| {
                dstrength = xml.parseF32(v) orelse 0;
            }
            var deat: i32 = 0;
            if (xml.passiveEffectValue(body, "DistractionEatTicks")) |v| {
                deat = std.fmt.parseInt(i32, v, 10) catch 0;
            }
            try stock_dtags.append(allocator, dtags);
            try stock_dradius.append(allocator, dradius);
            try stock_dlifetime.append(allocator, dlifetime);
            try stock_dstrength.append(allocator, dstrength);
            try stock_deat.append(allocator, deat);
            try stock_stacks.append(allocator, stack);
            try stock_names.append(allocator, try arena.dupe(u8, name));
            try stock_types.append(allocator, next_stock);
            next_stock += 1;
        }
        i = ii + 6;
    }

    // Resolve Stacknumber through the Extends chain (stock items.xml declares
    // ~1144 Extends properties; a child can precede its parent in the file, so
    // this is a second pass). An item with no Stacknumber anywhere inherits the
    // ItemClass default of 500 (asm.il:749089).
    {
        var own_map: std.StringHashMapUnmanaged(u16) = .{};
        defer own_map.deinit(allocator);
        var ext_map: std.StringHashMapUnmanaged([]const u8) = .{};
        defer ext_map.deinit(allocator);
        for (stock_names.items, 0..) |n, idx| {
            if (own_stacks.items[idx] != 0) try own_map.put(allocator, n, own_stacks.items[idx]);
            if (ext_names.items[idx].len > 0) try ext_map.put(allocator, n, ext_names.items[idx]);
        }
        const max_hops: usize = 24;
        for (stock_names.items, 0..) |n, idx| {
            var cur = n;
            var hops: usize = 0;
            while (hops < max_hops) : (hops += 1) {
                if (own_map.get(cur)) |s| {
                    stock_stacks.items[idx] = s;
                    break;
                }
                cur = ext_map.get(cur) orelse break;
            }
        }
    }

    // Builtin defs: fill stock_type + stack/econ/dmg from items.xml via stock alias.
    var list: std.ArrayList(ItemDef) = .empty;
    defer list.deinit(allocator);
    for (builtin_defs) |d| {
        var def = d;
        def.name = try arena.dupe(u8, d.name);
        if (builtinStockName(d.id)) |sn| {
            for (stock_names.items, 0..) |n, idx| {
                if (!std.mem.eql(u8, n, sn)) continue;
                def.stock_type = stock_types.items[idx];
                def.stack = stock_stacks.items[idx];
                def.econ = stock_econs.items[idx];
                def.entity_damage = stock_edmgs.items[idx];
                def.fuel_value = stock_fuels.items[idx];
                def.is_eat = stock_is_eat.items[idx];
                def.food_amount = stock_food_amt.items[idx];
                def.food_health = stock_food_hp.items[idx];
                def.water_amount = stock_water_amt.items[idx];
                // Prefer stock name so byName("casinoCoin") works without alias walk.
                def.name = n;
                break;
            }
        }
        try list.append(allocator, def);
    }

    // Also register XML items as high sim ids (100+) for admin/give by stock name later.
    var next_sim: u16 = 100;
    for (stock_names.items, 0..) |n, idx| {
        var is_builtin = false;
        for (list.items) |d| {
            if (std.mem.eql(u8, d.name, n)) {
                is_builtin = true;
                break;
            }
        }
        if (is_builtin) continue;
        try list.append(allocator, .{
            .id = next_sim,
            .name = n,
            .stack = stock_stacks.items[idx],
            .stock_type = stock_types.items[idx],
            .econ = stock_econs.items[idx],
            .entity_damage = stock_edmgs.items[idx],
            .fuel_value = stock_fuels.items[idx],
            // ItemActionEat props (was missing; stack-loss isEat relied on name heuristic only).
            .is_eat = stock_is_eat.items[idx],
            .food_amount = stock_food_amt.items[idx],
            .food_health = stock_food_hp.items[idx],
            .water_amount = stock_water_amt.items[idx],
            .distraction_tags = stock_dtags.items[idx],
            .distraction_radius = stock_dradius.items[idx],
            .distraction_lifetime = stock_dlifetime.items[idx],
            .distraction_strength = stock_dstrength.items[idx],
            .distraction_eat_ticks = stock_deat.items[idx],
        });
        next_sim +%= 1;
        if (list.items.len >= max_items) break;
    }

    const defs = try arena.alloc(ItemDef, list.items.len);
    @memcpy(defs, list.items);
    const sn = try arena.alloc([]const u8, stock_names.items.len);
    @memcpy(sn, stock_names.items);
    const st = try arena.alloc(i32, stock_types.items.len);
    @memcpy(st, stock_types.items);
    const ss = try arena.alloc(u16, stock_stacks.items.len);
    @memcpy(ss, stock_stacks.items);

    return .{
        .defs = defs,
        .arena_ptr = arena_holder,
        .source = .xml,
        .stock_names = sn,
        .stock_types = st,
        .stock_stacks = ss,
    };
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?ItemTable {
    const paths = @import("paths.zig");
    return paths.tryLoadConfig("items.xml", ItemTable, loadFromPath, allocator, game_dir, config_dir);
}

test "builtin items" {
    const t = ItemTable.builtin();
    try std.testing.expectEqualStrings("dukeCoin", t.byId(6).?.name);
    try std.testing.expectEqualStrings("meleeToolRepairT0StoneAxe", builtinStockName(8).?);
}

// ecs/inventory keeps a leaf offline mirror (no assets import). Drift here breaks
// fixture place/stack/armor when stack_fn/place_fn are unset.
test "ecs offline inventory catalog mirrors builtins" {
    const inv = @import("../ecs/inventory.zig");
    for (builtin_defs) |d| {
        const want_stack: u16 = if (d.stack == 0) 1 else d.stack;
        try std.testing.expectEqual(want_stack, inv.maxStackBuiltin(d.id));
    }
    var id: u16 = 1;
    while (id <= 12) : (id += 1) {
        const a = builtinStockName(id);
        const b = inv.builtinStockNameFallback(id);
        if (a == null and b == null) continue;
        try std.testing.expect(a != null and b != null);
        try std.testing.expectEqualStrings(a.?, b.?);
    }
    try std.testing.expect(inv.isArmorOffline(11));
    try std.testing.expect(!inv.isArmorOffline(7));
}

test "stock type first item is ItemsStartHere+1" {
    try std.testing.expectEqual(@as(i32, 65537), stock_first_item_type);
}

test "DistractionTags + Distraction* effects parse (stock decoy shape)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items.xml", .{dir});
    try io_fs.writeFile(path, "<items>\n" ++
        "  <item name=\"resourceRockDecoy\">\n" ++
        "    <property name=\"ThrowableDecoy\" value=\"true\"/>\n" ++
        "    <property name=\"DistractionTags\" value=\"zombie,requires_contact\"/>\n" ++
        "    <effect_group name=\"decoy\" tiered=\"false\">\n" ++
        "      <passive_effect name=\"DistractionRadius\" operation=\"base_set\" value=\"25\"/>\n" ++
        "      <passive_effect name=\"DistractionLifetime\" operation=\"base_set\" value=\"1\"/>\n" ++
        "      <passive_effect name=\"DistractionStrength\" operation=\"base_set\" value=\"100\"/>\n" ++
        "    </effect_group>\n" ++
        "  </item>\n" ++
        "  <item name=\"foodBait\">\n" ++
        "    <property name=\"DistractionTags\" value=\"zombie,eat\"/>\n" ++
        "    <effect_group name=\"decoy\">\n" ++
        "      <passive_effect name=\"DistractionRadius\" operation=\"base_set\" value=\"10\"/>\n" ++
        "      <passive_effect name=\"DistractionLifetime\" operation=\"base_set\" value=\"5\"/>\n" ++
        "      <passive_effect name=\"DistractionStrength\" operation=\"base_set\" value=\"50\"/>\n" ++
        "      <passive_effect name=\"DistractionEatTicks\" operation=\"base_set\" value=\"12\"/>\n" ++
        "    </effect_group>\n" ++
        "  </item>\n" ++
        "  <item name=\"resourceWood\">\n" ++
        "    <property name=\"Stacknumber\" value=\"100\"/>\n" ++
        "  </item>\n" ++
        "</items>\n");
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const decoy = t.byName("resourceRockDecoy").?;
    const d = t.distractionFor(decoy.id).?;
    try std.testing.expectEqual(@as(u8, 2 | 4), d.tags); // requires_contact + zombie
    try std.testing.expectEqual(@as(f32, 25), d.radius);
    try std.testing.expectEqual(@as(i32, 1), d.lifetime);
    try std.testing.expectEqual(@as(f32, 100), d.strength);
    try std.testing.expectEqual(@as(i32, 0), d.eat_ticks); // decoy is not eaten
    // Eat distraction parses the DistractionEatTicks passive effect.
    const bait = t.byName("foodBait").?;
    const b = t.distractionFor(bait.id).?;
    try std.testing.expectEqual(@as(u8, 1 | 4), b.tags);
    try std.testing.expectEqual(@as(f32, 10), b.radius);
    try std.testing.expectEqual(@as(i32, 12), b.eat_ticks);
    // Plain items are not distractions.
    const wood = t.byName("resourceWood").?;
    try std.testing.expect(t.distractionFor(wood.id) == null);
}

test "load stock items.xml when present" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days To Die/Data/Config/items.xml";
    var t = loadFromPath(std.testing.allocator, path) catch return error.SkipZigTest;
    defer t.deinit();
    try std.testing.expect(t.stock_names.len > 100);
    try std.testing.expectEqual(@as(i32, 65537), t.byStockName("meleeToolRepairT0StoneAxe").?);
    try std.testing.expectEqual(t.byStockName("meleeToolRepairT0StoneAxe").?, t.stockTypeFor(8));
    try std.testing.expect(t.stockTypeFor(7) > stock_first_item_type); // wood
    // Stock gas can: FuelValue from items.xml (ammoGasCan).
    if (t.byName("ammoGasCan")) |gas| {
        try std.testing.expect(gas.fuel_value > 0);
        try std.testing.expectEqual(gas.fuel_value, t.fuelValueFor(gas.id));
    }
    var buf: [512 * 1024]u8 = undefined;
    const map = try t.writeNameIdMapping(&buf);
    try std.testing.expect(map.len > 16);
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, map[0..4], .little));
}

test "stock items.xml Stacknumber default and Extends resolution" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/items.xml";
    var t = loadFromPath(std.testing.allocator, path) catch return error.SkipZigTest;
    defer t.deinit();
    const stackOf = struct {
        fn f(tab: *const ItemTable, name: []const u8) u16 {
            for (tab.stock_names, 0..) |n, i| {
                if (std.mem.eql(u8, n, name)) return tab.stock_stacks[i];
            }
            return 0;
        }
    }.f;
    // Leaf with no Stacknumber and no Extends: ItemClass default 500.
    try std.testing.expectEqual(@as(u16, 500), stackOf(&t, "meleeToolRepairT0StoneAxe"));
    // One Extends hop: ammoArrowExploding -> ammoArrowIron (75).
    try std.testing.expectEqual(@as(u16, 75), stackOf(&t, "ammoArrowExploding"));
    // Two hops: meleeHandZombieFeral -> meleeHandZombie01 -> meleeHandMaster (1).
    try std.testing.expectEqual(@as(u16, 1), stackOf(&t, "meleeHandZombieFeral"));
    // The builtin stone axe (id 8) inherits the resolved stack via its stock alias.
    try std.testing.expectEqual(@as(u16, 500), t.byId(8).?.stack);
}
