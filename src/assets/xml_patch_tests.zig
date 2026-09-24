//! XML patch tests: xpath parse, ops, conditionals, CSV, routing.
//!
//! Split out of assets/xml_patch.zig (same code, moved verbatim).

const std = @import("std");
const xml_patch = @import("xml_patch.zig");
const parseXPath = xml_patch.parseXPath;
const XPredKind = xml_patch.XPredKind;
const applyPatchDoc = xml_patch.applyPatchDoc;
const applyModDirs = xml_patch.applyModDirs;
const fileFromXPath = xml_patch.fileFromXPath;
const io_fs = @import("../util/io_fs.zig");
const mods = @import("modlets.zig");

test "parse xpath property value" {
    const p = parseXPath("/blocks/block[@name='generatorbank']/property[@name='MaxFuel']/@value").?;
    try std.testing.expectEqual(@as(usize, 3), p.n);
    try std.testing.expectEqualStrings("blocks", p.segs[0].tag);
    try std.testing.expectEqualStrings("block", p.segs[1].tag);
    try std.testing.expectEqual(@as(u8, 1), p.segs[1].pred_n);
    try std.testing.expectEqual(XPredKind.attr_eq, p.segs[1].preds[0].kind);
    try std.testing.expectEqualStrings("name", p.segs[1].preds[0].attr);
    try std.testing.expectEqualStrings("generatorbank", p.segs[1].preds[0].val);
    try std.testing.expectEqualStrings("value", p.set_attr.?);
}

test "set MaxFuel on generatorbank" {
    const base =
        \\<blocks>
        \\<block name="generatorbank">
        \\  <property name="MaxFuel" value="1000"/>
        \\  <property name="MaxPower" value="12250"/>
        \\</block>
        \\</blocks>
    ;
    const patch =
        \\<configs file="blocks.xml">
        \\  <set xpath="/blocks/block[@name='generatorbank']/property[@name='MaxFuel']/@value">50</set>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "value=\"50\"") != null);
    try std.testing.expect(std.mem.find(u8, out, "12250") != null);
}

test "set the root element attribute a modlet raises the quality tier with" {
    // The stock-supported way to move `ItemClass.MaxQualityTier`: a root
    // attribute patch (`/items/@max_quality_tier`), which `items.zig` then
    // reads as the quality-axis bound.
    const base =
        \\<items>
        \\<item name="gunMaster">
        \\  <property name="Stacknumber" value="1"/>
        \\</item>
        \\</items>
    ;
    const patch =
        \\<configs file="items.xml">
        \\  <set xpath="/items/@max_quality_tier">10</set>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "items.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "max_quality_tier=\"10\"") != null);
}

test "remove block" {
    const base =
        \\<blocks>
        \\<block name="a"><property name="x" value="1"/></block>
        \\<block name="b"><property name="x" value="2"/></block>
        \\</blocks>
    ;
    const patch =
        \\<configs>
        \\  <remove xpath="/blocks/block[@name='a']"/>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "name=\"a\"") == null);
    try std.testing.expect(std.mem.find(u8, out, "name=\"b\"") != null);
}

test "prepend inserts after the opening tag" {
    const base =
        \\<blocks>
        \\<block name="a"><property name="x" value="1"/></block>
        \\</blocks>
    ;
    const patch =
        \\<configs file="blocks.xml">
        \\  <prepend xpath="/blocks/block[@name='a']"><property name="pre" value="1"/></prepend>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    // prepended property precedes the original child
    const pre = std.mem.find(u8, out, "name=\"pre\"").?;
    const x = std.mem.find(u8, out, "name=\"x\"").?;
    try std.testing.expect(pre < x);
}

test "insertafter places a sibling after the matched element" {
    const base =
        \\<blocks>
        \\<block name="a"><property name="x" value="1"/></block>
        \\</blocks>
    ;
    const patch =
        \\<configs file="blocks.xml">
        \\  <insertafter xpath="/blocks/block[@name='a']"><block name="b"/></insertafter>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "name=\"b\"") != null);
    const a = std.mem.find(u8, out, "name=\"a\"").?;
    const b = std.mem.find(u8, out, "name=\"b\"").?;
    try std.testing.expect(a < b);
}

test "removeattribute drops one attribute from the element" {
    const base =
        \\<blocks>
        \\<block name="a" class="terrain" hardness="3"><property name="x" value="1"/></block>
        \\</blocks>
    ;
    const patch =
        \\<configs file="blocks.xml">
        \\  <removeattribute xpath="/blocks/block[@name='a']/@class"/>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "class=") == null);
    try std.testing.expect(std.mem.find(u8, out, "hardness=\"3\"") != null);
}

test "removeattribute terminates on an unquoted or bare attribute" {
    // The attribute scan must always advance: a modlet is operator-supplied
    // XML, so an unquoted value (hardness=3) or a bare token (disabled) in the
    // opening tag used to leave the cursor parked and spin forever, hanging the
    // load. Malformed input must fail or no-op, never hang.
    const cases = [_][]const u8{
        // unquoted value after the target attribute
        \\<blocks>
        \\<block name="a" class="terrain" hardness=3></block>
        \\</blocks>
        ,
        // bare valueless token in the opening tag
        \\<blocks>
        \\<block name="a" class="terrain" disabled></block>
        \\</blocks>
        ,
        // unquoted value before the target attribute
        \\<blocks>
        \\<block name="a" hardness=3 class="terrain"></block>
        \\</blocks>
        ,
    };
    const patch =
        \\<configs file="blocks.xml">
        \\  <removeattribute xpath="/blocks/block[@name='a']/@class"/>
        \\</configs>
    ;
    for (cases) |base| {
        const out = applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{}) catch continue;
        defer std.testing.allocator.free(out);
        // Termination is the point, but the scan must still find the target:
        // a quoted attribute after a malformed neighbour is removed normally.
        try std.testing.expect(std.mem.find(u8, out, "class=") == null);
        try std.testing.expect(std.mem.find(u8, out, "name=\"a\"") != null);
    }
}

test "csvoperations add and remove on a comma list" {
    const base =
        \\<items>
        \\<item name="x"><property name="Tags" value="a,b,c"/></item>
        \\</items>
    ;
    const add_patch =
        \\<configs file="items.xml">
        \\  <csvoperations xpath="/items/item[@name='x']/property[@name='Tags']/@value" op="add" value="d"/>
        \\</configs>
    ;
    const after_add = try applyPatchDoc(std.testing.allocator, base, add_patch, "items.xml", .{});
    defer std.testing.allocator.free(after_add);
    try std.testing.expect(std.mem.find(u8, after_add, "value=\"a,b,c,d\"") != null);

    const rm_patch =
        \\<configs file="items.xml">
        \\  <csvoperations xpath="/items/item[@name='x']/property[@name='Tags']/@value" op="remove" value="b"/>
        \\</configs>
    ;
    const after_rm = try applyPatchDoc(std.testing.allocator, base, rm_patch, "items.xml", .{});
    defer std.testing.allocator.free(after_rm);
    try std.testing.expect(std.mem.find(u8, after_rm, "value=\"a,c\"") != null);
}

test "file name routes a patch with an unresolvable xpath root" {
    // Stock modlet convention (G3): Config/loadingscreen.xml targets
    // loadingscreen.xml, and must not leak into other catalogs even though
    // /loadingscreen is not in the inference map.
    const base =
        \\<blocks><block name="a"/></blocks>
    ;
    const patch =
        \\<configs>
        \\  <append xpath="/loadingscreen/tip"><tip text="hi"/></append>
        \\</configs>
    ;
    // Patch file named blocks.xml applies to blocks.xml (append no-ops: xpath
    // not found) instead of leaking.
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{ .patch_file_name = "blocks.xml" });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("<blocks><block name=\"a\"/></blocks>", out);
    // With no routing evidence and no file name, the op is skipped entirely.
    const out2 = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out2);
    try std.testing.expectEqualStrings("<blocks><block name=\"a\"/></blocks>", out2);
}

test "unknown op is skipped, the rest of the file still applies" {
    // Stock resolves the op through a local-name lookup and warns on a miss
    // (XmlPatcher IL_0176-0204); killing the server instead turned a code
    // modlet that registers its own op into a boot failure. Everything else
    // in the file still applies.
    const base =
        \\<blocks><block name="a"/></blocks>
    ;
    const patch =
        \\<configs file="blocks.xml">
        \\  <append xpath="/blocks"><block name="b"/></append>
        \\  <frobnicate xpath="/blocks/block[@name='a']"/>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "name=\"b\"") != null);
}

test "conditional picks the if/else branch, unknown expressions skip" {
    const base =
        \\<blocks><block name="a"/></blocks>
    ;
    // No mods installed: mod_loaded('X') is false, so the else branch applies.
    const patch =
        \\<configs file="blocks.xml">
        \\  <conditional>
        \\    <if cond="mod_loaded('NotInstalled')"><append xpath="/blocks"><block name="fromIf"/></append></if>
        \\    <else><append xpath="/blocks"><block name="fromElse"/></append></else>
        \\  </conditional>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "fromElse") != null);
    try std.testing.expect(std.mem.find(u8, out, "fromIf") == null);

    // An expression this server cannot evaluate skips the whole block (no
    // change, no boot failure): NCalc's game_version needs the stock version
    // string mapping zdtd does not carry.
    const unevaluable =
        \\<configs file="blocks.xml">
        \\  <conditional>
        \\    <if cond="game_version('V 2.0 (b8)')"><append xpath="/blocks"><block name="gv"/></append></if>
        \\  </conditional>
        \\</configs>
    ;
    const out2 = try applyPatchDoc(std.testing.allocator, base, unevaluable, "blocks.xml", .{});
    defer std.testing.allocator.free(out2);
    try std.testing.expectEqualStrings(base, out2);
}

test "xpath predicates: contains, starts-with, and/or, position, existence" {
    const base =
        \\<items>
        \\<item name="a_rifle"><property name="Tags" value="rifleSkill"/><property name="Damage" value="1"/></item>
        \\<item name="a_pistol"><property name="Tags" value="handgunSkill"/></item>
        \\<item name="b_rifle"><property name="Tags" value="rifleSkill"/></item>
        \\</items>
    ;
    // contains(): every rifle item is patched (stock applies to all matches).
    const contains_patch =
        \\<configs file="items.xml">
        \\  <set xpath="//item[contains(@name,'rifle')]/property[@name='Tags']/@value">patched</set>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, contains_patch, "items.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "value=\"patched\""));

    // starts-with() + 'or' over two name values, through `setattribute`
    // (attribute name from the patch element's `name` attribute, stock
    // SetAttributeByXPath) on the element target.
    const or_patch =
        \\<configs file="items.xml">
        \\  <setattribute xpath="//item[starts-with(@name,'a_') or @name='b_rifle'][1]" name="CustomIcon">anIcon</setattribute>
        \\</configs>
    ;
    const out2 = try applyPatchDoc(std.testing.allocator, base, or_patch, "items.xml", .{});
    defer std.testing.allocator.free(out2);
    try std.testing.expect(std.mem.find(u8, out2, "CustomIcon=\"anIcon\"") != null);
    // A `name`-less setattribute is a patch error (stock throws).
    const bad_attr =
        \\<configs file="items.xml">
        \\  <setattribute xpath="//item[@name='a_rifle']">x</setattribute>
        \\</configs>
    ;
    try std.testing.expectError(error.PatchMissingNameAttribute, applyPatchDoc(std.testing.allocator, base, bad_attr, "items.xml", .{}));

    // Positional [2] selects the second match.
    const pos_patch =
        \\<configs file="items.xml">
        \\  <set xpath="//item[contains(@name,'rifle')][2]/property[@name='Tags']/@value">second</set>
        \\</configs>
    ;
    const out3 = try applyPatchDoc(std.testing.allocator, base, pos_patch, "items.xml", .{});
    defer std.testing.allocator.free(out3);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out3, "second"));

    // Attribute existence.
    const exists_patch =
        \\<configs file="items.xml">
        \\  <set xpath="//item[@name]"><item name="renamed"/></set>
        \\</configs>
    ;
    const out4 = try applyPatchDoc(std.testing.allocator, base, exists_patch, "items.xml", .{});
    defer std.testing.allocator.free(out4);
    try std.testing.expect(std.mem.find(u8, out4, "renamed") != null);
}

test "csv op name and attribute append match the stock forms" {
    const base =
        \\<items><item name="x"><property name="Tags" value="a,b"/></item></items>
    ;
    const csv_patch =
        \\<configs file="items.xml">
        \\  <csv op="add" xpath="/items/item[@name='x']/property[@name='Tags']/@value">c</csv>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, csv_patch, "items.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "value=\"a,b,c\"") != null);

    // append to an /@attr target appends to the attribute text (stock
    // AppendByXPath on an XAttribute).
    const append_patch =
        \\<configs file="items.xml">
        \\  <append xpath="/items/item[@name='x']/property[@name='Tags']/@value">,d</append>
        \\</configs>
    ;
    const out2 = try applyPatchDoc(std.testing.allocator, base, append_patch, "items.xml", .{});
    defer std.testing.allocator.free(out2);
    try std.testing.expect(std.mem.find(u8, out2, "value=\"a,b,d\"") != null);
}

test "csv honours delim and adds each entry (stock grammar)" {
    // Stock CsvOperationsByXPath: op add|remove, `delim` exactly one character
    // or the literal \n, default comma; the patch text is split, trimmed and
    // each entry added/removed against the target list.
    const base =
        \\<items><item name="x"><property name="Groups" value="a;b"/></item></items>
    ;
    const patch =
        \\<configs file="items.xml">
        \\  <csv op="add" delim=";" xpath="/items/item[@name='x']/property[@name='Groups']/@value">c;d</csv>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "items.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "value=\"a;b;c;d\"") != null);

    // Adding an entry already present is a no-op; removing one works.
    const dedup =
        \\<configs file="items.xml">
        \\  <csv op="add" delim=";" xpath="/items/item[@name='x']/property[@name='Groups']/@value">b</csv>
        \\</configs>
    ;
    const out2 = try applyPatchDoc(std.testing.allocator, base, dedup, "items.xml", .{});
    defer std.testing.allocator.free(out2);
    try std.testing.expect(std.mem.find(u8, out2, "value=\"a;b\"") != null);
    const rm =
        \\<configs file="items.xml">
        \\  <csv op="remove" delim=";" xpath="/items/item[@name='x']/property[@name='Groups']/@value">a</csv>
        \\</configs>
    ;
    const out3 = try applyPatchDoc(std.testing.allocator, base, rm, "items.xml", .{});
    defer std.testing.allocator.free(out3);
    try std.testing.expect(std.mem.find(u8, out3, "value=\"b\"") != null);

    // The literal `\n` delim splits on real newlines in the patch text.
    const nl_base = "<items><item name=\"x\"><property name=\"Groups\" value=\"a\"/></item></items>";
    const nl_patch =
        \\<configs file="items.xml">
        \\  <csv op="add" delim="\n" xpath="/items/item[@name='x']/property[@name='Groups']/@value">
        \\b
        \\c
        \\  </csv>
        \\</configs>
    ;
    const out4 = try applyPatchDoc(std.testing.allocator, nl_base, nl_patch, "items.xml", .{});
    defer std.testing.allocator.free(out4);
    try std.testing.expect(std.mem.find(u8, out4, "value=\"a\nb\nc\"") != null);

    // A multi-character delimiter is a patch error (stock throws).
    const bad =
        \\<configs file="items.xml">
        \\  <csv op="add" delim=";;" xpath="/items/item[@name='x']/property[@name='Groups']/@value">c</csv>
        \\</configs>
    ;
    try std.testing.expectError(error.PatchInvalidDelim, applyPatchDoc(std.testing.allocator, base, bad, "items.xml", .{}));
}

test "set on an element replaces its children (stock ReplaceNodes)" {
    const base =
        \\<items><item name="x"><property name="Old" value="1"/></item></items>
    ;
    const patch =
        \\<configs file="items.xml">
        \\  <set xpath="//item[@name='x']"><property name="New" value="2"/></set>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "items.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "name=\"New\"") != null);
    try std.testing.expect(std.mem.find(u8, out, "name=\"Old\"") == null);
    // A self-closing match expands to hold the new children.
    const base2 =
        \\<items><item name="y"/></items>
    ;
    const patch2 =
        \\<configs file="items.xml">
        \\  <set xpath="//item[@name='y']"><property name="A" value="1"/></set>
        \\</configs>
    ;
    const out2 = try applyPatchDoc(std.testing.allocator, base2, patch2, "items.xml", .{});
    defer std.testing.allocator.free(out2);
    try std.testing.expect(std.mem.find(u8, out2, "<item name=\"y\"><property name=\"A\" value=\"1\"/></item>") != null);
}

test "remove with an attribute target is a no-op (stock guard)" {
    const base =
        \\<items><item name="x"><property name="Tags" value="a"/></item></items>
    ;
    const patch =
        \\<configs file="items.xml">
        \\  <remove xpath="/items/item[@name='x']/property[@name='Tags']/@value"/>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "items.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(base, out);
}

test "a realistic xml-only modlet applies through the scan and patch path" {
    // The shape a 7daystodiemods.com XML-only modlet ships: ModInfo.xml V2,
    // Config/ patches (append a new item, set an existing property, csv-add a
    // tag, conditional on a mod that is not installed), Bundles/ and
    // Localization.csv that the server tolerates without reading.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const mod_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/Mods/SimpleMod", .{root});
    defer std.testing.allocator.free(mod_dir);
    const cfg_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/Config", .{mod_dir});
    defer std.testing.allocator.free(cfg_dir);
    const bnd_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/Bundles", .{mod_dir});
    defer std.testing.allocator.free(bnd_dir);
    io_fs.mkdirPath(cfg_dir);
    io_fs.mkdirPath(bnd_dir);
    const modinfo = try std.fmt.allocPrint(std.testing.allocator, "{s}/ModInfo.xml", .{mod_dir});
    defer std.testing.allocator.free(modinfo);
    try io_fs.writeFile(modinfo,
        \\<xml>
        \\  <Name value="SimpleMod"/>
        \\  <DisplayName value="Simple Mod"/>
        \\  <Version value="1.2"/>
        \\  <Author value="someone"/>
        \\</xml>
    );
    const items_patch = try std.fmt.allocPrint(std.testing.allocator, "{s}/items.xml", .{cfg_dir});
    defer std.testing.allocator.free(items_patch);
    try io_fs.writeFile(items_patch,
        \\<configs>
        \\  <append xpath="/items">
        \\    <item name="simpleModItem">
        \\      <property name="Stacknumber" value="250"/>
        \\      <property name="Tags" value="simple,modded"/>
        \\    </item>
        \\  </append>
        \\  <set xpath="/items/item[@name='existing']/property[@name='Stacknumber']/@value">99</set>
        \\  <csv op="add" xpath="/items/item[@name='existing']/property[@name='Tags']/@value">fromMod</csv>
        \\  <conditional>
        \\    <if cond="mod_loaded('SomeOtherMod')"><append xpath="/items"><item name="shouldNotAppear"/></append></if>
        \\  </conditional>
        \\</configs>
    );
    const loc = try std.fmt.allocPrint(std.testing.allocator, "{s}/Localization.csv", .{cfg_dir});
    defer std.testing.allocator.free(loc);
    try io_fs.writeFile(loc, "simpleModItem,simpleModItemName,Simple Mod Item\n");
    // A config that lives in a subdirectory of the base Config tree is patched
    // by the same relative path under the mod's Config/ (stock resolves
    // `<mod>/Config/<configName>`), e.g. XUi_InGame/windows.
    const xui_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/XUi_InGame", .{cfg_dir});
    defer std.testing.allocator.free(xui_dir);
    io_fs.mkdirPath(xui_dir);
    const xui_patch = try std.fmt.allocPrint(std.testing.allocator, "{s}/windows.xml", .{xui_dir});
    defer std.testing.allocator.free(xui_patch);
    try io_fs.writeFile(xui_patch,
        \\<configs>
        \\  <append xpath="/windows"><window name="modWindow"/></append>
        \\</configs>
    );

    const mods_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/Mods", .{root});
    defer std.testing.allocator.free(mods_root);
    var mst: mods.State = .{};
    defer mst.deinit(std.testing.allocator);
    const dirs = try mst.install(std.testing.allocator, mods_root, null);
    mods.bind(&mst);
    defer mods.unbind();
    defer mst.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), dirs.len);
    try std.testing.expect(mods.isLoaded("simplemod"));
    try std.testing.expectEqualStrings("1.2", mods.versionByName("SimpleMod").?);

    const base =
        \\<items><item name="existing"><property name="Stacknumber" value="1"/><property name="Tags" value="a"/></item></items>
    ;
    const out = try applyModDirs(std.testing.allocator, base, "items.xml", dirs);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "simpleModItem") != null);
    try std.testing.expect(std.mem.find(u8, out, "value=\"99\"") != null);
    try std.testing.expect(std.mem.find(u8, out, "value=\"a,fromMod\"") != null);
    try std.testing.expect(std.mem.find(u8, out, "shouldNotAppear") == null);
    // The matching-name file is applied exactly once (the per-file scan skips
    // the file the exact-name pass already used).
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "simpleModItem"));

    const xui_base = "<windows><window name=\"base\"/></windows>";
    const xui_out = try applyModDirs(std.testing.allocator, xui_base, "XUi_InGame/windows", dirs);
    defer std.testing.allocator.free(xui_out);
    try std.testing.expect(std.mem.find(u8, xui_out, "modWindow") != null);
}

test "include with @modfolder token pulls another patch file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const mods_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/Mods", .{root});
    defer std.testing.allocator.free(mods_root);
    const mod_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/A", .{mods_root});
    defer std.testing.allocator.free(mod_dir);
    const cfg_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/Config", .{mod_dir});
    defer std.testing.allocator.free(cfg_dir);
    io_fs.mkdirPath(cfg_dir);
    var p_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const mi = try std.fmt.bufPrint(&p_buf, "{s}/ModInfo.xml", .{mod_dir});
    try io_fs.writeFile(mi, "<xml><Name value=\"A\"/><DisplayName value=\"A\"/><Version value=\"1.0\"/></xml>");
    const main_f = try std.fmt.bufPrint(&p_buf, "{s}/main.xml", .{cfg_dir});
    try io_fs.writeFile(main_f, "<configs file=\"blocks.xml\"><include xpath=\"@modfolder:/Config/inc.xml\"/></configs>");
    const inc_f = try std.fmt.bufPrint(&p_buf, "{s}/inc.xml", .{cfg_dir});
    try io_fs.writeFile(inc_f, "<configs file=\"blocks.xml\"><append xpath=\"/blocks/block[@name='a']\"><property name=\"FromInclude\" value=\"1\"/></append></configs>");

    var mst2: mods.State = .{};
    defer mst2.deinit(std.testing.allocator);
    const mod_dirs = try mst2.install(std.testing.allocator, mods_root, null);
    mods.bind(&mst2);
    defer mods.unbind();
    defer mst2.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), mod_dirs.len);

    const base =
        \\<blocks><block name="a"><property name="x" value="1"/></block></blocks>
    ;
    const out = try applyModDirs(std.testing.allocator, base, "blocks.xml", mod_dirs);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "FromInclude") != null);
}

test "fileFromXPath" {
    try std.testing.expectEqualStrings("blocks.xml", fileFromXPath("/blocks/block[@name='x']").?);
    try std.testing.expectEqualStrings("items.xml", fileFromXPath("/items/item[@name='y']").?);
}

test "include filename resolves against the including patch file's directory" {
    // Stock `XmlPatchMethods::Include` reads `filename=` and joins it with the
    // *including file's* directory, which is how a mod reaches a subdirectory
    // patch (SphereII's `Config/Agility/main.xml` includes `Init.xml` next to
    // it). zdtd used to read `xpath`/`path`, resolve against the CWD and treat
    // a miss as fatal, so those modlets refused the boot.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var sub_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const sub = try std.fmt.bufPrint(&sub_buf, "{s}/Agility", .{dir});
    io_fs.mkdirPath(sub);
    var main_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const main_path = try std.fmt.bufPrint(&main_buf, "{s}/main.xml", .{sub});
    var inc_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const inc_path = try std.fmt.bufPrint(&inc_buf, "{s}/Init.xml", .{sub});
    try io_fs.writeFile(main_path,
        \\<configs>
        \\  <include filename="Init.xml" />
        \\</configs>
    );
    try io_fs.writeFile(inc_path,
        \\<configs>
        \\  <set xpath="/blocks/block[@name='terrStone']/@maxdamage">42</set>
        \\  <unknownop xpath="/blocks/block[@name='terrStone']/@maxdamage">7</unknownop>
        \\</configs>
    );
    const base =
        \\<blocks>
        \\<block name="terrStone" maxdamage="500" />
        \\</blocks>
    ;
    const patch = try io_fs.readFileAll(std.testing.allocator, main_path);
    defer std.testing.allocator.free(patch);
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{
        .patch_file_name = "main.xml",
        .patch_file_dir = sub,
    });
    defer std.testing.allocator.free(out);
    // The included op applied, and the unknown op in the same file was skipped
    // rather than aborting the load.
    try std.testing.expect(std.mem.find(u8, out, "maxdamage=\"42\"") != null);
    try std.testing.expect(std.mem.find(u8, out, "maxdamage=\"7\"") == null);

    // A missing include drops the file, never the boot.
    try io_fs.writeFile(main_path,
        \\<configs>
        \\  <include filename="nope.xml" />
        \\</configs>
    );
    const patch2 = try io_fs.readFileAll(std.testing.allocator, main_path);
    defer std.testing.allocator.free(patch2);
    const out2 = try applyPatchDoc(std.testing.allocator, base, patch2, "blocks.xml", .{
        .patch_file_name = "main.xml",
        .patch_file_dir = sub,
    });
    defer std.testing.allocator.free(out2);
    try std.testing.expectEqualStrings(base, out2);
}

test "a patch root that is not <configs> is a container, not an op" {
    // Stock walks the root element's children, so the root tag is irrelevant:
    // 0-SCore ships `<SCore name="XUi_Common/styles.xml">` and zdtd used to
    // fail the whole load on it.
    const base =
        \\<blocks>
        \\<block name="terrStone" maxdamage="500" />
        \\</blocks>
    ;
    const patch =
        \\<SCore name="XUi_Common/styles.xml">
        \\  <set xpath="/blocks/block[@name='terrStone']/@maxdamage">9</set>
        \\</SCore>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "maxdamage=\"9\"") != null);
}

test "a known op with no xpath abandons the file instead of the boot" {
    // Stock raises XmlPatchException here; LoadAndPatchConfig catches it, so
    // the one patch file is dropped and the boot continues.
    const base = "<blocks><block name=\"terrStone\" maxdamage=\"500\" /></blocks>";
    const patch =
        \\<configs>
        \\  <set xpath="/blocks/block[@name='terrStone']/@maxdamage">9</set>
        \\  <set>10</set>
        \\  <set xpath="/blocks/block[@name='terrStone']/@maxdamage">11</set>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    // Ops before the malformed element are applied; the ones after are not.
    try std.testing.expect(std.mem.find(u8, out, "maxdamage=\"9\"") != null);
    try std.testing.expect(std.mem.find(u8, out, "maxdamage=\"11\"") == null);
}

test "element-existence predicates and last() resolve the real modlet xpaths" {
    // Three xpaths that the installed SphereII/0-SCore corpus uses and the
    // subset used to reject (silently, before the logging change):
    //   /blocks/block[property[@name='Tags' and @value='treasureHunter']]
    //   //item_modifier/effect_group[passive_effect]
    //   /entitygroups/entitygroup[last()]
    const base =
        \\<blocks>
        \\<block name="a"><property name="Tags" value="treasureHunter"/></block>
        \\<block name="b"><property name="Tags" value="other"/></block>
        \\</blocks>
    ;
    const patch =
        \\<configs>
        \\  <set xpath="/blocks/block[property[@name='Tags' and @value='treasureHunter']]/@name">hit</set>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "name=\"hit\"") != null);
    // The non-matching sibling keeps its name.
    try std.testing.expect(std.mem.find(u8, out, "name=\"b\"") != null);

    // `[passive_effect]`: existence of a child element, evaluated on the
    // candidate's body.
    const mod_base =
        \\<item_modifiers>
        \\<item_modifier name="m1"><effect_group><passive_effect name="DamageModifier"/></effect_group></item_modifier>
        \\<item_modifier name="m2"><effect_group/></item_modifier>
        \\</item_modifiers>
    ;
    const mod_patch =
        \\<configs>
        \\  <set xpath="//item_modifier/effect_group[passive_effect]/@name">hit</set>
        \\</configs>
    ;
    // Routed by the patch file name, as production does (`<mod>/Config/
    // item_modifiers.xml`); the xpath root `<item_modifier>` is the singular
    // form the file itself uses.
    const mod_out = try applyPatchDoc(std.testing.allocator, mod_base, mod_patch, "item_modifiers.xml", .{
        .patch_file_name = "item_modifiers.xml",
    });
    defer std.testing.allocator.free(mod_out);
    try std.testing.expect(std.mem.find(u8, mod_out, "name=\"hit\"") != null);

    // `[last()]` selects the final match of the path.
    const grp_base =
        \\<entitygroups>
        \\<entitygroup name="g1"/>
        \\<entitygroup name="g2"/>
        \\</entitygroups>
    ;
    const grp_patch =
        \\<configs>
        \\  <set xpath="/entitygroups/entitygroup[last()]/@name">last</set>
        \\</configs>
    ;
    const grp_out = try applyPatchDoc(std.testing.allocator, grp_base, grp_patch, "entitygroups.xml", .{});
    defer std.testing.allocator.free(grp_out);
    try std.testing.expect(std.mem.find(u8, grp_out, "name=\"last\"") != null);
    try std.testing.expect(std.mem.find(u8, grp_out, "name=\"g1\"") != null);
}

test "conditional evaluates version() comparisons and xpath() existence" {
    // The two expressions the installed 0-SCore / SphereII corpus uses:
    //   cond="mod_version('0-SCore_sphereii') &gt;= version(1,0,81,1048)"
    //   cond="xpath('//entity_class[starts-with(@name, &quot;vehicle&quot;)]/property[@name=&quot;Buffs&quot;]') != null"
    // Both used to be skipped as "not evaluable", dropping their patch blocks.
    const base =
        \\<blocks>
        \\<block name="a" Buffs="yes"/>
        \\</blocks>
    ;
    const with_buffs =
        \\<configs>
        \\  <conditional>
        \\    <if cond="xpath('/blocks/block[@name=&quot;a&quot;]/@Buffs') != null">
        \\      <set xpath="/blocks/block[@name='a']/@Buffs">hit</set>
        \\    </if>
        \\    <else>
        \\      <set xpath="/blocks/block[@name='a']/@Buffs">miss</set>
        \\    </else>
        \\  </conditional>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, with_buffs, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "Buffs=\"hit\"") != null);

    // `!= null` takes the else branch when the node is absent.
    const absent =
        \\<configs>
        \\  <conditional>
        \\    <if cond="xpath('/blocks/block[@name=&quot;zzz&quot;]') != null">
        \\      <set xpath="/blocks/block[@name='a']/@Buffs">hit</set>
        \\    </if>
        \\    <else>
        \\      <set xpath="/blocks/block[@name='a']/@Buffs">miss</set>
        \\    </else>
        \\  </conditional>
        \\</configs>
    ;
    const out2 = try applyPatchDoc(std.testing.allocator, base, absent, "blocks.xml", .{});
    defer std.testing.allocator.free(out2);
    try std.testing.expect(std.mem.find(u8, out2, "Buffs=\"miss\"") != null);

    // The corpus form nests a call inside xpath(): the closing paren must be
    // the matching one, not the first `)` (which closes `starts-with(...)`).
    const nested =
        \\<configs>
        \\  <conditional>
        \\    <if cond="xpath('//block[starts-with(@name, &quot;a&quot;)]/property[@name=&quot;Tags&quot;]') != null">
        \\      <set xpath="/blocks/block[@name='a']/@Buffs">hit</set>
        \\    </if>
        \\  </conditional>
        \\</configs>
    ;
    const nested_base =
        \\<blocks>
        \\<block name="a"><property name="Tags" value="x"/></block>
        \\</blocks>
    ;
    const out_nested = try applyPatchDoc(std.testing.allocator, nested_base, nested, "blocks.xml", .{});
    defer std.testing.allocator.free(out_nested);
    try std.testing.expect(std.mem.find(u8, out_nested, "Buffs=\"hit\"") != null);

    // version(): a mod that is not installed compares as 0.0.0.0, so
    // `>= version(1,0,0,0)` is false and the else branch wins. The escaped
    // `&gt;=` must be decoded for the comparison to be seen at all.
    const ver_patch =
        \\<configs>
        \\  <conditional>
        \\    <if cond="mod_version('no_such_mod') &gt;= version(1,0,0,0)">
        \\      <set xpath="/blocks/block[@name='a']/@Buffs">hit</set>
        \\    </if>
        \\    <else>
        \\      <set xpath="/blocks/block[@name='a']/@Buffs">miss</set>
        \\    </else>
        \\  </conditional>
        \\</configs>
    ;
    const out3 = try applyPatchDoc(std.testing.allocator, base, ver_patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out3);
    try std.testing.expect(std.mem.find(u8, out3, "Buffs=\"miss\"") != null);
}
