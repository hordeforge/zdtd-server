// core_questgate — a quest-acceptance policy plugin (AGENTS.md rule 29,
// Wasm-first). Reference module for quest gating (whitelists, class/level
// restrictions): uses the on_quest_accept verdict + the `quest` query verb to
// deny quests named `forbidden_*` and log every acceptance.
//
// Build (zig): see mods/BUILDING.md. Committed as core_questgate.wasm.

const std = @import("std");
const common = @import("plugin_common");

var out: common.Buf = .{};
var cfg: common.Config = .{};
var name_buf: [64]u8 = undefined;
var deny_prefix: [32]u8 = undefined;
var deny_len: usize = 0;

fn startsDenied(s: []const u8) bool {
    return deny_len > 0 and std.mem.startsWith(u8, s, deny_prefix[0..deny_len]);
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
    cfg.load();
    const dflt = "forbidden_";
    deny_len = dflt.len;
    @memcpy(deny_prefix[0..deny_len], dflt);
    if (cfg.get("deny_prefix")) |p| {
        const t = std.mem.trim(u8, p, " \"'");
        if (t.len > 0 and t.len <= deny_prefix.len) {
            deny_len = t.len;
            @memcpy(deny_prefix[0..deny_len], t);
        }
    }
    out.reset();
    out.put("core_questgate v1.0 enabled (deny prefix: ");
    out.put(deny_prefix[0..deny_len]);
    out.put(")");
    out.logLine(1);
}

export fn on_shutdown() void {
    out.reset();
    out.put("core_questgate shutdown");
    out.logLine(1);
}

export fn on_quest_accept(player: i32, def_id: i32) i32 {
    const nn = queryQuestName(def_id);
    const forb = startsDenied(name_buf[0..nn]);
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

comptime {
    common.exportRequires("on_quest_accept,query,config,log");
}
