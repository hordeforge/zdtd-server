//! Config-file advertisement extracted from game.zig sendLocalConfigFiles.

const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const ln_peer = @import("../../litenet/peer.zig");
const wire_binary = @import("../../wire/binary.zig");

pub fn sendLocalConfigFiles(self: *Game, peer: *ln_peer.Peer) !void {
    const names = [_][]const u8{
        "events",               "materials",          "physicsbodies",   "painting",          "shapes",               "blocks",
        "progression",          "buffs",              "misc",            "items",             "item_modifiers",       "entityclasses",
        "qualityinfo",          "sounds",             "recipes",         "blockplaceholders", "loot",                 "entitygroups",
        "utilityai",            "vehicles",           "weathersurvival", "archetypes",        "challenges",           "quests",
        "traders",              "npc",                "dialogs",         "ui_display",        "nav_objects",          "gameevents",
        "twitch",               "twitch_events",      "dmscontent",      "XUi_Common/styles", "XUi_Common/templates", "XUi_InGame/styles",
        "XUi_InGame/templates", "XUi_InGame/windows", "XUi_InGame/xui",  "biomes",            "worldglobal",          "sandbox_overrides",
    };
    for (names) |name| {
        var w: wire_binary.Writer = .{ .buf = self.body_buf[0..] };
        try w.writeString(name);
        try w.writeI32(-1);
        try self.sendGame(peer, "NetPackageConfigFile", w.written());
        peer.resendPending(&self.net.sock) catch self.harness.counters.inc(.net_send_errors);
        self.pollNetOnce();
    }
}
