//! Minimal TCP admin console (telnet-like): one command line per connection.
//! Listen/accept via `util/tcp_listen` (std.Io.net); no std.os.linux.

const std = @import("std");
const tcp = @import("../util/tcp_listen.zig");

pub const max_cmd: usize = 256;

pub const max_sessions: usize = 4;

pub const Server = struct {
    listener: tcp.Listener = .{},
    port: u16 = 0,
    /// Persistent telnet-style sessions (-1 = free slot).
    sessions: [max_sessions]tcp.Handle = .{-1} ** max_sessions,
    recv_bufs: [max_sessions][max_cmd]u8 = undefined,
    recv_lens: [max_sessions]usize = .{0} ** max_sessions,
    /// Session whose line is currently being handled (reply target).
    active: usize = 0,

    pub fn listen(self: *Server, port: u16) !void {
        if (port == 0) return;
        // Loopback only: admin has no auth (give/kick/shutdown).
        try self.listener.listen(0x7f000001, port, 4);
        self.port = self.listener.port;
    }

    pub fn deinit(self: *Server) void {
        for (&self.sessions) |*s| {
            if (s.* >= 0) tcp.closeFd(s.*);
            s.* = -1;
        }
        self.recv_lens = .{0} ** max_sessions;
        self.listener.deinit();
        self.port = 0;
    }

    fn acceptNew(self: *Server) void {
        const cfd = self.listener.accept() catch return orelse return;
        for (&self.sessions, 0..) |*s, i| {
            if (s.* < 0) {
                s.* = cfd;
                self.recv_lens[i] = 0;
                self.active = i;
                self.reply("zdtd admin. 'help' for commands.\n");
                return;
            }
        }
        // all slots busy: evict oldest (slot 0)
        tcp.closeFd(self.sessions[0]);
        self.sessions[0] = cfd;
        self.recv_lens[0] = 0;
        self.active = 0;
        self.reply("zdtd admin. 'help' for commands.\n");
    }

    /// Non-blocking: accept new sessions, then read one line from any session.
    /// Sessions stay open across commands (telnet-style); replies go to the
    /// session that sent the line.
    pub fn pollLine(self: *Server, buf: []u8) ?[]const u8 {
        if (!self.listener.enabled()) return null;
        self.acceptNew();
        for (&self.sessions, 0..) |*s, i| {
            if (s.* < 0) continue;
            const pending = self.recv_lens[i];
            if (pending == max_cmd) {
                tcp.closeFd(s.*);
                s.* = -1;
                self.recv_lens[i] = 0;
                continue;
            }
            var total = pending;
            if (std.mem.indexOfScalar(u8, self.recv_bufs[i][0..pending], '\n') == null) {
                const dst = self.recv_bufs[i][pending..];
                const n = tcp.read(s.*, dst) catch |err| switch (err) {
                    error.WouldBlock => continue,
                    else => {
                        tcp.closeFd(s.*);
                        s.* = -1;
                        self.recv_lens[i] = 0;
                        continue;
                    },
                };
                if (n == 0) {
                    tcp.closeFd(s.*);
                    s.* = -1;
                    self.recv_lens[i] = 0;
                    continue;
                }
                total += n;
            }
            const newline = std.mem.indexOfScalar(u8, self.recv_bufs[i][0..total], '\n') orelse {
                self.recv_lens[i] = total;
                continue;
            };
            var end = newline;
            if (end > 0 and self.recv_bufs[i][end - 1] == '\r') end -= 1;
            if (end > buf.len) {
                tcp.closeFd(s.*);
                s.* = -1;
                self.recv_lens[i] = 0;
                continue;
            }
            @memcpy(buf[0..end], self.recv_bufs[i][0..end]);
            const consumed = newline + 1;
            const remaining = total - consumed;
            std.mem.copyForwards(u8, self.recv_bufs[i][0..remaining], self.recv_bufs[i][consumed..total]);
            self.recv_lens[i] = remaining;
            if (end == 0) continue;
            self.active = i;
            return buf[0..end];
        }
        return null;
    }

    /// Close the session whose line is being handled (admin `quit`/`exit`).
    pub fn closeActive(self: *Server) void {
        const fd = self.sessions[self.active];
        if (fd < 0) return;
        tcp.closeFd(fd);
        self.sessions[self.active] = -1;
        self.recv_lens[self.active] = 0;
    }

    /// Best-effort response to the session whose line is being handled.
    pub fn reply(self: *Server, text: []const u8) void {
        const fd = self.sessions[self.active];
        if (fd < 0) return;
        tcp.writeAll(fd, text);
    }
};

pub const Command = union(enum) {
    help,
    status,
    /// Dump C2S authority reject counters (phase/ownership/bounds/movement/decode).
    guardstats,
    /// Clear guard quarantine bits + any armed policy kick on a peer slot
    /// (operator escape hatch for a false positive).
    guardclear: usize,
    evidence,
    /// Dump zdtd-native APM counters + section latency (same text as --ticks exit).
    apm,
    save,
    kick: usize,
    /// Ban by connected peer slot (records IP when available in Game).
    ban: usize,
    unban: u32,
    list,
    give: struct { peer: usize, item: u16, count: u16 },
    tele: struct { peer: usize, x: f32, y: f32, z: f32 },
    say: []const u8,
    /// Force-kill entity by net id (EntityRemove + loot path).
    kill: i32,
    /// Dump a joined peer's inventory slots (debug/parity probe).
    inv: usize,
    /// Stock `gettime` (day + HH:MM).
    gettime,
    /// Stock `settime <day|night|dayN HH MM|ticks>` (subset: day/night/dayN).
    settime: struct { day: u32, hour: u8, minute: u8 },
    /// Stock `spawnentity <peerSlot> <entityClassName>` (near player).
    spawnentity: struct { peer: usize, name_off: usize, name_len: usize },
    /// Stock `gamestage [slot]` (ConsoleCmdGameStage): stage inputs per player.
    gamestage: ?usize,
    /// Stock `listents` (alive entity table).
    listents,
    /// Stock `listplayers` / `lp` (joined peers with entity ids).
    listplayers,
    /// Stock `killall` (non-player AI).
    killall,
    /// Stock `saveworld`.
    saveworld,
    /// Stock `shutdown` (graceful stop).
    shutdown,
    /// Stock `version`.
    version,
    /// Erase a player record from players.zsv by login name (operator right-to-erasure).
    /// Name is a slice into the original command line (must outlive the Command).
    wipeplayer: []const u8,
    /// Known verb, missing or malformed arguments (slice of the input line).
    bad_args: []const u8,
    unknown,
};

/// One-line usage for a known verb (admin `bad_args` replies). Null if unknown.
pub fn usageFor(verb: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, verb, "kick")) return "kick <slot>";
    if (std.mem.eql(u8, verb, "ban")) return "ban <slot>";
    if (std.mem.eql(u8, verb, "unban")) return "unban <iphex>";
    if (std.mem.eql(u8, verb, "give")) return "give <slot> <itemId> [count]";
    if (std.mem.eql(u8, verb, "tele") or std.mem.eql(u8, verb, "tp"))
        return "tele|tp <slot> <x> <y> <z>";
    if (std.mem.eql(u8, verb, "say")) return "say <msg>";
    if (std.mem.eql(u8, verb, "kill")) return "kill <entityId>";
    if (std.mem.eql(u8, verb, "inv")) return "inv <slot>";
    if (std.mem.eql(u8, verb, "settime") or std.mem.eql(u8, verb, "st"))
        return "settime <day|night|ticks|D H M>";
    if (std.mem.eql(u8, verb, "spawnentity") or std.mem.eql(u8, verb, "se"))
        return "spawnentity <slot|entityId> <class>";
    if (std.mem.eql(u8, verb, "wipeplayer")) return "wipeplayer <name>";
    if (std.mem.eql(u8, verb, "gamestage")) return "gamestage [slot]";
    if (std.mem.eql(u8, verb, "guardclear") or std.mem.eql(u8, verb, "gc"))
        return "guardclear <slot>";
    return null;
}

pub fn parseCommand(line: []const u8) Command {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const cmd = it.next() orelse return .unknown;
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "?") or std.mem.eql(u8, cmd, "commands"))
        return if (it.next() == null) .help else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "status")) return if (it.next() == null) .status else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "guardstats") or std.mem.eql(u8, cmd, "gs")) return if (it.next() == null) .guardstats else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "guardclear") or std.mem.eql(u8, cmd, "gc")) {
        const p = it.next() orelse return .{ .bad_args = cmd };
        const peer = std.fmt.parseInt(usize, p, 10) catch return .{ .bad_args = cmd };
        if (it.next() != null) return .{ .bad_args = cmd };
        return .{ .guardclear = peer };
    }
    if (std.mem.eql(u8, cmd, "evidence") or std.mem.eql(u8, cmd, "ev")) return if (it.next() == null) .evidence else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "apm") or std.mem.eql(u8, cmd, "metrics")) return if (it.next() == null) .apm else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "save")) return if (it.next() == null) .save else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "kick")) {
        const p = it.next() orelse return .{ .bad_args = cmd };
        const peer = std.fmt.parseInt(usize, p, 10) catch return .{ .bad_args = cmd };
        if (it.next() != null) return .{ .bad_args = cmd };
        return .{ .kick = peer };
    }
    if (std.mem.eql(u8, cmd, "ban")) {
        const p = it.next() orelse return .{ .bad_args = cmd };
        const peer = std.fmt.parseInt(usize, p, 10) catch return .{ .bad_args = cmd };
        if (it.next() != null) return .{ .bad_args = cmd };
        return .{ .ban = peer };
    }
    if (std.mem.eql(u8, cmd, "unban")) {
        const p = it.next() orelse return .{ .bad_args = cmd };
        const ip = std.fmt.parseInt(u32, p, 16) catch return .{ .bad_args = cmd };
        if (it.next() != null) return .{ .bad_args = cmd };
        return .{ .unban = ip };
    }
    if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "players")) return if (it.next() == null) .list else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "gamestage")) {
        const p = it.next() orelse return .{ .gamestage = null };
        if (it.next() != null) return .{ .bad_args = cmd };
        return .{ .gamestage = std.fmt.parseInt(usize, p, 10) catch return .{ .bad_args = cmd } };
    }
    if (std.mem.eql(u8, cmd, "give")) {
        const p = it.next() orelse return .{ .bad_args = cmd };
        const i = it.next() orelse return .{ .bad_args = cmd };
        const c = it.next() orelse "1";
        if (it.next() != null) return .{ .bad_args = cmd };
        return .{ .give = .{
            .peer = std.fmt.parseInt(usize, p, 10) catch return .{ .bad_args = cmd },
            .item = std.fmt.parseInt(u16, i, 10) catch return .{ .bad_args = cmd },
            .count = std.fmt.parseInt(u16, c, 10) catch return .{ .bad_args = cmd },
        } };
    }
    // `tp` matches in-game console / WEBUI docs; same args as `tele`.
    if (std.mem.eql(u8, cmd, "tele") or std.mem.eql(u8, cmd, "tp")) {
        const p = it.next() orelse return .{ .bad_args = cmd };
        const xs = it.next() orelse return .{ .bad_args = cmd };
        const ys = it.next() orelse return .{ .bad_args = cmd };
        const zs = it.next() orelse return .{ .bad_args = cmd };
        if (it.next() != null) return .{ .bad_args = cmd };
        const x = std.fmt.parseFloat(f32, xs) catch return .{ .bad_args = cmd };
        const y = std.fmt.parseFloat(f32, ys) catch return .{ .bad_args = cmd };
        const z = std.fmt.parseFloat(f32, zs) catch return .{ .bad_args = cmd };
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(z)) return .{ .bad_args = cmd };
        return .{ .tele = .{
            .peer = std.fmt.parseInt(usize, p, 10) catch return .{ .bad_args = cmd },
            .x = x,
            .y = y,
            .z = z,
        } };
    }
    if (std.mem.eql(u8, cmd, "say")) {
        // it.rest() so leading whitespace before the verb cannot shift the slice.
        const rest = std.mem.trim(u8, it.rest(), " ");
        if (rest.len == 0) return .{ .bad_args = cmd };
        return .{ .say = rest };
    }
    if (std.mem.eql(u8, cmd, "kill")) {
        const p = it.next() orelse return .{ .bad_args = cmd };
        const id = std.fmt.parseInt(i32, p, 10) catch return .{ .bad_args = cmd };
        if (it.next() != null) return .{ .bad_args = cmd };
        return .{ .kill = id };
    }
    if (std.mem.eql(u8, cmd, "inv")) {
        const p = it.next() orelse return .{ .bad_args = cmd };
        const peer = std.fmt.parseInt(usize, p, 10) catch return .{ .bad_args = cmd };
        if (it.next() != null) return .{ .bad_args = cmd };
        return .{ .inv = peer };
    }
    if (std.mem.eql(u8, cmd, "gettime") or std.mem.eql(u8, cmd, "gt")) return if (it.next() == null) .gettime else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "settime") or std.mem.eql(u8, cmd, "st")) {
        const a = it.next() orelse return .{ .bad_args = cmd };
        if (std.mem.eql(u8, a, "day")) return if (it.next() == null) .{ .settime = .{ .day = 0, .hour = 8, .minute = 0 } } else .{ .bad_args = cmd };
        if (std.mem.eql(u8, a, "night")) return if (it.next() == null) .{ .settime = .{ .day = 0, .hour = 22, .minute = 0 } } else .{ .bad_args = cmd };
        // Stock telnet often sends a single world-time integer (e.g. 8000, 22000).
        // Packing used by playtest orch: thousands digit ~ hour*1000-ish; map common values.
        const n = std.fmt.parseInt(u32, a, 10) catch return .{ .bad_args = cmd };
        if (it.peek() == null) {
            // Single token: either stock ticks-ish or a lone day number.
            if (n >= 100) {
                // Stock world time: 1000 ticks per hour (8000 -> 08:00, 22500 -> 22:30).
                const hour: u8 = @intCast(@min(23, n / 1000));
                const minute: u8 = @intCast((n % 1000) * 60 / 1000);
                return .{ .settime = .{ .day = 0, .hour = hour, .minute = minute } };
            }
            return .{ .settime = .{ .day = n, .hour = 8, .minute = 0 } };
        }
        // "settime <day> <hour> <minute>"
        const h = std.fmt.parseInt(u8, it.next() orelse "8", 10) catch return .{ .bad_args = cmd };
        const mi = std.fmt.parseInt(u8, it.next() orelse "0", 10) catch return .{ .bad_args = cmd };
        if (h > 23 or mi > 59) return .{ .bad_args = cmd };
        if (it.next() != null) return .{ .bad_args = cmd };
        return .{ .settime = .{ .day = n, .hour = h, .minute = mi } };
    }
    if (std.mem.eql(u8, cmd, "spawnentity") or std.mem.eql(u8, cmd, "se")) {
        const p = it.next() orelse return .{ .bad_args = cmd };
        // peer slot (0..7) or stock player entity id (>=100). Game resolves both.
        const peer = std.fmt.parseInt(usize, p, 10) catch return .{ .bad_args = cmd };
        const name = it.next() orelse return .{ .bad_args = cmd };
        if (it.next() != null) return .{ .bad_args = cmd };
        // Offsets into the original line (name slice must outlive tokenizer).
        const off = @intFromPtr(name.ptr) - @intFromPtr(line.ptr);
        return .{ .spawnentity = .{ .peer = peer, .name_off = off, .name_len = name.len } };
    }
    if (std.mem.eql(u8, cmd, "listents") or std.mem.eql(u8, cmd, "le")) return if (it.next() == null) .listents else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "listplayers") or std.mem.eql(u8, cmd, "lp")) return if (it.next() == null) .listplayers else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "killall") or std.mem.eql(u8, cmd, "ka")) return if (it.next() == null) .killall else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "saveworld") or std.mem.eql(u8, cmd, "sa")) return if (it.next() == null) .saveworld else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "shutdown")) return if (it.next() == null) .shutdown else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "version")) return if (it.next() == null) .version else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "wipeplayer")) {
        const name = it.next() orelse return .{ .bad_args = cmd };
        if (name.len == 0 or name.len > 32) return .{ .bad_args = cmd };
        if (it.next() != null) return .{ .bad_args = cmd };
        return .{ .wipeplayer = name };
    }
    return .unknown;
}

test "parse give" {
    const c = parseCommand("give 0 2 5");
    try std.testing.expect(c == .give);
    try std.testing.expectEqual(@as(u16, 2), c.give.item);
    try std.testing.expectEqual(@as(u16, 5), c.give.count);
}

test "parse ban kick list" {
    try std.testing.expect(parseCommand("kick 1") == .kick);
    try std.testing.expect(parseCommand("ban 2") == .ban);
    try std.testing.expect(parseCommand("list") == .list);
    try std.testing.expect(parseCommand("unban 7f000001") == .unban);
}

test "parse tp alias for tele" {
    const c = parseCommand("tp 0 10 70 -5");
    try std.testing.expect(c == .tele);
    try std.testing.expectEqual(@as(usize, 0), c.tele.peer);
    try std.testing.expectEqual(@as(f32, 10), c.tele.x);
    try std.testing.expectEqual(@as(f32, 70), c.tele.y);
    try std.testing.expectEqual(@as(f32, -5), c.tele.z);
    try std.testing.expectEqualStrings("tele|tp <slot> <x> <y> <z>", usageFor("tp").?);
}

test "parse kill" {
    const c = parseCommand("kill 100");
    try std.testing.expect(c == .kill);
    try std.testing.expectEqual(@as(i32, 100), c.kill);
}

test "parse inv" {
    const c = parseCommand("inv 0");
    try std.testing.expect(c == .inv);
    try std.testing.expectEqual(@as(usize, 0), c.inv);
}

test "parse guardstats" {
    try std.testing.expect(parseCommand("guardstats") == .guardstats);
    try std.testing.expect(parseCommand("gs") == .guardstats);
}

test "parse evidence" {
    try std.testing.expect(parseCommand("evidence") == .evidence);
    try std.testing.expect(parseCommand("ev") == .evidence);
}

test "parse guardclear" {
    const gc = parseCommand("guardclear 3");
    try std.testing.expect(gc == .guardclear);
    try std.testing.expectEqual(@as(usize, 3), gc.guardclear);
    try std.testing.expect(parseCommand("gc 0") == .guardclear);
    try std.testing.expect(parseCommand("guardclear") == .bad_args);
    try std.testing.expect(parseCommand("guardclear x") == .bad_args);
    try std.testing.expect(parseCommand("guardclear 1 2") == .bad_args);
    try std.testing.expectEqualStrings("guardclear <slot>", usageFor("guardclear").?);
}

test "parse apm" {
    try std.testing.expect(parseCommand("apm") == .apm);
    try std.testing.expect(parseCommand("metrics") == .apm);
}

test "parse stock ops commands" {
    try std.testing.expect(parseCommand("gettime") == .gettime);
    const st = parseCommand("settime night");
    try std.testing.expect(st == .settime);
    try std.testing.expectEqual(@as(u8, 22), st.settime.hour);
    const st2 = parseCommand("settime 7 10 30");
    try std.testing.expectEqual(@as(u32, 7), st2.settime.day);
    const st3 = parseCommand("settime 22000");
    try std.testing.expect(st3 == .settime);
    try std.testing.expectEqual(@as(u8, 22), st3.settime.hour);
    const st4 = parseCommand("settime 8000");
    try std.testing.expectEqual(@as(u8, 8), st4.settime.hour);
    const line = "spawnentity 0 zombieBoe";
    const se = parseCommand(line);
    try std.testing.expect(se == .spawnentity);
    try std.testing.expectEqualStrings("zombieBoe", line[se.spawnentity.name_off..][0..se.spawnentity.name_len]);
    try std.testing.expect(parseCommand("listents") == .listents);
    try std.testing.expect(parseCommand("listplayers") == .listplayers);
    try std.testing.expect(parseCommand("lp") == .listplayers);
    try std.testing.expect(parseCommand("killall") == .killall);
    try std.testing.expect(parseCommand("saveworld") == .saveworld);
    try std.testing.expect(parseCommand("version") == .version);
    try std.testing.expect(parseCommand("shutdown") == .shutdown);
}

test "say keeps message intact despite leading whitespace" {
    const c = parseCommand("  say hello world");
    try std.testing.expect(c == .say);
    try std.testing.expectEqualStrings("hello world", c.say);
    try std.testing.expect(parseCommand("say") == .bad_args);
}

test "settime ticks map to stock minutes" {
    const st = parseCommand("settime 22500");
    try std.testing.expect(st == .settime);
    try std.testing.expectEqual(@as(u8, 22), st.settime.hour);
    try std.testing.expectEqual(@as(u8, 30), st.settime.minute);
}

test "parse rejects malformed numeric arguments" {
    try std.testing.expect(parseCommand("give 0 2 many") == .bad_args);
    try std.testing.expect(parseCommand("tele 0 nan 70 10") == .bad_args);
    try std.testing.expect(parseCommand("tele 0 10 inf 10") == .bad_args);
    try std.testing.expect(parseCommand("settime 7 noon 30") == .bad_args);
    try std.testing.expect(parseCommand("settime 7 24 00") == .bad_args);
    try std.testing.expect(parseCommand("settime 7 23 60") == .bad_args);
}

test "parse rejects trailing arguments for fixed-arity commands" {
    try std.testing.expect(parseCommand("status now") == .bad_args);
    try std.testing.expect(parseCommand("kick 1 extra") == .bad_args);
    try std.testing.expect(parseCommand("give 0 2 5 extra") == .bad_args);
    try std.testing.expect(parseCommand("tp 0 10 70 10 extra") == .bad_args);
    try std.testing.expect(parseCommand("settime 7 10 30 extra") == .bad_args);
    try std.testing.expect(parseCommand("spawnentity 0 zombieBoe extra") == .bad_args);
    try std.testing.expect(parseCommand("wipeplayer Alice extra") == .bad_args);
}

test "bad args carry the verb; unknown verbs stay unknown" {
    const c = parseCommand("kick many");
    try std.testing.expect(c == .bad_args);
    try std.testing.expectEqualStrings("kick", c.bad_args);
    try std.testing.expect(parseCommand("frobnicate 1") == .unknown);
    try std.testing.expect(parseCommand("kick") == .bad_args);
}

test "commands alias is help; usageFor covers common verbs" {
    try std.testing.expect(parseCommand("commands") == .help);
    try std.testing.expectEqualStrings("kick <slot>", usageFor("kick").?);
    try std.testing.expectEqualStrings("give <slot> <itemId> [count]", usageFor("give").?);
    try std.testing.expectEqualStrings("wipeplayer <name>", usageFor("wipeplayer").?);
    try std.testing.expect(usageFor("frobnicate") == null);
}

test "parse wipeplayer" {
    const c = parseCommand("wipeplayer Alice");
    try std.testing.expect(c == .wipeplayer);
    try std.testing.expectEqualStrings("Alice", c.wipeplayer);
    try std.testing.expect(parseCommand("wipeplayer") == .bad_args);
}

test "parse gamestage with and without a slot" {
    const all = parseCommand("gamestage");
    try std.testing.expect(all == .gamestage);
    try std.testing.expect(all.gamestage == null);
    const one = parseCommand("gamestage 2");
    try std.testing.expect(one == .gamestage);
    try std.testing.expectEqual(@as(usize, 2), one.gamestage.?);
    try std.testing.expect(parseCommand("gamestage x") == .bad_args);
    try std.testing.expect(parseCommand("gamestage 1 2") == .bad_args);
    try std.testing.expectEqualStrings("gamestage [slot]", usageFor("gamestage").?);
}
