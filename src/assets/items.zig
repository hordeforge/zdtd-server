//! items.xml loader + builtin sim ids with stock name/type resolution for client UI.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const buffs = @import("buffs.zig");
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
    /// items.xml EconomicSellScale (stock `ItemClass.EconomicSellScale`,
    /// IL default 1.0; the sell price base is EconomicValue * scale, RE
    /// loot-economy.md GetSellPrice). A39.
    econ_sell_scale: f32 = 1.0,
    /// items.xml EconomicBundleSize (RE loot-economy.md §5 GetBuyPrice/
    /// GetSellPrice: the price divides by the bundle). 89 stock items carry
    /// it (ammoGasCan 100, resourceWood 50, …); absent = 1.
    econ_bundle_size: u16 = 1,
    /// items.xml passive_effect DegradationMax (passive 8, stock
    /// `ItemClass.get_MaxUseTimesBase`, IL=25): the durability cap. Quality
    /// tiers "min,max" (tier 1..6 = quality 1..6) lerp between the pair; a
    /// single value is constant. 0 = no durability (PercentUsesLeft = 1).
    /// RE items.md §7 + ItemValue.get_PercentUsesLeft (IL=17).
    degradation_min: u32 = 0,
    degradation_max: u32 = 0,
    /// items.xml Action0 DamageEntity (melee hand damage; 0 = none/unset).
    entity_damage: f32 = 0,
    /// items.xml DamageBlock property (hand-item block chew: zombie hand 8,
    /// feral 24; 0 = none/unset → the `[rules.progression] block_bite_damage`
    /// floor).
    damage_block: f32 = 0,
    /// items.xml melee reach: `Range` property (zombie hand 1.6) or the
    /// passive `MaxRange` (club/axe 2.4). 0 = none/unset → the
    /// `[rules.combat] attack_range_sq` floor.
    melee_range: f32 = 0,
    /// items.xml PhysicalDamageResist passive (41) quality curve: value[i]
    /// sits at quality 1 + 5i/(n-1), piecewise-linear (RE PassiveEffect.
    /// ModValue IL=796; GetTotalPhysicalArmorRating sums it on the wearer,
    /// combat-damage.md). 0 segments = the item carries no row.
    phys_resist_curve: [buffs.max_curve_len]f32 = .{0} ** buffs.max_curve_len,
    phys_resist_n: u8 = 0,
    /// ElementalDamageResist passive (42), same curve shape. The sim's damage
    /// chokes are physical-only today, so the PDR leg is the live one.
    elem_resist_curve: [buffs.max_curve_len]f32 = .{0} ** buffs.max_curve_len,
    elem_resist_n: u8 = 0,
    /// items.xml DegradationPerUse passive (base_set, stock
    /// ItemValue.UseTimes wear per use): the durability consumed by one use.
    /// 0 = no row -> the callers' 1.0 default (the pre-XML behavior).
    degradation_per_use: f32 = 0,
    /// items.xml TargetArmor passive (163, perc_add, UNTAGGED rows only):
    /// armor penetration fraction applied to the target's mitigation
    /// (GetTotalPhysicalArmorRating IL=47: passive 163 on the attacking item
    /// modifies the wearer's passive-41 rating base). The perk-tag-gated rows
    /// (perkJavelinMaster etc.) need tag evaluation - recorded.
    target_armor: f32 = 0,
    /// items.xml Action1 Class=PlaceAsBlock `Blockname` (b14: exactly two —
    /// meleeToolTorch → wallTorchLightPlayer, candle → candleWallLightPlayer).
    /// Resolved to a block id via AssignIds at place time; empty = not
    /// placeable (fail closed — resourceWood etc. carry no Blockname and do
    /// not place in stock).
    place_block_name: []const u8 = "",
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
    /// Per-item EconomicSellScale (stock ItemClass field, default 1.0; A39).
    stock_econ_scales: []const f32 = &.{},

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
            if (self.source == .builtin and
                (d.is_eat or (d.name.len >= 4 and std.mem.startsWith(u8, d.name, "food")))) return 15;
        }
        if (self.source == .builtin and item_id == 2) return 15;
        return 0;
    }

    pub fn foodHealthFor(self: *const ItemTable, item_id: u16) f32 {
        if (self.byId(item_id)) |d| {
            if (d.food_health > 0) return d.food_health;
            if (self.source == .builtin) {
                if (item_id == 4 or std.mem.eql(u8, d.name, "medicine")) return 25;
                if (d.is_eat) return 7;
            }
        }
        if (self.source == .builtin and item_id == 2) return 7;
        if (self.source == .builtin and item_id == 4) return 25;
        return 0;
    }

    pub fn waterAmountFor(self: *const ItemTable, item_id: u16) f32 {
        if (self.byId(item_id)) |d| {
            if (d.water_amount > 0) return d.water_amount;
            if (self.source == .builtin and d.name.len >= 5 and std.mem.startsWith(u8, d.name, "drink")) return 20;
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
        // The relative-id pin exists only for the no-game-dir fixture catalog.
        // In XML mode an unresolved type would name the wrong stock item.
        if (self.source == .builtin) return typeFromBuiltinId(item_id);
        return 0;
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
        // Relative ids are an offline fixture convention, never XML truth.
        if (self.source == .builtin and stock_type > items_start_here) {
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
        // Low byte first; the | 0x80 below overwrites bit 7 with the
        // continuation flag, so the discarded high bits shift down on the next
        // iteration (same 7-bit length shape as the wire codec's writer).
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
    const clean = try xml.readCleanFile(allocator, path);
    defer allocator.free(clean);

    const arena_holder = try arena_util.newArenaHolder(allocator);
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
    var stock_econ_declared: std.ArrayList(bool) = .empty;
    defer stock_econ_declared.deinit(allocator);
    var stock_bundles: std.ArrayList(u16) = .empty;
    defer stock_bundles.deinit(allocator);
    var stock_bundle_declared: std.ArrayList(bool) = .empty;
    defer stock_bundle_declared.deinit(allocator);
    var stock_econ_scales: std.ArrayList(f32) = .empty;
    defer stock_econ_scales.deinit(allocator);
    var stock_edmgs: std.ArrayList(f32) = .empty;
    defer stock_edmgs.deinit(allocator);
    var stock_place_names: std.ArrayList([]const u8) = .empty;
    defer stock_place_names.deinit(allocator);
    var stock_dmg_blocks: std.ArrayList(f32) = .empty;
    defer stock_dmg_blocks.deinit(allocator);
    var stock_melee_ranges: std.ArrayList(f32) = .empty;
    defer stock_melee_ranges.deinit(allocator);
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
    var stock_pdr_curves: std.ArrayList([buffs.max_curve_len]f32) = .empty;
    defer stock_pdr_curves.deinit(allocator);
    var stock_pdr_n: std.ArrayList(u8) = .empty;
    defer stock_pdr_n.deinit(allocator);
    var stock_edr_curves: std.ArrayList([buffs.max_curve_len]f32) = .empty;
    defer stock_edr_curves.deinit(allocator);
    var stock_edr_n: std.ArrayList(u8) = .empty;
    defer stock_edr_n.deinit(allocator);
    var stock_degrad_per_use: std.ArrayList(f32) = .empty;
    defer stock_degrad_per_use.deinit(allocator);
    var stock_target_armor: std.ArrayList(f32) = .empty;
    defer stock_target_armor.deinit(allocator);
    defer stock_dradius.deinit(allocator);
    var stock_dlifetime: std.ArrayList(i32) = .empty;
    defer stock_dlifetime.deinit(allocator);
    var stock_dstrength: std.ArrayList(f32) = .empty;
    defer stock_dstrength.deinit(allocator);
    var stock_deat: std.ArrayList(i32) = .empty;
    defer stock_deat.deinit(allocator);
    var stock_degrad_min: std.ArrayList(u32) = .empty;
    defer stock_degrad_min.deinit(allocator);
    var stock_degrad_max: std.ArrayList(u32) = .empty;
    defer stock_degrad_max.deinit(allocator);

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
            var econ_declared = false;
            if (xml.propertyValue(clean[ii..item_end], "EconomicValue")) |v| {
                econ = xml.parseU16(v) orelse 0;
                econ_declared = true;
            }
            try stock_econs.append(allocator, econ);
            try stock_econ_declared.append(allocator, econ_declared);
            // EconomicBundleSize (RE loot-economy.md §5): GetBuyPrice /
            // GetSellPrice divide the unit price by the bundle. 89 stock
            // items carry it (ammoGasCan 100, resourceWood 50, …); absent = 1.
            var bundle: u16 = 1;
            var bundle_declared = false;
            if (xml.propertyValue(clean[ii..item_end], "EconomicBundleSize")) |v| {
                bundle = xml.parseU16(v) orelse 1;
                bundle_declared = true;
            }
            try stock_bundles.append(allocator, bundle);
            try stock_bundle_declared.append(allocator, bundle_declared);
            // A39: EconomicSellScale (default 1.0 = stock ItemClass ctor IL).
            var econ_scale: f32 = 1.0;
            if (xml.propertyValue(clean[ii..item_end], "EconomicSellScale")) |v| {
                econ_scale = xml.parseF32(v) orelse 1.0;
            }
            try stock_econ_scales.append(allocator, econ_scale);
            // Action0 DamageEntity (first hit; melee hands and weapons).
            var edmg: f32 = 0;
            if (xml.propertyValue(clean[ii..item_end], "DamageEntity")) |v| {
                edmg = xml.parseF32(v) orelse 0;
            }
            // Club/axe declare damage only as the EntityDamage passive effect
            // (operation=base_set; perk-tagged perc_add rows are ignored
            // without perks). Stock: club 12, stone axe 6.
            if (edmg == 0) {
                if (xml.passiveEffectValue(clean[ii..item_end], "EntityDamage")) |v| {
                    edmg = xml.parseF32(v) orelse 0;
                }
            }
            try stock_edmgs.append(allocator, edmg);
            // ItemActionPlaceAsBlock (Action1 Class=PlaceAsBlock): only items
            // with a Blockname place (stock b14 exactly two). Empty = not
            // placeable; resolved via AssignIds at place time.
            var place_name: []const u8 = "";
            if (itemActionClassIs(clean[ii..item_end], "PlaceAsBlock")) {
                if (xml.propertyValue(clean[ii..item_end], "Blockname")) |bn| place_name = try arena.dupe(u8, bn);
            }
            try stock_place_names.append(allocator, place_name);
            // DamageBlock property (hand items: zombie hand 8, feral 24).
            var dmg_block: f32 = 0;
            if (xml.propertyValue(clean[ii..item_end], "DamageBlock")) |v| {
                dmg_block = xml.parseF32(v) orelse 0;
            }
            try stock_dmg_blocks.append(allocator, dmg_block);
            // Melee reach: `Range` property (zombie hand 1.6) or the passive
            // `MaxRange` (club/axe 2.4). Drives the AI attack-range gate.
            var mrange: f32 = 0;
            if (xml.propertyValue(clean[ii..item_end], "Range")) |v| {
                mrange = xml.parseF32(v) orelse 0;
            }
            if (mrange <= 0) {
                if (xml.passiveEffectValue(clean[ii..item_end], "MaxRange")) |v| {
                    mrange = xml.parseF32(v) orelse 0;
                }
            }
            try stock_melee_ranges.append(allocator, mrange);
            var fuel: f32 = 0;
            if (xml.propertyValue(clean[ii..item_end], "FuelValue")) |v| {
                fuel = xml.parseF32(v) orelse 0;
            }
            try stock_fuels.append(allocator, fuel);
            // ItemActionEat: Action0 Class=Eat + effect_group cvars.
            const body = clean[ii..item_end];
            var is_eat = itemActionClassIs(body, "Eat");
            const food_amt: f32 = firstCvarAdd(body, "$foodAmountAdd") orelse 0;
            // HP on consume: food items carry `foodHealthAmount`; medical
            // items heal through the `medicalRegHealthAmount` cvar instead
            // (stock bandage 30/action, medkit 400). Both feed EatProps.hp.
            const food_hp: f32 = firstCvarAdd(body, "foodHealthAmount") orelse
                firstCvarAdd(body, "medicalRegHealthAmount") orelse 0;
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
            // Armor resist passives (41/42): quality curves. The curve
            // segments are the per-quality values scaled over Q1..Q6 (stock
            // PassiveEffect.ModValue interpolation, RE items.md).
            var pdr_curve: [buffs.max_curve_len]f32 = .{0} ** buffs.max_curve_len;
            var pdr_n: u8 = 0;
            const pdr_v = xml.passiveEffectValue(body, "PhysicalDamageResist");
            if (pdr_v) |v| {
                pdr_n = buffs.parseCurveValue(v, &pdr_curve);
            }
            var edr_curve: [buffs.max_curve_len]f32 = .{0} ** buffs.max_curve_len;
            var edr_n: u8 = 0;
            const edr_v = xml.passiveEffectValue(body, "ElementalDamageResist");
            if (edr_v) |v| {
                edr_n = buffs.parseCurveValue(v, &edr_curve);
            }
            try stock_pdr_curves.append(allocator, pdr_curve);
            try stock_pdr_n.append(allocator, pdr_n);
            try stock_edr_curves.append(allocator, edr_curve);
            try stock_edr_n.append(allocator, edr_n);
            // DegradationPerUse (base_set): the per-use durability wear.
            // The 3 perc_add rows are the modifier form - recorded.
            var degrad_per_use: f32 = 0;
            if (xml.passiveEffectValue(body, "DegradationPerUse")) |v| {
                if (xml.passiveOperation(body, "DegradationPerUse") == null or
                    std.mem.eql(u8, xml.passiveOperation(body, "DegradationPerUse").?, "base_set"))
                {
                    degrad_per_use = xml.parseF32(v) orelse 0;
                }
            }
            // TargetArmor (163, perc_add): armor penetration. Only UNTAGGED
            // rows apply without perk-tag evaluation (the perkJavelinMaster
            // rows are the recorded tag-gated leg).
            var target_armor: f32 = 0;
            if (xml.passiveEffectRow(body, "TargetArmor")) |row| {
                if (xml.attr(row, 0, "tags") == null) {
                    if (xml.attr(row, 0, "value")) |v| target_armor = xml.parseF32(v) orelse 0;
                }
            }
            try stock_degrad_per_use.append(allocator, degrad_per_use);
            try stock_target_armor.append(allocator, target_armor);
            var deat: i32 = 0;
            if (xml.passiveEffectValue(body, "DistractionEatTicks")) |v| {
                deat = std.fmt.parseInt(i32, v, 10) catch 0;
            }
            // DegradationMax (passive 8): the durability cap, quality-tiered
            // "min,max" (tier 1..6 = quality 1..6) or a single constant.
            // Feeds MaxUseTimes -> ItemValue.PercentUsesLeft (worn items sell
            // for less, RE GetSellPrice / items.md §7).
            var dmin: u32 = 0;
            var dmax: u32 = 0;
            if (xml.passiveEffectValue(body, "DegradationMax")) |v| {
                if (std.mem.findScalar(u8, v, ',')) |comma| {
                    dmin = xml.parseU32(v[0..comma]) orelse 0;
                    dmax = xml.parseU32(v[comma + 1 ..]) orelse 0;
                } else {
                    dmax = xml.parseU32(v) orelse 0;
                    dmin = dmax;
                }
            }
            try stock_degrad_min.append(allocator, dmin);
            try stock_degrad_max.append(allocator, dmax);
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

    // Resolve Stacknumber, EconomicValue and EconomicBundleSize through the
    // Extends chain (stock items.xml declares ~1144 Extends properties; a
    // child can precede its parent in the file, so this is a second pass).
    // An item with no Stacknumber anywhere inherits the ItemClass default of
    // 500 (asm.il:749089). EconomicValue inherits like any property (286
    // stock items get their econ from a master, e.g. armorAssassinBoots ->
    // armorMediumMaster econ 1000; no stock item declares EconomicValue="0").
    {
        var own_stack_map: std.StringHashMapUnmanaged(u16) = .{};
        defer own_stack_map.deinit(allocator);
        var own_econ_map: std.StringHashMapUnmanaged(u16) = .{};
        defer own_econ_map.deinit(allocator);
        var own_bundle_map: std.StringHashMapUnmanaged(u16) = .{};
        defer own_bundle_map.deinit(allocator);
        var ext_map: std.StringHashMapUnmanaged([]const u8) = .{};
        defer ext_map.deinit(allocator);
        for (stock_names.items, 0..) |n, idx| {
            if (own_stacks.items[idx] != 0) try own_stack_map.put(allocator, n, own_stacks.items[idx]);
            if (stock_econ_declared.items[idx]) try own_econ_map.put(allocator, n, stock_econs.items[idx]);
            if (stock_bundle_declared.items[idx]) try own_bundle_map.put(allocator, n, stock_bundles.items[idx]);
            if (ext_names.items[idx].len > 0) try ext_map.put(allocator, n, ext_names.items[idx]);
        }
        const max_hops: usize = 24;
        for (stock_names.items, 0..) |n, idx| {
            var cur = n;
            var hops: usize = 0;
            while (hops < max_hops) : (hops += 1) {
                if (own_stack_map.get(cur)) |s| {
                    stock_stacks.items[idx] = s;
                    break;
                }
                cur = ext_map.get(cur) orelse break;
            }
        }
        for (stock_names.items, 0..) |n, idx| {
            var cur = n;
            var hops: usize = 0;
            while (hops < max_hops) : (hops += 1) {
                if (own_econ_map.get(cur)) |e| {
                    stock_econs.items[idx] = e;
                    break;
                }
                cur = ext_map.get(cur) orelse break;
            }
        }
        for (stock_names.items, 0..) |n, idx| {
            var cur = n;
            var hops: usize = 0;
            while (hops < max_hops) : (hops += 1) {
                if (own_bundle_map.get(cur)) |b| {
                    stock_bundles.items[idx] = b;
                    break;
                }
                cur = ext_map.get(cur) orelse break;
            }
        }
        // Armor resist curves inherit through the Extends chain like any
        // property (armorPrimitiveHelmet -> armorPrimitiveMaster carries the
        // PDR rows): the first ancestor with a row wins (stock property
        // inheritance; RE items.md Extends).
        {
            var own_pdr_map: std.StringHashMapUnmanaged([buffs.max_curve_len]f32) = .{};
            defer own_pdr_map.deinit(allocator);
            var own_pdrn_map: std.StringHashMapUnmanaged(u8) = .{};
            defer own_pdrn_map.deinit(allocator);
            var own_edr_map: std.StringHashMapUnmanaged([buffs.max_curve_len]f32) = .{};
            defer own_edr_map.deinit(allocator);
            var own_edrn_map: std.StringHashMapUnmanaged(u8) = .{};
            defer own_edrn_map.deinit(allocator);
            for (stock_names.items, 0..) |n, idx| {
                if (stock_pdr_n.items[idx] > 0) {
                    try own_pdr_map.put(allocator, n, stock_pdr_curves.items[idx]);
                    try own_pdrn_map.put(allocator, n, stock_pdr_n.items[idx]);
                }
                if (stock_edr_n.items[idx] > 0) {
                    try own_edr_map.put(allocator, n, stock_edr_curves.items[idx]);
                    try own_edrn_map.put(allocator, n, stock_edr_n.items[idx]);
                }
            }
            for (stock_names.items, 0..) |n, idx| {
                var cur = n;
                var hops: usize = 0;
                while (hops < max_hops) : (hops += 1) {
                    if (own_pdrn_map.get(cur)) |cn| {
                        stock_pdr_n.items[idx] = cn;
                        stock_pdr_curves.items[idx] = own_pdr_map.get(cur).?;
                        break;
                    }
                    cur = ext_map.get(cur) orelse break;
                }
                cur = n;
                hops = 0;
                while (hops < max_hops) : (hops += 1) {
                    if (own_edrn_map.get(cur)) |cn| {
                        stock_edr_n.items[idx] = cn;
                        stock_edr_curves.items[idx] = own_edr_map.get(cur).?;
                        break;
                    }
                    cur = ext_map.get(cur) orelse break;
                }
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
                def.econ_bundle_size = stock_bundles.items[idx];
                def.econ_sell_scale = stock_econ_scales.items[idx];
                def.degradation_min = stock_degrad_min.items[idx];
                def.degradation_max = stock_degrad_max.items[idx];
                def.entity_damage = stock_edmgs.items[idx];
                def.place_block_name = stock_place_names.items[idx];
                def.damage_block = stock_dmg_blocks.items[idx];
                def.melee_range = stock_melee_ranges.items[idx];
                def.phys_resist_curve = stock_pdr_curves.items[idx];
                def.phys_resist_n = stock_pdr_n.items[idx];
                def.elem_resist_curve = stock_edr_curves.items[idx];
                def.elem_resist_n = stock_edr_n.items[idx];
                def.degradation_per_use = stock_degrad_per_use.items[idx];
                def.target_armor = stock_target_armor.items[idx];
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
            .econ_bundle_size = stock_bundles.items[idx],
            .econ_sell_scale = stock_econ_scales.items[idx],
            .degradation_min = stock_degrad_min.items[idx],
            .degradation_max = stock_degrad_max.items[idx],
            .entity_damage = stock_edmgs.items[idx],
            .place_block_name = stock_place_names.items[idx],
            .damage_block = stock_dmg_blocks.items[idx],
            .melee_range = stock_melee_ranges.items[idx],
            .fuel_value = stock_fuels.items[idx],
            // ItemActionEat props (was missing; stack-loss isEat relied on name heuristic only).
            .is_eat = stock_is_eat.items[idx],
            .food_amount = stock_food_amt.items[idx],
            .food_health = stock_food_hp.items[idx],
            .water_amount = stock_water_amt.items[idx],
            .distraction_tags = stock_dtags.items[idx],
            .distraction_radius = stock_dradius.items[idx],
            .phys_resist_curve = stock_pdr_curves.items[idx],
            .phys_resist_n = stock_pdr_n.items[idx],
            .elem_resist_curve = stock_edr_curves.items[idx],
            .elem_resist_n = stock_edr_n.items[idx],
            .degradation_per_use = stock_degrad_per_use.items[idx],
            .target_armor = stock_target_armor.items[idx],
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
    const ssc = try arena.alloc(f32, stock_econ_scales.items.len);
    @memcpy(ssc, stock_econ_scales.items);

    return .{
        .defs = defs,
        .arena_ptr = arena_holder,
        .source = .xml,
        .stock_names = sn,
        .stock_types = st,
        .stock_stacks = ss,
        .stock_econ_scales = ssc,
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

test "XML item table fails closed instead of using builtin balance or ids" {
    const defs = [_]ItemDef{
        .{ .id = 100, .name = "foodUnspecified", .is_eat = true },
        .{ .id = 101, .name = "drinkUnspecified", .is_eat = true },
    };
    const t: ItemTable = .{ .defs = &defs, .source = .xml };

    try std.testing.expectEqual(@as(f32, 0), t.foodAmountFor(100));
    try std.testing.expectEqual(@as(f32, 0), t.foodHealthFor(100));
    try std.testing.expectEqual(@as(f32, 0), t.waterAmountFor(101));
    try std.testing.expectEqual(@as(i32, 0), t.stockTypeFor(99));
    try std.testing.expectEqual(@as(u16, 0), t.ecsIdFromStockType(items_start_here + 99));

    const builtin = ItemTable.builtin();
    try std.testing.expectEqual(@as(i32, items_start_here + 7), builtin.stockTypeFor(7));
    try std.testing.expectEqual(@as(f32, 15), builtin.foodAmountFor(2));
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
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.stock_names.len > 100);
    try std.testing.expectEqual(@as(i32, 65537), t.byStockName("meleeToolRepairT0StoneAxe").?);
    try std.testing.expectEqual(t.byStockName("meleeToolRepairT0StoneAxe").?, t.stockTypeFor(8));
    try std.testing.expect(t.stockTypeFor(7) > stock_first_item_type); // wood
    // DegradationMax (passive 8): the builtin stone axe quality tier is
    // "250,500" (Q1 -> 250, Q6 -> 500; stock items.xml). Feeds the sell
    // price's PercentUsesLeft term (worn items sell for less).
    if (t.byId(8)) |axe| {
        try std.testing.expectEqual(@as(u32, 250), axe.degradation_min);
        try std.testing.expectEqual(@as(u32, 500), axe.degradation_max);
    }
    // Non-durable items (no DegradationMax) price full: pul term is 1.
    if (t.byName("resourceWood")) |wood| {
        try std.testing.expectEqual(@as(u32, 0), wood.degradation_max);
    }
    // Stock gas can: FuelValue from items.xml (ammoGasCan).
    if (t.byName("ammoGasCan")) |gas| {
        try std.testing.expect(gas.fuel_value > 0);
        try std.testing.expectEqual(gas.fuel_value, t.fuelValueFor(gas.id));
    }
    // Action1 PlaceAsBlock Blockname: b14 exactly two items place, and the
    // rest (resourceWood etc.) are not placeable.
    if (t.byName("meleeToolTorch")) |torch| {
        try std.testing.expectEqualStrings("wallTorchLightPlayer", torch.place_block_name);
    }
    if (t.byName("candle")) |cnd| {
        try std.testing.expectEqualStrings("candleWallLightPlayer", cnd.place_block_name);
    }
    if (t.byName("resourceWood")) |wood| {
        try std.testing.expectEqualStrings("", wood.place_block_name);
    }
    // EconomicValue resolves through the Extends chain (286 stock items get
    // their econ from a master) and EconomicBundleSize divides the price.
    if (t.byName("armorAssassinBoots")) |boots| {
        try std.testing.expectEqual(@as(u16, 1000), boots.econ);
    }
    if (t.byName("ammoGasCan")) |gas| {
        try std.testing.expectEqual(@as(u16, 100), gas.econ_bundle_size);
    }
    if (t.byName("resourceWood")) |wood| {
        try std.testing.expectEqual(@as(u16, 50), wood.econ_bundle_size);
    }
    // Melee damage: club/axe declare it as the EntityDamage passive effect
    // (base_set) — property-less items must not resolve to 0.
    if (t.byName("meleeWpnClubT0WoodenClub")) |club| {
        try std.testing.expectEqual(@as(f32, 12), club.entity_damage);
    }
    if (t.byName("meleeToolRepairT0StoneAxe")) |axe| {
        try std.testing.expectEqual(@as(f32, 6), axe.entity_damage);
    }
    // Per-class block chew: DamageBlock property on the zombie hand items.
    if (t.byName("meleeHandZombie01")) |hand| {
        try std.testing.expectEqual(@as(f32, 8), hand.damage_block);
    }
    if (t.byName("meleeHandZombieFeral")) |feral| {
        try std.testing.expectEqual(@as(f32, 24), feral.damage_block);
    }
    // Melee reach: zombie hand Range property 1.6; club falls back to the
    // passive MaxRange 2.4.
    if (t.byName("meleeHandZombie01")) |hand| {
        try std.testing.expectEqual(@as(f32, 1.6), hand.melee_range);
    }
    if (t.byName("meleeWpnClubT0WoodenClub")) |club| {
        try std.testing.expectEqual(@as(f32, 2.4), club.melee_range);
    }
    // Medical heal: bandage heals via the medicalRegHealthAmount cvar.
    if (t.byName("medicalFirstAidBandage")) |band| {
        try std.testing.expect(band.food_health > 0);
    }
    var buf: [512 * 1024]u8 = undefined;
    const map = try t.writeNameIdMapping(&buf);
    try std.testing.expect(map.len > 16);
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, map[0..4], .little));
}

test "stock items.xml Stacknumber default and Extends resolution" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/items.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
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
    // A39: EconomicSellScale from items.xml (stock ItemClass.EconomicSellScale,
    // IL ctor default 1.0; toolCookingGrill marks down to .5).
    const scaleOf = struct {
        fn f(tab: *const ItemTable, name: []const u8) f32 {
            for (tab.stock_names, 0..) |n, i| {
                if (std.mem.eql(u8, n, name)) return tab.stock_econ_scales[i];
            }
            return 0;
        }
    }.f;
    try std.testing.expectEqual(@as(f32, 1.0), scaleOf(&t, "meleeToolRepairT0StoneAxe"));
    try std.testing.expectEqual(@as(f32, 0.5), scaleOf(&t, "toolCookingGrill"));
    try std.testing.expectEqual(@as(f32, 1.0), t.byId(8).?.econ_sell_scale);
}

test "armor resist curves parse from stock items.xml (PDR quality curves)" {
    const gd = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    var t = try loadFromPath(std.testing.allocator, gd ++ "/Data/Config/items.xml");
    defer t.deinit();
    // armorPrimitiveHelmet carries PhysicalDamageResist "8,12.3" (Q1..Q6).
    var found: usize = 0;
    for (t.defs) |d| {
        if (std.mem.eql(u8, d.name, "armorPrimitiveHelmet")) {
            try std.testing.expectEqual(@as(u8, 2), d.phys_resist_n);
            try std.testing.expectApproxEqAbs(@as(f32, 8), d.phys_resist_curve[0], 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 12.3), d.phys_resist_curve[1], 0.001);
            try std.testing.expectEqual(@as(u8, 2), d.elem_resist_n);
            found += 1;
        }
        if (d.phys_resist_n > 0) found += 1;
    }
    // The XML def table caps at max_items; the armor family (alphabetically
    // early) carries the bulk of the 134 PDR rows.
    try std.testing.expect(found >= 50);
    // DegradationPerUse (base_set) on tools; TargetArmor (perc_add) only on
    // untagged rows (ammo9mmBulletAP, the armor-piercing round).
    var stone_axe = false;
    var ap_ammo = false;
    for (t.defs) |d| {
        if (std.mem.eql(u8, d.name, "meleeToolRepairT0StoneAxe")) {
            try std.testing.expectApproxEqAbs(@as(f32, 1), d.degradation_per_use, 0.001);
            stone_axe = true;
        }
        if (std.mem.eql(u8, d.name, "ammo9mmBulletAP")) {
            try std.testing.expectApproxEqAbs(@as(f32, -0.5), d.target_armor, 0.001);
            ap_ammo = true;
        }
    }
    try std.testing.expect(stone_axe);
    try std.testing.expect(ap_ammo);
}
