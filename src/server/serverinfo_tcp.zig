//! Stock ServerInformationTcpProvider: TCP on ServerPort serves GameServerInfo text.
//!
//! Client path (NetworkClientLiteNetLib.Connect):
//!   IP = GameInfoString IP, UDP = GameInfoInt Port + 2.
//! So `Port` in this text must be ServerPort (info TCP), not the LiteNet bind port.

const std = @import("std");
const version = @import("../version.zig");
const tcp = @import("../util/tcp_listen.zig");

pub const ServerInfo = struct {
    /// Advertised display / world names.
    game_name: []const u8 = "zdtd",
    game_host: []const u8 = "zdtd",
    level_name: []const u8 = "Navezgane",
    ip: []const u8 = "127.0.0.1",
    /// TCP ServerPort (GameInfoInt Port). Client dials LiteNet at Port+2.
    info_port: u16 = 27015,
    max_players: i32 = 8,
    current_players: i32 = 0,
    server_version: []const u8 = version.stock_wire_announce,
    world_size: i32 = 6144,
    eac_enabled: bool = false,
    /// Stock IsPasswordProtected (ServerPassword set).
    password_protected: bool = false,
};

/// Strip CR/LF/`;` so operator-supplied names cannot inject extra GSI key lines.
fn gsiSafe(s: []const u8, scratch: []u8) []const u8 {
    const n = @min(s.len, scratch.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = s[i];
        scratch[i] = switch (c) {
            '\r', '\n', ';' => '_',
            else => c,
        };
    }
    return scratch[0..n];
}

/// Build GameServerInfo.ToString(true): `Key:Value;\r\n` … trailing `\r\n`.
/// Includes the keys stock NetworkClientLiteNetLib / connect dialog use.
pub fn buildInfoText(buf: []u8, info: ServerInfo) ![]const u8 {
    const max_players = @max(0, info.max_players);
    const current_players = @max(0, @min(info.current_players, max_players));
    var gn: [64]u8 = undefined;
    var gh: [64]u8 = undefined;
    var ln: [64]u8 = undefined;
    var ipb: [64]u8 = undefined;
    var ver: [32]u8 = undefined;
    return std.fmt.bufPrint(
        buf,
        "GameType:7DTD;\r\nGameName:{s};\r\nGameMode:Survival;\r\nGameHost:{s};\r\nLevelName:{s};\r\nIP:{s};\r\nServerVersion:{s};\r\nPort:{d};\r\nCurrentPlayers:{d};\r\nMaxPlayers:{d};\r\nFreePlayerSlots:{d};\r\nWorldSize:{d};\r\nIsDedicated:True;\r\nIsPasswordProtected:{s};\r\nEACEnabled:{s};\r\nAllowCrossplay:False;\r\nArchitecture64:True;\r\nIsPublic:True;\r\n\r\n",
        .{
            gsiSafe(info.game_name, &gn),
            gsiSafe(info.game_host, &gh),
            gsiSafe(info.level_name, &ln),
            gsiSafe(info.ip, &ipb),
            gsiSafe(info.server_version, &ver),
            info.info_port,
            current_players,
            max_players,
            max_players - current_players,
            info.world_size,
            if (info.password_protected) "True" else "False",
            if (info.eac_enabled) "True" else "False",
        },
    );
}

/// 5 ASCII digits + CRLF length prefix (stock AcceptTcpClient framing).
fn lengthHeader(n: usize) [7]u8 {
    return .{
        @intCast('0' + (n / 10000) % 10),
        @intCast('0' + (n / 1000) % 10),
        @intCast('0' + (n / 100) % 10),
        @intCast('0' + (n / 10) % 10),
        @intCast('0' + n % 10),
        '\r',
        '\n',
    };
}

/// Format length as 5 ASCII digits + CRLF + body (stock AcceptTcpClient).
pub fn writeResponse(stream_write: *const fn (ctx: ?*anyopaque, data: []const u8) anyerror!void, ctx: ?*anyopaque, body: []const u8) !void {
    if (body.len > 99999) return error.Overflow;
    const hdr = lengthHeader(body.len);
    try stream_write(ctx, hdr[0..]);
    try stream_write(ctx, body);
}

pub const Provider = struct {
    listener: tcp.Listener = .{},
    info: ServerInfo = .{},
    text_buf: [4096]u8 = undefined,
    text_len: usize = 0,

    pub fn start(self: *Provider, info: ServerInfo) !void {
        self.info = info;
        try self.rebuildText();
        // INADDR_ANY: stock GSI is reachable on all interfaces.
        try self.listener.listen(0, info.info_port, 8);
    }

    pub fn stop(self: *Provider) void {
        self.listener.deinit();
    }

    pub fn setPlayers(self: *Provider, current: i32) void {
        self.info.current_players = @max(0, @min(current, @max(0, self.info.max_players)));
        self.rebuildText() catch |err|
            std.debug.print("zdtd: serverinfo rebuild failed: {s}; serving stale info\n", .{@errorName(err)});
    }

    fn rebuildText(self: *Provider) !void {
        const t = try buildInfoText(&self.text_buf, self.info);
        self.text_len = t.len;
    }

    /// Non-blocking: accept one client and write info response.
    pub fn poll(self: *Provider) void {
        if (!self.listener.enabled()) return;
        const client = self.listener.accept() catch return orelse return;
        defer tcp.closeFd(client);

        const hdr = lengthHeader(self.text_len);
        tcp.writeAll(client, hdr[0..]);
        if (self.text_len > 0) {
            tcp.writeAll(client, self.text_buf[0..self.text_len]);
        }
    }
};

test "info text has Port and CRLF records" {
    var buf: [1024]u8 = undefined;
    const t = try buildInfoText(&buf, .{
        .game_name = "zdtd",
        .level_name = "Navezgane",
        .ip = "127.0.0.1",
        .info_port = 27015,
    });
    // Port is ServerPort; client connects LiteNet to Port+2.
    try std.testing.expect(std.mem.indexOf(u8, t, "Port:27015;") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "GameName:zdtd;") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "EACEnabled:False;") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "AllowCrossplay:False;") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "IsDedicated:True;") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "IsPasswordProtected:False;") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, t, "\r\n\r\n"));
}

test "info text advertises password and sanitizes GSI fields" {
    var buf: [1024]u8 = undefined;
    const pw = try buildInfoText(&buf, .{ .password_protected = true });
    try std.testing.expect(std.mem.indexOf(u8, pw, "IsPasswordProtected:True;") != null);

    const inj = try buildInfoText(&buf, .{ .level_name = "evil;\r\nInjected:1", .info_port = 27015 });
    // CR/LF/; must not create a new GSI key line; still one Port: record (info_port).
    try std.testing.expect(std.mem.indexOf(u8, inj, "\r\nInjected:") == null);
    try std.testing.expect(std.mem.indexOf(u8, inj, "LevelName:evil") != null);
    try std.testing.expect(std.mem.indexOf(u8, inj, "Port:27015;") != null);
}

test "info text clamps player counts" {
    var buf: [1024]u8 = undefined;
    const full = try buildInfoText(&buf, .{ .max_players = 8, .current_players = 12 });
    try std.testing.expect(std.mem.indexOf(u8, full, "CurrentPlayers:8;") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "FreePlayerSlots:0;") != null);

    const empty = try buildInfoText(&buf, .{ .max_players = 8, .current_players = -1 });
    try std.testing.expect(std.mem.indexOf(u8, empty, "CurrentPlayers:0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty, "FreePlayerSlots:8;") != null);
}

test "response header is 5 digit length" {
    var out: [64]u8 = undefined;
    var pos: usize = 0;
    const Ctx = struct {
        buf: []u8,
        pos: *usize,
        fn w(ctx: ?*anyopaque, data: []const u8) !void {
            const c: *@This() = @ptrCast(@alignCast(ctx.?));
            @memcpy(c.buf[c.pos.*..][0..data.len], data);
            c.pos.* += data.len;
        }
    };
    var ctx: Ctx = .{ .buf = &out, .pos = &pos };
    const body = "Port:1;\r\n\r\n";
    try writeResponse(Ctx.w, &ctx, body);
    try std.testing.expectEqual(@as(u8, '0'), out[0]);
    try std.testing.expectEqual(@as(u8, '0'), out[1]);
    try std.testing.expectEqual(@as(u8, '0'), out[2]);
    try std.testing.expectEqual(@as(u8, '1'), out[3]);
    try std.testing.expectEqual(@as(u8, '1'), out[4]); // len 11
    try std.testing.expectEqual(@as(u8, '\r'), out[5]);
}
