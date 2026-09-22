//! Item table tests: Extends inheritance, stock loads, passive rows,
//! trader fields, gamestage rolls.
//!
//! Split out of assets/items.zig (same tests, moved verbatim).

const std = @import("std");
const items = @import("items.zig");
const ItemTable = items.ItemTable;
const ItemDef = items.ItemDef;
const builtinStockName = items.builtinStockName;
const builtin_defs = items.builtin_defs;
const stock_first_item_type = items.stock_first_item_type;
const items_start_here = items.items_start_here;
const max_items = items.max_items;
const loadFromPath = items.loadFromPath;
const GsStat = items.GsStat;
const RolledGsStat = items.RolledGsStat;
const rollGsStats = items.rollGsStats;
const buffs = @import("buffs.zig");
const game_random = @import("../util/game_random.zig");
const stock_paths = @import("../util/stock_paths.zig");
const io_fs = @import("../util/io_fs.zig");

test "items inherit Action0 damage and Tags through Extends" {
    // Range / DamageBlock / Tags used to read the own body only: 1449 items
    // inherit MaxDamage-style props through Extends and 286 declare no Tags of
    // their own (schematicNoQualityMaster children), which made the loot mod
    // roll and the attachment scrub fail closed on them.
    const path = stock_paths.configFile("items.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    // meleeHandZombieFeral extends meleeHandZombie01 (Range 1.6).
    const feral = t.byName("meleeHandZombieFeral").?;
    const plain = t.byName("meleeHandZombie01").?;
    try std.testing.expect(plain.melee_range > 0);
    try std.testing.expectApproxEqAbs(plain.melee_range, feral.melee_range, 1e-4);
    // A schematic master child inherits the master's Tags.
    const schematic = t.byName("ammoArrowStoneSchematic");
    if (schematic) |d| try std.testing.expect(d.tags.len > 0);
    try std.testing.expect(t.byName("schematicNoQualityMaster").?.tags.len > 0);
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

test "sandbox MaxStackSize scales stackable items but never quality ones" {
    // Stock ItemClass.get_MaxCount (IL=10): with MaxStackSizeModifier != 1 the
    // Stacknumber is scaled and clamped at 30000, but only for items that
    // stack and carry no quality (a weapon's stack of 1 must not follow the
    // option). The option is 163 StackSizeMultiplier, set from the decoded
    // server code.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items.xml", .{dir});
    try io_fs.writeFile(path,
        \\<items>
        \\  <item name="resourceWood">
        \\    <property name="Stacknumber" value="5" />
        \\  </item>
        \\  <item name="resourceScrapIron">
        \\    <property name="Stacknumber" value="1000" />
        \\  </item>
        \\  <item name="gunHandgunT1Pistol">
        \\    <property name="Stacknumber" value="1" />
        \\    <effect_group tiered="true" name="quality">
        \\      <passive_effect name="DamageModifier" operation="perc_add" value=".1" tier="1,6" />
        \\    </effect_group>
        \\  </item>
        \\  <item name="thrownRock">
        \\    <property name="Stacknumber" value="1" />
        \\  </item>
        \\</items>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const wood = t.byName("resourceWood").?.id;
    const iron = t.byName("resourceScrapIron").?.id;
    const pistol = t.byName("gunHandgunT1Pistol").?.id;
    const rock = t.byName("thrownRock").?.id;
    try std.testing.expect(t.byName("gunHandgunT1Pistol").?.has_quality);
    try std.testing.expect(!t.byName("resourceWood").?.has_quality);

    // Default: every raw Stacknumber stands.
    try std.testing.expectEqual(@as(u16, 5), t.stackFor(wood));
    try std.testing.expectEqual(@as(u16, 1000), t.stackFor(iron));

    // x2: stackables double, quality and non-stacking items are untouched.
    t.setStackSizeModifier(2.0);
    try std.testing.expectEqual(@as(u16, 10), t.stackFor(wood));
    try std.testing.expectEqual(@as(u16, 2000), t.stackFor(iron));
    try std.testing.expectEqual(@as(u16, 1), t.stackFor(pistol));
    try std.testing.expectEqual(@as(u16, 1), t.stackFor(rock));

    // x1.5 on a 5-count stack is a .NET midpoint: Math.Round(7.5) = 8.
    t.setStackSizeModifier(1.5);
    try std.testing.expectEqual(@as(u16, 8), t.stackFor(wood));
    // The clamp is stock's 30000, applied only on the scaled path.
    t.setStackSizeModifier(100.0);
    try std.testing.expectEqual(@as(u16, 30000), t.stackFor(iron));
    // A modifier the decoded code does not carry is not one: 0 falls back to 1.
    t.setStackSizeModifier(0);
    try std.testing.expectEqual(@as(u16, 1000), t.stackFor(iron));
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
    try std.testing.expect(t.byName("casinoCoin") == null);
    try std.testing.expectEqual(@as(u16, 0), t.ecsIdByName("resourceWood"));
    try std.testing.expect(!t.isEat(2));
    try std.testing.expect(!t.isEat(4));
    try std.testing.expectEqual(@as(i32, 0), t.stockTypeFor(6));

    const unparsed = [_]ItemDef{
        .{ .id = 102, .name = "foodUnparsed" },
        .{ .id = 103, .name = "drinkUnparsed" },
    };
    const xml_names: ItemTable = .{ .defs = &unparsed, .source = .xml };
    try std.testing.expect(!xml_names.isEat(102));
    try std.testing.expect(!xml_names.isEat(103));
    try std.testing.expectEqual(@as(f32, 0), xml_names.foodAmountFor(102));
    try std.testing.expectEqual(@as(f32, 0), xml_names.waterAmountFor(103));

    const builtin = ItemTable.builtin();
    try std.testing.expectEqual(@as(i32, items_start_here + 7), builtin.stockTypeFor(7));
    try std.testing.expectEqual(@as(f32, 15), builtin.foodAmountFor(2));
    try std.testing.expectEqual(@as(u16, 6), builtin.ecsIdByName("casinoCoin"));
    try std.testing.expect(builtin.isEat(2));
}

test "magazine AddProgressionLevel parses onto the eat item" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items.xml", .{dir});
    try io_fs.writeFile(path,
        \\<items>
        \\  <item name="harvestingToolsSkillMagazine">
        \\    <property class="Action0">
        \\      <property name="Class" value="Eat"/>
        \\    </property>
        \\    <effect_group tiered="false">
        \\      <triggered_effect trigger="onSelfPrimaryActionEnd" action="AddProgressionLevel" progression_name="craftingHarvestingTools" level="1"/>
        \\      <triggered_effect trigger="onSelfPrimaryActionEnd" action="GiveExp" exp="50"/>
        \\    </effect_group>
        \\  </item>
        \\  <item name="foodCanBeef">
        \\    <property class="Action0">
        \\      <property name="Class" value="Eat"/>
        \\    </property>
        \\    <effect_group>
        \\      <triggered_effect trigger="onSelfPrimaryActionEnd" action="ModifyCVar" cvar="$foodAmountAdd" operation="add" value="15"/>
        \\    </effect_group>
        \\  </item>
        \\</items>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const mag = t.byName("harvestingToolsSkillMagazine").?;
    try std.testing.expect(mag.is_eat);
    try std.testing.expect(t.isEat(mag.id));
    try std.testing.expectEqualStrings("craftingHarvestingTools", mag.progression_name);
    try std.testing.expectEqual(@as(u8, 1), mag.progression_add);
    try std.testing.expectEqual(@as(u16, 50), mag.eat_exp);
    const food = t.byName("foodCanBeef").?;
    try std.testing.expectEqual(@as(u8, 0), food.progression_add);
    try std.testing.expectEqualStrings("", food.progression_name);
    try std.testing.expectEqual(@as(u16, 0), food.eat_exp);
    try std.testing.expectEqual(@as(usize, 0), food.progression_set_max.len);
}

test "almanac SetProgressionLevel level=-1 parses as set-to-max" {
    // RE minevents.md IL=104: level=-1 sets ProgressionClass.MaxLevel.
    // Stock ships only -1 (426 rows); non -1 is omitted.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items.xml", .{dir});
    try io_fs.writeFile(path,
        \\<items>
        \\  <item name="bookFiremansAlmanacHeat">
        \\    <property class="Action0">
        \\      <property name="Class" value="Eat"/>
        \\    </property>
        \\    <effect_group tiered="false">
        \\      <triggered_effect trigger="onSelfPrimaryActionEnd" action="SetProgressionLevel" progression_name="perkFiremansAlmanacHeat" level="-1"/>
        \\      <triggered_effect trigger="onSelfPrimaryActionEnd" action="SetProgressionLevel" progression_name="perkFiremansAlmanacComplete" level="-1"/>
        \\      <triggered_effect trigger="onSelfPrimaryActionEnd" action="SetProgressionLevel" progression_name="perkIgnoredAbsolute" level="3"/>
        \\      <triggered_effect trigger="onSelfPrimaryActionEnd" action="GiveExp" exp="50"/>
        \\    </effect_group>
        \\  </item>
        \\</items>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const book = t.byName("bookFiremansAlmanacHeat").?;
    try std.testing.expect(book.is_eat);
    try std.testing.expect(t.isEat(book.id));
    try std.testing.expectEqual(@as(u8, 0), book.progression_add);
    try std.testing.expectEqualStrings("", book.progression_name);
    try std.testing.expectEqual(@as(usize, 2), book.progression_set_max.len);
    try std.testing.expectEqualStrings("perkFiremansAlmanacHeat", book.progression_set_max[0]);
    try std.testing.expectEqualStrings("perkFiremansAlmanacComplete", book.progression_set_max[1]);
    try std.testing.expectEqual(@as(u16, 50), book.eat_exp);
}

test "Tags + ModSlots parse and modSlotsFor gates the mod budget" {
    // RE items.md: the item's Tags surface (mod-attachment gates) + the
    // ModSlots quality curve (CalcModSlotCount IL=29 = GetValue(ModSlots,
    // item, Quality-1)); an item without ModSlots allows no mods (fail
    // closed in the attachment scrub).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items.xml", .{dir});
    try io_fs.writeFile(path, "<items>\n" ++
        "  <item name=\"testGun\">\n" ++
        "    <property name=\"Tags\" value=\"T0,weapon,gun,barrelAttachments\"/>\n" ++
        "    <effect_group name=\"testGun\">\n" ++
        "      <passive_effect name=\"ModSlots\" operation=\"base_set\" value=\"1,1,1,2,2,3\" tier=\"1,2,3,4,5,6\"/>\n" ++
        "    </effect_group>\n" ++
        "  </item>\n" ++
        "  <item name=\"resourceWood\">\n" ++
        "    <property name=\"Stacknumber\" value=\"100\"/>\n" ++
        "  </item>\n" ++
        "</items>\n");
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const gun = t.byName("testGun") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("T0,weapon,gun,barrelAttachments", gun.tags);
    try std.testing.expectEqual(@as(u8, 6), gun.mod_slots_n);
    // Quality 1..3 → budget 1; quality 4..5 → 2; quality 6 → 3 (stock tier
    // curve). Quality 0 (unset) treats as tier 1.
    try std.testing.expectEqual(@as(u8, 1), t.modSlotsFor(gun.id, 1));
    try std.testing.expectEqual(@as(u8, 2), t.modSlotsFor(gun.id, 4));
    try std.testing.expectEqual(@as(u8, 3), t.modSlotsFor(gun.id, 6));
    try std.testing.expectEqual(@as(u8, 1), t.modSlotsFor(gun.id, 0));
    const wood = t.byName("resourceWood") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u8, 0), t.modSlotsFor(wood.id, 3)); // no ModSlots → 0
    try std.testing.expectEqual(@as(u8, 0), t.modSlotsFor(9999, 3)); // unknown item → 0
}

test "DistractionTags + Distraction* effects parse (stock decoy shape)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
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

test "HarvestCount held-tool rows parse and fold over base 1" {
    // RE GameUtils.HarvestOnAttack IL=623: count = trunc(rolled *
    // GetValue(141, tool, 1, holder, null, dropTag)). Ops: base_add ->
    // base+value, base_set -> base=value, perc_add -> base*(1+value);
    // a curve evaluates at the tool quality. Tag-gated by the drop row.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items.xml", .{dir});
    try io_fs.writeFile(path,
        \\<items>
        \\  <item name="meleeToolPickT3Auger">
        \\    <effect_group name="Auger">
        \\      <passive_effect name="HarvestCount" operation="perc_add" value=".2"/>
        \\    </effect_group>
        \\  </item>
        \\  <item name="meleeWpnClubT0WoodenClub">
        \\    <effect_group name="Club">
        \\      <passive_effect name="HarvestCount" operation="base_add" value="-.75" tags="allHarvest"/>
        \\      <passive_effect name="HarvestCount" operation="base_add" value="-.75" tags="allToolsHarvest"/>
        \\      <passive_effect name="HarvestCount" operation="base_add" value="-.75" tags="oreWoodHarvest"/>
        \\    </effect_group>
        \\  </item>
        \\  <item name="meleeToolAxeT2SteelAxe">
        \\    <effect_group name="Axe">
        \\      <passive_effect name="HarvestCount" operation="base_set" value=".7" tags="butcherHarvest"/>
        \\    </effect_group>
        \\  </item>
        \\  <item name="armorMinerHelmet">
        \\    <effect_group name="Helmet">
        \\      <passive_effect name="HarvestCount" operation="perc_add" value=".05,.1,.15,.20,.25,.30" tier="1,2,3,4,5,6" tags="oreWoodHarvest"/>
        \\    </effect_group>
        \\  </item>
        \\  <item name="meleeToolPickT1IronPickaxe">
        \\    <effect_group name="Pick">
        \\      <passive_effect name="HarvestCount" operation="perc_add" value=".1,.5" tier="2,6" tags="oreWoodHarvest"/>
        \\    </effect_group>
        \\  </item>
        \\</items>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();

    // Untagged perc_add applies to every drop: 1 + .2 = 1.2.
    const auger = t.byName("meleeToolPickT3Auger").?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), t.harvestMultiplier(auger.id, 1, "oreWoodHarvest"), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), t.harvestMultiplier(auger.id, 1, ""), 1e-4);
    // Club: base_add -.75 over base 1 -> 0.25 for a matching tag; no match
    // (butcherHarvest) -> 1.0 (no row applies).
    const club = t.byName("meleeWpnClubT0WoodenClub").?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), t.harvestMultiplier(club.id, 1, "oreWoodHarvest"), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), t.harvestMultiplier(club.id, 1, "allHarvest,lumberjackHarvest"), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), t.harvestMultiplier(club.id, 1, "butcherHarvest"), 1e-4);
    // Axe: base_set .7 replaces the base for butcherHarvest only.
    const axe = t.byName("meleeToolAxeT2SteelAxe").?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), t.harvestMultiplier(axe.id, 1, "butcherHarvest"), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), t.harvestMultiplier(axe.id, 1, "oreWoodHarvest"), 1e-4);
    // Curve: quality 3 -> 1 + .15 = 1.15 (piecewise at quality 1..6).
    const helmet = t.byName("armorMinerHelmet").?;
    try std.testing.expectEqual(@as(u8, 6), helmet.harvest_rows[0].curve_levels_n);
    try std.testing.expectApproxEqAbs(@as(f32, 1.05), t.harvestMultiplier(helmet.id, 1, "oreWoodHarvest"), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.15), t.harvestMultiplier(helmet.id, 3, "oreWoodHarvest"), 1e-4);
    // tier="2,6": Q1 is out of range (stock ModValue) so the row applies
    // nothing; Q2 starts at .1 and Q6 ends at .5.
    const pick = t.byName("meleeToolPickT1IronPickaxe").?;
    try std.testing.expectEqual(@as(u8, 2), pick.harvest_rows[0].curve_levels_n);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), t.harvestMultiplier(pick.id, 1, "oreWoodHarvest"), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), t.harvestMultiplier(pick.id, 2, "oreWoodHarvest"), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), t.harvestMultiplier(pick.id, 6, "oreWoodHarvest"), 1e-4);
    // Unknown item / no rows -> 1.0.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), t.harvestMultiplier(9999, 1, "oreWoodHarvest"), 1e-4);
}

test "load stock items.xml when present" {
    const path = stock_paths.steam_client ++ "/Data/Config/items.xml";
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
        // A tool carries owner-tiered effect groups, so the trader roll gives
        // it a quality (ItemClass.HasQuality).
        try std.testing.expect(axe.has_quality);
    }
    // Stackable resources carry no effect_group at all: no quality.
    try std.testing.expect(!t.hasQualityByName("resourceWood"));
    // Non-durable items (no DegradationMax) price full: pul term is 1.
    if (t.byName("resourceWood")) |wood| {
        try std.testing.expectEqual(@as(u32, 0), wood.degradation_max);
    }
    // Stock gas can: FuelValue from items.xml (ammoGasCan).
    if (t.byName("ammoGasCan")) |gas| {
        try std.testing.expect(gas.fuel_value > 0);
        try std.testing.expectEqual(gas.fuel_value, t.fuelValueFor(gas.id));
    }
    // Forge melt inputs: Weight + MeltTimePerUnit from items.xml.
    if (t.byName("unit_iron")) |iron| {
        try std.testing.expectEqual(@as(u16, 1), iron.weight);
        try std.testing.expectApproxEqAbs(@as(f32, 0.25), iron.melt_time_per_unit, 1e-4);
        try std.testing.expectEqual(iron.weight, t.weightFor(iron.id));
        try std.testing.expectApproxEqAbs(iron.melt_time_per_unit, t.meltTimePerUnitFor(iron.id), 1e-4);
    }
    // unit_lead Extends unit_iron: Weight + MeltTimePerUnit inherit.
    if (t.byName("unit_lead")) |lead| {
        try std.testing.expectEqual(@as(u16, 1), lead.weight);
        try std.testing.expectApproxEqAbs(@as(f32, 0.25), lead.melt_time_per_unit, 1e-4);
    }
    if (t.byName("resourceScrapBrass")) |brass| {
        try std.testing.expectEqual(@as(u16, 1), brass.weight);
        try std.testing.expectApproxEqAbs(@as(f32, 0.4), brass.melt_time_per_unit, 1e-4);
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
        try std.testing.expectEqual(@as(f32, 1000), boots.econ);
    }
    if (t.byName("ammoGasCan")) |gas| {
        try std.testing.expectEqual(@as(u16, 100), gas.econ_bundle_size);
    }
    if (t.byName("resourceWood")) |wood| {
        try std.testing.expectEqual(@as(u16, 50), wood.econ_bundle_size);
    }
    // Held-item lights (Inventory.GetLightLevel IL=76): torches and
    // flashlights carry items.xml LightValue for the stealth selfLight term.
    if (t.byName("meleeToolTorch")) |torch| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.35), torch.light_value, 0.001);
    }
    if (t.byName("meleeToolFlashlight02")) |fl| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.55), fl.light_value, 0.001);
    }
    if (t.byName("gunHandgunT0PipePistol")) |gun| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.45), gun.light_value, 0.001);
    }
    // Melee damage: club/axe declare it as the EntityDamage passive effect
    // (base_set) - property-less items must not resolve to 0.
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
    const path = stock_paths.configFile("items.xml");
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

test "item passive rows parse with their gates and inherit through Extends" {
    const gd = stock_paths.dedicated_server;
    if (!io_fs.dirExists(gd ++ "/Data/Config")) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, gd ++ "/Data/Config/items.xml");
    defer t.deinit();
    const rowOf = struct {
        fn f(d: ItemDef, name: []const u8) ?buffs.Passive {
            for (d.passives) |p| {
                if (std.mem.eql(u8, p.name, name)) return p;
            }
            return null;
        }
    }.f;
    // armorAthleticOutfit carries HealthMax "2,4,6,8,10,20" (a 6-segment tier
    // curve); the survival VM folds it at the item's quality.
    const outfit = t.byName("armorAthleticOutfit") orelse return error.SkipZigTest;
    const hm = rowOf(outfit, "HealthMax") orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(u8, 6), hm.curve_len);
    try std.testing.expectApproxEqAbs(@as(f32, 20), hm.curve[5], 0.001);
    // armorRangerBoots inherits StaminaMax from its master class (the same
    // Extends chain the resist curves use).
    const boots = t.byName("armorRangerBoots") orelse return error.SkipZigTest;
    const sm = rowOf(boots, "StaminaMax") orelse return error.SkipZigTest;
    try std.testing.expect(sm.curve_len > 0);
    // armorEnforcerOutfit's flat GeneralDamageResist row (passive 40), the one
    // item row the round-2 damage choke consumes.
    const enforcer = t.byName("armorEnforcerOutfit") orelse return error.SkipZigTest;
    const gdr = rowOf(enforcer, "GeneralDamageResist") orelse return error.SkipZigTest;
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), gdr.value, 0.0001);
    // The admin items gate their rows on IsEquipped (6 stock rows), which the
    // item fold answers with Ctx.item_equipped.
    const shirt = t.byName("toughGuyShirtAdmin") orelse return error.SkipZigTest;
    var gated = false;
    for (shirt.passives) |p| {
        for (p.reqs) |r| {
            if (r.kind == .is_equipped) gated = true;
        }
    }
    try std.testing.expect(gated);
}

test "armor resist curves parse from stock items.xml (PDR quality curves)" {
    const gd = stock_paths.dedicated_server;
    if (!io_fs.fileExists(gd ++ "/Data/Config/items.xml")) return error.SkipZigTest;
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
    // Measured against stock V3.2.0 items.xml (2026-09-04): 1413 items, of
    // which 67 carry a PhysicalDamageResist passive; the parse finds 73 rows
    // because a def can hold more than one. The old bound was 50 with a note
    // that max_items might truncate the tail - it cannot: the table runs at
    // 17% of the cap, so nothing is lost and the bound can be tight enough to
    // catch a regression instead of tolerating one.
    try std.testing.expect(found >= 70);
    // DegradationPerUse (base_set) on tools; TargetArmor (perc_add) only on
    // untagged rows (ammo9mmBulletAP, the armor-piercing round).
    var stone_axe = false;
    var ap_ammo = false;
    var javelin = false;
    for (t.defs) |d| {
        if (std.mem.eql(u8, d.name, "meleeToolRepairT0StoneAxe")) {
            try std.testing.expectApproxEqAbs(@as(f32, 1), d.degradation_per_use, 0.001);
            stone_axe = true;
        }
        if (std.mem.eql(u8, d.name, "ammo9mmBulletAP")) {
            try std.testing.expectApproxEqAbs(@as(f32, -0.5), d.target_armor, 0.001);
            ap_ammo = true;
        }
        // perk-tag-gated TargetArmor: the javelin carries `-.3` tagged
        // perkJavelinMaster (applies only when the attacker owns the perk).
        if (std.mem.startsWith(u8, d.name, "meleeWpnSpear") and d.target_armor_tagged != 0) {
            try std.testing.expectEqualStrings("perkJavelinMaster", d.target_armor_tag);
            javelin = true;
        }
    }
    try std.testing.expect(stone_axe);
    try std.testing.expect(ap_ammo);
    try std.testing.expect(javelin);
}

test "StaminaLoss parses as the per-attack cost" {
    const gd = stock_paths.dedicated_server;
    if (!io_fs.fileExists(gd ++ "/Data/Config/items.xml")) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, gd ++ "/Data/Config/items.xml");
    defer t.deinit();
    var found = false;
    for (t.defs) |d| {
        if (std.mem.eql(u8, d.name, "meleeToolRepairT0StoneAxe")) {
            try std.testing.expectApproxEqAbs(@as(f32, 8), d.stamina_loss, 0.001);
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "HasQuality follows owner-tiered effect groups and inherits through Extends" {
    // ItemClass.HasQuality (IL=9) = Effects != null && IsOwnerTiered(). Effects
    // is a property, so a child with no effect_group of its own answers from
    // the first ancestor that declares one.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items.xml", .{dir});
    try io_fs.writeFile(path, "<items>\n" ++
        "  <item name=\"gunMaster\">\n" ++
        "    <effect_group name=\"gunMaster\">\n" ++
        "      <passive_effect name=\"ModSlots\" operation=\"base_set\" value=\"1,1,1,2,2,3\" tier=\"1,2,3,4,5,6\"/>\n" ++
        "    </effect_group>\n" ++
        "  </item>\n" ++
        "  <item name=\"gunChild\">\n" ++
        "    <property name=\"Extends\" value=\"gunMaster\"/>\n" ++
        "  </item>\n" ++
        "  <item name=\"perkBook\">\n" ++
        "    <effect_group name=\"perkBook\" tiered=\"false\">\n" ++
        "      <passive_effect name=\"ModSlots\" operation=\"base_set\" value=\"1\"/>\n" ++
        "    </effect_group>\n" ++
        "  </item>\n" ++
        "  <item name=\"perkBookChild\">\n" ++
        "    <property name=\"Extends\" value=\"perkBook\"/>\n" ++
        "  </item>\n" ++
        "  <item name=\"resourceWood\">\n" ++
        "    <property name=\"Stacknumber\" value=\"100\"/>\n" ++
        "  </item>\n" ++
        "</items>\n");
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.byName("gunMaster").?.has_quality);
    try std.testing.expect(t.byName("gunChild").?.has_quality);
    try std.testing.expect(!t.byName("perkBook").?.has_quality);
    try std.testing.expect(!t.byName("perkBookChild").?.has_quality);
    // No effect_group anywhere in the chain: null Effects, no quality.
    try std.testing.expect(!t.byName("resourceWood").?.has_quality);
    // Name lookup mirrors the field (the trader roll's resolver); an unknown
    // name fails closed.
    try std.testing.expect(t.hasQualityByName("gunChild"));
    try std.testing.expect(!t.hasQualityByName("noSuchItem"));
}

test "items root max_quality_tier bounds the quality axes" {
    // Stock `ItemClassesFromXml.CreateItems` parses the `<items>` root
    // attribute into the static `ItemClass.MaxQualityTier` and assigns 6 when
    // it is absent. V3.2.0 ships no attribute; a modlet that sets it (XPath
    // `/items/@max_quality_tier`) has to move the quality axis with it, or the
    // server clamps a tier the client accepts.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items.xml", .{dir});
    try io_fs.writeFile(path,
        \\<items max_quality_tier="10">
        \\  <item name="gunMaster">
        \\    <property name="Stacknumber" value="1"/>
        \\    <effect_group name="gunMaster" tiered="true">
        \\      <passive_effect name="ModSlots" operation="base_set" value="1"/>
        \\    </effect_group>
        \\  </item>
        \\</items>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expectEqual(@as(u8, 10), t.max_quality_tier);
    // The harvest curve spreads over the table's tier count, not the default.
    const no_rows = t.harvestMultiplier(t.byName("gunMaster").?.id, 7, "wood");
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), no_rows, 0.001);

    // Absent attribute: stock's 6. A degenerate value keeps it too.
    try io_fs.writeFile(path, "<items max_quality_tier=\"0\">\n</items>\n");
    var t2 = try loadFromPath(std.testing.allocator, path);
    defer t2.deinit();
    try std.testing.expectEqual(@as(u8, 6), t2.max_quality_tier);
}

test "EconomicValue keeps stock's float range and fraction" {
    // Stock fields EconomicValue as `Single` and parses it with ParseFloat
    // (ItemClass IL_0666). Typing it u16 turned a modlet's 1000000-duke relic
    // (or a 2.5 value) into 0, which the trader then prices at the
    // "econ == 0" fallback of buy 5 / sell 1, i.e. not tradeable as authored.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items.xml", .{dir});
    try io_fs.writeFile(path,
        \\<items>
        \\  <item name="relic">
        \\    <property name="EconomicValue" value="1000000"/>
        \\  </item>
        \\  <item name="fraction">
        \\    <property name="EconomicValue" value="2.5"/>
        \\  </item>
        \\  <item name="plain"/>
        \\</items>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expectEqual(@as(f32, 1000000), t.byName("relic").?.econ);
    try std.testing.expectEqual(@as(f32, 2.5), t.byName("fraction").?.econ);
    // No EconomicValue anywhere: 0, the trader's untradeable marker.
    try std.testing.expectEqual(@as(f32, 0), t.byName("plain").?.econ);
}

test "items.xml stats rows parse with stock's field grammar and guards" {
    // Stock ItemClass::GSStatsParseXml IL=181: each `<stat>` needs a name and a
    // value with at least five comma fields (quality, gameStage, chance, min,
    // max); |min| or |max| at 163.835 or above is rejected rather than
    // overflowing the i16 cast, and the stored value is the XML number divided
    // by 0.005.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items_stats.xml", .{dir});
    try io_fs.writeFile(path,
        \\<items>
        \\  <item name="gunMaster">
        \\    <stats>
        \\      <stat name="EntityDamage" value="0,0,1,0,.1"/>
        \\      <stat name="DegradationMax" value="0,60,.5,-.1,.2"/>
        \\    </stats>
        \\  </item>
        \\  <item name="badRows">
        \\    <stats>
        \\      <stat name="EntityDamage" value="0,0,1,0"/>
        \\      <stat name="" value="0,0,1,0,.1"/>
        \\      <stat name="Range" value="0,0,1,0,200"/>
        \\      <stat name="BlockDamage" value="0,0,1,notanumber,.1"/>
        \\    </stats>
        \\  </item>
        \\  <item name="emptyStats"><stats></stats></item>
        \\</items>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const gm = t.byName("gunMaster").?;
    try std.testing.expectEqual(@as(usize, 2), gm.stats.len);
    try std.testing.expectEqualStrings("EntityDamage", gm.stats[0].effect);
    try std.testing.expectEqual(@as(i16, 0), gm.stats[0].quality);
    try std.testing.expectEqual(@as(i16, 0), gm.stats[0].game_stage);
    try std.testing.expectEqual(@as(f32, 1), gm.stats[0].chance);
    try std.testing.expectEqual(@as(i16, 0), gm.stats[0].min);
    try std.testing.expectEqual(@as(i16, 20), gm.stats[0].max); // .1 / .005
    try std.testing.expectEqualStrings("DegradationMax", gm.stats[1].effect);
    try std.testing.expectEqual(@as(i16, 60), gm.stats[1].game_stage);
    try std.testing.expectEqual(@as(f32, 0.5), gm.stats[1].chance);
    try std.testing.expectEqual(@as(i16, -20), gm.stats[1].min); // -.1 / .005
    try std.testing.expectEqual(@as(i16, 40), gm.stats[1].max); // .2 / .005
    // Every malformed row is dropped; the well-formed ones stay.
    try std.testing.expectEqual(@as(usize, 0), t.byName("badRows").?.stats.len);
    try std.testing.expectEqual(@as(usize, 0), t.byName("emptyStats").?.stats.len);
}

test "stock items.xml stats rows load" {
    const path = stock_paths.configFile("items.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    // A tool carries the Base_Random_Roll rows; EntityDamage is
    // "0,0,1,0,.1" (chance 1, min 0, max 20 after the /0.005 scale).
    const axe = t.byName("meleeToolAxeT1IronFireaxe") orelse return error.TestUnexpectedResult;
    try std.testing.expect(axe.stats.len >= 4);
    // Two EntityDamage rows: the quality-0 base roll (chance 1, max .1) and the
    // quality-1 boosted roll (chance .3, min .1, max .5).
    var base: ?GsStat = null;
    var boosted: ?GsStat = null;
    for (axe.stats) |r| {
        if (!std.mem.eql(u8, r.effect, "EntityDamage")) continue;
        if (r.quality == 0) base = r;
        if (r.quality == 1) boosted = r;
    }
    try std.testing.expectEqual(@as(i16, 20), base.?.max);
    try std.testing.expectEqual(@as(f32, 1), base.?.chance);
    try std.testing.expectEqual(@as(i16, 20), boosted.?.min);
    try std.testing.expectEqual(@as(i16, 100), boosted.?.max);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), boosted.?.chance, 0.0001);
    // An item with no <stats> block stays empty (fail closed, no invented rows).
    try std.testing.expectEqual(@as(usize, 0), t.byName("resourceWood").?.stats.len);
}

test "SellableToTrader parses and inherits through Extends" {
    // Stock `ItemClass` reads SellableToTrader with ParseBool (default true)
    // and the property dictionary is copied through Extends, so a child of an
    // unsellable master is unsellable too. 48 stock items declare it.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items_sell.xml", .{dir});
    try io_fs.writeFile(path,
        \\<items>
        \\  <item name="questItemMaster">
        \\    <property name="SellableToTrader" value="false"/>
        \\  </item>
        \\  <item name="questItemChild">
        \\    <property name="Extends" value="questItemMaster"/>
        \\  </item>
        \\  <item name="plainItem"/>
        \\  <item name="declaredTrue">
        \\    <property name="SellableToTrader" value="true"/>
        \\  </item>
        \\</items>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(!t.byName("questItemMaster").?.sellable_to_trader);
    try std.testing.expect(!t.byName("questItemChild").?.sellable_to_trader);
    // Absent keeps stock's true default.
    try std.testing.expect(t.byName("plainItem").?.sellable_to_trader);
    try std.testing.expect(t.byName("declaredTrue").?.sellable_to_trader);
}

test "stock items.xml SellableToTrader rows load" {
    const path = stock_paths.configFile("items.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    // meleeWpnBladeT0BoneKnife carries value="false" (items.xml:40) and the
    // quest masters inherit it.
    try std.testing.expect(!t.byName("meleeWpnBladeT0BoneKnife").?.sellable_to_trader);
    // The default is true for the bulk of the catalog.
    try std.testing.expect(t.byName("gunHandgunT0PipePistol").?.sellable_to_trader);
}

test "TraderQualityMod parses and inherits through Extends" {
    // Stock ItemClass reads the quality price pair
    // (TraderQualityMinMod/MaxMod, written as the comma pair TraderQualityMod
    // in items.xml; 4 stock rows, all "1,20") and XUiM_Trader's GetBuyPrice /
    // GetSellPrice lerp it over (Quality-1)/5, falling back to the trader's
    // pair when the item declares none.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items_tqm.xml", .{dir});
    try io_fs.writeFile(path,
        \\<items>
        \\  <item name="cookMaster">
        \\    <property name="TraderQualityMod" value="1,20"/>
        \\  </item>
        \\  <item name="cookChild">
        \\    <property name="Extends" value="cookMaster"/>
        \\  </item>
        \\  <item name="splitKeys">
        \\    <property name="TraderQualityMinMod" value="2"/>
        \\    <property name="TraderQualityMaxMod" value="7"/>
        \\  </item>
        \\  <item name="plain"/>
        \\</items>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expectEqual(@as(f32, 1), t.byName("cookMaster").?.trader_quality_min_mod);
    try std.testing.expectEqual(@as(f32, 20), t.byName("cookMaster").?.trader_quality_max_mod);
    // Extends carries both halves.
    try std.testing.expectEqual(@as(f32, 1), t.byName("cookChild").?.trader_quality_min_mod);
    try std.testing.expectEqual(@as(f32, 20), t.byName("cookChild").?.trader_quality_max_mod);
    // The two separate keys work too, and an absent pair stays 0 (the
    // trader's own pair applies).
    try std.testing.expectEqual(@as(f32, 2), t.byName("splitKeys").?.trader_quality_min_mod);
    try std.testing.expectEqual(@as(f32, 7), t.byName("splitKeys").?.trader_quality_max_mod);
    try std.testing.expectEqual(@as(f32, 0), t.byName("plain").?.trader_quality_min_mod);
    try std.testing.expectEqual(@as(f32, 0), t.byName("plain").?.trader_quality_max_mod);
}

test "stock items.xml TraderQualityMod rows load" {
    const path = stock_paths.configFile("items.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const pot = t.byName("toolCookingPot") orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(f32, 1), pot.trader_quality_min_mod);
    try std.testing.expectEqual(@as(f32, 20), pot.trader_quality_max_mod);
    // A normal tool declares no pair: the trader's own quality mod applies.
    try std.testing.expectEqual(@as(f32, 0), t.byName("meleeToolAxeT1IronFireaxe").?.trader_quality_min_mod);
}

test "the gamestage stat roll follows stock's draw order" {
    // The stock axe rows (items.xml meleeToolAxeT1IronFireaxe): a quality-0
    // base row (chance 1, min 0, max .1) and a quality-1 boosted row
    // (chance .3, min .1, max .5); the stored i16s are the XML value / 0.005,
    // so the ranges are 0..20 and 20..100.
    const rows = [_]GsStat{
        .{ .effect = "EntityDamage", .quality = 0, .game_stage = 0, .chance = 1, .min = 0, .max = 20 },
        .{ .effect = "EntityDamage", .quality = 1, .game_stage = 0, .chance = 0.3, .min = 20, .max = 100 },
        .{ .effect = "DegradationMax", .quality = 0, .game_stage = 0, .chance = 1, .min = 0, .max = 0 },
    };
    var out: [6]RolledGsStat = undefined;

    // Deterministic: the same seed draws the same entries, and the base roll
    // stays inside the base row's range.
    var r1 = game_random.GameRandom.init(1234);
    const n1 = rollGsStats(&rows, 1, 0, &r1, &out);
    try std.testing.expect(n1 >= 1);
    // EntityDamage is the first effect and `None`=0, `EntityDamage`=1.
    try std.testing.expectEqual(@as(u8, 1), out[0].effect);
    const value1: i32 = @as(i32, out[0].slot_a) + @as(i32, out[0].slot_b);
    try std.testing.expect(value1 >= 0 and value1 <= 120);
    var r2 = game_random.GameRandom.init(1234);
    var out2: [6]RolledGsStat = undefined;
    const n2 = rollGsStats(&rows, 1, 0, &r2, &out2);
    try std.testing.expectEqual(n1, n2);
    try std.testing.expectEqualSlices(RolledGsStat, out[0..n1], out2[0..n2]);

    // The zero-sum row contributes nothing: an all-zero base row and no
    // quality row emit no entry (stock's RemoveUnusedStats).
    const zero_rows = [_]GsStat{
        .{ .effect = "BlockDamage", .quality = 0, .game_stage = 0, .chance = 1, .min = 0, .max = 0 },
    };
    var r3 = game_random.GameRandom.init(7);
    var out3: [6]RolledGsStat = undefined;
    try std.testing.expectEqual(@as(usize, 0), rollGsStats(&zero_rows, 1, 0, &r3, &out3));

    // A row whose chance gate fails leaves the base roll alone and the added
    // roll out: chance 0 never passes, so the entry is the base only.
    const gated = [_]GsStat{
        .{ .effect = "EntityDamage", .quality = 0, .game_stage = 0, .chance = 1, .min = 5, .max = 5 },
        .{ .effect = "EntityDamage", .quality = 3, .game_stage = 0, .chance = 0, .min = 50, .max = 60 },
    };
    var r4 = game_random.GameRandom.init(99);
    var out4: [6]RolledGsStat = undefined;
    const n4 = rollGsStats(&gated, 3, 0, &r4, &out4);
    try std.testing.expectEqual(@as(usize, 1), n4);
    // Base 5..5 (RandomRange(5, 6) = 5), no added value, so the value is a
    // non-boosted slot_a.
    try std.testing.expectEqual(@as(i16, 5), out4[0].slot_a);
    try std.testing.expectEqual(@as(i16, 0), out4[0].slot_b);

    // A stage below the row's gameStage skips it (the quality-1 row declares
    // stage 20: at stage 0 the added roll finds nothing).
    const staged = [_]GsStat{
        .{ .effect = "EntityDamage", .quality = 1, .game_stage = 20, .chance = 1, .min = 40, .max = 40 },
    };
    var r5 = game_random.GameRandom.init(3);
    var out5: [6]RolledGsStat = undefined;
    try std.testing.expectEqual(@as(usize, 0), rollGsStats(&staged, 1, 0, &r5, &out5));
    var r6 = game_random.GameRandom.init(3);
    var out6: [6]RolledGsStat = undefined;
    try std.testing.expectEqual(@as(usize, 0), rollGsStats(&staged, 1, 0, &r6, &out6));
    var r7 = game_random.GameRandom.init(3);
    var out7: [6]RolledGsStat = undefined;
    const n7 = rollGsStats(&staged, 0, 0, &r7, &out7);
    try std.testing.expectEqual(@as(usize, 0), n7);
}
