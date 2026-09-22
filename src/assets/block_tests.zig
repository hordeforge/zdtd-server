//! Block table tests: ids, shapes, fixtures.
//!
//! Split out of assets/blocks.zig (same tests, moved verbatim).

const std = @import("std");
const blocks = @import("blocks.zig");
const BlockTable = blocks.BlockTable;
const maxdamage_dep = @import("maxdamage.zig");
const xml = @import("xml_util.zig");
const stock_paths = @import("../util/stock_paths.zig");
const io_fs = @import("../util/io_fs.zig");
const CollideMask = blocks.CollideMask;
const collide_arrows = blocks.collide_arrows;
const collide_bullets = blocks.collide_bullets;
const collide_default = blocks.collide_default;
const collide_melee = blocks.collide_melee;
const collide_movement = blocks.collide_movement;
const collide_rockets = blocks.collide_rockets;
const collide_sight = blocks.collide_sight;
const loadFromPath = blocks.loadFromPath;
const tryLoad = blocks.tryLoad;

test "block Tags parses for TriggerHasTags gates" {
    // The church-bell spawn gate needs the damaged block's tags
    // (`TriggerHasTags churchbell`): blocks.xml Tags feed the block def.
    // churchBellHanging extends churchBell with no own Tags, so inheritance
    // must carry the parent's churchbell tag.
    const path = stock_paths.configFile("blocks.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path, fixtureId, null);
    defer t.deinit();
    const bell = t.byName("churchBell") orelse return error.SkipZigTest;
    try std.testing.expect(std.mem.indexOf(u8, bell.tags, "churchbell") != null);
    const hanging = t.byName("churchBellHanging") orelse return error.SkipZigTest;
    try std.testing.expect(std.mem.indexOf(u8, hanging.tags, "churchbell") != null);
}

test "signable composite flag parses and follows Extends" {
    // blocks.xml declares a composite TE module as
    // `<property class="TEFeatureSignable">` (no name attr): 9 stock blocks
    // carry it, the player signs and the writable crates among them. The C2S
    // sign-text leg accepts only those positions, and the sign shapes inherit
    // it (playerSignWood1x3 extends playerSignWood1x1 and declares no
    // CompositeFeatures of its own).
    const src =
        \\<blocks>
        \\<block name="playerSignWood1x1">
        \\  <property name="Class" value="CompositeTileEntity"/>
        \\  <property class="CompositeFeatures">
        \\    <property class="TEFeatureSignable">
        \\      <property name="FontSize" value="110"/>
        \\    </property>
        \\    <property class="TEFeatureLockable"/>
        \\  </property>
        \\</block>
        \\<block name="playerSignWood1x3">
        \\  <property name="Extends" value="playerSignWood1x1"/>
        \\</block>
        \\<block name="cntWoodCrateWood01">
        \\  <property name="Class" value="CompositeTileEntity"/>
        \\  <property class="CompositeFeatures">
        \\    <property class="TEFeatureStorage">
        \\      <property name="LootList" value="playerWoodWritableStorage"/>
        \\    </property>
        \\  </property>
        \\</block>
        \\</blocks>
    ;
    const path = ".zdtd_test_blocks_signable.xml";
    try io_fs.writeFile(path, src);
    defer io_fs.deleteFile(path);

    var t = try loadFromPath(std.testing.allocator, path, fixtureId, null);
    defer t.deinit();
    try std.testing.expect(t.byName("playerSignWood1x1").?.signable);
    try std.testing.expect(t.byName("playerSignWood1x3").?.signable); // inherited
    try std.testing.expect(!t.byName("cntWoodCrateWood01").?.signable); // storage only
}

test "LPHardnessScale parses, defaults to 1 and follows Extends" {
    // Stock's Block property loader sets LPHardnessScale = 1 before reading the
    // property (IL_0553-0559), so an absent row means 1, not 0; the 7 stock rows
    // that do declare it are terrain (2) and cntGasPumpRandomLootHelper (0,
    // opted out of land-claim protection). The value is the baseline the claim
    // owner's durability modifier multiplies.
    const src =
        \\<blocks>
        \\<block name="terrStone">
        \\  <property name="LPHardnessScale" value="2"/>
        \\</block>
        \\<block name="cntGasPumpRandomLootHelper">
        \\  <property name="LPHardnessScale" value="0"/>
        \\</block>
        \\<block name="plainBlock">
        \\  <property name="Class" value="Storage"/>
        \\</block>
        \\<block name="terrStoneChild">
        \\  <property name="Extends" value="terrStone"/>
        \\</block>
        \\</blocks>
    ;
    const path = ".zdtd_test_blocks_lp.xml";
    try io_fs.writeFile(path, src);
    defer io_fs.deleteFile(path);

    var t = try loadFromPath(std.testing.allocator, path, fixtureId, null);
    defer t.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 2), t.byName("terrStone").?.lp_hardness_scale, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), t.byName("cntGasPumpRandomLootHelper").?.lp_hardness_scale, 0.001);
    // No property: the loader default, not zero.
    try std.testing.expectApproxEqAbs(@as(f32, 1), t.byName("plainBlock").?.lp_hardness_scale, 0.001);
    // Extends carries it.
    try std.testing.expectApproxEqAbs(@as(f32, 2), t.byName("terrStoneChild").?.lp_hardness_scale, 0.001);
}

test "modlet-added blocks get stock's leftover block ids" {
    // Block.assignIdsLinear -> assignLeftOverBlocks: names the AssignIds dump
    // carries keep their pinned id, and the leftovers take the first free id -
    // terrain-shaped blocks (Shape="Terrain", BlockShape::IsTerrain) scanning
    // from 0, everything else from 0xff (255) - in document order. A modded
    // client runs the same algorithm, so both sides agree.
    const src =
        \\<blocks>
        \\<block name="air"/>
        \\<block name="terrStone">
        \\  <property name="Shape" value="Terrain"/>
        \\</block>
        \\<block name="modTerrainBlock">
        \\  <property name="Shape" value="Terrain"/>
        \\</block>
        \\<block name="modSolidBlock">
        \\  <property name="Shape" value="ModelEntity"/>
        \\</block>
        \\<block name="modSolidBlock2">
        \\  <property name="Class" value="Storage"/>
        \\</block>
        \\</blocks>
    ;
    const path = ".zdtd_test_blocks_g9.xml";
    try io_fs.writeFile(path, src);
    defer io_fs.deleteFile(path);

    var t = try loadFromPath(std.testing.allocator, path, g9FixtureId, null);
    defer t.deinit();
    // Pinned names keep their dump id.
    try std.testing.expectEqual(@as(u16, 0), t.byName("air").?.id);
    try std.testing.expectEqual(@as(u16, 200), t.byName("terrStone").?.id);
    // The modlet's terrain block takes the first free id from 0 (0 and 200 are
    // taken here).
    try std.testing.expectEqual(@as(u16, 1), t.byName("modTerrainBlock").?.id);
    // The others scan from 0xff, in document order.
    try std.testing.expectEqual(@as(u16, 255), t.byName("modSolidBlock").?.id);
    try std.testing.expectEqual(@as(u16, 256), t.byName("modSolidBlock2").?.id);
    // Reverse lookup agrees.
    try std.testing.expectEqualStrings("modSolidBlock", t.byId(255).?.name);
    try std.testing.expectEqualStrings("modTerrainBlock", t.byId(1).?.name);
}

fn g9FixtureId(_: ?*anyopaque, name: []const u8) ?u16 {
    const map = .{
        .{ "air", 0 },
        .{ "terrStone", 200 },
    };
    inline for (map) |e| {
        if (std.mem.eql(u8, e[0], name)) return e[1];
    }
    return null;
}

test "the stock leftover block ids match Block.assignLeftOverBlocks" {
    // `assignLeftOverBlocks` (IL=7528) walks `fixedBlockIds` first and assigns
    // everything still unassigned - a modlet's blocks *and* the stock rows the
    // dump omits - from the free pool, terrain from 0 and the rest from 255, in
    // `nameToBlock` insertion (document) order. The 11 stock leftovers below are
    // therefore stock's own assignment, not zdtd inventing ids for abstract
    // bases: they are the `*Shapes` shape masters plus cntChickenCoop and
    // oldWoodDoorNoHonk, which is why a modded client and this server agree on
    // where a mod's first block lands.
    const game = stock_paths.dedicated_server;
    const cpath = game ++ "/Data/Config/blocks.xml";
    if (!io_fs.fileExists(cpath)) return error.SkipZigTest;
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    var mt = (maxdamage_dep.tryLoad(gpa, game, null) catch null) orelse return error.SkipZigTest;
    defer mt.deinit();
    mt.tryMergeBundledAssignIds(gpa);
    const Ctx = struct {
        fn lookup(ctx: ?*anyopaque, name: []const u8) ?u16 {
            const m: *maxdamage_dep.Table = @ptrCast(@alignCast(ctx.?));
            return m.idByName(name);
        }
    };
    var t = try loadFromPath(gpa, cpath, Ctx.lookup, @ptrCast(&mt));
    defer t.deinit();
    try std.testing.expect(t.defs.len > 4000);
    // Every name the dump carries keeps its pinned id.
    var pinned_n: usize = 0;
    for (t.defs) |d| {
        const pinned = mt.idByName(d.name) orelse continue;
        try std.testing.expectEqual(pinned, d.id);
        pinned_n += 1;
    }
    try std.testing.expect(pinned_n > 6000);
    // The dump's leftovers, in document order from 0xff.
    const expect_leftovers = [_]struct { []const u8, u16 }{
        .{ "woodShapes", 255 },
        .{ "brickShapes", 259 },
        .{ "cobblestoneShapes", 260 },
        .{ "concreteShapes", 261 },
        .{ "steelShapes", 262 },
        .{ "awningShapes", 263 },
        .{ "corrugatedMetalShapes", 264 },
        .{ "frameShapes", 265 },
        .{ "bulletproofShapes", 266 },
        .{ "cntChickenCoop", 267 },
        .{ "oldWoodDoorNoHonk", 268 },
    };
    for (expect_leftovers) |e| {
        const d = t.byName(e[0]) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(e[1], d.id);
        try std.testing.expect(mt.idByName(e[0]) == null);
    }
    var leftover: usize = 0;
    for (t.defs) |d| {
        if (mt.idByName(d.name) == null) leftover += 1;
    }
    try std.testing.expectEqual(expect_leftovers.len, leftover);
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
        \\  <property name="BlockTag" value="Door"/>
        \\</block>
        \\<block name="woodHatchChild">
        \\  <property name="Extends" value="woodHatchBase"/>
        \\</block>
        \\<block name="woodHatchBase">
        \\  <property name="BlockTag" value="Door"/>
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
        \\    <property name="InputMaterials" value="iron,brass,lead,glass,stone,clay"/>
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
    // Door detection (stock `BlockTag="Door"`, resolved through Extends):
    // a tagged door stays a door, an untagged crate is not, and the tag
    // reaches the nameless gates and hatches the old substring missed.
    try std.testing.expect(t.byName("doorWoodLargeGate").?.is_door);
    try std.testing.expect(t.byName("woodHatchChild").?.is_door); // inherited tag
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
    try std.testing.expect(!t.hasMaterialInput(fire.id));
    try std.testing.expect(!t.hasMaterialInput(bench.id));
    // CraftingAreaRecipes gate: workbench allows player + workbench recipes
    // only; forge only forge; campfire (no list) only its own name.
    try std.testing.expect(t.allowsCraftArea(bench.id, "workbench"));
    try std.testing.expect(t.allowsCraftArea(bench.id, "player"));
    try std.testing.expect(!t.allowsCraftArea(bench.id, "forge"));
    const forge = t.byName("forge").?;
    try std.testing.expect(t.hasFuelModule(forge.id));
    try std.testing.expect(t.hasMaterialInput(forge.id));
    try std.testing.expectEqualStrings("iron,brass,lead,glass,stone,clay", t.inputMaterials(forge.id));
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
        .{ "oreNoExtend", 208 },
        .{ "playerSignWood1x1", 209 },
        .{ "playerSignWood1x3", 210 },
        .{ "plainBlock", 211 },
        .{ "cntGasPumpRandomLootHelper", 213 },
        .{ "terrStoneChild", 212 },
        .{ "collideSix", 214 },
        .{ "collideBullets", 215 },
        .{ "collideMixed", 216 },
        .{ "collideAbsent", 217 },
        .{ "collideBase", 218 },
        .{ "collideChild", 219 },
        .{ "glassBusinessSheet", 220 },
        .{ "glassBusinessCTRSheet", 221 },
        .{ "opaqueBusinessGlass", 222 },
        .{ "collideNoValue", 223 },
        .{ "treeMaster", 224 },
        .{ "woodMaster", 227 },
        .{ "woodDoor", 228 },
        .{ "woodHatchBase", 229 },
        .{ "woodHatchChild", 230 },
        .{ "treeOakSml01", 225 },
        .{ "terrStone", 226 },
    };
    inline for (map) |e| {
        if (std.mem.eql(u8, name, e[0])) return e[1];
    }
    return null;
}

test "Extends resolves through a multi-level chain and stops on a cycle" {
    // Stock chains are deeper than one hop (cntVendingMachineTrader extends
    // cntVendingMachine extends ...), so a grandchild must inherit from its
    // grandparent. The cycle guard must key on the chain step: keying it on
    // the block the walk started from truncated every chain after one level.
    // Names come from fixtureId's table: an unmapped name resolves to null and
    // is dropped fail-closed, so the fixture reuses the vending chain blocks.
    //
    // Child before parent on purpose. Resolution writes each block's result
    // back into the parsed list, so when a parent precedes its child the child
    // only ever needs one hop and a broken cycle guard stays invisible. Listing
    // the grandchild first forces two hops in a single walk, which is exactly
    // what a guard keyed on the starting block cuts short.
    const src =
        \\<blocks>
        \\<block name="cntVendingMachine2">
        \\  <property name="Extends" value="cntVendingMachine2Broken"/>
        \\</block>
        \\<block name="cntVendingMachine2Broken">
        \\  <property name="Extends" value="cntVendingMachine"/>
        \\</block>
        \\<block name="cntVendingMachine">
        \\  <property name="Class" value="VendingMachine"/>
        \\  <property name="TraderID" value="7"/>
        \\</block>
        \\<block name="cntWoodCrateWood01">
        \\  <property name="Extends" value="doorWoodLargeGate"/>
        \\</block>
        \\<block name="doorWoodLargeGate">
        \\  <property name="Extends" value="cntWoodCrateWood01"/>
        \\</block>
        \\<block name="campfire">
        \\  <property name="Extends" value="campfire"/>
        \\</block>
        \\</blocks>
    ;
    const path = ".zdtd_test_blocks_extends_chain.xml";
    try io_fs.writeFile(path, src);
    defer io_fs.deleteFile(path);

    var t = try loadFromPath(std.testing.allocator, path, fixtureId, null);
    defer t.deinit();

    // One hop: the direct child inherits Class and TraderID.
    const mid = t.byName("cntVendingMachine2Broken").?;
    try std.testing.expect(t.isVending(mid.id));
    try std.testing.expectEqual(@as(i32, 7), t.traderId(mid.id));
    // Two hops: the grandchild must reach the base through the middle block.
    const leaf = t.byName("cntVendingMachine2").?;
    try std.testing.expect(t.isVending(leaf.id));
    try std.testing.expectEqual(@as(i32, 7), t.traderId(leaf.id));
    // A two-block cycle and a self-extend both terminate (reaching here proves
    // it) and inherit nothing.
    try std.testing.expect(!t.isVending(t.byName("cntWoodCrateWood01").?.id));
    try std.testing.expect(!t.isVending(t.byName("campfire").?.id));
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
        \\<block name="oreNoExtend">
        \\  <property name="Extends" value="cntOreBase"/>
        \\  <dropextendsoff />
        \\  <drop event="Harvest" name="resourceWood" count="7" tag="lumberjackHarvest"/>
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

    // <dropextendsoff />: the child keeps its own row only (stock skips
    // LoadExtendedItemDrops when the element is present; 226 stock rows).
    const no_ext = t.byName("oreNoExtend").?;
    const nd = t.harvestDrops(no_ext.id);
    try std.testing.expectEqual(@as(usize, 1), nd.len);
    try std.testing.expectEqualStrings("resourceWood", nd[0].item_name);
    try std.testing.expectEqual(@as(u32, 7), nd[0].count_min);

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

test "Collide parses the blocking bits and follows Extends" {
    // BlocksFromXml IL_0404-04F0: when the property is present the mask starts
    // at 0 and ORs one bit per verb found by a case-insensitive SUBSTRING test
    // (Extensions::ContainsCaseInsensitive, Extensions.il IL=9), so "bullets"
    // sets the bullet bit and "Movement,MELEE" sets movement + melee. An absent
    // property keeps the stock collidable default 255 (IL_04D5-04EB), and the
    // child's Extends param1 hides the parent's mask.
    const src =
        \\<blocks>
        \\<block name="collideSix">
        \\  <property name="Collide" value="sight,movement,bullet,rocket,arrow,melee"/>
        \\</block>
        \\<block name="collideBullets">
        \\  <property name="Collide" value="bullets"/>
        \\</block>
        \\<block name="collideMixed">
        \\  <property name="Collide" value="Movement,MELEE"/>
        \\</block>
        \\<block name="collideAbsent">
        \\  <property name="Class" value="Storage"/>
        \\</block>
        \\<block name="collideNoValue">
        \\  <property name="Collide"/>
        \\</block>
        \\<block name="collideBase">
        \\  <property name="Collide" value="movement,melee"/>
        \\</block>
        \\<block name="collideChild">
        \\  <property name="Extends" value="collideBase"/>
        \\</block>
        \\<block name="glassBusinessSheet">
        \\  <property name="Collide" value="movement,melee,bullet,arrow,rocket"/>
        \\</block>
        \\<block name="glassBusinessCTRSheet">
        \\  <property name="Extends" value="glassBusinessSheet"/>
        \\</block>
        \\<block name="opaqueBusinessGlass">
        \\  <property name="Extends" value="glassBusinessCTRSheet" param1="Mesh,Collide"/>
        \\  <property name="Texture" value="532"/>
        \\</block>
        \\</blocks>
    ;
    const path = ".zdtd_test_blocks_collide.xml";
    try io_fs.writeFile(path, src);
    defer io_fs.deleteFile(path);

    var t = try loadFromPath(std.testing.allocator, path, fixtureId, null);
    defer t.deinit();

    // All six verbs: 1 | 2 | 4 | 8 | 32 | 16 = 63.
    const six = t.byName("collideSix").?;
    try std.testing.expectEqual(
        collide_sight | collide_movement | collide_bullets |
            collide_rockets | collide_arrows | collide_melee,
        six.collide,
    );
    try std.testing.expectEqual(@as(CollideMask, 63), t.collideMask(six.id));
    // Substring, not token-exact: "bullets" contains "bullet" (4) and nothing
    // else matches.
    try std.testing.expectEqual(collide_bullets, t.byName("collideBullets").?.collide);
    // Case-insensitive: "Movement,MELEE" = 2 | 16 = 18.
    try std.testing.expectEqual(@as(CollideMask, 18), t.byName("collideMixed").?.collide);
    // Absent property: the stock collidable default, not 0.
    try std.testing.expectEqual(collide_default, t.byName("collideAbsent").?.collide);
    try std.testing.expectEqual(@as(CollideMask, 255), t.collideMask(t.byName("collideAbsent").?.id));
    // Present but valueless: 0 (the property is in the dictionary, no verb
    // matches), not the absent default.
    try std.testing.expectEqual(@as(CollideMask, 0), t.byName("collideNoValue").?.collide);
    // Extends carries the mask when the child declares none.
    try std.testing.expectEqual(@as(CollideMask, 18), t.byName("collideChild").?.collide);
    // param1="Collide" on the child: the mask is NOT inherited, the child keeps
    // the absent default, while the middle block does inherit it (stock's
    // opaqueBusinessGlass / glassBusinessCTRSheet / glassBusinessSheet chain).
    try std.testing.expectEqual(@as(CollideMask, 62), t.byName("glassBusinessSheet").?.collide);
    try std.testing.expectEqual(@as(CollideMask, 62), t.byName("glassBusinessCTRSheet").?.collide);
    try std.testing.expectEqual(@as(CollideMask, 255), t.byName("opaqueBusinessGlass").?.collide);
}

test "the stock Collide rows match BlocksFromXml" {
    // Stock carries 418 `Collide` rows. The param1 case is the one that matters:
    // opaqueBusinessGlass extends glassBusinessCTRSheet with
    // param1="Mesh,Collide", so it must NOT inherit the parent's mask and reads
    // the absent default 255; glassBusinessCTRSheet itself inherits
    // "movement,melee,bullet,arrow,rocket" = 2+16+4+32+8 = 62 from
    // glassBusinessSheet.
    const game = stock_paths.dedicated_server;
    const cpath = game ++ "/Data/Config/blocks.xml";
    if (!io_fs.fileExists(cpath)) return error.SkipZigTest;
    const Ctx = struct {
        // Ids are irrelevant here (lookups are by name), so every block takes
        // the leftover path instead of pinning the AssignIds dump.
        fn lookup(_: ?*anyopaque, _: []const u8) ?u16 {
            return null;
        }
    };
    var t = try loadFromPath(std.testing.allocator, cpath, Ctx.lookup, null);
    defer t.deinit();
    try std.testing.expectEqual(@as(CollideMask, 62), t.byName("glassBusinessSheet").?.collide);
    try std.testing.expectEqual(@as(CollideMask, 62), t.byName("glassBusinessCTRSheet").?.collide);
    try std.testing.expectEqual(@as(CollideMask, 255), t.byName("opaqueBusinessGlass").?.collide);
}

test "material collidable=false clears the undeclared Collide default" {
    // Stock `BlocksFromXml` IL_04D5-04EB: a block with no declared `Collide`
    // takes `blockMaterial.IsCollidable ? 255 : 0`. The 4 stock non-collidable
    // materials (Mair/Mwater/Mtallgrass/Mweb) clear the default; declared
    // masks (including explicit 0) are untouched by the fixup, which runs at
    // Game init - here it is driven directly with a synthetic material map.
    const game = stock_paths.dedicated_server;
    const cpath = game ++ "/Data/Config/blocks.xml";
    if (!io_fs.fileExists(cpath)) return error.SkipZigTest;
    const Ctx = struct {
        fn lookup(_: ?*anyopaque, _: []const u8) ?u16 {
            return null;
        }
    };
    var t = try loadFromPath(std.testing.allocator, cpath, Ctx.lookup, null);
    defer t.deinit();
    var map: std.StringHashMapUnmanaged(bool) = .{};
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, "Mair", false);
    try map.put(std.testing.allocator, "Mwater", false);
    try map.put(std.testing.allocator, "Mstone", true);
    // A block on a non-collidable material with no declared Collide clears.
    var air_found = false;
    for (t.defs) |d| {
        if (std.mem.eql(u8, d.material, "Mair") and !d.collide_declared) {
            air_found = true;
            break;
        }
    }
    try std.testing.expect(air_found);
    t.applyMaterialCollideDefaults(map);
    for (t.defs) |d| {
        if (std.mem.eql(u8, d.material, "Mair") and !d.collide_declared) {
            try std.testing.expectEqual(@as(CollideMask, 0), d.collide);
        }
        if (std.mem.eql(u8, d.material, "Mstone") and !d.collide_declared) {
            try std.testing.expectEqual(collide_default, d.collide);
        }
    }
    // Declared masks survive the fixup, including an explicit 0.
    try std.testing.expectEqual(@as(CollideMask, 62), t.byName("glassBusinessSheet").?.collide);
}

test "CanPlayersSpawnOn and CanMobsSpawnOn parse and inherit through Extends" {
    // Stock Block.il IL_01BF-01F4 sets CanMobsSpawnOn = false and
    // CanPlayersSpawnOn = true before ParseBool, so the defaults are asymmetric;
    // 24 stock rows declare players=false (treeMaster, the vehicle masters) and
    // 24 mobs=true (terrain, farm plots, a few trees).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/blocks_spawn.xml", .{dir});
    try io_fs.writeFile(path,
        \\<blocks>
        \\<block name="treeMaster">
        \\  <property name="CanPlayersSpawnOn" value="false" />
        \\</block>
        \\<block name="treeOakSml01">
        \\  <property name="Extends" value="treeMaster" />
        \\</block>
        \\<block name="terrStone">
        \\  <property name="CanMobsSpawnOn" value="true" />
        \\</block>
        \\<block name="terrStoneChild">
        \\  <property name="Extends" value="terrStone" />
        \\</block>
        \\<block name="plainBlock" />
        \\</blocks>
    );
    var t = try loadFromPath(std.testing.allocator, path, fixtureId, null);
    defer t.deinit();
    try std.testing.expect(!t.canPlayersSpawnOn(fixtureId(null, "treeMaster").?));
    try std.testing.expect(!t.canPlayersSpawnOn(fixtureId(null, "treeOakSml01").?));
    try std.testing.expect(t.canPlayersSpawnOn(fixtureId(null, "plainBlock").?));
    try std.testing.expect(t.canMobsSpawnOn(fixtureId(null, "terrStone").?));
    try std.testing.expect(t.canMobsSpawnOn(fixtureId(null, "terrStoneChild").?));
    // Absent keeps stock's false default for mobs.
    try std.testing.expect(!t.canMobsSpawnOn(fixtureId(null, "plainBlock").?));
}

test "PassThroughDamage parses and inherits through Extends" {
    // Stock `Block.OnBlockDamaged` IL_0384-03AE recurses the leftover damage
    // into the replacement block when the destroyed block declares
    // PassThroughDamage (102 stock rows, all true: the door/gate/hatch chains
    // and the wood/steel/vehicle masters, e.g. woodMaster and
    // cntCar03SedanDamage0Master).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/blocks_pt.xml", .{dir});
    try io_fs.writeFile(path,
        \\<blocks>
        \\<block name="woodMaster">
        \\  <property name="PassThroughDamage" value="true" />
        \\</block>
        \\<block name="woodDoor">
        \\  <property name="Extends" value="woodMaster" />
        \\</block>
        \\<block name="treeMaster">
        \\  <property name="PassThroughDamage" value="true" />
        \\</block>
        \\<block name="treeOakSml01">
        \\  <property name="Extends" value="treeMaster" param1="PassThroughDamage" />
        \\</block>
        \\<block name="plainBlock" />
        \\</blocks>
    );
    var t = try loadFromPath(std.testing.allocator, path, fixtureId, null);
    defer t.deinit();
    try std.testing.expect(t.passThrough(fixtureId(null, "woodMaster").?));
    try std.testing.expect(t.passThrough(fixtureId(null, "woodDoor").?));
    // param1 excludes the property: the child keeps the false default.
    try std.testing.expect(!t.passThrough(fixtureId(null, "treeOakSml01").?));
    try std.testing.expect(!t.passThrough(fixtureId(null, "plainBlock").?));
    // Unknown ids fail closed (no pass-through).
    try std.testing.expect(!t.passThrough(60000));
}
