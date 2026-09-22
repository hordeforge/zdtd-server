//! NPC catalog tests: trader class mapping.
//!
//! Split out of assets/npc.zig (same tests, moved verbatim).

const std = @import("std");
const npc = @import("npc.zig");
const loadFromPath = npc.loadFromPath;
const xml = @import("xml_util.zig");
const stock_paths = @import("../util/stock_paths.zig");
const io_fs = @import("../util/io_fs.zig");

test "npc table maps the five stock trader classes to trader_info ids" {
    const path = stock_paths.configFile("npc.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
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
