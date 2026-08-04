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
};

pub const ItemTable = struct {
    defs: []const ItemDef = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    source: enum { builtin, xml } = .builtin,
    /// All stock items from XML (name → absolute type), for IdMapping export.
    stock_names: []const []const u8 = &.{},
    stock_types: []const i32 = &.{},

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
        const pi = std.mem.indexOfPos(u8, body, i, "<property") orelse break;
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
        const ti = std.mem.indexOfPos(u8, body, i, "triggered_effect") orelse break;
        const end = std.mem.indexOfPos(u8, body, ti, "/>") orelse (std.mem.indexOfPos(u8, body, ti, ">") orelse break);
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

/// Map builtin ECS id → stock items.xml name (V3.0.1 vanilla).
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

    var next_stock: i32 = stock_first_item_type;
    var i: usize = 0;
    while (i < clean.len and stock_names.items.len < max_items) {
        const ii = std.mem.indexOfPos(u8, clean, i, "<item ") orelse break;
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
            const item_end = std.mem.indexOfPos(u8, clean, ii + 6, "<item ") orelse clean.len;
            var stack: u16 = 1;
            if (xml.propertyValue(clean[ii..item_end], "Stacknumber")) |v| {
                stack = xml.parseU16(v) orelse 1;
            }
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
            try stock_stacks.append(allocator, stack);
            try stock_names.append(allocator, try arena.dupe(u8, name));
            try stock_types.append(allocator, next_stock);
            next_stock += 1;
        }
        i = ii + 6;
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

    return .{
        .defs = defs,
        .arena_ptr = arena_holder,
        .source = .xml,
        .stock_names = sn,
        .stock_types = st,
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

test "stock type first item is ItemsStartHere+1" {
    try std.testing.expectEqual(@as(i32, 65537), stock_first_item_type);
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
