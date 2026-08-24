// zdtd_questgate — a quest-acceptance policy plugin (AGENTS.md rule 29,
// Wasm-first). Reference module for quest gating (whitelists, class/level
// restrictions): uses the on_quest_accept verdict + the `quest` query verb to
// deny quests named `forbidden_*` and log every acceptance.
//
// Build (zig): see mods/BUILDING.md. Committed as zdtd_questgate.wasm.

const std = @import("std");
const common = @import("plugin_common");

var out: common.Buf = .{};
var name_buf: [64]u8 = undefined;

fn startsForbidden(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "forbidden_");
}

// "quest <def_id>" -> bytes written of the quest name, or 0 when unknown.
fn queryQuestName(def_id: i32) usize {
    var req: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&req, "quest {d}", .{def_id}) catch return 0;
    return @intCast(@max(0, common.query(
        @intCast(@intFromPtr(&req)),
        @intCast(s.len),
        @intCast(@intFromPtr(&name_buf)),
        name_buf.len,
    )));
}

export fn on_enable() void {
    out.reset();
    out.put("zdtd_questgate v1.0 enabled (deny quests named forbidden_*)");
    out.logLine(1);
}

export fn on_shutdown() void {
    out.reset();
    out.put("zdtd_questgate shutdown");
    out.logLine(1);
}

export fn on_quest_accept(player: i32, def_id: i32) i32 {
    const nn = queryQuestName(def_id);
    const forb = startsForbidden(name_buf[0..nn]);
    out.reset();
    out.put("quest accept: player=");
    out.putInt(player);
    out.put(" def=");
    out.putInt(def_id);
    out.put(" name=");
    out.put(name_buf[0..nn]);
    if (forb) {
        out.put(" DENIED");
        out.logLine(1);
        return -1; // deny the accept
    }
    out.logLine(1);
    return 0; // keep everything else
}
