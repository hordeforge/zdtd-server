//! Game-wide constants re-exported by game.zig. Keeps the 40-line help table
//! and a few caps out of the main file. Behavior-identical: re-exported as
//! `pub const` from game.zig so external refs keep compiling.

const protocol = @import("../../protocol.zig");
const admin_cmds = @import("../admin_cmds.zig");
const persist = @import("../persist.zig");

pub const max_quest_position_data: usize = 3;
pub const apm_report_period_ticks: u64 = protocol.ticks_per_second * 60;

pub const admin_help_index = [_]admin_cmds.HelpEntry{
    .{ .names = "admin", .description = "Manage user permission levels" },
    .{ .names = "apm, metrics", .description = "zdtd: server APM counters and section latency" },
    .{ .names = "ban", .description = "Manage ban entries" },
    .{ .names = "chunkcache, cc", .description = "Display cached chunks" },
    .{ .names = "evidence, ev", .description = "zdtd: recent authority reject evidence ring" },
    .{ .names = "getgamepref, gg", .description = "Gets game preferences" },
    .{ .names = "gettime, gt", .description = "Get the current game time" },
    .{ .names = "give", .description = "zdtd: drop an item stack at a player's feet" },
    .{ .names = "giveself, gi", .description = "zdtd: grant items to your own inventory" },
    .{ .names = "clearweather, stormoff", .description = "zdtd: end any active storm; next storm a day out" },
    .{ .names = "spawnairdrop", .description = "zdtd: trigger an air drop immediately" },
    .{ .names = "storm", .description = "zdtd: force every storm-capable biome into an active storm" },
    .{ .names = "guardclear, gc", .description = "zdtd: clear guard quarantine on a peer slot" },
    .{ .names = "guardstats, gs", .description = "zdtd: C2S authority reject counters" },
    .{ .names = "help", .description = "Help on console and specific commands" },
    .{ .names = "inv", .description = "zdtd: dump a joined peer's inventory slots" },
    .{ .names = "kick", .description = "Kicks user with optional reason" },
    .{ .names = "kickall", .description = "Kicks all users with optional reason" },
    .{ .names = "kill", .description = "Kill an entity by id" },
    .{ .names = "killall, ka", .description = "Kill all AI entities" },
    .{ .names = "listents, le", .description = "lists all entities" },
    .{ .names = "listplayerids, lpi", .description = "Lists all players with their IDs for ingame commands" },
    .{ .names = "listplayers, lp", .description = "lists all players" },
    .{ .names = "mem", .description = "Prints memory information" },
    .{ .names = "save", .description = "zdtd: save player records" },
    .{ .names = "saveworld, sa", .description = "Saves the world manually" },
    .{ .names = "say", .description = "Sends a message to all connected clients" },
    .{ .names = "setgamepref, sg", .description = "Sets a game pref" },
    .{ .names = "settime, st", .description = "Set the current game time" },
    .{ .names = "shutdown", .description = "shuts down the game server" },
    .{ .names = "spawnentity, se", .description = "spawns an entity" },
    .{ .names = "status", .description = "zdtd: one-line load and error counters" },
    .{ .names = "tele, tp", .description = "zdtd: teleport a player (stock tp is client-only)" },
    .{ .names = "unban", .description = "zdtd: drop a raw IPv4 ban" },
    .{ .names = "version", .description = "Get the currently running version" },
    .{ .names = "whitelist", .description = "Manage whitelist entries" },
    .{ .names = "wipeplayer", .description = "zdtd: erase a player record by login name" },
};

pub const logPersistErr = persist.logPersistErr;
pub const Zpv2Drop = persist.Zpv2Drop;
pub const zpvRecordLen = persist.zpvRecordLen;
pub const zpv2DropName = persist.zpv2DropName;
