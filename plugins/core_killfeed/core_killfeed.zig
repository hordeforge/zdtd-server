// core_killfeed — a minimal event-observer plugin (AGENTS.md rule 29,
// "Wasm-first": anything that is discretionary behavior ships as a Wasm
// plugin). Reference module for announcements, kill-feeds, scoreboards and
// external integrations: it observes the event/verdict hooks, logs each event
// to the server log and always keeps the stock outcome (returns 0).
//
// Hooks used (see docs/PLUGIN_DEV.md "Hooks"):
//   on_player_join(slot: i32, entity_id: i32)
//   on_player_leave(slot: i32, entity_id: i32)
//   on_player_death(victim: i32) -> i32
//   on_entity_killed(killed: i32, killer: i32) -> i32
//   on_quest_complete(player: i32, quest_def: i32) -> i32
// Verdict convention: <0 deny, 0 keep, >0 adjust (per hook). A pure observer
// returns 0 everywhere. No imports beyond zdtd.log: this module neither reads
// the sim nor queues commands, so it is a zero-risk addition to any server.
//
// Build (zig): scripts/build-plugins.sh. Committed as plugins/core_killfeed/core_killfeed.wasm.

const std = @import("std");
const common = @import("plugin_common");

var out: common.Buf = .{};
var cfg: common.Config = .{};
var log_level: i32 = 1;

export fn on_enable() void {
    cfg.load();
    if (cfg.get("log_level")) |v| {
        const t = std.mem.trim(u8, v, " \"'");
        if (std.mem.eql(u8, t, "off")) {
            log_level = -1;
        } else if (std.mem.eql(u8, t, "info")) {
            log_level = 0;
        } else if (std.mem.eql(u8, t, "debug")) {
            log_level = 1;
        }
    }
    out.reset();
    out.put("core_killfeed v1.0 enabled (log_level=");
    out.putInt(log_level);
    out.put(")");
    out.logLine(0);
}

export fn on_shutdown() void {
    out.reset();
    out.put("core_killfeed shutdown");
    if (log_level >= 0) out.logLine(log_level);
}

export fn on_player_join(slot: i32, entity_id: i32) void {
    out.reset();
    out.put("join: slot=");
    out.putInt(slot);
    out.put(" entity=");
    out.putInt(entity_id);
    if (log_level >= 0) out.logLine(log_level);
}

export fn on_player_leave(slot: i32, entity_id: i32) void {
    out.reset();
    out.put("leave: slot=");
    out.putInt(slot);
    out.put(" entity=");
    out.putInt(entity_id);
    if (log_level >= 0) out.logLine(log_level);
}

export fn on_entity_killed(killed: i32, killer: i32) i32 {
    out.reset();
    out.put("kill: killer=");
    out.putInt(killer);
    out.put(" killed=");
    out.putInt(killed);
    if (log_level >= 0) out.logLine(log_level);
    return 0; // keep the stock outcome
}

export fn on_player_death(victim: i32) i32 {
    out.reset();
    out.put("death: victim=");
    out.putInt(victim);
    if (log_level >= 0) out.logLine(log_level);
    return 0;
}

export fn on_quest_complete(player: i32, quest_def: i32) i32 {
    out.reset();
    out.put("quest complete: player=");
    out.putInt(player);
    out.put(" def=");
    out.putInt(quest_def);
    if (log_level >= 0) out.logLine(log_level);
    return 0;
}
