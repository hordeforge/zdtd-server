//! blocks.xml solid/name table. Wire ids come only from AssignIds (idByName),
//! never sequential XML declaration order.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const util_log = @import("../util/log.zig");
const assignids = @import("assignids_comptime.zig");
const paths = @import("paths.zig");
/// Test-only: the stock AssignIds dump, to pin that a stock install never
/// enters the leftover-id path. Production passes the resolver in as a
/// callback, so the dependency stays one-way.
/// Storage cap on parsed block defs, a zdtd bound rather than a stock rule:
/// stock assigns ids dynamically and the wire id space is 16 bits
/// (`wire/stock_nameid.max_blocks` = 0x10000). Measured against V3.2.0
/// `Data/Config` (2026-09-04): stock blocks.xml defines **6643**, so this sits
/// at 81% and leaves roughly 1550 slots for modlets, the tightest cap in the
/// loader set.
///
/// Overflow matters more here than for the other catalogs: a truncated block
/// table means names missing from the negotiated AssignIds map, and the client
/// resolves block ids through that map, so the loss is wire-visible. The parse
/// logs once at the cap rather than shipping a short table in silence.
pub const max_blocks: usize = 8192;

/// The block id space: stock's `MAX_BLOCKS` bounds the used-id array the
/// leftover assignment scans, and a zdtd block id is a u16 on the wire.
pub const max_block_ids: usize = 65536;

/// Where `assignLeftOverBlocks` starts scanning for a non-terrain block
/// (stock's literal 0xff; terrain scans from 0).
pub const leftover_id_start: u32 = 0xff;

/// Max `<drop>` rows a block may resolve (own + Extends-inherited; the
/// largest stock block carries 16 Harvest rows, 1,748 Harvest rows total).
pub const max_harvest_drops: usize = 16;

/// `<property name="Collide" value="movement,melee,..."/>` blocking-type mask
/// (stock `Block.BlockingType`): one bit per verb, OR-ed from zero when the
/// property is present (BlocksFromXml IL_0404-04F0).
pub const CollideMask = u8;

// Bits in stock OR order: sight 1, movement 2, bullet(s) 4, rocket(s) 8,
// arrow(s) 32, melee 16 (BlocksFromXml IL_0431-04CE); all six = 63. The needle
// is the singular verb, matched as a case-insensitive SUBSTRING of the value
// (`Extensions::ContainsCaseInsensitive`, Extensions.il IL=9:
// value.IndexOf(verb, OrdinalIgnoreCase) >= 0), not a token-exact compare.
pub const collide_sight: CollideMask = 1;
pub const collide_movement: CollideMask = 2;
pub const collide_bullets: CollideMask = 4;
pub const collide_rockets: CollideMask = 8;
pub const collide_melee: CollideMask = 16;
pub const collide_arrows: CollideMask = 32;

/// The absent-`Collide` value: `blockMaterial.IsCollidable ? 255 : 0`
/// (BlocksFromXml IL_04D5-04EB), i.e. 255 blocks every verb for a collidable
/// material. zdtd parses materials.xml `collidable` in maxdamage.zig
/// (`mergeMaterialsXml`), but blocks.zig is not given a material handle at this
/// layer, so the 0 half (the 4 stock non-collidable materials) is the later
/// step; 255 is the stock value for every collidable material.
pub const collide_default: CollideMask = 0xff;

/// The three stock drop events (`EnumDropEvent`: Destroy=0, Fall=1,
/// Harvest=2, il/full-v3.2.0/_global/EnumDropEvent.il.txt).
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
    /// blocks.xml `Tags` property (519/6653 stock rows): the block's tag set,
    /// feeding `TriggerHasTags` on the block-damage events (the church-bell
    /// spawn gate). "" = no tags declared.
    tags: []const u8 = "",
    /// Block Class property (engine class name, e.g. "VendingMachine"). 0
    /// length = not parsed / unknown.
    class: []const u8 = "",
    /// TraderID property (blocks.xml), resolved through the Extends chain.
    trader_id: i32 = 0,
    /// Door block: stock tags the openables with `BlockTag="Door"`
    /// (`BlockTags` bit 2 in the code-side FastTag set), resolved through
    /// Extends like every string property (79 shipped rows; the chainlink
    /// gates, hatches and porta-potties carry the tag with no "door" in the
    /// name). Zombies open these on their path instead of chewing, and powered
    /// doors actuate on them.
    is_door: bool = false,
    /// blocks.xml `LPHardnessScale` (stock `Block.LPHardnessScale`, default 1
    /// when the property is absent - Block's property loader sets it at
    /// IL_0553-0559 before reading `LPHardnessScale`): the land-claim hardness
    /// baseline. 0 opts a block out of claim protection entirely (stock ships
    /// `cntGasPumpRandomLootHelper` at 0), and the value multiplies the claim
    /// owner's durability modifier. Only 7 stock rows override the default.
    lp_hardness_scale: f32 = 1,
    /// The block's composite TE carries `TEFeatureSignable`: blocks.xml
    /// declares it as `<property class="TEFeatureSignable">` inside
    /// `CompositeFeatures` (9 stock blocks: the player signs, the metal sign
    /// letters and the writable crates). Only these positions accept a C2S
    /// sign-text TE write.
    signable: bool = false,
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
    /// Workstation Modules list contains "material_input": forge melt path
    /// (HandleMaterialInput). Campfire uses "input" (no melt).
    has_material_input: bool = false,
    /// Workstation InputMaterials comma list ("iron,brass,lead,glass,stone,clay").
    /// Empty = no forge material slots. Arena-owned.
    input_materials: []const u8 = "",
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
    /// blocks.xml `Material` property (e.g. Mstone, Mair): the materials.xml
    /// row whose `collidable` decides the undeclared-`Collide` default (stock
    /// `BlocksFromXml` IL_04D5-04EB: `blockMaterial.IsCollidable ? 255 : 0`).
    /// Resolved through Extends like the other string properties.
    material: []const u8 = "",
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
    /// `<property name="Collide" ...>` blocking-type mask (stock
    /// `Block.BlockingType`), resolved through Extends. Absent at the end of
    /// the chain -> `collide_default` (255). Recorded only; see `collideMask`.
    collide: CollideMask = collide_default,
    /// True when any block in the Extends chain declared `Collide` (including
    /// an explicit 0 mask). Drives `applyMaterialCollideDefaults`: only the
    /// absent default is material-driven.
    collide_declared: bool = false,
    /// `<property name="CanPlayersSpawnOn">`: stock `Block::CanPlayersSpawnOn`
    /// defaults TRUE (Block.il IL_01BF-01F4) and 24 stock rows declare false
    /// (treeMaster and the vehicle masters), so a forest or vehicle column does
    /// not spawn a player on top of it. Resolved through Extends.
    can_players_spawn_on: bool = true,
    /// `<property name="PassThroughDamage">` (102 stock rows, all true: the
    /// door/gate/hatch chains and the wood/steel/vehicle masters). Stock
    /// `Block.OnBlockDamaged` IL_0384-03AE hands the leftover damage
    /// (incoming - MaxDamage) to the replacement block at the same cell.
    pass_through: bool = false,
    /// `<property name="CanMobsSpawnOn">`: stock's default is FALSE and 24
    /// stock rows declare true (terrain, terrainFiller, farm plots, a few
    /// trees). Recorded; the AI spawn gate reads it through `canMobsSpawnOn`.
    can_mobs_spawn_on: bool = false,
};

pub const IdByNameFn = *const fn (?*anyopaque, []const u8) ?u16;

pub const BlockTable = struct {
    defs: []const BlockDef = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    source: enum { builtin, xml } = .builtin,

    pub fn deinit(self: *BlockTable) void {
        arena_util.destroyHolder(&self.arena_ptr);
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

    /// `PassThroughDamage` for a block (default false), resolved through
    /// Extends like the other blocks.xml properties.
    pub fn passThrough(self: *const BlockTable, id: u16) bool {
        if (self.byId(id)) |d| return d.pass_through;
        return false;
    }

    /// `<property name="CanPlayersSpawnOn">` for a block, default true
    /// (stock `Chunk::CanPlayersSpawnAtPos` IL_0023 requires the block under
    /// the feet to allow it).
    pub fn canPlayersSpawnOn(self: *const BlockTable, id: u16) bool {
        if (self.byId(id)) |d| return d.can_players_spawn_on;
        return true;
    }

    /// `<property name="CanMobsSpawnOn">` for a block, default false (stock
    /// `Chunk::CanMobsSpawnAtPos` IL_0043).
    pub fn canMobsSpawnOn(self: *const BlockTable, id: u16) bool {
        if (self.byId(id)) |d| return d.can_mobs_spawn_on;
        return false;
    }

    /// Blocking-type mask for a block (stock `Block.BlockingType`): the
    /// `Collide` property resolved through Extends, or `collide_default` (255)
    /// when no block in the chain declares it, and for an unknown id. Nothing
    /// consumes it yet (solidity still runs through `isSolid`); it is the
    /// recorded stock value for the later change.
    pub fn collideMask(self: *const BlockTable, id: u16) CollideMask {
        if (self.byId(id)) |d| return d.collide;
        return collide_default;
    }

    /// Apply the material `collidable` default to blocks with no declared
    /// `Collide` (stock `BlocksFromXml` IL_04D5-04EB:
    /// `blockMaterial.IsCollidable ? 255 : 0`). Declared masks (including an
    /// explicit 0) are untouched; only the absent default is material-driven.
    /// Runs at Game init where both tables exist, keeping `world/` table-free.
    pub fn applyMaterialCollideDefaults(self: *BlockTable, collidable: std.StringHashMapUnmanaged(bool)) void {
        for (@constCast(self.defs)) |*d| {
            if (d.collide_declared) continue;
            if (d.material.len == 0) continue;
            if (collidable.get(d.material)) |c| {
                if (!c) d.collide = 0;
            }
        }
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

    /// True when Modules includes "material_input" (forge melt path).
    pub fn hasMaterialInput(self: *const BlockTable, id: u16) bool {
        if (self.byId(id)) |d| return d.has_material_input;
        return false;
    }

    /// InputMaterials comma list, or empty when unset / unknown.
    pub fn inputMaterials(self: *const BlockTable, id: u16) []const u8 {
        if (self.byId(id)) |d| return d.input_materials;
        return "";
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

/// BlocksFromXml IL_0404-04F0: when `Collide` is present the mask starts at 0
/// and ORs one bit per verb found in the value by a case-insensitive SUBSTRING
/// test (`Extensions::ContainsCaseInsensitive`, Extensions.il IL=9:
/// value.IndexOf(verb, OrdinalIgnoreCase) >= 0), so "bullets" sets the bullet
/// bit and "Movement,MELEE" sets both. The caller supplies the absent default.
fn parseCollideMask(v: []const u8) CollideMask {
    var m: CollideMask = 0;
    if (std.ascii.findIgnoreCase(v, "sight") != null) m |= collide_sight;
    if (std.ascii.findIgnoreCase(v, "movement") != null) m |= collide_movement;
    if (std.ascii.findIgnoreCase(v, "bullet") != null) m |= collide_bullets;
    if (std.ascii.findIgnoreCase(v, "rocket") != null) m |= collide_rockets;
    if (std.ascii.findIgnoreCase(v, "arrow") != null) m |= collide_arrows;
    if (std.ascii.findIgnoreCase(v, "melee") != null) m |= collide_melee;
    return m;
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
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    // Raw per-block props for Class / TraderID / Extends, keyed by name, so the
    // extends chain can be resolved after the single scan pass.
    const Parsed = struct {
        id: u16,
        name: []const u8,
        class: ?[]const u8 = null,
        tags: ?[]const u8 = null,
        trader_id: i32 = -1, // -1 = not declared
        extends: ?[]const u8 = null,
        /// Extends `param1`: the property names this block does not inherit
        /// from its parent (stock CreateProperties; Class is the common one).
        extends_param1: []const u8 = "",
        trader_onoff: bool = false,
        /// Raw `BlockTag` value (`"Door"` for the openables), resolved through
        /// Extends during the chain walk. `is_door` below is derived from it.
        block_tag: ?[]const u8 = null,
        is_door: bool = false,
        signable: bool = false,
        /// `Shape="Terrain"` (stock `BlockShape::IsTerrain`, the 17 terrain
        /// rows): leftovers take ids from 0 rather than 0xff.
        terrain: bool = false,
        /// True while the AssignIds dump has no id for this name (a
        /// modlet-added block). `assignLeftOverBlocks` fills these after every
        /// pinned id is known.
        unassigned: bool = false,
        lp_hardness_scale: f32 = 1,
        /// True when this row (or a base) declared LPHardnessScale. The
        /// default 1 is not an override, so the chain needs to tell them apart.
        lp_declared: bool = false,
        heat_strength: f32 = 0,
        has_fuel_module: bool = false,
        has_material_input: bool = false,
        input_materials: ?[]const u8 = null,
        crafting_areas: ?[]const u8 = null,
        radius_effect_buff: ?[]const u8 = null,
        radius_effect_radius_sq: f32 = 0,
        pickup_source: ?[]const u8 = null,
        mesh: ?[]const u8 = null,
        material: ?[]const u8 = null,
        texture_top: u16 = 0,
        map_color: u16 = 0,
        /// Own `Collide` blocking-type mask. Only a declared property can be
        /// nonzero-based, so `collide_declared` tells the Extends walk an own
        /// value (including a zero mask) from "ask the parent".
        collide: CollideMask = collide_default,
        collide_declared: bool = false,
        can_players_spawn_on: bool = true,
        can_players_spawn_declared: bool = false,
        can_mobs_spawn_on: bool = false,
        can_mobs_spawn_declared: bool = false,
        pass_through: bool = false,
        pass_through_declared: bool = false,
        /// `<dropextendsoff />`: this block does NOT copy the parent's drop
        /// rows (stock BlocksFromXml reads the element next to the drop list
        /// and skips LoadExtendedItemDrops; 226 stock rows).
        drop_extends_off: bool = false,
        /// Own (non-inherited) drop rows per event, arena-backed.
        harvest_drops: []const HarvestDrop = &.{},
        destroy_drops: []const HarvestDrop = &.{},
        fall_drops: []const HarvestDrop = &.{},
    };
    var parsed: std.ArrayList(Parsed) = .empty;
    defer parsed.deinit(allocator);
    var name_idx: std.StringHashMapUnmanaged(usize) = .empty;
    defer name_idx.deinit(allocator);

    var i: usize = 0;
    while (i < clean.len and parsed.items.len < max_blocks) {
        const bi = std.mem.findPos(u8, clean, i, "<block ") orelse break;
        if (parsed.items.len + 1 == max_blocks) {
            util_log.err(
                "zdtd: blocks.xml hit the {d}-block cap; later blocks are dropped " ++
                    "and will be missing from the AssignIds map\n",
                .{max_blocks},
            );
        }
        const name = xml.attr(clean, bi, "name") orelse {
            i = bi + 7;
            continue;
        };
        if (seen.contains(name)) {
            i = bi + 7;
            continue;
        }
        // A name the AssignIds dump does not carry is a modlet's own block:
        // stock assigns it an id from the leftover pool (Block.assignIdsLinear
        // -> assignLeftOverBlocks) instead of dropping the block.
        const pinned_id = id_by_name(ctx, name);
        const id: u16 = pinned_id orelse 0;
        const kn = try arena.dupe(u8, name);
        try seen.put(allocator, kn, {});
        // Scan this block's body for Class / TraderID / Extends / IndexName /
        // HeatMapStrength.
        var class: ?[]const u8 = null;
        var trader_id: i32 = -1;
        var extends: ?[]const u8 = null;
        var extends_param1: []const u8 = "";
        var trader_onoff = false;
        var block_tag: ?[]const u8 = null;
        var tags: ?[]const u8 = null;
        var signable = false;
        var lp_hardness_scale: f32 = 1;
        var lp_declared = false;
        var heat_strength: f32 = 0;
        var has_fuel_module = false;
        var has_material_input = false;
        var input_materials: ?[]const u8 = null;
        var crafting_areas: ?[]const u8 = null;
        var radius_effect_buff: ?[]const u8 = null;
        var radius_effect_radius_sq: f32 = 0;
        var pickup_source: ?[]const u8 = null;
        var terrain = false;
        var mesh: ?[]const u8 = null;
        var material: ?[]const u8 = null;
        var texture_top: u16 = 0;
        var map_color: u16 = 0;
        var collide: CollideMask = collide_default;
        var collide_declared = false;
        var can_players_spawn_on = true;
        var can_players_spawn_declared = false;
        var can_mobs_spawn_on = false;
        var can_mobs_spawn_declared = false;
        var pass_through = false;
        var pass_through_declared = false;
        var resource_scale: f32 = 1;
        var drop_extends_off = false;
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
            const dxi = std.mem.findPos(u8, clean, p, "<dropextendsoff") orelse body_end;
            const at = @min(pi, @min(di, dxi));
            if (at >= body_end) break;
            if (dxi < pi and dxi < di) {
                drop_extends_off = true;
                p = dxi + 15;
                continue;
            }
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
                // `<property class="TEFeatureSignable">` is a composite module
                // declaration, not a named property: stock reads these into the
                // TE module list (BlocksFromXml CompositeFeatures) and the
                // module order decides the wire feature order.
                if (xml.attr(clean, pi, "class")) |cn| {
                    if (std.ascii.eqlIgnoreCase(cn, "TEFeatureSignable")) signable = true;
                }
                p = pi + 10;
                continue;
            };
            if (std.mem.eql(u8, pname, "Class")) {
                class = xml.attr(clean, pi, "value");
            } else if (std.mem.eql(u8, pname, "Tags")) {
                tags = xml.attr(clean, pi, "value");
            } else if (std.mem.eql(u8, pname, "BlockTag")) {
                // Stock tags the openables with `BlockTag="Door"` (bit 2 of the
                // code-side FastTag set; `EAIBreakBlock` IL_003D,
                // `EntityMoveHelper` IL_0053), including the gates, hatches and
                // porta-potties whose names carry no "door".
                block_tag = xml.attr(clean, pi, "value");
            } else if (std.mem.eql(u8, pname, "TraderID")) {
                if (xml.attr(clean, pi, "value")) |v| trader_id = std.fmt.parseInt(i32, v, 10) catch -1;
            } else if (std.mem.eql(u8, pname, "Extends")) {
                extends = xml.attr(clean, pi, "value");
                extends_param1 = xml.attr(clean, pi, "param1") orelse "";
            } else if (std.mem.eql(u8, pname, "IndexName")) {
                if (xml.attr(clean, pi, "value")) |v| {
                    if (std.mem.eql(u8, v, "TraderOnOff")) trader_onoff = true;
                }
            } else if (std.mem.eql(u8, pname, "Shape")) {
                if (xml.attr(clean, pi, "value")) |v| terrain = std.ascii.eqlIgnoreCase(v, "Terrain");
            } else if (std.mem.eql(u8, pname, "LPHardnessScale")) {
                if (xml.attr(clean, pi, "value")) |v| {
                    lp_hardness_scale = std.fmt.parseFloat(f32, v) catch 1;
                    lp_declared = true;
                }
            } else if (std.mem.eql(u8, pname, "HeatMapStrength")) {
                if (xml.attr(clean, pi, "value")) |v| heat_strength = std.fmt.parseFloat(f32, v) catch 0;
            } else if (std.mem.eql(u8, pname, "Modules")) {
                if (xml.attr(clean, pi, "value")) |v| {
                    if (std.mem.find(u8, v, "fuel") != null) has_fuel_module = true;
                    if (std.mem.find(u8, v, "material_input") != null) has_material_input = true;
                }
            } else if (std.mem.eql(u8, pname, "InputMaterials")) {
                input_materials = xml.attr(clean, pi, "value");
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
            } else if (std.mem.eql(u8, pname, "Material")) {
                material = xml.attr(clean, pi, "value");
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
            } else if (std.mem.eql(u8, pname, "CanPlayersSpawnOn")) {
                if (xml.attr(clean, pi, "value")) |v| {
                    can_players_spawn_on = std.ascii.eqlIgnoreCase(v, "true");
                    can_players_spawn_declared = true;
                }
            } else if (std.mem.eql(u8, pname, "PassThroughDamage")) {
                if (xml.attr(clean, pi, "value")) |v| {
                    pass_through = std.ascii.eqlIgnoreCase(v, "true");
                    pass_through_declared = true;
                }
            } else if (std.mem.eql(u8, pname, "CanMobsSpawnOn")) {
                if (xml.attr(clean, pi, "value")) |v| {
                    can_mobs_spawn_on = std.ascii.eqlIgnoreCase(v, "true");
                    can_mobs_spawn_declared = true;
                }
            } else if (std.mem.eql(u8, pname, "Collide")) {
                // Presence alone starts the mask at 0 and ORs a bit per verb
                // found (BlocksFromXml IL_0404-04F0), so a property with no
                // value attr is 0, not the absent default.
                collide = if (xml.attr(clean, pi, "value")) |v| parseCollideMask(v) else 0;
                collide_declared = true;
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
            .unassigned = pinned_id == null,
            .terrain = terrain,
            .name = kn,
            .class = class,
            .tags = if (tags) |t| try arena.dupe(u8, t) else null,
            .trader_id = trader_id,
            .extends = extends,
            .extends_param1 = if (extends_param1.len > 0) try arena.dupe(u8, extends_param1) else "",
            .trader_onoff = trader_onoff,
            .block_tag = if (block_tag) |bt| try arena.dupe(u8, bt) else null,
            .is_door = false, // resolved from BlockTag after the Extends walk
            .signable = signable,
            .lp_hardness_scale = lp_hardness_scale,
            .lp_declared = lp_declared,
            .heat_strength = heat_strength,
            .has_fuel_module = has_fuel_module,
            .has_material_input = has_material_input,
            .input_materials = if (input_materials) |im| try arena.dupe(u8, im) else "",
            .crafting_areas = if (crafting_areas) |ca| try arena.dupe(u8, ca) else "",
            .radius_effect_buff = if (radius_effect_buff) |rb| try arena.dupe(u8, rb) else "",
            .radius_effect_radius_sq = radius_effect_radius_sq,
            .pickup_source = if (pickup_source) |ps| try arena.dupe(u8, ps) else "",
            .mesh = if (mesh) |m| try arena.dupe(u8, m) else "",
            .material = if (material) |m| try arena.dupe(u8, m) else null,
            .texture_top = texture_top,
            .map_color = map_color,
            .collide = collide,
            .collide_declared = collide_declared,
            .can_players_spawn_on = can_players_spawn_on,
            .can_players_spawn_declared = can_players_spawn_declared,
            .can_mobs_spawn_on = can_mobs_spawn_on,
            .can_mobs_spawn_declared = can_mobs_spawn_declared,
            .pass_through = pass_through,
            .pass_through_declared = pass_through_declared,
            .drop_extends_off = drop_extends_off,
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
        var own_material = pb.material;
        var own_texture = pb.texture_top;
        var own_map_color = pb.map_color;
        var own_collide = pb.collide;
        var own_collide_declared = pb.collide_declared;
        var own_can_players = pb.can_players_spawn_on;
        var own_can_players_declared = pb.can_players_spawn_declared;
        var own_can_mobs = pb.can_mobs_spawn_on;
        var own_can_mobs_declared = pb.can_mobs_spawn_declared;
        var own_pass_through = pb.pass_through;
        var own_pass_through_declared = pb.pass_through_declared;
        var own_signable = pb.signable;
        var own_tag = pb.block_tag;
        var own_tags = pb.tags;
        var own_lp = pb.lp_hardness_scale;
        var own_lp_declared = pb.lp_declared;
        var own_drops = pb.harvest_drops;
        var own_destroy = pb.destroy_drops;
        var own_fall = pb.fall_drops;
        var ext = pb.extends;
        while (ext) |e| : (depth += 1) {
            if (depth >= max_extends_depth) break;
            if (own_class != null and own_trader >= 0 and own_mesh != null and
                own_texture > 0 and own_map_color > 0 and own_drops.len >= max_harvest_drops and
                own_destroy.len >= max_harvest_drops and own_fall.len >= max_harvest_drops) break;
            const base = name_idx.get(e) orelse break;
            // Cycle guard: the chain step is what repeats, not the block the
            // walk started from. Recording `idx_cur` here made `seen_chain[0]`
            // always equal it, so the second hop always tripped the dup check
            // and every Extends chain truncated after one level.
            var dup = base == idx_cur;
            for (seen_chain[0..chain_n]) |s| {
                if (s == base) dup = true;
            }
            if (dup) break;
            seen_chain[chain_n] = base;
            chain_n += 1;
            const base_p = &parsed.items[base];
            // The starting block's Extends param1 excludes those properties
            // from the whole chain (stock CreateProperties copies the parent's
            // *resolved* dictionary minus the child's list, so an exclusion
            // also hides a grandparent value); the excluded field keeps its
            // default.
            const p1 = pb.extends_param1;
            if (own_class == null and !xml.tagListContains(p1, "Class")) own_class = base_p.class;
            if (own_trader < 0 and !xml.tagListContains(p1, "TraderID")) own_trader = base_p.trader_id;
            if (own_mesh == null and !xml.tagListContains(p1, "Mesh")) own_mesh = base_p.mesh;
            if (own_material == null and !xml.tagListContains(p1, "Material")) own_material = base_p.material;
            if (own_texture == 0 and !xml.tagListContains(p1, "Texture")) own_texture = base_p.texture_top;
            if (own_map_color == 0 and !xml.tagListContains(p1, "MapColor")) own_map_color = base_p.map_color;
            // Collide follows the chain like the other blocks.xml properties
            // (the absent default is not an override). The starting block's
            // Extends param1 hides an ancestor's mask: `opaqueBusinessGlass`
            // extends glassBusinessCTRSheet with param1="Mesh,Collide", so it
            // keeps collide_default (255) instead of the glass mask.
            if (!own_collide_declared and !xml.tagListContains(p1, "Collide")) {
                own_collide = base_p.collide;
                if (base_p.collide_declared) own_collide_declared = true;
            }
            if (!own_can_players_declared and !xml.tagListContains(p1, "CanPlayersSpawnOn")) {
                own_can_players = base_p.can_players_spawn_on;
                if (base_p.can_players_spawn_declared) own_can_players_declared = true;
            }
            if (!own_can_mobs_declared and !xml.tagListContains(p1, "CanMobsSpawnOn")) {
                own_can_mobs = base_p.can_mobs_spawn_on;
                if (base_p.can_mobs_spawn_declared) own_can_mobs_declared = true;
            }
            if (!own_pass_through_declared and !xml.tagListContains(p1, "PassThroughDamage")) {
                own_pass_through = base_p.pass_through;
                if (base_p.pass_through_declared) own_pass_through_declared = true;
            }
            // A sign block's shape lives on its base (playerSignWood1x3
            // extends playerSignWood1x1 and declares no CompositeFeatures of
            // its own), so the module flag follows the chain.
            if (!own_signable) own_signable = base_p.signable;
            // BlockTag follows the chain like the other string properties
            // (own wins; no stock row excludes it through param1). An
            // explicitly-tagged row never changes the result down-chain, so
            // one walk covers it.
            if (own_tag == null) own_tag = base_p.block_tag;
            // Tags (TriggerHasTags / church-bell gate): churchBellHanging
            // extends churchBell and declares no Tags of its own, so the
            // parent's `churchbell` tag must follow the chain.
            if (own_tags == null and !xml.tagListContains(p1, "Tags")) own_tags = base_p.tags;
            // LPHardnessScale follows the chain like every other blocks.xml
            // property the loader copies (the default is not an override).
            if (!own_lp_declared) {
                own_lp = base_p.lp_hardness_scale;
                if (base_p.lp_declared) own_lp_declared = true;
            }
            // CopyDroppedFrom (IL=89): base drop rows append per event unless
            // the item name is already present (own wins), so a block that
            // declares its own wood row still inherits the base's stone row.
            // Bounded by max_harvest_drops like the own-row parse cap.
            if (!pb.drop_extends_off) {
                own_drops = try mergeDrops(arena, own_drops, base_p.harvest_drops);
                own_destroy = try mergeDrops(arena, own_destroy, base_p.destroy_drops);
                own_fall = try mergeDrops(arena, own_fall, base_p.fall_drops);
            }
            ext = base_p.extends;
        }
        pb.class = own_class;
        pb.trader_id = @max(own_trader, 0);
        pb.mesh = own_mesh;
        pb.material = own_material;
        pb.block_tag = own_tag;
        pb.tags = own_tags;
        pb.is_door = own_tag != null and std.ascii.eqlIgnoreCase(own_tag.?, "Door");
        pb.texture_top = own_texture;
        pb.map_color = own_map_color;
        pb.collide = own_collide;
        pb.collide_declared = own_collide_declared;
        pb.can_players_spawn_on = own_can_players;
        pb.can_players_spawn_declared = own_can_players_declared;
        pb.can_mobs_spawn_on = own_can_mobs;
        pb.can_mobs_spawn_declared = own_can_mobs_declared;
        pb.pass_through = own_pass_through;
        pb.pass_through_declared = own_pass_through_declared;
        pb.signable = own_signable;
        pb.lp_hardness_scale = own_lp;
        pb.lp_declared = own_lp_declared;
        pb.harvest_drops = own_drops;
        pb.destroy_drops = own_destroy;
        pb.fall_drops = own_fall;
    }

    // Block.assignIdsLinear -> assignLeftOverBlocks: every name the dump
    // carries keeps its pinned id (already set), and the leftovers - a modlet's
    // added blocks - take the first free id, terrain-shaped blocks scanning up
    // from 0 and everything else from 0xff (255), in block-list (document)
    // order. A modded client runs the same algorithm on the same document, so
    // both sides agree without a mapping row. The pool is the u16 id space;
    // exhaustion drops the block rather than stamping a wrong id.
    if (parsed.items.len > 0) {
        const used = try allocator.alloc(bool, max_block_ids);
        defer allocator.free(used);
        @memset(used, false);
        for (parsed.items) |pb| {
            if (pb.unassigned) continue;
            if (pb.id < used.len) used[pb.id] = true;
        }
        var pi: usize = 0;
        while (pi < parsed.items.len) {
            const pb = &parsed.items[pi];
            if (!pb.unassigned) {
                pi += 1;
                continue;
            }
            var cand: u32 = if (pb.terrain) 0 else leftover_id_start;
            while (cand < used.len and used[cand]) : (cand += 1) {}
            if (cand >= used.len) {
                util_log.err(
                    "zdtd: block id space exhausted; modlet block '{s}' dropped\n",
                    .{pb.name},
                );
                _ = parsed.orderedRemove(pi);
                continue;
            }
            pb.id = @intCast(cand);
            pb.unassigned = false;
            used[cand] = true;
            pi += 1;
        }
    }

    const defs = try arena.alloc(BlockDef, parsed.items.len);
    for (parsed.items, 0..) |pb, di| {
        defs[di] = .{
            .id = pb.id,
            .name = pb.name,
            .solid = isSolidName(pb.name),
            .class = if (pb.class) |c| try arena.dupe(u8, c) else "",
            .tags = if (pb.tags) |t| try arena.dupe(u8, t) else "",
            .trader_id = pb.trader_id,
            .trader_onoff = pb.trader_onoff,
            .is_door = pb.is_door,
            .signable = pb.signable,
            .lp_hardness_scale = pb.lp_hardness_scale,
            .heat_strength = pb.heat_strength,
            .has_fuel_module = pb.has_fuel_module,
            .has_material_input = pb.has_material_input,
            .input_materials = if (pb.input_materials) |im| try arena.dupe(u8, im) else "",
            .crafting_areas = if (pb.crafting_areas) |ca| try arena.dupe(u8, ca) else "",
            .radius_effect_buff = if (pb.radius_effect_buff) |rb| try arena.dupe(u8, rb) else "",
            .radius_effect_radius_sq = pb.radius_effect_radius_sq,
            .mesh = if (pb.mesh) |m| try arena.dupe(u8, m) else "",
            .material = if (pb.material) |m| try arena.dupe(u8, m) else "",
            .texture_top = pb.texture_top,
            .map_color = pb.map_color,
            .collide = pb.collide,
            .collide_declared = pb.collide_declared,
            .can_players_spawn_on = pb.can_players_spawn_on,
            .can_mobs_spawn_on = pb.can_mobs_spawn_on,
            .pass_through = pb.pass_through,
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
