//! Buff catalog tests: folds, parses, loads, deltas, stages.
//!
//! Split out of assets/buffs.zig (same tests, moved verbatim).

const std = @import("std");
const buffs = @import("buffs.zig");
const Passive = buffs.Passive;
const Table = buffs.Table;
const loadFromPath = buffs.loadFromPath;
const tryLoad = buffs.tryLoad;
const lootProbFold = buffs.lootProbFold;
const playerExpGainFold = buffs.playerExpGainFold;
const namedPassiveFold = buffs.namedPassiveFold;
const requirements = @import("requirements.zig");
const BuffDef = buffs.BuffDef;
const builtin = buffs.builtin;
const curveValueAt = buffs.curveValueAt;
const io_fs = @import("../util/io_fs.zig");
const max_curve_len = buffs.max_curve_len;
const max_triggered_adds = buffs.max_triggered_adds;
const parseUpdateRateTicks = buffs.parseUpdateRateTicks;
const StackType = buffs.StackType;
const stageBuffName = buffs.stageBuffName;
const stagesFromWanted = buffs.stagesFromWanted;
const stock_paths = @import("../util/stock_paths.zig");
const Survival = buffs.Survival;
const tagsMatch = buffs.tagsMatch;
const Triggered = buffs.Triggered;
const trackedDeltasAt = buffs.trackedDeltasAt;
const parseStackType = buffs.parseStackType;
const default_update_rate_ticks = buffs.default_update_rate_ticks;
const builtin_defs = buffs.builtin_defs;
const components = @import("../ecs/components.zig");
const cvars = @import("cvars.zig");
const evaluateRows = buffs.evaluateRows;
const evaluateTriggered = buffs.evaluateTriggered;
const hpLossPerSecond = buffs.hpLossPerSecond;
const max_triggered_removes = buffs.max_triggered_removes;
const parseAnchors = buffs.parseAnchors;
const parseCurveLevels = buffs.parseCurveLevels;
const parseCurveValue = buffs.parseCurveValue;
const sandbox = @import("sandbox.zig");
const stageOfBuffName = buffs.stageOfBuffName;
const survival = buffs.survival;
const trackedDeltas = buffs.trackedDeltas;
const curveAt = buffs.curveAt;
const curveValueAtLevels = buffs.curveValueAtLevels;
const effectTotals = buffs.effectTotals;
const healthAddDelta = buffs.healthAddDelta;
const survivalStages = buffs.survivalStages;
const SurvivalStages = buffs.SurvivalStages;
const survivalCheckId = buffs.survivalCheckId;
const tracked_delta_max = buffs.tracked_delta_max;
const stage3HpLossPerSecond = buffs.stage3HpLossPerSecond;

test "lootProbFold applies tagged LootProb rows in order" {
    // perkDeadEye shape: perc_add 2..10 over levels 1..5 with the entry's tag
    // in the query. Untagged queries and unmatched tags leave the base alone.
    const rows = [_]Passive{
        .{ .name = "LootProb", .op = .perc_add, .tags = "rifleSkill", .curve = .{ 2, 4, 6, 8, 10, 0, 0, 0 }, .curve_len = 5, .curve_levels = .{ 1, 2, 3, 4, 5, 0, 0, 0 }, .curve_levels_len = 5 },
        .{ .name = "LootProb", .op = .base_set, .value = 1, .tags = "" },
    };
    var counts: requirements.Counts = .{};
    const hit: requirements.Ctx = .{ .tags = "rifleSkill" };
    // base 0.5 -> perc_add 10% at level 5 -> 0.55, then the untagged base_set 1
    // (an untagged row matches any query) replaces it with 1.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), lootProbFold(&rows, .{ .level = 5 }, hit, 0.5, &counts), 1e-4);
    // Without the tag only the untagged row applies.
    const miss: requirements.Ctx = .{ .tags = "shotgunSkill" };
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), lootProbFold(&rows, .{ .level = 5 }, miss, 0.5, &counts), 1e-4);
    // Level 0 (not purchased) short-circuits before any row.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), lootProbFold(&rows, .{ .level = 0 }, hit, 0.5, &counts), 1e-4);
    // A perc-only list scales the base: 0.5 * 1.02 = 0.51 at level 1.
    const perc_only = [_]Passive{rows[0]};
    try std.testing.expectApproxEqAbs(@as(f32, 0.51), lootProbFold(&perc_only, .{ .level = 1 }, hit, 0.5, &counts), 1e-4);
}

test "playerExpGainFold uses fraction perc_add not percent" {
    // Stock MotherLode / miner shape: Harvesting perc_add -.1..-.4 (penalty) or
    // Kill/medical fraction bonuses. Unlike LootProb, perc_add is `1+v`.
    const rows = [_]Passive{
        .{ .name = "PlayerExpGain", .op = .perc_add, .tags = "Harvesting", .curve = .{ -0.1, -0.2, -0.3, -0.4, 0, 0, 0, 0 }, .curve_len = 4, .curve_levels = .{ 1, 2, 3, 4, 0, 0, 0, 0 }, .curve_levels_len = 4 },
        .{ .name = "PlayerExpGain", .op = .perc_add, .tags = "Kill", .value = 0.05 },
    };
    var counts: requirements.Counts = .{};
    const harvest: requirements.Ctx = .{ .tags = "Harvesting" };
    // base 100 -> perc_add -0.4 at level 4 -> 60
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), playerExpGainFold(&rows, .{ .level = 4 }, harvest, 100.0, &counts), 1e-4);
    // Kill tag only hits the Kill row: 100 * 1.05 = 105
    const kill: requirements.Ctx = .{ .tags = "Kill" };
    try std.testing.expectApproxEqAbs(@as(f32, 105.0), playerExpGainFold(&rows, .{ .level = 1 }, kill, 100.0, &counts), 1e-4);
    // Empty tags: tagged rows do not match
    const empty: requirements.Ctx = .{ .tags = "" };
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), playerExpGainFold(&rows, .{ .level = 4 }, empty, 100.0, &counts), 1e-4);
    // Level 0 short-circuit
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), playerExpGainFold(&rows, .{ .level = 0 }, harvest, 100.0, &counts), 1e-4);
}

test "namedPassiveFold scales GlobalGameStageModifier from base 1" {
    const rows = [_]Passive{
        .{ .name = "GlobalGameStageModifier", .op = .perc_add, .value = 0.5 },
        .{ .name = "GlobalLootStageModifier", .op = .perc_add, .value = 0.25 },
    };
    var counts: requirements.Counts = .{};
    const ctx: requirements.Ctx = .{};
    // 1 * 1.5 = 1.5
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), namedPassiveFold("GlobalGameStageModifier", &rows, .{ .level = 1 }, ctx, 1.0, &counts), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), namedPassiveFold("GlobalLootStageModifier", &rows, .{ .level = 1 }, ctx, 1.0, &counts), 1e-4);
    // wrong name leaves base alone
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), namedPassiveFold("BiomeGameStageModifier", &rows, .{ .level = 1 }, ctx, 1.0, &counts), 1e-4);
}

test "the quality axis evaluates item rows at the item's tier" {
    var counts: requirements.Counts = .{};
    // A single-segment row is level-independent (ModValue's `_levels == null`,
    // `_values.Length == 1` branch): it applies at any quality, including the 0
    // of an item with no quality tier (a plain shirt's flat row).
    var flat: Passive = .{ .name = "GeneralDamageResist", .op = .base_add, .curve_len = 1 };
    flat.curve[0] = 0.05;
    flat.value = 0.05;
    for ([_]u8{ 0, 1, 6 }) |q| {
        const d = trackedDeltasAt(&.{flat}, .{ .quality = .{ .level = q, .max = 6 } }, .{}, &counts);
        try std.testing.expectApproxEqAbs(@as(f32, 0.05), d.general_resist, 0.0001);
    }
    // Six values anchored by tier="1,2,3,4,5,6" (armorAthleticOutfit
    // HealthMax "2,4,6,8,10,20" at items.xml:14305): Q1 = 2, Q6 = 20.
    var curve: Passive = .{ .name = "HealthMax", .op = .base_add, .curve_len = 6, .curve_levels_len = 6 };
    curve.curve = .{ 2, 4, 6, 8, 10, 20, 0, 0 };
    curve.curve_levels = .{ 1, 2, 3, 4, 5, 6, 0, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 20), trackedDeltasAt(&.{curve}, .{ .quality = .{ .level = 6, .max = 6 } }, .{}, &counts).hp_max, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), trackedDeltasAt(&.{curve}, .{ .quality = .{ .level = 1, .max = 6 } }, .{}, &counts).hp_max, 0.001);
    // A no-quality item sits below the first anchor: nothing applies (stock
    // returns from ModValue without touching the value).
    try std.testing.expectEqual(@as(f32, 0), trackedDeltasAt(&.{curve}, .{ .quality = .{ .level = 0, .max = 6 } }, .{}, &counts).hp_max);
    // Two values anchored by tier="1,6" (the armor resist row
    // PhysicalDamageResist "8,12.3" at items.xml:13620): Q1 = 8, Q6 = 12.3.
    var pair: Passive = .{ .name = "PhysicalDamageResist", .op = .base_add, .curve_len = 2, .curve_levels_len = 2 };
    pair.curve = .{ 8, 12.3, 0, 0, 0, 0, 0, 0 };
    pair.curve_levels = .{ 1, 6, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 8), trackedDeltasAt(&.{pair}, .{ .quality = .{ .level = 1, .max = 6 } }, .{}, &counts).phys_resist, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 12.3), trackedDeltasAt(&.{pair}, .{ .quality = .{ .level = 6, .max = 6 } }, .{}, &counts).phys_resist, 0.001);
    // An anchor-less two-value row is stock's per-item roll
    // (PassiveEffect::ModValue IL_0427); the deterministic sim projects the
    // mean, so the old quality spread must not come back.
    var roll: Passive = .{ .name = "PhysicalDamageResist", .op = .base_add, .curve_len = 2 };
    roll.curve = .{ -0.2, 0.2, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0), trackedDeltasAt(&.{roll}, .{ .quality = .{ .level = 1, .max = 6 } }, .{}, &counts).phys_resist, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), trackedDeltasAt(&.{roll}, .{ .quality = .{ .level = 6, .max = 6 } }, .{}, &counts).phys_resist, 0.001);
    // Anchors come from `level=`, else `tier=`, else `duration=` in that order
    // (PassiveEffect::ParsePassiveEffect IL_01D3 / IL_026C / IL_0304), each
    // branch jumping past the attributes after it.
    const tier_row = "<passive_effect name=\"PhysicalDamageResist\" operation=\"base_add\" value=\"8,12.3\" tier=\"1,6\"/>";
    var tl: [max_curve_len]f32 = .{0} ** max_curve_len;
    try std.testing.expectEqual(@as(u8, 2), parseAnchors(tier_row, 0, &tl));
    try std.testing.expectApproxEqAbs(@as(f32, 1), tl[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 6), tl[1], 0.001);
    const all_three = "<passive_effect name=\"x\" value=\"1\" level=\"1,5\" tier=\"2,6\" duration=\"0,20\"/>";
    var al: [max_curve_len]f32 = .{0} ** max_curve_len;
    try std.testing.expectEqual(@as(u8, 2), parseAnchors(all_three, 0, &al));
    try std.testing.expectApproxEqAbs(@as(f32, 1), al[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), al[1], 0.001); // level=, not tier=/duration=
    const duration_row = "<passive_effect name=\"x\" value=\"1,5\" duration=\"0,3,60\"/>";
    var dl: [max_curve_len]f32 = .{0} ** max_curve_len;
    try std.testing.expectEqual(@as(u8, 3), parseAnchors(duration_row, 0, &dl));
    try std.testing.expectApproxEqAbs(@as(f32, 60), dl[2], 0.001);
}

test "stack_type parse is case-insensitive and falls back to ignore" {
    try std.testing.expectEqual(StackType.duration, parseStackType("Duration"));
    try std.testing.expectEqual(StackType.effect, parseStackType("EFFECT"));
    try std.testing.expectEqual(StackType.replace, parseStackType("replace"));
    // Absent or garbage keeps BuffClass::.ctor's Ignore default (asm.il 732691).
    try std.testing.expectEqual(StackType.ignore, parseStackType(""));
    try std.testing.expectEqual(StackType.ignore, parseStackType("stacked"));
}

test "update_rate seconds convert to stock UpdateRateTicks" {
    try std.testing.expectEqual(@as(i32, 20), parseUpdateRateTicks("1"));
    try std.testing.expectEqual(@as(i32, 10), parseUpdateRateTicks(".5"));
    try std.testing.expectEqual(@as(i32, 44), parseUpdateRateTicks("2.217")); // truncating conv.i4
    // Absent / unparsable keeps the 20-tick default.
    try std.testing.expectEqual(default_update_rate_ticks, parseUpdateRateTicks(""));
    try std.testing.expectEqual(default_update_rate_ticks, parseUpdateRateTicks("fast"));
    // Zero and negative rates cannot count down; stock stores them as-is (fires every tick).
    try std.testing.expectEqual(@as(i32, 0), parseUpdateRateTicks("0"));
    try std.testing.expectEqual(@as(i32, 0), parseUpdateRateTicks("-3"));
}

test "builtin catalog resolves by name case-insensitively" {
    var t = builtin();
    defer t.deinit();
    const id = t.indexOfName("BUFFSHOCKED").?;
    const d = t.byId(id).?;
    try std.testing.expectEqualStrings("buffShocked", d.name);
    try std.testing.expectEqual(StackType.duration, d.stack_type);
    try std.testing.expectEqual(@as(f32, 4), d.duration);
    try std.testing.expect(d.remove_on_death);
    try std.testing.expect(t.indexOfName("buffNotInCatalog") == null);
    try std.testing.expect(t.byId(@intCast(builtin_defs.len)) == null);
    // buffHarvest survives death (stock hidden console buff).
    try std.testing.expect(!t.byName("buffHarvest").?.remove_on_death);
}

test "parsed buff fields: stack, duration, update rate, remove_on_death" {
    const xml_src =
        \\<buffs>
        \\<buff name="buffShocked">
        \\<stack_type value="duration"/>
        \\<duration value="4"/>
        \\<update_rate value="1"/>
        \\</buff>
        \\<buff name="buffHarvest" hidden="true" remove_on_death="false">
        \\<stack_type value="effect"/>
        \\<duration value="0"/>
        \\<passive_effect name="HarvestCount" operation="perc_add" value="0.5"/>
        \\</buff>
        \\<buff name="buffNoStack"/>
        \\</buffs>
    ;
    const path = "worlds/zdtd_buffs_parse.xml";
    io_fs.mkdirPath("worlds");
    try io_fs.writeFile(path, xml_src);
    defer io_fs.deleteFile(path);

    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 3), t.defs.len);

    const shocked = t.byName("buffShocked").?;
    try std.testing.expectEqual(StackType.duration, shocked.stack_type);
    try std.testing.expectEqual(@as(f32, 4), shocked.duration);
    try std.testing.expectEqual(@as(i32, 20), shocked.update_rate_ticks);
    try std.testing.expect(shocked.remove_on_death);

    const harvest = t.byName("buffHarvest").?;
    try std.testing.expectEqual(StackType.effect, harvest.stack_type);
    try std.testing.expect(!harvest.remove_on_death);
    try std.testing.expectEqual(@as(usize, 1), harvest.passives.len);
    try std.testing.expectEqual(@as(f32, 0.5), t.passiveValue("buffHarvest", "HarvestCount").?);

    // No stack_type element at all: Ignore, not Replace (73 stock buffs rely on this).
    const nostack = t.byName("buffNoStack").?;
    try std.testing.expectEqual(StackType.ignore, nostack.stack_type);
    try std.testing.expectEqual(default_update_rate_ticks, nostack.update_rate_ticks);
}

/// Test-local name resolver for `requirements.BuffNames` (the same shape the
/// server's per-tick lookup uses).
const TestNames = struct {
    table: *const Table,
    fn resolve(ctx: *const anyopaque, name: []const u8) ?u16 {
        const self: *const TestNames = @ptrCast(@alignCast(ctx));
        return self.table.indexOfName(name);
    }
};

test "an AddBuff row is visible to a later row's HasBuff gate" {
    // Stock applies AddBuff as the row passes, so the stage rows' chains work
    // (each stage's onSelfBuffStart removes the others, and the highest stage
    // added wins). The engine records the request either way; with a sink and a
    // live lookup the later gate sees it in the same pass.
    const xml_src =
        \\<buffs>
        \\<buff name="check">
        \\<effect_group>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="AddBuff" buff="first"/>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="AddBuff" buff="second">
        \\<requirement name="HasBuff" buff="first"/>
        \\</triggered_effect>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="AddBuff" buff="third">
        \\<requirement name="!HasBuff" buff="first"/>
        \\</triggered_effect>
        \\</effect_group>
        \\</buff>
        \\<buff name="first"/><buff name="second"/><buff name="third"/>
        \\</buffs>
    ;
    const path = "worlds/zdtd_buffs_live.xml";
    io_fs.mkdirPath("worlds");
    try io_fs.writeFile(path, xml_src);
    defer io_fs.deleteFile(path);
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const cid = t.indexOfName("check").?;
    var counts: requirements.Counts = .{};
    // Record only: the snapshot cannot show the add, so "second" is not
    // requested and "third" is.
    const plain = evaluateTriggered(&t, cid, .update, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 2), plain.add_n);
    try std.testing.expectEqualStrings("first", plain.add_buffs[0]);
    try std.testing.expectEqualStrings("third", plain.add_buffs[1]);
    // Live: a sink applies "first" and the lookups see it.
    var active: [4]u16 = undefined;
    var active_n: usize = 0;
    const Live = struct {
        table: *const Table,
        ids: []u16,
        n: *usize,
        fn add(ctx: *const anyopaque, name: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(@constCast(ctx)));
            const id = self.table.indexOfName(name) orelse return;
            self.ids[self.n.*] = id;
            self.n.* += 1;
        }
        fn remove(ctx: *const anyopaque, name: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(@constCast(ctx)));
            const id = self.table.indexOfName(name) orelse return;
            var i: usize = 0;
            while (i < self.n.*) : (i += 1) {
                if (self.ids[i] != id) continue;
                var j = i;
                while (j + 1 < self.n.*) : (j += 1) self.ids[j] = self.ids[j + 1];
                self.n.* -= 1;
                return;
            }
        }
        fn has(ctx: *const anyopaque, name: []const u8) bool {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            const id = self.table.indexOfName(name) orelse return false;
            for (self.ids[0..self.n.*]) |a| if (a == id) return true;
            return false;
        }
    };
    var live = Live{ .table = &t, .ids = &active, .n = &active_n };
    const live_ctx = requirements.Ctx{
        .live_buff = &live,
        .buff_active = Live.has,
        .sink = .{ .ctx = &live, .add_buff = Live.add, .remove_buff = Live.remove },
    };
    const applied = evaluateTriggered(&t, cid, .update, live_ctx, &counts);
    // Row 2 now passes (`first` landed during the scan) and row 3 is refused by
    // `!HasBuff first`, which is the stock ordering the stage chain needs.
    try std.testing.expectEqual(@as(u8, 2), applied.add_n);
    try std.testing.expectEqualStrings("first", applied.add_buffs[0]);
    try std.testing.expectEqualStrings("second", applied.add_buffs[1]);
    // The sink ran in row order, so exactly those two are active.
    try std.testing.expectEqual(@as(usize, 2), active_n);
    try std.testing.expectEqual(t.indexOfName("first").?, active[0]);
    try std.testing.expectEqual(t.indexOfName("second").?, active[1]);
    try std.testing.expect(Live.has(&live, "first"));
    try std.testing.expect(Live.has(&live, "second"));
    try std.testing.expect(!Live.has(&live, "third"));
}

test "ModifyCVar applies in row order and a later row's gate sees it" {
    // Stock applies a ModifyCVar action as the row's requirements pass, so a
    // later row in the same pass reads the value an earlier row wrote
    // (check02's `.ArmorLightTotal` is `set @.ArmorLightLevel` then
    // `multiply @.ArmorLightWorn`, and the rows after it gate on the result).
    const xml_src =
        \\<buffs>
        \\<buff name="check">
        \\<effect_group>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="ModifyCVar" cvar=".total" operation="set" value="4"/>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="ModifyCVar" cvar=".total" operation="multiply" value="@.level"/>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="ModifyCVar" cvar=".count" operation="add" value="1"/>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="RemoveCVar" cvar=".gone"/>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="ModifyCVar" cvar=".rolled" operation="set" value="randomint(1,5)"/>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="AddBuff" buff="gated">
        \\<requirement name="CVarCompare" cvar=".total" operation="Equals" value="12"/>
        \\</triggered_effect>
        \\</effect_group>
        \\</buff>
        \\<buff name="gated"/>
        \\</buffs>
    ;
    const path = "worlds/zdtd_buffs_cvar.xml";
    io_fs.mkdirPath("worlds");
    try io_fs.writeFile(path, xml_src);
    defer io_fs.deleteFile(path);
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const cid = t.indexOfName("check").?;
    var store: cvars.Set = .{};
    _ = store.apply(".level", .set, 3);
    _ = store.apply(".gone", .set, 9);
    _ = store.apply(".rolled", .set, 7);
    var counts: requirements.Counts = .{};
    const r = evaluateTriggered(&t, cid, .update, .{ .cvars = &store }, &counts);
    // 4 * 3, with the multiply reading the value the set row just wrote.
    try std.testing.expectApproxEqAbs(@as(f32, 12), store.get(".total"), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), store.get(".count"), 0.0001);
    try std.testing.expectEqual(@as(f32, 0), store.get(".gone"));
    // The gated AddBuff row saw .total == 12 within the same pass.
    try std.testing.expectEqual(@as(u8, 1), r.add_n);
    try std.testing.expectEqualStrings("gated", r.add_buffs[0]);
    // A `randomint(...)` operand is not implemented: the row is refused, so the
    // sentinel survives instead of the row writing its unparsed 0.
    try std.testing.expectApproxEqAbs(@as(f32, 7), store.get(".rolled"), 0.0001);
    // Without a store the rows are gates-only and nothing is written.
    const no_store = evaluateTriggered(&t, cid, .update, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 0), no_store.add_n);
}

test "an effect_group gate applies to its triggered rows and its passives" {
    // Before this the parser read only bare `<requirement>` children: a
    // `<requirement_group op="or">` was skipped whole (turning the gate OFF), a
    // nested group ended its parent early (elementEnd matched the first close
    // tag), and a triggered row took no effect_group gate at all, so the row
    // fired with every branch false.
    const xml_src =
        \\<buffs>
        \\<buff name="check">
        \\<effect_group>
        \\<requirement_group op="or">
        \\<requirement name="HasBuff" buff="buffA"/>
        \\<requirement_group op="and">
        \\<requirement name="HasBuff" buff="buffB"/>
        \\<requirement name="IsAlive"/>
        \\</requirement_group>
        \\</requirement_group>
        \\<requirement name="HasBuff" buff="buffC"/>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="AddBuff" buff="target"/>
        \\</effect_group>
        \\<effect_group>
        \\<requirement name="HasBuff" buff="buffD"/>
        \\<passive_effect name="StaminaChangeOT" operation="base_add" value="0.5"/>
        \\</effect_group>
        \\</buff>
        \\<buff name="buffA"/><buff name="buffB"/><buff name="buffC"/><buff name="buffD"/><buff name="target"/>
        \\</buffs>
    ;
    const path = "worlds/zdtd_buffs_group.xml";
    io_fs.mkdirPath("worlds");
    try io_fs.writeFile(path, xml_src);
    defer io_fs.deleteFile(path);
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    // Every consecutive self-closing `<buff/>` loads (the walk used to resume
    // one char late and drop every second one).
    try std.testing.expectEqual(@as(usize, 6), t.defs.len);
    const cid = t.indexOfName("check").?;
    const a_id = t.indexOfName("buffA").?;
    const b_id = t.indexOfName("buffB").?;
    const c_id = t.indexOfName("buffC").?;
    const d_id = t.indexOfName("buffD").?;
    const names = requirements.BuffNames{ .ctx = &TestNames{ .table = &t }, .resolve = TestNames.resolve };
    var counts: requirements.Counts = .{};
    // The effect_group gate is (A or (B and alive)) AND C.
    const none = evaluateTriggered(&t, cid, .update, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 0), none.add_n);
    const with_a = evaluateTriggered(&t, cid, .update, .{ .active_buffs = &.{a_id}, .buff_names = &names }, &counts);
    try std.testing.expectEqual(@as(u8, 0), with_a.add_n);
    const with_c = evaluateTriggered(&t, cid, .update, .{ .active_buffs = &.{c_id}, .buff_names = &names }, &counts);
    try std.testing.expectEqual(@as(u8, 0), with_c.add_n);
    const with_ac = evaluateTriggered(&t, cid, .update, .{ .active_buffs = &.{ a_id, c_id }, .buff_names = &names }, &counts);
    try std.testing.expectEqual(@as(u8, 1), with_ac.add_n);
    try std.testing.expectEqualStrings("target", with_ac.add_buffs[0]);
    const with_bc = evaluateTriggered(&t, cid, .update, .{ .active_buffs = &.{ b_id, c_id }, .buff_names = &names }, &counts);
    try std.testing.expectEqual(@as(u8, 1), with_bc.add_n);
    // The nested AND still needs IsAlive.
    const with_bc_dead = evaluateTriggered(&t, cid, .update, .{ .active_buffs = &.{ b_id, c_id }, .buff_names = &names, .alive = false }, &counts);
    try std.testing.expectEqual(@as(u8, 0), with_bc_dead.add_n);
    // The passive in the second group folds only under that group's gate.
    var set: components.BuffSet = .{};
    set.slots[0] = .{ .active = true, .def_id = cid };
    try std.testing.expectApproxEqAbs(@as(f32, 0), effectTotals(&t, &set, .{}, &counts).stamina_ot, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), effectTotals(&t, &set, .{
        .active_buffs = &.{d_id},
        .buff_names = &names,
    }, &counts).stamina_ot, 0.0001);
}

test "load buffs.xml when present" {
    const p = stock_paths.configFile("buffs.xml");
    if (!io_fs.fileExists(p)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, p);
    defer t.deinit();
    try std.testing.expect(t.defs.len > 10);
    try std.testing.expect(t.passive_pool.len > 0);
}

test "survival numbers resolve from the shipped buffs.xml" {
    const gd = stock_paths.dedicated_server;
    var t = (tryLoad(std.testing.allocator, gd, null) catch null) orelse return error.SkipZigTest;
    defer t.deinit();
    const sv = survival(&t);
    try std.testing.expect(sv.ok());
    // buffStatusCheck01 gates: Food <= .5 / .25 / .02 of max.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sv.hungry_frac[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), sv.hungry_frac[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.02), sv.hungry_frac[2], 0.001);
    try std.testing.expect(sv.thirsty_frac[0] > 0);
    // buffStatusHungry03: ModifyStats Health subtract .25 per update.
    try std.testing.expect(sv.starve_hp_per_s > 0);
    try std.testing.expect(sv.dehydrate_hp_per_s > 0);
    // The VM folds the real rows: Hungry03's StaminaChangeOT perc_subtract
    // lands in the tracked deltas and its stage-3 Health loss rate reads off
    // the def.
    const h3 = t.byName("buffStatusHungry03").?;
    var counts: requirements.Counts = .{};
    const d3 = trackedDeltas(&h3, 1, .{}, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, -0.1), d3.stamina_ot, 0.001);
    try std.testing.expectApproxEqAbs(sv.starve_hp_per_s, hpLossPerSecond(&h3), 0.0001);
    // A starved player resolves to stage 3 for both bars.
    var hh: components.Health = .{ .food_max = 100, .water_max = 100, .food = 1, .water = 1 };
    const st = survivalStages(sv, &hh);
    try std.testing.expectEqual(@as(u8, 3), st.hungry);
    try std.testing.expectEqual(@as(u8, 3), st.thirsty);
    // The triggered engine selects the same stage from check01's update rows
    // (the raw result also carries check01's other update AddBuff rows, so
    // assert the survival-relevant selection via stagesFromWanted).
    const cid = survivalCheckId(&t).?;
    var tc3: requirements.Counts = .{};
    const well = evaluateTriggered(&t, cid, .update, .{ .food_frac = 0.6, .water_frac = 0.6, .food_max = 100, .water_max = 100 }, &tc3);
    const well_st = stagesFromWanted(well.add_buffs[0..well.add_n]);
    try std.testing.expectEqual(@as(u8, 0), well_st.hungry);
    try std.testing.expectEqual(@as(u8, 0), well_st.thirsty);
    const mid = evaluateTriggered(&t, cid, .update, .{ .food_frac = 0.4, .water_frac = 0.01, .food_max = 100, .water_max = 100 }, &tc3);
    const mid_st = stagesFromWanted(mid.add_buffs[0..mid.add_n]);
    try std.testing.expectEqual(@as(u8, 1), mid_st.hungry);
    try std.testing.expectEqual(@as(u8, 3), mid_st.thirsty);
}

test "an empty table resolves to not-ok rather than to zeros that look real" {
    var t = builtin();
    defer t.deinit();
    const sv = survival(&t);
    try std.testing.expect(!sv.ok());
}

test "trackedDeltas folds the tracked surface, omits base_set and untracked names" {
    const def = BuffDef{
        .name = "testBuff",
        .passives = &.{
            .{ .name = "HealthChangeOT", .op = .base_add, .value = 2 },
            .{ .name = "StaminaChangeOT", .op = .perc_subtract, .value = 0.1 },
            .{ .name = "PhysicalDamageResist", .op = .base_add, .value = 8 },
            .{ .name = "GeneralDamageResist", .op = .base_subtract, .value = 3 },
            .{ .name = "HealthMax", .op = .base_set, .value = 150 }, // no base -> omitted
            .{ .name = "HarvestCount", .op = .base_add, .value = 3 }, // untracked
            .{ .name = "HealthMaxBlockage", .op = .base_add, .value = 12 },
            .{ .name = "StaminaMaxBlockage", .op = .base_add, .value = 7 },
        },
    };
    var counts: requirements.Counts = .{};
    const d = trackedDeltas(&def, 1, .{}, &counts);
    try std.testing.expectEqual(@as(f32, 2), d.hp_ot);
    try std.testing.expectEqual(@as(f32, -0.1), d.stamina_ot);
    try std.testing.expectEqual(@as(f32, 8), d.phys_resist);
    try std.testing.expectEqual(@as(f32, -3), d.general_resist);
    try std.testing.expectEqual(@as(f32, 0), d.hp_max); // base_set omitted
    try std.testing.expectEqual(@as(f32, 12), d.hp_block);
    try std.testing.expectEqual(@as(f32, 7), d.stamina_block);
    try std.testing.expect(d.any());
}

test "effectTotals sums active buffs and reverts exactly on removal" {
    const def = BuffDef{
        .name = "testBuff",
        .passives = &.{
            .{ .name = "HealthChangeOT", .op = .base_add, .value = 2 },
            .{ .name = "StaminaMax", .op = .base_add, .value = 10 },
        },
    };
    const defs = [_]BuffDef{def};
    const t = Table{ .defs = defs[0..] };
    var set: components.BuffSet = .{};
    set.slots[0] = .{ .active = true, .def_id = 0 };
    var counts: requirements.Counts = .{};
    const one = effectTotals(&t, &set, .{}, &counts);
    try std.testing.expectEqual(@as(f32, 2), one.hp_ot);
    try std.testing.expectEqual(@as(f32, 10), one.stamina_max);
    // A second active slot of the same def doubles the sum (additive deltas).
    set.slots[1] = .{ .active = true, .def_id = 0 };
    const two = effectTotals(&t, &set, .{}, &counts);
    try std.testing.expectEqual(@as(f32, 4), two.hp_ot);
    try std.testing.expectEqual(@as(f32, 20), two.stamina_max);
    // Removal recomputes without it: reverts exactly (revertible effects).
    set.slots[1].active = false;
    const back = effectTotals(&t, &set, .{}, &counts);
    try std.testing.expectEqual(@as(f32, 2), back.hp_ot);
    try std.testing.expectEqual(@as(f32, 10), back.stamina_max);
    set.slots[0].active = false;
    try std.testing.expect(!effectTotals(&t, &set, .{}, &counts).any());
}

test "addDeltas clamps pathological curve values to the sanity ceiling" {
    // A modded passive value of 1e38 (or inf/nan) must not reach the tick's
    // @trunc casts; the fold saturates instead.
    const def = BuffDef{
        .name = "hugeBuff",
        .passives = &.{
            .{ .name = "HealthMax", .op = .base_add, .value = 1e38 },
            .{ .name = "HealthChangeOT", .op = .base_add, .value = std.math.inf(f32) },
        },
    };
    const defs = [_]BuffDef{def};
    const t = Table{ .defs = defs[0..] };
    var set: components.BuffSet = .{};
    set.slots[0] = .{ .active = true, .def_id = 0 };
    var counts: requirements.Counts = .{};
    const totals = effectTotals(&t, &set, .{}, &counts);
    try std.testing.expectEqual(tracked_delta_max, totals.hp_max);
    try std.testing.expectEqual(tracked_delta_max, totals.hp_ot);
    // NaN folds to 0 (fail closed), and a second huge buff still saturates.
    const def2 = BuffDef{
        .name = "nanBuff",
        .passives = &.{.{ .name = "StaminaMax", .op = .base_add, .value = std.math.nan(f32) }},
    };
    const defs2 = [_]BuffDef{ def, def2 };
    const t2 = Table{ .defs = defs2[0..] };
    set.slots[1] = .{ .active = true, .def_id = 1 };
    const t2totals = effectTotals(&t2, &set, .{}, &counts);
    try std.testing.expectEqual(@as(f32, 0), t2totals.stamina_max);
    try std.testing.expectEqual(tracked_delta_max, t2totals.hp_max);
}

test "survivalStages selects the stock stage thresholds (0.5 / 0.25 / 0.02)" {
    const sv = Survival{
        .hungry_frac = .{ 0.5, 0.25, 0.02 },
        .thirsty_frac = .{ 0.5, 0.25, 0.02 },
    };
    const expect = struct {
        fn stages(sv_in: Survival, food: f32, water: f32, want_h: u8, want_w: u8) !void {
            var hh: components.Health = .{ .food_max = 100, .water_max = 100, .food = food, .water = water };
            const s = survivalStages(sv_in, &hh);
            try std.testing.expectEqual(@as(u8, want_h), s.hungry);
            try std.testing.expectEqual(@as(u8, want_w), s.thirsty);
        }
    };
    try expect.stages(sv, 60, 60, 0, 0);
    try expect.stages(sv, 50, 50, 1, 1); // <= 0.5
    try expect.stages(sv, 25, 25, 2, 2); // <= 0.25
    try expect.stages(sv, 2, 2, 3, 3); // <= 0.02
    try expect.stages(sv, 1, 99, 3, 0);
}

test "hpLossPerSecond converts the ModifyStats Health row to a per-second rate" {
    const def = BuffDef{
        .name = "buffStatusHungry03",
        .update_rate_ticks = 44, // stock update_rate 2.2 s
        .stat_mods = &.{.{ .stat = "Health", .op = .base_subtract, .value = 0.25 }},
    };
    const per_s = hpLossPerSecond(&def);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25 / 2.2), per_s, 0.0001);
}

test "stageBuffName maps stages to the stock conditional buff names" {
    try std.testing.expectEqualStrings("buffStatusHungry01", stageBuffName(1, false).?);
    try std.testing.expectEqualStrings("buffStatusHungry02", stageBuffName(2, false).?);
    try std.testing.expectEqualStrings("buffStatusHungry03", stageBuffName(3, false).?);
    try std.testing.expectEqualStrings("buffStatusThirsty01", stageBuffName(1, true).?);
    try std.testing.expectEqualStrings("buffStatusThirsty03", stageBuffName(3, true).?);
    try std.testing.expect(stageBuffName(0, false) == null);
}

test "parseCurveValue fills per-level segments; curveAt clamps and levels" {
    var c: [max_curve_len]f32 = .{0} ** max_curve_len;
    const n = parseCurveValue(".011,.022,.05,.1,.16", &c);
    try std.testing.expectEqual(@as(u8, 5), n);
    try std.testing.expectApproxEqAbs(@as(f32, 0.011), c[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), c[4], 0.0001);
    const p = Passive{ .curve = c, .curve_len = n };
    // No `level=`/`duration=`: stock's ModValue applies one value flat, averages
    // two, and applies nothing for more, so this anchor-less 5-value row folds
    // nothing at any level.
    try std.testing.expectEqual(@as(f32, 0), curveAt(p, 1));
    try std.testing.expectEqual(@as(f32, 0), curveAt(p, 5));
    const anchored = Passive{
        .curve = c,
        .curve_len = n,
        .curve_levels = .{ 1, 2, 3, 4, 5, 0, 0, 0 },
        .curve_levels_len = 5,
    };
    try std.testing.expectApproxEqAbs(@as(f32, 0.011), curveAt(anchored, 1), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), curveAt(anchored, 4), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), curveAt(anchored, 5), 0.0001);
    try std.testing.expectEqual(@as(f32, 0), curveAt(anchored, 9)); // past the last anchor
    try std.testing.expectEqual(@as(f32, 0), curveAt(anchored, 0)); // unpurchased
    // A two-value anchor-less row applies the average (ModValue IL=3C4).
    const two = Passive{ .curve = .{ 2, 4, 0, 0, 0, 0, 0, 0 }, .curve_len = 2 };
    try std.testing.expectApproxEqAbs(@as(f32, 3), curveAt(two, 1), 0.0001);
    // Single-segment rows repeat the flat value.
    var c1: [max_curve_len]f32 = .{0} ** max_curve_len;
    _ = parseCurveValue("1.5", &c1);
    const p1 = Passive{ .curve = c1, .curve_len = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), curveAt(p1, 3), 0.0001);
}

test "trackedDeltasAt scales a perk curve to its level" {
    const passives = [_]Passive{
        .{ .name = "HealthChangeOT", .op = .base_add, .curve = .{ 0.011, 0.022, 0.05, 0.1, 0.16, 0, 0, 0 }, .curve_len = 5, .curve_levels = .{ 1, 2, 3, 4, 5, 0, 0, 0 }, .curve_levels_len = 5 },
        .{ .name = "GeneralDamageResist", .op = .base_add, .curve = .{ 0.05, 0.25, 0, 0, 0, 0, 0, 0 }, .curve_len = 2, .curve_levels = .{ 1, 5, 0, 0, 0, 0, 0, 0 }, .curve_levels_len = 2 },
    };
    var counts: requirements.Counts = .{};
    const l1 = trackedDeltasAt(&passives, .{ .level = 1 }, .{}, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, 0.011), l1.hp_ot, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), l1.general_resist, 0.0001);
    const l5 = trackedDeltasAt(&passives, .{ .level = 5 }, .{}, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), l5.hp_ot, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), l5.general_resist, 0.0001); // clamp
    const l0 = trackedDeltasAt(&passives, .{ .level = 0 }, .{}, &counts);
    try std.testing.expect(!l0.any());
}

test "a buff passive folds only under its effect_group requirement" {
    // buffCoffee carries StaminaChangeOT perc_add 0.2 gated
    // `!HasBuff buffHealWaterMax` and 0.1 gated `HasBuff buffHealWaterMax`.
    // Both folded before the buff parser honoured effect_group requirements, so
    // a coffee drinker got 0.3 instead of one of the two rows.
    const path = stock_paths.configFile("buffs.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const coffee = t.indexOfName("buffCoffee").?;
    var set: components.BuffSet = .{};
    set.slots[0] = .{ .active = true, .def_id = coffee };
    const names = requirements.BuffNames{ .ctx = undefined, .resolve = struct {
        fn f(_: *const anyopaque, name: []const u8) ?u16 {
            return if (std.ascii.eqlIgnoreCase(name, "buffHealWaterMax")) 7 else null;
        }
    }.f };
    var counts: requirements.Counts = .{};
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), effectTotals(&t, &set, .{}, &counts).stamina_ot, 0.0001);
    const active_ids = [_]u16{7};
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), effectTotals(&t, &set, .{
        .active_buffs = &active_ids,
        .buff_names = &names,
    }, &counts).stamina_ot, 0.0001);
}

test "SandboxOptionBool gates a passive on the decoded sandbox option" {
    // PlayerLevelBonusApplied is a stock YesNo option whose census default is
    // Yes (SandboxOptionManager IL, option 11), and it gates buffStatusCheck01's
    // four max-stat rows. The decoded code supplies the value when it carries
    // the option; index 0 is an explicit No.
    const passives = [_]Passive{.{
        .name = "HealthMax",
        .op = .base_add,
        .value = 50,
        .reqs = &.{.{
            .kind = .sandbox_option_bool,
            .name = "SandboxOptionBool",
            .arg = "PlayerLevelBonusApplied",
        }},
    }};
    var counts: requirements.Counts = .{};
    // No code: the stock default (Yes) lets the row apply.
    try std.testing.expectApproxEqAbs(@as(f32, 50), trackedDeltasAt(&passives, .{ .level = 1 }, .{}, &counts).hp_max, 0.0001);
    try std.testing.expectEqual(@as(u32, 1), counts.resolved);
    try std.testing.expectEqual(@as(u32, 0), counts.unsupported);
    // Code index 1 = Yes, index 0 = No (even though the default is Yes).
    const on = [_]sandbox.Group{.{ .option_id = sandbox.optionByName("PlayerLevelBonusApplied").?.id, .index = 1 }};
    try std.testing.expectApproxEqAbs(@as(f32, 50), trackedDeltasAt(&passives, .{ .level = 1 }, .{ .sandbox_groups = &on }, &counts).hp_max, 0.0001);
    const off = [_]sandbox.Group{.{ .option_id = sandbox.optionByName("PlayerLevelBonusApplied").?.id, .index = 0 }};
    try std.testing.expectEqual(@as(f32, 0), trackedDeltasAt(&passives, .{ .level = 1 }, .{ .sandbox_groups = &off }, &counts).hp_max);
}

test "the stock SandboxOptionBool gates resolve instead of refusing" {
    const path = stock_paths.configFile("buffs.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const check = t.byName("buffStatusCheck01").?;
    var counts: requirements.Counts = .{};
    // Four max-stat rows, each gated SandboxOptionBool PlayerLevelBonusApplied.
    // They fold 0 either way (the value is a CVar reference), so the counter is
    // what proves the gate resolved rather than failed closed.
    _ = trackedDeltasAt(check.passives, .{ .level = 1 }, .{}, &counts);
    try std.testing.expectEqual(@as(u32, 4), counts.resolved);
    try std.testing.expectEqual(@as(u32, 0), counts.unsupported);
}

test "duration-anchored buff rows ramp with the elapsed seconds" {
    // buffInternalBleeding carries HealthChangeOT base_subtract
    // duration="0,3,60" value="1,5,200": the bleed ramps from 1 to 5 hp/s over
    // the first 3 s and on to 200 hp/s by 60 s (ModValue interpolates between
    // the anchors), so the folded delta is negative. The parser used to read
    // only `level=`, so the row fell into the anchor-less branch and folded a
    // constant, and the fold had no duration axis at all.
    const path = stock_paths.configFile("buffs.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const b = t.byName("buffInternalBleeding").?;
    var counts: requirements.Counts = .{};
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), trackedDeltasAt(b.passives, .{ .duration = 0 }, .{}, &counts).hp_ot, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -5.0), trackedDeltasAt(b.passives, .{ .duration = 3 }, .{}, &counts).hp_ot, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -97.368), trackedDeltasAt(b.passives, .{ .duration = 30 }, .{}, &counts).hp_ot, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -200.0), trackedDeltasAt(b.passives, .{ .duration = 60 }, .{}, &counts).hp_ot, 0.01);
    // The duration anchors really parsed (not the implicit average).
    var found = false;
    for (b.passives) |p| {
        if (!std.mem.eql(u8, p.name, "HealthChangeOT") or p.curve_levels_len == 0) continue;
        found = true;
        try std.testing.expectApproxEqAbs(@as(f32, 3), p.curve_levels[1], 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 60), p.curve_levels[2], 0.001);
    }
    try std.testing.expect(found);
    // The buff fold feeds the elapsed ticks in: 600 ticks = 30 s, 40 ticks = 2 s.
    const bleeding = t.indexOfName("buffInternalBleeding").?;
    var set: components.BuffSet = .{};
    set.slots[0] = .{ .active = true, .def_id = bleeding, .duration_ticks = 600 };
    var counts2: requirements.Counts = .{};
    try std.testing.expectApproxEqAbs(@as(f32, -97.368), effectTotals(&t, &set, .{}, &counts2).hp_ot, 0.05);
    set.slots[0].duration_ticks = 40;
    try std.testing.expectApproxEqAbs(@as(f32, -3.667), effectTotals(&t, &set, .{}, &counts2).hp_ot, 0.01);
}

test "HoldingItemHasTags gates the hold-breath stamina rows" {
    // buffHoldBreathAiming01 has two untagged StaminaChangeOT rows whose curves
    // are anchored on `duration=` (`0,1 -> -.9,-1.6` and `1,9999 -> -1.6`), so
    // they are evaluated at the buff's elapsed seconds and only one applies at a
    // time, plus four rows gated `HoldingItemHasTags tags="perkDeadEye"` with
    // `ProgressionLevel Equals 3/4/5/1`. All four used to join the untagged sum
    // (+0.75) and before the duration axis both duration rows folded together.
    const path = stock_paths.configFile("buffs.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const p = t.byName("buffHoldBreathAiming01").?;
    var counts: requirements.Counts = .{};
    // t = 0 s: only the first duration segment is live.
    try std.testing.expectApproxEqAbs(@as(f32, -0.9), trackedDeltasAt(p.passives, .{ .duration = 0 }, .{}, &counts).stamina_ot, 0.0001);
    // t = 2 s: the second segment only, and the perk rows stay out of an empty hand.
    try std.testing.expectApproxEqAbs(@as(f32, -1.6), trackedDeltasAt(p.passives, .{ .duration = 2 }, .{}, &counts).stamina_ot, 0.0001);
    // perkDeadEye 5 in hand: the Equals-5 row joins (+0.3).
    const lv5 = [_]requirements.NameLevel{.{ .name = "perkDeadEye", .level = 5 }};
    try std.testing.expectApproxEqAbs(@as(f32, -1.3), trackedDeltasAt(p.passives, .{ .duration = 2 }, .{
        .held_tags = "T0,perkDeadEye",
        .levels = &lv5,
    }, &counts).stamina_ot, 0.0001);
    // perkDeadEye 3: the Equals-3 row joins (+0.1).
    const lv3 = [_]requirements.NameLevel{.{ .name = "perkDeadEye", .level = 3 }};
    try std.testing.expectApproxEqAbs(@as(f32, -1.5), trackedDeltasAt(p.passives, .{ .duration = 2 }, .{
        .held_tags = "T0,perkDeadEye",
        .levels = &lv3,
    }, &counts).stamina_ot, 0.0001);
    // A weapon without the perk tag still gets nothing.
    try std.testing.expectApproxEqAbs(@as(f32, -1.6), trackedDeltasAt(p.passives, .{ .duration = 2 }, .{
        .held_tags = "T0,axe",
        .levels = &lv5,
    }, &counts).stamina_ot, 0.0001);
}

test "an unworn armor group refuses every biker tier" {
    // buffBikerSetBonus's six PhysicalDamageResist rows are gated
    // `ArmorGroupLowestQuality group_name="groupBiker" Equals 1..6`. With no
    // armor worn the group reads quality 0 (the stock lookup's missing-key
    // branch), so every tier refuses. All six used to fold unconditionally, so
    // a bare player read 1+2+3+4+5+6 = 21.
    const path = stock_paths.configFile("buffs.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const biker = t.indexOfName("buffBikerSetBonus").?;
    var set: components.BuffSet = .{};
    set.slots[0] = .{ .active = true, .def_id = biker };
    var counts: requirements.Counts = .{};
    const totals = effectTotals(&t, &set, .{}, &counts);
    try std.testing.expectEqual(@as(f32, 0), totals.phys_resist);
    try std.testing.expectEqual(@as(u32, 6), counts.resolved);
    try std.testing.expectEqual(@as(u32, 0), counts.unsupported);
}

test "the stock coredamageresist armor rows fold only under the armor query" {
    // Equipment::GetTotalPhysicalArmorRating (IL=887) queries passive 41 with
    // the `coredamageresist` tag. The `god` buff carries both an untagged 200
    // point PhysicalDamageResist row and a `coredamageresist`-tagged one, so the
    // untagged query sees 200 and the armor query sees both (400); the tick's
    // armor leg must use the armor query.
    const path = stock_paths.configFile("buffs.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const god = t.indexOfName("god").?;
    var set: components.BuffSet = .{};
    set.slots[0] = .{ .active = true, .def_id = god };
    var counts: requirements.Counts = .{};
    try std.testing.expectApproxEqAbs(@as(f32, 200), effectTotals(&t, &set, .{}, &counts).phys_resist, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 400), effectTotals(&t, &set, .{ .tags = "coredamageresist" }, &counts).phys_resist, 0.001);
}

test "tagsMatch follows PassiveEffect::hasMatchingTag with the stock defaults" {
    // ctor: MatchAnyTags = true, InvertTagCheck = false; no shipped row sets
    // match_all_tags or invert_tag_check.
    try std.testing.expect(tagsMatch("", ""));
    try std.testing.expect(tagsMatch("", "running")); // untagged row matches anything
    try std.testing.expect(!tagsMatch("running", "")); // tagged row never matches untagged
    try std.testing.expect(tagsMatch("running", "running"));
    try std.testing.expect(tagsMatch("running", "walking,running")); // any-set
    try std.testing.expect(tagsMatch("running,swimmingRun", "swimmingRun"));
    try std.testing.expect(!tagsMatch("running", "walking"));
    try std.testing.expect(tagsMatch("coredamageresist", "coredamageresist"));
    // Passive tags match case-insensitively (stock FastTags): a buff's own
    // name queries its BuffResistance rows regardless of case.
    try std.testing.expect(tagsMatch("buffInjuryStunned01", "buffinjurystunned01"));
    try std.testing.expect(tagsMatch("BUFFEFFECT", "buffeffect"));
    // Whitespace and empty segments are tolerated on both sides.
    try std.testing.expect(tagsMatch(" running , secondary ", "secondary"));
    try std.testing.expect(tagsMatch("running", " running ,"));
}

test "a tagged passive folds only for a query that carries its tag" {
    const passives = [_]Passive{
        .{ .name = "StaminaChangeOT", .op = .perc_add, .value = 0.3, .tags = "running" },
        .{ .name = "StaminaMax", .op = .base_add, .value = 25 },
        .{ .name = "PhysicalDamageResist", .op = .base_add, .value = 200, .tags = "coredamageresist" },
    };
    var counts: requirements.Counts = .{};
    const untagged = trackedDeltasAt(&passives, .{ .level = 1 }, .{}, &counts);
    try std.testing.expectEqual(@as(f32, 0), untagged.stamina_ot);
    try std.testing.expectApproxEqAbs(@as(f32, 25), untagged.stamina_max, 0.0001);
    try std.testing.expectEqual(@as(f32, 0), untagged.phys_resist);
    const running = trackedDeltasAt(&passives, .{ .level = 1 }, .{ .tags = "running" }, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), running.stamina_ot, 0.0001);
    // The untagged row matches every query, including the tagged ones.
    try std.testing.expectApproxEqAbs(@as(f32, 25), running.stamina_max, 0.0001);
    const armor = trackedDeltasAt(&passives, .{ .level = 1 }, .{ .tags = "coredamageresist" }, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, 200), armor.phys_resist, 0.0001);
    try std.testing.expectEqual(@as(f32, 0), armor.stamina_ot);
}

test "a requirement-gated row is folded only when its gates pass" {
    // The stock shape that matters: perkHealingFactor's HealthChangeOT row is
    // gated `!HasBuff buffStatusHungry03,buffStatusThirsty03`, so a starving
    // player must not get the regen.
    const reqs = [_]requirements.Requirement{.{
        .kind = .has_buff,
        .negated = true,
        .name = "HasBuff",
        .list = "buffStatusHungry03,buffStatusThirsty03",
    }};
    const passives = [_]Passive{
        .{ .name = "HealthChangeOT", .op = .base_add, .curve = .{ 0.011, 0.022, 0.05, 0.1, 0.16, 0, 0, 0 }, .curve_len = 5, .curve_levels = .{ 1, 2, 3, 4, 5, 0, 0, 0 }, .curve_levels_len = 5, .reqs = &reqs },
        .{ .name = "StaminaMax", .op = .base_add, .curve = .{ 25, 50, 0, 0, 0, 0, 0, 0 }, .curve_len = 2, .curve_levels = .{ 4, 5, 0, 0, 0, 0, 0, 0 }, .curve_levels_len = 2 },
    };
    var counts: requirements.Counts = .{};
    // No active buffs: the gate passes and the row folds.
    const fed = trackedDeltasAt(&passives, .{ .level = 5 }, .{}, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), fed.hp_ot, 0.0001);
    try std.testing.expectEqual(@as(u32, 1), counts.resolved);
    // Starving: the negated HasBuff gate fails, so only the ungated row folds.
    const starving_ids = [_]u16{3};
    const names = requirements.BuffNames{ .ctx = undefined, .resolve = struct {
        fn f(_: *const anyopaque, name: []const u8) ?u16 {
            if (std.ascii.eqlIgnoreCase(name, "buffStatusThirsty03")) return 3;
            if (std.ascii.eqlIgnoreCase(name, "buffStatusHungry03")) return 4;
            return null;
        }
    }.f };
    counts = .{};
    const starving = trackedDeltasAt(&passives, .{ .level = 5 }, .{
        .active_buffs = &starving_ids,
        .buff_names = &names,
    }, &counts);
    try std.testing.expectEqual(@as(f32, 0), starving.hp_ot);
    try std.testing.expectApproxEqAbs(@as(f32, 50), starving.stamina_max, 0.0001);
    try std.testing.expectEqual(@as(u32, 1), counts.resolved);
    // A gate the evaluator cannot resolve refuses the row and is counted.
    const unsupported = [_]requirements.Requirement{.{ .kind = .unsupported, .name = "RandomRoll" }};
    const gated = [_]Passive{.{ .name = "StaminaMax", .op = .base_add, .value = 50, .reqs = &unsupported }};
    counts = .{};
    try std.testing.expect(!trackedDeltasAt(&gated, .{ .level = 5 }, .{}, &counts).any());
    try std.testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "curveValueAt interpolates the stock quality curve (Q1..Q6)" {
    // RE PassiveEffect.ModValue (IL=796): levels scaled so value[0] = Q1 and
    // value[n-1] = Q6, piecewise-linear. armorPrimitiveHelmet "8,12.3".
    const two = [_]f32{ 8, 12.3 };
    try std.testing.expectApproxEqAbs(@as(f32, 8), curveValueAt(1, 6, &two), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 12.3), curveValueAt(6, 6, &two), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 9.72), curveValueAt(3, 6, &two), 0.001); // 8 + 4.3*(2/5)
    // A 6-value curve = per-quality values (armorPreacherOutfit .02..15).
    const six = [_]f32{ 0.02, 0.04, 0.06, 0.08, 0.1, 0.15 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.02), curveValueAt(1, 6, &six), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), curveValueAt(5, 6, &six), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), curveValueAt(6, 6, &six), 0.0001);
    // Single value is constant; level 0 / empty curve apply nothing.
    const one = [_]f32{5};
    try std.testing.expectApproxEqAbs(@as(f32, 5), curveValueAt(4, 6, &one), 0.001);
    try std.testing.expectEqual(@as(f32, 0), curveValueAt(0, 6, &two));
    try std.testing.expectEqual(@as(f32, 0), curveValueAt(3, 6, &.{}));
}

test "a triggered action past the bounded result is counted, not silently dropped" {
    // Stock's widest row set is buffStatusCheck02's 16 onSelfBuffUpdate AddBuff
    // rows; the bound is above that on purpose, and anything past it must show
    // up in `truncated` rather than disappear.
    try std.testing.expect(max_triggered_adds >= 16);
    try std.testing.expect(max_triggered_removes >= 16);
    const over = max_triggered_adds + 3;
    const rows = comptime blk: {
        var r: [over]Triggered = undefined;
        for (&r, 0..) |*e, i| e.* = .{
            .trigger = .update,
            .action = .add_buff,
            .buff = if (i % 2 == 0) "setBonusA" else "setBonusB",
        };
        break :blk r;
    };
    const defs = [_]BuffDef{.{ .name = "check02", .triggered = &rows }};
    const t = Table{ .defs = defs[0..] };
    var counts: requirements.Counts = .{};
    const r = evaluateTriggered(&t, 0, .update, .{}, &counts);
    try std.testing.expectEqual(max_triggered_adds, r.add_n);
    try std.testing.expectEqual(@as(u8, 3), r.truncated);
    try std.testing.expectEqualStrings("setBonusA", r.add_buffs[0]);
    try std.testing.expectEqualStrings("setBonusB", r.add_buffs[max_triggered_adds - 1]);
}

test "evaluateTriggered gates, filters events, and caps the bounded actions" {
    // The stage rows are gated StatComparePercCurrentToMax on Food, now through
    // the shared requirement evaluator.
    const food_lt_50 = [_]requirements.Requirement{.{
        .kind = .stat_compare_perc_current_to_max,
        .name = "StatComparePercCurrentToMax",
        .arg = "Food",
        .op = .lt,
        .value = 0.5,
    }};
    const food_lt_2 = [_]requirements.Requirement{.{
        .kind = .stat_compare_perc_current_to_max,
        .name = "StatComparePercCurrentToMax",
        .arg = "Food",
        .op = .lt,
        .value = 0.02,
    }};
    const defs = [_]BuffDef{
        .{
            .name = "check01",
            .triggered = &.{
                .{ .trigger = .update, .action = .add_buff, .buff = "hungry01", .reqs = &food_lt_50 },
                .{ .trigger = .update, .action = .add_buff, .buff = "hungry03", .reqs = &food_lt_2 },
                .{ .trigger = .start, .action = .remove_buff, .buff = "sibling" },
                .{ .trigger = .update, .action = .other }, // recorded action: skipped
            },
        },
        .{
            .name = "buffStatusHungry03",
            .update_rate_ticks = 44,
            .triggered = &.{
                .{ .trigger = .update, .action = .modify_stats, .stat = "Health", .op = .subtract, .value = 0.25 },
            },
        },
    };
    const t = Table{ .defs = defs[0..] };
    var counts: requirements.Counts = .{};
    // Food 40%: hungry01 passes, hungry03 (2%) fails; event filter skips start.
    const r1 = evaluateTriggered(&t, 0, .update, .{ .food_frac = 0.4, .food_max = 100 }, &counts);
    try std.testing.expectEqual(@as(u8, 1), r1.add_n);
    try std.testing.expectEqualStrings("hungry01", r1.add_buffs[0]);
    try std.testing.expectEqual(@as(u8, 0), r1.remove_n);
    // Food 1%: both rows pass (bounded result keeps both).
    const r2 = evaluateTriggered(&t, 0, .update, .{ .food_frac = 0.01, .food_max = 100 }, &counts);
    try std.testing.expectEqual(@as(u8, 2), r2.add_n);
    // The start event fires the sibling removal only.
    const r3 = evaluateTriggered(&t, 0, .start, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 0), r3.add_n);
    try std.testing.expectEqual(@as(u8, 1), r3.remove_n);
    try std.testing.expectEqualStrings("sibling", r3.remove_buffs[0]);
    // ModifyStats on the stage-3 buff's update.
    const r4 = evaluateTriggered(&t, 1, .update, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 1), r4.mod_n);
    try std.testing.expectEqualStrings("Health", r4.mods[0].stat);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), r4.mods[0].value, 0.0001);
    // stage3HpLossPerSecond converts through the engine: 0.25 / 2.2s.
    const sv = SurvivalStages{ .hungry = 3, .thirsty = 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.25 / 2.2), stage3HpLossPerSecond(&t, sv), 0.0001);
}

test "AddHealth parses as ModifyStats Health add" {
    // MinEventActionAddHealth → EntityAlive.AddHealth; show_splatter is client-only.
    const xml_src =
        \\<buffs>
        \\<buff name="burn">
        \\<effect_group>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="AddHealth" health="-2"/>
        \\<triggered_effect trigger="onSelfBuffStart" action="AddHealth" health="5"/>
        \\</effect_group>
        \\</buff>
        \\</buffs>
    ;
    const path = "worlds/zdtd_buffs_addhealth.xml";
    io_fs.mkdirPath("worlds");
    try io_fs.writeFile(path, xml_src);
    defer io_fs.deleteFile(path);
    var table = try loadFromPath(std.testing.allocator, path);
    defer table.deinit();
    const id = table.indexOfName("burn").?;
    var counts: requirements.Counts = .{};
    const up = evaluateTriggered(&table, id, .update, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 1), up.mod_n);
    try std.testing.expectEqualStrings("Health", up.mods[0].stat);
    try std.testing.expect(up.mods[0].op == .add);
    try std.testing.expectApproxEqAbs(@as(f32, -2), up.mods[0].value, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -2), healthAddDelta(&up), 0.0001);
    const st = evaluateTriggered(&table, id, .start, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 1), st.mod_n);
    try std.testing.expectApproxEqAbs(@as(f32, 5), st.mods[0].value, 0.0001);
}

test "stagesFromWanted derives the stage set from engine names" {
    const wanted = [_][]const u8{ "buffStatusHungry02", "buffStatusThirsty03" };
    const st = stagesFromWanted(&wanted);
    try std.testing.expectEqual(@as(u8, 2), st.hungry);
    try std.testing.expectEqual(@as(u8, 3), st.thirsty);
    try std.testing.expectEqual(@as(u8, 1), stageOfBuffName("buffStatusHungry01").?);
    try std.testing.expect(stageOfBuffName("buffShocked") == null);
}

test "explicit level= curve pairs evaluate piecewise-linearly" {
    // progression.xml's dominant form: level="1,5" value="2,10".
    var lv: [max_curve_len]f32 = .{0} ** max_curve_len;
    const n = parseCurveLevels("1,5", &lv);
    try std.testing.expectEqual(@as(u8, 2), n);
    try std.testing.expectApproxEqAbs(@as(f32, 1), lv[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), lv[1], 0.001);
    const vals = [_]f32{ 2, 10 };
    const ls = lv[0..n];
    try std.testing.expectApproxEqAbs(@as(f32, 2), curveValueAtLevels(1, ls, &vals), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), curveValueAtLevels(5, ls, &vals), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 6), curveValueAtLevels(3, ls, &vals), 0.001); // interpolated
    try std.testing.expectEqual(@as(f32, 0), curveValueAtLevels(0, ls, &vals));
    try std.testing.expectEqual(@as(f32, 0), curveValueAtLevels(6, ls, &vals)); // out of range
    // curveAt honors the anchors: a 4,5-anchored row applies nothing below 4.
    const p = Passive{ .curve = .{ 50, 100, 0, 0, 0, 0, 0, 0 }, .curve_len = 2, .curve_levels = .{ 4, 5, 0, 0, 0, 0, 0, 0 }, .curve_levels_len = 2 };
    try std.testing.expectEqual(@as(f32, 0), curveAt(p, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 50), curveAt(p, 4), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), curveAt(p, 5), 0.001);
    // A single anchor applies at its own level only (PassiveEffect::ModValue
    // IL=161 compares FloorToInt(level) to FloorToInt(levels[0]), it does not
    // extrapolate). Every `<book>` row and 148 progression rows use this form,
    // so a single anchor folding 0 made read almanacs and level-1 perks no-ops.
    const one_anchor = Passive{
        .curve = .{ 0.2, 0, 0, 0, 0, 0, 0, 0 },
        .curve_len = 1,
        .curve_levels = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
        .curve_levels_len = 1,
    };
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), curveAt(one_anchor, 1), 0.001);
    try std.testing.expectEqual(@as(f32, 0), curveAt(one_anchor, 2));
    try std.testing.expectEqual(@as(f32, 0), curveAt(one_anchor, 0));

    // Two anchors with a single value hold it flat across the bracket
    // (PassiveEffect::ModValue IL_0348): 305 stock rows are this shape, e.g.
    // LootProb level="2,3" value="8" and CraftingIngredientCount level="1,5"
    // value="-1". Padding the value slice to the anchor count ramped it to 0
    // instead, so perkMasterChef 3 folded LootProb 0 and resourceGlue's bone
    // cost faded out by tier 5.
    const flat = Passive{
        .curve = .{ 8, 0, 0, 0, 0, 0, 0, 0 },
        .curve_len = 1,
        .curve_levels = .{ 2, 3, 0, 0, 0, 0, 0, 0 },
        .curve_levels_len = 2,
    };
    try std.testing.expectEqual(@as(f32, 0), curveAt(flat, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 8), curveAt(flat, 2), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 8), curveAt(flat, 3), 0.001);
    try std.testing.expectEqual(@as(f32, 0), curveAt(flat, 4));

    // The mirror shape - one anchor, two values - is stock's per-item roll
    // (IL_01D4 RandomRange, mean when the cached seed is 0); with the mean the
    // primitive-armor resist rows give the same value at every quality instead
    // of a Q1..Q6 ramp. No stock row uses it today, but the shapes pair.
    const roll = Passive{
        .curve = .{ -0.2, 0.2, 0, 0, 0, 0, 0, 0 },
        .curve_len = 2,
        .curve_levels = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
        .curve_levels_len = 1,
    };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), curveAt(roll, 1), 0.001);
    try std.testing.expectEqual(@as(f32, 0), curveAt(roll, 2));
}

test "AddOrRemoveBuff toggles on its gates" {
    // Stock `MinEventActionAddOrRemoveBuff` (Execute IL=11): the row gates
    // decide — pass adds, fail removes. Weather/hazard toggles ride
    // `onSelfBuffUpdate` with a CVar threshold gate.
    const rows = [_]Triggered{
        .{ .trigger = .update, .action = .add_or_remove_buff, .buff = "buffHot", .reqs = &.{} },
    };
    var counts: requirements.Counts = .{};
    // No gates: pass = add.
    const added = evaluateRows(&rows, .update, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 1), added.add_n);
    try std.testing.expectEqual(@as(u8, 0), added.remove_n);
    try std.testing.expectEqualStrings("buffHot", added.add_buffs[0]);
    // A failing gate removes instead: force-fail with an unsatisfiable
    // cvar threshold (missing cvar reads 0, never >= 100).
    const gated = [_]Triggered{
        .{ .trigger = .update, .action = .add_or_remove_buff, .buff = "buffHot", .reqs = &.{
            .{ .kind = .cvar_compare, .arg = "noSuchCvarZZZ", .op = .ge, .value = 100 },
        } },
    };
    counts = .{};
    const removed = evaluateRows(&gated, .update, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 0), removed.add_n);
    try std.testing.expectEqual(@as(u8, 1), removed.remove_n);
    try std.testing.expectEqualStrings("buffHot", removed.remove_buffs[0]);
}

test "ModifyStats target=other flags the victim mod" {
    // Stock buffPhysicianEuthanizer's start row sets Health on target=other
    // (instant-kill); the flag routes it to the victim applier, not self.
    const rows = [_]Triggered{
        .{ .trigger = .start, .action = .modify_stats, .stat = "Health", .op = .set, .value = -25000, .target_other = true, .reqs = &.{} },
        .{ .trigger = .start, .action = .modify_stats, .stat = "Health", .op = .add, .value = 2, .reqs = &.{} },
    };
    var counts: requirements.Counts = .{};
    const res = evaluateRows(&rows, .start, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 2), res.mod_n);
    try std.testing.expect(res.mods[0].target_other);
    try std.testing.expect(!res.mods[1].target_other);
    // Self-only folds skip victim rows (SiphoningStrikes path unaffected).
    try std.testing.expectApproxEqAbs(@as(f32, 2), healthAddDelta(&res), 0.0001);
}

test "damage_type element parses onto the def" {
    // `<damage_type value>` drives RemoveAllNegativeBuffs matching.
    const path = stock_paths.configFile("buffs.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expectEqualStrings("Bashing", t.byName("buffInjuryAbrasion").?.damage_type);
    try std.testing.expectEqualStrings("bloodloss", t.byName("buffInjuryBleeding").?.damage_type);
    try std.testing.expectEqualStrings("stun", t.byName("buffHarvest").?.damage_type);
}

test "cure-all row evaluates on regen start" {
    // The regen cure row is gated PlayerLevel LT 6; level 1 passes and the
    // result flags remove_all_negative.
    const path = stock_paths.configFile("buffs.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const id = t.indexOfName("buffNearDeathRegen").?;
    var counts: requirements.Counts = .{};
    const res = evaluateTriggered(&t, id, .start, .{ .player_level = 1 }, &counts);
    try std.testing.expect(res.remove_all_negative);
}

test "GiveExp rows sum the passing gates" {
    // Bandage shape: ungated 10 plus a Physician-gated 20. Both land at
    // Physician 1; only the base lands without it.
    const rows = [_]Triggered{
        .{ .trigger = .primary_action_end, .action = .give_exp, .value = 10, .reqs = &.{} },
        .{ .trigger = .primary_action_end, .action = .give_exp, .value = 20, .reqs = &.{
            .{ .kind = .progression_level, .arg = "perkPhysician", .op = .ge, .value = 1 },
        } },
    };
    var counts: requirements.Counts = .{};
    const levels = [_]requirements.NameLevel{.{ .name = "perkPhysician", .level = 1 }};
    const with_perk = evaluateRows(&rows, .primary_action_end, .{ .levels = &levels }, &counts);
    try std.testing.expectEqual(@as(u32, 30), with_perk.give_exp);
    counts = .{};
    const bare = evaluateRows(&rows, .primary_action_end, .{}, &counts);
    try std.testing.expectEqual(@as(u32, 10), bare.give_exp);
}
