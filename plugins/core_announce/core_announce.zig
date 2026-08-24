// core_announce — server chat announcements via the `zdtd.queue say` verb
// (AGENTS.md rule 29, Wasm-first). v2 adds clock announcements from the
// zdtd.sense header (v3: world_time + blood_moon): day rolls and blood-moon
// start/end, alongside the join/leave broadcasts.
//
// Hooks used (docs/PLUGIN_DEV.md "Hooks"):
//   on_enable / on_shutdown / on_tick
//   on_player_join(slot: i32, entity_id: i32)
//   on_player_leave(slot: i32, entity_id: i32)
// Verdict convention: this module is a pure announcer, so it returns 0
// everywhere (keep the stock outcome).
//
// Imports: zdtd.log, zdtd.queue with the `say` verb, zdtd.sense (header only:
// magic 'ZBS3' @0, world_time u32 @16, blood_moon u32 @20 — see
// docs/rfc/0001-fps-bot-spec.md).
//
// Build (zig, committed as plugins/core_announce/core_announce.wasm):
//   scripts/build-plugins.sh
// Enable via zdtd.toml: [plugin] modules = "plugins/core_announce/core_announce.wasm"

const std = @import("std");
const common = @import("plugin_common");

const sense_cap = 64;
var sense_buf: [sense_cap]u8 = undefined;
var out: common.Buf = .{};

// Last-seen clock state (the instance persists across on_tick calls).
var last_day: i32 = -1;
var last_blood_moon: i32 = -1;

fn say(s: []const u8) void {
    out.reset();
    out.put("say ");
    out.put(s);
    _ = out.send();
}

// Read the v3 sense header; returns null if the snapshot is
// unavailable/mismatched (nothing to announce that tick).
const ClockState = struct { day: i32, blood_moon: i32 };
fn clockState() ?ClockState {
    const n = common.sense(@intCast(@intFromPtr(&sense_buf)), sense_cap, 0);
    if (n < 24) return null;
    if (!std.mem.eql(u8, sense_buf[0..4], "ZBS3")) return null;
    const world_time = std.mem.readInt(u32, sense_buf[16..20], .little);
    const bm = std.mem.readInt(u32, sense_buf[20..24], .little);
    // world_time is in ticks per stock convention; a day is 24000 ticks.
    return .{ .day = @intCast(world_time / 24000), .blood_moon = if (bm != 0) 1 else 0 };
}

export fn on_enable() void {
    out.reset();
    out.put("core_announce v2.0 enabled (day + blood-moon announcements)");
    out.logLine(0);
}

export fn on_shutdown() void {
    out.reset();
    out.put("core_announce shutdown");
    out.logLine(0);
}

export fn on_tick() void {
    const st = clockState() orelse return;
    if (last_day >= 0 and st.day != last_day) {
        // Day roll: announce every day (a mode can gate this).
        out.reset();
        out.put("say Day ");
        out.putInt(st.day);
        _ = out.send();
    }
    if (last_blood_moon >= 0 and st.blood_moon != last_blood_moon) {
        say(if (st.blood_moon != 0) "The blood moon rises!" else "The blood moon fades.");
    }
    last_day = st.day;
    last_blood_moon = st.blood_moon;
}

export fn on_player_join(slot: i32, entity_id: i32) void {
    _ = slot;
    _ = entity_id;
    say("A new survivor has joined the wasteland.");
}

export fn on_player_leave(slot: i32, entity_id: i32) void {
    _ = slot;
    _ = entity_id;
    say("A survivor has left the wasteland.");
}
