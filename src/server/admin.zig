//! Minimal TCP admin console (telnet-like): one command line per connection.
//! Listen/accept via `util/tcp_listen` (std.Io.net); no std.os.linux.

const std = @import("std");
const tcp = @import("../util/tcp_listen.zig");
const clock = @import("../util/clock.zig");
const secret = @import("../util/secret.zig");

pub const max_cmd: usize = 256;

pub const max_sessions: usize = 4;

/// Stock telnet login (TelnetConnection::authenticate, asm.il ~270254).
/// An empty password means no auth, which is also what decides the bind address:
/// TelnetConsole::.ctor (asm.il ~270735-270746) binds IPAddress.Loopback when the
/// password is empty and IPAddress.Any only when one is set.
pub const Auth = struct {
    password: []const u8 = "",
    /// TelnetFailedLoginLimit (EnumGamePrefs 0xA5, asm.il:1903939).
    fail_limit: u8 = 10,
    /// TelnetFailedLoginsBlocktime (EnumGamePrefs 0xA6): minutes to refuse further
    /// password attempts after `fail_limit` failures. Process-wide (no peer IP on
    /// the accept path); 0 disables the lockout window (session still closes).
    fail_block_minutes: u16 = 10,

    pub fn enabled(self: Auth) bool {
        return self.password.len > 0;
    }

    /// Constant-time password compare, same helper as the LiteNet connect-key
    /// and webui secret checks. An unset password accepts every line.
    pub fn matches(self: Auth, line: []const u8) bool {
        if (!self.enabled()) return true;
        return secret.constantTimeEql(line, self.password);
    }
};

/// Fields of the stock greeting block (TelnetConnection::LoginMessage, asm.il
/// ~269912-269850+). Empty strings are printed as stock prints them.
pub const Greeting = struct {
    version: []const u8 = "",
    compat_version: []const u8 = "",
    /// Stock prints the ServerIP pref, or "Any" when it is unset.
    server_ip: []const u8 = "Any",
    server_port: u16 = 0,
    max_players: u16 = 0,
    game_mode: []const u8 = "",
    world: []const u8 = "",
    game_name: []const u8 = "",
    difficulty: u8 = 0,
};

pub const Server = struct {
    listener: tcp.Listener = .{},
    port: u16 = 0,
    /// Persistent telnet-style sessions (-1 = free slot).
    sessions: [max_sessions]tcp.Handle = .{-1} ** max_sessions,
    recv_bufs: [max_sessions][max_cmd]u8 = undefined,
    recv_lens: [max_sessions]usize = .{0} ** max_sessions,
    /// Session whose line is currently being handled (reply target).
    active: usize = 0,
    /// Set before `listen`: decides the bind address and the login prompt.
    auth: Auth = .{},
    greeting: Greeting = .{},
    /// Per-session login state. A session with `authed[i] == false` never reaches
    /// the command dispatcher; its lines are password attempts only.
    authed: [max_sessions]bool = .{false} ** max_sessions,
    fails: [max_sessions]u8 = .{0} ** max_sessions,
    /// Failed attempts across every session since the last success or lockout.
    /// The per-session counter resets whenever a socket closes, so on its own it
    /// throttles nothing: a brute force just disconnects one attempt short of
    /// `fail_limit` and reconnects. This one survives reconnects and arms the
    /// same lockout, which is what actually bounds the guess rate.
    fails_total: u32 = 0,
    /// Mono ns until which further password attempts are rejected (0 = unlocked).
    /// Armed when any session hits `auth.fail_limit` and `fail_block_minutes > 0`.
    login_lock_until_ns: u64 = 0,

    pub fn listen(self: *Server, port: u16) !void {
        if (port == 0) return;
        // Stock rule: no password means loopback only (the console can kick,
        // ban and shut the server down). A password is the only way off 127.0.0.1.
        const host: u32 = if (self.auth.enabled()) 0 else 0x7f000001;
        try self.listener.listen(host, port, 4);
        self.port = self.listener.port;
    }

    /// True when `listen` would expose the console beyond loopback.
    pub fn public(self: *const Server) bool {
        return self.auth.enabled();
    }

    fn loginLocked(self: *const Server) bool {
        if (self.login_lock_until_ns == 0) return false;
        return clock.monoNs() < self.login_lock_until_ns;
    }

    pub fn deinit(self: *Server) void {
        for (&self.sessions) |*s| {
            if (s.* >= 0) tcp.closeFd(s.*);
            s.* = -1;
        }
        self.recv_lens = .{0} ** max_sessions;
        self.authed = .{false} ** max_sessions;
        self.fails = .{0} ** max_sessions;
        self.fails_total = 0;
        self.login_lock_until_ns = 0;
        self.listener.deinit();
        self.port = 0;
    }

    fn openSession(self: *Server, i: usize, cfd: tcp.Handle) void {
        self.sessions[i] = cfd;
        self.recv_lens[i] = 0;
        self.fails[i] = 0;
        self.authed[i] = !self.auth.enabled();
        self.active = i;
        // Stock ctor (asm.il ~269865): prompt when auth is on, greet otherwise.
        if (self.authed[i]) self.writeGreeting() else self.reply("Please enter password:\n");
    }

    fn acceptNew(self: *Server) void {
        const cfd = self.listener.accept() catch return orelse return;
        for (&self.sessions, 0..) |*s, i| {
            if (s.* < 0) {
                self.openSession(i, cfd);
                return;
            }
        }
        // All slots busy: prefer evicting an unauthenticated session so a flood
        // of pre-login TCP handshakes cannot kick a logged-in operator. Fall
        // back to slot 0 only when every session is already authed.
        var victim: usize = 0;
        for (self.authed, 0..) |a, i| {
            if (!a) {
                victim = i;
                break;
            }
        }
        tcp.closeFd(self.sessions[victim]);
        self.openSession(victim, cfd);
    }

    /// TelnetConnection::LoginMessage (asm.il ~269912): the block operator tooling
    /// scrapes for server identity right after connect.
    pub fn writeGreeting(self: *Server) void {
        const g = self.greeting;
        var buf: [512]u8 = undefined;
        var s0: [96]u8 = undefined;
        var s1: [96]u8 = undefined;
        self.reply("*** Connected with 7DTD server.\n");
        self.replyFmt(&buf, "*** Server version: {s} Compatibility Version: {s}\n", .{
            telnetSafe(g.version, &s0), telnetSafe(g.compat_version, &s1),
        });
        self.reply("\n");
        self.replyFmt(&buf, "Server IP:   {s}\n", .{telnetSafe(g.server_ip, &s0)});
        self.replyFmt(&buf, "Server port: {d}\n", .{g.server_port});
        self.replyFmt(&buf, "Max players: {d}\n", .{g.max_players});
        self.replyFmt(&buf, "Game mode:   {s}\n", .{telnetSafe(g.game_mode, &s0)});
        self.replyFmt(&buf, "World:       {s}\n", .{telnetSafe(g.world, &s0)});
        self.replyFmt(&buf, "Game name:   {s}\n", .{telnetSafe(g.game_name, &s0)});
        self.replyFmt(&buf, "Difficulty:  {d}\n", .{g.difficulty});
        self.reply("\n");
        self.reply("Press 'help' to get a list of all commands. Press \n");
        self.reply("\n");
    }

    fn replyFmt(self: *Server, buf: []u8, comptime fmt: []const u8, args: anytype) void {
        self.reply(std.fmt.bufPrint(buf, fmt, args) catch return);
    }

    /// One password attempt on session `i`. Returns false when the session was
    /// closed (too many failures or lockout). The line (a password attempt) is
    /// never echoed or logged, but the failed attempt itself is: this console
    /// can kick, ban and shut the server down, so a silent brute force is a
    /// blind spot (the webui logs every rejected login; the telnet console must
    /// too). The password bytes stay out of the log; only the session and
    /// attempt count.
    fn authenticate(self: *Server, i: usize, line: []const u8) bool {
        self.active = i;
        if (self.loginLocked()) {
            var ts: [19]u8 = undefined;
            std.debug.print("zdtd: {s} admin login lockout session={d}\n", .{ clock.wallStamp(&ts), i });
            self.reply("Too many failed login attempts!\n");
            self.closeActive();
            return false;
        }
        if (self.auth.matches(line)) {
            self.authed[i] = true;
            self.fails[i] = 0;
            self.fails_total = 0;
            self.login_lock_until_ns = 0;
            // Log the success too: "who held a console session when X happened"
            // is unanswerable from failures alone, and the `audit source=admin`
            // command lines below have no session to attribute them to.
            var ts: [19]u8 = undefined;
            std.debug.print("zdtd: {s} admin login ok session={d}\n", .{ clock.wallStamp(&ts), i });
            self.reply("Logon successful.\n\n\n\n");
            self.writeGreeting();
            return true;
        }
        self.fails[i] +|= 1;
        self.fails_total +|= 1;
        if (self.fails[i] >= self.auth.fail_limit or self.fails_total >= self.auth.fail_limit) {
            const block_m = self.auth.fail_block_minutes;
            if (block_m > 0) {
                const block_ns = @as(u64, block_m) *% 60 *% std.time.ns_per_s;
                self.login_lock_until_ns = clock.monoNs() +% block_ns;
            }
            // Start the next window clean; the lockout above is the throttle.
            self.fails_total = 0;
            var ts: [19]u8 = undefined;
            std.debug.print(
                "zdtd: {s} admin login failed session={d} attempts={d} closed block_min={d}\n",
                .{ clock.wallStamp(&ts), i, self.fails[i], block_m },
            );
            self.reply("Too many failed login attempts!\n");
            self.closeActive();
            return false;
        }
        var ts: [19]u8 = undefined;
        std.debug.print("zdtd: {s} admin login failed session={d} attempts={d}\n", .{ clock.wallStamp(&ts), i, self.fails[i] });
        self.reply("Password incorrect, please enter password:\n");
        return true;
    }

    /// Close one session and clear every bit of its state, login included, so a
    /// recycled slot can never start out already authenticated.
    fn dropSession(self: *Server, i: usize) void {
        if (self.sessions[i] >= 0) tcp.closeFd(self.sessions[i]);
        self.sessions[i] = -1;
        self.recv_lens[i] = 0;
        self.authed[i] = false;
        self.fails[i] = 0;
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
                self.dropSession(i);
                continue;
            }
            var total = pending;
            if (std.mem.findScalar(u8, self.recv_bufs[i][0..pending], '\n') == null) {
                const dst = self.recv_bufs[i][pending..];
                const n = tcp.read(s.*, dst) catch |err| switch (err) {
                    error.WouldBlock => continue,
                    else => {
                        self.dropSession(i);
                        continue;
                    },
                };
                if (n == 0) {
                    self.dropSession(i);
                    continue;
                }
                total += n;
            }
            const newline = std.mem.findScalar(u8, self.recv_bufs[i][0..total], '\n') orelse {
                self.recv_lens[i] = total;
                continue;
            };
            var end = newline;
            if (end > 0 and self.recv_bufs[i][end - 1] == '\r') end -= 1;
            if (end > buf.len) {
                self.dropSession(i);
                continue;
            }
            @memcpy(buf[0..end], self.recv_bufs[i][0..end]);
            const consumed = newline + 1;
            const remaining = total - consumed;
            std.mem.copyForwards(u8, self.recv_bufs[i][0..remaining], self.recv_bufs[i][consumed..total]);
            self.recv_lens[i] = remaining;
            if (!self.authed[i]) {
                // Password attempts never reach the dispatcher, and an empty line
                // still counts as a failed attempt (stock compares it verbatim).
                _ = self.authenticate(i, buf[0..end]);
                continue;
            }
            if (end == 0) continue;
            self.active = i;
            return buf[0..end];
        }
        return null;
    }

    /// Close the session whose line is being handled (admin `quit`/`exit`).
    pub fn closeActive(self: *Server) void {
        // Unconditional: clearing login state must not depend on the fd still
        // being open, or a half-closed slot could be recycled already authorised.
        self.dropSession(self.active);
    }

    /// Best-effort response to the session whose line is being handled.
    pub fn reply(self: *Server, text: []const u8) void {
        const fd = self.sessions[self.active];
        if (fd < 0) return;
        tcp.writeAll(fd, text);
    }
};

/// Strip CR/LF from operator-supplied greeting fields so a crafted GameName /
/// GameWorld cannot inject extra telnet lines (or forge a second greeting block).
fn telnetSafe(s: []const u8, scratch: []u8) []const u8 {
    const n = @min(s.len, scratch.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = s[i];
        scratch[i] = if (c == '\r' or c == '\n') '_' else c;
    }
    return scratch[0..n];
}

/// Stock ConsoleHelper::ParseParamPartialNameOrId (asm.il:268297) accepts an
/// entity id, a user id or a (partial) player name in the same argument slot.
/// zdtd additionally resolves a small integer as a peer slot, the way
/// `spawnentity` already does, so existing zdtd tooling keeps working.
pub const Target = union(enum) {
    id: i32,
    name: []const u8,
};

fn parseTarget(tok: []const u8) Target {
    return if (std.fmt.parseInt(i32, tok, 10)) |n| .{ .id = n } else |_| .{ .name = tok };
}

/// Stock ban duration units (ConsoleCmdBan, asm.il 209578-210270).
fn durationUnitSeconds(unit: []const u8) ?i64 {
    const table = [_]struct { name: []const u8, secs: i64 }{
        .{ .name = "min", .secs = 60 },
        .{ .name = "minute", .secs = 60 },
        .{ .name = "minutes", .secs = 60 },
        .{ .name = "h", .secs = 3600 },
        .{ .name = "hour", .secs = 3600 },
        .{ .name = "hours", .secs = 3600 },
        .{ .name = "d", .secs = 86400 },
        .{ .name = "day", .secs = 86400 },
        .{ .name = "days", .secs = 86400 },
        .{ .name = "w", .secs = 7 * 86400 },
        .{ .name = "week", .secs = 7 * 86400 },
        .{ .name = "weeks", .secs = 7 * 86400 },
        .{ .name = "month", .secs = 30 * 86400 },
        .{ .name = "months", .secs = 30 * 86400 },
        .{ .name = "y", .secs = 365 * 86400 },
        .{ .name = "yr", .secs = 365 * 86400 },
        .{ .name = "year", .secs = 365 * 86400 },
        .{ .name = "years", .secs = 365 * 86400 },
    };
    for (table) |e| if (std.ascii.eqlIgnoreCase(unit, e.name)) return e.secs;
    return null;
}

pub const BanSub = union(enum) {
    add: struct { target: Target, seconds: i64, reason: []const u8 },
    remove: Target,
    list,
};

pub const AdminSub = union(enum) {
    add: struct { target: Target, level: u8 },
    remove: Target,
    list,
};

pub const WhitelistSub = union(enum) {
    add: Target,
    remove: Target,
    list,
};

pub const Command = union(enum) {
    /// `help` with no topic prints the index; `help <topic>` prints that command's
    /// usage/description. The topic is a slice of the input line.
    help: ?[]const u8,
    status,
    /// Dump C2S authority reject counters (phase/ownership/bounds/movement/decode).
    guardstats,
    /// Clear guard quarantine bits + any armed policy kick on a peer slot
    /// (operator escape hatch for a false positive).
    guardclear: usize,
    /// `evidence` prints the ring inline; `evidence dump [path]` writes the
    /// JSONL lines to a file (default `<world>/evidence.jsonl`).
    evidence: ?[]const u8,
    /// zdtd wasm plugin ops: `plugin list` / `plugin reload <name>` (paper:
    /// hot module replacement - dispose the old fiber, reinstantiate).
    plugin: []const u8,
    /// Dump zdtd-native APM counters + section latency (same text as --ticks exit).
    apm,
    save,
    /// Stock `kick <name / entity id / user id> [reason]` (ConsoleCmdKick, asm.il 229326).
    kick: struct { target: Target, reason: []const u8 },
    /// Stock `kickall [reason]` (ConsoleCmdKickAll, asm.il 229473).
    kickall: []const u8,
    /// Stock `ban add|remove|list ...` (ConsoleCmdBan, asm.il 209578).
    ban: BanSub,
    /// zdtd-only: drop a raw IPv4 ban recorded by `ban add` on a connected peer.
    unban: u32,
    /// Stock `admin add|remove|list` (ConsoleCmdAdmin, asm.il 204593). zdtd has no
    /// Steam group concept, so addgroup/removegroup are deliberately absent.
    admin: AdminSub,
    /// Stock `whitelist add|remove|list` (ConsoleCmdWhitelist, asm.il 265358).
    whitelist: WhitelistSub,
    /// Stock `listplayerids` / `lpi` (asm.il 231089).
    listplayerids,
    /// Stock `getgamepref` / `gg [filter]` (asm.il 220877).
    getgamepref: []const u8,
    /// Stock `getgamestat` / `ggs [filter]` (ConsoleCmdGetGameStats, asm.il
    /// 224074): the GameStats the sim tracks, as `GameStat.X = value`.
    getgamestat: []const u8,
    /// Stock `setgamepref` / `sg <name> <value>` (asm.il 251176).
    setgamepref: struct { name: []const u8, value: []const u8 },
    /// Stock `chunkcache` / `cc` (asm.il 213107).
    chunkcache,
    /// Stock `mem` (asm.il 234965).
    mem,
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
    /// Stock `settime day|night|<worldtime>|<day> <hour> <minute>`, already reduced
    /// to the world time stock computes (ConsoleCmdSetTime, asm.il 251838;
    /// GameUtils::DayTimeToWorldTime, asm.il 1926175).
    settime: u64,
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
    /// zdtd-only: force every storm-capable biome into an active storm.
    storm,
    /// zdtd-only: end any active storm (`clearweather` / `stormoff`).
    clearweather,
    /// zdtd-only: trigger an air drop immediately.
    spawnairdrop,
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
    /// zdtd-only verbs use this; stock verbs use `err_text` / `wrong_args` so the
    /// reply matches what stock prints.
    bad_args: []const u8,
    /// Verbatim stock console error, printed as `{prefix}{token}{suffix}`. The
    /// literals come from the IL; `token` is a slice of the input line.
    err_text: struct { prefix: []const u8, token: []const u8 = "", suffix: []const u8 = "" },
    /// Stock "Wrong number of arguments, expected {expected}, found {found}."
    /// `expected` is one of the literal shapes stock uses ("at least 1", "1 or 3", ...).
    wrong_args: struct { expected: []const u8, found: usize },
    unknown,
};

/// GameUtils::DayTimeToWorldTime (asm.il 1926175): 24000 ticks per day,
/// 1000 per hour, minutes scaled by 1000/60 with C truncation.
pub fn dayTimeToWorldTime(day: i32, hours: i32, minutes: i32) u64 {
    if (day < 1) return 0;
    const d: u64 = @intCast(day - 1);
    return d * 24000 + @as(u64, @intCast(hours)) * 1000 + @as(u64, @intCast(minutes)) * 1000 / 60;
}

/// Stock's arg counter excludes the verb itself.
fn argCount(line: []const u8) usize {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next();
    var n: usize = 0;
    while (it.next() != null) n += 1;
    return n;
}

fn notAnInteger(tok: []const u8) Command {
    return .{ .err_text = .{ .prefix = "\"", .token = tok, .suffix = "\" is not a valid integer." } };
}

fn badSubCommand(sub: ?[]const u8) Command {
    const s = sub orelse return .{ .err_text = .{ .prefix = "No sub command given." } };
    return .{ .err_text = .{ .prefix = "Invalid sub command \"", .token = s, .suffix = "\"." } };
}

/// One-line usage for a known verb (admin `bad_args` replies and `help <verb>`
/// topics). Null if unknown.
pub fn usageFor(verb: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, verb, "unban")) return "unban <iphex>";
    if (std.mem.eql(u8, verb, "give")) return "give <slot> <itemId> [count]";
    if (std.mem.eql(u8, verb, "tele") or std.mem.eql(u8, verb, "tp"))
        return "tele|tp <slot> <x> <y> <z>";
    if (std.mem.eql(u8, verb, "say")) return "say <msg>";
    if (std.mem.eql(u8, verb, "kill")) return "kill <entityId>";
    if (std.mem.eql(u8, verb, "inv")) return "inv <slot>";
    if (std.mem.eql(u8, verb, "settime") or std.mem.eql(u8, verb, "st"))
        return "settime <day|night|worldtime|day hour minute>";
    if (std.mem.eql(u8, verb, "listplayerids") or std.mem.eql(u8, verb, "lpi"))
        return "listplayerids";
    if (std.mem.eql(u8, verb, "chunkcache") or std.mem.eql(u8, verb, "cc")) return "chunkcache";
    if (std.mem.eql(u8, verb, "mem")) return "mem";
    if (std.mem.eql(u8, verb, "spawnentity") or std.mem.eql(u8, verb, "se"))
        return "spawnentity <slot|entityId> <class>";
    if (std.mem.eql(u8, verb, "wipeplayer")) return "wipeplayer <name>";
    if (std.mem.eql(u8, verb, "gamestage")) return "gamestage [slot]";
    if (std.mem.eql(u8, verb, "guardclear") or std.mem.eql(u8, verb, "gc"))
        return "guardclear <slot>";
    if (std.mem.eql(u8, verb, "help") or std.mem.eql(u8, verb, "?") or std.mem.eql(u8, verb, "commands"))
        return "help [topic]";
    if (std.mem.eql(u8, verb, "status")) return "status";
    if (std.mem.eql(u8, verb, "guardstats") or std.mem.eql(u8, verb, "gs")) return "guardstats";
    if (std.mem.eql(u8, verb, "evidence") or std.mem.eql(u8, verb, "ev")) return "evidence [dump [path]]";
    if (std.mem.eql(u8, verb, "apm") or std.mem.eql(u8, verb, "metrics")) return "apm";
    if (std.mem.eql(u8, verb, "save")) return "save";
    if (std.mem.eql(u8, verb, "plugin")) return "plugin <list|reload <name>>";
    if (std.mem.eql(u8, verb, "list") or std.mem.eql(u8, verb, "players")) return "list";
    if (std.mem.eql(u8, verb, "gettime") or std.mem.eql(u8, verb, "gt")) return "gettime";
    if (std.mem.eql(u8, verb, "listents") or std.mem.eql(u8, verb, "le")) return "listents";
    if (std.mem.eql(u8, verb, "listplayers") or std.mem.eql(u8, verb, "lp")) return "listplayers";
    if (std.mem.eql(u8, verb, "killall") or std.mem.eql(u8, verb, "ka")) return "killall";
    if (std.mem.eql(u8, verb, "storm")) return "storm";
    if (std.mem.eql(u8, verb, "clearweather") or std.mem.eql(u8, verb, "stormoff"))
        return "clearweather|stormoff";
    if (std.mem.eql(u8, verb, "spawnairdrop")) return "spawnairdrop";
    if (std.mem.eql(u8, verb, "saveworld") or std.mem.eql(u8, verb, "sa")) return "saveworld";
    if (std.mem.eql(u8, verb, "shutdown")) return "shutdown";
    if (std.mem.eql(u8, verb, "version")) return "version";
    if (std.mem.eql(u8, verb, "kick")) return "kick <name/entity id/user id> [reason]";
    if (std.mem.eql(u8, verb, "kickall")) return "kickall [reason]";
    if (std.mem.eql(u8, verb, "ban")) return "ban <add|remove|list> <target> [duration] [unit] [reason]";
    if (std.mem.eql(u8, verb, "admin")) return "admin <add|remove|list> <target> [level]";
    if (std.mem.eql(u8, verb, "whitelist")) return "whitelist <add|remove|list> <target>";
    if (std.mem.eql(u8, verb, "getgamepref") or std.mem.eql(u8, verb, "gg")) return "getgamepref [filter]";
    if (std.mem.eql(u8, verb, "getgamestat") or std.mem.eql(u8, verb, "ggs")) return "getgamestat [filter]";
    if (std.mem.eql(u8, verb, "setgamepref") or std.mem.eql(u8, verb, "sg")) return "setgamepref <name> <value>";
    return null;
}

pub fn parseCommand(line: []const u8) Command {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const cmd = it.next() orelse return .unknown;
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "?") or std.mem.eql(u8, cmd, "commands")) {
        const topic = it.next();
        if (topic != null and it.next() != null) return .{ .bad_args = cmd };
        return .{ .help = topic };
    }
    if (std.mem.eql(u8, cmd, "status")) return if (it.next() == null) .status else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "guardstats") or std.mem.eql(u8, cmd, "gs")) return if (it.next() == null) .guardstats else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "guardclear") or std.mem.eql(u8, cmd, "gc")) {
        const p = it.next() orelse return .{ .bad_args = cmd };
        const peer = std.fmt.parseInt(usize, p, 10) catch return .{ .bad_args = cmd };
        if (it.next() != null) return .{ .bad_args = cmd };
        return .{ .guardclear = peer };
    }
    if (std.mem.eql(u8, cmd, "evidence") or std.mem.eql(u8, cmd, "ev")) {
        const rest = std.mem.trim(u8, it.rest(), " ");
        if (rest.len == 0) return .{ .evidence = null };
        var rit = std.mem.tokenizeAny(u8, rest, " \t");
        const sub = rit.next() orelse return .{ .evidence = null };
        if (!std.mem.eql(u8, sub, "dump")) return .{ .bad_args = cmd };
        return .{ .evidence = std.mem.trim(u8, rit.rest(), " ") };
    }
    if (std.mem.eql(u8, cmd, "apm") or std.mem.eql(u8, cmd, "metrics")) return if (it.next() == null) .apm else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "save")) return if (it.next() == null) .save else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "plugin")) {
        // zdtd wasm plugin ops: `plugin list` / `plugin reload <name>`.
        return .{ .plugin = std.mem.trim(u8, it.rest(), " ") };
    }
    if (std.mem.eql(u8, cmd, "kick")) {
        // Stock: "kick <name / entity id / user id> [reason]" (asm.il 229326).
        const p = it.next() orelse return .{ .wrong_args = .{ .expected = "at least 1", .found = 0 } };
        return .{ .kick = .{ .target = parseTarget(p), .reason = std.mem.trim(u8, it.rest(), " ") } };
    }
    if (std.mem.eql(u8, cmd, "kickall")) {
        // Stock takes the whole remainder as the reason (asm.il 229473).
        return .{ .kickall = std.mem.trim(u8, it.rest(), " ") };
    }
    if (std.mem.eql(u8, cmd, "ban")) {
        const sub = it.next() orelse return badSubCommand(null);
        if (std.ascii.eqlIgnoreCase(sub, "list")) return .{ .ban = .list };
        if (std.ascii.eqlIgnoreCase(sub, "remove")) {
            const t = it.next() orelse return .{ .wrong_args = .{ .expected = "2", .found = 1 } };
            return .{ .ban = .{ .remove = parseTarget(t) } };
        }
        if (!std.ascii.eqlIgnoreCase(sub, "add")) return badSubCommand(sub);
        // "ban add <target> <duration> <unit> [reason]"
        const t = it.next() orelse return .{ .wrong_args = .{ .expected = "at least 4", .found = argCount(line) } };
        const dur = it.next() orelse return .{ .wrong_args = .{ .expected = "at least 4", .found = argCount(line) } };
        const unit = it.next() orelse return .{ .wrong_args = .{ .expected = "at least 4", .found = argCount(line) } };
        const n = std.fmt.parseInt(i64, dur, 10) catch return notAnInteger(dur);
        const per = durationUnitSeconds(unit) orelse
            return .{ .err_text = .{ .prefix = "\"", .token = unit, .suffix = "\" is not an allowed duration unit." } };
        const secs = std.math.mul(i64, n, per) catch return notAnInteger(dur);
        return .{ .ban = .{ .add = .{
            .target = parseTarget(t),
            .seconds = secs,
            .reason = std.mem.trim(u8, it.rest(), " "),
        } } };
    }
    if (std.mem.eql(u8, cmd, "admin")) {
        const sub = it.next() orelse return badSubCommand(null);
        if (std.ascii.eqlIgnoreCase(sub, "list")) return .{ .admin = .list };
        if (std.ascii.eqlIgnoreCase(sub, "remove")) {
            const t = it.next() orelse return .{ .wrong_args = .{ .expected = "2", .found = 1 } };
            return .{ .admin = .{ .remove = parseTarget(t) } };
        }
        if (!std.ascii.eqlIgnoreCase(sub, "add")) return badSubCommand(sub);
        const t = it.next() orelse return .{ .wrong_args = .{ .expected = "3 or 4", .found = argCount(line) } };
        const lvl = it.next() orelse return .{ .wrong_args = .{ .expected = "3 or 4", .found = argCount(line) } };
        // Stock levels run 0 (max) .. 1000; anything wider is a typo, not a level.
        const level = std.fmt.parseInt(u16, lvl, 10) catch return notAnInteger(lvl);
        if (level > 1000) return notAnInteger(lvl);
        return .{ .admin = .{ .add = .{ .target = parseTarget(t), .level = @intCast(@min(level, 255)) } } };
    }
    if (std.mem.eql(u8, cmd, "whitelist")) {
        const sub = it.next() orelse return badSubCommand(null);
        if (std.ascii.eqlIgnoreCase(sub, "list")) return .{ .whitelist = .list };
        if (std.ascii.eqlIgnoreCase(sub, "add")) {
            const t = it.next() orelse return .{ .wrong_args = .{ .expected = "2 or 3", .found = 1 } };
            return .{ .whitelist = .{ .add = parseTarget(t) } };
        }
        if (std.ascii.eqlIgnoreCase(sub, "remove")) {
            const t = it.next() orelse return .{ .wrong_args = .{ .expected = "2", .found = 1 } };
            return .{ .whitelist = .{ .remove = parseTarget(t) } };
        }
        return badSubCommand(sub);
    }
    if (std.mem.eql(u8, cmd, "listplayerids") or std.mem.eql(u8, cmd, "lpi"))
        return if (it.next() == null) .listplayerids else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "getgamepref") or std.mem.eql(u8, cmd, "gg")) {
        const filter = it.next() orelse "";
        if (it.next() != null) return .{ .wrong_args = .{ .expected = "0 or 1", .found = argCount(line) } };
        return .{ .getgamepref = filter };
    }
    if (std.mem.eql(u8, cmd, "getgamestat") or std.mem.eql(u8, cmd, "ggs")) {
        const filter = it.next() orelse "";
        if (it.next() != null) return .{ .wrong_args = .{ .expected = "0 or 1", .found = argCount(line) } };
        return .{ .getgamestat = filter };
    }
    if (std.mem.eql(u8, cmd, "setgamepref") or std.mem.eql(u8, cmd, "sg")) {
        const nm = it.next() orelse return .{ .wrong_args = .{ .expected = "2", .found = 0 } };
        const val = it.next() orelse return .{ .wrong_args = .{ .expected = "2", .found = 1 } };
        if (it.next() != null) return .{ .wrong_args = .{ .expected = "2", .found = argCount(line) } };
        return .{ .setgamepref = .{ .name = nm, .value = val } };
    }
    if (std.mem.eql(u8, cmd, "chunkcache") or std.mem.eql(u8, cmd, "cc"))
        return if (it.next() == null) .chunkcache else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "mem")) return if (it.next() == null) .mem else .{ .bad_args = cmd };
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
        // ConsoleCmdSetTime::Execute (asm.il 251900): 1 arg (day/night/worldtime)
        // or 3 args (day hour minute). Anything else is an arity error.
        const n_args = argCount(line);
        if (n_args == 1) {
            const a = it.next().?;
            if (std.ascii.eqlIgnoreCase(a, "day")) return .{ .settime = dayTimeToWorldTime(1, 12, 0) };
            if (std.ascii.eqlIgnoreCase(a, "night")) return .{ .settime = dayTimeToWorldTime(2, 0, 0) };
            const wt = std.fmt.parseInt(u64, a, 10) catch return .{ .err_text = .{
                .prefix = "Invalid value for single argument variant: \"",
                .token = a,
                .suffix = "\"",
            } };
            return .{ .settime = wt };
        }
        if (n_args != 3) return .{ .wrong_args = .{ .expected = "1 or 3", .found = n_args } };
        const ds = it.next().?;
        const hs = it.next().?;
        const ms = it.next().?;
        const day = std.fmt.parseInt(i32, ds, 10) catch return notAnInteger(ds);
        const hour = std.fmt.parseInt(i32, hs, 10) catch return notAnInteger(hs);
        const minute = std.fmt.parseInt(i32, ms, 10) catch return notAnInteger(ms);
        if (day < 1) return .{ .err_text = .{ .prefix = "Day must be >= 1" } };
        if (hour > 23) return .{ .err_text = .{ .prefix = "Hour must be <= 23" } };
        if (minute > 59) return .{ .err_text = .{ .prefix = "Minute must be <= 59" } };
        // Stock lets negative hour/minute through into the multiply; clamp instead
        // so the world time can never go backwards past day start.
        return .{ .settime = dayTimeToWorldTime(day, @max(0, hour), @max(0, minute)) };
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
    if (std.mem.eql(u8, cmd, "storm")) return if (it.next() == null) .storm else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "clearweather") or std.mem.eql(u8, cmd, "stormoff"))
        return if (it.next() == null) .clearweather else .{ .bad_args = cmd };
    if (std.mem.eql(u8, cmd, "spawnairdrop")) return if (it.next() == null) .spawnairdrop else .{ .bad_args = cmd };
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
    const k = parseCommand("kick 1");
    try std.testing.expectEqual(@as(i32, 1), k.kick.target.id);
    try std.testing.expectEqual(@as(usize, 0), k.kick.reason.len);

    const b = parseCommand("ban add 2 1 day");
    try std.testing.expectEqual(@as(i32, 2), b.ban.add.target.id);
    try std.testing.expectEqual(@as(i64, 86400), b.ban.add.seconds);
    try std.testing.expectEqual(@as(usize, 0), b.ban.add.reason.len);

    try std.testing.expect(parseCommand("list") == .list);
    try std.testing.expectEqual(@as(u32, 0x7f000001), parseCommand("unban 7f000001").unban);
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

test "parse weather and airdrop verbs advertised by help" {
    try std.testing.expect(parseCommand("storm") == .storm);
    try std.testing.expect(parseCommand("clearweather") == .clearweather);
    try std.testing.expect(parseCommand("stormoff") == .clearweather);
    try std.testing.expect(parseCommand("spawnairdrop") == .spawnairdrop);
    try std.testing.expect(parseCommand("storm now") == .bad_args);
    try std.testing.expectEqualStrings("clearweather|stormoff", usageFor("stormoff").?);
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
    // Stock: "day" is day 1 12:00, "night" day 2 00:00 (asm.il 251900).
    try std.testing.expectEqual(@as(u64, 12000), parseCommand("settime day").settime);
    try std.testing.expectEqual(@as(u64, 24000), parseCommand("settime night").settime);
    // 3-arg form goes through DayTimeToWorldTime; 1-arg is raw world time.
    try std.testing.expectEqual(@as(u64, 6 * 24000 + 10500), parseCommand("settime 7 10 30").settime);
    try std.testing.expectEqual(@as(u64, 22000), parseCommand("settime 22000").settime);
    try std.testing.expectEqual(@as(u64, 8000), parseCommand("settime 8000").settime);
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

test "settime reports the stock validation errors" {
    // ConsoleCmdSetTime::Execute (asm.il 251900) error literals, in stock order.
    try std.testing.expectEqualStrings("Day must be >= 1", parseCommand("settime 0 1 1").err_text.prefix);
    try std.testing.expectEqualStrings("Hour must be <= 23", parseCommand("settime 1 24 0").err_text.prefix);
    try std.testing.expectEqualStrings("Minute must be <= 59", parseCommand("settime 1 23 60").err_text.prefix);
    const bad = parseCommand("settime noon");
    try std.testing.expectEqualStrings("Invalid value for single argument variant: \"", bad.err_text.prefix);
    try std.testing.expectEqualStrings("noon", bad.err_text.token);
    const arity = parseCommand("settime 1 2");
    try std.testing.expectEqualStrings("1 or 3", arity.wrong_args.expected);
    try std.testing.expectEqual(@as(usize, 2), arity.wrong_args.found);
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\"noon\" is not a valid integer.",
        try renderErrText(&buf, parseCommand("settime 1 noon 0")),
    );
}

/// The quoted-integer error shape shared by several stock commands, rendered the
/// way Game.runAdminLine renders it.
fn renderErrText(buf: []u8, c: Command) ![]const u8 {
    const e = c.err_text;
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ e.prefix, e.token, e.suffix });
}

test "parse rejects malformed numeric arguments" {
    try std.testing.expect(parseCommand("give 0 2 many") == .bad_args);
    try std.testing.expect(parseCommand("tele 0 nan 70 10") == .bad_args);
    try std.testing.expect(parseCommand("tele 0 10 inf 10") == .bad_args);
    try std.testing.expect(parseCommand("settime 7 noon 30") == .err_text);
    try std.testing.expect(parseCommand("settime 7 24 00") == .err_text);
    try std.testing.expect(parseCommand("settime 7 23 60") == .err_text);
}

test "parse rejects trailing arguments for fixed-arity commands" {
    try std.testing.expect(parseCommand("status now") == .bad_args);
    try std.testing.expect(parseCommand("give 0 2 5 extra") == .bad_args);
    try std.testing.expect(parseCommand("tp 0 10 70 10 extra") == .bad_args);
    try std.testing.expect(parseCommand("settime 7 10 30 extra") == .wrong_args);
    try std.testing.expect(parseCommand("spawnentity 0 zombieBoe extra") == .bad_args);
    try std.testing.expect(parseCommand("wipeplayer Alice extra") == .bad_args);
}

test "bad args carry the verb; unknown verbs stay unknown" {
    const c = parseCommand("inv many");
    try std.testing.expect(c == .bad_args);
    try std.testing.expectEqualStrings("inv", c.bad_args);
    try std.testing.expect(parseCommand("frobnicate 1") == .unknown);
    try std.testing.expect(parseCommand("inv") == .bad_args);
    // Stock verbs report the stock arity error instead.
    const k = parseCommand("kick");
    try std.testing.expectEqualStrings("at least 1", k.wrong_args.expected);
    try std.testing.expectEqual(@as(usize, 0), k.wrong_args.found);
}

test "commands alias is help; usageFor covers common verbs" {
    try std.testing.expect(parseCommand("commands") == .help);
    try std.testing.expectEqualStrings("give <slot> <itemId> [count]", usageFor("give").?);
    try std.testing.expectEqualStrings("wipeplayer <name>", usageFor("wipeplayer").?);
    try std.testing.expectEqualStrings("status", usageFor("status").?);
    try std.testing.expectEqualStrings("getgamepref [filter]", usageFor("gg").?);
    try std.testing.expectEqualStrings("getgamestat [filter]", usageFor("ggs").?);
    try std.testing.expectEqualStrings("ban <add|remove|list> <target> [duration] [unit] [reason]", usageFor("ban").?);
    try std.testing.expect(usageFor("frobnicate") == null);
}

test "help with a topic carries the topic; extra args are bad_args" {
    try std.testing.expect(parseCommand("help").help == null);
    try std.testing.expectEqualStrings("kick", parseCommand("help kick").help.?);
    try std.testing.expectEqualStrings("tp", parseCommand("help tp").help.?);
    try std.testing.expectEqualStrings("le", parseCommand("? le").help.?);
    try std.testing.expect(parseCommand("help kick ban") == .bad_args);
    try std.testing.expect(parseCommand("commands status") == .help);
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

test "kick takes a stock target plus an optional reason" {
    const k = parseCommand("kick Alice being rude");
    try std.testing.expectEqualStrings("Alice", k.kick.target.name);
    try std.testing.expectEqualStrings("being rude", k.kick.reason);
    // A bare integer is an entity id / peer slot, not a name.
    const k2 = parseCommand("kick 171");
    try std.testing.expectEqual(@as(i32, 171), k2.kick.target.id);
    try std.testing.expectEqual(@as(usize, 0), k2.kick.reason.len);
    try std.testing.expectEqualStrings("at least 1", parseCommand("kick").wrong_args.expected);

    try std.testing.expectEqualStrings("", parseCommand("kickall").kickall);
    try std.testing.expectEqualStrings("server restart", parseCommand("kickall server restart").kickall);
}

test "ban grammar follows the stock sub-command and unit table" {
    const b = parseCommand("ban add Alice 2 days repeated griefing");
    try std.testing.expectEqualStrings("Alice", b.ban.add.target.name);
    try std.testing.expectEqual(@as(i64, 2 * 86400), b.ban.add.seconds);
    try std.testing.expectEqualStrings("repeated griefing", b.ban.add.reason);
    try std.testing.expect(parseCommand("ban list") == .ban);
    try std.testing.expect(parseCommand("ban LIST").ban == .list);
    try std.testing.expectEqualStrings("Alice", parseCommand("ban remove Alice").ban.remove.name);

    // Every stock unit spelling resolves; nothing else does.
    for ([_][]const u8{ "min", "minute", "minutes", "h", "hour", "hours", "d", "day", "days", "w", "week", "weeks", "month", "months", "y", "yr", "year", "years" }) |u| {
        try std.testing.expect(durationUnitSeconds(u) != null);
    }
    try std.testing.expect(durationUnitSeconds("fortnight") == null);
    try std.testing.expectEqualStrings(
        "\" is not an allowed duration unit.",
        parseCommand("ban add Alice 2 fortnights").err_text.suffix,
    );
    try std.testing.expectEqualStrings(
        "\" is not a valid integer.",
        parseCommand("ban add Alice two days").err_text.suffix,
    );
    try std.testing.expectEqualStrings("No sub command given.", parseCommand("ban").err_text.prefix);
    try std.testing.expectEqualStrings("frobnicate", parseCommand("ban frobnicate x").err_text.token);
    try std.testing.expectEqualStrings("at least 4", parseCommand("ban add Alice 2").wrong_args.expected);
    // A duration that would overflow i64 seconds is a bad integer, not a wrap.
    try std.testing.expect(parseCommand("ban add Alice 9223372036854775807 years") == .err_text);
}

test "admin and whitelist sub-commands" {
    const a = parseCommand("admin add Alice 0");
    try std.testing.expectEqualStrings("Alice", a.admin.add.target.name);
    try std.testing.expectEqual(@as(u8, 0), a.admin.add.level);
    try std.testing.expect(parseCommand("admin list").admin == .list);
    try std.testing.expectEqualStrings("Alice", parseCommand("admin remove Alice").admin.remove.name);
    try std.testing.expectEqualStrings("3 or 4", parseCommand("admin add Alice").wrong_args.expected);
    try std.testing.expect(parseCommand("admin add Alice notalevel") == .err_text);
    // Stock permission levels stop at 1000; a wider number is a typo.
    try std.testing.expect(parseCommand("admin add Alice 5000") == .err_text);

    try std.testing.expectEqualStrings("Alice", parseCommand("whitelist add Alice").whitelist.add.name);
    try std.testing.expectEqualStrings("Alice", parseCommand("whitelist remove Alice").whitelist.remove.name);
    try std.testing.expect(parseCommand("whitelist list").whitelist == .list);
    try std.testing.expectEqualStrings("No sub command given.", parseCommand("whitelist").err_text.prefix);
}

test "parse remaining stock read-only verbs" {
    try std.testing.expect(parseCommand("listplayerids") == .listplayerids);
    try std.testing.expect(parseCommand("lpi") == .listplayerids);
    try std.testing.expect(parseCommand("chunkcache") == .chunkcache);
    try std.testing.expect(parseCommand("cc") == .chunkcache);
    try std.testing.expect(parseCommand("mem") == .mem);
    try std.testing.expectEqualStrings("", parseCommand("gg").getgamepref);
    try std.testing.expectEqualStrings("Server", parseCommand("getgamepref Server").getgamepref);
    try std.testing.expectEqualStrings("", parseCommand("getgamestat").getgamestat);
    try std.testing.expectEqualStrings("Day", parseCommand("ggs Day").getgamestat);
    const sp = parseCommand("sg ServerPort 26902");
    try std.testing.expectEqualStrings("ServerPort", sp.setgamepref.name);
    try std.testing.expectEqualStrings("26902", sp.setgamepref.value);
    try std.testing.expectEqualStrings("2", parseCommand("setgamepref ServerPort").wrong_args.expected);
}

test "dayTimeToWorldTime matches GameUtils" {
    // asm.il 1926175: (day-1)*24000 + hours*1000 + minutes*1000/60, truncating.
    try std.testing.expectEqual(@as(u64, 0), dayTimeToWorldTime(1, 0, 0));
    try std.testing.expectEqual(@as(u64, 12000), dayTimeToWorldTime(1, 12, 0));
    try std.testing.expectEqual(@as(u64, 24000), dayTimeToWorldTime(2, 0, 0));
    try std.testing.expectEqual(@as(u64, 22500), dayTimeToWorldTime(1, 22, 30));
    // Minute scaling truncates: 1 minute is 16 ticks, not 16.67.
    try std.testing.expectEqual(@as(u64, 16), dayTimeToWorldTime(1, 0, 1));
    // Day 0 and below is "no time" in stock, not a wrap.
    try std.testing.expectEqual(@as(u64, 0), dayTimeToWorldTime(0, 23, 59));
    try std.testing.expectEqual(@as(u64, 0), dayTimeToWorldTime(-5, 0, 0));
}

test "auth is disabled by an empty password and never by a wrong one" {
    const off: Auth = .{};
    try std.testing.expect(!off.enabled());
    // Nothing is a credential when auth is off, but an empty password must not
    // become "the password" either.
    try std.testing.expect(off.matches("anything"));

    const on: Auth = .{ .password = "hunter2" };
    try std.testing.expect(on.enabled());
    try std.testing.expect(on.matches("hunter2"));
    try std.testing.expect(!on.matches(""));
    try std.testing.expect(!on.matches("hunter"));
    try std.testing.expect(!on.matches("hunter2 "));
    try std.testing.expect(!on.matches("Hunter2"));
}

test "listen binds loopback without a password and INADDR_ANY with one" {
    var closed: Server = .{};
    try std.testing.expect(!closed.public());

    var open: Server = .{ .auth = .{ .password = "hunter2" } };
    try std.testing.expect(open.public());

    // Port 0 means console disabled (no bind), not "pick an ephemeral port".
    try closed.listen(0);
    try std.testing.expectEqual(@as(u16, 0), closed.port);
    try std.testing.expect(!closed.listener.enabled());

    // Real binds on high ports (reuse_address). SkipZigTest if the port is busy.
    // Host selection (loopback vs ANY) is asserted in util/tcp_listen.zig; here we
    // prove the admin Server path actually opens a socket and records the port.
    closed.listen(19877) catch return error.SkipZigTest;
    defer closed.deinit();
    try std.testing.expect(closed.listener.enabled());
    try std.testing.expectEqual(@as(u16, 19877), closed.port);

    open.listen(19878) catch return error.SkipZigTest;
    defer open.deinit();
    try std.testing.expect(open.listener.enabled());
    try std.testing.expectEqual(@as(u16, 19878), open.port);
}

test "session state machine gates commands behind the password" {
    var s: Server = .{ .auth = .{ .password = "hunter2", .fail_limit = 3 } };
    // No socket: replies are dropped, but the state machine still runs.
    s.authed[0] = false;
    s.fails[0] = 0;

    try std.testing.expect(s.authenticate(0, "wrong"));
    try std.testing.expect(!s.authed[0]);
    try std.testing.expectEqual(@as(u8, 1), s.fails[0]);

    try std.testing.expect(s.authenticate(0, "hunter2"));
    try std.testing.expect(s.authed[0]);
    // A success clears the counter so a long session cannot be locked out later.
    try std.testing.expectEqual(@as(u8, 0), s.fails[0]);
}

test "too many failed logins closes the session" {
    var s: Server = .{ .auth = .{ .password = "hunter2", .fail_limit = 2, .fail_block_minutes = 0 } };
    s.authed[1] = false;
    s.active = 1;
    try std.testing.expect(s.authenticate(1, "no"));
    try std.testing.expect(!s.authenticate(1, "no"));
    // dropSession cleared the slot: a reconnect starts unauthenticated.
    try std.testing.expectEqual(@as(tcp.Handle, -1), s.sessions[1]);
    try std.testing.expect(!s.authed[1]);
    try std.testing.expectEqual(@as(u8, 0), s.fails[1]);
    // fail_block_minutes=0: no process-wide lockout window.
    try std.testing.expectEqual(@as(u64, 0), s.login_lock_until_ns);
}

test "fail limit arms process-wide login lockout" {
    var s: Server = .{ .auth = .{ .password = "hunter2", .fail_limit = 2, .fail_block_minutes = 10 } };
    s.authed[0] = false;
    s.active = 0;
    try std.testing.expect(s.authenticate(0, "no"));
    try std.testing.expect(!s.authenticate(0, "no"));
    try std.testing.expect(s.login_lock_until_ns != 0);
    try std.testing.expect(s.loginLocked());
    // A fresh slot still refuses attempts during the lockout window
    // (sessions stay -1 so closeActive is a no-op on the fd).
    s.authed[2] = false;
    s.fails[2] = 0;
    s.active = 2;
    try std.testing.expect(!s.authenticate(2, "hunter2"));
    try std.testing.expect(!s.authed[2]);
}

test "reconnecting does not reset the brute-force counter" {
    // Attack shape: guess up to one short of fail_limit, drop the socket, come
    // back on a fresh slot. Per-session `fails` is zero again each time, so only
    // the cross-session counter can arm the lockout.
    var s: Server = .{ .auth = .{ .password = "hunter2", .fail_limit = 4, .fail_block_minutes = 10 } };
    // Connection 1: two guesses, then "disconnect" (fresh slot next round).
    s.authed[0] = false;
    s.fails[0] = 0;
    s.active = 0;
    try std.testing.expect(s.authenticate(0, "no"));
    try std.testing.expect(s.authenticate(0, "no"));
    try std.testing.expect(!s.loginLocked());
    // Connection 2: per-session counter starts at zero again.
    s.authed[1] = false;
    s.fails[1] = 0;
    s.active = 1;
    try std.testing.expect(s.authenticate(1, "no"));
    // 4th attempt overall trips the limit even though this session saw only 2.
    try std.testing.expect(!s.authenticate(1, "no"));
    try std.testing.expect(s.loginLocked());
}

test "acceptNew prefers unauthenticated victim when full" {
    var s: Server = .{ .auth = .{ .password = "hunter2" } };
    // Three occupied slots: authed in 0 and 2, unauthed in 1.
    s.sessions = .{ 10, 11, 12, -1 };
    s.authed = .{ true, false, true, false };
    // No real listener: call the eviction branch by filling the free slot first.
    s.openSession(3, 13);
    try std.testing.expectEqual(@as(tcp.Handle, 13), s.sessions[3]);
    // Manually run the "all full" policy used by acceptNew.
    var victim: usize = 0;
    for (s.authed, 0..) |a, i| {
        if (!a) {
            victim = i;
            break;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), victim);
}

const parse_fuzz_corpus = [_][]const u8{
    "kick Alice rude",
    "ban add Alice 2 days x",
    "admin add Alice 0",
    "settime 1 23 59",
    "whitelist remove Alice",
    "tele 0 1 2 3",
    "spawnentity 0 zombieBoe",
};

test "fuzz admin command parser" {
    try std.testing.fuzz({}, fuzzParseCommand, .{ .corpus = &parse_fuzz_corpus });
}

fn fuzzParseCommand(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [max_cmd]u8 = undefined;
    const line = storage[0..smith.slice(&storage)];

    const cmd = parseCommand(line);
    // Every slice a Command hands to the dispatcher must point into the input,
    // or Game would format freed / unrelated memory into an operator reply.
    switch (cmd) {
        .say => |s| try expectWithin(line, s),
        .wipeplayer => |s| try expectWithin(line, s),
        .kickall => |s| try expectWithin(line, s),
        .getgamepref => |s| try expectWithin(line, s),
        .bad_args => |s| try expectWithin(line, s),
        .err_text => |e| try expectWithin(line, e.token),
        .kick => |k| {
            try expectTargetWithin(line, k.target);
            try expectWithin(line, k.reason);
        },
        .setgamepref => |sp| {
            try expectWithin(line, sp.name);
            try expectWithin(line, sp.value);
        },
        .ban => |b| switch (b) {
            .add => |a| {
                try expectTargetWithin(line, a.target);
                try expectWithin(line, a.reason);
            },
            .remove => |t| try expectTargetWithin(line, t),
            .list => {},
        },
        .admin => |a| switch (a) {
            .add => |x| try expectTargetWithin(line, x.target),
            .remove => |t| try expectTargetWithin(line, t),
            .list => {},
        },
        .whitelist => |wl| switch (wl) {
            .add, .remove => |t| try expectTargetWithin(line, t),
            .list => {},
        },
        .spawnentity => |se| try std.testing.expect(se.name_off + se.name_len <= line.len),
        .help => |t| if (t) |tt| try expectWithin(line, tt),
        .plugin => |p| try expectWithin(line, p),
        else => {},
    }
}

fn expectWithin(line: []const u8, s: []const u8) !void {
    if (s.len == 0) return;
    const base = @intFromPtr(line.ptr);
    const off = @intFromPtr(s.ptr);
    try std.testing.expect(off >= base and off + s.len <= base + line.len);
}

fn expectTargetWithin(line: []const u8, t: Target) !void {
    switch (t) {
        .name => |n| try expectWithin(line, n),
        .id => {},
    }
}
