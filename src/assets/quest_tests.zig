//! Quest catalog tests: defs, phases, actions, events.
//!
//! Split out of assets/quests.zig (same tests, moved verbatim).

const std = @import("std");
const quests = @import("quests.zig");
const QuestDef = quests.QuestDef;
const QuestVar = quests.QuestVar;
const max_quest_vars = quests.max_quest_vars;
const buildPhaseGraph = quests.buildPhaseGraph;
const parseActions = quests.parseActions;
const parseQuestEvents = quests.parseQuestEvents;
const parseVariables = quests.parseVariables;
const resolveDifficultyTier = quests.resolveDifficultyTier;
const scanObjectiveMeta = quests.scanObjectiveMeta;
const parseCatalog = quests.parseCatalog;
const loadFromPath = quests.loadFromPath;
const quest = @import("../ecs/quest.zig");
const xml = @import("xml_util.zig");
const stock_paths = @import("../util/stock_paths.zig");
const io_fs = @import("../util/io_fs.zig");

test "parse fixture catalog" {
    const fixture =
        \\<?xml version="1.0"?>
        \\<!-- comment with <quest id="nope"> -->
        \\<quests max_quest_tier="2" quests_per_tier="3" starter_quest="quest_starter">
        \\  <quest id="quest_starter">
        \\    <property name="name_key" value="Starter Visit"/>
        \\    <property name="completiontype" value="TurnIn"/>
        \\    <objective type="Goto" id="trader" value="5" phase="1"/>
        \\    <objective type="InteractWithNPC" phase="2"/>
        \\    <reward type="Exp" value="500"/>
        \\  </quest>
        \\  <quest id="tier1_clear">
        \\    <property name="name_key" value="Clear POI"/>
        \\    <property name="difficulty_tier" value="1"/>
        \\    <property name="completiontype" value="TurnIn"/>
        \\    <objective type="RandomPOIGoto" phase="1"/>
        \\    <objective type="ClearSleepers">
        \\      <property name="phase" value="3"/>
        \\    </objective>
        \\    <objective type="ReturnToNPC" phase="4"/>
        \\    <reward type="Exp" value="1000"/>
        \\  </quest>
        \\  <quest id="tier1_fetch">
        \\    <property name="name_key" value="Fetch bag"/>
        \\    <property name="difficulty_tier" value="1"/>
        \\    <objective type="FetchFromContainer">
        \\      <property name="item_count" value="1"/>
        \\    </objective>
        \\    <reward type="Exp" value="400"/>
        \\  </quest>
        \\  <quest_list id="trader_jen_quests">
        \\    <quest id="tier1_clear"/>
        \\    <quest id="tier1_fetch"/>
        \\  </quest_list>
        \\</quests>
    ;
    var cat = try parseCatalog(std.testing.allocator, fixture, .{});
    defer cat.deinit();
    try std.testing.expectEqual(@as(usize, 3), cat.defs.len);
    try std.testing.expectEqualStrings("quest_starter", cat.starter_name);
    const st = cat.byId(cat.starter_id).?;
    try std.testing.expectEqual(quest.QuestKind.fetch_trader, st.kind);
    try std.testing.expect(st.turn_in);
    // Phase graph: Goto trader (phase1) → InteractWithNPC (phase2), TurnIn.
    try std.testing.expectEqual(@as(u8, 2), st.highest_phase);
    try std.testing.expectEqual(@as(usize, 2), st.phases.len);
    try std.testing.expectEqual(quest.PhaseKind.trader_interact, st.phases[0].kind);
    try std.testing.expectEqual(quest.PhaseKind.trader_interact, st.phases[1].kind);
    const clear = cat.byName("tier1_clear").?;
    try std.testing.expectEqual(quest.QuestKind.kill_zombies, clear.kind);
    try std.testing.expect(clear.target_count >= 3);
    // Nested `<property name="phase">` honored: ClearSleepers sits at phase 3.
    try std.testing.expect(clear.highest_phase >= 4);
    try std.testing.expectEqual(quest.PhaseKind.goto_point, clear.phases[0].kind);
    try std.testing.expectEqual(quest.PhaseKind.kill_zombies, clear.phases[2].kind);
    try std.testing.expectEqual(quest.PhaseKind.trader_interact, clear.phases[3].kind);
    // Phase 2 has no objective → auto scaffolding phase.
    try std.testing.expectEqual(quest.PhaseKind.auto, clear.phases[1].kind);
    try std.testing.expectEqual(@as(usize, 3), clear.objective_phases.len);
    try std.testing.expectEqual(@as(u8, 3), clear.objective_phases[1]);
    const fetch = cat.byName("tier1_fetch").?;
    try std.testing.expectEqual(quest.QuestKind.fetch_item, fetch.kind);
    try std.testing.expectEqual(@as(usize, 1), cat.lists.len);
    try std.testing.expectEqualStrings("trader_jen_quests", cat.lists[0].id);
    try std.testing.expectEqual(@as(usize, 2), cat.lists[0].entries.len);
}

test "rally point objective becomes a rally phase without stealing one" {
    const fixture =
        \\<?xml version="1.0"?>
        \\<quests starter_quest="tier1_rally">
        \\  <quest id="tier1_rally">
        \\    <property name="name_key" value="Rally"/>
        \\    <objective type="RandomPOIGoto" phase="1"/>
        \\    <objective type="RallyPoint" phase="2"/>
        \\    <objective type="RallyPoint" phase="3"/>
        \\    <objective type="ClearSleepers" phase="3"/>
        \\    <reward type="Exp" value="100"/>
        \\  </quest>
        \\</quests>
    ;
    var cat = try parseCatalog(std.testing.allocator, fixture, .{});
    defer cat.deinit();
    const d = cat.byName("tier1_rally").?;
    try std.testing.expectEqual(@as(u8, 3), d.highest_phase);
    try std.testing.expectEqual(quest.PhaseKind.goto_point, d.phases[0].kind);
    // Alone in its phase, RallyPoint drives it.
    try std.testing.expectEqual(quest.PhaseKind.rally, d.phases[1].kind);
    // Sharing a phase with real work, RallyPoint must lose.
    try std.testing.expectEqual(quest.PhaseKind.kill_zombies, d.phases[2].kind);
}

test "load stock quests.xml when present" {
    // Both installs carry the same quests.xml (verified byte-identical); the
    // test pins the table the dedicated server actually serves, falling back
    // to the client copy when only it is on disk.
    const path = blk: {
        const dedi = stock_paths.configFile("quests.xml");
        if (io_fs.fileExists(dedi)) break :blk dedi;
        break :blk stock_paths.steam_client ++ "/Data/Config/quests.xml";
    };
    if (!io_fs.fileExists(path)) return;
    var cat = try loadFromPath(std.testing.allocator, path, .{});
    defer cat.deinit();
    try std.testing.expect(cat.defs.len > 50);
    try std.testing.expectEqualStrings("quest_whiteRiverCitizen1", cat.starter_name);
    try std.testing.expect(cat.byName("quest_whiteRiverCitizen1") != null);
    try std.testing.expect(cat.byName("tier1_clear") != null);
    try std.testing.expect(cat.lists.len >= 1);
    // Six tier rows in document order (tiers 2..7); walk indexes tier-2.
    try std.testing.expectEqual(@as(usize, 6), cat.tier_rewards.len);
    try std.testing.expectEqual(cat.byName("quest_tier1complete").?.id, cat.tier_rewards[0]);
    try std.testing.expectEqual(cat.byName("quest_tier6complete").?.id, cat.tier_rewards[5]);
}

test "quest template inheritance fills derived quests" {
    const fixture =
        \\<quests>
        \\  <quest id="tpl_base">
        \\    <property name="name_key" value="Base"/>
        \\    <objective type="Goto" id="trader" value="5" phase="1"/>
        \\    <reward type="Exp" value="500"/>
        \\  </quest>
        \\  <quest id="derived" template="tpl_base">
        \\    <reward type="Exp" value="1000"/>
        \\  </quest>
        \\</quests>
    ;
    var cat = try parseCatalog(std.testing.allocator, fixture, .{});
    defer cat.deinit();
    const b = cat.byName("tpl_base").?;
    try std.testing.expect(b.objective_count >= 1);
    const d = cat.byName("derived").?;
    // The derived quest inherits the template's objective and adds its own
    // reward, so it is no longer an empty def.
    try std.testing.expect(d.objective_count >= 1);
    try std.testing.expect(d.reward_count >= 2);
}

test "objective write kinds follow objective type" {
    const fixture =
        \\<quests>
        \\  <quest id="mixed">
        \\    <objective type="Goto" phase="1"/>
        \\    <objective type="TreasureChest" phase="2"/>
        \\    <objective type="POIStayWithin" phase="3"/>
        \\    <objective type="StayWithin" phase="4"/>
        \\    <objective type="Time" phase="5"/>
        \\  </quest>
        \\</quests>
    ;
    var cat = try parseCatalog(std.testing.allocator, fixture, .{});
    defer cat.deinit();
    const d = cat.byName("mixed").?;
    try std.testing.expectEqual(@as(usize, 5), d.objective_kinds.len);
    try std.testing.expectEqual(quest.ObjectiveWireKind.base, d.objective_kinds[0]);
    try std.testing.expectEqual(quest.ObjectiveWireKind.treasure_chest, d.objective_kinds[1]);
    try std.testing.expectEqual(quest.ObjectiveWireKind.empty, d.objective_kinds[2]);
    // StayWithin is a distinct class from POIStayWithin and also Writes
    // nothing; Time writes a bare UInt16 instead of the base pair.
    try std.testing.expectEqual(quest.ObjectiveWireKind.empty, d.objective_kinds[3]);
    try std.testing.expectEqual(quest.ObjectiveWireKind.time, d.objective_kinds[4]);
}

test "reward_coin sums currency Item rewards and fails closed" {
    const fixture =
        \\<quests>
        \\  <quest id="payday">
        \\    <reward type="Exp" value="1000"/>
        \\    <reward type="Item" id="casinoCoin" value="500"/>
        \\    <reward type="Item" id="casinoCoin" value="250"/>
        \\  </quest>
        \\  <quest id="freebie">
        \\    <reward type="Exp" value="1000"/>
        \\  </quest>
        \\  <quest id="altpay">
        \\    <reward type="Item" id="dukeCoin" value="100"/>
        \\    <reward type="Item" id="casinoCoin" value="999"/>
        \\  </quest>
        \\</quests>
    ;
    var cat = try parseCatalog(std.testing.allocator, fixture, .{});
    defer cat.deinit();
    const pay = cat.byName("payday").?;
    try std.testing.expectEqual(@as(u32, 750), pay.reward_coin);
    const free = cat.byName("freebie").?;
    try std.testing.expectEqual(@as(u32, 0), free.reward_coin);

    // traders.xml currency_item override: only matching id rows credit the wallet.
    var cat2 = try parseCatalog(std.testing.allocator, fixture, .{ .currency_item = "dukeCoin" });
    defer cat2.deinit();
    try std.testing.expectEqual(@as(u32, 0), cat2.byName("payday").?.reward_coin);
    try std.testing.expectEqual(@as(u32, 100), cat2.byName("altpay").?.reward_coin);
}

test "objective-kinds mapping is data-driven (config spec overrides builtin)" {
    const fixture =
        \\<quests>
        \\  <quest id="q_unknown"><objective type="QuestItem" value="1"/></quest>
        \\  <quest id="q_goto"><objective type="Goto" value="5"/></quest>
        \\  <quest id="q_goto_trader"><objective type="Goto" id="trader" value="5"/></quest>
        \\</quests>
    ;
    // No config: an unmapped stock type is .auto scaffolding (fail-closed),
    // Goto maps to goto_point, and the id="trader" special case still wins.
    var cat = try parseCatalog(std.testing.allocator, fixture, .{});
    defer cat.deinit();
    try std.testing.expectEqual(quest.PhaseKind.auto, cat.byName("q_unknown").?.phases[0].kind);
    try std.testing.expectEqual(quest.PhaseKind.goto_point, cat.byName("q_goto").?.phases[0].kind);
    try std.testing.expectEqual(quest.PhaseKind.trader_interact, cat.byName("q_goto_trader").?.phases[0].kind);

    // A config row maps a NEW stock type without any code change.
    var cat2 = try parseCatalog(std.testing.allocator, fixture, .{ .objective_kinds = "QuestItem=craft" });
    defer cat2.deinit();
    try std.testing.expectEqual(quest.PhaseKind.craft, cat2.byName("q_unknown").?.phases[0].kind);

    // Config rows override the builtin defaults (same precedence as rules);
    // the hardcoded id="trader" game fact still beats the override.
    var cat3 = try parseCatalog(std.testing.allocator, fixture, .{ .objective_kinds = "Goto=block_activate, QuestItem=kill_zombies" });
    defer cat3.deinit();
    try std.testing.expectEqual(quest.PhaseKind.block_activate, cat3.byName("q_goto").?.phases[0].kind);
    try std.testing.expectEqual(quest.PhaseKind.kill_zombies, cat3.byName("q_unknown").?.phases[0].kind);
    try std.testing.expectEqual(quest.PhaseKind.trader_interact, cat3.byName("q_goto_trader").?.phases[0].kind);

    // Malformed rows are skipped, not fatal.
    var cat4 = try parseCatalog(std.testing.allocator, fixture, .{ .objective_kinds = "BogusKind=x,  =craft" });
    defer cat4.deinit();
    try std.testing.expectEqual(quest.PhaseKind.auto, cat4.byName("q_unknown").?.phases[0].kind);
}

test "quest policy tunables drive kill defaults at parse (ADR 0021)" {
    const fixture =
        \\<quests>
        \\  <quest id="q_kill"><objective type="ClearSleepers" phase="1"/></quest>
        \\  <quest id="q_kill_t1">
        \\    <property name="difficulty_tier" value="1"/>
        \\    <objective type="ClearSleepers" phase="1"/>
        \\  </quest>
        \\</quests>
    ;
    // No explicit kill count: the `[quests]` policy fills the floor.
    var cat = try parseCatalog(std.testing.allocator, fixture, .{ .default_kill_count = 5, .kill_per_tier = 1 });
    defer cat.deinit();
    try std.testing.expectEqual(@as(u16, 5), cat.byName("q_kill").?.phases[0].required); // tier 0
    try std.testing.expectEqual(@as(u16, 6), cat.byName("q_kill_t1").?.phases[0].required); // 5 + 1*1
    // The builtin defaults stay when the policy is empty.
    var cat2 = try parseCatalog(std.testing.allocator, fixture, .{});
    defer cat2.deinit();
    try std.testing.expectEqual(@as(u16, 3), cat2.byName("q_kill").?.phases[0].required);
    try std.testing.expectEqual(@as(u16, 5), cat2.byName("q_kill_t1").?.phases[0].required); // 3 + 2*1
}

test "rewards parse kinds, item names and values in document order" {
    const fixture =
        \\<quests>
        \\  <quest id="rich">
        \\    <reward type="Exp" value="1000"/>
        \\    <reward type="Item" id="casinoCoin" value="500"/>
        \\    <reward type="LootItem" id="gunPistolT2" value="2"/>
        \\    <reward type="SkillPoints" value="3"/>
        \\  </quest>
        \\</quests>
    ;
    var cat = try parseCatalog(std.testing.allocator, fixture, .{});
    defer cat.deinit();
    const d = cat.byName("rich").?;
    try std.testing.expectEqual(@as(u8, 4), d.reward_n);
    try std.testing.expectEqual(quest.RewardKind.exp, d.rewards[0].kind);
    try std.testing.expectEqual(@as(u32, 1000), d.rewards[0].value);
    try std.testing.expectEqual(quest.RewardKind.item, d.rewards[1].kind);
    try std.testing.expectEqualStrings("casinoCoin", d.rewards[1].item_name);
    try std.testing.expectEqual(@as(u32, 500), d.rewards[1].value);
    try std.testing.expectEqual(quest.RewardKind.loot_item, d.rewards[2].kind);
    try std.testing.expectEqualStrings("gunPistolT2", d.rewards[2].item_name);
    try std.testing.expectEqual(@as(u32, 2), d.rewards[2].value);
    try std.testing.expectEqual(quest.RewardKind.skill_points, d.rewards[3].kind);
    // The wire ItemStack flags match the Item/LootItem kinds.
    try std.testing.expect(d.reward_has_item[1]);
    try std.testing.expect(d.reward_has_item[2]);
    try std.testing.expect(!d.reward_has_item[0]);
}

test "stock quests.xml template quests parse non-empty" {
    const path = stock_paths.configFile("quests.xml");
    if (!io_fs.fileExists(path)) return;
    var cat = try loadFromPath(std.testing.allocator, path, .{});
    defer cat.deinit();
    // 67 stock quests use template=; the derived challenge rewards must carry
    // the template's objectives instead of parsing as empty defs.
    const adv = cat.byName("challengegroup_reward_advanced_survival");
    try std.testing.expect(adv != null);
    const advanced_survival = adv.?;
    try std.testing.expect(advanced_survival.objective_count >= 1);
    try std.testing.expect(advanced_survival.reward_count >= 1);
    const homestead = cat.byName("challengegroup_reward_homesteading");
    try std.testing.expect(homestead != null);
    const homesteading = homestead.?;
    try std.testing.expect(homesteading.objective_count >= 1);
    // The merged body counts the template's objectives too: the wire
    // objective_count must be at least the template's (the client's inherited
    // QuestClass carries the template's full objective list, so a count of 1
    // would trip its ValidateSizeMarker on the join PDF).
    try std.testing.expect(advanced_survival.objective_count >= homesteading.objective_count);
    // difficulty_tier resolves through the `<variable name="difficulty">`
    // override (template property carries param1="difficulty"): tier2_fetch
    // must report 2, not the template's 1.
    const t2 = cat.byName("tier2_fetch");
    try std.testing.expect(t2 != null);
    try std.testing.expectEqual(@as(u8, 2), t2.?.difficulty_tier);
    const t1 = cat.byName("tier1_fetch");
    try std.testing.expect(t1 != null);
    try std.testing.expectEqual(@as(u8, 1), t1.?.difficulty_tier);
}

test "quest actions parse types, phases and properties" {
    const fixture =
        \\<quests>
        \\  <quest id="poi_quest">
        \\    <action type="UnlockPOI">
        \\      <property name="phase" value="4"/>
        \\    </action>
        \\    <action type="SetCVar">
        \\      <property name="cvar" value="StarterQuest"/>
        \\      <property name="value" value="1"/>
        \\    </action>
        \\    <action type="SpawnGSEnemy">
        \\      <property name="gamestage_list" value="SleeperGSList"/>
        \\      <property name="count" value="1-2"/>
        \\    </action>
        \\  </quest>
        \\</quests>
    ;
    var cat = try parseCatalog(std.testing.allocator, fixture, .{});
    defer cat.deinit();
    const d = cat.byName("poi_quest").?;
    try std.testing.expectEqual(@as(u8, 3), d.action_n);
    try std.testing.expectEqual(quest.QuestActionKind.unlock_poi, d.actions[0].kind);
    try std.testing.expectEqual(@as(u8, 4), d.actions[0].phase);
    try std.testing.expectEqual(quest.QuestActionKind.set_cvar, d.actions[1].kind);
    try std.testing.expectEqualStrings("StarterQuest", d.actions[1].name);
    try std.testing.expectEqualStrings("1", d.actions[1].value);
    try std.testing.expectEqual(quest.QuestActionKind.spawn_gs_enemy, d.actions[2].kind);
    try std.testing.expectEqualStrings("SleeperGSList", d.actions[2].name);
}

test "difficulty_tier resolves through template variable overrides" {
    // tier1_fetch declares difficulty_tier via param1="difficulty"; the
    // derived tier2_fetch overrides the variable to 2 (and tier3 to 3).
    const fixture =
        \\<quests>
        \\  <quest id="tier1_fetch">
        \\    <property name="name_key" value="q1"/>
        \\    <property name="difficulty_tier" value="1" param1="difficulty"/>
        \\    <objective type="Fetch" id="1"/>
        \\  </quest>
        \\  <quest id="tier2_fetch" template="tier1_fetch">
        \\    <variable name="difficulty" value="2"/>
        \\    <objective type="Fetch" id="1"/>
        \\  </quest>
        \\  <quest id="tier3_fetch" template="tier1_fetch">
        \\    <variable name="difficulty" value="3"/>
        \\    <objective type="Fetch" id="1"/>
        \\  </quest>
        \\</quests>
    ;
    var cat = try parseCatalog(std.testing.allocator, fixture, .{});
    defer cat.deinit();
    try std.testing.expectEqual(@as(u8, 1), cat.byName("tier1_fetch").?.difficulty_tier);
    try std.testing.expectEqual(@as(u8, 2), cat.byName("tier2_fetch").?.difficulty_tier);
    try std.testing.expectEqual(@as(u8, 3), cat.byName("tier3_fetch").?.difficulty_tier);
}

test "resolveDifficultyTier reads param1 variables directly" {
    const body =
        \\<property name="name_key" value="q1"/>
        \\<property name="difficulty_tier" value="1" param1="difficulty"/>
        \\<variable name="difficulty" value="2"/>
    ;
    var vars: [max_quest_vars]QuestVar = undefined;
    const vn = parseVariables(body, &vars);
    try std.testing.expectEqual(@as(u8, 1), vn);
    try std.testing.expectEqualStrings("difficulty", vars[0].name);
    try std.testing.expectEqualStrings("2", vars[0].value);
    try std.testing.expectEqual(@as(u8, 2), resolveDifficultyTier(body, vars[0..vn]));
}

test "objective nav_object rides the phase spec for the quest marker" {
    const fixture =
        \\<?xml version="1.0"?>
        \\<quests starter_quest="tier1_clear">
        \\  <quest id="tier1_clear">
        \\    <property name="name_key" value="Clear"/>
        \\    <objective type="ClearSleepers" phase="1">
        \\      <property name="nav_object" value="sleeper_volume"/>
        \\    </objective>
        \\    <objective type="InteractWithNPC" phase="2">
        \\      <property name="nav_object" value="return_to_trader"/>
        \\    </objective>
        \\    <objective type="Goto" id="trader" phase="1">
        \\      <property name="nav_object" value="go_to_trader"/>
        \\    </objective>
        \\    <reward type="Exp" value="100"/>
        \\  </quest>
        \\</quests>
    ;
    var cat = try parseCatalog(std.testing.allocator, fixture, .{});
    defer cat.deinit();
    const d = cat.byName("tier1_clear").?;
    // Phase 1: ClearSleepers out-scores Goto, so the sleeper marker wins.
    try std.testing.expectEqualStrings("sleeper_volume", d.phases[0].nav_object);
    try std.testing.expectEqualStrings("return_to_trader", d.phases[1].nav_object);
    // The slice is arena-owned (not a view into the transient XML buffer).
    try std.testing.expect(d.phases[0].nav_object.len > 0);
}

test "loot group rewards parse ischosen/isfixed and quest chains carry the id" {
    const fixture =
        \\<?xml version="1.0"?>
        \\<quests starter_quest="tier1_clear">
        \\  <quest id="tier1_clear">
        \\    <property name="name_key" value="Clear"/>
        \\    <objective type="ClearSleepers" phase="1"/>
        \\    <reward type="LootItem" id="groupQuestWeapons" value="2" ischosen="true" isfixed="true"/>
        \\    <reward type="LootItem" id="gunPistolT2" value="1"/>
        \\    <reward type="Quest" id="quest_tier2complete"/>
        \\  </quest>
        \\</quests>
    ;
    var cat = try parseCatalog(std.testing.allocator, fixture, .{});
    defer cat.deinit();
    const d = cat.byName("tier1_clear").?;
    try std.testing.expectEqual(quest.RewardKind.loot_item, d.rewards[0].kind);
    try std.testing.expectEqualStrings("groupQuestWeapons", d.rewards[0].item_name);
    try std.testing.expect(d.rewards[0].is_chosen);
    try std.testing.expect(d.rewards[0].is_fixed);
    try std.testing.expectEqual(@as(u32, 2), d.rewards[0].value);
    try std.testing.expectEqual(quest.RewardKind.loot_item, d.rewards[1].kind);
    try std.testing.expect(!d.rewards[1].is_chosen);
    // Quest-chain rewards carry the chained quest id.
    try std.testing.expectEqual(quest.RewardKind.quest, d.rewards[2].kind);
    try std.testing.expectEqualStrings("quest_tier2complete", d.rewards[2].item_name);
}

test "objective meta scan derives quest tags / POI select kind / biome filter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Stock-shaped quest: RandomPOIGoto (tag-less) + ClearSleepers (clear) +
    // a Goto-family objective with the stock biome filter properties.
    const body =
        \\<quest id="tier1_clear">
        \\  <objective type="RandomPOIGoto" phase="1"/>
        \\  <objective type="ClearSleepers" phase="3">
        \\    <property name="biome_filter_type" value="OnlyBiome"/>
        \\    <property name="biome_filter" value="pine_forest,wasteland"/>
        \\    <property name="allow_current_poi" value="true"/>
        \\  </objective>
        \\  <objective type="ReturnToNPC" phase="4"/>
        \\</quest>
    ;
    const m = try scanObjectiveMeta(arena, body, &.{});
    try std.testing.expectEqual(@intFromEnum(quest.QuestTag.clear), m.tags_mask);
    // RandomPOIGoto wins the selector kind; ClearSleepers never does.
    try std.testing.expectEqual(quest.PoiSelectKind.random, m.poi_select);
    try std.testing.expectEqual(quest.biome_filter_only, m.biome_type);
    try std.testing.expectEqualStrings("pine_forest,wasteland", m.biome_filter);
    try std.testing.expect(m.allow_current_poi);

    // Goto/ClosestPOIGoto → closest; ExcludeBiome/SameBiome spellings.
    const body2 =
        \\<quest id="q">
        \\  <objective type="ClosestPOIGoto">
        \\    <property name="biome_filter_type" value="ExcludeBiome"/>
        \\    <property name="biome_filter" value="wasteland"/>
        \\  </objective>
        \\</quest>
    ;
    const m2 = try scanObjectiveMeta(arena, body2, &.{});
    try std.testing.expectEqual(quest.PoiSelectKind.closest, m2.poi_select);
    try std.testing.expectEqual(quest.biome_filter_exclude, m2.biome_type);
    try std.testing.expectEqualStrings("wasteland", m2.biome_filter);

    // No Goto-family objective → no selection, no tags.
    const body3 =
        \\<quest id="q"><objective type="FetchFromContainer" id="1" value="1"/></quest>
    ;
    const m3 = try scanObjectiveMeta(arena, body3, &.{});
    try std.testing.expectEqual(@intFromEnum(quest.QuestTag.fetch), m3.tags_mask);
    try std.testing.expectEqual(quest.PoiSelectKind.none, m3.poi_select);
    try std.testing.expectEqual(quest.biome_filter_none, m3.biome_type);

    // param1 variable substitution: the objective template default is
    // SameBiome, but the quest's `<variable name="biome_filter_type"
    // value="AnyBiome"/>` wins (18 stock variables, 8 AnyBiome). AnyBiome is
    // not a filter spelling, so the kind stays none.
    const body4 =
        \\<quest id="q">
        \\  <variable name="biome_filter_type" value="AnyBiome"/>
        \\  <objective type="RandomPOIGoto">
        \\    <property name="biome_filter_type" value="SameBiome" param1="biome_filter_type"/>
        \\  </objective>
        \\</quest>
    ;
    var vars4: [max_quest_vars]QuestVar = undefined;
    const vn4 = parseVariables(body4, &vars4);
    const m4 = try scanObjectiveMeta(arena, body4, vars4[0..vn4]);
    try std.testing.expectEqual(quest.biome_filter_none, m4.biome_type);
    // Without the variable the property default applies (SameBiome).
    const m5 = try scanObjectiveMeta(arena, body4, &.{});
    try std.testing.expectEqual(quest.biome_filter_same, m5.biome_type);

    // StayWithin carries its radius as a nested property (15 stock rows); the
    // phase graph must pick it up instead of the policy default.
    const body6 =
        \\<quest id="q">
        \\  <objective type="POIStayWithin" phase="1">
        \\    <property name="radius" value="25"/>
        \\  </objective>
        \\</quest>
    ;
    const graph = try buildPhaseGraph(arena, body6, 1, quest.builtin_objective_kinds[0..], .{});
    try std.testing.expectEqual(@as(usize, 1), graph.phases.len);
    try std.testing.expectApproxEqAbs(@as(f32, 25), graph.phases[0].radius, 1e-4);
}

test "SpawnGSEnemy action parses count range and gamestage list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body =
        \\<quest id="q">
        \\  <action type="SpawnGSEnemy">
        \\    <property name="gamestage_list" value="SleeperGSList"/>
        \\    <property name="count" value="1-2"/>
        \\    <property name="phase" value="4"/>
        \\  </action>
        \\  <action type="SpawnGSEnemy">
        \\    <property name="gamestage_list" value="SleeperGSList"/>
        \\    <property name="count" value="3"/>
        \\  </action>
        \\</quest>
    ;
    var specs: [quest.max_actions]quest.QuestActionSpec = undefined;
    const n = parseActions(arena, body, &specs);
    try std.testing.expectEqual(@as(u8, 2), n);
    try std.testing.expectEqual(quest.QuestActionKind.spawn_gs_enemy, specs[0].kind);
    try std.testing.expectEqualStrings("SleeperGSList", specs[0].name);
    try std.testing.expectEqual(@as(u8, 1), specs[0].count_min);
    try std.testing.expectEqual(@as(u8, 2), specs[0].count_max);
    try std.testing.expectEqual(@as(u8, 4), specs[0].phase);
    // A bare count means exactly that many.
    try std.testing.expectEqual(@as(u8, 3), specs[1].count_min);
    try std.testing.expectEqual(@as(u8, 3), specs[1].count_max);
}

test "TreasureRadiusReduction event parses chance, gamestage list and count range" {
    // Stock block (quests.xml: chance 0.25, 1-3 SleeperGSList, mirroring the
    // tier1_buried_supplies treasure dig) plus an unknown event type that must
    // be skipped and a second radius event with a bare count (no chance = 0 =
    // always fires).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body =
        \\<quest id="q">
        \\  <event type="TreasureRadiusReduction">
        \\    <property name="chance" value="0.25"/>
        \\    <action type="SpawnGSEnemy">
        \\      <property name="gamestage_list" value="SleeperGSList"/>
        \\      <property name="count" value="1-3"/>
        \\    </action>
        \\  </event>
        \\  <event type="SomeFutureEvent">
        \\    <property name="chance" value="1"/>
        \\  </event>
        \\  <event type="TreasureRadiusReduction">
        \\    <action type="SpawnGSEnemy">
        \\      <property name="gamestage_list" value="ZombieWastelandGS"/>
        \\      <property name="count" value="2"/>
        \\    </action>
        \\  </event>
        \\</quest>
    ;
    var specs: [quest.max_quest_events]quest.QuestEventSpec = undefined;
    const n = parseQuestEvents(arena, body, &specs);
    try std.testing.expectEqual(@as(u8, 2), n); // unknown type skipped
    try std.testing.expectEqual(@as(f32, 0.25), specs[0].chance);
    try std.testing.expectEqualStrings("SleeperGSList", specs[0].spawn_list);
    try std.testing.expectEqual(@as(u8, 1), specs[0].spawn_min);
    try std.testing.expectEqual(@as(u8, 3), specs[0].spawn_max);
    // No chance attribute → 0 = always fires.
    try std.testing.expectEqual(@as(f32, 0), specs[1].chance);
    try std.testing.expectEqualStrings("ZombieWastelandGS", specs[1].spawn_list);
    try std.testing.expectEqual(@as(u8, 2), specs[1].spawn_min);
    try std.testing.expectEqual(@as(u8, 2), specs[1].spawn_max);
}
