//! Quest catalog (shared resource) + definition types.
//! Runtime journal/wallet live as SoA components; mutations are in systems.zig.

const std = @import("std");
const c = @import("components.zig");

pub const max_quests: usize = 512;
pub const max_journal = c.max_journal;

pub const QuestKind = enum(u8) {
    kill_zombies,
    goto_point,
    fetch_trader,
    fetch_item,
    craft,
    stay_within,
};

/// Max phases per quest (stock CurrentPhase is uint8; real quests stay well under this).
pub const max_phases: usize = 32;

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
    rally,
    auto,
};

/// One phase of the quest graph: the advancing objective kind + required count.
/// Grounded in Quest.refreshQuestCompletion (asm.il 983645-983904): a phase
/// completes when its tracked count objective reaches its required Value.
pub const PhaseSpec = struct {
    kind: PhaseKind,
    required: u16 = 1,
};

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
    turn_in: bool = false,
    category: []const u8 = "quest",
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
    item_name: []const u8 = "", // Item/LootItem id attr (catalog arena slice)
    value: u32 = 0, // count for items, amount for exp/skill
};

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
