//! parachute guest (ADR 0037): watches the sense v4 snapshot for players who
//! are wearing the glider item and falling fast, and arms the glide
//! exemption (`glide <net_id> 1`) so the movement envelope does not reject
//! the sustained fall. Deceleration itself is client-side (paired client
//! mod); this module is the server-side authority/coordination half.
//!
//! Hooks: on_enable (read config), on_tick (deploy state machine), on_join
//! (nothing to do - the state machine is per-player over the sense view).
//! Requires: log, tick, sense, queue, config.

const std = @import("std");
const common = @import("plugin_common");

const sense_header_len = 24;
const sense_record_len = 40; // v4 (ADR 0037)
const sense_cap = 2048;

// Sense record offsets (v4 layout, all little-endian).
const off_net_id: usize = 0;
const off_kind: usize = 4;
const off_vy: usize = 28;
const off_wearing: usize = 36;
const kind_player: u8 = 0;

// Per-player deploy state (fixed roster, no heap).
const max_players = 16;
var roster_net: [max_players]i32 = [_]i32{-1} ** max_players;
var roster_armed: [max_players]u8 = [_]u8{0} ** max_players;
var roster_fall_ticks: [max_players]u8 = [_]u8{0} ** max_players;
var roster_gliding: [max_players]u8 = [_]u8{0} ** max_players;

// Config (read once at on_enable via zdtd.config).
var cfg_deploy_vy: f32 = -6.0;
var cfg_delay_ticks: u8 = 10;
var cfg_require_worn: bool = true;
var cfg_item_tag: []const u8 = "parachute";
var cfg_announce: bool = true;
var cfg_announce_text: []const u8 = "deployed their parachute";

var sense_buf: [sense_cap]u8 = undefined;
var out_buf: [common.out_cap]u8 = undefined;

fn rosterFind(net: i32) ?usize {
    for (roster_net, 0..) |n, i| {
        if (n == net) return i;
    }
    return null;
}

fn rosterAlloc(net: i32) ?usize {
    for (roster_net, 0..) |n, i| {
        if (n < 0) {
            roster_net[i] = net;
            roster_armed[i] = 0;
            roster_fall_ticks[i] = 0;
            roster_gliding[i] = 0;
            return i;
        }
    }
    return null;
}

fn queueCmd(s: []const u8) void {
    const n = @min(s.len, common.out_cap);
    @memcpy(out_buf[0..n], s[0..n]);
    _ = common.queue(@intCast(@intFromPtr(&out_buf)), @intCast(n));
}

fn say(player_name: []const u8) void {
    if (!cfg_announce) return;
    var b: [common.out_cap]u8 = undefined;
    var n: usize = 0;
    if (player_name.len > 0) {
        const take = @min(player_name.len, 24);
        @memcpy(b[0..take], player_name[0..take]);
        n += take;
        b[n] = ' ';
        n += 1;
    }
    const txt = cfg_announce_text;
    const take = @min(txt.len, common.out_cap - 1 - n);
    @memcpy(b[n..][0..take], txt[0..take]);
    n += take;
    queueCmd(b[0..n]);
}

/// Minimal `key = value` config parse (comments + quoted values, the
/// plugin_common.Config subset reimplemented here to avoid heap).
fn parseConfig(data: []const u8) void {
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (val.len == 0) continue;
        if (std.mem.eql(u8, key, "deploy_vy_threshold")) {
            cfg_deploy_vy = std.fmt.parseFloat(f32, val) catch continue;
        } else if (std.mem.eql(u8, key, "deploy_delay_ticks")) {
            cfg_delay_ticks = std.fmt.parseInt(u8, val, 10) catch continue;
        } else if (std.mem.eql(u8, key, "require_worn")) {
            cfg_require_worn = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
        } else if (std.mem.eql(u8, key, "item_tag")) {
            cfg_item_tag = val;
        } else if (std.mem.eql(u8, key, "announce_on_deploy")) {
            cfg_announce = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
        } else if (std.mem.eql(u8, key, "announce_text")) {
            cfg_announce_text = val;
        }
    }
}

export fn on_enable() void {
    var cfg_buf: [1024]u8 = undefined;
    const n = common.config(@intCast(@intFromPtr(&cfg_buf)), @intCast(cfg_buf.len));
    if (n > 0) parseConfig(cfg_buf[0..@min(@as(usize, @intCast(n)), cfg_buf.len)]);
    var b: common.Buf = .{};
    b.put("parachute: config deploy_vy=");
    b.putInt(@as(i32, @intFromFloat(cfg_deploy_vy)));
    b.put(" delay_ticks=");
    b.putInt(cfg_delay_ticks);
    b.logLine(0);
}

export fn on_tick() void {
    const n = common.sense(@intCast(@intFromPtr(&sense_buf)), @intCast(sense_cap), 0);
    if (n < sense_header_len) return;
    if (!(sense_buf[0] == 'Z' and sense_buf[1] == 'B' and sense_buf[2] == 'S' and sense_buf[3] == '4')) return;
    const count = std.mem.readInt(u32, sense_buf[4..8], .little);
    const avail = (@as(usize, @intCast(n)) - sense_header_len) / sense_record_len;
    const recs = @min(@as(usize, count), avail);

    // Mark players seen this pass; purge stale roster entries.
    var seen: [max_players]u8 = [_]u8{0} ** max_players;
    var i: usize = 0;
    while (i < recs) : (i += 1) {
        const base = sense_header_len + i * sense_record_len;
        if (sense_buf[base + off_kind] != kind_player) continue;
        const net = @as(i32, @bitCast(@as(u32, sense_buf[base]) | (@as(u32, sense_buf[base + 1]) << 8) | (@as(u32, sense_buf[base + 2]) << 16) | (@as(u32, sense_buf[base + 3]) << 24)));
        if (rosterFind(net)) |ri| seen[ri] = 1;
    }
    for (roster_net, 0..) |rn, ri| {
        if (rn >= 0 and seen[ri] == 0) {
            // Left the sense view: clear any armed glide.
            if (roster_gliding[ri] != 0) {
                var b: [40]u8 = undefined;
                const s = std.fmt.bufPrint(&b, "glide {d} 0", .{rn}) catch continue;
                queueCmd(s);
            }
            roster_net[ri] = -1;
        }
    }

    i = 0;
    while (i < recs) : (i += 1) {
        const base = sense_header_len + i * sense_record_len;
        if (sense_buf[base + off_kind] != kind_player) continue;
        const net = @as(i32, @bitCast(@as(u32, sense_buf[base]) | (@as(u32, sense_buf[base + 1]) << 8) | (@as(u32, sense_buf[base + 2]) << 16) | (@as(u32, sense_buf[base + 3]) << 24)));
        const vy: f32 = @bitCast(@as(u32, sense_buf[base + off_vy]) | (@as(u32, sense_buf[base + off_vy + 1]) << 8) | (@as(u32, sense_buf[base + off_vy + 2]) << 16) | (@as(u32, sense_buf[base + off_vy + 3]) << 24));
        const wearing: u8 = sense_buf[base + off_wearing];
        const ri = rosterFind(net) orelse rosterAlloc(net) orelse continue;
        if (cfg_require_worn and wearing == 0) {
            roster_armed[ri] = 0;
            roster_fall_ticks[ri] = 0;
            if (roster_gliding[ri] != 0) {
                var b: [40]u8 = undefined;
                const s = std.fmt.bufPrint(&b, "glide {d} 0", .{net}) catch continue;
                queueCmd(s);
                roster_gliding[ri] = 0;
            }
            continue;
        }
        if (roster_armed[ri] == 0) {
            if (vy < cfg_deploy_vy) {
                roster_fall_ticks[ri] +%= 1;
                if (roster_fall_ticks[ri] >= cfg_delay_ticks) {
                    roster_armed[ri] = 1;
                    roster_fall_ticks[ri] = 0;
                }
            } else {
                roster_fall_ticks[ri] = 0;
            }
        } else {
            // Deployed: keep the glide exemption armed while falling; clear on
            // landing (vy back near zero/positive).
            if (roster_gliding[ri] == 0) {
                var b: [40]u8 = undefined;
                const s = std.fmt.bufPrint(&b, "glide {d} 1", .{net}) catch continue;
                queueCmd(s);
                roster_gliding[ri] = 1;
                say(""); // host chat names the player in the broadcast
            }
            if (vy > -1.0) {
                roster_armed[ri] = 0;
                roster_gliding[ri] = 0;
                var b: [40]u8 = undefined;
                const s = std.fmt.bufPrint(&b, "glide {d} 0", .{net}) catch continue;
                queueCmd(s);
            }
        }
    }
}

export fn on_shutdown() void {
    // Clear every armed glide (fail closed on reload/disable).
    for (roster_net, 0..) |rn, ri| {
        if (rn >= 0 and roster_gliding[ri] != 0) {
            var b: [40]u8 = undefined;
            const s = std.fmt.bufPrint(&b, "glide {d} 0", .{rn}) catch continue;
            queueCmd(s);
        }
    }
}
