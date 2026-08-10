//! Operator web UI HTTP listener (WU0–WU2: dashboard + console cmds).
//! Loopback by default; shared secret required when enabled.
//! Cookie/CSRF use an HMAC session token (shared secret stays off the wire cookie/HTML).
//! TCP: util/tcp_listen (std.Io.net). HTTP parse/respond: std.http.Server.
//! Polled from Game.step (non-blocking). Snapshot filled on main thread.
//! POST /api/cmd runs via admin_fn on the poll thread (same path as admin TCP).
//! Design: docs/WEBUI.md

const std = @import("std");
const http = std.http;
const tcp = @import("../util/tcp_listen.zig");
const constantTimeEql = @import("../util/secret.zig").constantTimeEql;
const version = @import("../version.zig");
const clock = @import("../util/clock.zig");

pub const max_req: usize = 8192;
pub const max_secret: usize = 128;
/// Minimum shared-secret length when webui is enabled (trivial secrets rejected).
pub const min_secret: usize = 8;
/// Hex length of HMAC-derived session token (cookie + CSRF; not the shared secret).
pub const session_token_hex_len: usize = 32;
/// One roster row per client slot: a 64-slot server must not hide the players
/// past the cap from the operator (both the HTML partial and the stats JSON
/// render a full roster inside the 16 KiB body buffer).
pub const max_players_snap: usize = @import("../litenet/server.zig").max_peers;
pub const max_name: usize = 32;
/// Max admin line from web console POST /api/cmd.
pub const max_cmd_line: usize = 256;
pub const max_cmd_out: usize = 4096;
pub const max_audit: usize = 24;
pub const max_audit_line: usize = 160;
/// Failed POST /login attempts before temporary lockout (brute-force throttle).
pub const login_fail_limit: u32 = 8;
/// Lockout duration after `login_fail_limit` bad tokens (mono ns).
pub const login_lockout_ns: u64 = 30 * std.time.ns_per_s;
/// Session cookie lifetime (seconds). Stolen cookies expire without process restart.
pub const session_cookie_max_age_s: u32 = 43_200;

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
    /// Monotonic time (clock.monoNs) of the last main-loop tick that refreshed
    /// this snapshot. Read from the webui poll thread; written from Game.step.
    last_tick_ns: u64 = 0,
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
    phase_rejects: u64 = 0,
    ownership_rejects: u64 = 0,
    bounds_rejects: u64 = 0,
    movement_rejects: u64 = 0,
    decode_rejects: u64 = 0,
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
    listener: tcp.Listener = .{},
    port: u16 = 0,
    bind_addr: u32 = 0x7f000001,
    secret_buf: [max_secret]u8 = undefined,
    secret_len: usize = 0,
    /// HMAC session material for cookie/CSRF (never the raw secret).
    session_token: [session_token_hex_len]u8 = undefined,
    /// Monotonic deadline for the current browser session. The cookie's
    /// Max-Age is not an authorization boundary because a stolen cookie can be
    /// replayed by a non-browser client after that client-side deadline.
    session_expires_ns: u64 = 0,
    client_fd: tcp.Handle = -1,
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
    /// POST /login brute-force throttle (process-local; single poll thread).
    login_fails: u32 = 0,
    /// Mono ns until which further login attempts are rejected (0 = unlocked).
    login_lock_until_ns: u64 = 0,
    /// When `client_fd < 0` (unit tests), the last response is copied here so
    /// assertions can check status lines without a real socket.
    test_resp_len: usize = 0,
    test_resp: [4096]u8 = undefined,

    pub fn enabled(self: *const Server) bool {
        return self.listener.enabled();
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
        self.audit_i = @intCast((@as(usize, self.audit_i) + 1) % max_audit);
        if (self.audit_n < max_audit) self.audit_n += 1;
    }

    pub fn listen(self: *Server, cfg: Config) !void {
        if (cfg.port == 0) return;
        if (cfg.secret.len == 0) return error.SecretRequired;
        if (cfg.secret.len < min_secret) return error.SecretTooShort;
        if (cfg.secret.len > max_secret) return error.SecretTooLong;
        // Secret may appear in Authorization / login query; reject control chars and
        // separators so operators cannot accidentally enable CR/LF header injection.
        if (!secretCharsetOk(cfg.secret)) return error.SecretInvalid;

        const addr_host = try parseIpv4(cfg.bind_host);
        if (!isLoopbackIpv4(addr_host)) return error.LoopbackRequired;
        try self.listener.listen(addr_host, cfg.port, 8);

        @memcpy(self.secret_buf[0..cfg.secret.len], cfg.secret);
        self.secret_len = cfg.secret.len;
        var nonce: [32]u8 = undefined;
        defer @memset(&nonce, 0);
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        threaded.io().random(&nonce);
        fillSessionToken(cfg.secret, &nonce, &self.session_token);
        self.session_expires_ns = 0;
        self.port = self.listener.port;
        self.bind_addr = addr_host;
        self.client_fd = -1;
        self.recv_len = 0;
    }

    pub fn deinit(self: *Server) void {
        if (self.client_fd >= 0) tcp.closeFd(self.client_fd);
        self.client_fd = -1;
        self.recv_len = 0;
        self.listener.deinit();
        self.port = 0;
        if (self.secret_len > 0) @memset(self.secret_buf[0..self.secret_len], 0);
        self.secret_len = 0;
        @memset(&self.session_token, 0);
        self.session_expires_ns = 0;
    }

    fn secret(self: *const Server) []const u8 {
        return self.secret_buf[0..self.secret_len];
    }

    fn sessionTok(self: *const Server) []const u8 {
        return self.session_token[0..];
    }

    fn sessionValid(self: *const Server) bool {
        // Zero keeps isolated unit fixtures that install a token directly
        // usable; production sessions always receive a deadline at login.
        return self.session_expires_ns == 0 or clock.monoNs() < self.session_expires_ns;
    }

    fn rotateSession(self: *Server) void {
        var nonce: [32]u8 = undefined;
        defer @memset(&nonce, 0);
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        threaded.io().random(&nonce);
        fillSessionToken(self.secret(), &nonce, &self.session_token);
        self.session_expires_ns = clock.monoNs() +% (@as(u64, session_cookie_max_age_s) * std.time.ns_per_s);
    }

    fn loginLocked(self: *const Server) bool {
        if (self.login_lock_until_ns == 0) return false;
        return clock.monoNs() < self.login_lock_until_ns;
    }

    fn noteLoginFailure(self: *Server) void {
        self.login_fails +|= 1;
        if (self.login_fails >= login_fail_limit) {
            self.login_lock_until_ns = clock.monoNs() +% login_lockout_ns;
            self.login_fails = 0;
            var ts: [19]u8 = undefined;
            std.debug.print("zdtd: {s} webui login lockout ({d} s)\n", .{ clock.wallStamp(&ts), login_lockout_ns / std.time.ns_per_s });
        }
    }

    /// Polls before an incomplete request is dropped (~10 s at 4 polls per
    /// 50 ms tick). Frees the single client slot from stalled/half-open peers.
    pub const max_client_polls: u32 = 800;

    pub fn poll(self: *Server) void {
        if (!self.listener.enabled()) return;
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
        const cfd = self.listener.accept() catch return orelse return;
        self.client_fd = cfd;
        self.client_polls = 0;
        self.recv_len = 0;
    }

    fn closeClient(self: *Server) void {
        if (self.client_fd >= 0) tcp.closeFd(self.client_fd);
        self.client_fd = -1;
        self.client_polls = 0;
        self.recv_len = 0;
        self.set_cookie = false;
    }

    fn readAndServe(self: *Server) void {
        const fd = self.client_fd;
        if (fd < 0) return;
        if (self.recv_len >= max_req) {
            self.closeClient();
            return;
        }
        const dst = self.recv_buf[self.recv_len..];
        const n = tcp.read(fd, dst) catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                self.closeClient();
                return;
            },
        };
        if (n == 0) {
            self.closeClient();
            return;
        }
        self.recv_len += n;

        // Wait until headers are complete before handing off to std.http.Server.
        const head_end = std.mem.find(u8, self.recv_buf[0..self.recv_len], "\r\n\r\n") orelse {
            if (self.recv_len >= max_req) self.closeClient();
            return;
        };
        // Pre-check Content-Length so we accumulate a full body (non-blocking poll).
        const clen = peekContentLength(self.recv_buf[0 .. head_end + 4]) catch |err| {
            // Match the real framing fault so clients/proxies can fix the request.
            const msg: []const u8 = switch (err) {
                error.UnsupportedTransferEncoding => "unsupported transfer encoding\n",
                error.DuplicateContentLength => "duplicate content length\n",
                error.InvalidContentLength => "invalid content length\n",
            };
            self.rawRespond(400, "text/plain; charset=utf-8", msg);
            self.closeClient();
            return;
        };
        // Checked add: huge Content-Length must not wrap `need` in ReleaseFast and
        // cause an incomplete request to be treated as complete.
        const prefix = head_end + 4;
        if (clen > max_req or prefix > max_req or clen > max_req - prefix) {
            self.rawRespond(413, "text/plain; charset=utf-8", "request too large\n");
            self.closeClient();
            return;
        }
        const need = prefix + clen;
        if (self.recv_len < need) return;

        self.serveHttp() catch |err| {
            std.debug.print("zdtd: webui request failed: {s}\n", .{@errorName(err)});
            self.rawRespond(500, "text/plain; charset=utf-8", "internal error\n");
        };
        self.closeClient();
    }

    /// Parse and respond with `std.http.Server` over the buffered request bytes.
    fn serveHttp(self: *Server) !void {
        var in_r: std.Io.Reader = .fixed(self.recv_buf[0..self.recv_len]);
        var out_buf: [49152]u8 = undefined;
        var out_w: std.Io.Writer = .fixed(&out_buf);
        var http_srv = http.Server.init(&in_r, &out_w);
        var req = http_srv.receiveHead() catch |err| {
            // A malformed request line / bad headers is a client fault (400/431),
            // never an internal error (500). Truncated or closing reads mean the
            // peer is gone; close without responding.
            switch (err) {
                error.HttpHeadersInvalid => self.rawRespond(400, "text/plain; charset=utf-8", "bad request\n"),
                error.HttpHeadersOversize => self.rawRespond(431, "text/plain; charset=utf-8", "request header fields too large\n"),
                else => {},
            }
            return;
        };

        const path = pathOnly(req.head.target);
        const method = req.head.method;

        if (std.mem.eql(u8, path, "/healthz")) {
            // HEAD for k8s/load-balancer probes (same status as GET; empty body).
            if (method != .GET and method != .HEAD) {
                try self.httpRespond(&req, .method_not_allowed, "text/plain; charset=utf-8", "method not allowed\n", &.{
                    .{ .name = "Allow", .value = "GET, HEAD" },
                });
                return;
            }
            const body_txt: []const u8 = if (method == .HEAD) "" else "ok\n";
            try self.httpRespond(&req, .ok, "text/plain; charset=utf-8", body_txt, &.{});
            return;
        }

        if (std.mem.eql(u8, path, "/readyz")) {
            if (method != .GET and method != .HEAD) {
                try self.httpRespond(&req, .method_not_allowed, "text/plain; charset=utf-8", "method not allowed\n", &.{
                    .{ .name = "Allow", .value = "GET, HEAD" },
                });
                return;
            }
            if (readinessStatus(&self.snap) == 503) {
                const body_txt: []const u8 = if (method == .HEAD) "" else "not ready\n";
                try self.httpRespond(&req, .service_unavailable, "text/plain; charset=utf-8", body_txt, &.{
                    .{ .name = "Retry-After", .value = "1" },
                });
            } else {
                const body_txt: []const u8 = if (method == .HEAD) "" else "ready\n";
                try self.httpRespond(&req, .ok, "text/plain; charset=utf-8", body_txt, &.{});
            }
            return;
        }

        // Body remains in recv_buf after receiveHead advanced the fixed reader.
        if (req.head.transfer_encoding != .none) {
            try self.httpRespond(&req, .bad_request, "text/plain; charset=utf-8", "unsupported transfer encoding\n", &.{});
            return;
        }
        const body = self.recv_buf[in_r.seek..in_r.end];

        if (std.mem.eql(u8, path, "/login")) {
            if (method == .GET) {
                // Already signed in (bookmark or reopened /login): go to dashboard.
                if (requestAuthorizedHttp(&req, self.secret(), self.sessionTok(), self.sessionValid())) {
                    try self.httpRedirect(&req, "/");
                    return;
                }
                // Show lockout on the form page so operators know why Sign in is refused.
                if (self.loginLocked()) {
                    try self.httpRespond(&req, .too_many_requests, "text/html; charset=utf-8", loginLockoutHtml(), &.{
                        .{ .name = "Retry-After", .value = "30" },
                    });
                } else {
                    try self.httpRespond(&req, .ok, "text/html; charset=utf-8", loginHintHtml(false), &.{});
                }
                return;
            }
            if (method == .POST) {
                if (!isFormContentType(req.head.content_type)) {
                    try self.httpRespond(&req, .unsupported_media_type, "text/plain; charset=utf-8", "expected application/x-www-form-urlencoded\n", &.{});
                    return;
                }
                if (self.loginLocked()) {
                    try self.httpRespond(&req, .too_many_requests, "text/html; charset=utf-8", loginLockoutHtml(), &.{
                        .{ .name = "Retry-After", .value = "30" },
                    });
                    return;
                }
                // Missing/empty token is a client error (400). Wrong secret is 401.
                const tok = formField(body, "token") orelse {
                    try self.httpRespond(&req, .bad_request, "text/html; charset=utf-8", loginHintHtml(true), &.{});
                    return;
                };
                if (tok.len == 0) {
                    try self.httpRespond(&req, .bad_request, "text/html; charset=utf-8", loginHintHtml(true), &.{});
                    return;
                }
                if (constantTimeEql(tok, self.secret())) {
                    self.login_fails = 0;
                    self.login_lock_until_ns = 0;
                    self.rotateSession();
                    self.set_cookie = true;
                    // Successes are as load-bearing as failures for an audit
                    // trail: /api/cmd runs privileged console lines under this
                    // session, and only this line dates the sign-in.
                    var ts: [19]u8 = undefined;
                    std.debug.print("zdtd: {s} webui login ok\n", .{clock.wallStamp(&ts)});
                    // 303 See Other: POST → GET dashboard (PRG; matches /logout).
                    try self.httpRedirect(&req, "/");
                    return;
                }
                self.noteLoginFailure();
                var ts: [19]u8 = undefined;
                std.debug.print("zdtd: {s} webui login rejected (bad token)\n", .{clock.wallStamp(&ts)});
                try self.httpRespond(&req, .unauthorized, "text/html; charset=utf-8", loginHintHtml(true), &.{});
                return;
            }
            try self.httpRespond(&req, .method_not_allowed, "text/plain; charset=utf-8", "method not allowed\n", &.{
                .{ .name = "Allow", .value = "GET, POST" },
            });
            return;
        }

        if (!requestAuthorizedHttp(&req, self.secret(), self.sessionTok(), self.sessionValid())) {
            // Count only explicit credential presentations (not bare anonymous GET).
            const presented = headerFromReq(&req, "Authorization") != null or headerFromReq(&req, "X-Zdtd-Secret") != null;
            if (presented) {
                if (self.loginLocked()) {
                    try self.httpRespond(&req, .too_many_requests, "text/plain; charset=utf-8", "too many failed sign-ins; try again shortly\n", &.{
                        .{ .name = "Retry-After", .value = "30" },
                    });
                    return;
                }
                self.noteLoginFailure();
                var ts: [19]u8 = undefined;
                std.debug.print("zdtd: {s} webui auth rejected (bad credential)\n", .{clock.wallStamp(&ts)});
            }
            if (std.mem.startsWith(u8, path, "/api/")) {
                // Machine clients: Bearer challenge + plain body (no HTML login form).
                try self.httpRespond(&req, .unauthorized, "text/plain; charset=utf-8", "unauthorized\n", &.{
                    .{ .name = "WWW-Authenticate", .value = "Bearer realm=\"zdtd-webui\"" },
                });
            } else {
                try self.httpRespond(&req, .unauthorized, "text/html; charset=utf-8", loginHintHtml(false), &.{});
            }
            return;
        }
        // Valid session/Bearer clears the fail counter (successful auth).
        self.login_fails = 0;

        if (std.mem.eql(u8, path, "/logout")) {
            if (method != .POST) {
                try self.httpRespond(&req, .method_not_allowed, "text/plain; charset=utf-8", "method not allowed\n", &.{
                    .{ .name = "Allow", .value = "POST" },
                });
                return;
            }
            if (!isFormContentType(req.head.content_type)) {
                try self.httpRespond(&req, .unsupported_media_type, "text/plain; charset=utf-8", "expected application/x-www-form-urlencoded\n", &.{});
                return;
            }
            // CSRF: session token (browser form) or shared secret (API tools), same as /api/cmd.
            const csrf = formField(body, "csrf") orelse {
                try self.httpRespond(&req, .forbidden, "text/plain; charset=utf-8", "sign-out request expired; return to the dashboard and try again\n", &.{});
                return;
            };
            const sess_ok = constantTimeEql(csrf, self.sessionTok());
            const secret_ok = constantTimeEql(csrf, self.secret());
            if (!sess_ok and !secret_ok) {
                try self.httpRespond(&req, .forbidden, "text/plain; charset=utf-8", "sign-out request expired; return to the dashboard and try again\n", &.{});
                return;
            }
            try self.httpLogout(&req);
            return;
        }

        // Shell HTML is the largest body; keep headroom for CSS/JS polish (poll path only).
        var body_buf: [16384]u8 = undefined;

        if (std.mem.eql(u8, path, "/api/cmd")) {
            if (method != .POST) {
                try self.httpRespond(&req, .method_not_allowed, "text/plain; charset=utf-8", "method not allowed\n", &.{
                    .{ .name = "Allow", .value = "POST" },
                });
                return;
            }
            try self.handleCmdPost(&req, body, &body_buf);
            return;
        }

        if (isGetOnlyPath(path)) {
            // HEAD works wherever GET does (RFC 9110); std.http elides the body.
            if (method != .GET and method != .HEAD) {
                try self.httpRespond(&req, .method_not_allowed, "text/plain; charset=utf-8", "method not allowed\n", &.{
                    .{ .name = "Allow", .value = "GET, HEAD" },
                });
                return;
            }
            if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
                try self.httpRespond(&req, .ok, "text/html; charset=utf-8", try renderShell(&body_buf, self.sessionTok()), &.{});
                return;
            }
            if (std.mem.eql(u8, path, "/partials/status")) {
                try self.httpRespond(&req, .ok, "text/html; charset=utf-8", try renderStatus(&body_buf, &self.snap), &.{});
                return;
            }
            if (std.mem.eql(u8, path, "/partials/players")) {
                try self.httpRespond(&req, .ok, "text/html; charset=utf-8", try renderPlayers(&body_buf, &self.snap), &.{});
                return;
            }
            if (std.mem.eql(u8, path, "/partials/apm")) {
                try self.httpRespond(&req, .ok, "text/html; charset=utf-8", try renderApm(&body_buf, &self.snap), &.{});
                return;
            }
            if (std.mem.eql(u8, path, "/partials/console")) {
                try self.httpRespond(&req, .ok, "text/html; charset=utf-8", try renderConsoleLog(&body_buf, self), &.{});
                return;
            }
            if (std.mem.eql(u8, path, "/api/apm.json")) {
                try self.httpRespond(&req, .ok, "application/json; charset=utf-8", try renderApmJson(&body_buf, &self.snap), &.{});
                return;
            }
        }

        try self.httpRespond(&req, .not_found, "text/plain; charset=utf-8", "not found\n", &.{});
    }

    fn handleCmdPost(self: *Server, req: *http.Server.Request, body: []u8, html_buf: []u8) !void {
        // Tools that send Accept: text/plain (or application/json) get plain bodies;
        // browser dashboard (no Accept preference) keeps HTML fragments.
        const plain = prefersPlainBody(req);

        if (!isFormContentType(req.head.content_type)) {
            try self.httpRespond(req, .unsupported_media_type, "text/plain; charset=utf-8", "expected application/x-www-form-urlencoded\n", &.{});
            return;
        }

        const csrf = formField(body, "csrf") orelse formField(body, "token");
        const has_valid_auth_header = requestHeaderAuthorizedHttp(req, self.secret());
        if (csrf) |c| {
            const sess_ok = constantTimeEql(c, self.sessionTok());
            const secret_ok = constantTimeEql(c, self.secret());
            if (!sess_ok and !secret_ok) {
                try self.cmdClientError(req, plain, .forbidden, "session expired or invalid; reload the dashboard and try again\n", "<pre class=\"err\">Session expired or invalid. Reload the dashboard and try again.</pre>\n");
                return;
            }
        } else if (!has_valid_auth_header) {
            try self.cmdClientError(req, plain, .forbidden, "missing security token; reload the dashboard and try again\n", "<pre class=\"err\">Missing security token. Reload the dashboard and try again.</pre>\n");
            return;
        }

        const raw_line = formField(body, "line") orelse formField(body, "cmd") orelse {
            try self.cmdClientError(req, plain, .bad_request, "enter a command in the line field\n", "<pre class=\"err\">Enter a command in the line field.</pre>\n");
            return;
        };
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0 or line.len > max_cmd_line or !adminLineOk(line)) {
            try self.cmdClientError(req, plain, .bad_request, "command is empty, too long, or contains invalid characters\n", "<pre class=\"err\">Command is empty, too long, or contains invalid characters.</pre>\n");
            return;
        }

        var reply_buf: [max_cmd_out]u8 = undefined;
        var reply_len: usize = 0;
        if (self.admin_fn) |f| {
            const ctx = self.admin_ctx orelse {
                try self.cmdClientError(req, plain, .service_unavailable, "console is temporarily unavailable; try again in a moment\n", "<pre class=\"err\">Console is temporarily unavailable. Try again in a moment.</pre>\n");
                return;
            };
            reply_len = f(ctx, line, &reply_buf);
        } else {
            // Single-slot queue full: rate-limit (429), not process-down (503).
            // Aligns with docs/WEBUI.md ("drop + 429 if full").
            if (!self.enqueueCmd(line)) {
                if (plain) {
                    try self.httpRespond(req, .too_many_requests, "text/plain; charset=utf-8", "server is busy; wait a moment and try again\n", &.{
                        .{ .name = "Retry-After", .value = "1" },
                    });
                } else {
                    try self.httpRespond(req, .too_many_requests, "text/html; charset=utf-8", "<pre class=\"err\">Server is busy. Wait a moment and try again.</pre>\n", &.{
                        .{ .name = "Retry-After", .value = "1" },
                    });
                }
                return;
            }
            if (plain) {
                var w: std.Io.Writer = .fixed(html_buf);
                try w.print("queued: {s}\n", .{line});
                try self.httpRespond(req, .ok, "text/plain; charset=utf-8", w.buffered(), &.{});
            } else {
                var w: std.Io.Writer = .fixed(html_buf);
                try w.writeAll("<pre class=\"ok\">queued: ");
                try htmlEscape(&w, line);
                try w.writeAll("</pre>\n");
                try self.httpRespond(req, .ok, "text/html; charset=utf-8", w.buffered(), &.{});
            }
            self.pushAudit(line);
            return;
        }

        const reply = if (reply_len > 0) reply_buf[0..reply_len] else "ok\n";
        var audit_line: [max_audit_line]u8 = undefined;
        const al = std.fmt.bufPrint(&audit_line, "> {s}", .{line}) catch line;
        self.pushAudit(al);
        if (reply_len > 0) {
            const first = std.mem.findScalar(u8, reply, '\n') orelse reply.len;
            self.pushAudit(reply[0..@min(first, max_audit_line)]);
        }

        // Semantic command failures stay HTTP 200 (console contract) but are
        // marked in HTML so the dashboard can style them as errors.
        if (plain) {
            try self.httpRespond(req, .ok, "text/plain; charset=utf-8", reply, &.{});
        } else {
            const html = try renderCmdReply(html_buf, line, reply);
            try self.httpRespond(req, .ok, "text/html; charset=utf-8", html, &.{});
        }
    }

    fn cmdClientError(
        self: *Server,
        req: *http.Server.Request,
        plain: bool,
        status: http.Status,
        plain_body: []const u8,
        html_body: []const u8,
    ) !void {
        if (plain) {
            try self.httpRespond(req, status, "text/plain; charset=utf-8", plain_body, &.{});
        } else {
            try self.httpRespond(req, status, "text/html; charset=utf-8", html_body, &.{});
        }
    }

    fn httpRespond(
        self: *Server,
        req: *http.Server.Request,
        status: http.Status,
        content_type: []const u8,
        body: []const u8,
        extra: []const http.Header,
    ) !void {
        var hdrs: [16]http.Header = undefined;
        var n: usize = 0;
        hdrs[n] = .{ .name = "Content-Type", .value = content_type };
        n += 1;
        hdrs[n] = .{ .name = "Cache-Control", .value = "no-store" };
        n += 1;
        hdrs[n] = .{ .name = "X-Content-Type-Options", .value = "nosniff" };
        n += 1;
        hdrs[n] = .{ .name = "X-Frame-Options", .value = "DENY" };
        n += 1;
        hdrs[n] = .{ .name = "Referrer-Policy", .value = "no-referrer" };
        n += 1;
        hdrs[n] = .{ .name = "Content-Security-Policy", .value = csp_policy };
        n += 1;
        hdrs[n] = .{ .name = "Permissions-Policy", .value = "camera=(), microphone=(), geolocation=()" };
        n += 1;
        hdrs[n] = .{ .name = "Connection", .value = "close" };
        n += 1;
        var cookie_val: [128]u8 = undefined;
        if (self.set_cookie) {
            const cv = try formatSessionCookie(&cookie_val, self.sessionTok());
            hdrs[n] = .{ .name = "Set-Cookie", .value = cv };
            n += 1;
        }
        for (extra) |h| {
            if (n >= hdrs.len) break;
            hdrs[n] = h;
            n += 1;
        }
        try req.respond(body, .{
            .status = status,
            .keep_alive = false,
            .extra_headers = hdrs[0..n],
        });
        self.flushHttpOut(req);
    }

    fn httpRedirect(self: *Server, req: *http.Server.Request, loc: []const u8) !void {
        var hdrs: [14]http.Header = undefined;
        var n: usize = 0;
        hdrs[n] = .{ .name = "Location", .value = loc };
        n += 1;
        hdrs[n] = .{ .name = "Cache-Control", .value = "no-store" };
        n += 1;
        hdrs[n] = .{ .name = "Connection", .value = "close" };
        n += 1;
        hdrs[n] = .{ .name = "X-Content-Type-Options", .value = "nosniff" };
        n += 1;
        hdrs[n] = .{ .name = "X-Frame-Options", .value = "DENY" };
        n += 1;
        hdrs[n] = .{ .name = "Referrer-Policy", .value = "no-referrer" };
        n += 1;
        hdrs[n] = .{ .name = "Content-Security-Policy", .value = csp_policy };
        n += 1;
        hdrs[n] = .{ .name = "Permissions-Policy", .value = "camera=(), microphone=(), geolocation=()" };
        n += 1;
        var cookie_val: [128]u8 = undefined;
        if (self.set_cookie) {
            const cv = try formatSessionCookie(&cookie_val, self.sessionTok());
            hdrs[n] = .{ .name = "Set-Cookie", .value = cv };
            n += 1;
        }
        // 303: always follow with GET (login POST must not be replayed on refresh).
        try req.respond("", .{
            .status = .see_other,
            .keep_alive = false,
            .extra_headers = hdrs[0..n],
        });
        self.flushHttpOut(req);
    }

    fn httpLogout(self: *Server, req: *http.Server.Request) !void {
        try req.respond("", .{
            .status = .see_other,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/login" },
                .{ .name = "Set-Cookie", .value = "zdtd_webui=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0" },
                .{ .name = "Connection", .value = "close" },
                .{ .name = "Cache-Control", .value = "no-store" },
                .{ .name = "X-Content-Type-Options", .value = "nosniff" },
                .{ .name = "X-Frame-Options", .value = "DENY" },
                .{ .name = "Referrer-Policy", .value = "no-referrer" },
                .{ .name = "Content-Security-Policy", .value = csp_policy },
                .{ .name = "Permissions-Policy", .value = "camera=(), microphone=(), geolocation=()" },
            },
        });
        self.flushHttpOut(req);
    }

    fn flushHttpOut(self: *Server, req: *http.Server.Request) void {
        const out = req.server.out.buffered();
        if (out.len == 0) return;
        const fd = self.client_fd;
        if (fd < 0) {
            self.captureTestResp(out);
            return;
        }
        tcp.writeAll(fd, out);
    }

    /// Fallback when http.Server is not yet set up (buffer overflow before parse).
    fn rawRespond(self: *Server, status: u16, content_type: []const u8, body: []const u8) void {
        var hdr: [640]u8 = undefined;
        const h = std.fmt.bufPrint(
            &hdr,
            "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: {s}\r\nPermissions-Policy: camera=(), microphone=(), geolocation=()\r\nConnection: close\r\n\r\n",
            .{ status, httpReasonPhrase(status), content_type, body.len, csp_policy },
        ) catch return;
        const fd = self.client_fd;
        if (fd < 0) {
            self.captureTestResp(h);
            self.captureTestResp(body);
            return;
        }
        tcp.writeAll(fd, h);
        tcp.writeAll(fd, body);
    }

    fn captureTestResp(self: *Server, data: []const u8) void {
        const space = self.test_resp.len - self.test_resp_len;
        const n = @min(data.len, space);
        if (n == 0) return;
        @memcpy(self.test_resp[self.test_resp_len..][0..n], data[0..n]);
        self.test_resp_len += n;
    }

    fn testResp(self: *const Server) []const u8 {
        return self.test_resp[0..self.test_resp_len];
    }
};

/// Inline CSS/JS dashboard; no third-party origins. form-action self for console POSTs.
const csp_policy =
    "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'";

/// Console lines must be single-line printable (no C0/DEL) so URL-decoded form
/// bodies cannot inject multi-line admin input or log-break sequences.
fn adminLineOk(line: []const u8) bool {
    for (line) |c| {
        if (c < 0x20 or c == 0x7f) return false;
    }
    return true;
}

/// RFC reason phrase for early raw responses (before std.http.Server is set up).
fn httpReasonPhrase(status: u16) []const u8 {
    return switch (status) {
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Content Too Large",
        415 => "Unsupported Media Type",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "Error",
    };
}

fn peekContentLength(head_with_crlf: []const u8) !usize {
    // head includes trailing \r\n\r\n
    if (headerValue(head_with_crlf, "Transfer-Encoding") != null)
        return error.UnsupportedTransferEncoding;
    // Line-based parse: a "content-length" substring inside a header value or
    // the request target must not set framing; duplicates are ambiguous (400).
    return (try validatedContentLength(head_with_crlf)) orelse 0;
}

fn headerFromReq(req: *const http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

fn requestAuthorizedHttp(req: *const http.Server.Request, secret: []const u8, session_token: []const u8, session_valid: bool) bool {
    if (secret.len == 0) return false;
    if (requestHeaderAuthorizedHttp(req, secret)) return true;
    if (session_valid) {
        if (headerFromReq(req, "Cookie")) |ck| {
            if (cookieValue(ck, "zdtd_webui")) |cv| {
                if (constantTimeEql(cv, session_token)) return true;
            }
        }
    }
    return false;
}

fn requestHeaderAuthorizedHttp(req: *const http.Server.Request, secret: []const u8) bool {
    if (secret.len == 0) return false;
    if (headerFromReq(req, "Authorization")) |auth| {
        if (bearerToken(auth)) |token|
            if (constantTimeEql(token, secret)) return true;
    }
    if (headerFromReq(req, "X-Zdtd-Secret")) |v| {
        if (constantTimeEql(std.mem.trim(u8, v, " \t"), secret)) return true;
    }
    return false;
}

fn isGetOnlyPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/") or
        std.mem.eql(u8, path, "/index.html") or
        std.mem.eql(u8, path, "/partials/status") or
        std.mem.eql(u8, path, "/partials/players") or
        std.mem.eql(u8, path, "/partials/apm") or
        std.mem.eql(u8, path, "/partials/console") or
        std.mem.eql(u8, path, "/api/apm.json");
}

/// 30 s without a main-loop tick means the sim loop is wedged (blocked poll,
/// deadlocked flush, debugger attach): the webui thread keeps serving, so a
/// stale tick is the only signal the game is not actually advancing. Generous:
/// a periodic save-all on a large overlay can take seconds, never this long.
const readiness_stale_ns: u64 = 30 * std.time.ns_per_s;

fn readinessStatus(s: *const Snapshot) u16 {
    if (s.tick_n == 0) return 503; // pre-first-tick startup: not ready yet
    if (clock.monoNs() -% s.last_tick_ns > readiness_stale_ns) return 503;
    return 200;
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
    if (std.mem.findScalar(u8, target, '?')) |q| return target[0..q];
    return target;
}

fn validatedContentLength(head: []const u8) !?usize {
    var found: ?usize = null;
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next();
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "Content-Length")) continue;
        if (found != null) return error.DuplicateContentLength;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len == 0) return error.InvalidContentLength;
        found = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
    }
    return found;
}

fn isFormContentType(value: ?[]const u8) bool {
    const raw = value orelse return false;
    const semicolon = std.mem.findScalar(u8, raw, ';') orelse raw.len;
    const media_type = std.mem.trim(u8, raw[0..semicolon], " \t");
    return std.ascii.eqlIgnoreCase(media_type, "application/x-www-form-urlencoded");
}

fn formField(body: []u8, name: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (start <= body.len) {
        const amp = std.mem.findScalar(u8, body[start..], '&') orelse body.len - start;
        const pair = body[start .. start + amp];
        const eq = std.mem.findScalar(u8, pair, '=') orelse {
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

/// True when the client asks for a machine-readable body (scripts / curl).
/// Browsers typically send `*/*` or omit Accept; those keep HTML fragments.
fn prefersPlainBody(req: *const http.Server.Request) bool {
    const accept = headerFromReq(req, "Accept") orelse return false;
    // Explicit HTML wins (dashboards that set Accept).
    if (mediaTypePresent(accept, "text/html")) return false;
    return mediaTypePresent(accept, "text/plain") or mediaTypePresent(accept, "application/json");
}

fn mediaTypePresent(accept: []const u8, media: []const u8) bool {
    var it = std.mem.splitScalar(u8, accept, ',');
    while (it.next()) |part| {
        const raw = std.mem.trim(u8, part, " \t");
        const semi = std.mem.findScalar(u8, raw, ';') orelse raw.len;
        const mt = std.mem.trim(u8, raw[0..semi], " \t");
        if (std.ascii.eqlIgnoreCase(mt, media)) return true;
    }
    return false;
}

/// First-line prefixes used by Game.runAdminLine for operator-visible failures.
fn adminReplyLooksFailed(reply: []const u8) bool {
    const first = std.mem.findScalar(u8, reply, '\n') orelse reply.len;
    const line = std.mem.trimEnd(u8, reply[0..first], " \t\r");
    const prefixes = [_][]const u8{
        // Stock console error shapes (SdtdConsole::executeCommand, asm.il:269448;
        // the per-command arity/validation errors). Keep in sync with the
        // .unknown / .err_text / .wrong_args arms of Game.runAdminLine.
        "*** ERROR:",
        "Wrong number of arguments,",
        "Invalid sub command",
        "No sub command given.",
        "Day must be",
        "Hour must be",
        "Minute must be",
        "Invalid value for single argument variant:",
        "unknown command",
        "bad arguments",
        "no player",
        "give failed",
        "teleport encode failed",
        "teleport send failed",
        "unknown entity class",
        "spawn failed",
        "kill missed",
        "no inventory",
        "wipe failed",
        "save failed",
        "world save failed",
        "apm dump empty",
    };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, line, p)) return true;
    }
    return false;
}

fn renderCmdReply(buf: []u8, line: []const u8, reply: []const u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    // tabindex so keyboard users can scroll overflow (max-height); WCAG 2.1.1.
    // No aria-label here: the pre is injected into the #cmd-out polite live
    // region, and an explicit label would replace the actual command output in
    // the region's text alternative (screen readers would hear "Command result"
    // instead of the reply). The pre's text content is its accessible name.
    // class=err when the admin reply is a known failure string (still HTTP 200).
    if (adminReplyLooksFailed(reply)) {
        // The stable #cmd-out container becomes the alert after insertion.
        // Keeping the role off this child avoids nested live regions and
        // duplicate screen-reader announcements.
        try w.writeAll("<pre class=\"cmd-out err\" tabindex=\"0\" data-command-error=\"true\"><span class=\"in\">&gt; ");
    } else {
        try w.writeAll("<pre class=\"cmd-out\" tabindex=\"0\"><span class=\"in\">&gt; ");
    }
    try htmlEscape(&w, line);
    try w.writeAll("</span>\n");
    try htmlEscape(&w, reply);
    try w.writeAll("</pre>");
    return w.buffered();
}

fn renderConsoleLog(buf: []u8, s: *const Server) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    // The stable outer region owns focus so polling cannot discard it; tabindex
    // here because this pre is the scroll container (max-height) and a
    // keyboard-only operator must be able to scroll the history (WCAG 2.1.1).
    try w.writeAll("<pre class=\"cmd-log\" tabindex=\"0\">");
    if (s.audit_n == 0) {
        try w.writeAll("<span class=\"meta\">No commands run yet. Enter a command above and choose Run.</span>");
    } else {
        const n: usize = s.audit_n;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const idx = (@as(usize, s.audit_i) + max_audit - n + k) % max_audit;
            const len = s.audit_lens[idx];
            const line = s.audit_lines[idx][0..len];
            // Match cmd-out failure styling so history is scannable for errors.
            if (adminReplyLooksFailed(line)) {
                try w.writeAll("<span class=\"err\">");
                try htmlEscape(&w, line);
                try w.writeAll("</span>\n");
            } else {
                try htmlEscape(&w, line);
                try w.writeAll("\n");
            }
        }
    }
    try w.writeAll("</pre>");
    return w.buffered();
}

/// HMAC-SHA256(secret, fresh process nonce) → first 16 bytes as hex (32 chars).
/// Cookie and CSRF use this so the shared secret is not stored in browser storage/HTML,
/// and old cookies stop working whenever the listener restarts.
fn fillSessionToken(secret: []const u8, nonce: []const u8, out: *[session_token_hex_len]u8) void {
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, nonce, secret);
    // Leading half of the HMAC; the token is an opaque cookie, not a MAC to verify.
    out.* = std.fmt.bytesToHex(mac[0 .. session_token_hex_len / 2].*, .lower);
}

fn isLoopbackIpv4(ip: u32) bool {
    return ip & 0xff000000 == 0x7f000000;
}

fn requestAuthorized(head: []const u8, secret: []const u8, session_token: []const u8) bool {
    if (secret.len == 0) return false;
    if (requestHeaderAuthorized(head, secret)) return true;
    if (headerValue(head, "Cookie")) |ck| {
        if (cookieValue(ck, "zdtd_webui")) |cv| {
            // Session cookie only; raw secret in Cookie is rejected (not in HTML/cookie).
            if (constantTimeEql(cv, session_token)) return true;
        }
    }
    return false;
}

fn requestHeaderAuthorized(head: []const u8, secret: []const u8) bool {
    if (secret.len == 0) return false;
    if (headerValue(head, "Authorization")) |auth| {
        if (bearerToken(auth)) |token|
            if (constantTimeEql(token, secret)) return true;
    }
    if (headerValue(head, "X-Zdtd-Secret")) |v| {
        if (constantTimeEql(std.mem.trim(u8, v, " \t"), secret)) return true;
    }
    return false;
}

fn bearerToken(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    const separator = std.mem.findScalar(u8, trimmed, ' ') orelse return null;
    if (!std.ascii.eqlIgnoreCase(trimmed[0..separator], "Bearer")) return null;
    const token = std.mem.trim(u8, trimmed[separator + 1 ..], " \t");
    return if (token.len == 0) null else token;
}

fn formatSessionCookie(buf: []u8, token: []const u8) error{Overflow}![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "zdtd_webui={s}; Path=/; HttpOnly; SameSite=Strict; Max-Age={d}",
        .{ token, session_cookie_max_age_s },
    ) catch return error.Overflow;
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
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
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

/// The three login pages and the dashboard shell live under `assets/webui/` as
/// real HTML files and are embedded at compile time, so they stay editable (and
/// openable in a browser) instead of being escaped Zig string literals. Nothing
/// is read from disk at runtime: the bytes are in the binary.
///
/// Zig multiline literals carry no trailing newline, so trim the file's to keep
/// the served bytes identical to what the inline literals produced.
fn embedTrimmed(comptime path: []const u8) []const u8 {
    const raw = @embedFile(path);
    return comptime if (raw.len > 0 and raw[raw.len - 1] == '\n') raw[0 .. raw.len - 1] else raw;
}

const login_html = embedTrimmed("webui/login.html");
const login_failed_html = embedTrimmed("webui/login_failed.html");
const login_lockout_html = embedTrimmed("webui/login_lockout.html");
const shell_html = embedTrimmed("webui/shell.html");

fn loginHintHtml(bad_token: bool) []const u8 {
    return if (bad_token) login_failed_html else login_html;
}

/// Temporary lockout after too many failed sign-ins (same form chrome as login).
fn loginLockoutHtml() []const u8 {
    return login_lockout_html;
}

const Subst = struct { key: []const u8, val: []const u8 };

/// Copy `src` into `buf`, replacing each `__ZDTD_*__` placeholder with its
/// value. The templates use named placeholders rather than `{s}` so the CSS and
/// JS can keep literal braces instead of doubling every one of them.
///
/// One forward pass: placeholders are literal ASCII and never nest, and a
/// substituted value is never rescanned, so a value containing a placeholder
/// cannot inject another. An unknown `__ZDTD_` run is copied through rather than
/// dropped, so a template typo is visible on the page instead of vanishing.
fn renderTemplate(buf: []u8, src: []const u8, subs: []const Subst) ![]const u8 {
    var w: usize = 0;
    var i: usize = 0;
    outer: while (i < src.len) {
        if (src[i] == '_' and std.mem.startsWith(u8, src[i..], "__ZDTD_")) {
            for (subs) |sub| {
                if (!std.mem.startsWith(u8, src[i..], sub.key)) continue;
                if (w + sub.val.len > buf.len) return error.NoSpaceLeft;
                @memcpy(buf[w..][0..sub.val.len], sub.val);
                w += sub.val.len;
                i += sub.key.len;
                continue :outer;
            }
        }
        if (w >= buf.len) return error.NoSpaceLeft;
        buf[w] = src[i];
        w += 1;
        i += 1;
    }
    return buf[0..w];
}

test "shell template substitutes every placeholder" {
    var buf: [64 * 1024]u8 = undefined;
    const out = try renderShell(&buf, "deadbeef");
    // A missed placeholder would ship "__ZDTD_CSRF__" to the browser and break
    // the logout form, which no other test would notice.
    try std.testing.expect(std.mem.find(u8, out, "__ZDTD_") == null);
    try std.testing.expect(std.mem.find(u8, out, "value=\"deadbeef\"") != null);
    try std.testing.expect(std.mem.find(u8, out, version.product) != null);
}

test "renderTemplate reports a buffer too small instead of truncating" {
    var small: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, renderShell(&small, "x"));
}

test "renderTemplate leaves an unknown placeholder in place" {
    var buf: [64]u8 = undefined;
    const out = try renderTemplate(&buf, "a __ZDTD_NOPE__ b", &.{});
    try std.testing.expectEqualStrings("a __ZDTD_NOPE__ b", out);
}

/// `csrf_token` must be the HMAC session token (not the shared secret).
fn renderShell(buf: []u8, csrf_token: []const u8) ![]const u8 {
    return renderTemplate(buf, shell_html, &.{
        .{ .key = "__ZDTD_PRODUCT__", .val = version.product },
        .{ .key = "__ZDTD_STOCK_WIRE__", .val = version.stock_wire },
        .{ .key = "__ZDTD_CSRF__", .val = csrf_token },
    });
}

fn renderStatus(buf: []u8, s: *const Snapshot) ![]const u8 {
    const wn = s.world_name[0..s.world_name_len];
    const hh: u32 = @floor(s.hours);
    const mm: u32 = @floor((s.hours - @as(f32, @floatFromInt(hh))) * 60.0);
    const bm: []const u8 = if (s.bloodmoon_active) "<span class=\"warn-text\">ACTIVE</span>" else "idle";
    const auth: []const u8 = if (s.authority_correct) "correct" else "observe";
    // HTML display only (JSON keeps "set"/"open" for tool stability).
    const pw: []const u8 = if (s.password_set) "set" else "not set";
    const wc: []const u8 = if (s.wire_chunks) "on" else "off";
    const overrun_cls: []const u8 = if (s.tick_overruns > 0) "num warn-text" else "num";
    var w: std.Io.Writer = .fixed(buf);
    try w.print(
        \\<ul class="grid">
        \\<li class="stat"><b class="num">{d}</b><span>server tick</span></li>
        \\<li class="stat"><b class="num">d{d} {d:0>2}:{d:0>2}</b><span>world time</span></li>
        \\<li class="stat"><b>{s}</b><span>blood moon (every {d}d)</span></li>
        \\<li class="stat"><b class="num">{d}/{d}</b><span>joined / max</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>entered world</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>peers connected</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>chunks in memory</span></li>
        \\<li class="stat"><b class="{s}">{d}</b><span>tick overruns</span></li>
        \\</ul>
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
        overrun_cls,
        s.tick_overruns,
    });
    try w.print(
        \\<h3>Entities</h3>
        \\<ul class="grid">
        \\<li class="stat"><b class="num">{d}/{d}</b><span>zombies / cap</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>animals</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>player entities</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>traders</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>vehicles</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>turrets</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>loot bags</span></li>
        \\</ul>
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
        \\<h3>Server</h3>
        \\<ul class="grid">
        \\<li class="stat"><b>
    );
    // World names come from config/CLI; still escape so a crafted path cannot break HTML.
    if (wn.len == 0) {
        try w.writeAll("<span class=\"meta\">(unnamed)</span>");
    } else {
        try htmlEscape(&w, wn);
    }
    try w.print(
        \\</b><span>world</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>info port</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>game port</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>webui port</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>view radius</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>max streamed chunks</span></li>
        \\<li class="stat"><b class="num">{d:.0}</b><span>interest range (m)</span></li>
        \\<li class="stat"><b class="num">{d:.0}</b><span>edit range (m)</span></li>
        \\<li class="stat"><b>{s}</b><span>authority mode</span></li>
        \\<li class="stat"><b>{s}</b><span>password</span></li>
        \\<li class="stat"><b>{s}</b><span>chunk streaming</span></li>
        \\</ul>
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
    try w.writeAll("<table><caption class=\"sr-only\">Connected players</caption><thead><tr><th scope=\"col\">Slot</th><th scope=\"col\">Name</th><th scope=\"col\">Entity ID</th><th scope=\"col\">Position</th><th scope=\"col\">State</th></tr></thead><tbody>");
    var any = false;
    for (s.players) |p| {
        if (!p.used) continue;
        any = true;
        const nm = p.name[0..p.name_len];
        const st: []const u8 = if (p.entered) "in world" else if (p.joined) "joined" else "connecting";
        // Names are client-supplied (PlayerLogin); never interpolate raw into HTML.
        try w.print("<tr><td class=\"num\">{d}</td><th scope=\"row\">", .{p.slot});
        try htmlEscape(&w, nm);
        try w.print(
            \\</th><td class="num">{d}</td><td class="num">{d:.0},{d:.0},{d:.0}</td><td>{s}</td></tr>
        , .{ p.entity_id, p.x, p.y, p.z, st });
    }
    if (!any) try w.writeAll("<tr><td colspan=\"5\" style=\"color:var(--muted)\">No players are connected. They appear here when clients join.</td></tr>");
    try w.writeAll("</tbody></table>");
    return w.buffered();
}

fn us(ns: u64) u64 {
    return ns / 1000;
}
fn ms(ns: u64) u64 {
    return ns / 1_000_000;
}

/// Class for a counter value: neutral when zero, warn/err when non-zero so
/// operators can scan the grid for problems without reading every label.
fn alertNumClass(n: u64, severe: bool) []const u8 {
    if (n == 0) return "num";
    return if (severe) "num err" else "num warn-text";
}

fn renderApm(buf: []u8, s: *const Snapshot) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    // Tick budget is 50 ms (20 TPS). Flag p99/max when they breach it.
    const tick_budget_ns: u64 = 50 * std.time.ns_per_ms;
    const p99_cls: []const u8 = if (s.tick_p99_ns > tick_budget_ns) "num warn-text" else "num";
    const max_cls: []const u8 = if (s.tick_max_ns > tick_budget_ns) "num warn-text" else "num";
    try w.print(
        \\<h3 style="margin-top:0">Latency (tick budget 50 ms)</h3>
        \\<ul class="grid">
        \\<li class="stat"><b class="num">{d} ms</b><span>tick mean</span></li>
        \\<li class="stat"><b class="{s}">{d} / {d} ms</b><span>tick p50 / p99</span></li>
        \\<li class="stat"><b class="{s}">{d} ms</b><span>tick max</span></li>
        \\<li class="stat"><b class="num">{d} / {d} µs</b><span>net mean / p99</span></li>
        \\<li class="stat"><b class="num">{d} / {d} µs</b><span>sim mean / p99</span></li>
        \\<li class="stat"><b class="num">{d} / {d} µs</b><span>replicate mean / p99</span></li>
        \\<li class="stat"><b class="num">{d} / {d} µs</b><span>stream mean / p99</span></li>
        \\<li class="stat"><b class="num">{d} µs</b><span>save mean</span></li>
        \\</ul>
    , .{
        ms(s.tick_mean_ns),
        p99_cls,
        ms(s.tick_p50_ns),
        ms(s.tick_p99_ns),
        max_cls,
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
        \\<h3>Traffic</h3>
        \\<ul class="grid">
        \\<li class="stat"><b class="num">{d}</b><span>packets in</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>packets out</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>bytes in</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>bytes out</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>packages encoded</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>packages sent</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>entities ticked</span></li>
        \\</ul>
    , .{
        s.net_packets_in,
        s.net_packets_out,
        s.net_bytes_in,
        s.net_bytes_out,
        s.packages_encoded,
        s.packages_broadcast,
        s.entities_ticked,
    });
    const join_cls = alertNumClass(s.join_fail, true);
    try w.print(
        \\<h3>Errors and rejections</h3>
        \\<ul class="grid">
        \\<li class="stat"><b class="{s}">{d}/{d}</b><span>join ok / fail</span></li>
        \\<li class="stat"><b class="{s}">{d}</b><span>tick overruns</span></li>
        \\<li class="stat"><b class="{s}">{d}</b><span>encode errors</span></li>
        \\<li class="stat"><b class="{s}">{d}</b><span>stream errors</span></li>
        \\<li class="stat"><b class="{s}">{d}</b><span>net poll errors</span></li>
        \\<li class="stat"><b class="{s}">{d}</b><span>payload errors</span></li>
        \\<li class="stat"><b class="{s}">{d}</b><span>send errors</span></li>
        \\<li class="stat"><b class="{s}">{d}</b><span>window drops</span></li>
        \\<li class="stat"><b class="{s}">{d}</b><span>persist errors</span></li>
        \\<li class="stat"><b class="{s}">{d}</b><span>stale peers reaped</span></li>
        \\<li class="stat"><b class="{s}">{d}</b><span>phase rejects</span></li>
        \\<li class="stat"><b class="{s}">{d}</b><span>ownership rejects</span></li>
        \\<li class="stat"><b class="{s}">{d}</b><span>bounds rejects</span></li>
        \\<li class="stat"><b class="{s}">{d}</b><span>movement rejects</span></li>
        \\<li class="stat"><b class="{s}">{d}</b><span>decode rejects</span></li>
        \\</ul>
    , .{
        join_cls,
        s.join_ok,
        s.join_fail,
        alertNumClass(s.tick_overruns, false),
        s.tick_overruns,
        alertNumClass(s.encode_errors, true),
        s.encode_errors,
        alertNumClass(s.stream_errors, true),
        s.stream_errors,
        alertNumClass(s.net_poll_errors, true),
        s.net_poll_errors,
        alertNumClass(s.net_payload_errors, true),
        s.net_payload_errors,
        alertNumClass(s.net_send_errors, true),
        s.net_send_errors,
        alertNumClass(s.reliable_window_drops, false),
        s.reliable_window_drops,
        alertNumClass(s.persistence_errors, true),
        s.persistence_errors,
        alertNumClass(s.stale_peers_reaped, false),
        s.stale_peers_reaped,
        alertNumClass(s.phase_rejects, false),
        s.phase_rejects,
        alertNumClass(s.ownership_rejects, false),
        s.ownership_rejects,
        alertNumClass(s.bounds_rejects, false),
        s.bounds_rejects,
        alertNumClass(s.movement_rejects, false),
        s.movement_rejects,
        alertNumClass(s.decode_rejects, false),
        s.decode_rejects,
    });
    return w.buffered();
}

fn jsonEscapeWrite(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
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
        \\,"net_p99_ns":{d},"sim_p99_ns":{d},"repl_p99_ns":{d},"stream_p99_ns":{d},"save_mean_ns":{d}
    , .{
        s.net_p99_ns,
        s.sim_p99_ns,
        s.repl_p99_ns,
        s.stream_p99_ns,
        s.save_mean_ns,
    });
    try w.print(
        \\,"join_ok":{d},"join_fail":{d},"pkg_enc":{d},"pkg_bc":{d},"max_players":{d},"info_port":{d},"webui_port":{d},"auth":"{s}","password":"{s}","wire_chunks":{s}
    , .{
        s.join_ok,
        s.join_fail,
        s.packages_encoded,
        s.packages_broadcast,
        s.max_players,
        s.info_port,
        s.webui_port,
        if (s.authority_correct) "correct" else "observe",
        if (s.password_set) "set" else "open",
        if (s.wire_chunks) "true" else "false",
    });
    // World name (same snapshot as status partial; escaped for JSON string safety).
    try w.writeAll(",\"world\":\"");
    try jsonEscapeWrite(&w, s.world_name[0..s.world_name_len]);
    try w.writeAll("\"");
    // Same reject counters as HTML Errors panel / guardstats (tools use this JSON).
    try w.print(
        \\,"phase_rejects":{d},"ownership_rejects":{d},"bounds_rejects":{d},"movement_rejects":{d},"decode_rejects":{d}
    , .{
        s.phase_rejects,
        s.ownership_rejects,
        s.bounds_rejects,
        s.movement_rejects,
        s.decode_rejects,
    });
    // Compact player roster so tools need not scrape HTML partials.
    try w.writeAll(",\"players\":[");
    var first_player = true;
    for (s.players) |p| {
        if (!p.used) continue;
        if (!first_player) try w.writeAll(",");
        first_player = false;
        try w.print(
            \\{{"slot":{d},"entity_id":{d},"joined":{s},"entered":{s},"x":{d:.1},"y":{d:.1},"z":{d:.1},"name":"
        , .{
            p.slot,
            p.entity_id,
            if (p.joined) "true" else "false",
            if (p.entered) "true" else "false",
            p.x,
            p.y,
            p.z,
        });
        try jsonEscapeWrite(&w, p.name[0..p.name_len]);
        try w.writeAll("\"}");
    }
    try w.writeAll("]}\n");
    return w.buffered();
}

test "parseIpv4 loopback and any" {
    try std.testing.expectEqual(@as(u32, 0x7f000001), try parseIpv4("127.0.0.1"));
    try std.testing.expectEqual(@as(u32, 0), try parseIpv4("0.0.0.0"));
}

test "pathOnly strips query without treating it as credentials" {
    try std.testing.expectEqualStrings("/foo", pathOnly("/foo?token=x"));
}

test "webui IPv4 binding is loopback only" {
    try std.testing.expect(isLoopbackIpv4(try parseIpv4("127.0.0.1")));
    try std.testing.expect(isLoopbackIpv4(try parseIpv4("127.2.3.4")));
    try std.testing.expect(!isLoopbackIpv4(try parseIpv4("0.0.0.0")));
    try std.testing.expect(!isLoopbackIpv4(try parseIpv4("192.168.1.2")));
}

test "isGetOnlyPath known dashboard routes" {
    try std.testing.expect(isGetOnlyPath("/"));
    try std.testing.expect(isGetOnlyPath("/api/apm.json"));
    try std.testing.expect(isGetOnlyPath("/partials/status"));
    try std.testing.expect(!isGetOnlyPath("/api/cmd"));
    try std.testing.expect(!isGetOnlyPath("/logout"));
    try std.testing.expect(!isGetOnlyPath("/nope"));
}

test "readiness waits for first live snapshot" {
    var s: Snapshot = .{};
    try std.testing.expectEqual(@as(u16, 503), readinessStatus(&s));
    s.tick_n = 1;
    s.last_tick_ns = clock.monoNs(); // fresh snapshot: ready
    try std.testing.expectEqual(@as(u16, 200), readinessStatus(&s));
}

test "readiness goes stale when the sim loop wedges" {
    var s: Snapshot = .{ .tick_n = 100, .last_tick_ns = clock.monoNs() };
    // One threshold later, the webui thread still serves but the game has not
    // advanced a tick: orchestrators must drain/restart instead of trusting 200.
    s.last_tick_ns = clock.monoNs() -% (readiness_stale_ns + 1);
    try std.testing.expectEqual(@as(u16, 503), readinessStatus(&s));
    s.last_tick_ns = clock.monoNs();
    try std.testing.expectEqual(@as(u16, 200), readinessStatus(&s));
}

test "requestAuthorized cookie and bearer" {
    const nonce = [_]u8{0x5a} ** 32;
    var sess: [session_token_hex_len]u8 = undefined;
    fillSessionToken("s3cr3t", &nonce, &sess);
    const h1 = "GET / HTTP/1.1\r\nAuthorization: Bearer s3cr3t\r\n";
    try std.testing.expect(requestAuthorized(h1, "s3cr3t", &sess));
    var h2buf: [160]u8 = undefined;
    const h2 = try std.fmt.bufPrint(&h2buf, "GET / HTTP/1.1\r\nCookie: zdtd_webui={s}; other=1\r\n", .{sess[0..]});
    try std.testing.expect(requestAuthorized(h2, "s3cr3t", &sess));
    try std.testing.expect(!requestAuthorized(h2, "nope", "wrong-session"));
    // Raw secret must not authenticate via cookie (session token only).
    const h3 = "GET / HTTP/1.1\r\nCookie: zdtd_webui=s3cr3t; other=1\r\n";
    try std.testing.expect(!requestAuthorized(h3, "s3cr3t", &sess));
    // Query credentials are accepted only by the dedicated /login route.
    const h4 = "GET /api/apm.json?token=s3cr3t HTTP/1.1\r\n";
    try std.testing.expect(!requestAuthorized(h4, "s3cr3t", &sess));
}

/// Test helper: load a complete HTTP/1.1 request into recv_buf and run std.http path.
fn testServeHttp(s: *Server, request: []const u8) !void {
    if (request.len > s.recv_buf.len) return error.Overflow;
    @memcpy(s.recv_buf[0..request.len], request);
    s.recv_len = request.len;
    s.client_fd = -1; // no socket write; response is captured into test_resp
    s.test_resp_len = 0;
    try s.serveHttp();
}

test "POST /login sets session cookie only on valid token" {
    var s: Server = .{};
    @memcpy(s.secret_buf[0..6], "s3cr3t");
    s.secret_len = 6;
    const nonce = [_]u8{0x5a} ** 32;
    fillSessionToken("s3cr3t", &nonce, &s.session_token);
    try testServeHttp(&s, "POST /login HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 12\r\n\r\ntoken=s3cr3t");
    try std.testing.expect(s.set_cookie);
    // PRG: 303 See Other to the dashboard (not 200 with a form body).
    try std.testing.expect(std.mem.find(u8, s.testResp(), "HTTP/1.1 303 ") != null);
    s.set_cookie = false;
    try testServeHttp(&s, "POST /login HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 11\r\n\r\ntoken=wrong");
    try std.testing.expect(!s.set_cookie);
    try std.testing.expect(std.mem.find(u8, s.testResp(), "HTTP/1.1 401 ") != null);
    try testServeHttp(&s, "POST /login HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\ntoken=s3cr3t");
    try std.testing.expect(!s.set_cookie);
    try std.testing.expect(std.mem.find(u8, s.testResp(), "HTTP/1.1 415 ") != null);
    // Missing token field: no cookie; client mistake (distinct from wrong secret).
    try testServeHttp(&s, "POST /login HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 0\r\n\r\n");
    try std.testing.expect(!s.set_cookie);
    try std.testing.expect(std.mem.find(u8, s.testResp(), "HTTP/1.1 400 ") != null);
    try testServeHttp(&s, "POST /login HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 6\r\n\r\ntoken=");
    try std.testing.expect(!s.set_cookie);
    try std.testing.expect(std.mem.find(u8, s.testResp(), "HTTP/1.1 400 ") != null);
}

test "malformed request lines are client faults, not internal errors" {
    var s: Server = .{};
    @memcpy(s.secret_buf[0..6], "s3cr3t");
    s.secret_len = 6;
    const nonce = [_]u8{0x5a} ** 32;
    fillSessionToken("s3cr3t", &nonce, &s.session_token);
    // serveHttp must answer protocol faults itself (400-class) instead of
    // letting receiveHead errors bubble up to the 500 handler: garbage request
    // line, unsupported HTTP version, header without a name.
    const cases = [_][]const u8{
        "GARBAGE\r\n\r\n",
        "GET / HTTP/9.9\r\n\r\n",
        "GET / HTTP/1.1\r\n: nokey\r\n\r\n",
    };
    for (cases) |req| {
        try testServeHttp(&s, req);
        const resp = s.testResp();
        try std.testing.expect(std.mem.find(u8, resp, "HTTP/1.1 400 ") != null);
        try std.testing.expect(std.mem.find(u8, resp, "HTTP/1.1 500 ") == null);
        try std.testing.expect(std.mem.find(u8, resp, "bad request") != null);
    }
}

test "HEAD accepted on GET-only dashboard routes" {
    var s: Server = .{};
    @memcpy(s.secret_buf[0..6], "s3cr3t");
    s.secret_len = 6;
    const nonce = [_]u8{0x5a} ** 32;
    fillSessionToken("s3cr3t", &nonce, &s.session_token);
    // Same contract as /healthz + /readyz: HEAD mirrors GET (200, empty body).
    const cases = [_][]const u8{
        "HEAD / HTTP/1.1\r\nAuthorization: Bearer s3cr3t\r\n\r\n",
        "HEAD /partials/status HTTP/1.1\r\nAuthorization: Bearer s3cr3t\r\n\r\n",
        "HEAD /api/apm.json HTTP/1.1\r\nAuthorization: Bearer s3cr3t\r\n\r\n",
    };
    for (cases) |req| {
        try testServeHttp(&s, req);
        const resp = s.testResp();
        try std.testing.expect(std.mem.find(u8, resp, "HTTP/1.1 200 ") != null);
        try std.testing.expect(std.mem.find(u8, resp, "HTTP/1.1 405 ") == null);
        // HEAD must not carry a body after the header block.
        if (std.mem.find(u8, resp, "\r\n\r\n")) |end| {
            try std.testing.expectEqual(@as(usize, 0), resp[end + 4 ..].len);
        } else {
            return error.TestUnexpectedResult;
        }
    }
}

test "GET /login redirects when session cookie is already valid" {
    var s: Server = .{};
    @memcpy(s.secret_buf[0..6], "s3cr3t");
    s.secret_len = 6;
    const nonce = [_]u8{0x5a} ** 32;
    fillSessionToken("s3cr3t", &nonce, &s.session_token);
    var req_buf: [160]u8 = undefined;
    const req = try std.fmt.bufPrint(
        &req_buf,
        "GET /login HTTP/1.1\r\nCookie: zdtd_webui={s}\r\n\r\n",
        .{s.session_token[0..]},
    );
    try testServeHttp(&s, req);
    const resp = s.testResp();
    try std.testing.expect(std.mem.find(u8, resp, "HTTP/1.1 303 ") != null);
    try std.testing.expect(std.mem.find(u8, resp, "Location: /") != null);
    // Browser Max-Age alone is not sufficient: a copied cookie replayed by a
    // script must also fail at the server-side deadline.
    s.session_expires_ns = clock.monoNs() -% 1;
    try testServeHttp(&s, req);
    try std.testing.expect(std.mem.find(u8, s.testResp(), "HTTP/1.1 200 ") != null);
    try std.testing.expect(std.mem.find(u8, s.testResp(), "HTTP/1.1 303 ") == null);
    // Anonymous GET /login still serves the form.
    try testServeHttp(&s, "GET /login HTTP/1.1\r\n\r\n");
    try std.testing.expect(std.mem.find(u8, s.testResp(), "HTTP/1.1 200 ") != null);
    try std.testing.expect(std.mem.find(u8, s.testResp(), "Shared secret") != null);
}

test "fillSessionToken rotates with its nonce and is not the secret" {
    const nonce_a = [_]u8{0x11} ** 32;
    const nonce_b = [_]u8{0x22} ** 32;
    var a: [session_token_hex_len]u8 = undefined;
    var b: [session_token_hex_len]u8 = undefined;
    fillSessionToken("s3cr3t", &nonce_a, &a);
    fillSessionToken("s3cr3t", &nonce_b, &b);
    try std.testing.expect(!std.mem.eql(u8, a[0..], b[0..]));
    try std.testing.expect(!std.mem.eql(u8, a[0..], "s3cr3t"));
    for (a) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(ok);
    }
}

test "validatedContentLength rejects ambiguous framing" {
    try std.testing.expectEqual(@as(?usize, 7), try validatedContentLength(
        "POST / HTTP/1.1\r\nContent-Length: 7\r\n",
    ));
    try std.testing.expectError(error.DuplicateContentLength, validatedContentLength(
        "POST / HTTP/1.1\r\nContent-Length: 7\r\ncontent-length: 7\r\n",
    ));
    try std.testing.expectError(error.InvalidContentLength, validatedContentLength(
        "POST / HTTP/1.1\r\nContent-Length: nope\r\n",
    ));
}

test "peekContentLength rejects transfer encoding case-insensitively" {
    try std.testing.expectError(error.UnsupportedTransferEncoding, peekContentLength(
        "POST / HTTP/1.1\r\ntRaNsFeR-EnCoDiNg: chunked\r\n\r\n",
    ));
    try std.testing.expectEqual(@as(usize, 0), try peekContentLength(
        "GET /Transfer-Encoding: HTTP/1.1\r\nHost: localhost\r\n\r\n",
    ));
}

test "request header authorization requires a valid credential" {
    const invalid = "POST /api/cmd HTTP/1.1\r\nAuthorization: Bearer wrong\r\n";
    try std.testing.expect(!requestHeaderAuthorized(invalid, "s3cr3t"));
    const valid = "POST /api/cmd HTTP/1.1\r\nX-Zdtd-Secret: s3cr3t\r\n";
    try std.testing.expect(requestHeaderAuthorized(valid, "s3cr3t"));
    const lowercase_scheme = "POST /api/cmd HTTP/1.1\r\nAuthorization: bearer s3cr3t\r\n";
    try std.testing.expect(requestHeaderAuthorized(lowercase_scheme, "s3cr3t"));
    const wrong_scheme = "POST /api/cmd HTTP/1.1\r\nAuthorization: Basic s3cr3t\r\n";
    try std.testing.expect(!requestHeaderAuthorized(wrong_scheme, "s3cr3t"));
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

test "listen refuses short secret" {
    var s: Server = .{};
    defer s.deinit();
    try std.testing.expectError(error.SecretTooShort, s.listen(.{ .port = 1, .secret = "short" }));
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
    try std.testing.expect(std.mem.find(u8, html, "42") != null);
    try std.testing.expect(std.mem.find(u8, html, "test") != null);
    const apm = try renderApm(&buf, &s);
    try std.testing.expect(std.mem.find(u8, apm, "tick mean") != null);
    const js = try renderApmJson(&buf, &s);
    try std.testing.expect(std.mem.find(u8, js, "\"tick\":42") != null);
    try std.testing.expect(std.mem.find(u8, js, "\"net_p99_ns\":") != null);
    try std.testing.expect(std.mem.find(u8, js, "\"save_mean_ns\":") != null);
    try std.testing.expect(std.mem.find(u8, js, "\"max_players\":") != null);
    try std.testing.expect(std.mem.find(u8, js, "\"phase_rejects\":") != null);
    try std.testing.expect(std.mem.find(u8, js, "\"ownership_rejects\":") != null);
    try std.testing.expect(std.mem.find(u8, js, "\"bounds_rejects\":") != null);
    try std.testing.expect(std.mem.find(u8, js, "\"movement_rejects\":") != null);
    try std.testing.expect(std.mem.find(u8, js, "\"decode_rejects\":") != null);
    try std.testing.expect(std.mem.find(u8, js, "\"world\":\"test\"") != null);
    try std.testing.expect(std.mem.find(u8, js, "\"wire_chunks\":") != null);
    try std.testing.expect(std.mem.find(u8, js, "\"players\":[") != null);
    try std.testing.expect(std.mem.find(u8, js, "\"webui_port\":") != null);
}

test "httpReasonPhrase covers early rawRespond statuses" {
    try std.testing.expectEqualStrings("Bad Request", httpReasonPhrase(400));
    try std.testing.expectEqualStrings("Content Too Large", httpReasonPhrase(413));
    try std.testing.expectEqualStrings("Internal Server Error", httpReasonPhrase(500));
    try std.testing.expectEqualStrings("Too Many Requests", httpReasonPhrase(429));
}

test "adminLineOk rejects control chars" {
    try std.testing.expect(adminLineOk("give 0 1 1"));
    try std.testing.expect(!adminLineOk("say hi\nshutdown"));
    try std.testing.expect(!adminLineOk("kick\r1"));
    try std.testing.expect(!adminLineOk(&.{ 'k', 0, 'x' }));
    try std.testing.expect(!adminLineOk("tab\there"));
    try std.testing.expect(!adminLineOk(&.{ 'x', 0x7f }));
}

test "formatSessionCookie sets Max-Age" {
    var buf: [128]u8 = undefined;
    const c = try formatSessionCookie(&buf, "0123456789abcdef0123456789abcdef");
    try std.testing.expect(std.mem.find(u8, c, "Max-Age=43200") != null);
    try std.testing.expect(std.mem.find(u8, c, "HttpOnly") != null);
    try std.testing.expect(std.mem.find(u8, c, "SameSite=Strict") != null);
}

test "login lockout after repeated failures" {
    var s: Server = .{};
    @memcpy(s.secret_buf[0..6], "s3cr3t");
    s.secret_len = 6;
    const nonce = [_]u8{0x5a} ** 32;
    fillSessionToken("s3cr3t", &nonce, &s.session_token);
    var i: u32 = 0;
    while (i < login_fail_limit) : (i += 1) {
        try testServeHttp(&s, "POST /login HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 11\r\n\r\ntoken=wrong");
        try std.testing.expect(!s.set_cookie);
    }
    try std.testing.expect(s.loginLocked());
    // Further attempts while locked must not set a session cookie.
    try testServeHttp(&s, "POST /login HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 12\r\n\r\ntoken=s3cr3t");
    try std.testing.expect(!s.set_cookie);
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
    try std.testing.expect(std.mem.find(u8, html, "<img") == null);
    try std.testing.expect(std.mem.find(u8, html, "&lt;img") != null);
    try std.testing.expect(std.mem.find(u8, html, "<caption class=\"sr-only\">Connected players</caption>") != null);
    try std.testing.expect(std.mem.find(u8, html, "<th scope=\"col\">Name</th>") != null);
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
    // Strict framing (duplicate Content-Length / Transfer-Encoding rejection)
    // must not panic, and an accepted length must be within the header block it
    // was parsed from.
    if (validatedContentLength(head)) |strict| {
        if (strict) |n| try std.testing.expect(std.fmt.count("{d}", .{n}) <= head.len);
    } else |_| {}
    _ = peekContentLength(head) catch {};
    _ = isFormContentType(headerValue(head, "Content-Type"));
    if (headerValue(head, "Cookie")) |ck| {
        if (cookieValue(ck, "zdtd_webui")) |cv| try std.testing.expect(cv.len <= head.len);
    }
    _ = requestAuthorized(head, "fuzz-secret-0123", "0123456789abcdef0123456789abcdef");
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

    // HTML escape used for player names / cmd replies must not panic and must
    // expand specials without overflowing the fixed render buffer when short.
    var esc_buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&esc_buf);
    htmlEscape(&w, head) catch return;
    const escaped = w.buffered();
    try std.testing.expect(escaped.len <= esc_buf.len);
    // Unescaped angle brackets must not survive (XSS hardening for webui).
    try std.testing.expect(std.mem.findScalar(u8, escaped, '<') == null);
    try std.testing.expect(std.mem.findScalar(u8, escaped, '>') == null);
    try std.testing.expect(std.mem.findScalar(u8, escaped, '"') == null);
}

test "renderShell exposes console names and status updates" {
    var buf: [16 * 1024]u8 = undefined;
    var sess: [session_token_hex_len]u8 = undefined;
    const nonce = [_]u8{0x33} ** 32;
    fillSessionToken("s3cr3t", &nonce, &sess);
    const html = try renderShell(&buf, sess[0..]);
    try std.testing.expect(std.mem.find(u8, html, "<label for=\"cmd-line\"") != null);
    try std.testing.expect(std.mem.find(u8, html, "maxlength=\"256\" required") != null);
    try std.testing.expect(std.mem.find(u8, html, "id=\"cmd-out\" aria-live=\"polite\"") != null);
    try std.testing.expect(std.mem.find(u8, html, "class=\"skip-link\"") != null);
    try std.testing.expect(std.mem.find(u8, html, ":focus-visible") != null);
    try std.testing.expect(std.mem.find(u8, html, "id=\"auto-refresh\"") != null);
    try std.testing.expect(std.mem.find(u8, html, "id=\"refresh-now\"") != null);
    try std.testing.expect(std.mem.find(u8, html, "aria-label=\"Dashboard sections\"") != null);
    try std.testing.expect(std.mem.find(u8, html, "id=\"status-section\"") != null);
    try std.testing.expect(std.mem.find(u8, html, "action=\"/logout\"") != null);
    try std.testing.expect(std.mem.find(u8, html, "method=\"post\" action=\"/api/cmd\"") != null);
    try std.testing.expect(std.mem.find(u8, html, "window.confirm") != null);
    try std.testing.expect(std.mem.find(u8, html, "line.split(/\\s+/,1)") != null);
    try std.testing.expect(std.mem.find(u8, html, "id=\"status-heading\"") != null);
    try std.testing.expect(std.mem.find(u8, html, "aria-label=\"Recent commands\"") != null);
    try std.testing.expect(std.mem.find(u8, html, "forced-colors:active") != null);
    try std.testing.expect(std.mem.find(u8, html, "prefers-reduced-motion") != null);
    // Control borders come from the --edge token; both halves must stay in sync.
    try std.testing.expect(std.mem.find(u8, html, "--edge:#6a738c") != null);
    try std.testing.expect(std.mem.find(u8, html, "border:1px solid var(--edge)") != null);
    try std.testing.expect(std.mem.find(u8, html, "text-decoration:underline") != null);
    try std.testing.expect(std.mem.find(u8, html, "id=\"refresh-state\" role=\"status\"") != null);
    try std.testing.expect(std.mem.find(u8, html, "commandFailed?'alert':'status'") != null);
    try std.testing.expect(std.mem.find(u8, html, "out.setAttribute('aria-busy','true')") != null);
    try std.testing.expect(std.mem.find(u8, html, "pre.cmd-out:focus-visible,pre.cmd-log:focus-visible,#console-log:focus-visible") != null);
    try std.testing.expect(std.mem.find(u8, html, "list-style:none") != null);
    try std.testing.expect(std.mem.find(u8, html, "min-width:1.5rem;min-height:1.5rem") != null);
    try std.testing.expect(std.mem.find(u8, html, "aria-labelledby=\"status-heading\"") != null);
    try std.testing.expect(std.mem.find(u8, html, "Loading performance data") != null);
    try std.testing.expect(std.mem.find(u8, html, "Loading command history") != null);
    try std.testing.expect(std.mem.find(u8, html, "position:sticky") != null);
    // Automatic polling must not replace a focused scroll region; explicit
    // Refresh now and post-command refreshes may force a swap.
    try std.testing.expect(std.mem.find(u8, html, "el.contains(document.activeElement)") != null);
    try std.testing.expect(std.mem.find(u8, html, "el._hxOnce=()=>swap(true)") != null);
    try std.testing.expect(std.mem.find(u8, html, "r.status===401") != null);
    try std.testing.expect(std.mem.find(u8, html, "let inFlight=false") != null);
    try std.testing.expect(std.mem.find(u8, html, "if(!el.hasAttribute('data-load-error'))") != null);
    try std.testing.expect(std.mem.find(u8, html, "forced-color-adjust:none") == null);
    try std.testing.expect(std.mem.find(u8, html, ".err,.noscript,.warn-text{color:MarkText;background:Mark}") != null);
    try std.testing.expect(std.mem.find(u8, html, "prefers-reduced-motion: reduce').matches") == null);
    try std.testing.expect(std.mem.find(u8, html, "JavaScript is required for live updates") != null);
    try std.testing.expect(std.mem.find(u8, html, "'kick','kickall','ban'") != null);
    try std.testing.expect(std.mem.find(u8, html, "its outcome is unknown") != null);
    // Shared secret must not appear in HTML; CSRF uses session token only.
    try std.testing.expect(std.mem.find(u8, html, "s3cr3t") == null);
    try std.testing.expect(std.mem.find(u8, html, sess[0..]) != null);
    // Runtime body_buf for GET / is 16384; shell must fit.
    try std.testing.expect(html.len < 16384);
}

test "loginHintHtml exposes labeled secret form" {
    const ok = loginHintHtml(false);
    try std.testing.expect(std.mem.find(u8, ok, "<label for=\"login-token\">Shared secret</label>") != null);
    try std.testing.expect(std.mem.find(u8, ok, "name=\"token\"") != null);
    try std.testing.expect(std.mem.find(u8, ok, "type=\"password\"") != null);
    try std.testing.expect(std.mem.find(u8, ok, "maxlength=\"128\"") != null);
    try std.testing.expect(std.mem.find(u8, ok, "id=\"toggle-secret\"") != null);
    try std.testing.expect(std.mem.find(u8, ok, "aria-pressed=\"false\"") != null);
    try std.testing.expect(std.mem.find(u8, ok, "token.type=shown?'password':'text'") != null);
    try std.testing.expect(std.mem.find(u8, ok, "role=\"alert\"") == null);
    const bad = loginHintHtml(true);
    try std.testing.expect(std.mem.find(u8, bad, "role=\"alert\"") != null);
    try std.testing.expect(std.mem.find(u8, bad, "aria-invalid=\"true\"") != null);
    try std.testing.expect(std.mem.find(u8, bad, "Sign-in failed") != null);
    try std.testing.expect(std.mem.find(u8, bad, "id=\"toggle-secret\"") != null);
    try std.testing.expect(std.mem.find(u8, ok, "aria-invalid") == null);
    try std.testing.expect(std.mem.find(u8, ok, "forced-colors:active") != null);
    try std.testing.expect(std.mem.find(u8, bad, "color:MarkText;background:Mark") != null);
    try std.testing.expect(std.mem.find(u8, bad, "forced-color-adjust:none") == null);
    const locked = loginLockoutHtml();
    try std.testing.expect(std.mem.find(u8, locked, "Too many failed sign-ins") != null);
    try std.testing.expect(std.mem.find(u8, locked, "role=\"alert\"") != null);
    try std.testing.expect(std.mem.find(u8, locked, "method=\"post\" action=\"/login\"") != null);
    // During lockout, controls are disabled so users cannot keep submitting failures.
    try std.testing.expect(std.mem.find(u8, locked, "disabled>") != null);
    try std.testing.expect(std.mem.find(u8, locked, "tabindex=\"-1\"") != null);
    // The countdown ticks inside role="alert"; without aria-live=off a screen
    // reader interrupts itself once a second for the whole lockout.
    try std.testing.expect(std.mem.find(u8, locked, "id=\"retry-seconds\" aria-live=\"off\"") != null);
    try std.testing.expect(std.mem.find(u8, locked, "window.location.replace('/login')") != null);
}

test "command result marks known failures and is keyboard-scrollable" {
    var buf: [2048]u8 = undefined;
    const reply = try renderCmdReply(&buf, "status", "ok");
    try std.testing.expect(std.mem.find(u8, reply, "tabindex=\"0\"") != null);
    // No aria-label: the pre is read by the #cmd-out live region, and a label
    // would mask the actual command output from screen reader announcements.
    try std.testing.expect(std.mem.find(u8, reply, "aria-label=") == null);
    try std.testing.expect(std.mem.find(u8, reply, "class=\"cmd-out err\"") == null);
    const fail = try renderCmdReply(&buf, "frob", "unknown command 'frob'. 'help' for list.\n");
    try std.testing.expect(std.mem.find(u8, fail, "class=\"cmd-out err\"") != null);
    try std.testing.expect(std.mem.find(u8, fail, "data-command-error=\"true\"") != null);
    try std.testing.expect(std.mem.find(u8, fail, "role=\"alert\"") == null);
    try std.testing.expect(adminReplyLooksFailed("bad arguments to 'inv'. usage: inv <slot>\n"));
    try std.testing.expect(!adminReplyLooksFailed("kicked\n"));
    // Stock console error shapes must light the failure indicator too.
    try std.testing.expect(adminReplyLooksFailed("*** ERROR: unknown command 'frob'\n"));
    try std.testing.expect(adminReplyLooksFailed("Wrong number of arguments, expected 1 or 3, found 2.\n"));
    try std.testing.expect(adminReplyLooksFailed("Invalid sub command \"frob\".\n"));
    try std.testing.expect(adminReplyLooksFailed("No sub command given.\n"));
    try std.testing.expect(adminReplyLooksFailed("Day must be >= 1\n"));
    try std.testing.expect(adminReplyLooksFailed("Hour must be <= 23\n"));
    try std.testing.expect(adminReplyLooksFailed("Minute must be <= 59\n"));
    try std.testing.expect(adminReplyLooksFailed("Invalid value for single argument variant: \"noon\"\n"));
    // Successful stock replies must not.
    try std.testing.expect(!adminReplyLooksFailed("Kicking Player Alice: rude\n"));
    try std.testing.expect(!adminReplyLooksFailed("Total of 0 in the game\n"));
    try std.testing.expect(!adminReplyLooksFailed("Set time to 12000\n"));
    try std.testing.expect(!adminReplyLooksFailed("Ban list entries:\n"));
    var s: Server = .{};
    var log_buf: [2048]u8 = undefined;
    const log = try renderConsoleLog(&log_buf, &s);
    // The pre is the scroll container, so it must be tabbable (WCAG 2.1.1).
    try std.testing.expect(std.mem.find(u8, log, "<pre class=\"cmd-log\" tabindex=\"0\">") != null);
    // The name lives on the stable outer region, not on the swapped-in partial.
    try std.testing.expect(std.mem.find(u8, log, "aria-label=\"Recent commands\"") == null);
    // Failure replies in the audit ring keep the same err styling as #cmd-out.
    s.pushAudit("> frob");
    s.pushAudit("unknown command 'frob'. 'help' for list.");
    const log_err = try renderConsoleLog(&log_buf, &s);
    try std.testing.expect(std.mem.find(u8, log_err, "<span class=\"err\">") != null);
    try std.testing.expect(std.mem.find(u8, log_err, "unknown command") != null);
    var sess: [session_token_hex_len]u8 = undefined;
    const nonce = [_]u8{0x44} ** 32;
    fillSessionToken("s3cr3t", &nonce, &sess);
    var shell_buf: [16 * 1024]u8 = undefined;
    const shell = try renderShell(&shell_buf, sess[0..]);
    // role= so the aria-label is actually exposed (a bare div has no name),
    // tabindex=-1 so the poll's focus restore has somewhere to land.
    try std.testing.expect(std.mem.find(u8, shell, "id=\"console-log\" aria-label=\"Recent commands\" role=\"region\" tabindex=\"-1\"") != null);
}

test "renderStatus and renderApm use list markup for stat grids" {
    var snap: Snapshot = .{ .tick_n = 1 };
    var buf: [8192]u8 = undefined;
    const status = try renderStatus(&buf, &snap);
    try std.testing.expect(std.mem.find(u8, status, "<ul class=\"grid\">") != null);
    try std.testing.expect(std.mem.find(u8, status, "<li class=\"stat\">") != null);
    try std.testing.expect(std.mem.find(u8, status, "server tick") != null);
    try std.testing.expect(std.mem.find(u8, status, "not set") != null);
    try std.testing.expect(std.mem.find(u8, status, "(unnamed)") != null);
    // Zero overruns stay neutral; non-zero overruns use warn styling.
    try std.testing.expect(std.mem.find(u8, status, "class=\"num warn-text\"") == null);
    snap.tick_overruns = 3;
    const status_warn = try renderStatus(&buf, &snap);
    try std.testing.expect(std.mem.find(u8, status_warn, "class=\"num warn-text\"") != null);
    var apm_buf: [8192]u8 = undefined;
    const apm = try renderApm(&apm_buf, &snap);
    try std.testing.expect(std.mem.find(u8, apm, "<ul class=\"grid\">") != null);
    try std.testing.expect(std.mem.find(u8, apm, "<li class=\"stat\">") != null);
    try std.testing.expect(std.mem.find(u8, apm, "class=\"num warn-text\"") != null);
    snap.join_fail = 2;
    const apm_err = try renderApm(&apm_buf, &snap);
    try std.testing.expect(std.mem.find(u8, apm_err, "class=\"num err\"") != null);
}

test "renderStatus uses h3 for subsections under shell Status h2" {
    var s: Snapshot = .{ .tick_n = 1 };
    var buf: [4096]u8 = undefined;
    const html = try renderStatus(&buf, &s);
    try std.testing.expect(std.mem.find(u8, html, "<h2>Status</h2>") == null);
    try std.testing.expect(std.mem.find(u8, html, "<h3>Entities</h3>") != null);
    try std.testing.expect(std.mem.find(u8, html, "<h3>Server</h3>") != null);
}

test "renderPlayers identifies each player name as a row header" {
    var s: Snapshot = .{};
    s.players[0].used = true;
    s.players[0].name_len = 3;
    @memcpy(s.players[0].name[0..3], "Ada");
    var buf: [4096]u8 = undefined;
    const html = try renderPlayers(&buf, &s);
    try std.testing.expect(std.mem.find(u8, html, "<th scope=\"row\">Ada</th>") != null);
}

test "renderApmJson includes escaped player names and world" {
    var s: Snapshot = .{ .tick_n = 1, .wire_chunks = false };
    @memcpy(s.world_name[0..5], "Na\"ve");
    s.world_name_len = 5;
    s.players[0] = .{
        .used = true,
        .slot = 1,
        .entity_id = 100,
        .joined = true,
        .entered = true,
        .x = 1.5,
        .y = 70,
        .z = -2,
        .name_len = 5,
    };
    // Name bytes: A " b \ c (5 chars) to verify JSON escaping.
    @memcpy(s.players[0].name[0..5], "A\"b\\c");
    var buf: [8192]u8 = undefined;
    const js = try renderApmJson(&buf, &s);
    try std.testing.expect(std.mem.find(u8, js, "\"world\":\"Na\\\"ve\"") != null);
    try std.testing.expect(std.mem.find(u8, js, "\"wire_chunks\":false") != null);
    try std.testing.expect(std.mem.find(u8, js, "\"name\":\"A\\\"b\\\\c\"") != null);
    try std.testing.expect(std.mem.find(u8, js, "\"slot\":1") != null);
    try std.testing.expect(std.mem.find(u8, js, "\"entity_id\":100") != null);
}

test "prefersPlainBody honors Accept without HTML" {
    // Build minimal request heads via the raw header helper path used by prefersPlainBody.
    // requestAuthorized-style string heads are not used here; we unit-test mediaTypePresent.
    try std.testing.expect(mediaTypePresent("text/plain", "text/plain"));
    try std.testing.expect(mediaTypePresent("text/plain, */*", "text/plain"));
    try std.testing.expect(mediaTypePresent("application/json;q=0.9", "application/json"));
    try std.testing.expect(!mediaTypePresent("text/html,application/xhtml+xml", "text/plain"));
    try std.testing.expect(mediaTypePresent("text/html, application/json", "application/json"));
}
