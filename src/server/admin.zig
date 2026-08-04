//! Minimal TCP admin console (telnet-like): one command line per connection.

const std = @import("std");
const linux = std.os.linux;

pub const max_cmd: usize = 256;

pub const max_sessions: usize = 4;

pub const Server = struct {
    fd: i32 = -1,
    port: u16 = 0,
    /// Persistent telnet-style sessions (-1 = free slot).
    sessions: [max_sessions]i32 = .{-1} ** max_sessions,
    recv_bufs: [max_sessions][max_cmd]u8 = undefined,
    recv_lens: [max_sessions]usize = .{0} ** max_sessions,
    /// Session whose line is currently being handled (reply target).
    active: usize = 0,

    pub fn listen(self: *Server, port: u16) !void {
        if (port == 0) return;
        const sock_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(sock_rc) != .SUCCESS) return error.Socket;
        const fd: i32 = @intCast(sock_rc);
        var yes: c_int = 1;
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&yes), @sizeOf(c_int));
        // Loopback only: admin has no auth (give/kick/shutdown). Do not bind 0.0.0.0.
        var addr = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
        };
        const rc = linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
        if (linux.errno(rc) != .SUCCESS) {
            _ = linux.close(fd);
            return error.Bind;
        }
        const lc = linux.listen(fd, 4);
        if (linux.errno(lc) != .SUCCESS) {
            _ = linux.close(fd);
            return error.Listen;
        }
        self.fd = fd;
        self.port = port;
    }

    pub fn deinit(self: *Server) void {
        for (&self.sessions) |*s| {
            if (s.* >= 0) _ = linux.close(s.*);
            s.* = -1;
        }
        self.recv_lens = .{0} ** max_sessions;
        if (self.fd >= 0) _ = linux.close(self.fd);
        self.fd = -1;
    }

    fn acceptNew(self: *Server) void {
        var addr: linux.sockaddr.storage = undefined;
        var alen: linux.socklen_t = @sizeOf(linux.sockaddr.storage);
        const cfd_r = linux.accept(self.fd, @ptrCast(&addr), &alen);
        if (linux.errno(cfd_r) != .SUCCESS) return;
        const cfd: i32 = @intCast(cfd_r);
        const fl = linux.fcntl(cfd, linux.F.GETFL, 0);
        _ = linux.fcntl(cfd, linux.F.SETFL, fl | 0o4000); // O_NONBLOCK
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
        _ = linux.close(self.sessions[0]);
        self.sessions[0] = cfd;
        self.recv_lens[0] = 0;
        self.active = 0;
        self.reply("zdtd admin. 'help' for commands.\n");
    }

    /// Non-blocking: accept new sessions, then read one line from any session.
    /// Sessions stay open across commands (telnet-style); replies go to the
    /// session that sent the line.
    pub fn pollLine(self: *Server, buf: []u8) ?[]const u8 {
        if (self.fd < 0) return null;
        self.acceptNew();
        for (&self.sessions, 0..) |*s, i| {
            if (s.* < 0) continue;
            const pending = self.recv_lens[i];
            if (pending == max_cmd) {
                _ = linux.close(s.*);
                s.* = -1;
                self.recv_lens[i] = 0;
                continue;
            }
            var total = pending;
            if (std.mem.indexOfScalar(u8, self.recv_bufs[i][0..pending], '\n') == null) {
                const dst = self.recv_bufs[i][pending..];
                const n = linux.read(s.*, dst.ptr, dst.len);
                const errn = linux.errno(n);
                if (errn == .AGAIN) continue;
                if (errn != .SUCCESS or n == 0) {
                    _ = linux.close(s.*);
                    s.* = -1;
                    self.recv_lens[i] = 0;
                    continue;
                }
                total += @intCast(n);
            }
            const newline = std.mem.indexOfScalar(u8, self.recv_bufs[i][0..total], '\n') orelse {
                self.recv_lens[i] = total;
                continue;
            };
            var end = newline;
            if (end > 0 and self.recv_bufs[i][end - 1] == '\r') end -= 1;
            if (end > buf.len) {
                _ = linux.close(s.*);
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

    /// Best-effort response to the session whose line is being handled.
    pub fn reply(self: *Server, text: []const u8) void {
        const fd = self.sessions[self.active];
        if (fd < 0) return;
        var sent: usize = 0;
        while (sent < text.len) {
            const n = linux.write(fd, text[sent..].ptr, text.len - sent);
            if (linux.errno(n) != .SUCCESS or n == 0) return;
            sent += @intCast(n);
        }
    }
};

pub const Command = union(enum) {
    help,
    status,
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
    unknown,
};

pub fn parseCommand(line: []const u8) Command {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const cmd = it.next() orelse return .unknown;
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "?")) return .help;
    if (std.mem.eql(u8, cmd, "status")) return .status;
    if (std.mem.eql(u8, cmd, "save")) return .save;
    if (std.mem.eql(u8, cmd, "kick")) {
        const p = it.next() orelse return .unknown;
        const peer = std.fmt.parseInt(usize, p, 10) catch return .unknown;
        return .{ .kick = peer };
    }
    if (std.mem.eql(u8, cmd, "ban")) {
        const p = it.next() orelse return .unknown;
        const peer = std.fmt.parseInt(usize, p, 10) catch return .unknown;
        return .{ .ban = peer };
    }
    if (std.mem.eql(u8, cmd, "unban")) {
        const p = it.next() orelse return .unknown;
        const ip = std.fmt.parseInt(u32, p, 16) catch return .unknown;
        return .{ .unban = ip };
    }
    if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "players")) return .list;
    if (std.mem.eql(u8, cmd, "give")) {
        const p = it.next() orelse return .unknown;
        const i = it.next() orelse return .unknown;
        const c = it.next() orelse "1";
        return .{ .give = .{
            .peer = std.fmt.parseInt(usize, p, 10) catch return .unknown,
            .item = std.fmt.parseInt(u16, i, 10) catch return .unknown,
            .count = std.fmt.parseInt(u16, c, 10) catch return .unknown,
        } };
    }
    if (std.mem.eql(u8, cmd, "tele")) {
        const p = it.next() orelse return .unknown;
        const xs = it.next() orelse return .unknown;
        const ys = it.next() orelse return .unknown;
        const zs = it.next() orelse return .unknown;
        return .{ .tele = .{
            .peer = std.fmt.parseInt(usize, p, 10) catch return .unknown,
            .x = std.fmt.parseFloat(f32, xs) catch return .unknown,
            .y = std.fmt.parseFloat(f32, ys) catch return .unknown,
            .z = std.fmt.parseFloat(f32, zs) catch return .unknown,
        } };
    }
    if (std.mem.eql(u8, cmd, "say")) {
        const rest = std.mem.trimStart(u8, line["say".len..], " ");
        if (rest.len == 0) return .unknown;
        return .{ .say = rest };
    }
    if (std.mem.eql(u8, cmd, "kill")) {
        const p = it.next() orelse return .unknown;
        const id = std.fmt.parseInt(i32, p, 10) catch return .unknown;
        return .{ .kill = id };
    }
    if (std.mem.eql(u8, cmd, "inv")) {
        const p = it.next() orelse return .unknown;
        const peer = std.fmt.parseInt(usize, p, 10) catch return .unknown;
        return .{ .inv = peer };
    }
    if (std.mem.eql(u8, cmd, "gettime") or std.mem.eql(u8, cmd, "gt")) return .gettime;
    if (std.mem.eql(u8, cmd, "settime") or std.mem.eql(u8, cmd, "st")) {
        const a = it.next() orelse return .unknown;
        if (std.mem.eql(u8, a, "day")) return .{ .settime = .{ .day = 0, .hour = 8, .minute = 0 } };
        if (std.mem.eql(u8, a, "night")) return .{ .settime = .{ .day = 0, .hour = 22, .minute = 0 } };
        // Stock telnet often sends a single world-time integer (e.g. 8000, 22000).
        // Packing used by playtest orch: thousands digit ~ hour*1000-ish; map common values.
        const n = std.fmt.parseInt(u32, a, 10) catch return .unknown;
        if (it.peek() == null) {
            // Single token: either stock ticks-ish or a lone day number.
            if (n >= 100) {
                // 8000 -> 08:00, 22000 -> 22:00, 12000 -> 12:00
                const hour: u8 = @intCast(@min(23, n / 1000));
                const minute: u8 = @intCast(@min(59, (n % 1000) / 10)); // coarse
                return .{ .settime = .{ .day = 0, .hour = hour, .minute = minute } };
            }
            return .{ .settime = .{ .day = n, .hour = 8, .minute = 0 } };
        }
        // "settime <day> <hour> <minute>"
        const h = std.fmt.parseInt(u8, it.next() orelse "8", 10) catch return .unknown;
        const mi = std.fmt.parseInt(u8, it.next() orelse "0", 10) catch return .unknown;
        if (h > 23 or mi > 59) return .unknown;
        return .{ .settime = .{ .day = n, .hour = h, .minute = mi } };
    }
    if (std.mem.eql(u8, cmd, "spawnentity") or std.mem.eql(u8, cmd, "se")) {
        const p = it.next() orelse return .unknown;
        // peer slot (0..7) or stock player entity id (>=100). Game resolves both.
        const peer = std.fmt.parseInt(usize, p, 10) catch return .unknown;
        const name = it.next() orelse return .unknown;
        // Offsets into the original line (name slice must outlive tokenizer).
        const off = @intFromPtr(name.ptr) - @intFromPtr(line.ptr);
        return .{ .spawnentity = .{ .peer = peer, .name_off = off, .name_len = name.len } };
    }
    if (std.mem.eql(u8, cmd, "listents") or std.mem.eql(u8, cmd, "le")) return .listents;
    if (std.mem.eql(u8, cmd, "listplayers") or std.mem.eql(u8, cmd, "lp")) return .listplayers;
    if (std.mem.eql(u8, cmd, "killall") or std.mem.eql(u8, cmd, "ka")) return .killall;
    if (std.mem.eql(u8, cmd, "saveworld") or std.mem.eql(u8, cmd, "sa")) return .saveworld;
    if (std.mem.eql(u8, cmd, "shutdown")) return .shutdown;
    if (std.mem.eql(u8, cmd, "version")) return .version;
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

test "parse rejects malformed numeric arguments" {
    try std.testing.expect(parseCommand("give 0 2 many") == .unknown);
    try std.testing.expect(parseCommand("settime 7 noon 30") == .unknown);
    try std.testing.expect(parseCommand("settime 7 24 00") == .unknown);
    try std.testing.expect(parseCommand("settime 7 23 60") == .unknown);
}
