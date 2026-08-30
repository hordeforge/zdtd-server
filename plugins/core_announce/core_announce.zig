// core_announce - day + blood-moon + join/leave announcements over chat.
// Reads the sim clock via zdtd.sense and broadcasts `say` commands on the
// on_tick / on_player_join / on_player_leave observers.
//
// All announce strings come from this mod's own config.toml (zdtd.config
// import); the `say ` command verb is the protocol, not policy.

const std = @import("std");
const common = @import("plugin_common");

const sense_cap = 64;
var sense_buf: [sense_cap]u8 = undefined;
var out: common.Buf = .{};
var cfg: common.Config = .{};
var last_day: i32 = -1;
var last_blood_moon: i32 = -1;

var day_prefix: [48]u8 = undefined;
var day_prefix_len: usize = 0;
var bm_rise: [96]u8 = undefined;
var bm_rise_len: usize = 0;
var bm_fade: [96]u8 = undefined;
var bm_fade_len: usize = 0;
var join_msg: [96]u8 = undefined;
var join_msg_len: usize = 0;
var leave_msg: [96]u8 = undefined;
var leave_msg_len: usize = 0;

fn setStr(buf: []u8, len: *usize, dflt: []const u8, key: []const u8) void {
    var src = dflt;
    if (cfg.get(key)) |v| {
        const t = std.mem.trim(u8, v, " \"'");
        if (t.len > 0 and t.len <= buf.len) src = t;
    }
    len.* = src.len;
    @memcpy(buf[0..src.len], src);
}

fn say(s: []const u8) void {
    out.reset();
    out.put("say ");
    out.put(s);
    _ = out.send();
}

const ClockState = struct { day: i32, blood_moon: i32 };

fn clockState() ?ClockState {
    const n = common.sense(@intCast(@intFromPtr(&sense_buf)), sense_cap, 0);
    if (n < 24) return null;
    if (!std.mem.eql(u8, sense_buf[0..4], "ZBS4")) return null;
    const world_time = std.mem.readInt(u32, sense_buf[16..20], .little);
    const bm = std.mem.readInt(u32, sense_buf[20..24], .little);
    // world_time is in ticks per stock convention; a day is 24000 ticks.
    return .{ .day = @intCast(world_time / 24000), .blood_moon = if (bm != 0) 1 else 0 };
}

export fn on_enable() void {
    cfg.load();
    setStr(&day_prefix, &day_prefix_len, "Day", "day_prefix");
    setStr(&bm_rise, &bm_rise_len, "The blood moon rises!", "blood_moon_rise");
    setStr(&bm_fade, &bm_fade_len, "The blood moon fades.", "blood_moon_fade");
    setStr(&join_msg, &join_msg_len, "A new survivor has joined the wasteland.", "join_message");
    setStr(&leave_msg, &leave_msg_len, "A survivor has left the wasteland.", "leave_message");
    out.reset();
    out.put("core_announce v2.0 enabled (config-driven announce strings)");
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
        out.put("say ");
        out.put(day_prefix[0..day_prefix_len]);
        out.put(" ");
        out.putInt(st.day);
        _ = out.send();
    }
    if (last_blood_moon >= 0 and st.blood_moon != last_blood_moon) {
        say(if (st.blood_moon != 0) bm_rise[0..bm_rise_len] else bm_fade[0..bm_fade_len]);
    }
    last_day = st.day;
    last_blood_moon = st.blood_moon;
}

export fn on_player_join(slot: i32, entity_id: i32) void {
    _ = slot;
    _ = entity_id;
    say(join_msg[0..join_msg_len]);
}

export fn on_player_leave(slot: i32, entity_id: i32) void {
    _ = slot;
    _ = entity_id;
    say(leave_msg[0..leave_msg_len]);
}

comptime {
    common.exportRequires("on_tick,on_player_join,on_player_leave,sense,config,queue,log");
}
