//! Stock telnet console output shapes and the persistent operator lists.
//!
//! Every formatter here takes plain data, never `*Game`, so the exact bytes an
//! operator tool parses can be asserted against the decompiled client IL without
//! building a world. Literals are cited to /home/maci/.cache/zdtd-scratch/asm.il
//! (V3.1.0 b14); do not "tidy" a string without re-reading the IL.

const std = @import("std");

/// Extensions::ToCultureInvariantString(Vector3) (asm.il 2089550): "(x, y, z)"
/// with each component in invariant "F1" (exactly one fraction digit).
pub fn writeVec3(w: *std.Io.Writer, x: f32, y: f32, z: f32) !void {
    try w.print("({d:.1}, {d:.1}, {d:.1})", .{ x, y, z });
}

/// One row of stock `listplayers` (ConsoleCmdListPlayers::Execute, asm.il 231241).
/// Fields zdtd does not track are printed with the same placeholder stock uses
/// for an unresolved platform id ("<unknown>"), never invented.
pub const PlayerRow = struct {
    entity_id: i32,
    name: []const u8,
    x: f32,
    y: f32,
    z: f32,
    rot_x: f32 = 0,
    rot_y: f32 = 0,
    rot_z: f32 = 0,
    remote: bool = true,
    health: i32 = 100,
    deaths: u32 = 0,
    zombie_kills: u32 = 0,
    player_kills: u32 = 0,
    score: i32 = 0,
    level: u32 = 1,
    platform_id: []const u8 = "<unknown>",
    cross_id: []const u8 = "<unknown>",
    ip: []const u8 = "<unknown>",
    ping: u32 = 0,
};

pub fn writePlayerRow(w: *std.Io.Writer, index: usize, r: PlayerRow) !void {
    try w.print("{d}. id={d}, {s}, pos=", .{ index, r.entity_id, r.name });
    try writeVec3(w, r.x, r.y, r.z);
    try w.writeAll(", rot=");
    try writeVec3(w, r.rot_x, r.rot_y, r.rot_z);
    try w.print(", remote={s}, health={d}, deaths={d}, zombies={d}, players={d}", .{
        boolWord(r.remote), r.health, r.deaths, r.zombie_kills, r.player_kills,
    });
    try w.print(", score={d}, level={d}, pltfmid={s}, crossid={s}, ip={s}, ping={d}\n", .{
        r.score, r.level, r.platform_id, r.cross_id, r.ip, r.ping,
    });
}

/// ConsoleCmdListPlayerIds (asm.il 231089): literally "{0}. id={1}, {2}".
pub fn writePlayerIdRow(w: *std.Io.Writer, index: usize, entity_id: i32, name: []const u8) !void {
    try w.print("{d}. id={d}, {s}\n", .{ index, entity_id, name });
}

/// One row of stock `listents` (ConsoleCmdListEntities, asm.il 230715).
pub const EntityRow = struct {
    entity_id: i32,
    name: []const u8,
    x: f32,
    y: f32,
    z: f32,
    rot_x: f32 = 0,
    rot_y: f32 = 0,
    rot_z: f32 = 0,
    /// Seconds until despawn; stock prints "float.Max" for entities that never do.
    lifetime: ?f32 = null,
    remote: bool = false,
    dead: bool = false,
    /// Absent for entities with no health component (stock omits the field).
    health: ?i32 = null,
};

pub fn writeEntityRow(w: *std.Io.Writer, index: usize, r: EntityRow) !void {
    try w.print("{d}. id={d}, {s}, pos=", .{ index, r.entity_id, r.name });
    try writeVec3(w, r.x, r.y, r.z);
    try w.writeAll(", rot=");
    try writeVec3(w, r.rot_x, r.rot_y, r.rot_z);
    try w.writeAll(", lifetime=");
    if (r.lifetime) |lt| try w.print("{d:.1}", .{lt}) else try w.writeAll("float.Max");
    try w.print(", remote={s}, dead={s}", .{ boolWord(r.remote), boolWord(r.dead) });
    if (r.health) |hp| try w.print(", health={d}", .{hp});
    try w.writeAll("\n");
}

/// Both list commands close with StringBuilder.Append(bool), which is .NET
/// "True"/"False", and the shared "Total of N in the game" trailer.
pub fn writeTotal(w: *std.Io.Writer, n: usize) !void {
    try w.print("Total of {d} in the game\n", .{n});
}

fn boolWord(b: bool) []const u8 {
    return if (b) "True" else "False";
}

/// ConsoleCmdGetGamePrefs (asm.il 220877): "GamePref.{0} = {1}".
pub fn writeGamePref(w: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try w.print("GamePref.{s} = {s}\n", .{ name, value });
}

/// ConsoleCmdChunkCache (asm.il 213107) tail: the two lines operator tools read.
pub fn writeChunkCache(w: *std.Io.Writer, chunks: usize, bytes: u64) !void {
    try w.print("Chunks: {d}\n", .{chunks});
    try w.print("Chunk Memory: {d}MB\n", .{bytes / (1024 * 1024)});
}

/// ConsoleCmdMem (asm.il 235864): one line, fixed separators.
pub const MemStats = struct {
    minutes: u64,
    fps: u32,
    heap_mb: u64,
    max_mb: u64,
    chunks: usize,
    chunk_game_objects: usize,
    players: usize,
    zombies: usize,
    entities: usize,
    entities_of_type: usize,
    items: usize,
    collision_objects: usize,
    rss_mb: u64,
};

pub fn writeMem(w: *std.Io.Writer, m: MemStats) !void {
    try w.print(
        "Time: {d}m FPS: {d} Heap: {d}MB Max: {d}MB Chunks: {d} CGO: {d} Ply: {d} Zom: {d} Ent: {d} ({d}) Items: {d} CO: {d} RSS: {d}MB\n",
        .{
            m.minutes,            m.fps,               m.heap_mb, m.max_mb,   m.chunks,
            m.chunk_game_objects, m.players,           m.zombies, m.entities, m.entities_of_type,
            m.items,              m.collision_objects, m.rss_mb,
        },
    );
}

/// SdtdConsole::executeCommand (asm.il 269448).
pub fn writeUnknownCommand(w: *std.Io.Writer, verb: []const u8) !void {
    try w.print("*** ERROR: unknown command '{s}'\n", .{verb});
}

pub const HelpEntry = struct {
    /// Comma-joined command names exactly as stock lists them ("listplayers, lp").
    names: []const u8,
    description: []const u8,
};

/// ConsoleCmdHelp with no arguments (asm.il 226623): the generic block then the
/// command index. Column padding is stock's (names padded to the widest name).
pub fn writeHelp(w: *std.Io.Writer, entries: []const HelpEntry) !void {
    try w.writeAll("*** Generic Console Help ***\n");
    try w.writeAll("To get further help on a specific topic or command type (without the quotes):\n");
    try w.writeAll("    help <topic / command>\n");
    try w.writeAll("\n");
    try w.writeAll("Generic notation of command parameters:\n");
    try w.writeAll("   <param name>              Required parameter\n");
    try w.writeAll("   <entityId / player name>  Possible types of parameter values\n");
    try w.writeAll("   [param name]              Optional parameter\n");
    try w.writeAll("\n");
    try w.writeAll("*** List of Commands ***\n");
    var width: usize = 0;
    for (entries) |e| width = @max(width, e.names.len);
    for (entries) |e| {
        try w.writeAll(e.names);
        for (e.names.len..width) |_| try w.writeAll(" ");
        try w.print(" => {s}\n", .{e.description});
    }
}

// ---------------------------------------------------------------------------
// Persistent operator lists
// ---------------------------------------------------------------------------

pub const max_entries: usize = 64;
pub const max_id: usize = 64;
pub const max_reason: usize = 96;

/// A bounded, owned string. Keeps the lists allocation-free and makes an
/// over-long operator argument a truncation, never a heap failure mid-command.
fn Bounded(comptime cap: usize) type {
    return struct {
        buf: [cap]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn set(self: *Self, s: []const u8) void {
            self.len = @min(s.len, cap);
            @memcpy(self.buf[0..self.len], s[0..self.len]);
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

pub const BanEntry = struct {
    id: Bounded(max_id) = .{},
    reason: Bounded(max_reason) = .{},
    /// Absolute wall-clock expiry so a restart neither resurrects an expired ban
    /// nor silently extends a live one.
    expires_unix: i64 = 0,
};

pub const BanList = struct {
    entries: [max_entries]BanEntry = @splat(.{}),
    n: usize = 0,

    /// Adds or replaces the entry for `id`. False when the list is full.
    pub fn add(self: *BanList, id: []const u8, expires_unix: i64, reason: []const u8) bool {
        if (self.find(id)) |i| {
            self.entries[i].expires_unix = expires_unix;
            self.entries[i].reason.set(reason);
            return true;
        }
        if (self.n == max_entries) return false;
        var e: BanEntry = .{ .expires_unix = expires_unix };
        e.id.set(id);
        e.reason.set(reason);
        self.entries[self.n] = e;
        self.n += 1;
        return true;
    }

    pub fn find(self: *const BanList, id: []const u8) ?usize {
        for (self.entries[0..self.n], 0..) |*e, i| {
            if (std.ascii.eqlIgnoreCase(e.id.slice(), id)) return i;
        }
        return null;
    }

    pub fn remove(self: *BanList, id: []const u8) bool {
        const i = self.find(id) orelse return false;
        self.entries[i] = self.entries[self.n - 1];
        self.n -= 1;
        return true;
    }

    /// True when `id` is banned at `now`. Expired entries are dropped in place so
    /// the list cannot grow stale under a long uptime.
    pub fn banned(self: *BanList, id: []const u8, now: i64) bool {
        self.expire(now);
        return self.find(id) != null;
    }

    pub fn expire(self: *BanList, now: i64) void {
        var i: usize = 0;
        while (i < self.n) {
            if (self.entries[i].expires_unix <= now) {
                self.entries[i] = self.entries[self.n - 1];
                self.n -= 1;
            } else i += 1;
        }
    }
};

/// ConsoleCmdBan list sub-command (asm.il 210188+).
pub fn writeBanList(w: *std.Io.Writer, list: *const BanList) !void {
    try w.writeAll("Ban list entries:\n");
    // Timestamps are UTC (formatUnix applies no zone offset); say so in the
    // header, since an operator reading a bare stamp assumes local time.
    try w.writeAll("  Banned until (UTC) - UserID (name) - Reason\n");
    for (list.entries[0..list.n]) |*e| {
        var tb: [24]u8 = undefined;
        try w.print("  {s} - {s} ({s}) - {s}\n", .{
            formatUnix(&tb, e.expires_unix),
            e.id.slice(),
            e.id.slice(),
            if (e.reason.len == 0) "-unknown-" else e.reason.slice(),
        });
    }
}

pub const PermissionEntry = struct {
    id: Bounded(max_id) = .{},
    level: u8 = 0,
};

pub const PermissionList = struct {
    entries: [max_entries]PermissionEntry = @splat(.{}),
    n: usize = 0,

    pub fn add(self: *PermissionList, id: []const u8, level: u8) bool {
        if (self.find(id)) |i| {
            self.entries[i].level = level;
            return true;
        }
        if (self.n == max_entries) return false;
        var e: PermissionEntry = .{ .level = level };
        e.id.set(id);
        self.entries[self.n] = e;
        self.n += 1;
        return true;
    }

    pub fn find(self: *const PermissionList, id: []const u8) ?usize {
        for (self.entries[0..self.n], 0..) |*e, i| {
            if (std.ascii.eqlIgnoreCase(e.id.slice(), id)) return i;
        }
        return null;
    }

    pub fn remove(self: *PermissionList, id: []const u8) bool {
        const i = self.find(id) orelse return false;
        self.entries[i] = self.entries[self.n - 1];
        self.n -= 1;
        return true;
    }
};

/// ConsoleCmdAdmin list sub-command (asm.il 205169+). zdtd stores no separate
/// online/stored name, so both columns carry the one identity it has.
pub fn writeAdminList(w: *std.Io.Writer, list: *const PermissionList) !void {
    try w.writeAll("Defined User Permissions:\n");
    try w.writeAll("  Level: UserID (Player name if online, stored name)\n");
    for (list.entries[0..list.n]) |*e| {
        try w.print("  {d: >5}: {s} (stored name: {s})\n", .{ e.level, e.id.slice(), e.id.slice() });
    }
}

/// ConsoleCmdWhitelist list sub-command (asm.il 265988+). Whitelist entries carry
/// no level, so the shared PermissionList is used with level ignored.
pub fn writeWhitelist(w: *std.Io.Writer, list: *const PermissionList) !void {
    if (list.n == 0) {
        try w.writeAll("No users or groups on whitelist, whitelist only mode disabled\n");
        return;
    }
    try w.writeAll("Whitelisted users:\n");
    for (list.entries[0..list.n]) |*e| {
        try w.print("  {s} (stored name: {s})\n", .{ e.id.slice(), e.id.slice() });
    }
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

/// Line format: `<expires_unix>\t<id>\t<reason>` for bans and `<level>\t<id>` for
/// permission lists. Tabs are stripped from operator input on write, so a line
/// always has the field count it claims.
pub const LoadResult = struct {
    loaded: usize = 0,
    /// Lines that did not parse. They are never applied: a corrupt permissions
    /// file must not grant anything, and the operator gets a warning instead.
    skipped: usize = 0,
};

pub fn serializeBans(w: *std.Io.Writer, list: *const BanList) !void {
    for (list.entries[0..list.n]) |*e| {
        try w.print("{d}\t{s}\t{s}\n", .{ e.expires_unix, e.id.slice(), sanitize(e.reason.slice()) });
    }
}

pub fn deserializeBans(list: *BanList, text: []const u8, now: i64) LoadResult {
    var res: LoadResult = .{};
    list.* = .{};
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |line| {
        var f = std.mem.splitScalar(u8, line, '\t');
        const exp_s = f.next() orelse {
            res.skipped += 1;
            continue;
        };
        const id = f.next() orelse {
            res.skipped += 1;
            continue;
        };
        const reason = f.next() orelse "";
        const exp = std.fmt.parseInt(i64, exp_s, 10) catch {
            res.skipped += 1;
            continue;
        };
        if (id.len == 0) {
            res.skipped += 1;
            continue;
        }
        // Expired on disk stays expired: reloading must not resurrect a ban.
        if (exp <= now) continue;
        if (!list.add(id, exp, reason)) {
            res.skipped += 1;
            continue;
        }
        res.loaded += 1;
    }
    return res;
}

pub fn serializePermissions(w: *std.Io.Writer, list: *const PermissionList) !void {
    for (list.entries[0..list.n]) |*e| {
        try w.print("{d}\t{s}\n", .{ e.level, e.id.slice() });
    }
}

pub fn deserializePermissions(list: *PermissionList, text: []const u8) LoadResult {
    var res: LoadResult = .{};
    list.* = .{};
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |line| {
        var f = std.mem.splitScalar(u8, line, '\t');
        const lvl_s = f.next() orelse {
            res.skipped += 1;
            continue;
        };
        const id = f.next() orelse {
            res.skipped += 1;
            continue;
        };
        const level = std.fmt.parseInt(u8, lvl_s, 10) catch {
            res.skipped += 1;
            continue;
        };
        if (id.len == 0 or !list.add(id, level)) {
            res.skipped += 1;
            continue;
        }
        res.loaded += 1;
    }
    return res;
}

/// Field separators must never survive into a stored value or the next load
/// would read a different number of fields than were written.
fn sanitize(s: []const u8) []const u8 {
    if (std.mem.findAny(u8, s, "\t\r\n") == null) return s;
    return "-unknown-";
}

/// `YYYY-MM-DD HH:MM:SS` from a Unix timestamp (days-from-civil, proleptic
/// Gregorian). Stock prints a locale DateTime; a fixed sortable form is the one
/// choice that stays parseable for tooling.
pub fn formatUnix(buf: *[24]u8, secs: i64) []const u8 {
    const days = @divFloor(secs, 86400);
    const rem = secs - days * 86400;
    const hh: u64 = @intCast(@divFloor(rem, 3600));
    const mi: u64 = @intCast(@divFloor(@mod(rem, 3600), 60));
    const ss: u64 = @intCast(@mod(rem, 60));

    var z = days + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9));
    z = y + @intFromBool(m <= 2);
    // Format unsigned: {d} on a signed type prints a leading '+' for positives.
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(@max(0, z))),
        @as(u64, @intCast(m)),
        @as(u64, @intCast(d)),
        hh,
        mi,
        ss,
    }) catch "0000-00-00 00:00:00";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn render(buf: []u8, comptime f: anytype, args: anytype) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try @call(.auto, f, .{&w} ++ args);
    return w.buffered();
}

test "writeVec3 matches Unity F1 invariant formatting" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("(1.0, -2.5, 70.2)", try render(&buf, writeVec3, .{ 1.0, -2.5, 70.24 }));
    try std.testing.expectEqualStrings("(0.0, 0.0, 0.0)", try render(&buf, writeVec3, .{ 0.0, 0.0, 0.0 }));
}

test "listplayers row keeps stock field order" {
    var buf: [512]u8 = undefined;
    const row: PlayerRow = .{ .entity_id = 171, .name = "Alice", .x = 10, .y = 70, .z = -5 };
    try std.testing.expectEqualStrings(
        "0. id=171, Alice, pos=(10.0, 70.0, -5.0), rot=(0.0, 0.0, 0.0), remote=True, health=100, " ++
            "deaths=0, zombies=0, players=0, score=0, level=1, pltfmid=<unknown>, crossid=<unknown>, " ++
            "ip=<unknown>, ping=0\n",
        try render(&buf, writePlayerRow, .{ @as(usize, 0), row }),
    );
}

test "listplayerids and totals match stock literals" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "3. id=171, Alice\n",
        try render(&buf, writePlayerIdRow, .{ @as(usize, 3), @as(i32, 171), "Alice" }),
    );
    try std.testing.expectEqualStrings("Total of 0 in the game\n", try render(&buf, writeTotal, .{@as(usize, 0)}));
    try std.testing.expectEqualStrings("Total of 7 in the game\n", try render(&buf, writeTotal, .{@as(usize, 7)}));
}

test "listents row prints float.Max lifetime and omits absent health" {
    var buf: [512]u8 = undefined;
    const alive: EntityRow = .{ .entity_id = 9, .name = "zombieBoe", .x = 1, .y = 2, .z = 3, .health = 100 };
    try std.testing.expectEqualStrings(
        "0. id=9, zombieBoe, pos=(1.0, 2.0, 3.0), rot=(0.0, 0.0, 0.0), lifetime=float.Max, " ++
            "remote=False, dead=False, health=100\n",
        try render(&buf, writeEntityRow, .{ @as(usize, 0), alive }),
    );
    const bag: EntityRow = .{ .entity_id = 12, .name = "lootbag", .x = 0, .y = 0, .z = 0, .lifetime = 30 };
    try std.testing.expectEqualStrings(
        "1. id=12, lootbag, pos=(0.0, 0.0, 0.0), rot=(0.0, 0.0, 0.0), lifetime=30.0, " ++
            "remote=False, dead=False\n",
        try render(&buf, writeEntityRow, .{ @as(usize, 1), bag }),
    );
}

test "unknown command and gamepref match stock literals" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "*** ERROR: unknown command 'frobnicate'\n",
        try render(&buf, writeUnknownCommand, .{"frobnicate"}),
    );
    try std.testing.expectEqualStrings(
        "GamePref.ServerPort = 26902\n",
        try render(&buf, writeGamePref, .{ "ServerPort", "26902" }),
    );
}

test "chunkcache and mem lines match stock separators" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Chunks: 12\nChunk Memory: 3MB\n",
        try render(&buf, writeChunkCache, .{ @as(usize, 12), @as(u64, 3 * 1024 * 1024 + 5) }),
    );
    const m: MemStats = .{
        .minutes = 4,
        .fps = 20,
        .heap_mb = 6,
        .max_mb = 8,
        .chunks = 12,
        .chunk_game_objects = 0,
        .players = 1,
        .zombies = 2,
        .entities = 5,
        .entities_of_type = 5,
        .items = 3,
        .collision_objects = 0,
        .rss_mb = 90,
    };
    try std.testing.expectEqualStrings(
        "Time: 4m FPS: 20 Heap: 6MB Max: 8MB Chunks: 12 CGO: 0 Ply: 1 Zom: 2 Ent: 5 (5) Items: 3 CO: 0 RSS: 90MB\n",
        try render(&buf, writeMem, .{m}),
    );
}

test "help index uses the stock headers and arrow separator" {
    var buf: [1024]u8 = undefined;
    const entries = [_]HelpEntry{
        .{ .names = "listplayers, lp", .description = "lists all players" },
        .{ .names = "mem", .description = "Prints memory information" },
    };
    const out = try render(&buf, writeHelp, .{@as([]const HelpEntry, &entries)});
    try std.testing.expect(std.mem.startsWith(u8, out, "*** Generic Console Help ***\n"));
    try std.testing.expect(std.mem.find(u8, out, "\n*** List of Commands ***\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "listplayers, lp => lists all players\n") != null);
    // Names are padded to the widest entry so the arrows line up.
    try std.testing.expect(std.mem.find(u8, out, "mem             => Prints memory information\n") != null);
}

test "ban list add, replace, remove and expiry" {
    var l: BanList = .{};
    try std.testing.expect(l.add("Alice", 1000, "griefing"));
    try std.testing.expect(l.add("Bob", 2000, ""));
    try std.testing.expectEqual(@as(usize, 2), l.n);
    // Same id replaces rather than duplicating.
    try std.testing.expect(l.add("alice", 3000, "still griefing"));
    try std.testing.expectEqual(@as(usize, 2), l.n);
    try std.testing.expectEqual(@as(i64, 3000), l.entries[l.find("Alice").?].expires_unix);

    try std.testing.expect(l.banned("Bob", 1999));
    try std.testing.expect(!l.banned("Bob", 2000));
    try std.testing.expectEqual(@as(usize, 1), l.n);
    try std.testing.expect(l.remove("Alice"));
    try std.testing.expect(!l.remove("Alice"));
    try std.testing.expectEqual(@as(usize, 0), l.n);
}

test "ban list is bounded and refuses to overflow" {
    var l: BanList = .{};
    var i: usize = 0;
    while (i < max_entries) : (i += 1) {
        var nb: [8]u8 = undefined;
        try std.testing.expect(l.add(try std.fmt.bufPrint(&nb, "u{d}", .{i}), 10_000, ""));
    }
    try std.testing.expect(!l.add("overflow", 10_000, ""));
    try std.testing.expectEqual(max_entries, l.n);
}

test "ban list output matches stock header block" {
    var l: BanList = .{};
    _ = l.add("Alice", 1700000000, "griefing");
    _ = l.add("Bob", 1700000000, "");
    var buf: [512]u8 = undefined;
    const out = try render(&buf, writeBanList, .{&l});
    try std.testing.expect(std.mem.startsWith(u8, out, "Ban list entries:\n  Banned until (UTC) - UserID (name) - Reason\n"));
    try std.testing.expect(std.mem.find(u8, out, "2023-11-14 22:13:20 - Alice (Alice) - griefing\n") != null);
    // Stock prints "-unknown-" where a field is missing, never an empty column.
    try std.testing.expect(std.mem.find(u8, out, "- Bob (Bob) - -unknown-\n") != null);
}

test "admin and whitelist listings match stock headers" {
    var l: PermissionList = .{};
    _ = l.add("Alice", 0);
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Defined User Permissions:\n  Level: UserID (Player name if online, stored name)\n" ++
            "      0: Alice (stored name: Alice)\n",
        try render(&buf, writeAdminList, .{&l}),
    );
    var empty: PermissionList = .{};
    try std.testing.expectEqualStrings(
        "No users or groups on whitelist, whitelist only mode disabled\n",
        try render(&buf, writeWhitelist, .{&empty}),
    );
    try std.testing.expectEqualStrings(
        "Whitelisted users:\n  Alice (stored name: Alice)\n",
        try render(&buf, writeWhitelist, .{&l}),
    );
}

test "ban persistence round-trips and drops expired entries on load" {
    var l: BanList = .{};
    _ = l.add("Alice", 5000, "griefing");
    _ = l.add("Bob", 1000, "spam");
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try serializeBans(&w, &l);
    const text = w.buffered();

    var back: BanList = .{};
    const res = deserializeBans(&back, text, 2000);
    try std.testing.expectEqual(@as(usize, 1), res.loaded);
    try std.testing.expectEqual(@as(usize, 0), res.skipped);
    // Bob expired at 1000 and must not come back; Alice must survive intact.
    try std.testing.expect(back.find("Bob") == null);
    const a = back.find("Alice").?;
    try std.testing.expectEqual(@as(i64, 5000), back.entries[a].expires_unix);
    try std.testing.expectEqualStrings("griefing", back.entries[a].reason.slice());
}

test "corrupt list files grant nothing" {
    var l: PermissionList = .{};
    const res = deserializePermissions(&l, "notanumber\tAlice\n0\n\t\n0\tBob\n");
    try std.testing.expectEqual(@as(usize, 1), res.loaded);
    try std.testing.expectEqual(@as(usize, 3), res.skipped);
    try std.testing.expect(l.find("Alice") == null);
    try std.testing.expect(l.find("Bob") != null);

    var b: BanList = .{};
    const bres = deserializeBans(&b, "garbage\n\t\nx\tAlice\ty\n", 0);
    try std.testing.expectEqual(@as(usize, 0), bres.loaded);
    try std.testing.expectEqual(@as(usize, 3), bres.skipped);
    try std.testing.expectEqual(@as(usize, 0), b.n);
}

test "truncated ban file never resurrects a partial entry" {
    var b: BanList = .{};
    // A write cut mid-line leaves an id with no reason field, which is legal, and
    // a bare timestamp with no id, which is not.
    const res = deserializeBans(&b, "5000\tAlice\n5000\n", 0);
    try std.testing.expectEqual(@as(usize, 1), res.loaded);
    try std.testing.expectEqual(@as(usize, 1), res.skipped);
    try std.testing.expectEqual(@as(usize, 0), b.entries[b.find("Alice").?].reason.len);
}

test "reason separators cannot corrupt the stored line" {
    var l: BanList = .{};
    _ = l.add("Alice", 5000, "hit\ttab\nnewline");
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try serializeBans(&w, &l);
    try std.testing.expectEqualStrings("5000\tAlice\t-unknown-\n", w.buffered());
}

test "formatUnix covers epoch, a known date and a negative timestamp" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01 00:00:00", formatUnix(&buf, 0));
    try std.testing.expectEqualStrings("2023-11-14 22:13:20", formatUnix(&buf, 1700000000));
    try std.testing.expectEqualStrings("2024-02-29 00:00:00", formatUnix(&buf, 1709164800));
    try std.testing.expectEqualStrings("1969-12-31 23:59:59", formatUnix(&buf, -1));
}

test "bounded strings truncate instead of overflowing" {
    var e: BanEntry = .{};
    e.id.set("x" ** (max_id + 32));
    try std.testing.expectEqual(max_id, e.id.len);
    e.reason.set("");
    try std.testing.expectEqual(@as(usize, 0), e.reason.len);
}

const list_fuzz_corpus = [_][]const u8{
    "5000\tAlice\tgriefing\n",
    "0\tAlice\n",
    "\t\t\n",
    "-1\t\t",
    "9223372036854775807\tAlice\t",
};

test "fuzz list deserializers against arbitrary bytes" {
    try std.testing.fuzz({}, fuzzListDeserializers, .{ .corpus = &list_fuzz_corpus });
}

fn fuzzListDeserializers(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [4096]u8 = undefined;
    const input = storage[0..smith.slice(&storage)];

    var b: BanList = .{};
    _ = deserializeBans(&b, input, 0);
    try std.testing.expect(b.n <= max_entries);
    var p: PermissionList = .{};
    _ = deserializePermissions(&p, input);
    try std.testing.expect(p.n <= max_entries);

    // Whatever loaded must round-trip through the writer without overflowing the
    // buffer a save uses, and must not carry a field separator into a value.
    var buf: [16 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try serializeBans(&w, &b);
    try std.testing.expect(std.mem.count(u8, w.buffered(), "\n") == b.n);
    var w2: std.Io.Writer = .fixed(&buf);
    try serializePermissions(&w2, &p);
    try std.testing.expect(std.mem.count(u8, w2.buffered(), "\n") == p.n);
}
