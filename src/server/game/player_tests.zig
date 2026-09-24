//! Player helper tests: skill ledger, magazine XP, barter.
//!
//! Split out of server/game/player.zig (same tests, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const assets_buffs = @import("../../assets/buffs.zig");
const requirements = @import("../../assets/requirements.zig");
const assets_progression = @import("../../assets/progression.zig");
const assets_items = @import("../../assets/items.zig");
const player = @import("player.zig");
const skillCostForLevel = player.skillCostForLevel;
const barterBuyScale = player.barterBuyScale;
const barterSellScale = player.barterSellScale;

test "skill ledger: level-up awards SP; purchase validates, level gate and spends" {
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_ledger", 0);
    defer g.destroy();
    // Minimal progression tree: one attribute + one perk whose level 1 is
    // gated on the attribute (stock's shape: the gate is `<level_requirements>`
    // on a progression name, not the perk's `parent` grouping name).
    const gate_l1 = [_]requirements.Requirement{.{ .kind = .progression_level, .op = .ge, .value = 1, .arg = "attGeneral" }};
    const gate_l2 = [_]requirements.Requirement{.{ .kind = .progression_level, .op = .ge, .value = 3, .arg = "attGeneral" }};
    const lvl_reqs = [_]assets_progression.LevelReq{
        .{ .level = 1, .reqs = &gate_l1 },
        .{ .level = 2, .reqs = &gate_l2 },
    };
    const attrs = [_]assets_progression.AttrDef{
        .{ .name = "attGeneral", .max_level = 10, .base_cost = 1, .cost_mult = 1.14 },
    };
    const perks = [_]assets_progression.PerkDef{
        .{ .name = "perkLightEater", .max_level = 5, .parent_attr = "skillGeneral", .level_reqs = &lvl_reqs },
    };
    g.progression_table.attributes = &attrs;
    g.progression_table.perks = &perks;
    g.progression.skill_points_per_level = 1;

    // Level up from 1 to 2: skill_points_per_level awarded per new level.
    const level1_xp = g.progression.expForLevel(1);
    g.awardXp(0, level1_xp);
    try std.testing.expectEqual(@as(u16, 2), g.clients[0].level);
    try std.testing.expectEqual(@as(u32, 1), g.clients[0].skill_points);

    // Perk with unmet level gate: denied, no SP spent.
    try std.testing.expect(!g.purchaseSkill(0, "perkLightEater", 1));
    try std.testing.expectEqual(@as(u32, 1), g.clients[0].skill_points);
    // Unknown skill denies.
    try std.testing.expect(!g.purchaseSkill(0, "notASkill", 1));
    // Buy the attribute first (cost 1 = base), then the perk level 1.
    try std.testing.expect(g.purchaseSkill(0, "attGeneral", 1));
    try std.testing.expectEqual(@as(u8, 1), g.skillLevelOf(0, "attGeneral"));
    try std.testing.expectEqual(@as(u32, 0), g.clients[0].skill_points);
    // Second level would cost base x mult (1.14 -> round 1): still 0 SP.
    try std.testing.expect(!g.purchaseSkill(0, "attGeneral", 2));
    // Perk buys at base cost 1 now that its level-1 gate passes.
    g.clients[0].skill_points = 1;
    try std.testing.expect(g.purchaseSkill(0, "perkLightEater", 1));
    try std.testing.expectEqual(@as(u8, 1), g.skillLevelOf(0, "perkLightEater"));
    try std.testing.expectEqual(@as(u32, 0), g.clients[0].skill_points);
    // Re-purchase of the same level denies (one level per request).
    try std.testing.expect(!g.purchaseSkill(0, "perkLightEater", 1));
    // Level 2 needs attGeneral >= 3, which the ledger does not hold yet.
    g.clients[0].skill_points = 5;
    try std.testing.expect(!g.purchaseSkill(0, "perkLightEater", 2));
    try std.testing.expectEqual(@as(u32, 5), g.clients[0].skill_points);
    g.clients[0].skill_levels[0] = .{ .name = "attGeneral", .level = 3 };
    try std.testing.expect(g.purchaseSkill(0, "perkLightEater", 2));
    try std.testing.expectEqual(@as(u8, 2), g.skillLevelOf(0, "perkLightEater"));
    std.debug.print("PASS skill-ledger: SP award, cost, level gate, echo state\n", .{});
}

test "skill cost follows CalculatedCostForLevel and the row override table" {
    // IL=423: conv.i4(Mathf.Pow(CostMultiplier, level) * BaseCostToLevel), with
    // Mathf.Pow in double cast back to float and conv.i4 truncating. Stock
    // attributes are base 1 / mult 1.14, so the goldens are 1,1,1,1,1,2,2,2,3,3
    // (the old round(base*mult^(level-1)) gave 2 at level 5 and 3 at level 8).
    const goldens = [_]u32{ 1, 1, 1, 1, 1, 2, 2, 2, 3, 3 };
    for (goldens, 0..) |want, i| {
        try std.testing.expectEqual(want, skillCostForLevel(1, 1.14, @intCast(i + 1)));
    }
    // A flat multiplier (stock perks: mult 1) costs the base at every level.
    try std.testing.expectEqual(@as(u32, 1), skillCostForLevel(1, 1.0, 5));
    try std.testing.expectEqual(@as(u32, 3), skillCostForLevel(3, 1.0, 4));
    // A zero-cost row is free (stock conv.i4 of 0); level 0 has no cost.
    try std.testing.expectEqual(@as(u32, 0), skillCostForLevel(0, 1.14, 3));
    try std.testing.expectEqual(@as(u32, 0), skillCostForLevel(1, 1.14, 0));
}

test "override_cost replaces the curve and refuses past its end" {
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_cost", 0);
    defer g.destroy();
    const attrs = [_]assets_progression.AttrDef{
        .{ .name = "attPerception", .max_level = 10, .base_cost = 1, .cost_mult = 1.14 },
    };
    const gate = [_]requirements.Requirement{.{ .kind = .progression_level, .op = .ge, .value = 1, .arg = "attPerception" }};
    const lvl = [_]assets_progression.LevelReq{
        .{ .level = 1, .reqs = &gate },
        .{ .level = 2, .reqs = &gate },
    };
    // Stock shape: perkPummelPete carries override_cost="1,2,2,3".
    const perks = [_]assets_progression.PerkDef{
        .{ .name = "perkPummelPete", .max_level = 4, .level_reqs = &lvl, .override_cost = &.{ 1, 2 } },
    };
    g.progression_table.attributes = &attrs;
    g.progression_table.perks = &perks;
    g.clients[0].skill_levels[0] = .{ .name = "attPerception", .level = 4 };
    g.clients[0].skill_level_n = 1;
    g.clients[0].skill_points = 10;
    // The attribute ladder: level 5 costs 1 under the stock formula.
    try std.testing.expectEqual(@as(?u32, 1), g.skillCostOf(0, "attPerception", 5));
    // The override table wins for the perk.
    try std.testing.expectEqual(@as(?u32, 1), g.skillCostOf(0, "perkPummelPete", 1));
    try std.testing.expect(g.purchaseSkill(0, "perkPummelPete", 1));
    try std.testing.expectEqual(@as(u32, 9), g.clients[0].skill_points);
    try std.testing.expectEqual(@as(?u32, 2), g.skillCostOf(0, "perkPummelPete", 2));
    try std.testing.expect(g.purchaseSkill(0, "perkPummelPete", 2));
    try std.testing.expectEqual(@as(u32, 7), g.clients[0].skill_points);
    // Level 3 has no override entry: stock would index past the table, so the
    // purchase refuses instead of falling back to the curve.
    try std.testing.expect(g.skillCostOf(0, "perkPummelPete", 3) == null);
    try std.testing.expect(!g.purchaseSkill(0, "perkPummelPete", 3));
    try std.testing.expectEqual(@as(u32, 7), g.clients[0].skill_points);
    std.debug.print("PASS perk cost: stock curve + row override_cost\n", .{});
}

test "killXpAward scales by the on_entity_killed verdict percent" {
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_killscale", 0);
    defer g.destroy();
    // killXpAward(slot, base, scale, trap, killed): 200 base x 150% = 300
    // (xp_multiplier default 100 keeps 1.0x). No corpse net id -> the shared
    // kill class falls back to the stock default (unused here, no party).
    const before = g.clients[0].xp;
    g.killXpAward(0, 200, 150, false, 0);
    try std.testing.expectEqual(before + 300, g.clients[0].xp);
    std.debug.print("PASS kill-xp-scale: 200 x 150% = {d}\n", .{g.clients[0].xp - before});
}

test "addProgressionLevel clamps to crafting_skill max and fails closed on unknown names" {
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_magread", 0);
    defer g.destroy();
    const skills = [_]assets_progression.CraftingSkill{
        .{ .name = "craftingHarvestingTools", .max_level = 5, .entries = &.{} },
    };
    g.progression_table.crafting_skills = &skills;
    try std.testing.expect(!g.addProgressionLevel(0, "notASkill", 1));
    try std.testing.expect(g.addProgressionLevel(0, "craftingHarvestingTools", 1));
    try std.testing.expectEqual(@as(u8, 1), g.skillLevelOf(0, "craftingHarvestingTools"));
    try std.testing.expect(g.addProgressionLevel(0, "craftingHarvestingTools", 1));
    try std.testing.expectEqual(@as(u8, 2), g.skillLevelOf(0, "craftingHarvestingTools"));
    try std.testing.expect(g.addProgressionLevel(0, "craftingHarvestingTools", 10));
    try std.testing.expectEqual(@as(u8, 5), g.skillLevelOf(0, "craftingHarvestingTools"));
    try std.testing.expect(!g.addProgressionLevel(0, "craftingHarvestingTools", 1));
}

test "grantMagazineRead awards GiveExp through the server ledger" {
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_magxp", 0);
    defer g.destroy();
    const skills = [_]assets_progression.CraftingSkill{
        .{ .name = "craftingHarvestingTools", .max_level = 100, .entries = &.{} },
    };
    g.progression_table.crafting_skills = &skills;
    const defs = [_]assets_items.ItemDef{
        .{
            .id = 100,
            .name = "harvestingToolsSkillMagazine",
            .is_eat = true,
            .progression_name = "craftingHarvestingTools",
            .progression_add = 1,
            .eat_exp = 50,
        },
    };
    g.items = .{ .defs = &defs, .source = .xml };
    const before = g.clients[0].xp;
    g.grantMagazineRead(0, 100);
    try std.testing.expectEqual(@as(u8, 1), g.skillLevelOf(0, "craftingHarvestingTools"));
    // XP rides the eat path's gated GiveExp sum now (fireItemUseBuffs), not
    // the flat award: the ledger itself is unchanged here.
    try std.testing.expectEqual(before, g.clients[0].xp);
}

test "grantMagazineRead SetProgressionLevel -1 sets perk to max" {
    // RE minevents.md IL=104: level=-1 sets ProgressionClass.MaxLevel.
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_setmax", 0);
    defer g.destroy();
    const perks = [_]assets_progression.PerkDef{
        .{ .name = "perkFiremansAlmanacHeat", .max_level = 5 },
        .{ .name = "perkFiremansAlmanacComplete", .max_level = 1 },
    };
    g.progression_table.perks = &perks;
    const set_names = [_][]const u8{ "perkFiremansAlmanacHeat", "perkFiremansAlmanacComplete" };
    const defs = [_]assets_items.ItemDef{
        .{
            .id = 100,
            .name = "bookFiremansAlmanacHeat",
            .is_eat = true,
            .progression_set_max = &set_names,
            .eat_exp = 50,
        },
    };
    g.items = .{ .defs = &defs, .source = .xml };
    const before = g.clients[0].xp;
    g.grantMagazineRead(0, 100);
    try std.testing.expectEqual(before, g.clients[0].xp);
    try std.testing.expectEqual(@as(u8, 5), g.skillLevelOf(0, "perkFiremansAlmanacHeat"));
    try std.testing.expectEqual(@as(u8, 1), g.skillLevelOf(0, "perkFiremansAlmanacComplete"));
    // Idempotent at max.
    try std.testing.expect(!g.setProgressionLevelMax(0, "perkFiremansAlmanacHeat"));
    try std.testing.expect(!g.setProgressionLevelMax(0, "notAPerk"));
}

test "dismemberSelfChance folds perk levels and active buffs, 0 when absent" {
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_dismember143", 0);
    defer g.destroy();
    // No rows anywhere: the stock unbuffed value.
    try std.testing.expectEqual(@as(f32, 0), g.dismemberSelfChance(0, null));
    // Perk leg: a DismemberSelfChance base_add curve 0.1/level.
    const perks = [_]assets_progression.PerkDef{
        .{
            .name = "perkSkullCrusher",
            .max_level = 5,
            .passives = &.{.{ .name = "DismemberSelfChance", .op = .base_add, .curve = .{ 0.1, 0.2, 0.3, 0, 0, 0, 0, 0 }, .curve_len = 3, .curve_levels = .{ 1, 2, 3, 0, 0, 0, 0, 0 }, .curve_levels_len = 3 }},
        },
    };
    g.progression_table.perks = &perks;
    _ = g.sim.spawnPlayer(0, 70, 0, 0).?;
    g.clients[0].skill_levels[0] = .{ .name = "perkSkullCrusher", .level = 2 };
    g.clients[0].skill_level_n = 1;
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), g.dismemberSelfChance(0, null), 0.0001);
    // Unknown skill names are ignored (fail closed).
    g.clients[0].skill_levels[0].name = "notAPerk";
    try std.testing.expectEqual(@as(f32, 0), g.dismemberSelfChance(0, null));
    g.clients[0].skill_levels[0].name = "perkSkullCrusher";
    // Buff leg: an active buff's untagged row adds at level 1.
    const defs = [_]assets_buffs.BuffDef{
        .{ .name = "testDismemberBuff", .passives = &.{.{ .name = "DismemberSelfChance", .op = .base_add, .value = 0.5 }} },
    };
    g.buffs.defs = defs[0..];
    const ps = g.sim.playerByPeer(0) orelse return error.TestUnexpectedResult;
    const bs = g.sim.buffsMut(ps);
    bs.slots[0] = .{ .active = true, .def_id = 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), g.dismemberSelfChance(0, ps), 0.0001);
    // Inactive buff contributes nothing.
    bs.slots[0].active = false;
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), g.dismemberSelfChance(0, ps), 0.0001);
    // Removing the perk level reverts exactly.
    g.clients[0].skill_level_n = 0;
    try std.testing.expectEqual(@as(f32, 0), g.dismemberSelfChance(0, ps));
    std.debug.print("PASS dismember-143: perk curve + buff leg fold, revertible\n", .{});
}

test "barter scales discount buying and bonus selling off the same fold" {
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_barter", 0);
    defer g.destroy();
    // No rows: scales are identity (slot 0 has no player yet, so the
    // buff leg resolves empty and only the empty perk ledger folds).
    // g is already *Game; &g would be **Game and mis-cast.
    const ctx: ?*anyopaque = @ptrCast(g);
    try std.testing.expectEqual(@as(f32, 1), barterBuyScale(ctx, 0));
    try std.testing.expectEqual(@as(f32, 1), barterSellScale(ctx, 0));
    const perks = [_]assets_progression.PerkDef{
        .{
            .name = "perkBetterBarter",
            .max_level = 5,
            .passives = &.{
                .{ .name = "BarteringBuying", .op = .base_add, .curve = .{ 0.05, 0.1, 0, 0, 0, 0, 0, 0 }, .curve_len = 2, .curve_levels = .{ 1, 2, 0, 0, 0, 0, 0, 0 }, .curve_levels_len = 2 },
                .{ .name = "BarteringSelling", .op = .base_add, .curve = .{ 0.05, 0.1, 0, 0, 0, 0, 0, 0 }, .curve_len = 2, .curve_levels = .{ 1, 2, 0, 0, 0, 0, 0, 0 }, .curve_levels_len = 2 },
            },
        },
    };
    g.progression_table.perks = &perks;
    _ = g.sim.spawnPlayer(0, 70, 0, 0).?;
    g.clients[0].skill_levels[0] = .{ .name = "perkBetterBarter", .level = 2 };
    g.clients[0].skill_level_n = 1;
    // Level 2: 10% off buys, 10% over sells.
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), barterBuyScale(ctx, 0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), barterSellScale(ctx, 0), 0.0001);
    std.debug.print("PASS barter-scale: buy 0.9x sell 1.1x at level 2\n", .{});
}
