//! Stock ServerInformationTcpProvider: TCP on ServerPort serves GameServerInfo text.
//!
//! Client path (NetworkClientLiteNetLib.Connect):
//!   IP = GameInfoString IP, UDP = GameInfoInt Port + 2.
//! So `Port` in this text must be ServerPort (info TCP), not the LiteNet bind port.

const std = @import("std");
const linux = std.os.linux;

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
    server_version: []const u8 = "V 3.1.0",
    world_size: i32 = 6144,
    eac_enabled: bool = false,
};

/// Build GameServerInfo.ToString(true): `Key:Value;\r\n` … trailing `\r\n`.
/// Includes the keys stock NetworkClientLiteNetLib / connect dialog use.
pub fn buildInfoText(buf: []u8, info: ServerInfo) ![]const u8 {
    return std.fmt.bufPrint(buf,
        "GameType:7DTD;\r\nGameName:{s};\r\nGameMode:Survival;\r\nGameHost:{s};\r\nLevelName:{s};\r\nIP:{s};\r\nServerVersion:{s};\r\nPort:{d};\r\nCurrentPlayers:{d};\r\nMaxPlayers:{d};\r\nFreePlayerSlots:{d};\r\nWorldSize:{d};\r\nIsDedicated:True;\r\nIsPasswordProtected:False;\r\nEACEnabled:{s};\r\nAllowCrossplay:False;\r\nArchitecture64:True;\r\nIsPublic:True;\r\n\r\n",
        .{
            info.game_name,
            info.game_host,
            info.level_name,
            info.ip,
            info.server_version,
            info.info_port,
            info.current_players,
            info.max_players,
            info.max_players - info.current_players,
            info.world_size,
            if (info.eac_enabled) "True" else "False",
        },
    );
}

/// Format length as 5 ASCII digits + CRLF + body (stock AcceptTcpClient).
pub fn writeResponse(stream_write: *const fn (ctx: ?*anyopaque, data: []const u8) anyerror!void, ctx: ?*anyopaque, body: []const u8) !void {
    if (body.len > 99999) return error.Overflow;
    var hdr: [7]u8 = undefined;
    const n = body.len;
    hdr[0] = @intCast('0' + (n / 10000) % 10);
    hdr[1] = @intCast('0' + (n / 1000) % 10);
    hdr[2] = @intCast('0' + (n / 100) % 10);
    hdr[3] = @intCast('0' + (n / 10) % 10);
    hdr[4] = @intCast('0' + (n / 1) % 10);
    hdr[5] = '\r';
    hdr[6] = '\n';
    try stream_write(ctx, hdr[0..]);
    try stream_write(ctx, body);
}

pub const Provider = struct {
    listen_fd: i32 = -1,
    info: ServerInfo = .{},
    text_buf: [4096]u8 = undefined,
    text_len: usize = 0,

    pub fn start(self: *Provider, info: ServerInfo) !void {
        self.info = info;
        try self.rebuildText();

        const sock_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(sock_rc) != .SUCCESS) return error.SocketFailed;
        const fd: i32 = @intCast(sock_rc);
        errdefer _ = linux.close(fd);

        var yes: c_int = 1;
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&yes), @sizeOf(c_int));

        var addr = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, info.info_port),
            .addr = 0, // INADDR_ANY
        };
        const br = linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
        if (linux.errno(br) != .SUCCESS) return error.BindFailed;
        const lc = linux.listen(fd, 8);
        if (linux.errno(lc) != .SUCCESS) return error.ListenFailed;

        self.listen_fd = fd;
    }

    pub fn stop(self: *Provider) void {
        if (self.listen_fd >= 0) {
            _ = linux.close(self.listen_fd);
            self.listen_fd = -1;
        }
    }

    pub fn setPlayers(self: *Provider, current: i32) void {
        self.info.current_players = current;
        self.rebuildText() catch {};
    }

    fn rebuildText(self: *Provider) !void {
        const t = try buildInfoText(&self.text_buf, self.info);
        self.text_len = t.len;
    }

    /// Non-blocking: accept one client and write info response.
    pub fn poll(self: *Provider) void {
        if (self.listen_fd < 0) return;
        var addr: linux.sockaddr.storage = undefined;
        var alen: linux.socklen_t = @sizeOf(linux.sockaddr.storage);
        const cfd_r = linux.accept(self.listen_fd, @ptrCast(&addr), &alen);
        if (linux.errno(cfd_r) != .SUCCESS) return;
        const client: i32 = @intCast(cfd_r);
        defer _ = linux.close(client);

        var hdr: [7]u8 = undefined;
        const n = self.text_len;
        hdr[0] = @intCast('0' + (n / 10000) % 10);
        hdr[1] = @intCast('0' + (n / 1000) % 10);
        hdr[2] = @intCast('0' + (n / 100) % 10);
        hdr[3] = @intCast('0' + (n / 10) % 10);
        hdr[4] = @intCast('0' + (n / 1) % 10);
        hdr[5] = '\r';
        hdr[6] = '\n';
        _ = linux.write(client, &hdr, hdr.len);
        if (self.text_len > 0) {
            _ = linux.write(client, self.text_buf[0..self.text_len].ptr, self.text_len);
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
    try std.testing.expect(std.mem.indexOf(u8, t, "\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, t, "\r\n\r\n"));
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
