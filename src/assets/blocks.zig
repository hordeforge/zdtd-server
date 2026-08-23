//! blocks.xml solid/name table. Wire ids come only from AssignIds (idByName),
//! never sequential XML declaration order.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const util_log = @import("../util/log.zig");
const assignids = @import("assignids_comptime.zig");

pub const max_blocks: usize = 8192;

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
        const body_end = if (std.mem.findPos(u8, clean, bi, "</block>")) |e| e else clean.len;
        var p = bi + 7;
        while (p < body_end) : (p += 1) {
            const pi = std.mem.findPos(u8, clean, p, "<property ") orelse break;
            if (pi > body_end) break;
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
            }
            p = pi + 10;
        }
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
        });
        i = bi + 7;
    }

    if (parsed.items.len == 0) {
        // No dump match: fall back to builtin pins (offline).
        arena_holder.deinit();
        allocator.destroy(arena_holder);
        return BlockTable.builtin();
    }

    // Resolve the Extends chain for Class / TraderID (own props win). Depth-capped
    // so a corrupt cycle cannot spin; a block inheriting a VendingMachine class is
    // itself treated as vending (cntVendingMachineTrader extends cntVendingMachine).
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
        var ext = pb.extends;
        while (ext) |e| : (depth += 1) {
            if (depth >= max_extends_depth) break;
            if (own_class != null and own_trader >= 0 and own_mesh != null and
                own_texture > 0 and own_map_color > 0) break;
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
            ext = base_p.extends;
        }
        pb.class = own_class;
        pb.trader_id = if (own_trader < 0) 0 else own_trader;
        pb.mesh = own_mesh;
        pb.texture_top = own_texture;
        pb.map_color = own_map_color;
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
    };
    inline for (map) |e| {
        if (std.mem.eql(u8, name, e[0])) return e[1];
    }
    return null;
}
