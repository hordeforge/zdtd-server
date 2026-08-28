//! blocks.xml solid/name table. Wire ids come only from AssignIds (idByName),
//! never sequential XML declaration order.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const util_log = @import("../util/log.zig");
const assignids = @import("assignids_comptime.zig");

pub const max_blocks: usize = 8192;

/// Max `<drop>` rows a block may resolve (own + Extends-inherited; the
/// largest stock block carries 16 Harvest rows, 1,748 Harvest rows total).
pub const max_harvest_drops: usize = 16;

/// The three stock drop events (`EnumDropEvent`: Destroy=0, Fall=1,
/// Harvest=2, il/full-v3.1.0/_global/EnumDropEvent.il.txt).
pub const DropEvent = enum { destroy, fall, harvest };

/// One `<drop event="Harvest" .../>` row from a block's body. Roll
/// semantics are pinned by Block.DropItemsOnEvent IL=246 (count in
/// [minCount, maxCount+1), skip 0, drop when random < prob) and
/// GameUtils.HarvestOnAttack IL=623 (harvested stacks go to the breaker's
/// inventory, overflow to the ground). The `tool_category` / `tag` fields
/// are stored but never read by the roll (stock IL only reads name/count/
/// prob/stickChance); they are the item-side bonus legs, recorded.
pub const HarvestDrop = struct {
    /// Item name resolved via the item catalog. The IL specials "[recipe]"
    /// and "*" appear on no V3.1.0 b14 Harvest row and fail closed to a
    /// skip here (missing beats fake).
    item_name: []const u8 = "",
    /// Inclusive count bounds (ParseMinMaxCount on the `count` attr;
    /// "55" → 55..55, "3,6" → 3..6; absent → 1..1). Roll is
    /// RandomRange(min, max+1).
    count_min: u32 = 1,
    count_max: u32 = 1,
    /// Per-entry drop probability, already scaled by the block's
    /// ResourceScale property (BlocksFromXml: `prob * ResourceScale`;
    /// zero V3.1.0 b14 blocks set it, so stock rows are unmodified).
    prob: f32 = 1,
    /// stick_chance attr. Every stock row with stick_chance set is a
    /// Fall-event debris row (terrDestroyedStone/scrapMetalPile...); b14
    /// Harvest rows carry none. Stored for fidelity; the Fall slice is a
    /// separate gap row.
    stick_chance: f32 = 0,
    /// tool_category attr (e.g. "Disassemble"). Recorded leg, not a roll
    /// gate (the harvest drop list's toolCategory feeds the item-side
    /// Bonuses.Damage scaling, items.md; out of this slice).
    tool_category: []const u8 = "",
    /// tag attr (e.g. "allHarvest,perkJunkMiner"). Same recorded leg
    /// (HarvestCount passive scaling anchor).
    tag: []const u8 = "",
};

pub const BlockDef = struct {
    id: u16 = 0,
    name: []const u8 = "",
    solid: bool = true,
    /// Block Class property (engine class name, e.g. "VendingMachine"). 0
    /// length = not parsed / unknown.
    class: []const u8 = "",
    /// TraderID property (blocks.xml), resolved through the Extends chain.
    trader_id: i32 = 0,
    /// Door block (RE entity-ai.md CheckForDoorAndOpen): stock doors carry the
    /// door FastTag (bit 2) and a TEFeatureDoor; zdtd detects them by the
    /// stock naming (672 door-named blocks, all door classes) since the tag
    /// is class-assigned, not a blocks.xml property. Zombies open these on
    /// their path instead of chewing.
    is_door: bool = false,
    /// IndexName="TraderOnOff": trader-area gate/loudspeaker blocks that
    /// TraderArea::SetClosed toggles (doors lock, lights flip meta bit 0x2).
    trader_onoff: bool = false,
    /// HeatMapStrength: heat the block feeds the AI heat map while active
    /// (forge 6, campfire 5, workbench 5, torches 1...). 0 = none.
    heat_strength: f32 = 0,
    /// Workstation Modules list contains "fuel": the craft queue waits for
    /// isBurning (campfire/forge/chemistry). Workbench, cement mixer and
    /// table saw have no fuel module and advance regardless (stock
    /// TileEntityWorkstation.HandleRecipeQueue gate, asm.il 1331687).
    has_fuel_module: bool = false,
    /// Workstation CraftingAreaRecipes comma list ("player,workbench",
    /// "forge", "tablesaw"). Empty = the block name is the area (campfire,
    /// chemistryStation, cementMixer carry no list). Gates which recipes a
    /// workstation may queue (server authority, rule 17).
    crafting_areas: []const u8 = "",
    /// ActiveRadiusEffects="buffName,radius" (dedicated-misc-systems.md
    /// "BlockRadiusEffect"; asm.il EntityPlayerLocal.BlockRadiusEffectsTick
    /// IL=83 / BlockRadiusEffectsApply IL=58): a nearby player without the
    /// named buff gets it added while within `radius` of an active instance
    /// of this block (campfire/torch/candle warmth, a radiated barrel's
    /// buffRadiation01). Empty = no radius effect.
    radius_effect_buff: []const u8 = "",
    /// Squared radius for the radius-effect distance check (radius^2, so the
    /// hot-path compare avoids a sqrt). 0 when radius_effect_buff is empty.
    radius_effect_radius_sq: f32 = 0,
    /// PickupSource property (`<property name="PickupSource" ...>`, declared
    /// in the game's XML.txt:908). The block left behind when a player picks
    /// this block up: stock GameManager.PickupBlockServer resolves
    /// PickupSource != null ? Block.GetBlockValue(PickupSource) :
    /// BlockValue.Air (asm.il GameManager IL=77 IL_008D-00B4). V3.1.0 b14
    /// ships no block that sets it, so every stock pickup leaves Air; a
    /// modded blocks.xml is honoured rather than hardcoded.
    pickup_source: []const u8 = "",
    /// Mesh property (blocks.xml `Mesh="terrain|opaque|grass|water|..."`):
    /// picks the texture-atlas for the minimap color (GetColorForSide ->
    /// MeshDescription.meshes[MeshIndex].textureAtlas). Empty = default mesh
    /// 0 = "opaque" (RE texture-atlas.md; no block sets MeshIndex directly).
    mesh: []const u8 = "",
    /// Top-face texture id (first value of the Texture property, e.g.
    /// terrDirt "2", terrForestGround "195,570,..."). Indexes the atlas
    /// uvMapping for the minimap color. 0 = none.
    texture_top: u16 = 0,
    /// MapColor property packed RGB555 (0 = none). Blocks with bMapColorSet
    /// use this directly in Block.GetMapColor, skipping the atlas (RE
    /// texture-atlas.md; the terrain blocks all carry it).
    map_color: u16 = 0,
    /// Resolved `<drop event="Harvest">` rows (own + Extends-inherited,
    /// own wins per item name, RE CopyDroppedFrom IL=89). Empty = the block
    /// drops itself once when harvested (stock HarvestOnAttack
    /// ToItemValue x1).
    harvest_drops: []const HarvestDrop = &.{},
    /// Resolved `<drop event="Destroy">` rows (explosion/debris salvage,
    /// 1,286 stock rows; e.g. resourceScrapIron from broken metal).
    destroy_drops: []const HarvestDrop = &.{},
    /// Resolved `<drop event="Fall">` rows (falling-block debris, 587 stock
    /// rows; e.g. terrDestroyedStone crumbles into itself at prob .75).
    fall_drops: []const HarvestDrop = &.{},
};

pub const IdByNameFn = *const fn (?*anyopaque, []const u8) ?u16;

pub const BlockTable = struct {
    defs: []const BlockDef = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    source: enum { builtin, xml } = .builtin,

    pub fn deinit(self: *BlockTable) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = builtin();
    }

    pub fn builtin() BlockTable {
        return .{ .defs = builtin_defs[0..], .source = .builtin };
    }

    pub fn byId(self: *const BlockTable, id: u16) ?BlockDef {
        for (self.defs) |d| if (d.id == id) return d;
        return null;
    }

    pub fn byName(self: *const BlockTable, name: []const u8) ?BlockDef {
        for (self.defs) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    /// Resolved Harvest drop rows for a block (empty when none; unknown
    /// blocks fail closed to nothing, matching stock HasItemsToDropForEvent).
    pub fn harvestDrops(self: *const BlockTable, id: u16) []const HarvestDrop {
        if (self.byId(id)) |d| return d.harvest_drops;
        return &.{};
    }

    /// Resolved drop rows for a block + event (harvest/destroy/fall).
    pub fn dropsFor(self: *const BlockTable, id: u16, event: DropEvent) []const HarvestDrop {
        const d = self.byId(id) orelse return &.{};
        return switch (event) {
            .harvest => d.harvest_drops,
            .destroy => d.destroy_drops,
            .fall => d.fall_drops,
        };
    }

    pub fn isSolid(self: *const BlockTable, id: u16) bool {
        if (id == 0) return false;
        if (self.byId(id)) |d| return d.solid;
        return true;
    }

    /// True for blocks whose resolved Class is VendingMachine (own or inherited
    /// through Extends): the TE the client instantiates for these is
    /// TileEntityVendingMachine (TileEntityType.VendingMachine = 7).
    pub fn isVending(self: *const BlockTable, id: u16) bool {
        if (self.byId(id)) |d| return std.mem.eql(u8, d.class, "VendingMachine");
        return false;
    }

    /// TraderID for a block (TraderData.TraderID drives trader_info stock).
    pub fn traderId(self: *const BlockTable, id: u16) i32 {
        if (self.byId(id)) |d| return d.trader_id;
        return 0;
    }

    /// TraderArea::SetClosed gate set (IndexName="TraderOnOff"): these blocks
    /// toggle when the owning trader opens/closes.
    pub fn isTraderOnOff(self: *const BlockTable, id: u16) bool {
        if (self.byId(id)) |d| return d.trader_onoff;
        return false;
    }

    /// HeatMapStrength of a block (0 = no heat; feeds the AI heat map).
    pub fn heatStrength(self: *const BlockTable, id: u16) f32 {
        if (self.byId(id)) |d| return d.heat_strength;
        return 0;
    }

    /// True when the block's Workstation Modules list includes "fuel" (the
    /// craft queue waits for isBurning). Unknown/offline blocks default false
    /// (no fuel module → queue advances like a workbench).
    pub fn hasFuelModule(self: *const BlockTable, id: u16) bool {
        if (self.byId(id)) |d| return d.has_fuel_module;
        return false;
    }

    /// ActiveRadiusEffects buff name and squared radius for a block, or null
    /// when it carries none.
    pub fn radiusEffect(self: *const BlockTable, id: u16) ?struct { buff: []const u8, radius_sq: f32 } {
        const d = self.byId(id) orelse return null;
        if (d.radius_effect_buff.len == 0) return null;
        return .{ .buff = d.radius_effect_buff, .radius_sq = d.radius_effect_radius_sq };
    }

    /// PickupSource replacement block name for a pickup, or null when the
    /// pickup leaves Air behind (the V3.1.0 b14 stock state for every block;
    /// only a modded blocks.xml sets it).
    pub fn pickupSource(self: *const BlockTable, id: u16) ?[]const u8 {
        const d = self.byId(id) orelse return null;
        if (d.pickup_source.len == 0) return null;
        return d.pickup_source;
    }

    /// True when the workstation may craft recipes of `area` (the recipe's
    /// craft_area; empty = player/backpack recipe). The explicit
    /// CraftingAreaRecipes comma list wins ("player,workbench"); without a
    /// list the block name is the area (campfire -> "campfire"). Unknown
    /// blocks fail open so an unparsed station does not reject its queue.
    pub fn allowsCraftArea(self: *const BlockTable, id: u16, area: []const u8) bool {
        const d = self.byId(id) orelse return true;
        const want = if (area.len == 0) "player" else area;
        if (d.crafting_areas.len > 0) {
            var it = std.mem.splitScalar(u8, d.crafting_areas, ',');
            while (it.next()) |a| {
                const t = std.mem.trim(u8, a, " \t");
                if (t.len == 0) continue;
                if (std.mem.eql(u8, t, want)) return true;
            }
            return false;
        }
        if (d.name.len == 0) return true;
        return std.mem.eql(u8, d.name, want);
    }
};

// Offline / no-dump slice: dump-validated pins only (assignids_comptime).
pub const builtin_defs = [_]BlockDef{
    .{ .id = assignids.air, .name = "air", .solid = false },
    .{ .id = assignids.terr_stone, .name = "terrStone", .solid = true },
    .{ .id = assignids.terrain_filler, .name = "terrainFiller", .solid = true },
    .{ .id = assignids.terrain_filler_adaptive, .name = "terrainFillerAdaptive", .solid = true },
    .{ .id = assignids.terr_bedrock, .name = "terrBedrock", .solid = true },
    .{ .id = assignids.terr_dirt, .name = "terrDirt", .solid = true },
    .{ .id = assignids.terr_forest_ground, .name = "terrForestGround", .solid = true },
    .{ .id = assignids.terr_sand, .name = "terrSand", .solid = true },
    .{ .id = assignids.terr_topsoil, .name = "terrTopSoil", .solid = true },
    .{ .id = assignids.water, .name = "water", .solid = false },
};

/// "r,g,b" 0-255 ints -> RGB555 (Utils.ToColor5 on the /255 color; RE
/// texture-atlas.md). 0 on malformed input (treated as no MapColor).
fn parseMapColor5(v: []const u8) u16 {
    var it = std.mem.splitScalar(u8, v, ',');
    const rs = std.mem.trim(u8, it.next() orelse return 0, " ");
    const gs = std.mem.trim(u8, it.next() orelse return 0, " ");
    const bs = std.mem.trim(u8, it.next() orelse return 0, " ");
    const r = std.fmt.parseInt(u32, rs, 10) catch return 0;
    const g = std.fmt.parseInt(u32, gs, 10) catch return 0;
    const b = std.fmt.parseInt(u32, bs, 10) catch return 0;
    if (r > 255 or g > 255 or b > 255) return 0;
    // floor(v*31/255 + 0.5) == (v*31 + 127) / 255
    const c = struct {
        fn cc(x: u32) u16 {
            return @intCast((x * 31 + 127) / 255);
        }
    };
    return (c.cc(r) << 10) | (c.cc(g) << 5) | c.cc(b);
}

/// Inclusive count bounds (StringParsers.ParseMinMaxCount result).
pub const CountRange = struct { min: u32, max: u32 };

/// Parse a stock `count` attribute into inclusive bounds (StringParsers.
/// ParseMinMaxCount): "55" → 55..55, "3,6" → 3..6, "0,3" → 0..3. Malformed
/// or absent values fall back to the IL default 1..1.
fn parseMinMaxCount(v: []const u8) CountRange {
    if (std.mem.findScalar(u8, v, ',')) |comma| {
        const a = std.fmt.parseInt(u32, std.mem.trim(u8, v[0..comma], " \t"), 10) catch 1;
        const b = std.fmt.parseInt(u32, std.mem.trim(u8, v[comma + 1 ..], " \t"), 10) catch a;
        return .{ .min = @min(a, b), .max = @max(a, b) };
    }
    const n = std.fmt.parseInt(u32, std.mem.trim(u8, v, " \t"), 10) catch 1;
    return .{ .min = n, .max = n };
}

/// CopyDroppedFrom merge for one drop event (Block::CopyDroppedFrom IL=89):
/// base rows append unless the item name is already present (own wins).
/// Bounded by max_harvest_drops like the own-row parse cap. Arena-backed.
fn mergeDrops(
    arena: std.mem.Allocator,
    own: []const HarvestDrop,
    base: []const HarvestDrop,
) ![]const HarvestDrop {
    if (base.len == 0 or own.len >= max_harvest_drops) return own;
    const merged = try arena.alloc(HarvestDrop, @min(own.len + base.len, max_harvest_drops));
    @memcpy(merged[0..own.len], own);
    var n = own.len;
    for (base) |bd| {
        if (n >= max_harvest_drops) break;
        var dup_name = false;
        for (merged[0..n]) |od| {
            if (std.mem.eql(u8, od.item_name, bd.item_name)) {
                dup_name = true;
                break;
            }
        }
        if (dup_name) continue;
        merged[n] = bd;
        n += 1;
    }
    return merged[0..n];
}

fn isSolidName(name: []const u8) bool {
    if (std.mem.eql(u8, name, "air")) return false;
    if (std.mem.startsWith(u8, name, "water")) return false;
    if (std.mem.startsWith(u8, name, "terrWater")) return false;
    return true;
}

/// Load blocks.xml names; resolve ids only via AssignIds (`id_by_name`).
/// Names missing from the dump are omitted (fail closed).
pub fn loadFromPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    id_by_name: IdByNameFn,
    ctx: ?*anyopaque,
) !BlockTable {
    const clean = try xml.readCleanFile(allocator, path);
    defer allocator.free(clean);

    const arena_holder = try arena_util.newArenaHolder(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var list: std.ArrayList(BlockDef) = .empty;
    defer list.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer seen.deinit(allocator);

    // Raw per-block props for Class / TraderID / Extends, keyed by name, so the
    // extends chain can be resolved after the single scan pass.
    const Parsed = struct {
        id: u16,
        name: []const u8,
        class: ?[]const u8 = null,
        trader_id: i32 = -1, // -1 = not declared
        extends: ?[]const u8 = null,
        trader_onoff: bool = false,
        is_door: bool = false,
        heat_strength: f32 = 0,
        has_fuel_module: bool = false,
        crafting_areas: ?[]const u8 = null,
        radius_effect_buff: ?[]const u8 = null,
        radius_effect_radius_sq: f32 = 0,
        pickup_source: ?[]const u8 = null,
        mesh: ?[]const u8 = null,
        texture_top: u16 = 0,
        map_color: u16 = 0,
        /// Own (non-inherited) drop rows per event, arena-backed.
        harvest_drops: []const HarvestDrop = &.{},
        destroy_drops: []const HarvestDrop = &.{},
        fall_drops: []const HarvestDrop = &.{},
    };
    var parsed: std.ArrayList(Parsed) = .empty;
    defer parsed.deinit(allocator);
    var name_idx: std.StringHashMapUnmanaged(usize) = .{};
    defer name_idx.deinit(allocator);

    var i: usize = 0;
    while (i < clean.len and parsed.items.len < max_blocks) {
        const bi = std.mem.findPos(u8, clean, i, "<block ") orelse break;
        const name = xml.attr(clean, bi, "name") orelse {
            i = bi + 7;
            continue;
        };
        if (seen.contains(name)) {
            i = bi + 7;
            continue;
        }
        const id = id_by_name(ctx, name) orelse {
            i = bi + 7;
            continue;
        };
        const kn = try arena.dupe(u8, name);
        try seen.put(allocator, kn, {});
        // Scan this block's body for Class / TraderID / Extends / IndexName /
        // HeatMapStrength.
        var class: ?[]const u8 = null;
        var trader_id: i32 = -1;
        var extends: ?[]const u8 = null;
        var trader_onoff = false;
        var heat_strength: f32 = 0;
        var has_fuel_module = false;
        var crafting_areas: ?[]const u8 = null;
        var radius_effect_buff: ?[]const u8 = null;
        var radius_effect_radius_sq: f32 = 0;
        var pickup_source: ?[]const u8 = null;
        var mesh: ?[]const u8 = null;
        var texture_top: u16 = 0;
        var map_color: u16 = 0;
        var resource_scale: f32 = 1;
        var own_drops: std.ArrayList(HarvestDrop) = .empty;
        defer own_drops.deinit(allocator);
        var own_destroy: std.ArrayList(HarvestDrop) = .empty;
        defer own_destroy.deinit(allocator);
        var own_fall: std.ArrayList(HarvestDrop) = .empty;
        defer own_fall.deinit(allocator);
        const body_end = if (std.mem.findPos(u8, clean, bi, "</block>")) |e| e else clean.len;
        var p = bi + 7;
        while (p < body_end) : (p += 1) {
            // Both <property> and <drop> live in the block body, interleaved;
            // process whichever starts first. The drop parse mirrors
            // BlocksFromXml LoadItemsToDrop IL (event/name/count/prob/
            // stick_chance/tool_category/tag -> SItemDropProb).
            const pi = std.mem.findPos(u8, clean, p, "<property ") orelse body_end;
            const di = std.mem.findPos(u8, clean, p, "<drop ") orelse body_end;
            const at = @min(pi, di);
            if (at >= body_end) break;
            if (di < pi) {
                const ev = xml.attr(clean, di, "event") orelse "";
                const drop_list = if (std.mem.eql(u8, ev, "Harvest"))
                    &own_drops
                else if (std.mem.eql(u8, ev, "Destroy"))
                    &own_destroy
                else if (std.mem.eql(u8, ev, "Fall"))
                    &own_fall
                else
                    null;
                if (drop_list != null and drop_list.?.items.len < max_harvest_drops) {
                    const nm = xml.attr(clean, di, "name") orelse {
                        p = di + 6;
                        continue;
                    };
                    const mc = if (xml.attr(clean, di, "count")) |cnt|
                        parseMinMaxCount(cnt)
                    else
                        CountRange{ .min = 1, .max = 1 };
                    var prob: f32 = 1;
                    if (xml.attr(clean, di, "prob")) |pr| prob = std.fmt.parseFloat(f32, pr) catch 1;
                    var stick: f32 = 0;
                    if (xml.attr(clean, di, "stick_chance")) |sc| stick = std.fmt.parseFloat(f32, sc) catch 0;
                    try drop_list.?.append(allocator, .{
                        .item_name = try arena.dupe(u8, nm),
                        .count_min = mc.min,
                        .count_max = mc.max,
                        .prob = prob,
                        .stick_chance = stick,
                        .tool_category = if (xml.attr(clean, di, "tool_category")) |tc| try arena.dupe(u8, tc) else "",
                        .tag = if (xml.attr(clean, di, "tag")) |tg| try arena.dupe(u8, tg) else "",
                    });
                }
                p = di + 6;
                continue;
            }
            const pname = xml.attr(clean, pi, "name") orelse {
                p = pi + 10;
                continue;
            };
            if (std.mem.eql(u8, pname, "Class")) {
                class = xml.attr(clean, pi, "value");
            } else if (std.mem.eql(u8, pname, "TraderID")) {
                if (xml.attr(clean, pi, "value")) |v| trader_id = std.fmt.parseInt(i32, v, 10) catch -1;
            } else if (std.mem.eql(u8, pname, "Extends")) {
                extends = xml.attr(clean, pi, "value");
            } else if (std.mem.eql(u8, pname, "IndexName")) {
                if (xml.attr(clean, pi, "value")) |v| {
                    if (std.mem.eql(u8, v, "TraderOnOff")) trader_onoff = true;
                }
            } else if (std.mem.eql(u8, pname, "HeatMapStrength")) {
                if (xml.attr(clean, pi, "value")) |v| heat_strength = std.fmt.parseFloat(f32, v) catch 0;
            } else if (std.mem.eql(u8, pname, "Modules")) {
                if (xml.attr(clean, pi, "value")) |v| {
                    if (std.mem.find(u8, v, "fuel") != null) has_fuel_module = true;
                }
            } else if (std.mem.eql(u8, pname, "CraftingAreaRecipes")) {
                crafting_areas = xml.attr(clean, pi, "value");
            } else if (std.mem.eql(u8, pname, "ActiveRadiusEffects")) {
                // "buffName,radius" (comma pair, radius blocks). A crafted
                // value that fails to parse leaves no radius effect rather
                // than applying a buff at radius 0.
                if (xml.attr(clean, pi, "value")) |v| {
                    if (std.mem.findScalar(u8, v, ',')) |comma| {
                        const nm = std.mem.trim(u8, v[0..comma], " ");
                        const rs = std.mem.trim(u8, v[comma + 1 ..], " ");
                        if (nm.len > 0) {
                            if (std.fmt.parseFloat(f32, rs) catch null) |r| {
                                if (r > 0) {
                                    radius_effect_buff = nm;
                                    radius_effect_radius_sq = r * r;
                                }
                            }
                        }
                    }
                }
            } else if (std.mem.eql(u8, pname, "PickupSource")) {
                pickup_source = xml.attr(clean, pi, "value");
            } else if (std.mem.eql(u8, pname, "Mesh")) {
                mesh = xml.attr(clean, pi, "value");
            } else if (std.mem.eql(u8, pname, "Texture")) {
                // Top-face texture id = the first value of the comma list.
                if (xml.attr(clean, pi, "value")) |v| {
                    const first = if (std.mem.findScalar(u8, v, ',')) |comma|
                        std.mem.trim(u8, v[0..comma], " ")
                    else
                        std.mem.trim(u8, v, " ");
                    texture_top = std.fmt.parseInt(u16, first, 10) catch 0;
                }
            } else if (std.mem.eql(u8, pname, "MapColor")) {
                // "r,g,b" 0-255 ints -> RGB555 (Utils.ToColor5 on r/255).
                if (xml.attr(clean, pi, "value")) |v| {
                    map_color = parseMapColor5(v);
                }
            } else if (std.mem.eql(u8, pname, "ResourceScale")) {
                // Block-level drop probability multiplier (BlocksFromXml:
                // each drop's prob is scaled by ResourceScale). Zero V3.1.0
                // b14 blocks set it, so stock rows are unmodified; a modded
                // blocks.xml is honoured rather than hardcoded.
                if (xml.attr(clean, pi, "value")) |v| resource_scale = std.fmt.parseFloat(f32, v) catch 1;
            }
            p = pi + 10;
        }
        // Own rows into arena memory (prob already scaled by ResourceScale).
        // Shared so the three events get one copy path.
        const OwnLists = struct {
            harvest: std.ArrayList(HarvestDrop),
            destroy: std.ArrayList(HarvestDrop),
            fall: std.ArrayList(HarvestDrop),
            fn slice(l: std.ArrayList(HarvestDrop), al: std.mem.Allocator, sc: f32) ![]const HarvestDrop {
                if (l.items.len == 0) return &.{};
                const ds = try al.alloc(HarvestDrop, l.items.len);
                for (l.items, 0..) |d, dd| {
                    ds[dd] = d;
                    if (sc != 1) ds[dd].prob = d.prob * sc;
                }
                return ds;
            }
        };
        const own_drop_slice = try OwnLists.slice(own_drops, arena, resource_scale);
        const own_destroy_slice = try OwnLists.slice(own_destroy, arena, resource_scale);
        const own_fall_slice = try OwnLists.slice(own_fall, arena, resource_scale);
        const idx = parsed.items.len;
        try name_idx.put(allocator, kn, idx);
        try parsed.append(allocator, .{
            .id = id,
            .name = kn,
            .class = class,
            .trader_id = trader_id,
            .extends = extends,
            .trader_onoff = trader_onoff,
            .is_door = std.ascii.findIgnoreCase(kn, "door") != null,
            .heat_strength = heat_strength,
            .has_fuel_module = has_fuel_module,
            .crafting_areas = if (crafting_areas) |ca| try arena.dupe(u8, ca) else "",
            .radius_effect_buff = if (radius_effect_buff) |rb| try arena.dupe(u8, rb) else "",
            .radius_effect_radius_sq = radius_effect_radius_sq,
            .pickup_source = if (pickup_source) |ps| try arena.dupe(u8, ps) else "",
            .mesh = if (mesh) |m| try arena.dupe(u8, m) else "",
            .texture_top = texture_top,
            .map_color = map_color,
            .harvest_drops = own_drop_slice,
            .destroy_drops = own_destroy_slice,
            .fall_drops = own_fall_slice,
        });
        i = bi + 7;
    }

    if (parsed.items.len == 0) {
        // No dump match: fall back to builtin pins (offline).
        arena_holder.deinit();
        allocator.destroy(arena_holder);
        return BlockTable.builtin();
    }

    // Resolve the Extends chain for Class / TraderID / drops (own props win).
    // Depth-capped so a corrupt cycle cannot spin; a block inheriting a
    // VendingMachine class is itself treated as vending
    // (cntVendingMachineTrader extends cntVendingMachine).
    const max_extends_depth: usize = 8;
    for (parsed.items, 0..) |*pb, idx_cur| {
        var depth: usize = 0;
        var seen_chain: [max_extends_depth]usize = undefined;
        var chain_n: usize = 0;
        var own_class = pb.class;
        var own_trader = pb.trader_id;
        var own_mesh = pb.mesh;
        var own_texture = pb.texture_top;
        var own_map_color = pb.map_color;
        var own_drops = pb.harvest_drops;
        var own_destroy = pb.destroy_drops;
        var own_fall = pb.fall_drops;
        var ext = pb.extends;
        while (ext) |e| : (depth += 1) {
            if (depth >= max_extends_depth) break;
            if (own_class != null and own_trader >= 0 and own_mesh != null and
                own_texture > 0 and own_map_color > 0 and own_drops.len >= max_harvest_drops and
                own_destroy.len >= max_harvest_drops and own_fall.len >= max_harvest_drops) break;
            var dup = false;
            for (seen_chain[0..chain_n]) |s| {
                if (s == idx_cur) dup = true;
            }
            if (dup) break;
            seen_chain[chain_n] = idx_cur;
            chain_n += 1;
            const base = name_idx.get(e) orelse break;
            const base_p = &parsed.items[base];
            if (own_class == null) own_class = base_p.class;
            if (own_trader < 0) own_trader = base_p.trader_id;
            if (own_mesh == null) own_mesh = base_p.mesh;
            if (own_texture == 0) own_texture = base_p.texture_top;
            if (own_map_color == 0) own_map_color = base_p.map_color;
            // CopyDroppedFrom (IL=89): base drop rows append per event unless
            // the item name is already present (own wins), so a block that
            // declares its own wood row still inherits the base's stone row.
            // Bounded by max_harvest_drops like the own-row parse cap.
            own_drops = try mergeDrops(arena, own_drops, base_p.harvest_drops);
            own_destroy = try mergeDrops(arena, own_destroy, base_p.destroy_drops);
            own_fall = try mergeDrops(arena, own_fall, base_p.fall_drops);
            ext = base_p.extends;
        }
        pb.class = own_class;
        pb.trader_id = @max(own_trader, 0);
        pb.mesh = own_mesh;
        pb.texture_top = own_texture;
        pb.map_color = own_map_color;
        pb.harvest_drops = own_drops;
        pb.destroy_drops = own_destroy;
        pb.fall_drops = own_fall;
    }

    const defs = try arena.alloc(BlockDef, parsed.items.len);
    for (parsed.items, 0..) |pb, di| {
        defs[di] = .{
            .id = pb.id,
            .name = pb.name,
            .solid = isSolidName(pb.name),
            .class = if (pb.class) |c| try arena.dupe(u8, c) else "",
            .trader_id = pb.trader_id,
            .trader_onoff = pb.trader_onoff,
            .is_door = pb.is_door,
            .heat_strength = pb.heat_strength,
            .has_fuel_module = pb.has_fuel_module,
            .crafting_areas = if (pb.crafting_areas) |ca| try arena.dupe(u8, ca) else "",
            .radius_effect_buff = if (pb.radius_effect_buff) |rb| try arena.dupe(u8, rb) else "",
            .radius_effect_radius_sq = pb.radius_effect_radius_sq,
            .mesh = if (pb.mesh) |m| try arena.dupe(u8, m) else "",
            .texture_top = pb.texture_top,
            .map_color = pb.map_color,
            .harvest_drops = pb.harvest_drops,
            .destroy_drops = pb.destroy_drops,
            .fall_drops = pb.fall_drops,
        };
    }
    return .{ .defs = defs, .arena_ptr = arena_holder, .source = .xml };
}

pub fn tryLoad(
    allocator: std.mem.Allocator,
    game_dir: ?[]const u8,
    config_dir: ?[]const u8,
    id_by_name: IdByNameFn,
    ctx: ?*anyopaque,
) !?BlockTable {
    const paths = @import("paths.zig");
    var path_buf: [2048]u8 = undefined;
    const base = paths.resolveConfigXml(&path_buf, "blocks.xml", game_dir, config_dir) orelse return null;
    if (!paths.hasPatches()) {
        return loadLogged(allocator, base, id_by_name, ctx);
    }
    const merged = try paths.readConfigXml(allocator, "blocks.xml", game_dir, config_dir) orelse return null;
    defer allocator.free(merged);
    io_fs.mkdirPath(".zdtd_cfg_cache");
    const cp = ".zdtd_cfg_cache/blocks.xml";
    {
        io_fs.writeFile(cp, merged) catch |err| {
            util_log.err("zdtd: write config cache {s} failed: {s}; using base path\n", .{ cp, @errorName(err) });
            return loadLogged(allocator, base, id_by_name, ctx);
        };
    }
    return loadLogged(allocator, cp, id_by_name, ctx);
}

fn loadLogged(allocator: std.mem.Allocator, path: []const u8, id_by_name: IdByNameFn, ctx: ?*anyopaque) ?BlockTable {
    return loadFromPath(allocator, path, id_by_name, ctx) catch |err| {
        switch (err) {
            error.FileNotFound => {},
            else => util_log.err("zdtd: load blocks.xml failed: {s} ({s})\n", .{ @errorName(err), path }),
        }
        return null;
    };
}

test "builtin block table" {
    const t = BlockTable.builtin();
    try std.testing.expect(t.isSolid(1)); // terrStone
    try std.testing.expect(!t.isSolid(0));
    try std.testing.expectEqualStrings("terrainFiller", t.byId(2).?.name);
    try std.testing.expectEqualStrings("terrDirt", t.byId(5).?.name);
    try std.testing.expect(!t.isSolid(240)); // water
}

test "vending class and TraderID resolve with Extends inheritance" {
    // Fixture mirrors the stock chain: cntVendingMachineTrader extends
    // cntVendingMachine (Class inherited, TraderID overridden), the soda
    // machines extend cntVendingMachine2Broken (TraderID overridden).
    const src =
        \\<blocks>
        \\<block name="cntVendingMachine">
        \\  <property name="Class" value="VendingMachine"/>
        \\  <property name="TraderID" value="3"/>
        \\</block>
        \\<block name="cntVendingMachineTrader">
        \\  <property name="Extends" value="cntVendingMachine"/>
        \\  <property name="TraderID" value="5"/>
        \\</block>
        \\<block name="cntVendingMachine2Broken">
        \\  <property name="Class" value="VendingMachine"/>
        \\  <property name="TraderID" value="10"/>
        \\</block>
        \\<block name="cntVendingMachine2">
        \\  <property name="Extends" value="cntVendingMachine2Broken"/>
        \\  <property name="TraderID" value="4"/>
        \\</block>
        \\<block name="cntWoodCrateWood01">
        \\  <property name="Class" value="Storage"/>
        \\</block>
        \\<block name="doorWoodLargeGate">
        \\  <property name="IndexName" value="TraderOnOff"/>
        \\</block>
        \\<block name="campfire">
        \\  <property name="HeatMapStrength" value="5"/>
        \\  <property class="Workstation">
        \\    <property name="Modules" value="tools,output,fuel,input"/>
        \\  </property>
        \\</block>
        \\<block name="workbench">
        \\  <property class="Workstation">
        \\    <property name="Modules" value="output"/>
        \\    <property name="CraftingAreaRecipes" value="player,workbench"/>
        \\  </property>
        \\</block>
        \\<block name="forge">
        \\  <property class="Workstation">
        \\    <property name="Modules" value="tools,output,fuel,material_input"/>
        \\    <property name="CraftingAreaRecipes" value="forge"/>
        \\  </property>
        \\</block>
        \\</blocks>
    ;
    const path = ".zdtd_test_blocks_vending.xml";
    try io_fs.writeFile(path, src);
    defer io_fs.deleteFile(path);

    var t = try loadFromPath(std.testing.allocator, path, fixtureId, null);
    defer t.deinit();
    try std.testing.expect(t.source == .xml);

    const vm = t.byName("cntVendingMachine").?;
    try std.testing.expect(t.isVending(vm.id));
    try std.testing.expectEqual(@as(i32, 3), t.traderId(vm.id));
    // Inherited class + overridden TraderID through Extends.
    const vmt = t.byName("cntVendingMachineTrader").?;
    try std.testing.expect(t.isVending(vmt.id));
    try std.testing.expectEqual(@as(i32, 5), t.traderId(vmt.id));
    // Soda machine: extends cntVendingMachine2Broken, own TraderID 4.
    const soda = t.byName("cntVendingMachine2").?;
    try std.testing.expect(t.isVending(soda.id));
    try std.testing.expectEqual(@as(i32, 4), t.traderId(soda.id));
    // Non-vending block stays clear.
    const crate = t.byName("cntWoodCrateWood01").?;
    try std.testing.expect(!t.isVending(crate.id));
    try std.testing.expectEqual(@as(i32, 0), t.traderId(crate.id));
    // TraderOnOff gate block (IndexName property).
    const gate = t.byName("doorWoodLargeGate").?;
    try std.testing.expect(t.isTraderOnOff(gate.id));
    try std.testing.expect(!t.isTraderOnOff(crate.id));
    // Door detection (stock door-naming set): a door is a door, a crate is not.
    try std.testing.expect(t.byName("doorWoodLargeGate").?.is_door);
    try std.testing.expect(!t.byName("cntWoodCrateWood01").?.is_door);
    // HeatMapStrength feeds the AI heat map while the block runs.
    const fire = t.byName("campfire").?;
    try std.testing.expectApproxEqAbs(@as(f32, 5), t.heatStrength(fire.id), 1e-4);
    try std.testing.expectEqual(@as(f32, 0), t.heatStrength(crate.id));
    // Workstation Modules: campfire has a fuel module, workbench does not.
    try std.testing.expect(t.hasFuelModule(fire.id));
    const bench = t.byName("workbench").?;
    try std.testing.expect(!t.hasFuelModule(bench.id));
    try std.testing.expect(!t.hasFuelModule(crate.id));
    // CraftingAreaRecipes gate: workbench allows player + workbench recipes
    // only; forge only forge; campfire (no list) only its own name.
    try std.testing.expect(t.allowsCraftArea(bench.id, "workbench"));
    try std.testing.expect(t.allowsCraftArea(bench.id, "player"));
    try std.testing.expect(!t.allowsCraftArea(bench.id, "forge"));
    const forge = t.byName("forge").?;
    try std.testing.expect(t.allowsCraftArea(forge.id, "forge"));
    try std.testing.expect(!t.allowsCraftArea(forge.id, "campfire"));
    try std.testing.expect(t.allowsCraftArea(fire.id, "campfire"));
    try std.testing.expect(!t.allowsCraftArea(fire.id, "forge"));
    try std.testing.expect(!t.allowsCraftArea(fire.id, "player"));
}

test "ActiveRadiusEffects parses the buff name and squared radius" {
    // Shipped shape, verbatim value: <property name="ActiveRadiusEffects"
    // value="buffCampfireAOE,2"/> on wall torches and lit campfires.
    const src =
        \\<blocks>
        \\<block name="torch_wall">
        \\  <property name="ActiveRadiusEffects" value="buffCampfireAOE,2"/>
        \\</block>
        \\<block name="barrelRadiated">
        \\  <property name="ActiveRadiusEffects" value="buffRadiation01,2.5"/>
        \\</block>
        \\<block name="cntWoodCrateWood01">
        \\  <property name="Class" value="Storage"/>
        \\</block>
        \\<block name="crafted_bad">
        \\  <property name="ActiveRadiusEffects" value="notARealPair"/>
        \\</block>
        \\</blocks>
    ;
    const path = ".zdtd_test_blocks_radius_effect.xml";
    try io_fs.writeFile(path, src);
    defer io_fs.deleteFile(path);

    var t = try loadFromPath(std.testing.allocator, path, fixtureId, null);
    defer t.deinit();

    const torch = t.byName("torch_wall").?;
    const eff = t.radiusEffect(torch.id).?;
    try std.testing.expectEqualStrings("buffCampfireAOE", eff.buff);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), eff.radius_sq, 1e-4); // 2^2

    const barrel = t.byName("barrelRadiated").?;
    const beff = t.radiusEffect(barrel.id).?;
    try std.testing.expectEqualStrings("buffRadiation01", beff.buff);
    try std.testing.expectApproxEqAbs(@as(f32, 6.25), beff.radius_sq, 1e-4); // 2.5^2

    // No property at all: no radius effect.
    const crate = t.byName("cntWoodCrateWood01").?;
    try std.testing.expect(t.radiusEffect(crate.id) == null);

    // Malformed value (no comma pair): fails closed to no radius effect
    // rather than a buff applied at radius 0.
    const bad = t.byName("crafted_bad").?;
    try std.testing.expect(t.radiusEffect(bad.id) == null);
}

fn fixtureId(_: ?*anyopaque, name: []const u8) ?u16 {
    // Stable fixture ids (test-only; not the AssignIds table).
    const map = .{
        .{ "cntVendingMachine", 100 },
        .{ "cntVendingMachineTrader", 101 },
        .{ "cntVendingMachine2Broken", 102 },
        .{ "cntVendingMachine2", 103 },
        .{ "cntWoodCrateWood01", 104 },
        .{ "doorWoodLargeGate", 105 },
        .{ "campfire", 106 },
        .{ "workbench", 107 },
        .{ "forge", 108 },
        .{ "torch_wall", 109 },
        .{ "barrelRadiated", 110 },
        .{ "crafted_bad", 111 },
        .{ "terrStone", 200 },
        .{ "terrDirt", 201 },
        .{ "cntOreBase", 202 },
        .{ "cntOreChild", 203 },
        .{ "scaledBlock", 204 },
        .{ "destroyOnly", 205 },
        .{ "fallBase", 206 },
        .{ "fallChild", 207 },
    };
    inline for (map) |e| {
        if (std.mem.eql(u8, name, e[0])) return e[1];
    }
    return null;
}

test "Harvest drop rows parse with Extends inheritance" {
    // Fixture mirrors stock shapes: terrStone carries one Harvest row
    // (count "55" → 55..55), terrDirt a range row, the ore child extends a
    // base (CopyDroppedFrom merges, own wins per item name), ResourceScale
    // scales prob, and a Destroy-only block keeps no Harvest rows.
    const src =
        \\<blocks>
        \\<block name="terrStone">
        \\  <drop event="Harvest" name="resourceRockSmall" count="55" tag="oreWoodHarvest"/>
        \\</block>
        \\<block name="terrDirt">
        \\  <drop event="Harvest" name="resourceClayLump" count="22" tag="oreWoodHarvest"/>
        \\  <drop event="Harvest" name="resourceScrapIron" count="3,6" prob="0.5" stick_chance="0" tool_category="Disassemble"/>
        \\  <drop event="Harvest" name="resourceScrapIron" count="0" tag="salvageHarvest"/>
        \\</block>
        \\<block name="cntOreBase">
        \\  <drop event="Harvest" name="resourceWood" count="2" tag="allHarvest"/>
        \\  <drop event="Harvest" name="terrStone" count="1" prob="0.25"/>
        \\</block>
        \\<block name="cntOreChild">
        \\  <property name="Extends" value="cntOreBase"/>
        \\  <drop event="Harvest" name="resourceWood" count="5" tag="lumberjackHarvest"/>
        \\</block>
        \\<block name="scaledBlock">
        \\  <property name="ResourceScale" value="0.5"/>
        \\  <drop event="Harvest" name="resourceScrapIron" count="10" prob="0.8"/>
        \\</block>
        \\<block name="destroyOnly">
        \\  <drop event="Destroy" name="terrDirt" count="1" prob="0.75" stick_chance="1"/>
        \\  <drop event="Destroy" count="0"/>
        \\</block>
        \\<block name="fallBase">
        \\  <drop event="Fall" name="terrDirt" count="1" prob="0.25" stick_chance="1"/>
        \\</block>
        \\<block name="fallChild">
        \\  <property name="Extends" value="fallBase"/>
        \\  <drop event="Fall" name="terrDirt" count="2" prob="0.5"/>
        \\  <drop event="Fall" name="resourceRockSmall" count="44" prob="0.23" stick_chance="0"/>
        \\</block>
        \\</blocks>
    ;
    const path = ".zdtd_test_blocks_drops.xml";
    try io_fs.writeFile(path, src);
    defer io_fs.deleteFile(path);

    var t = try loadFromPath(std.testing.allocator, path, fixtureId, null);
    defer t.deinit();

    // Single fixed-count row: count "55" → 55..55, prob default 1, tag kept.
    const stone = t.byName("terrStone").?;
    const sd = t.harvestDrops(stone.id);
    try std.testing.expectEqual(@as(usize, 1), sd.len);
    try std.testing.expectEqualStrings("resourceRockSmall", sd[0].item_name);
    try std.testing.expectEqual(@as(u32, 55), sd[0].count_min);
    try std.testing.expectEqual(@as(u32, 55), sd[0].count_max);
    try std.testing.expectEqual(@as(f32, 1), sd[0].prob);
    try std.testing.expectEqualStrings("oreWoodHarvest", sd[0].tag);

    // Range row "3,6" + prob + stick_chance + tool_category; the duplicate
    // item name with count 0 parses too (the roll skips count 0).
    const dirt = t.byName("terrDirt").?;
    const dd = t.harvestDrops(dirt.id);
    try std.testing.expectEqual(@as(usize, 3), dd.len);
    try std.testing.expectEqualStrings("resourceScrapIron", dd[1].item_name);
    try std.testing.expectEqual(@as(u32, 3), dd[1].count_min);
    try std.testing.expectEqual(@as(u32, 6), dd[1].count_max);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), dd[1].prob, 1e-4);
    try std.testing.expectEqualStrings("Disassemble", dd[1].tool_category);
    try std.testing.expectEqual(@as(u32, 0), dd[2].count_max);

    // Extends inheritance (CopyDroppedFrom): the child's own resourceWood
    // wins; the base's terrStone row appends. No duplicates.
    const child = t.byName("cntOreChild").?;
    const cd = t.harvestDrops(child.id);
    try std.testing.expectEqual(@as(usize, 2), cd.len);
    try std.testing.expectEqualStrings("resourceWood", cd[0].item_name);
    try std.testing.expectEqual(@as(u32, 5), cd[0].count_min); // own, not base 2
    try std.testing.expectEqualStrings("lumberjackHarvest", cd[0].tag);
    try std.testing.expectEqualStrings("terrStone", cd[1].item_name);
    try std.testing.expectEqual(@as(f32, 0.25), cd[1].prob);

    // ResourceScale multiplies the row prob (0.8 * 0.5 = 0.4).
    const scaled = t.byName("scaledBlock").?;
    const sc = t.harvestDrops(scaled.id);
    try std.testing.expectEqual(@as(usize, 1), sc.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), sc[0].prob, 1e-4);

    // Destroy-only rows are not Harvest drops (bounded slice); the nameless
    // count=0 Destroy row parses away (stock no-op override row).
    const dstr = t.byName("destroyOnly").?;
    try std.testing.expectEqual(@as(usize, 0), t.harvestDrops(dstr.id).len);
    const dd_ = t.dropsFor(dstr.id, .destroy);
    try std.testing.expectEqual(@as(usize, 1), dd_.len);
    try std.testing.expectEqualStrings("terrDirt", dd_[0].item_name);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), dd_[0].prob, 1e-4);

    // Fall rows route to their own event; Extends merges per event with the
    // same own-wins-per-name rule (the child's terrDirt overrides the base's,
    // and the base's rows would only append under different names - here the
    // child's own rows both win, so exactly 2 rows survive).
    const fc = t.byName("fallChild").?;
    const fd = t.dropsFor(fc.id, .fall);
    try std.testing.expectEqual(@as(usize, 2), fd.len);
    try std.testing.expectEqualStrings("terrDirt", fd[0].item_name);
    try std.testing.expectEqual(@as(u32, 2), fd[0].count_min); // own, not base 1
    try std.testing.expectEqualStrings("resourceRockSmall", fd[1].item_name);
    try std.testing.expectEqual(@as(f32, 0.23), fd[1].prob);
    // The child's Fall rows do not leak into Harvest or Destroy.
    try std.testing.expectEqual(@as(usize, 0), t.dropsFor(fc.id, .harvest).len);
    try std.testing.expectEqual(@as(usize, 0), t.dropsFor(fc.id, .destroy).len);
    // The base's own Fall row (terrDirt) was overridden, not duplicated.
    const fb = t.byName("fallBase").?;
    try std.testing.expectEqual(@as(usize, 1), t.dropsFor(fb.id, .fall).len);
}
