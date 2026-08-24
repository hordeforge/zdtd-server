// zdtd_killfeed — a minimal event-observer plugin (AGENTS.md rule 29,
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
// Build (zig): see mods/BUILDING.md. Committed as zdtd_killfeed.wasm.

const common = @import("plugin_common");

var out: common.Buf = .{};

export fn on_enable() void {
    out.reset();
    out.put("zdtd_killfeed v1.0 enabled (observer: kill/death/quest hooks)");
    out.logLine(1);
}

export fn on_shutdown() void {
    out.reset();
    out.put("zdtd_killfeed shutdown");
    out.logLine(1);
}

export fn on_player_join(slot: i32, entity_id: i32) void {
    out.reset();
    out.put("join: slot=");
    out.putInt(slot);
    out.put(" entity=");
    out.putInt(entity_id);
    out.logLine(1);
}

export fn on_player_leave(slot: i32, entity_id: i32) void {
    out.reset();
    out.put("leave: slot=");
    out.putInt(slot);
    out.put(" entity=");
    out.putInt(entity_id);
    out.logLine(1);
}

export fn on_entity_killed(killed: i32, killer: i32) i32 {
    out.reset();
    out.put("kill: killer=");
    out.putInt(killer);
    out.put(" killed=");
    out.putInt(killed);
    out.logLine(1);
    return 0; // keep the stock outcome
}

export fn on_player_death(victim: i32) i32 {
    out.reset();
    out.put("death: victim=");
    out.putInt(victim);
    out.logLine(1);
    return 0;
}

export fn on_quest_complete(player: i32, quest_def: i32) i32 {
    out.reset();
    out.put("quest complete: player=");
    out.putInt(player);
    out.put(" def=");
    out.putInt(quest_def);
    out.logLine(1);
    return 0;
}
