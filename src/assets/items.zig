//! items.xml loader + builtin sim ids with stock name/type resolution for client UI.

const std = @import("std");
const xml = @import("xml_util.zig");
const linux = std.os.linux;
const stock_inv = @import("../wire/stock_inv.zig");

pub const max_items: usize = 8192;

/// First free item id after Blocks.ItemsStartHere (assignLeftOverItems pre-increments).
pub const stock_first_item_type: i32 = stock_inv.items_start_here + 1;

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
        for (self.defs) |d| if (d.id == id) return d;
        return null;
    }

    pub fn byName(self: *const ItemTable, name: []const u8) ?ItemDef {
        for (self.defs) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
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
        return stock_inv.typeFromBuiltinId(item_id);
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
        if (stock_type > stock_inv.items_start_here) {
            const rel = stock_type - stock_inv.items_start_here;
            if (rel > 0 and rel < 100) return @intCast(rel);
        }
        return 0;
    }

    /// NameIdMapping payload (version 1 + count + id/name pairs).
    pub fn writeNameIdMapping(self: *const ItemTable, buf: []u8) ![]u8 {
        var w: @import("../wire/binary.zig").Writer = .{ .buf = buf };
        try w.writeI32(1); // FILE_VERSION
        const n: i32 = @intCast(self.stock_names.len);
        try w.writeI32(n);
        for (self.stock_names, 0..) |name, i| {
            try w.writeI32(self.stock_types[i]);
            try w.writeString(name);
        }
        return w.written();
    }
};

/// Builtin ECS catalog (stable small ids for sim/save).
pub const builtin_defs = [_]ItemDef{
    .{ .id = 0, .name = "none", .stack = 0 },
    .{ .id = 1, .name = "scrap", .stack = 60000, .stock_type = 0 },
    .{ .id = 2, .name = "food", .stack = 50 },
    .{ .id = 3, .name = "ammo", .stack = 150 },
    .{ .id = 4, .name = "medicine", .stack = 10 },
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

fn readFileAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_z: [2048]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const rc = linux.open(path_z[0..path.len :0].ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const end = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(end) != .SUCCESS) return error.SeekFailed;
    const size: usize = @intCast(end);
    _ = linux.lseek(fd, 0, linux.SEEK.SET);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    var off: usize = 0;
    while (off < size) {
        const n = linux.read(fd, buf[off..].ptr, size - off);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        off += @intCast(n);
    }
    return buf[0..off];
}

/// Load items.xml: assign stock types like ItemClass.assignLeftOverItems
/// (first free id = ItemsStartHere+1, then sequential in document order).
pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !ItemTable {
    const raw = try readFileAll(allocator, path);
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
            try stock_stacks.append(allocator, stack);
            try stock_names.append(allocator, try arena.dupe(u8, name));
            try stock_types.append(allocator, next_stock);
            next_stock += 1;
        }
        i = ii + 6;
    }

    // Builtin defs with stock_type filled from aliases / stock table.
    var list: std.ArrayList(ItemDef) = .empty;
    defer list.deinit(allocator);
    for (builtin_defs) |d| {
        var def = d;
        def.name = try arena.dupe(u8, d.name);
        if (builtinStockName(d.id)) |sn| {
            for (stock_names.items, 0..) |n, idx| {
                if (std.mem.eql(u8, n, sn)) {
                    def.stock_type = stock_types.items[idx];
                    break;
                }
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
    var path_buf: [2048]u8 = undefined;
    if (config_dir) |cd| {
        const p = try std.fmt.bufPrint(&path_buf, "{s}/items.xml", .{cd});
        return loadFromPath(allocator, p) catch null;
    }
    if (game_dir) |gd| {
        const p = try std.fmt.bufPrint(&path_buf, "{s}/Data/Config/items.xml", .{gd});
        return loadFromPath(allocator, p) catch null;
    }
    return null;
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
    var buf: [512 * 1024]u8 = undefined;
    const map = try t.writeNameIdMapping(&buf);
    try std.testing.expect(map.len > 16);
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, map[0..4], .little));
}
