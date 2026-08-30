//! Quest catalog (shared resource) + definition types.
//! Runtime journal/wallet live as SoA components; mutations are in systems.zig.

const std = @import("std");
const c = @import("components.zig");

pub const max_journal = c.max_journal;
pub const max_quest_objectives = c.max_quest_objectives;

pub const QuestKind = enum(u8) {
    kill_zombies,
    goto_point,
    fetch_trader,
    fetch_item,
    craft,
    stay_within,
    block_activate,
};

/// Stock quest tag names (QuestEventManager statics, il/full-v3.1.0/_global/
/// QuestEventManager.il.txt IL_0024-IL_0088): manual, trader, clear, treasure,
/// fetch, crafting, restore_power, infested, bandit; plus `hidden_cache`, which
/// ObjectiveFetchFromContainer adds for its hidden-cache fetch mode. The bit
/// values are a zdtd-owned transport for the stock tag strings.
pub const QuestTag = enum(u32) {
    manual = 1 << 0,
    trader = 1 << 1,
    clear = 1 << 2,
    treasure = 1 << 3,
    fetch = 1 << 4,
    crafting = 1 << 5,
    restore_power = 1 << 6,
    infested = 1 << 7,
    bandit = 1 << 8,
    hidden_cache = 1 << 9,
};

/// Map a stock tag string ("clear", "fetch", ...) to its bit; null when the
/// name is unknown (fail-closed: unknown tags contribute nothing).
pub fn tagBit(name: []const u8) ?u32 {
    inline for (std.meta.fields(QuestTag)) |f| {
        if (std.mem.eql(u8, name, f.name)) return @intCast(f.value);
    }
    return null;
}

/// Comma-separated tag list ("clear, fetch") → OR of bits; 0 when empty.
pub fn tagsMask(list: []const u8) u32 {
    var mask: u32 = 0;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " ");
        if (t.len == 0) continue;
        if (tagBit(t)) |b| mask |= b;
    }
    return mask;
}

/// Stock BaseObjective.SetupQuestTag map (il/full-v3.1.0/_global/Objective*.il.txt):
/// which objective `type=` adds which tag to Quest.QuestTags. Unknown types add
/// nothing (BaseObjective.SetupQuestTag is an empty IL=1 method).
pub fn objectiveTag(obj_type: []const u8) u32 {
    if (std.mem.eql(u8, obj_type, "ClearSleepers")) return @intFromEnum(QuestTag.clear);
    if (std.mem.eql(u8, obj_type, "FetchFromContainer") or
        std.mem.eql(u8, obj_type, "FetchKeep") or
        std.mem.eql(u8, obj_type, "FetchAnyContainer") or
        std.mem.eql(u8, obj_type, "BaseFetchContainer")) return @intFromEnum(QuestTag.fetch);
    if (std.mem.eql(u8, obj_type, "Craft") or
        std.mem.eql(u8, obj_type, "CraftItem") or
        std.mem.eql(u8, obj_type, "TreasureChest")) return @intFromEnum(QuestTag.crafting);
    if (std.mem.eql(u8, obj_type, "POIBlockActivate") or
        std.mem.eql(u8, obj_type, "POIBlockUpgrade")) return @intFromEnum(QuestTag.restore_power);
    return 0;
}

/// Stock BiomeFilterTypes (ObjectiveGoto field; selector switch in
/// DynamicPrefabDecorator.GetRandomPOINearWorldPos IL_013D-IL_01D9):
/// 0 None, 1 ExcludeBiome, 2 OnlyBiome (comma list), 3 SameBiome (anchor biome).
pub const biome_filter_none: u8 = 0;
pub const biome_filter_exclude: u8 = 1;
pub const biome_filter_only: u8 = 2;
pub const biome_filter_same: u8 = 3;

/// How a quest's POI is chosen (stock objective family): `.random` =
/// ObjectiveRandomPOIGoto (GetRandomPOI*), `.closest` =
/// ObjectiveGoto/ClosestPOIGoto (GetClosestPOIToWorldPos), `.none` = no
/// selection (static position or base SetupPosition).
pub const PoiSelectKind = enum(u8) { none = 0, random, closest };

/// Stock Prefab.GetQuestTag = questTags.Test_AllSet (il/full-v3.1.0/_global/
/// Prefab.il.txt IL=5): the prefab must carry **every** tag the quest carries.
/// An empty quest tag set matches everything (vacuous AllSet).
pub fn prefabMatches(prefab_mask: u32, quest_mask: u32) bool {
    if (quest_mask == 0) return true;
    return (prefab_mask & quest_mask) == quest_mask;
}

/// Quest POI selector request (stock Quest.SetupPosition / Objective*GetPosition
/// inputs). Filled by the sim; the Game hook performs the selection against the
/// prefab index + biome map + lockout state.
pub const QuestPoiParams = struct {
    kind: PoiSelectKind = .none,
    /// Anchor: the player's position on accept, the trader's on offers.
    anchor_x: f32 = 0,
    anchor_z: f32 = 0,
    /// Quest.QuestTags mask (objective-derived, SetupTags).
    tags_mask: u32 = 0,
    /// Quest difficulty tier (stock ObjectiveRandomPOIGoto.get_POITier).
    tier: u8 = 0,
    biome_type: u8 = 0,
    biome_filter: []const u8 = "",
    /// Closest path: exclude the POI the anchor is inside unless the objective
    /// sets `allow_current_poi` (stock ObjectiveGoto.allowCurrentPoi, fed to
    /// GetClosestPOIToWorldPos as `ignoreCurrentPoi = !allowCurrentPoi`).
    allow_current_poi: bool = false,
    /// Trader path: stock GetRandomPOINearTrader (distance bands +
    /// ValidPrefabForQuest) instead of GetRandomPOINearWorldPos.
    is_trader: bool = false,
    /// Player entity id for CheckForPOILockouts (bedroll/claim/quest-lock).
    entity_id: i32 = -1,
};

/// Selector result: the POI rect (bbox origin + size → PositionData 2/3), the
/// center at terrain height (Quest.Position / wire QuestLocation) and the
/// prefab name (DataVariables["POIName"]).
pub const PoiSelect = struct {
    rect: c.PoiRect = .{},
    center_x: f32 = 0,
    center_y: f32 = 0,
    center_z: f32 = 0,
    /// Prefab name; a slice into the prefab index (stable for the Game's
    /// lifetime — the caller must not retain it past the index).
    name: []const u8 = "",

    pub fn valid(self: PoiSelect) bool {
        return self.rect.valid();
    }
};

/// Max phases per quest (stock CurrentPhase is uint8; real quests stay well under this).
pub const max_phases: usize = 32;

/// Quest sim-policy tunables (ADR 0021: server policy is config, not parse
/// arms). Defaults for objectives whose XML omits a count/distance; the
/// effective values come from `[quests]` (mode pack < zdtd.toml, merged in
/// main.zig) and ride on the catalog (`w.catalog.policy`). Provenance:
/// PROVENANCE.md §3.7 (the kill-count tier formula and radii defaults are
/// zdtd-owned; stock objective `value`s always win when present).
pub const QuestPolicy = struct {
    /// `[quests] objective_kinds` spec ("Type=PhaseKind, ..."); null/empty =
    /// builtin stock mapping only.
    objective_kinds: ?[]const u8 = null,
    /// Base kill count for a kill objective with no explicit `value`
    /// (ClearSleepers/EntityKill without one). Phase target =
    /// `default_kill_count + tier * kill_per_tier`.
    default_kill_count: u8 = 3,
    kill_per_tier: u8 = 2,
    /// Arrival radius fallback (metres) for a goto phase whose objective has
    /// no `value` distance (stock ObjectiveGoto::distance).
    goto_radius: f32 = 4.0,
    /// Stay radius fallback for a stay-within phase/objective with no parsed
    /// distance (`max(stay_radius, required)` keeps the legacy behaviour).
    stay_radius: f32 = 8.0,
    /// POI selection band (blocks) for random-POI-goto objectives (RE
    /// ObjectiveRandomPOIGoto: min/max distance) and the search budget.
    poi_min_dist: f32 = 32,
    poi_max_dist: f32 = 2000,
    max_poi_attempts: u32 = 50,
    /// Quest-POI bed lockout radius (blocks; hooks.zig homeLockout 32 m).
    poi_bed_lockout_radius: f32 = 32,
    /// GetRandomPOINearTrader distance bands (blocks; stock 500/1500 m).
    trader_band_1: f32 = 500,
    trader_band_2: f32 = 1500,
};

/// Objective `type=` -> phase-kind mapping, config rows first (zdtd.toml /
/// mode pack `[quests] objective_kinds`) then the builtin stock defaults.
/// parseCatalog replaces the default with the merged table.
pub const ObjectiveKindMap = struct {
    obj_type: []const u8,
    kind: PhaseKind,
};

/// Builtin default mapping for the stock objective family — 23 `type=`
/// spellings, covering the 16 used by the shipped `Data/Config/quests.xml`
/// (2026-08-09 census) plus stock variants the shipped quests do not
/// exercise (facts of the stock game, like wire constants). Config entries
/// override or extend these: the merged table the catalog carries scans
/// config rows before these defaults.
pub const builtin_objective_kinds = [_]ObjectiveKindMap{
    .{ .obj_type = "RallyPoint", .kind = .rally },
    .{ .obj_type = "ClearSleepers", .kind = .kill_zombies },
    .{ .obj_type = "EntityKill", .kind = .kill_zombies },
    .{ .obj_type = "AnimalKill", .kind = .kill_zombies },
    .{ .obj_type = "FetchKeep", .kind = .fetch_item },
    .{ .obj_type = "FetchFromContainer", .kind = .fetch_item },
    .{ .obj_type = "FetchFromTreasure", .kind = .fetch_item },
    .{ .obj_type = "TreasureChest", .kind = .fetch_item },
    .{ .obj_type = "InteractWithNPC", .kind = .trader_interact },
    .{ .obj_type = "ReturnToNPC", .kind = .trader_interact },
    .{ .obj_type = "RandomGotoNPC", .kind = .trader_interact },
    .{ .obj_type = "Craft", .kind = .craft },
    .{ .obj_type = "CraftItem", .kind = .craft },
    .{ .obj_type = "Recipe", .kind = .craft },
    .{ .obj_type = "StayWithin", .kind = .stay_within },
    .{ .obj_type = "StayWithinArea", .kind = .stay_within },
    .{ .obj_type = "POIStayWithin", .kind = .stay_within },
    .{ .obj_type = "POIBlockActivate", .kind = .block_activate },
    .{ .obj_type = "BlockActivate", .kind = .block_activate },
    .{ .obj_type = "Goto", .kind = .goto_point },
    .{ .obj_type = "RandomPOIGoto", .kind = .goto_point },
    .{ .obj_type = "ClosestPOIGoto", .kind = .goto_point },
    .{ .obj_type = "RandomGoto", .kind = .goto_point },
};

/// Resolve an objective `type=` attribute to an executable phase kind.
/// `table` is the catalog's merged mapping (config rows first, then the
/// builtin defaults); the stock `Goto`/`RandomGoto` `id="trader"` special case
/// is a hardcoded game fact and wins; an unknown type degrades to `.auto`
/// scaffolding (fail-closed: the phase auto-completes rather than deadlocking
/// the quest — see phaseIsScaffolding).
pub fn kindForObjective(table: []const ObjectiveKindMap, obj_type: []const u8, obj_id: ?[]const u8) PhaseKind {
    if (obj_id) |id| {
        if ((std.mem.eql(u8, obj_type, "Goto") or std.mem.eql(u8, obj_type, "RandomGoto")) and
            std.mem.eql(u8, id, "trader")) return .trader_interact;
    }
    for (table) |m| {
        if (std.mem.eql(u8, m.obj_type, obj_type)) return m.kind;
    }
    return .auto;
}

/// Advancing objective kind driving a single quest phase.
/// Mirrors the stock BaseObjective family collapsed to what the sim can execute.
/// `rally` waits for the client's rally-marker activation, but only when the
/// quest instance carries a POI rect; without one it degrades to scaffolding.
/// `auto` = scaffolding-only phase (unmodelled objective / empty) that
/// auto-completes on entry (see honest gaps in docs/GAP_ANALYSIS.md).
pub const PhaseKind = enum(u8) {
    kill_zombies,
    goto_point,
    fetch_item,
    trader_interact,
    craft,
    stay_within,
    block_activate,
    rally,
    auto,
};

/// One phase of the quest graph: the advancing objective kind + required count.
/// Grounded in Quest.refreshQuestCompletion (asm.il 983645-983904): a phase
/// completes when its tracked count objective reaches its required Value.
/// `radius` (metres) carries the ObjectiveGoto/StayWithin distance — stock
/// parses those `value`s as a float distance, not a count; 0 = the sim default
/// (4 m goto, `max(8, required)` stay-within). Ignored by count kinds.
pub const PhaseSpec = struct {
    kind: PhaseKind,
    required: u16 = 1,
    radius: f32 = 0,
    /// nav_objects.xml class for this phase's marker (quests.xml objective
    /// `<property name="nav_object">`), e.g. quest / rally / sleeper_volume /
    /// treasure / go_to_trader / return_to_trader. Empty = legacy fallback.
    nav_object: []const u8 = "",
    /// True when the driving objective is ClearSleepers (stock
    /// QuestEvent_SleepersCleared): kills only count when they happen inside
    /// the quest's bound POI rect, not anywhere on the map.
    poi_gated: bool = false,
};

/// Quest catalog row defaults before quests.xml loads (stock XML wins at
/// runtime). reward_coin / difficulty_tier / target_count mirror the stock
/// quest template fields.
pub const QuestDef = struct {
    id: u16,
    kind: QuestKind,
    name: []const u8 = "",
    title: []const u8,
    target_count: u16 = 1,
    tx: f32 = 0,
    ty: f32 = 70,
    tz: f32 = 0,
    reward_coin: u32 = 10,
    difficulty_tier: u8 = 0,
    /// QuestClass stage modifiers (progression.md 5 get_gameStage: the active
    /// quest's terms multiply/add onto the player stage). Stock quests.xml:
    /// `<property name="gamestage_mod" value=".6"/>` /
    /// `gamestage_bonus` (7 stock quests, e.g. the infested clears).
    gamestage_mod: f32 = 0,
    gamestage_bonus: f32 = 0,
    turn_in: bool = false,
    category: []const u8 = "quest",
    /// Objective-derived quest tags (union of BaseObjective.SetupQuestTag):
    /// the stock `Quest.QuestTags` the POI selector matches with
    /// Prefab.GetQuestTag (Test_AllSet).
    quest_tags: u32 = 0,
    /// POI selection kind from the objective family: `.random` =
    /// ObjectiveRandomPOIGoto, `.closest` = ObjectiveGoto/ClosestPOIGoto,
    /// `.none` = static or no POI.
    poi_select: PoiSelectKind = .none,
    /// First Goto-family objective's biome filter (stock ObjectiveGoto
    /// biomeFilterType / biomeFilter, biomes.xml names; quests.xml
    /// `biome_filter_type` = ExcludeBiome | OnlyBiome | SameBiome).
    biome_filter_type: u8 = biome_filter_none,
    biome_filter: []const u8 = "",
    /// First Goto-family objective's `allow_current_poi` (stock
    /// ObjectiveGoto.allowCurrentPoi): the closest selector may pick the POI
    /// the player is currently inside.
    allow_current_poi: bool = false,
    /// Stock client CreateQuest objective list length (for Quest.Write).
    objective_count: u8 = 1,
    /// Stock client CreateQuest reward list length (for Quest.Write).
    reward_count: u8 = 1,
    /// Per-reward: true if RewardItem/RewardLootItem (ItemStack after index).
    /// Length used is reward_count (capped at max_reward_flags).
    reward_has_item: [max_reward_flags]bool = .{false} ** max_reward_flags,
    /// Parsed `<reward>` list in document order (length reward_n). The journal
    /// wire writes real ItemStacks from these and turn-in pays them out.
    rewards: [max_reward_flags]RewardSpec = [_]RewardSpec{.{}} ** max_reward_flags,
    reward_n: u8 = 0,
    /// Parsed `<action>` list in document order (length action_n). UnlockPOI
    /// fires server-side on phase entry; the rest are recorded for the client.
    actions: [max_actions]QuestActionSpec = [_]QuestActionSpec{.{}} ** max_actions,
    action_n: u8 = 0,
    /// Parsed `<event>` blocks (stock QuestClass events; only
    /// TreasureRadiusReduction exists in the stock file). The client triggers
    /// them mid-quest; the server rolls chance and fires the nested spawn.
    events: [max_quest_events]QuestEventSpec = [_]QuestEventSpec{.{}} ** max_quest_events,
    event_n: u8 = 0,
    /// Ordered phase graph (index i == phase i+1). Empty = legacy single-kind path
    /// keyed on `kind`/`target_count`. Grounded in Quest.AdvancePhase (asm.il 982816).
    phases: []const PhaseSpec = &.{},
    /// max objective `phase` attribute == phases.len; 0 = legacy. QuestClass.HighestPhase.
    highest_phase: u8 = 0,
    /// Phase number (1-based) per flat objective, length objective_count, for the wire.
    objective_phases: []const u8 = &.{},
    /// Objective Write subclass per flat objective (length objective_count,
    /// same order as objective_phases). Mirrors the wire ObjectiveWriteKind;
    /// ecs stays wire-free, game.zig maps this to the stock enum.
    objective_kinds: []const ObjectiveWireKind = &.{},
    /// Flat objective list (XML-parsed quests only; builtin/legacy defs leave
    /// it empty and keep the single-progress path). Drives per-objective phase
    /// completion: stock Quest.refreshQuestCompletion requires ALL non-optional
    /// objectives of the current phase (plus always-active phase-0 objectives)
    /// to be complete before the phase advances.
    objectives: []const FlatObjective = &.{},
};

/// One flat objective (stock BaseObjective), same order as the client's
/// CreateQuest objective list. `required` carries the count the objective
/// needs (stock `currentValue >= required`); `optional` objectives never
/// block the phase; `force` (ForcePhaseFinish) fails the quest if left
/// incomplete. Grounded in Quest.refreshQuestCompletion (asm.il 983645-983904).
pub const FlatObjective = struct {
    /// Stock BaseObjective.Phase (1-based; 0 = always-active, checked in
    /// every phase).
    phase: u8 = 1,
    kind: PhaseKind = .auto,
    required: u16 = 1,
    optional: bool = false,
    force: bool = false,
    /// ClearSleepers objectives gate kills to the bound POI (stock
    /// ObjectiveClearSleepers counts the volume spawns as the target).
    poi_gated: bool = false,
};

/// Objective Write subclass (Quest.Write CreateQuest): BaseObjective writes
/// FileVersion + CurrentValue, ObjectiveTreasureChest writes destroyCount +
/// CurrentRadius (no base call), ObjectivePOIStayWithin writes nothing extra.
pub const ObjectiveWireKind = enum(u8) {
    base = 0,
    treasure_chest = 1,
    empty = 2,
};

pub const max_reward_flags: usize = 16;
/// Max `<action>` elements per quest (stock quests carry at most 2; cap for
/// modded files).
pub const max_actions: usize = 8;

/// One `<reward>` element kind (quests.xml `type` attribute).
pub const RewardKind = enum(u8) {
    item,
    loot_item,
    exp,
    skill,
    skill_points,
    quest,
    show_message_window,
    other,
};

/// One `<reward>` element: kind plus the wire and payout fields (Item/LootItem
/// carry an item name and a count; Exp carries an amount).
pub const RewardSpec = struct {
    kind: RewardKind = .other,
    item_name: []const u8 = "", // Item/LootItem/Quest id attr (catalog arena slice)
    value: u32 = 0, // count for items, amount for exp/skill
    /// `<reward ischosen="true">`: the value counts prob-weighted picks from
    /// a loot group (LootItem) instead of a plain item stack.
    is_chosen: bool = false,
    /// `<reward isfixed="true">`: the chosen picks are the first `value`
    /// group entries (deterministic).
    is_fixed: bool = false,
};

/// One `<action>` element kind (quests.xml `type` attribute). Server-side
/// firing is implemented only for the kinds that touch world state; the rest
/// are parsed and recorded (the owning player's client runs them locally in
/// stock, or they need a subsystem zdtd does not have yet).
pub const QuestActionKind = enum(u8) {
    unlock_poi,
    set_cvar,
    show_message_window,
    spawn_gs_enemy,
    game_event,
    other,
};

/// One `<action>` element. `phase` gates UnlockPOI (stock fires the action
/// when the quest reaches that phase); name/value carry the cvar, message,
/// event or gamestage properties.
pub const QuestActionSpec = struct {
    kind: QuestActionKind = .other,
    phase: u8 = 0,
    name: []const u8 = "",
    value: []const u8 = "",
    /// SpawnGSEnemy: the `count` property ("1-2") as a min/max range of
    /// gamestage-scaled enemies (stock QuestActionSpawnGSEnemy).
    count_min: u8 = 1,
    count_max: u8 = 1,
};

/// A quest `<event>` block (stock QuestClass events): the client triggers it
/// mid-quest (e.g. TreasureRadiusReduction on each treasure dig step) and the
/// server rolls the event's `chance` and fires the nested actions. Stock
/// quests.xml uses only TreasureRadiusReduction with a SpawnGSEnemy action.
pub const QuestEventSpec = struct {
    /// Stock `chance` (0..1) the event fires per trigger; 0 = always.
    chance: f32 = 0,
    /// The nested SpawnGSEnemy action (gamestage list + count range); empty =
    /// no spawn (the event only relays).
    spawn_list: []const u8 = "",
    spawn_min: u8 = 1,
    spawn_max: u8 = 1,
};

pub const max_quest_events: usize = 4;

pub const QuestList = struct {
    id: []const u8,
    entries: []const u16,
};

pub const CatalogSource = enum { builtin, stock_xml };

pub const Catalog = struct {
    defs: []const QuestDef = builtin_defs[0..],
    lists: []const QuestList = &.{},
    starter_id: u16 = 1,
    starter_name: []const u8 = "clear_the_noise",
    max_tier: u8 = 0,
    quests_per_tier: u8 = 0,
    source: CatalogSource = .builtin,
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    source_path: []const u8 = "",
    /// Objective `type=` -> phase-kind mapping, config rows first (zdtd.toml /
    /// mode pack `[quests] objective_kinds`) then the builtin stock defaults.
    /// parseCatalog replaces the default with the merged table.
    objective_kinds: []const ObjectiveKindMap = builtin_objective_kinds[0..],
    /// Effective quest sim-policy tunables (ADR 0021): kill-count defaults,
    /// goto/stay radius fallbacks — merged from `[quests]` by main.zig.
    policy: QuestPolicy = .{},

    pub fn builtin() Catalog {
        return .{
            .defs = builtin_defs[0..],
            .lists = &.{},
            .starter_id = 1,
            .starter_name = "clear_the_noise",
            .source = .builtin,
        };
    }

    pub fn deinit(self: *Catalog) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = Catalog.builtin();
    }

    pub fn byId(self: *const Catalog, id: u16) ?QuestDef {
        // defs are appended in id order starting at 1 (see quests.zig
        // parseCatalog's next_id and builtin_defs below), so id-1 is almost
        // always the right slot; scan only on mismatch (modded/gappy catalogs).
        if (id != 0) {
            const guess = @as(usize, id - 1);
            if (guess < self.defs.len and self.defs[guess].id == id) return self.defs[guess];
        }
        for (self.defs) |d| if (d.id == id) return d;
        return null;
    }

    pub fn byName(self: *const Catalog, name: []const u8) ?QuestDef {
        for (self.defs) |d| {
            if (d.name.len != 0 and std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    pub fn listById(self: *const Catalog, list_id: []const u8) ?QuestList {
        for (self.lists) |l| {
            if (std.mem.eql(u8, l.id, list_id)) return l;
        }
        return null;
    }
};

pub const QuestProgress = c.QuestProgress;
pub const Journal = c.Journal;

const clear_noise_phases = [_]PhaseSpec{.{ .kind = .kill_zombies, .required = 3 }};
const scout_ridge_phases = [_]PhaseSpec{.{ .kind = .goto_point, .required = 1 }};
const visit_trader_phases = [_]PhaseSpec{
    .{ .kind = .goto_point, .required = 1 },
    .{ .kind = .trader_interact, .required = 1 },
};

pub const builtin_defs = [_]QuestDef{
    .{
        .id = 1,
        .kind = .kill_zombies,
        .name = "clear_the_noise",
        .title = "Clear the noise",
        .target_count = 3,
        .reward_coin = 25,
        .objective_count = 1,
        .reward_count = 1,
        .phases = &clear_noise_phases,
        .highest_phase = 1,
        .objective_phases = &[_]u8{1},
    },
    .{
        .id = 2,
        .kind = .goto_point,
        .name = "scout_the_ridge",
        .title = "Scout the ridge",
        .target_count = 1,
        .tx = 50,
        .ty = 70,
        .tz = 50,
        .reward_coin = 15,
        .objective_count = 1,
        .reward_count = 1,
        .phases = &scout_ridge_phases,
        .highest_phase = 1,
        .objective_phases = &[_]u8{1},
    },
    .{
        .id = 3,
        .kind = .fetch_trader,
        .name = "visit_the_trader",
        .title = "Visit the trader",
        .target_count = 1,
        .reward_coin = 20,
        .objective_count = 2,
        .reward_count = 1,
        .phases = &visit_trader_phases,
        .highest_phase = 2,
        .objective_phases = &[_]u8{ 1, 2 },
    },
};

test "quest tag bit helpers mirror the stock SetupQuestTag map" {
    // Stock objective → tag map (Objective*.il.txt SetupQuestTag overrides).
    try std.testing.expectEqual(@intFromEnum(QuestTag.clear), objectiveTag("ClearSleepers"));
    try std.testing.expectEqual(@intFromEnum(QuestTag.fetch), objectiveTag("FetchFromContainer"));
    try std.testing.expectEqual(@intFromEnum(QuestTag.fetch), objectiveTag("FetchKeep"));
    try std.testing.expectEqual(@intFromEnum(QuestTag.fetch), objectiveTag("FetchAnyContainer"));
    try std.testing.expectEqual(@intFromEnum(QuestTag.crafting), objectiveTag("Craft"));
    try std.testing.expectEqual(@intFromEnum(QuestTag.crafting), objectiveTag("TreasureChest"));
    try std.testing.expectEqual(@intFromEnum(QuestTag.restore_power), objectiveTag("POIBlockActivate"));
    try std.testing.expectEqual(@intFromEnum(QuestTag.restore_power), objectiveTag("POIBlockUpgrade"));
    // BaseObjective.SetupQuestTag is empty: RallyPoint / Goto / RandomPOIGoto /
    // EntityKill / POIStayWithin add nothing.
    try std.testing.expectEqual(@as(u32, 0), objectiveTag("RallyPoint"));
    try std.testing.expectEqual(@as(u32, 0), objectiveTag("RandomPOIGoto"));
    try std.testing.expectEqual(@as(u32, 0), objectiveTag("EntityKill"));
    try std.testing.expectEqual(@as(u32, 0), objectiveTag("POIStayWithin"));
    // tagsMask splits + trims comma lists; unknown tags are fail-closed zeros.
    try std.testing.expectEqual(@intFromEnum(QuestTag.clear), tagsMask("clear"));
    try std.testing.expectEqual(
        @intFromEnum(QuestTag.clear) | @intFromEnum(QuestTag.fetch),
        tagsMask(" clear , fetch "),
    );
    try std.testing.expectEqual(@as(u32, 0), tagsMask("not_a_tag"));
    try std.testing.expectEqual(@as(u32, 0), tagsMask(""));
}

test "prefabMatches is stock Test_AllSet" {
    try std.testing.expect(prefabMatches(@intFromEnum(QuestTag.clear), @intFromEnum(QuestTag.clear)));
    // Prefab has every quest tag → true; missing one → false.
    const both = @intFromEnum(QuestTag.clear) | @intFromEnum(QuestTag.fetch);
    try std.testing.expect(prefabMatches(both, @intFromEnum(QuestTag.clear)));
    try std.testing.expect(!prefabMatches(@intFromEnum(QuestTag.clear), both));
    // Empty quest tag set matches everything (vacuous AllSet).
    try std.testing.expect(prefabMatches(0, 0));
    try std.testing.expect(prefabMatches(@intFromEnum(QuestTag.clear), 0));
}
