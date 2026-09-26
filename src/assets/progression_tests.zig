//! Progression catalog tests: perks, skills, requirements.
//!
//! Split out of assets/progression.zig (same tests, moved verbatim).

const std = @import("std");
const test_tmp = @import("../util/test_tmp.zig");
const progression = @import("progression.zig");
const buffs = @import("buffs.zig");
const cvars = @import("cvars.zig");
const requirements = @import("requirements.zig");
const xml = @import("xml_util.zig");
const stock_paths = @import("../util/stock_paths.zig");
const io_fs = @import("../util/io_fs.zig");
const AttrDef = progression.AttrDef;
const CraftingSkill = progression.CraftingSkill;
const LevelCurve = progression.LevelCurve;
const PerkDef = progression.PerkDef;
const SkillLevel = progression.SkillLevel;
const Table = progression.Table;
const loadTableFromPath = progression.loadTableFromPath;
const max_passives_per_def = progression.max_passives_per_def;
const perkTotals = progression.perkTotals;
const unlockRequirement = progression.unlockRequirement;

test "expForLevel matches stock GetExpForNextLevel golden values" {
    // Stock defaults from progression.xml parse (10000 / 1.05 / clamp 60):
    // cost(L) = float32(10000 * Mathf.Pow(1.05f, min(L+1, 60))), truncated,
    // Math.Min(.., 2.147484e9f) then conv.i4 saturates at int.MaxValue.
    // Golden values computed independently in float32 (numpy), same as the
    // stock Single arithmetic (Progression.il.txt 1083482).
    const c: LevelCurve = .{};
    try std.testing.expectEqual(@as(u64, 10500), c.expForLevel(0));
    try std.testing.expectEqual(@as(u64, 11024), c.expForLevel(1));
    try std.testing.expectEqual(@as(u64, 11576), c.expForLevel(2));
    try std.testing.expectEqual(@as(u64, 17103), c.expForLevel(10));
    try std.testing.expectEqual(@as(u64, 177896), c.expForLevel(58));
    try std.testing.expectEqual(@as(u64, 186791), c.expForLevel(59));
    // Exponent clamps at ClampExpCostAtLevel=60: 60 and beyond are identical.
    try std.testing.expectEqual(@as(u64, 186791), c.expForLevel(60));
    try std.testing.expectEqual(@as(u64, 186791), c.expForLevel(299));
    try std.testing.expectEqual(@as(u64, 186791), c.expForLevel(300));
    // A degenerate clamp (0 = no clamp) uses max_level: far levels hit the
    // 2.147484e9f ceiling like stock's Math.Min.
    const noclamp: LevelCurve = .{ .clamp_exp_cost_at_level = 0 };
    try std.testing.expectEqual(@as(u64, 2082136064), noclamp.expForLevel(250));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(i32)), noclamp.expForLevel(251));

    // NaN multiplier fails closed to 0 instead of trapping float-to-int trunc.
    const nan_mult: LevelCurve = .{ .experience_multiplier = std.math.nan(f32) };
    try std.testing.expectEqual(@as(u64, 0), nan_mult.expForLevel(1));
    const zero_exp: LevelCurve = .{ .exp_to_level = 0 };
    try std.testing.expectEqual(@as(u64, 0), zero_exp.expForLevel(1));
}

test "load progression.xml when present" {
    const p = stock_paths.configFile("progression.xml");
    if (!io_fs.fileExists(p)) return error.SkipZigTest;
    var t = try loadTableFromPath(std.testing.allocator, p);
    defer t.deinit();
    try std.testing.expect(t.curve.loaded);
    try std.testing.expectEqual(@as(u16, 300), t.curve.max_level);
    try std.testing.expectEqual(@as(u32, 10000), t.curve.exp_to_level);
    try std.testing.expect(t.attributes.len >= 4);
    try std.testing.expect(t.perks.len > 10);
    try std.testing.expect(t.curve.expForLevel(1) >= t.curve.exp_to_level);
}

test "perk parent and per-attribute overrides parse from stock progression.xml" {
    // (a) each <perk> carries its own `parent` (a skill/attribute name); the
    // old walk-back resolved every perk to the file's last <attribute>.
    // (b) attBooks/attCrafting/attGeneralPerks carry their own
    // min_level/max_level/base_skill_point_cost overrides.
    const p = stock_paths.configFile("progression.xml");
    if (!io_fs.fileExists(p)) return error.SkipZigTest;
    var t = try loadTableFromPath(std.testing.allocator, p);
    defer t.deinit();

    // A combat perk: parent resolves to its skill, not the last attribute.
    var found_dead_eye = false;
    for (t.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkDeadEye")) {
            try std.testing.expectEqualStrings("skillPerceptionCombat", pk.parent_attr);
            found_dead_eye = true;
        }
    }
    try std.testing.expect(found_dead_eye);
    // The rest of the ladder resolves to their skills, not the last
    // attribute in the file.
    var skill_parents: usize = 0;
    for (t.perks) |pk| {
        if (std.mem.startsWith(u8, pk.parent_attr, "skill")) skill_parents += 1;
    }
    try std.testing.expect(skill_parents > 20);

    // Attribute overrides: attBooks is 0/0/0, the default rows stay 1/10/1.
    var att_books = false;
    var att_perception = false;
    for (t.attributes) |a| {
        if (std.mem.eql(u8, a.name, "attBooks")) {
            try std.testing.expectEqual(@as(u8, 0), a.min_level);
            try std.testing.expectEqual(@as(u8, 0), a.max_level);
            try std.testing.expectEqual(@as(u16, 0), a.base_cost);
            att_books = true;
        }
        if (std.mem.eql(u8, a.name, "attPerception")) {
            try std.testing.expectEqual(@as(u8, 1), a.min_level);
            try std.testing.expectEqual(@as(u16, 1), a.base_cost);
            att_perception = true;
        }
    }
    try std.testing.expect(att_books);
    try std.testing.expect(att_perception);
}

test "crafting skill unlock_entry gates parse and resolve tiers" {
    const path = stock_paths.configFile("progression.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadTableFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.crafting_skills.len >= 20);
    // The stone axe unlocks at craftingHarvestingTools tier 1 -> level 1
    // (display_entry unlock_levels "1,2,4,6,8,10").
    const req = unlockRequirement(&t, "meleeToolRepairT0StoneAxe").?;
    try std.testing.expectEqualStrings("craftingHarvestingTools", req[0]);
    try std.testing.expectEqual(@as(u8, 1), req[1]);
    // Ungated items (always_unlocked) have no requirement.
    try std.testing.expect(unlockRequirement(&t, "resourceWood") == null);
}

test "progression triggered rows parse (perkIntellectMastery bookworm cvar)" {
    // The writer for `$perkBookwormChance` is data: `perkIntellectMastery`'s
    // two `onSelfProgressionUpdate` rows set 25 at level >= 2 and 0 at level
    // <= 1. Without them the 63 loot RandomRoll gates that read the cvar can
    // only ever fail, so the parse is the first half of that behaviour.
    const path = stock_paths.configFile("progression.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadTableFromPath(std.testing.allocator, path);
    defer t.deinit();
    var mastery: ?PerkDef = null;
    for (t.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkIntellectMastery")) {
            mastery = pk;
            break;
        }
    }
    const m = mastery orelse return error.TestUnexpectedResult;
    var set_row: ?buffs.Triggered = null;
    var clear_row: ?buffs.Triggered = null;
    for (m.triggered) |tr| {
        if (!std.mem.eql(u8, tr.cvar, "$perkBookwormChance")) continue;
        try std.testing.expectEqual(buffs.Trigger.progression_update, tr.trigger);
        try std.testing.expectEqual(buffs.TriggeredAction.modify_cvar, tr.action);
        try std.testing.expectEqual(@as(usize, 1), tr.reqs.len);
        try std.testing.expectEqual(requirements.Kind.progression_level, tr.reqs[0].kind);
        try std.testing.expectEqualStrings("perkIntellectMastery", tr.reqs[0].arg);
        if (tr.value == 25) set_row = tr else clear_row = tr;
    }
    const sr = set_row orelse return error.TestUnexpectedResult;
    const cr = clear_row orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(cvars.Operation.set, sr.cvar_op);
    try std.testing.expectEqual(requirements.Compare.ge, sr.reqs[0].op);
    try std.testing.expectEqual(@as(f32, 2), sr.reqs[0].value);
    try std.testing.expectEqual(requirements.Compare.le, cr.reqs[0].op);
    try std.testing.expectEqual(@as(f32, 1), cr.reqs[0].value);
    // Stock keeps these rows on the perk body, not on attributes.
    for (t.attributes) |a| try std.testing.expectEqual(@as(usize, 0), a.triggered.len);
}

test "crafting-skill passive_effect rows parse (CraftingTier)" {
    // The 14 crafting skills carry `<effect_group>` rows: CraftingTier (91)
    // produce the crafted output's quality tier for the recipes whose tag set
    // carries the row's tag (the output item name), and RecipeTagUnlocked (73)
    // is the learn gate. Before this they were parsed as display/unlock entries
    // only, so a crafted item always came out at tier 1.
    const path = stock_paths.configFile("progression.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadTableFromPath(std.testing.allocator, path);
    defer t.deinit();
    var tier_rows: usize = 0;
    var skill: ?CraftingSkill = null;
    for (t.crafting_skills) |sk| {
        if (std.mem.eql(u8, sk.name, "craftingRepairTools")) skill = sk;
        for (sk.passives) |p| {
            if (std.mem.eql(u8, p.name, "CraftingTier")) tier_rows += 1;
        }
    }
    try std.testing.expect(tier_rows > 40);
    const sk = skill orelse return error.SkipZigTest;
    // Claw hammer row: base_add 1,2,3,4,5,5 at levels 8,12,16,20,25,50.
    var found = false;
    for (sk.passives) |p| {
        if (!std.mem.eql(u8, p.name, "CraftingTier")) continue;
        if (!std.mem.eql(u8, p.tags, "meleeToolRepairT1ClawHammer")) continue;
        found = true;
        try std.testing.expectEqual(buffs.Op.base_add, p.op);
        try std.testing.expectApproxEqAbs(@as(f32, 0), buffs.curveAtAxis(p, 7), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1), buffs.curveAtAxis(p, 8), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 3), buffs.curveAtAxis(p, 16), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 5), buffs.curveAtAxis(p, 50), 1e-4);
    }
    try std.testing.expect(found);
}

test "perk/attribute passive_effect rows parse (the 649-row surface)" {
    const path = stock_paths.configFile("progression.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadTableFromPath(std.testing.allocator, path);
    defer t.deinit();
    // Stock perk bodies carry passive rows (e.g. GeneralDamageResist on
    // toughness perks, BlockDamage on SexRex); the parse must not truncate.
    var total: usize = 0;
    var tracked_hits: usize = 0;
    var counts: requirements.Counts = .{};
    for (t.perks) |p| {
        total += p.passives.len;
        const d = buffs.trackedDeltasFrom(p.passives, .{}, &counts);
        if (d.general_resist != 0 or d.phys_resist != 0 or d.hp_max != 0 or d.stamina_ot != 0) tracked_hits += 1;
    }
    for (t.attributes) |a| total += a.passives.len;
    try std.testing.expect(total > 100); // the 649 rows are mostly in effect_groups; perk+attr bodies hold hundreds
    // A known tracked row: perkSexRex BlockDamage is untracked, but the
    // toughness-tree GeneralDamageResist rows land in the VM's resist delta.
    try std.testing.expect(tracked_hits > 0);
    // Level-scaled fold against the real XML: perkHealingFactor carries
    // HealthChangeOT .011,.022,.05,.1,.16 (per-second regen), so level 5
    // folds 0.16 hp/s and level 0 folds nothing.
    var heal: ?PerkDef = null;
    for (t.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkHealingFactor")) {
            heal = pk;
            break;
        }
    }
    if (heal) |h| {
        try std.testing.expect(h.passives.len > 0);
        // The row is gated `!HasBuff buffStatusHungry03,buffStatusThirsty03`;
        // with the buff catalog absent but no buffs active the gate is decided
        // (empty set) so the regen folds.
        try std.testing.expect(h.passives[0].reqs.len > 0);
        const d5 = buffs.trackedDeltasAt(h.passives, .{ .level = 5 }, .{}, &counts);
        try std.testing.expectApproxEqAbs(@as(f32, 0.16), d5.hp_ot, 0.0001);
        const d0 = buffs.trackedDeltasAt(h.passives, .{ .level = 0 }, .{}, &counts);
        try std.testing.expect(!d0.any());
        // Starving for water: the row must not fold at all.
        const starving_ids = [_]u16{3};
        const names = requirements.BuffNames{ .ctx = undefined, .resolve = struct {
            fn f(_: *const anyopaque, name: []const u8) ?u16 {
                return if (std.ascii.eqlIgnoreCase(name, "buffStatusThirsty03")) 3 else null;
            }
        }.f };
        const starving = buffs.trackedDeltasAt(h.passives, .{ .level = 5 }, .{
            .active_buffs = &starving_ids,
            .buff_names = &names,
        }, &counts);
        try std.testing.expectEqual(@as(f32, 0), starving.hp_ot);
    }
    // Explicit level= anchors: perkFortitudeMastery HealthMax is level="4,5"
    // value="50,100" - the fold applies nothing below level 4 (the old
    // implicit scaling would have given level 1 -> 50).
    var fort: ?PerkDef = null;
    for (t.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkFortitudeMastery")) {
            fort = pk;
            break;
        }
    }
    if (fort) |f2| {
        const d1 = buffs.trackedDeltasAt(f2.passives, .{ .level = 1 }, .{}, &counts);
        try std.testing.expectEqual(@as(f32, 0), d1.hp_max);
        const d5 = buffs.trackedDeltasAt(f2.passives, .{ .level = 5 }, .{}, &counts);
        try std.testing.expectApproxEqAbs(@as(f32, 100), d5.hp_max, 0.0001);
    }
    // `<book>` blocks parse into the same catalog: the Fireman's Almanac
    // Complete passives are InBiome-gated AND tags="running", so they fold only
    // for a running query in that biome (an untagged query never matches a
    // tagged row).
    var book: ?PerkDef = null;
    for (t.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkFiremansAlmanacComplete")) {
            book = pk;
            break;
        }
    }
    try std.testing.expect(book != null);
    const b = book.?;
    try std.testing.expectEqual(@as(u8, 1), b.max_level);
    try std.testing.expect(b.passives.len > 0);
    var in_biome = false;
    for (b.passives) |p| {
        if (std.mem.eql(u8, p.name, "StaminaChangeOT") and p.reqs.len > 0) in_biome = true;
    }
    try std.testing.expect(in_biome);
    try std.testing.expectEqual(@as(f32, 0), buffs.trackedDeltasAt(b.passives, .{ .level = 1 }, .{ .biome_id = 1, .tags = "running" }, &counts).stamina_ot);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), buffs.trackedDeltasAt(b.passives, .{ .level = 1 }, .{ .biome_id = 8, .tags = "running" }, &counts).stamina_ot, 0.0001);
    // The same biome with an untagged query folds nothing: the row is tagged.
    try std.testing.expectEqual(@as(f32, 0), buffs.trackedDeltasAt(b.passives, .{ .level = 1 }, .{ .biome_id = 8 }, &counts).stamina_ot);
}

test "perkTotals folds purchased perk levels level-scaled and reverts" {
    const attrs = [_]AttrDef{.{ .name = "attFortitude", .max_level = 10 }};
    const perks = [_]PerkDef{
        .{
            .name = "perkHealingFactor",
            .max_level = 5,
            .parent_attr = "attFortitude",
            .passives = &.{.{ .name = "HealthChangeOT", .op = .base_add, .curve = .{ 0.011, 0.022, 0.05, 0.1, 0.16, 0, 0, 0 }, .curve_len = 5, .curve_levels = .{ 1, 2, 3, 4, 5, 0, 0, 0 }, .curve_levels_len = 5 }},
        },
        .{
            .name = "perkPackMule",
            .max_level = 5,
            .passives = &.{.{ .name = "GeneralDamageResist", .op = .base_add, .value = 1 }},
        },
    };
    const pt = Table{ .attributes = attrs[0..], .perks = perks[0..] };
    var counts: requirements.Counts = .{};
    // No purchases: no deltas.
    var levels = [_]SkillLevel{.{}} ** 4;
    try std.testing.expect(!perkTotals(&pt, &levels, .{}, &counts).any());
    // Healing Factor level 1: small regen; level 5: the full curve value.
    levels[0] = .{ .name = "perkHealingFactor", .level = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.011), perkTotals(&pt, &levels, .{}, &counts).hp_ot, 0.0001);
    levels[0].level = 5;
    levels[1] = .{ .name = "perkPackMule", .level = 3 };
    const t5 = perkTotals(&pt, &levels, .{}, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), t5.hp_ot, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), t5.general_resist, 0.0001);
    // Revertible: dropping the level drops its deltas exactly.
    levels[1].level = 0;
    const back = perkTotals(&pt, &levels, .{}, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, 0), back.general_resist, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), back.hp_ot, 0.0001);
    // Unknown names are ignored (fail closed).
    levels[0].name = "notAPerk";
    try std.testing.expect(!perkTotals(&pt, &levels, .{}, &counts).any());
    // The ProgressionLevel gate reads the same ledger the fold walks: a row
    // gated on its own progression name folds only once that level is held.
    const gated = [_]PerkDef{.{
        .name = "perkFortitudeMastery",
        .max_level = 5,
        .passives = &.{.{
            .name = "HealthMax",
            .op = .base_add,
            .curve = .{ 50, 100, 0, 0, 0, 0, 0, 0 },
            .curve_len = 2,
            .curve_levels = .{ 4, 5, 0, 0, 0, 0, 0, 0 },
            .curve_levels_len = 2,
            .reqs = &.{.{
                .kind = .progression_level,
                .op = .ge,
                .value = 1,
                .arg = "perkFortitudeMastery",
            }},
        }},
    }};
    const gt = Table{ .perks = gated[0..] };
    const held = [_]SkillLevel{.{ .name = "perkFortitudeMastery", .level = 5 }};
    const gate_ctx = requirements.Ctx{ .levels = &held };
    try std.testing.expectApproxEqAbs(@as(f32, 100), perkTotals(&gt, &held, gate_ctx, &counts).hp_max, 0.0001);
    // The gate blocks when the ctx ledger does not corroborate the folded
    // level (stock resolves the gate against the target's Progression, not
    // against the level the caller happens to fold at).
    try std.testing.expectEqual(@as(f32, 0), perkTotals(&gt, &held, .{
        .levels = &.{.{ .name = "other", .level = 1 }},
    }, &counts).hp_max);
}

test "effect_group and row requirements attach to the right passives" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/progression.xml", .{dir});
    try io_fs.writeFile(path,
        \\<progression>
        \\  <level max_level="10" exp_to_level="100" experience_multiplier="1.1" skill_points_per_level="1" clamp_exp_cost_at_level="5"/>
        \\  <attributes min_level="1" max_level="10" base_skill_point_cost="1" cost_multiplier_per_level="1"/>
        \\  <perks min_level="0" max_level="7" base_skill_point_cost="2" cost_multiplier_per_level="1.5">
        \\    <perk name="perkGated" max_level="5" parent="skillTest" override_cost="1,2">
        \\      <level_requirements level="1"><requirement name="ProgressionLevel" progression_name="attStrength" operation="GTE" value="1"/></level_requirements>
        \\      <level_requirements level="3"><requirement name="ProgressionLevel" progression_name="attStrength" operation="GTE" value="5"/></level_requirements>
        \\      <effect_group>
        \\        <requirement name="InBiome" biome="8"/>
        \\        <passive_effect name="StaminaMax" operation="base_add" level="1" value="25"/>
        \\        <passive_effect name="HealthMax" operation="base_add" level="1" value="50">
        \\          <requirement name="!HasBuff" buff="buffBleeding"/>
        \\        </passive_effect>
        \\        <triggered_effect trigger="onSelfPrimaryActionEnd" action="ModifyStats" stat="Health" operation="add" value="1">
        \\          <requirement name="PlayerLevel" operation="GTE" value="1"/>
        \\        </triggered_effect>
        \\        <passive_effect name="FoodMax" operation="base_add" level="1" value="10"/>
        \\      </effect_group>
        \\      <effect_group>
        \\        <passive_effect name="WaterMax" operation="base_add" level="1" value="5"/>
        \\        <passive_effect name="HealthChangeOT" operation="base_add" duration="0,5" value="1,2"/>
        \\      </effect_group>
        \\    </perk>
        \\    <perk name="perkInherits" parent="skillTest"/>
        \\    <book name="perkBookTest" max_level="1" parent="skillTest">
        \\      <effect_group>
        \\        <requirement name="ProgressionLevel" progression_name="perkGated" operation="GTE" value="1"/>
        \\        <passive_effect name="HealthChangeOT" operation="base_add" level="1" value="0.5"/>
        \\      </effect_group>
        \\    </book>
        \\  </perks>
        \\</progression>
    );
    var t = try loadTableFromPath(std.testing.allocator, path);
    defer t.deinit();
    var perk: ?PerkDef = null;
    var book: ?PerkDef = null;
    for (t.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkGated")) perk = pk;
        if (std.mem.eql(u8, pk.name, "perkBookTest")) book = pk;
    }
    try std.testing.expect(perk != null and book != null);
    const p = perk.?;
    // Five passives over the two groups. The triggered_effect's requirement is
    // not a group gate and its row is not a passive.
    try std.testing.expectEqual(@as(usize, 5), p.passives.len);
    // StaminaMax: the group gate only.
    try std.testing.expectEqual(@as(usize, 1), p.passives[0].reqs.len);
    try std.testing.expectEqual(requirements.Kind.in_biome, p.passives[0].reqs[0].kind);
    // HealthMax: the group gate plus its own nested requirement.
    try std.testing.expectEqual(@as(usize, 2), p.passives[1].reqs.len);
    try std.testing.expectEqual(requirements.Kind.has_buff, p.passives[1].reqs[1].kind);
    try std.testing.expect(p.passives[1].reqs[1].negated);
    // FoodMax still takes the group gate.
    try std.testing.expectEqual(@as(usize, 1), p.passives[2].reqs.len);
    // WaterMax is in the second group, which has no requirement.
    try std.testing.expectEqual(@as(usize, 0), p.passives[3].reqs.len);
    // The second group's HealthChangeOT row carries only duration anchors.
    try std.testing.expectEqual(@as(usize, 0), p.passives[4].reqs.len);
    try std.testing.expectEqual(@as(u8, 2), p.passives[4].curve_levels_len);
    // The two `<level_requirements>` blocks parse onto the row, in file order,
    // with their own nested requirements.
    try std.testing.expectEqual(@as(usize, 2), p.level_reqs.len);
    try std.testing.expectEqual(@as(u8, 1), p.level_reqs[0].level);
    try std.testing.expectEqual(@as(u8, 3), p.level_reqs[1].level);
    try std.testing.expectEqual(@as(usize, 1), p.level_reqs[1].reqs.len);
    try std.testing.expectEqual(requirements.Kind.progression_level, p.level_reqs[1].reqs[0].kind);
    try std.testing.expectEqualStrings("attStrength", p.level_reqs[1].reqs[0].arg);
    try std.testing.expectEqual(@as(f32, 5), p.level_reqs[1].reqs[0].value);
    // `duration=` fills the same anchors as `level=` (the IL parses it second).
    // No stock progression row uses it, but a modded one must not fall into the
    // anchor-less branch.
    var dur_ok = false;
    for (p.passives) |pp| {
        if (std.mem.eql(u8, pp.name, "HealthChangeOT") and pp.curve_levels_len == 2) {
            dur_ok = true;
            try std.testing.expectApproxEqAbs(@as(f32, 5), pp.curve_levels[1], 0.001);
        }
    }
    try std.testing.expect(dur_ok);
    // No gates pass with an empty ledger, so nothing is purchasable; a
    // strength of 5 unlocks level 3.
    var ledger = [_]SkillLevel{.{ .name = "attStrength", .level = 4 }};
    try std.testing.expectEqual(@as(u8, 1), t.calculatedMaxLevel(&ledger, 1, "perkGated").?);
    ledger[0].level = 5;
    try std.testing.expectEqual(@as(u8, 3), t.calculatedMaxLevel(&ledger, 1, "perkGated").?);
    try std.testing.expectEqual(@as(u8, 0), t.calculatedMaxLevel(&.{}, 1, "perkGated").?);
    // The book has no level gates: its catalog max (1) is the answer, and the
    // row is flagged as a book so the purchase path can refuse it.
    try std.testing.expectEqual(@as(usize, 0), book.?.level_reqs.len);
    try std.testing.expect(book.?.book);
    try std.testing.expectEqual(@as(u8, 1), t.calculatedMaxLevel(&.{}, 1, "perkBookTest").?);
    try std.testing.expect(t.calculatedMaxLevel(&.{}, 1, "notACatalogRow") == null);
    // The row's own cost attributes and override table parse, and a row with
    // neither inherits the <perks> container's defaults (max_level 7 here).
    try std.testing.expectEqualSlices(u16, &.{ 1, 2 }, p.override_cost);
    try std.testing.expectEqual(@as(u16, 2), p.base_cost);
    try std.testing.expectEqual(@as(f32, 1.5), p.cost_mult);
    const inh = for (t.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkInherits")) break pk;
    } else return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u8, 7), inh.max_level);
    try std.testing.expectEqual(@as(usize, 0), inh.override_cost.len);
    try std.testing.expectEqual(@as(u16, 2), t.perk_base_cost);
    try std.testing.expectEqual(@as(f32, 1.5), t.perk_cost_mult);
    var counts: requirements.Counts = .{};
    const in8 = buffs.trackedDeltasAt(p.passives, .{ .level = 1 }, .{ .biome_id = 8 }, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, 25), in8.stamina_max, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), in8.hp_max, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), in8.food_max, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), in8.water_max, 0.0001);
    // Wrong biome: the gated rows drop, the ungated second group stays. The
    // single `level="1"` anchor applies at level 1 (not interpolated).
    const in1 = buffs.trackedDeltasAt(p.passives, .{ .level = 1 }, .{ .biome_id = 1 }, &counts);
    try std.testing.expectEqual(@as(f32, 0), in1.stamina_max);
    try std.testing.expectEqual(@as(f32, 0), in1.hp_max);
    try std.testing.expectEqual(@as(f32, 0), in1.food_max);
    try std.testing.expectApproxEqAbs(@as(f32, 5), in1.water_max, 0.0001);
    // The book row is gated on the perk's level, so it needs the ledger entry.
    const b = book.?;
    try std.testing.expectEqual(@as(usize, 1), b.passives.len);
    try std.testing.expectEqual(requirements.Kind.progression_level, b.passives[0].reqs[0].kind);
    const book_ledger = [_]requirements.NameLevel{.{ .name = "perkGated", .level = 1 }};
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), buffs.trackedDeltasAt(b.passives, .{ .level = 1 }, .{ .levels = &book_ledger }, &counts).hp_ot, 0.0001);
    try std.testing.expectEqual(@as(f32, 0), buffs.trackedDeltasAt(b.passives, .{ .level = 1 }, .{}, &counts).hp_ot);
}

test "a def stops at max_passives_per_def rows" {
    // The bound is a zdtd storage cap, not a stock rule; it must hold across
    // the effect_group walk (a group-at-a-time scan must not lose the per-row
    // check the flat scan had) or a pathological modded body grows the pool.
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "<progression><attributes min_level=\"1\" max_level=\"10\"/><perks><perk name=\"perkMany\" max_level=\"5\"><effect_group><requirement name=\"InBiome\" biome=\"8\"/>");
    var i: usize = 0;
    while (i < max_passives_per_def + 8) : (i += 1) {
        try buf.appendSlice(a, "<passive_effect name=\"StaminaMax\" operation=\"base_add\" level=\"1\" value=\"1\"/>");
    }
    try buf.appendSlice(a, "</effect_group></perk></perks></progression>");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/progression.xml", .{dir});
    try io_fs.writeFile(path, buf.items);
    var t = try loadTableFromPath(a, path);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.perks.len);
    try std.testing.expectEqual(max_passives_per_def, t.perks[0].passives.len);
    var counts: requirements.Counts = .{};
    const d = buffs.trackedDeltasAt(t.perks[0].passives, .{ .level = 1 }, .{ .biome_id = 8 }, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(max_passives_per_def)), d.stamina_max, 0.0001);
}

test "stock level_requirements parse and gate the calculated max level" {
    const path = stock_paths.configFile("progression.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadTableFromPath(std.testing.allocator, path);
    defer t.deinit();

    // attPerception carries ten level blocks, each gated on PlayerLevel >= 1,
    // so every attribute level is reachable from player level 1.
    var att: ?AttrDef = null;
    for (t.attributes) |a| {
        if (std.mem.eql(u8, a.name, "attPerception")) att = a;
    }
    try std.testing.expect(att != null);
    try std.testing.expectEqual(@as(usize, 10), att.?.level_reqs.len);
    try std.testing.expectEqual(@as(u8, 10), t.calculatedMaxLevel(&.{}, 1, "attPerception").?);
    try std.testing.expectEqual(@as(u8, 0), t.calculatedMaxLevel(&.{}, 0, "attPerception").?);

    // A perk ladder: perkPummelPete wants attStrength 1/3/5/7/10 for levels
    // 1..5, so the highest passing block is the purchasable level.
    const pummel = for (t.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkPummelPete")) break pk;
    } else return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 5), pummel.level_reqs.len);
    var lv = [_]SkillLevel{.{ .name = "attStrength", .level = 6 }};
    try std.testing.expectEqual(@as(u8, 3), t.calculatedMaxLevel(&lv, 1, "perkPummelPete").?);
    lv[0].level = 2;
    try std.testing.expectEqual(@as(u8, 1), t.calculatedMaxLevel(&lv, 1, "perkPummelPete").?);
    lv[0].level = 10;
    try std.testing.expectEqual(@as(u8, 5), t.calculatedMaxLevel(&lv, 1, "perkPummelPete").?);

    // Every book row is flagged and carries no level gates (books are
    // item-granted), and the whole level-gate vocabulary is ProgressionLevel
    // plus PlayerLevel, which is what the evaluator implements.
    var books: usize = 0;
    var prog: usize = 0;
    var player: usize = 0;
    for (t.perks) |pk| {
        if (pk.book) {
            books += 1;
            try std.testing.expectEqual(@as(usize, 0), pk.level_reqs.len);
        }
        for (pk.level_reqs) |lr| {
            for (lr.reqs) |r| {
                switch (r.kind) {
                    .progression_level => prog += 1,
                    .player_level => player += 1,
                    else => return error.UnexpectedRequirementKind,
                }
            }
        }
    }
    for (t.attributes) |a| {
        for (a.level_reqs) |lr| {
            for (lr.reqs) |r| {
                switch (r.kind) {
                    .progression_level => prog += 1,
                    .player_level => player += 1,
                    else => return error.UnexpectedRequirementKind,
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 152), books);
    try std.testing.expectEqual(@as(usize, 250), prog);
    try std.testing.expectEqual(@as(usize, 51), player);

    // Seven stock perks replace the cost curve with a per-level table, and
    // perkLuckyLooter takes its max_level from the <perks> container.
    const lucky = for (t.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkLuckyLooter")) break pk;
    } else return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u8, 5), lucky.max_level);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 2, 2, 3 }, lucky.override_cost);
    try std.testing.expectEqual(@as(u16, 1), t.perk_base_cost);
    try std.testing.expectEqual(@as(f32, 1.0), t.perk_cost_mult);
    var overrides: usize = 0;
    for (t.perks) |pk| {
        if (pk.override_cost.len > 0) overrides += 1;
    }
    try std.testing.expectEqual(@as(usize, 7), overrides);
}
