//! npc.xml: npc_info entries map a trader entity class (localization_id) and
//! display name to a traders.xml `<trader_info>` id plus its quest_list.

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const paths = @import("paths.zig");

pub const max_npcs: usize = 64;

pub const NpcEntry = struct {
    /// Entity class name (npc.xml localization_id matches entityclasses name,
    /// e.g. "npcTraderJen").
    class_name: []const u8 = "",
    /// Display name (npc.xml name attr, e.g. "Trader Jen").
    display_name: []const u8 = "",
    /// traders.xml trader_info id (npc.xml trader_id attr).
    trader_id: u16 = 0,
    /// Stock quest_list id (e.g. "trader_jen_quests"); "" when none.
    quest_list: []const u8 = "",
};

pub const NpcTable = struct {
    entries: []const NpcEntry = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *NpcTable) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
        }
        self.* = .{};
    }

    pub fn empty() NpcTable {
        return .{};
    }

    /// trader_info id for a trader class name (localization_id primary, display
    /// name fallback for the builtin pad spawn). 0 = unknown.
    pub fn traderIdForClass(self: *const NpcTable, class_name: []const u8) u16 {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.class_name, class_name)) return e.trader_id;
        }
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.display_name, class_name)) return e.trader_id;
        }
        return 0;
    }

    /// First quest_list for a trader_info id (stock keeps one per trader id;
    /// entries without a list, e.g. the junk drone, are skipped).
    pub fn questListForTrader(self: *const NpcTable, trader_id: u16) ?[]const u8 {
        for (self.entries) |e| {
            if (e.trader_id == trader_id and e.quest_list.len > 0) return e.quest_list;
        }
        return null;
    }
};

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !NpcTable {
    const raw = try io_fs.readFileAll(allocator, path);
    defer allocator.free(raw);
    const clean = try xml.stripComments(allocator, raw);
    defer allocator.free(clean);

    var arena_holder = try allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var entries: std.ArrayList(NpcEntry) = .empty;
    defer entries.deinit(allocator);
    var i: usize = 0;
    while (i < clean.len and entries.items.len < max_npcs) {
        const ni = std.mem.indexOfPos(u8, clean, i, "<npc_info") orelse break;
        i = ni + 9;
        const tid = xml.attr(clean, ni, "trader_id") orelse continue;
        const trader_id = std.fmt.parseInt(u16, tid, 10) catch continue;
        try entries.append(allocator, .{
            .class_name = try arena.dupe(u8, xml.attr(clean, ni, "localization_id") orelse ""),
            .display_name = try arena.dupe(u8, xml.attr(clean, ni, "name") orelse ""),
            .trader_id = trader_id,
            .quest_list = try arena.dupe(u8, xml.attr(clean, ni, "quest_list") orelse ""),
        });
    }
    if (entries.items.len == 0) return error.OpenFailed;

    const esl = try arena.alloc(NpcEntry, entries.items.len);
    @memcpy(esl, entries.items);
    return .{ .entries = esl, .arena_ptr = arena_holder };
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) ?NpcTable {
    return paths.tryLoadConfig("npc.xml", NpcTable, loadFromPath, allocator, game_dir, config_dir) catch null;
}

test "npc table maps the five stock trader classes to trader_info ids" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/npc.xml";
    var t = loadFromPath(std.testing.allocator, path) catch return error.SkipZigTest;
    defer t.deinit();
    try std.testing.expectEqual(@as(u16, 1), t.traderIdForClass("npcTraderJoel"));
    try std.testing.expectEqual(@as(u16, 2), t.traderIdForClass("npcTraderJen"));
    try std.testing.expectEqual(@as(u16, 6), t.traderIdForClass("npcTraderBob"));
    try std.testing.expectEqual(@as(u16, 7), t.traderIdForClass("npcTraderHugh"));
    try std.testing.expectEqual(@as(u16, 8), t.traderIdForClass("npcTraderRekt"));
    try std.testing.expectEqual(@as(u16, 2), t.traderIdForClass("Trader Jen"));
    try std.testing.expectEqual(@as(u16, 9), t.traderIdForClass("Trader Test"));
    try std.testing.expectEqual(@as(u16, 0), t.traderIdForClass("npcTraderMissing"));
    try std.testing.expectEqualStrings("trader_joel_quests", t.questListForTrader(1).?);
    try std.testing.expectEqualStrings("trader_jen_quests", t.questListForTrader(2).?);
    try std.testing.expectEqualStrings("trader_bob_quests", t.questListForTrader(6).?);
    try std.testing.expectEqualStrings("trader_hugh_quests", t.questListForTrader(7).?);
    try std.testing.expectEqualStrings("trader_rekt_quests", t.questListForTrader(8).?);
    try std.testing.expectEqualStrings("test_quests", t.questListForTrader(9).?);
}
