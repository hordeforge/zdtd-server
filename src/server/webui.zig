//! Operator web UI HTTP listener (WU0 skeleton).
//! Loopback by default; shared secret required when enabled.
//! Polled from Game.step (non-blocking); does not run on a dedicated tick thread yet.
//! Design: docs/WEBUI.md

const std = @import("std");
const linux = std.os.linux;
const version = @import("../version.zig");

pub const max_req: usize = 8192;
pub const max_secret: usize = 128;
pub const max_bind_host: usize = 64;

pub const Config = struct {
    port: u16 = 0,
    /// IPv4 dotted quad; only 127.0.0.1 and 0.0.0.0 supported in WU0.
    bind_host: []const u8 = "127.0.0.1",
    /// Required when port != 0. Compared as bearer / X-Zdtd-Secret / cookie.
    secret: []const u8 = "",
};

pub const Server = struct {
    fd: i32 = -1,
    port: u16 = 0,
    bind_addr: u32 = 0x7f000001, // host order
    secret_buf: [max_secret]u8 = undefined,
    secret_len: usize = 0,
    /// One in-flight client (-1 free). WU0: single connection at a time.
    client_fd: i32 = -1,
    recv_buf: [max_req]u8 = undefined,
    recv_len: usize = 0,

    pub fn enabled(self: *const Server) bool {
        return self.fd >= 0;
    }

    pub fn listen(self: *Server, cfg: Config) !void {
        if (cfg.port == 0) return;
        if (cfg.secret.len == 0) return error.SecretRequired;
        if (cfg.secret.len > max_secret) return error.SecretTooLong;

        const addr_host = try parseIpv4(cfg.bind_host);
        // Refuse wildcard without explicit non-loopback intent is caller's job;
        // we still require secret for any bind.
        const sock_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(sock_rc) != .SUCCESS) return error.Socket;
        const fd: i32 = @intCast(sock_rc);
        errdefer _ = linux.close(fd);
        var yes: c_int = 1;
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&yes), @sizeOf(c_int));
        var addr = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, cfg.port),
            .addr = std.mem.nativeToBig(u32, addr_host),
        };
        const br = linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
        if (linux.errno(br) != .SUCCESS) return error.Bind;
        const lc = linux.listen(fd, 8);
        if (linux.errno(lc) != .SUCCESS) return error.Listen;

        @memcpy(self.secret_buf[0..cfg.secret.len], cfg.secret);
        self.secret_len = cfg.secret.len;
        self.fd = fd;
        self.port = cfg.port;
        self.bind_addr = addr_host;
        self.client_fd = -1;
        self.recv_len = 0;
    }

    pub fn deinit(self: *Server) void {
        if (self.client_fd >= 0) _ = linux.close(self.client_fd);
        self.client_fd = -1;
        self.recv_len = 0;
        if (self.fd >= 0) _ = linux.close(self.fd);
        self.fd = -1;
        self.port = 0;
        self.secret_len = 0;
    }

    fn secret(self: *const Server) []const u8 {
        return self.secret_buf[0..self.secret_len];
    }

    /// Non-blocking: accept at most one client, read request, respond, close.
    pub fn poll(self: *Server) void {
        if (self.fd < 0) return;
        self.acceptOne();
        if (self.client_fd < 0) return;
        self.readAndServe();
    }

    fn acceptOne(self: *Server) void {
        if (self.client_fd >= 0) return;
        var addr: linux.sockaddr.storage = undefined;
        var alen: linux.socklen_t = @sizeOf(linux.sockaddr.storage);
        const cfd_r = linux.accept(self.fd, @ptrCast(&addr), &alen);
        if (linux.errno(cfd_r) != .SUCCESS) return;
        const cfd: i32 = @intCast(cfd_r);
        const fl = linux.fcntl(cfd, linux.F.GETFL, 0);
        _ = linux.fcntl(cfd, linux.F.SETFL, fl | 0o4000);
        self.client_fd = cfd;
        self.recv_len = 0;
    }

    fn closeClient(self: *Server) void {
        if (self.client_fd >= 0) _ = linux.close(self.client_fd);
        self.client_fd = -1;
        self.recv_len = 0;
    }

    fn readAndServe(self: *Server) void {
        const fd = self.client_fd;
        if (fd < 0) return;
        if (self.recv_len >= max_req) {
            self.respond(413, "text/plain; charset=utf-8", "request too large\n");
            self.closeClient();
            return;
        }
        const dst = self.recv_buf[self.recv_len..];
        const n = linux.read(fd, dst.ptr, dst.len);
        const errn = linux.errno(n);
        if (errn == .AGAIN) return;
        if (errn != .SUCCESS or n == 0) {
            self.closeClient();
            return;
        }
        self.recv_len += @intCast(n);
        const head_end = std.mem.indexOf(u8, self.recv_buf[0..self.recv_len], "\r\n\r\n") orelse {
            if (self.recv_len >= max_req) {
                self.respond(413, "text/plain; charset=utf-8", "request too large\n");
                self.closeClient();
            }
            return;
        };
        const head = self.recv_buf[0..head_end];
        self.serveRequest(head) catch {
            self.respond(500, "text/plain; charset=utf-8", "internal error\n");
        };
        self.closeClient();
    }

    fn serveRequest(self: *Server, head: []const u8) !void {
        const line_end = std.mem.indexOf(u8, head, "\r\n") orelse {
            self.respond(400, "text/plain; charset=utf-8", "bad request\n");
            return;
        };
        const req_line = head[0..line_end];
        var it = std.mem.tokenizeScalar(u8, req_line, ' ');
        const method = it.next() orelse {
            self.respond(400, "text/plain; charset=utf-8", "bad request\n");
            return;
        };
        const target = it.next() orelse {
            self.respond(400, "text/plain; charset=utf-8", "bad request\n");
            return;
        };
        const path = pathOnly(target);

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/healthz")) {
            self.respond(200, "text/plain; charset=utf-8", "ok\n");
            return;
        }

        const authed = requestAuthorized(head, target, self.secret());
        if (!authed) {
            // WU0: no login form session yet; instruct operator.
            // A11y: lang, viewport, main landmark, descriptive title, contrast, focus ring.
            const body =
                \\<!DOCTYPE html>
                \\<html lang="en"><head><meta charset="utf-8">
                \\<meta name="viewport" content="width=device-width, initial-scale=1">
                \\<title>Unauthorized: zdtd webui</title>
                \\<style>
                \\body{font-family:system-ui,sans-serif;margin:2rem;max-width:40rem;line-height:1.5;color:#111;background:#fff}
                \\code{background:#eee;color:#111;padding:0.1em 0.3em}
                \\a:focus-visible{outline:2px solid #06c;outline-offset:2px}
                \\</style></head>
                \\<body>
                \\<main>
                \\<h1>Unauthorized</h1>
                \\<p>zdtd webui requires authentication. Send header <code>Authorization: Bearer &lt;secret&gt;</code>
                \\or <code>X-Zdtd-Secret: &lt;secret&gt;</code>.</p>
                \\<p>WU0 skeleton — see docs/WEBUI.md</p>
                \\</main>
                \\</body></html>
            ;
            self.respond(401, "text/html; charset=utf-8", body);
            return;
        }

        if (std.mem.eql(u8, method, "GET") and (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html"))) {
            var page_buf: [1536]u8 = undefined;
            const page = try std.fmt.bufPrint(&page_buf,
                \\<!DOCTYPE html>
                \\<html lang="en"><head><meta charset="utf-8">
                \\<meta name="viewport" content="width=device-width, initial-scale=1">
                \\<title>zdtd webui</title>
                \\<style>
                \\body{{font-family:system-ui,sans-serif;margin:2rem;max-width:40rem;line-height:1.5;color:#111;background:#fff}}
                \\code{{background:#eee;color:#111;padding:0.1em 0.3em}}
                \\a:focus-visible{{outline:2px solid #06c;outline-offset:2px}}
                \\</style></head>
                \\<body>
                \\<main>
                \\<h1>zdtd webui</h1>
                \\<p>WU0 skeleton — authenticated.</p>
                \\<ul>
                \\<li>product <code>{s}</code></li>
                \\<li>stock wire <code>{s}</code></li>
                \\<li>listen port <code>{d}</code></li>
                \\</ul>
                \\<p><a href="/healthz">/healthz</a> (no auth)</p>
                \\<p>Next: WU1 status/players/apm partials (docs/WEBUI.md).</p>
                \\</main>
                \\</body></html>
            , .{ version.product, version.stock_wire, self.port });
            self.respond(200, "text/html; charset=utf-8", page);
            return;
        }

        self.respond(404, "text/plain; charset=utf-8", "not found\n");
    }

    fn respond(self: *Server, status: u16, content_type: []const u8, body: []const u8) void {
        const fd = self.client_fd;
        if (fd < 0) return;
        const reason: []const u8 = switch (status) {
            200 => "OK",
            400 => "Bad Request",
            401 => "Unauthorized",
            404 => "Not Found",
            413 => "Payload Too Large",
            500 => "Internal Server Error",
            else => "Error",
        };
        var hdr: [512]u8 = undefined;
        const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "X-Content-Type-Options: nosniff\r\n" ++
            "\r\n", .{ status, reason, content_type, body.len }) catch return;
        writeAll(fd, h);
        writeAll(fd, body);
    }
};

fn writeAll(fd: i32, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = linux.write(fd, data[off..].ptr, data.len - off);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        off += @intCast(n);
    }
}

fn parseIpv4(host: []const u8) !u32 {
    if (std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost")) {
        return 0x7f000001;
    }
    if (std.mem.eql(u8, host, "0.0.0.0")) {
        return 0;
    }
    // Dotted quad
    var parts: [4]u8 = undefined;
    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |p| {
        if (idx >= 4) return error.BadBindHost;
        const v = std.fmt.parseInt(u8, p, 10) catch return error.BadBindHost;
        parts[idx] = v;
        idx += 1;
    }
    if (idx != 4) return error.BadBindHost;
    return (@as(u32, parts[0]) << 24) | (@as(u32, parts[1]) << 16) |
        (@as(u32, parts[2]) << 8) | @as(u32, parts[3]);
}

fn pathOnly(target: []const u8) []const u8 {
    if (target.len == 0) return "/";
    if (std.mem.indexOfScalar(u8, target, '?')) |q| return target[0..q];
    return target;
}

fn requestAuthorized(head: []const u8, target: []const u8, secret: []const u8) bool {
    if (secret.len == 0) return false;
    // Authorization: Bearer <secret>
    if (headerValue(head, "Authorization")) |auth| {
        const t = std.mem.trim(u8, auth, " \t");
        if (std.mem.startsWith(u8, t, "Bearer ")) {
            const tok = std.mem.trim(u8, t["Bearer ".len..], " \t");
            if (constantTimeEql(tok, secret)) return true;
        }
    }
    if (headerValue(head, "X-Zdtd-Secret")) |v| {
        if (constantTimeEql(std.mem.trim(u8, v, " \t"), secret)) return true;
    }
    // Optional query ?token= for quick curl (still secret knowledge).
    if (std.mem.indexOfScalar(u8, target, '?')) |q| {
        const qs = target[q + 1 ..];
        var it = std.mem.splitScalar(u8, qs, '&');
        while (it.next()) |pair| {
            if (std.mem.startsWith(u8, pair, "token=")) {
                const tok = pair["token=".len..];
                if (constantTimeEql(tok, secret)) return true;
            }
        }
    }
    return false;
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next(); // request line
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

test "parseIpv4 loopback and any" {
    try std.testing.expectEqual(@as(u32, 0x7f000001), try parseIpv4("127.0.0.1"));
    try std.testing.expectEqual(@as(u32, 0), try parseIpv4("0.0.0.0"));
    try std.testing.expectEqual(@as(u32, 0x0a000001), try parseIpv4("10.0.0.1"));
}

test "pathOnly strips query" {
    try std.testing.expectEqualStrings("/foo", pathOnly("/foo?token=x"));
    try std.testing.expectEqualStrings("/", pathOnly("/"));
}

test "requestAuthorized bearer and header" {
    const head =
        \\GET / HTTP/1.1
        \\Host: localhost
        \\Authorization: Bearer s3cr3t
        \\
    ;
    // head without final CRLF pair — use real CRLF
    const h1 = "GET / HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer s3cr3t\r\n";
    try std.testing.expect(requestAuthorized(h1, "/", "s3cr3t"));
    try std.testing.expect(!requestAuthorized(h1, "/", "nope"));
    const h2 = "GET / HTTP/1.1\r\nX-Zdtd-Secret: s3cr3t\r\n";
    try std.testing.expect(requestAuthorized(h2, "/", "s3cr3t"));
    try std.testing.expect(requestAuthorized("GET / HTTP/1.1\r\n", "/?token=s3cr3t", "s3cr3t"));
    _ = head;
}

test "listen refuses empty secret" {
    var s: Server = .{};
    defer s.deinit();
    try std.testing.expectError(error.SecretRequired, s.listen(.{ .port = 1, .secret = "" }));
}
