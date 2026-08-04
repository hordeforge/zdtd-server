//! Operator web UI HTTP listener (WU0–WU2: dashboard + console cmds).
//! Loopback by default; shared secret required when enabled.
//! Cookie/CSRF use an HMAC session token (shared secret stays off the wire cookie/HTML).
//! Polled from Game.step (non-blocking). Snapshot filled on main thread.
//! POST /api/cmd runs via admin_fn on the poll thread (same path as admin TCP).
//! Design: docs/WEBUI.md

const std = @import("std");
const linux = std.os.linux;
const version = @import("../version.zig");

pub const max_req: usize = 8192;
pub const max_secret: usize = 128;
/// Hex length of HMAC-derived session token (cookie + CSRF; not the shared secret).
pub const session_token_hex_len: usize = 32;
pub const max_players_snap: usize = 16;
pub const max_name: usize = 32;
/// Max admin line from web console POST /api/cmd.
pub const max_cmd_line: usize = 256;
pub const max_cmd_out: usize = 4096;
pub const max_audit: usize = 24;
pub const max_audit_line: usize = 160;

pub const Config = struct {
    port: u16 = 0,
    bind_host: []const u8 = "127.0.0.1",
    secret: []const u8 = "",
};

pub const PlayerRow = struct {
    used: bool = false,
    slot: u8 = 0,
    entity_id: i32 = 0,
    joined: bool = false,
    entered: bool = false,
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    name_len: u8 = 0,
    name: [max_name]u8 = .{0} ** max_name,
};

pub const Snapshot = struct {
    tick_n: u64 = 0,
    day: u32 = 1,
    hours: f32 = 8,
    bloodmoon_active: bool = false,
    bloodmoon_frequency: u32 = 7,
    joined: u16 = 0,
    entered: u16 = 0,
    peers_alive: u16 = 0,
    max_players: u16 = 8,
    // Entity census
    zombies: u16 = 0,
    animals: u16 = 0,
    traders: u16 = 0,
    vehicles: u16 = 0,
    turrets: u16 = 0,
    loot_bags: u16 = 0,
    players_ent: u16 = 0,
    chunks: u32 = 0,
    // Net counters
    net_packets_in: u64 = 0,
    net_packets_out: u64 = 0,
    net_bytes_in: u64 = 0,
    net_bytes_out: u64 = 0,
    entities_ticked: u64 = 0,
    // Errors / ops
    tick_overruns: u64 = 0,
    encode_errors: u64 = 0,
    stream_errors: u64 = 0,
    join_ok: u64 = 0,
    join_fail: u64 = 0,
    packages_encoded: u64 = 0,
    packages_broadcast: u64 = 0,
    net_poll_errors: u64 = 0,
    net_payload_errors: u64 = 0,
    net_send_errors: u64 = 0,
    reliable_window_drops: u64 = 0,
    persistence_errors: u64 = 0,
    stale_peers_reaped: u64 = 0,
    // Latency
    tick_mean_ns: u64 = 0,
    tick_p50_ns: u64 = 0,
    tick_p99_ns: u64 = 0,
    tick_max_ns: u64 = 0,
    net_mean_ns: u64 = 0,
    net_p99_ns: u64 = 0,
    sim_mean_ns: u64 = 0,
    sim_p99_ns: u64 = 0,
    repl_mean_ns: u64 = 0,
    repl_p99_ns: u64 = 0,
    stream_mean_ns: u64 = 0,
    stream_p99_ns: u64 = 0,
    save_mean_ns: u64 = 0,
    // Config / policy (read-only)
    view_radius: i32 = 7,
    max_streamed_chunks: u16 = 169,
    interest_range: f32 = 160,
    max_edit_range: f32 = 96,
    max_spawned_zombies: u16 = 64,
    info_port: u16 = 0,
    webui_port: u16 = 0,
    authority_correct: bool = true,
    password_set: bool = false,
    wire_chunks: bool = true,
    world_name_len: u8 = 0,
    world_name: [48]u8 = .{0} ** 48,
    players: [max_players_snap]PlayerRow = [_]PlayerRow{.{}} ** max_players_snap,
};

/// Called from HTTP poll with one admin line; must fill reply into out (same as admin TCP).
pub const AdminFn = *const fn (ctx: *anyopaque, line: []const u8, out: []u8) usize;

pub const Server = struct {
    fd: i32 = -1,
    port: u16 = 0,
    bind_addr: u32 = 0x7f000001,
    secret_buf: [max_secret]u8 = undefined,
    secret_len: usize = 0,
    /// HMAC session material for cookie/CSRF (never the raw secret).
    session_token: [session_token_hex_len]u8 = undefined,
    client_fd: i32 = -1,
    /// Polls since accept; a client that never completes a request would hold
    /// the single slot forever (half-open TCP reads EAGAIN, never EOF).
    client_polls: u32 = 0,
    recv_buf: [max_req]u8 = undefined,
    recv_len: usize = 0,
    snap: Snapshot = .{},
    set_cookie: bool = false,
    /// Queued console line (legacy drain path; POST prefers admin_fn same-request).
    cmd_pending: bool = false,
    cmd_line_buf: [max_cmd_line]u8 = undefined,
    cmd_line_len: usize = 0,
    cmd_out_buf: [max_cmd_out]u8 = undefined,
    cmd_out_len: usize = 0,
    /// Game installs this so POST /api/cmd runs runAdminLine on the poll thread.
    admin_fn: ?AdminFn = null,
    admin_ctx: ?*anyopaque = null,
    /// Ring of recent console lines for /partials/console (ops audit).
    audit_n: u8 = 0,
    audit_i: u8 = 0,
    audit_lens: [max_audit]u8 = .{0} ** max_audit,
    audit_lines: [max_audit][max_audit_line]u8 = undefined,

    pub fn enabled(self: *const Server) bool {
        return self.fd >= 0;
    }

    pub fn setAdminHandler(self: *Server, ctx: *anyopaque, f: AdminFn) void {
        self.admin_ctx = ctx;
        self.admin_fn = f;
    }

    fn pushAudit(self: *Server, line: []const u8) void {
        const i = self.audit_i % max_audit;
        const n = @min(line.len, max_audit_line);
        if (n > 0) @memcpy(self.audit_lines[i][0..n], line[0..n]);
        self.audit_lens[i] = @intCast(n);
        self.audit_i +%= 1;
        if (self.audit_n < max_audit) self.audit_n += 1;
    }

    pub fn listen(self: *Server, cfg: Config) !void {
        if (cfg.port == 0) return;
        if (cfg.secret.len == 0) return error.SecretRequired;
        if (cfg.secret.len > max_secret) return error.SecretTooLong;
        // Secret may appear in Authorization / login query; reject control chars and
        // separators so operators cannot accidentally enable CR/LF header injection.
        if (!secretCharsetOk(cfg.secret)) return error.SecretInvalid;

        const addr_host = try parseIpv4(cfg.bind_host);
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
        fillSessionToken(cfg.secret, &self.session_token);
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
        if (self.secret_len > 0) @memset(self.secret_buf[0..self.secret_len], 0);
        self.secret_len = 0;
        @memset(&self.session_token, 0);
    }

    pub fn publishSnap(self: *Server, s: Snapshot) void {
        self.snap = s;
    }

    fn secret(self: *const Server) []const u8 {
        return self.secret_buf[0..self.secret_len];
    }

    fn sessionTok(self: *const Server) []const u8 {
        return self.session_token[0..];
    }

    /// Polls before an incomplete request is dropped (~10 s at 4 polls per
    /// 50 ms tick). Frees the single client slot from stalled/half-open peers.
    pub const max_client_polls: u32 = 800;

    pub fn poll(self: *Server) void {
        if (self.fd < 0) return;
        self.acceptOne();
        if (self.client_fd < 0) return;
        self.client_polls += 1;
        if (self.client_polls > max_client_polls) {
            self.closeClient();
            return;
        }
        self.readAndServe();
    }

    /// Copy pending console command into `out` and clear the queue. Null if empty.
    pub fn takeCmd(self: *Server, out: []u8) ?[]const u8 {
        if (!self.cmd_pending or self.cmd_line_len == 0) return null;
        const n = @min(self.cmd_line_len, out.len);
        @memcpy(out[0..n], self.cmd_line_buf[0..n]);
        self.cmd_pending = false;
        self.cmd_line_len = 0;
        return out[0..n];
    }

    pub fn finishCmd(self: *Server, reply: []const u8) void {
        const n = @min(reply.len, self.cmd_out_buf.len);
        if (n > 0) @memcpy(self.cmd_out_buf[0..n], reply[0..n]);
        self.cmd_out_len = n;
    }

    pub fn enqueueCmd(self: *Server, line: []const u8) bool {
        if (self.cmd_pending) return false;
        if (line.len == 0 or line.len > max_cmd_line) return false;
        @memcpy(self.cmd_line_buf[0..line.len], line);
        self.cmd_line_len = line.len;
        self.cmd_pending = true;
        self.cmd_out_len = 0;
        return true;
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
        self.client_polls = 0;
        self.recv_len = 0;
    }

    fn closeClient(self: *Server) void {
        if (self.client_fd >= 0) _ = linux.close(self.client_fd);
        self.client_fd = -1;
        self.client_polls = 0;
        self.recv_len = 0;
        self.set_cookie = false;
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
        const body_start = head_end + 4;
        const clen = contentLength(head) orelse 0;
        if (clen > max_req - body_start) {
            self.respond(413, "text/plain; charset=utf-8", "request too large\n");
            self.closeClient();
            return;
        }
        if (self.recv_len < body_start + clen) return; // need more body
        const body = self.recv_buf[body_start .. body_start + clen];
        self.serveRequest(head, body) catch |err| {
            std.debug.print("zdtd: webui request failed: {s}\n", .{@errorName(err)});
            self.respond(500, "text/plain; charset=utf-8", "internal error\n");
        };
        self.closeClient();
    }

    fn serveRequest(self: *Server, head: []const u8, body: []u8) !void {
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

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/login")) {
            if (queryToken(target)) |tok| {
                if (constantTimeEql(tok, self.secret())) {
                    self.set_cookie = true;
                    self.respondRedirect("/");
                    return;
                }
                std.debug.print("zdtd: webui login rejected (bad token)\n", .{});
            }
            self.respond(401, "text/html; charset=utf-8", loginHintHtml());
            return;
        }

        if (!requestAuthorized(head, target, self.secret())) {
            self.respond(401, "text/html; charset=utf-8", loginHintHtml());
            return;
        }
        if (queryToken(target)) |tok| {
            // Login bootstrap: raw secret in query once; cookie is HMAC session token.
            if (constantTimeEql(tok, self.secret())) self.set_cookie = true;
        }

        var body_buf: [12288]u8 = undefined;

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/cmd")) {
            try self.handleCmdPost(head, body, &body_buf);
            return;
        }

        if (!std.mem.eql(u8, method, "GET")) {
            self.respond(405, "text/plain; charset=utf-8", "method not allowed\n");
            return;
        }

        if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
            // CSRF token is session material, not the shared secret.
            self.respond(200, "text/html; charset=utf-8", try renderShell(&body_buf, self.sessionTok()));
            return;
        }
        if (std.mem.eql(u8, path, "/partials/status")) {
            self.respond(200, "text/html; charset=utf-8", try renderStatus(&body_buf, &self.snap));
            return;
        }
        if (std.mem.eql(u8, path, "/partials/players")) {
            self.respond(200, "text/html; charset=utf-8", try renderPlayers(&body_buf, &self.snap));
            return;
        }
        if (std.mem.eql(u8, path, "/partials/apm")) {
            self.respond(200, "text/html; charset=utf-8", try renderApm(&body_buf, &self.snap));
            return;
        }
        if (std.mem.eql(u8, path, "/partials/console")) {
            self.respond(200, "text/html; charset=utf-8", try renderConsoleLog(&body_buf, self));
            return;
        }
        if (std.mem.eql(u8, path, "/api/apm.json")) {
            self.respond(200, "application/json; charset=utf-8", try renderApmJson(&body_buf, &self.snap));
            return;
        }
        self.respond(404, "text/plain; charset=utf-8", "not found\n");
    }

    fn handleCmdPost(self: *Server, head: []const u8, body: []u8, html_buf: []u8) !void {
        if (!isFormContentType(headerValue(head, "Content-Type"))) {
            self.respond(415, "text/plain; charset=utf-8", "expected application/x-www-form-urlencoded\n");
            return;
        }

        // CSRF: form field csrf=session token (preferred) or raw secret; or auth header.
        const csrf = formField(body, "csrf") orelse formField(body, "token");
        const has_valid_auth_header = requestHeaderAuthorized(head, self.secret());
        if (csrf) |c| {
            const sess_ok = constantTimeEql(c, self.sessionTok());
            const secret_ok = constantTimeEql(c, self.secret());
            if (!sess_ok and !secret_ok) {
                self.respond(403, "text/plain; charset=utf-8", "csrf rejected\n");
                return;
            }
        } else if (!has_valid_auth_header) {
            // Cookie-only session must send csrf field.
            self.respond(403, "text/plain; charset=utf-8", "csrf required\n");
            return;
        }

        const raw_line = formField(body, "line") orelse formField(body, "cmd") orelse {
            self.respond(400, "text/html; charset=utf-8", "<pre class=\"err\">missing line</pre>\n");
            return;
        };
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0 or line.len > max_cmd_line) {
            self.respond(400, "text/html; charset=utf-8", "<pre class=\"err\">bad line</pre>\n");
            return;
        }

        var reply_buf: [max_cmd_out]u8 = undefined;
        var reply_len: usize = 0;
        if (self.admin_fn) |f| {
            if (self.admin_ctx) |ctx| {
                reply_len = f(ctx, line, &reply_buf);
            }
        } else {
            // Fallback: queue for next tick (no same-request text).
            if (!self.enqueueCmd(line)) {
                self.respond(503, "text/html; charset=utf-8", "<pre class=\"err\">busy</pre>\n");
                return;
            }
            var w: std.Io.Writer = .fixed(html_buf);
            try w.writeAll("<pre class=\"ok\">queued: ");
            try htmlEscape(&w, line);
            try w.writeAll("</pre>\n");
            self.respond(200, "text/html; charset=utf-8", w.buffered());
            self.pushAudit(line);
            return;
        }

        const reply = if (reply_len > 0) reply_buf[0..reply_len] else "ok\n";
        var audit_line: [max_audit_line]u8 = undefined;
        const al = std.fmt.bufPrint(&audit_line, "> {s}", .{line}) catch line;
        self.pushAudit(al);
        if (reply_len > 0) {
            const first = std.mem.indexOfScalar(u8, reply, '\n') orelse reply.len;
            self.pushAudit(reply[0..@min(first, max_audit_line)]);
        }

        const html = try renderCmdReply(html_buf, line, reply);
        self.respond(200, "text/html; charset=utf-8", html);
    }

    fn respondRedirect(self: *Server, loc: []const u8) void {
        const fd = self.client_fd;
        if (fd < 0) return;
        var hbuf: [896]u8 = undefined;
        const h = if (self.set_cookie)
            std.fmt.bufPrint(&hbuf, "HTTP/1.1 302 Found\r\nLocation: {s}\r\nSet-Cookie: zdtd_webui={s}; Path=/; HttpOnly; SameSite=Strict\r\nContent-Length: 0\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n\r\n", .{ loc, self.sessionTok() }) catch return
        else
            std.fmt.bufPrint(&hbuf, "HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n\r\n", .{loc}) catch return;
        writeAll(fd, h);
    }

    fn respond(self: *Server, status: u16, content_type: []const u8, body: []const u8) void {
        const fd = self.client_fd;
        if (fd < 0) return;
        const reason: []const u8 = switch (status) {
            200 => "OK",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            413 => "Payload Too Large",
            415 => "Unsupported Media Type",
            500 => "Internal Server Error",
            503 => "Service Unavailable",
            else => "Error",
        };
        var hdr: [896]u8 = undefined;
        const h = if (self.set_cookie)
            std.fmt.bufPrint(&hdr, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\nSet-Cookie: zdtd_webui={s}; Path=/; HttpOnly; SameSite=Strict\r\n\r\n", .{ status, reason, content_type, body.len, self.sessionTok() }) catch return
        else
            std.fmt.bufPrint(&hdr, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n\r\n", .{ status, reason, content_type, body.len }) catch return;
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
    if (std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost")) return 0x7f000001;
    if (std.mem.eql(u8, host, "0.0.0.0")) return 0;
    var parts: [4]u8 = undefined;
    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |p| {
        if (idx >= 4) return error.BadBindHost;
        parts[idx] = std.fmt.parseInt(u8, p, 10) catch return error.BadBindHost;
        idx += 1;
    }
    if (idx != 4) return error.BadBindHost;
    return (@as(u32, parts[0]) << 24) | (@as(u32, parts[1]) << 16) | (@as(u32, parts[2]) << 8) | parts[3];
}

fn pathOnly(target: []const u8) []const u8 {
    if (target.len == 0) return "/";
    if (std.mem.indexOfScalar(u8, target, '?')) |q| return target[0..q];
    return target;
}

fn contentLength(head: []const u8) ?usize {
    const v = headerValue(head, "Content-Length") orelse return null;
    return std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t"), 10) catch null;
}

fn isFormContentType(value: ?[]const u8) bool {
    const raw = value orelse return false;
    const semicolon = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
    const media_type = std.mem.trim(u8, raw[0..semicolon], " \t");
    return std.ascii.eqlIgnoreCase(media_type, "application/x-www-form-urlencoded");
}

fn formField(body: []u8, name: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (start <= body.len) {
        const amp = std.mem.indexOfScalar(u8, body[start..], '&') orelse body.len - start;
        const pair = body[start .. start + amp];
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
            if (start + amp >= body.len) break;
            start += amp + 1;
            continue;
        };
        const key = pair[0..eq];
        if (std.mem.eql(u8, key, name)) {
            return urlDecodeInPlace(pair[eq + 1 ..]);
        }
        if (start + amp >= body.len) break;
        start += amp + 1;
    }
    return null;
}

/// Decode %XX and + in a form value; mutates a copy only when needed via scratch.
/// For simplicity, decode into a thread-local-ish static is avoided: in-place on
/// recv_buf is safe because body is discarded after the request.
fn urlDecodeInPlace(s: []u8) []const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '+') {
            s[w] = ' ';
            w += 1;
            i += 1;
        } else if (c == '%' and i + 2 < s.len) {
            const hi = fromHex(s[i + 1]) orelse {
                s[w] = c;
                w += 1;
                i += 1;
                continue;
            };
            const lo = fromHex(s[i + 2]) orelse {
                s[w] = c;
                w += 1;
                i += 1;
                continue;
            };
            s[w] = (hi << 4) | lo;
            w += 1;
            i += 3;
        } else {
            s[w] = c;
            w += 1;
            i += 1;
        }
    }
    return s[0..w];
}

fn fromHex(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn htmlEscape(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(c),
        }
    }
}

fn renderCmdReply(buf: []u8, line: []const u8, reply: []const u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("<pre class=\"cmd-out\"><span class=\"in\">&gt; ");
    try htmlEscape(&w, line);
    try w.writeAll("</span>\n");
    try htmlEscape(&w, reply);
    try w.writeAll("</pre>");
    return w.buffered();
}

fn renderConsoleLog(buf: []u8, s: *const Server) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("<pre class=\"cmd-log\">");
    if (s.audit_n == 0) {
        try w.writeAll("<span class=\"meta\">no commands yet</span>");
    } else {
        const n: usize = s.audit_n;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const idx = (s.audit_i -% @as(u8, @intCast(n)) +% @as(u8, @intCast(k))) % max_audit;
            const len = s.audit_lens[idx];
            try htmlEscape(&w, s.audit_lines[idx][0..len]);
            try w.writeAll("\n");
        }
    }
    try w.writeAll("</pre>");
    return w.buffered();
}

fn queryToken(target: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "token=")) return pair["token=".len..];
    }
    return null;
}

/// HMAC-SHA256(secret, "zdtd.webui.session.v1") → first 16 bytes as hex (32 chars).
/// Cookie and CSRF use this so the shared secret is not stored in browser storage/HTML.
fn fillSessionToken(secret: []const u8, out: *[session_token_hex_len]u8) void {
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, "zdtd.webui.session.v1", secret);
    const hex = "0123456789abcdef";
    const n = session_token_hex_len / 2;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const b = mac[i];
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
}

fn requestAuthorized(head: []const u8, target: []const u8, secret: []const u8) bool {
    if (secret.len == 0) return false;
    if (requestHeaderAuthorized(head, secret)) return true;
    var sess: [session_token_hex_len]u8 = undefined;
    fillSessionToken(secret, &sess);
    if (headerValue(head, "Cookie")) |ck| {
        if (cookieValue(ck, "zdtd_webui")) |cv| {
            // Session cookie only; raw secret in Cookie is rejected (not in HTML/cookie).
            if (constantTimeEql(cv, sess[0..])) return true;
        }
    }
    if (queryToken(target)) |tok| {
        // One-shot login bootstrap still accepts the shared secret on /login and routes.
        if (constantTimeEql(tok, secret)) return true;
    }
    return false;
}

fn requestHeaderAuthorized(head: []const u8, secret: []const u8) bool {
    if (secret.len == 0) return false;
    if (headerValue(head, "Authorization")) |auth| {
        const t = std.mem.trim(u8, auth, " \t");
        if (std.mem.startsWith(u8, t, "Bearer ")) {
            if (constantTimeEql(std.mem.trim(u8, t["Bearer ".len..], " \t"), secret)) return true;
        }
    }
    if (headerValue(head, "X-Zdtd-Secret")) |v| {
        if (constantTimeEql(std.mem.trim(u8, v, " \t"), secret)) return true;
    }
    return false;
}

fn cookieValue(cookie_hdr: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, cookie_hdr, ';');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        if (std.mem.startsWith(u8, p, name) and p.len > name.len and p[name.len] == '=') {
            return p[name.len + 1 ..];
        }
    }
    return null;
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next();
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

/// Cookie/header-safe secret: printable ASCII without whitespace, quotes, backslash, or `;`.
fn secretCharsetOk(secret: []const u8) bool {
    for (secret) |c| {
        if (c < 0x21 or c > 0x7e) return false;
        switch (c) {
            ';', '"', '\'', '\\', ',' => return false,
            else => {},
        }
    }
    return true;
}

fn loginHintHtml() []const u8 {
    return
    \\<!DOCTYPE html>
    \\<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    \\<title>zdtd webui login</title>
    \\<style>body{font-family:system-ui,sans-serif;margin:2rem;max-width:36rem;line-height:1.5;color:#e8e8e8;background:#1a1a1a}
    \\code{background:#333;padding:0.15em 0.4em;border-radius:3px}a{color:#7eb8ff}a:focus-visible{outline:3px solid #e8a838;outline-offset:3px}</style></head>
    \\<body><main><h1>zdtd webui</h1>
    \\<p>Unauthorized. Open <code>/login?token=YOUR_SECRET</code> once to set a cookie, or send
    \\<code>Authorization: Bearer …</code> / <code>X-Zdtd-Secret</code>.</p>
    \\<p>See docs/WEBUI.md</p></main></body></html>
    ;
}

/// `csrf_token` must be the HMAC session token (not the shared secret).
fn renderShell(buf: []u8, csrf_token: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf,
        \\<!DOCTYPE html>
        \\<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        \\<title>zdtd webui</title>
        \\<style>
        \\:root{{--bg:#12141a;--card:#1c2030;--fg:#e8eaef;--muted:#9aa3b5;--acc:#5b9fd4;--ok:#6bcb77;--warn:#e8a838;--err:#e85d5d}}
        \\*{{box-sizing:border-box}}body{{font-family:system-ui,sans-serif;margin:0;background:var(--bg);color:var(--fg);line-height:1.45}}
        \\.skip-link{{position:absolute;left:1rem;top:0;transform:translateY(-150%);background:var(--warn);color:#0a0c10;padding:0.65rem 0.85rem;border-radius:0 0 6px 6px;font-weight:700;z-index:1}}.skip-link:focus{{transform:translateY(0)}}
        \\header{{padding:1rem 1.25rem;border-bottom:1px solid #2a3144;display:flex;gap:1rem;align-items:baseline;flex-wrap:wrap}}
        \\header h1{{font-size:1.15rem;margin:0;font-weight:600}}header .meta{{color:var(--muted);font-size:0.9rem}}
        \\main{{padding:1rem 1.25rem;display:grid;gap:1rem;max-width:56rem}}
        \\section{{background:var(--card);border-radius:8px;padding:0.85rem 1rem;border:1px solid #2a3144}}
        \\section h2{{margin:0 0 0.6rem;font-size:0.95rem;color:var(--acc);font-weight:600;text-transform:uppercase;letter-spacing:0.04em}}
        \\table{{width:100%;border-collapse:collapse;font-size:0.9rem}}th,td{{text-align:left;padding:0.35rem 0.5rem;border-bottom:1px solid #2a3144}}
        \\th{{color:var(--muted);font-weight:500}} .num{{font-variant-numeric:tabular-nums}}
        \\.sr-only{{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}}
        \\.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(7.5rem,1fr));gap:0.5rem}}
        \\.stat{{background:#141824;border-radius:6px;padding:0.5rem 0.65rem}}.stat b{{display:block;font-size:1.1rem}}.stat span{{color:var(--muted);font-size:0.75rem}}
        \\footer{{padding:0.75rem 1.25rem;color:var(--muted);font-size:0.8rem}}
        \\.cmd-row{{display:flex;gap:0.5rem;flex-wrap:wrap;margin-top:0.5rem}}
        \\.cmd-row input[type=text]{{flex:1;min-width:12rem;background:#141824;border:1px solid #2a3144;color:var(--fg);padding:0.45rem 0.6rem;border-radius:6px;font-family:ui-monospace,monospace}}
        \\.cmd-row button{{background:var(--acc);color:#0a0c10;border:0;border-radius:6px;padding:0.55rem 0.9rem;min-height:44px;min-width:4.5rem;font-weight:600;cursor:pointer}}.cmd-row button:disabled{{opacity:0.65;cursor:wait}}
        \\a:focus-visible,button:focus-visible,input:focus-visible{{outline:3px solid var(--warn);outline-offset:3px}}
        \\pre.cmd-out,pre.cmd-log{{margin:0.5rem 0 0;background:#0e1018;border-radius:6px;padding:0.6rem 0.75rem;font-size:0.85rem;overflow:auto;max-height:14rem;white-space:pre-wrap;word-break:break-word}}
        \\pre .in{{color:var(--acc)}} .err{{color:var(--err)}} .ok{{color:var(--ok)}} pre .meta{{color:var(--muted)}}
        \\#players{{overflow-x:auto}}#players table{{min-width:30rem}}
        \\@media(max-width:36rem){{main{{padding:0.75rem}}header,footer{{padding-left:0.75rem;padding-right:0.75rem}}section{{padding:0.75rem}}.cmd-row{{display:grid;grid-template-columns:minmax(0,1fr) auto}}.cmd-row input[type=text]{{min-width:0}}}}
        \\@media(prefers-reduced-motion:reduce){{.skip-link{{transition:none}}}}
        \\</style></head>
        \\<body>
        \\<a class="skip-link" href="#main-content">Skip to dashboard</a>
        \\<header><h1>zdtd</h1><span class="meta">{s} · {s} · ops dashboard</span></header>
        \\<main id="main-content" tabindex="-1">
        \\<section id="status" aria-label="Status" hx-get="/partials/status" hx-trigger="load, every 2s" hx-swap="innerHTML"><p class="meta">loading…</p></section>
        \\<section aria-labelledby="apm-heading"><h2 id="apm-heading">APM / counters</h2><div id="apm" hx-get="/partials/apm" hx-trigger="load, every 2s" hx-swap="innerHTML"></div></section>
        \\<section aria-labelledby="players-heading"><h2 id="players-heading">Players</h2><div id="players" hx-get="/partials/players" hx-trigger="load, every 2s" hx-swap="innerHTML"></div></section>
        \\<section aria-labelledby="console-heading">
        \\<h2 id="console-heading">Console</h2>
        \\<p id="cmd-help" class="meta" style="margin:0 0 0.4rem;color:var(--muted);font-size:0.85rem">Use the same commands as the admin console, such as help, status, give, kick, and settime.</p>
        \\<form id="cmd-form" class="cmd-row">
        \\<input type="hidden" name="csrf" value="{s}">
        \\<label for="cmd-line" class="sr-only">Admin command</label>
        \\<input type="text" name="line" id="cmd-line" placeholder="Enter a command, for example: status" aria-describedby="cmd-help" autocomplete="off" spellcheck="false" maxlength="256" required>
        \\<button type="submit">Run</button>
        \\</form>
        \\<div id="cmd-out" role="status" aria-live="polite" aria-atomic="true"></div>
        \\<div id="console-log" hx-get="/partials/console" hx-trigger="load, every 5s" hx-swap="innerHTML"></div>
        \\</section>
        \\</main>
        \\<footer>Auto-refresh · <a href="/api/apm.json" style="color:var(--acc)">/api/apm.json</a> · <a href="/healthz" style="color:var(--acc)">/healthz</a></footer>
        \\<script>
        \\function hxPoll(el){{const u=el.getAttribute('hx-get');if(!u)return;const swap=()=>{{el.setAttribute('aria-busy','true');return fetch(u,{{credentials:'same-origin'}}).then(r=>r.ok?r.text():Promise.reject()).then(t=>{{el.innerHTML=t;el.removeAttribute('data-load-error');}}).catch(()=>{{if(!el.children.length||el.getAttribute('data-load-error'))el.innerHTML='<p class="err" role="alert">Unable to refresh. Retrying automatically.</p>';el.setAttribute('data-load-error','true');}}).finally(()=>el.removeAttribute('aria-busy'));}};swap();const ms=el.getAttribute('hx-trigger')&&el.getAttribute('hx-trigger').indexOf('5s')>=0?5000:2000;setInterval(swap,ms);}}
        \\document.querySelectorAll('[hx-get]').forEach(hxPoll);
        \\document.getElementById('cmd-form').addEventListener('submit',async(e)=>{{e.preventDefault();const form=e.target;const button=form.querySelector('button');const fd=new FormData(form);const out=document.getElementById('cmd-out');button.disabled=true;button.textContent='Running…';out.innerHTML='<pre class="meta">Running command…</pre>';try{{const r=await fetch('/api/cmd',{{method:'POST',credentials:'same-origin',headers:{{'Content-Type':'application/x-www-form-urlencoded'}},body:new URLSearchParams(fd)}});out.innerHTML=await r.text();const log=document.getElementById('console-log');if(log&&log.getAttribute('hx-get'))fetch(log.getAttribute('hx-get'),{{credentials:'same-origin'}}).then(x=>x.ok?x.text():Promise.reject()).then(t=>log.innerHTML=t).catch(()=>{{}});}}catch(err){{out.innerHTML='<pre class="err">Command could not be sent. Check the connection and try again.</pre>';}}finally{{button.disabled=false;button.textContent='Run';}}}});
        \\</script>
        \\</body></html>
    , .{ version.product, version.stock_wire, csrf_token });
}

fn renderStatus(buf: []u8, s: *const Snapshot) ![]const u8 {
    const wn = s.world_name[0..s.world_name_len];
    const hh: u32 = @intFromFloat(@floor(s.hours));
    const mm: u32 = @intFromFloat(@floor((s.hours - @as(f32, @floatFromInt(hh))) * 60.0));
    const bm: []const u8 = if (s.bloodmoon_active) "ACTIVE" else "idle";
    const auth: []const u8 = if (s.authority_correct) "correct" else "observe";
    const pw: []const u8 = if (s.password_set) "set" else "open";
    const wc: []const u8 = if (s.wire_chunks) "on" else "off";
    var w: std.Io.Writer = .fixed(buf);
    try w.print(
        \\<h2>Status</h2>
        \\<div class="grid">
        \\<div class="stat"><b class="num">{d}</b><span>tick</span></div>
        \\<div class="stat"><b class="num">d{d} {d:0>2}:{d:0>2}</b><span>world time</span></div>
        \\<div class="stat"><b>{s}</b><span>blood moon (every {d}d)</span></div>
        \\<div class="stat"><b class="num">{d}/{d}</b><span>joined / max</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>entered</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>peers alive</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>chunks RAM</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>tick overruns</span></div>
        \\</div>
    , .{
        s.tick_n,
        s.day,
        hh,
        mm,
        bm,
        s.bloodmoon_frequency,
        s.joined,
        s.max_players,
        s.entered,
        s.peers_alive,
        s.chunks,
        s.tick_overruns,
    });
    try w.print(
        \\<h2 style="margin-top:1rem">Entities</h2>
        \\<div class="grid">
        \\<div class="stat"><b class="num">{d}/{d}</b><span>zombies / cap</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>animals</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>players (ecs)</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>traders</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>vehicles</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>turrets</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>loot bags</span></div>
        \\</div>
    , .{
        s.zombies,
        s.max_spawned_zombies,
        s.animals,
        s.players_ent,
        s.traders,
        s.vehicles,
        s.turrets,
        s.loot_bags,
    });
    try w.writeAll(
        \\<h2 style="margin-top:1rem">Server</h2>
        \\<div class="grid">
        \\<div class="stat"><b>
    );
    // World names come from config/CLI; still escape so a crafted path cannot break HTML.
    try htmlEscape(&w, wn);
    try w.print(
        \\</b><span>world</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>info port</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>litenet port</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>webui port</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>view radius</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>max streamed</span></div>
        \\<div class="stat"><b class="num">{d:.0}</b><span>interest m</span></div>
        \\<div class="stat"><b class="num">{d:.0}</b><span>edit range m</span></div>
        \\<div class="stat"><b>{s}</b><span>authority</span></div>
        \\<div class="stat"><b>{s}</b><span>password</span></div>
        \\<div class="stat"><b>{s}</b><span>wire chunks</span></div>
        \\</div>
    , .{
        s.info_port,
        s.info_port +% 2,
        s.webui_port,
        s.view_radius,
        s.max_streamed_chunks,
        s.interest_range,
        s.max_edit_range,
        auth,
        pw,
        wc,
    });
    return w.buffered();
}

fn renderPlayers(buf: []u8, s: *const Snapshot) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("<table><caption class=\"sr-only\">Connected players</caption><thead><tr><th scope=\"col\">#</th><th scope=\"col\">Name</th><th scope=\"col\">Ent</th><th scope=\"col\">Pos</th><th scope=\"col\">State</th></tr></thead><tbody>");
    var any = false;
    for (s.players) |p| {
        if (!p.used) continue;
        any = true;
        const nm = p.name[0..p.name_len];
        const st: []const u8 = if (p.entered) "entered" else if (p.joined) "joined" else "...";
        // Names are client-supplied (PlayerLogin); never interpolate raw into HTML.
        try w.print("<tr><td class=\"num\">{d}</td><td>", .{p.slot});
        try htmlEscape(&w, nm);
        try w.print(
            \\</td><td class="num">{d}</td><td class="num">{d:.0},{d:.0},{d:.0}</td><td>{s}</td></tr>
        , .{ p.entity_id, p.x, p.y, p.z, st });
    }
    if (!any) try w.writeAll("<tr><td colspan=\"5\" style=\"color:var(--muted)\">no players</td></tr>");
    try w.writeAll("</tbody></table>");
    return w.buffered();
}

fn us(ns: u64) u64 {
    return ns / 1000;
}
fn ms(ns: u64) u64 {
    return ns / 1_000_000;
}

fn renderApm(buf: []u8, s: *const Snapshot) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.print(
        \\<h3 style="margin:0 0 0.5rem;font-size:0.8rem;color:var(--muted)">Latency (tick budget 50 ms)</h3>
        \\<div class="grid">
        \\<div class="stat"><b class="num">{d} ms</b><span>tick mean</span></div>
        \\<div class="stat"><b class="num">{d} / {d} ms</b><span>tick p50 / p99</span></div>
        \\<div class="stat"><b class="num">{d} ms</b><span>tick max</span></div>
        \\<div class="stat"><b class="num">{d} / {d} us</b><span>net mean/p99</span></div>
        \\<div class="stat"><b class="num">{d} / {d} us</b><span>sim mean/p99</span></div>
        \\<div class="stat"><b class="num">{d} / {d} us</b><span>repl mean/p99</span></div>
        \\<div class="stat"><b class="num">{d} / {d} us</b><span>stream mean/p99</span></div>
        \\<div class="stat"><b class="num">{d} us</b><span>save mean</span></div>
        \\</div>
    , .{
        ms(s.tick_mean_ns),
        ms(s.tick_p50_ns),
        ms(s.tick_p99_ns),
        ms(s.tick_max_ns),
        us(s.net_mean_ns),
        us(s.net_p99_ns),
        us(s.sim_mean_ns),
        us(s.sim_p99_ns),
        us(s.repl_mean_ns),
        us(s.repl_p99_ns),
        us(s.stream_mean_ns),
        us(s.stream_p99_ns),
        us(s.save_mean_ns),
    });
    try w.print(
        \\<h3 style="margin:1rem 0 0.5rem;font-size:0.8rem;color:var(--muted)">Traffic</h3>
        \\<div class="grid">
        \\<div class="stat"><b class="num">{d}</b><span>pkt in</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>pkt out</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>bytes in</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>bytes out</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>pkg encoded</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>pkg broadcast</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>entities ticked</span></div>
        \\</div>
    , .{
        s.net_packets_in,
        s.net_packets_out,
        s.net_bytes_in,
        s.net_bytes_out,
        s.packages_encoded,
        s.packages_broadcast,
        s.entities_ticked,
    });
    try w.print(
        \\<h3 style="margin:1rem 0 0.5rem;font-size:0.8rem;color:var(--muted)">Errors / ops</h3>
        \\<div class="grid">
        \\<div class="stat"><b class="num">{d}/{d}</b><span>join ok/fail</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>tick overruns</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>encode err</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>stream err</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>net poll err</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>payload err</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>send err</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>window drops</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>persist err</span></div>
        \\<div class="stat"><b class="num">{d}</b><span>stale reaped</span></div>
        \\</div>
    , .{
        s.join_ok,
        s.join_fail,
        s.tick_overruns,
        s.encode_errors,
        s.stream_errors,
        s.net_poll_errors,
        s.net_payload_errors,
        s.net_send_errors,
        s.reliable_window_drops,
        s.persistence_errors,
        s.stale_peers_reaped,
    });
    return w.buffered();
}

fn renderApmJson(buf: []u8, s: *const Snapshot) ![]const u8 {
    // Writer.print allows more than 32 args across multiple calls (bufPrint is capped).
    var w: std.Io.Writer = .fixed(buf);
    try w.print(
        \\{{"type":"zdtd_webui_apm","tick":{d},"day":{d},"hours":{d:.2},"bm":{s},"joined":{d},"entered":{d},"peers":{d}
    , .{
        s.tick_n,
        s.day,
        s.hours,
        if (s.bloodmoon_active) "true" else "false",
        s.joined,
        s.entered,
        s.peers_alive,
    });
    try w.print(
        \\,"zombies":{d},"animals":{d},"traders":{d},"vehicles":{d},"turrets":{d},"loot":{d},"chunks":{d},"view_r":{d},"interest":{d:.0}
    , .{
        s.zombies,
        s.animals,
        s.traders,
        s.vehicles,
        s.turrets,
        s.loot_bags,
        s.chunks,
        s.view_radius,
        s.interest_range,
    });
    try w.print(
        \\,"pkt_in":{d},"pkt_out":{d},"bytes_in":{d},"bytes_out":{d},"tick_overruns":{d},"encode_errors":{d},"stream_errors":{d}
    , .{
        s.net_packets_in,
        s.net_packets_out,
        s.net_bytes_in,
        s.net_bytes_out,
        s.tick_overruns,
        s.encode_errors,
        s.stream_errors,
    });
    try w.print(
        \\,"net_poll_err":{d},"payload_err":{d},"send_err":{d},"window_drops":{d},"persist_err":{d},"stale_reaped":{d}
    , .{
        s.net_poll_errors,
        s.net_payload_errors,
        s.net_send_errors,
        s.reliable_window_drops,
        s.persistence_errors,
        s.stale_peers_reaped,
    });
    try w.print(
        \\,"tick_mean_ns":{d},"tick_p50_ns":{d},"tick_p99_ns":{d},"tick_max_ns":{d},"net_mean_ns":{d},"sim_mean_ns":{d},"repl_mean_ns":{d},"stream_mean_ns":{d}
    , .{
        s.tick_mean_ns,
        s.tick_p50_ns,
        s.tick_p99_ns,
        s.tick_max_ns,
        s.net_mean_ns,
        s.sim_mean_ns,
        s.repl_mean_ns,
        s.stream_mean_ns,
    });
    try w.print(
        \\,"join_ok":{d},"join_fail":{d},"pkg_enc":{d},"pkg_bc":{d},"info_port":{d},"auth":"{s}","password":"{s}"}}
        \\
    , .{
        s.join_ok,
        s.join_fail,
        s.packages_encoded,
        s.packages_broadcast,
        s.info_port,
        if (s.authority_correct) "correct" else "observe",
        if (s.password_set) "set" else "open",
    });
    return w.buffered();
}

test "parseIpv4 loopback and any" {
    try std.testing.expectEqual(@as(u32, 0x7f000001), try parseIpv4("127.0.0.1"));
    try std.testing.expectEqual(@as(u32, 0), try parseIpv4("0.0.0.0"));
}

test "pathOnly and queryToken" {
    try std.testing.expectEqualStrings("/foo", pathOnly("/foo?token=x"));
    try std.testing.expectEqualStrings("s3", queryToken("/login?token=s3").?);
}

test "requestAuthorized cookie and bearer" {
    const h1 = "GET / HTTP/1.1\r\nAuthorization: Bearer s3cr3t\r\n";
    try std.testing.expect(requestAuthorized(h1, "/", "s3cr3t"));
    var sess: [session_token_hex_len]u8 = undefined;
    fillSessionToken("s3cr3t", &sess);
    var h2buf: [160]u8 = undefined;
    const h2 = try std.fmt.bufPrint(&h2buf, "GET / HTTP/1.1\r\nCookie: zdtd_webui={s}; other=1\r\n", .{sess[0..]});
    try std.testing.expect(requestAuthorized(h2, "/", "s3cr3t"));
    try std.testing.expect(!requestAuthorized(h2, "/", "nope"));
    // Raw secret must not authenticate via cookie (session token only).
    const h3 = "GET / HTTP/1.1\r\nCookie: zdtd_webui=s3cr3t; other=1\r\n";
    try std.testing.expect(!requestAuthorized(h3, "/", "s3cr3t"));
}

test "fillSessionToken is deterministic and not the secret" {
    var a: [session_token_hex_len]u8 = undefined;
    var b: [session_token_hex_len]u8 = undefined;
    fillSessionToken("s3cr3t", &a);
    fillSessionToken("s3cr3t", &b);
    try std.testing.expectEqualSlices(u8, a[0..], b[0..]);
    try std.testing.expect(!std.mem.eql(u8, a[0..], "s3cr3t"));
    for (a) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(ok);
    }
}

test "request header authorization requires a valid credential" {
    const invalid = "POST /api/cmd HTTP/1.1\r\nAuthorization: Bearer wrong\r\n";
    try std.testing.expect(!requestHeaderAuthorized(invalid, "s3cr3t"));
    const valid = "POST /api/cmd HTTP/1.1\r\nX-Zdtd-Secret: s3cr3t\r\n";
    try std.testing.expect(requestHeaderAuthorized(valid, "s3cr3t"));
}

test "command content type accepts form parameters only" {
    try std.testing.expect(isFormContentType("application/x-www-form-urlencoded"));
    try std.testing.expect(isFormContentType("Application/X-WWW-Form-Urlencoded; charset=utf-8"));
    try std.testing.expect(!isFormContentType("application/json"));
    try std.testing.expect(!isFormContentType(null));
}

test "listen refuses empty secret" {
    var s: Server = .{};
    defer s.deinit();
    try std.testing.expectError(error.SecretRequired, s.listen(.{ .port = 1, .secret = "" }));
}

test "listen refuses header-injectable secret" {
    var s: Server = .{};
    defer s.deinit();
    try std.testing.expectError(error.SecretInvalid, s.listen(.{ .port = 1, .secret = "bad\r\nX:1" }));
    try std.testing.expectError(error.SecretInvalid, s.listen(.{ .port = 1, .secret = "has;semi" }));
}

test "render status fits buffer" {
    var s: Snapshot = .{ .tick_n = 42, .day = 3, .hours = 14.5, .joined = 2, .max_players = 8 };
    @memcpy(s.world_name[0..4], "test");
    s.world_name_len = 4;
    var buf: [4096]u8 = undefined;
    const html = try renderStatus(&buf, &s);
    try std.testing.expect(std.mem.indexOf(u8, html, "42") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "test") != null);
    const apm = try renderApm(&buf, &s);
    try std.testing.expect(std.mem.indexOf(u8, apm, "tick mean") != null);
    const js = try renderApmJson(&buf, &s);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"tick\":42") != null);
}

test "renderPlayers html-escapes client names" {
    var s: Snapshot = .{};
    s.players[0] = .{
        .used = true,
        .slot = 0,
        .entity_id = 1,
        .joined = true,
        .entered = true,
        .name_len = 15,
    };
    @memcpy(s.players[0].name[0..15], "<img onerror=1>");
    var buf: [2048]u8 = undefined;
    const html = try renderPlayers(&buf, &s);
    try std.testing.expect(std.mem.indexOf(u8, html, "<img") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;img") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<caption class=\"sr-only\">Connected players</caption>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<th scope=\"col\">Name</th>") != null);
}

const http_fuzz_corpus = [_][]const u8{
    "",
    "GET / HTTP/1.1\r\nHost: x\r\n\r\n",
    "POST /api/cmd?token=s3cr3t HTTP/1.1\r\nContent-Length: 6\r\nContent-Type: application/x-www-form-urlencoded\r\nCookie: zdtd_webui=abc; other=1\r\n\r\n",
    "GET /login?token=oops&x=1 HTTP/1.1\r\nAuthorization: Bearer s3cr3t\r\n\r\n",
    "GET / HTTP/1.1\r\nContent-Length: 99999999999999999999\r\n\r\n",
    "GET / HTTP/1.1\r\nX-Zdtd-Secret: s3cr3t\r\n\r\n",
    "cmd=say+hi&x=%41%zz%",
    "a=%%%&b=+++&&&=&cmd=%2",
    "GET /\rmalformed\nCookie: a\r\nContent-Length: -1\r\n\r\n",
    "Cookie: zdtd_webui\r\nCookie:\r\n: nokey\r\n\r\n",
    "255.255.255.255",
    "1.2.3.4.5",
};

test "fuzz http request helper parsers" {
    try std.testing.fuzz({}, fuzzHttpHelpers, .{ .corpus = &http_fuzz_corpus });
}

fn fuzzHttpHelpers(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [2048]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const head = storage[0..len];

    const path = pathOnly(head);
    try std.testing.expect(path.len <= @max(head.len, 1));
    _ = queryToken(head);
    _ = contentLength(head);
    _ = isFormContentType(headerValue(head, "Content-Type"));
    if (headerValue(head, "Cookie")) |ck| {
        if (cookieValue(ck, "zdtd_webui")) |cv| try std.testing.expect(cv.len <= head.len);
    }
    _ = requestAuthorized(head, head, "fuzz-secret-0123");
    _ = parseIpv4(head) catch 0;

    // formField/urlDecodeInPlace mutate the buffer; run them on copies.
    var form: [2048]u8 = undefined;
    @memcpy(form[0..len], head);
    if (formField(form[0..len], "cmd")) |v| {
        try std.testing.expect(v.len <= len);
    }
    var dec: [2048]u8 = undefined;
    @memcpy(dec[0..len], head);
    const decoded = urlDecodeInPlace(dec[0..len]);
    try std.testing.expect(decoded.len <= len);
}

test "renderShell exposes console names and status updates" {
    var buf: [16 * 1024]u8 = undefined;
    var sess: [session_token_hex_len]u8 = undefined;
    fillSessionToken("s3cr3t", &sess);
    const html = try renderShell(&buf, sess[0..]);
    try std.testing.expect(std.mem.indexOf(u8, html, "<label for=\"cmd-line\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "maxlength=\"256\" required") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"cmd-out\" role=\"status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"skip-link\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, ":focus-visible") != null);
    // Shared secret must not appear in HTML; CSRF uses session token only.
    try std.testing.expect(std.mem.indexOf(u8, html, "s3cr3t") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, sess[0..]) != null);
}
