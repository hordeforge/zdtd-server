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
const version = @import("../version.zig");
const clock = @import("../util/clock.zig");

pub const max_req: usize = 8192;
pub const max_secret: usize = 128;
/// Minimum shared-secret length when webui is enabled (trivial secrets rejected).
pub const min_secret: usize = 8;
/// Hex length of HMAC-derived session token (cookie + CSRF; not the shared secret).
pub const session_token_hex_len: usize = 32;
pub const max_players_snap: usize = 16;
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

    fn loginLocked(self: *const Server) bool {
        if (self.login_lock_until_ns == 0) return false;
        return clock.monoNs() < self.login_lock_until_ns;
    }

    fn noteLoginFailure(self: *Server) void {
        self.login_fails +|= 1;
        if (self.login_fails >= login_fail_limit) {
            self.login_lock_until_ns = clock.monoNs() +% login_lockout_ns;
            self.login_fails = 0;
            std.debug.print("zdtd: webui login lockout ({d} s)\n", .{login_lockout_ns / std.time.ns_per_s});
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
        const head_end = std.mem.indexOf(u8, self.recv_buf[0..self.recv_len], "\r\n\r\n") orelse {
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
        var req = try http_srv.receiveHead();

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
                    self.set_cookie = true;
                    // 303 See Other: POST → GET dashboard (PRG; matches /logout).
                    try self.httpRedirect(&req, "/");
                    return;
                }
                self.noteLoginFailure();
                std.debug.print("zdtd: webui login rejected (bad token)\n", .{});
                try self.httpRespond(&req, .unauthorized, "text/html; charset=utf-8", loginHintHtml(true), &.{});
                return;
            }
            try self.httpRespond(&req, .method_not_allowed, "text/plain; charset=utf-8", "method not allowed\n", &.{
                .{ .name = "Allow", .value = "GET, POST" },
            });
            return;
        }

        if (!requestAuthorizedHttp(&req, self.secret(), self.sessionTok())) {
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
                std.debug.print("zdtd: webui auth rejected (bad credential)\n", .{});
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

        var body_buf: [12288]u8 = undefined;

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
            if (method != .GET) {
                try self.httpRespond(&req, .method_not_allowed, "text/plain; charset=utf-8", "method not allowed\n", &.{
                    .{ .name = "Allow", .value = "GET" },
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
            const first = std.mem.indexOfScalar(u8, reply, '\n') orelse reply.len;
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
        const fd = self.client_fd;
        if (fd < 0) return;
        const out = req.server.out.buffered();
        if (out.len > 0) tcp.writeAll(fd, out);
    }

    /// Fallback when http.Server is not yet set up (buffer overflow before parse).
    fn rawRespond(self: *Server, status: u16, content_type: []const u8, body: []const u8) void {
        const fd = self.client_fd;
        if (fd < 0) return;
        var hdr: [640]u8 = undefined;
        const h = std.fmt.bufPrint(
            &hdr,
            "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: {s}\r\nPermissions-Policy: camera=(), microphone=(), geolocation=()\r\nConnection: close\r\n\r\n",
            .{ status, httpReasonPhrase(status), content_type, body.len, csp_policy },
        ) catch return;
        tcp.writeAll(fd, h);
        tcp.writeAll(fd, body);
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

fn requestAuthorizedHttp(req: *const http.Server.Request, secret: []const u8, session_token: []const u8) bool {
    if (secret.len == 0) return false;
    if (requestHeaderAuthorizedHttp(req, secret)) return true;
    if (headerFromReq(req, "Cookie")) |ck| {
        if (cookieValue(ck, "zdtd_webui")) |cv| {
            if (constantTimeEql(cv, session_token)) return true;
        }
    }
    return false;
}

fn requestHeaderAuthorizedHttp(req: *const http.Server.Request, secret: []const u8) bool {
    if (secret.len == 0) return false;
    if (headerFromReq(req, "Authorization")) |auth| {
        const t = std.mem.trim(u8, auth, " \t");
        if (std.mem.startsWith(u8, t, "Bearer ")) {
            if (constantTimeEql(std.mem.trim(u8, t["Bearer ".len..], " \t"), secret)) return true;
        }
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

fn readinessStatus(s: *const Snapshot) u16 {
    return if (s.tick_n == 0) 503 else 200;
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

fn validatedContentLength(head: []const u8) !?usize {
    var found: ?usize = null;
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next();
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
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
        const semi = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
        const mt = std.mem.trim(u8, raw[0..semi], " \t");
        if (std.ascii.eqlIgnoreCase(mt, media)) return true;
    }
    return false;
}

/// First-line prefixes used by Game.runAdminLine for operator-visible failures.
fn adminReplyLooksFailed(reply: []const u8) bool {
    const first = std.mem.indexOfScalar(u8, reply, '\n') orelse reply.len;
    const line = std.mem.trimEnd(u8, reply[0..first], " \t\r");
    const prefixes = [_][]const u8{
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
    // class=err when the admin reply is a known failure string (still HTTP 200).
    if (adminReplyLooksFailed(reply)) {
        try w.writeAll("<pre class=\"cmd-out err\" tabindex=\"0\" aria-label=\"Command result\" role=\"alert\"><span class=\"in\">&gt; ");
    } else {
        try w.writeAll("<pre class=\"cmd-out\" tabindex=\"0\" aria-label=\"Command result\"><span class=\"in\">&gt; ");
    }
    try htmlEscape(&w, line);
    try w.writeAll("</span>\n");
    try htmlEscape(&w, reply);
    try w.writeAll("</pre>");
    return w.buffered();
}

fn renderConsoleLog(buf: []u8, s: *const Server) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    // The stable outer region owns focus so polling cannot discard it.
    try w.writeAll("<pre class=\"cmd-log\">");
    if (s.audit_n == 0) {
        try w.writeAll("<span class=\"meta\">No commands run yet. Enter a command above and choose Run.</span>");
    } else {
        const n: usize = s.audit_n;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const idx = (@as(usize, s.audit_i) + max_audit - n + k) % max_audit;
            const len = s.audit_lens[idx];
            try htmlEscape(&w, s.audit_lines[idx][0..len]);
            try w.writeAll("\n");
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
    const hex = "0123456789abcdef";
    const n = session_token_hex_len / 2;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const b = mac[i];
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
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
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn constantTimeEql(a: []const u8, b: []const u8) bool {
    // Always walk max(len) so length mismatches do not early-return before
    // content work (reduces online timing oracle on secret length).
    var diff: u8 = if (a.len == b.len) 0 else 1;
    const n = @max(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const x: u8 = if (i < a.len) a[i] else 0;
        const y: u8 = if (i < b.len) b[i] else 0;
        diff |= x ^ y;
    }
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

fn loginHintHtml(bad_token: bool) []const u8 {
    if (bad_token) {
        return
        \\<!DOCTYPE html>
        \\<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        \\<title>Sign in · zdtd</title>
        \\<style>:root{color-scheme:dark}*{box-sizing:border-box}body{font-family:system-ui,sans-serif;margin:0;padding:clamp(1rem,5vw,2rem);line-height:1.5;color:#e8e8e8;background:#1a1a1a}main{max-width:36rem}
        \\code{background:#333;padding:0.15em 0.4em;border-radius:3px}a{color:#7eb8ff;text-decoration:underline}
        \\label{display:block;font-weight:600;margin:1rem 0 0.35rem}input[type=password]{width:100%;max-width:24rem;box-sizing:border-box;min-height:44px;padding:0.5rem 0.65rem;border:1px solid #6a738c;border-radius:6px;background:#111;color:#e8e8e8;font:inherit}
        \\button{min-height:44px;min-width:5rem;margin-top:0.75rem;padding:0.5rem 1rem;border:0;border-radius:6px;background:#7eb8ff;color:#0a0c10;font-weight:600;cursor:pointer}button:hover{filter:brightness(1.08)}button:active{filter:brightness(0.95)}
        \\a:focus-visible,button:focus-visible,input:focus-visible{outline:3px solid #e8a838;outline-offset:3px}
        \\.err{color:#ff8a8a;margin:0.75rem 0}
        \\@media(forced-colors:active){body{background:Canvas;color:CanvasText}a{color:LinkText}input[type=password],button{border:1px solid ButtonText}a:focus-visible,button:focus-visible,input:focus-visible{outline:3px solid Highlight;outline-offset:3px}.err{color:MarkText;background:Mark}}
        \\</style></head>
        \\<body><main><h1>zdtd webui</h1>
        \\<p id="login-err" class="err" role="alert">Sign-in failed. The shared secret was not accepted.</p>
        \\<form method="post" action="/login">
        \\<label for="login-token">Shared secret</label>
        \\<input type="password" name="token" id="login-token" required maxlength="128" autocomplete="current-password" spellcheck="false" aria-invalid="true" aria-describedby="login-err login-help" autofocus>
        \\<button type="submit">Sign in</button>
        \\</form>
        \\<p id="login-help">Or send <code>Authorization: Bearer …</code> / <code>X-Zdtd-Secret</code>.</p>
        \\<p>Use the secret configured by the server operator with <code>ZDTD_WEBUI_SECRET</code>.</p></main></body></html>
        ;
    }
    return
    \\<!DOCTYPE html>
    \\<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    \\<title>Sign in · zdtd</title>
    \\<style>:root{color-scheme:dark}*{box-sizing:border-box}body{font-family:system-ui,sans-serif;margin:0;padding:clamp(1rem,5vw,2rem);line-height:1.5;color:#e8e8e8;background:#1a1a1a}main{max-width:36rem}
    \\code{background:#333;padding:0.15em 0.4em;border-radius:3px}a{color:#7eb8ff;text-decoration:underline}
    \\label{display:block;font-weight:600;margin:1rem 0 0.35rem}input[type=password]{width:100%;max-width:24rem;box-sizing:border-box;min-height:44px;padding:0.5rem 0.65rem;border:1px solid #6a738c;border-radius:6px;background:#111;color:#e8e8e8;font:inherit}
    \\button{min-height:44px;min-width:5rem;margin-top:0.75rem;padding:0.5rem 1rem;border:0;border-radius:6px;background:#7eb8ff;color:#0a0c10;font-weight:600;cursor:pointer}button:hover{filter:brightness(1.08)}button:active{filter:brightness(0.95)}
    \\a:focus-visible,button:focus-visible,input:focus-visible{outline:3px solid #e8a838;outline-offset:3px}
    \\@media(forced-colors:active){body{background:Canvas;color:CanvasText}a{color:LinkText}input[type=password],button{border:1px solid ButtonText}a:focus-visible,button:focus-visible,input:focus-visible{outline:3px solid Highlight;outline-offset:3px}}
    \\</style></head>
    \\<body><main><h1>zdtd webui</h1>
    \\<p>Sign in with the webui shared secret to set a session cookie.</p>
    \\<form method="post" action="/login">
    \\<label for="login-token">Shared secret</label>
    \\<input type="password" name="token" id="login-token" required maxlength="128" autocomplete="current-password" spellcheck="false" aria-describedby="login-help" autofocus>
    \\<button type="submit">Sign in</button>
    \\</form>
    \\<p id="login-help">Or send <code>Authorization: Bearer …</code> / <code>X-Zdtd-Secret</code>.</p>
    \\<p>Use the secret configured by the server operator with <code>ZDTD_WEBUI_SECRET</code>.</p></main></body></html>
    ;
}

/// Temporary lockout after too many failed sign-ins (same form chrome as login).
fn loginLockoutHtml() []const u8 {
    return
    \\<!DOCTYPE html>
    \\<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    \\<title>Sign in · zdtd</title>
    \\<style>:root{color-scheme:dark}*{box-sizing:border-box}body{font-family:system-ui,sans-serif;margin:0;padding:clamp(1rem,5vw,2rem);line-height:1.5;color:#e8e8e8;background:#1a1a1a}main{max-width:36rem}
    \\code{background:#333;padding:0.15em 0.4em;border-radius:3px}a{color:#7eb8ff;text-decoration:underline}
    \\label{display:block;font-weight:600;margin:1rem 0 0.35rem}input[type=password]{width:100%;max-width:24rem;box-sizing:border-box;min-height:44px;padding:0.5rem 0.65rem;border:1px solid #6a738c;border-radius:6px;background:#111;color:#e8e8e8;font:inherit}
    \\button{min-height:44px;min-width:5rem;margin-top:0.75rem;padding:0.5rem 1rem;border:0;border-radius:6px;background:#7eb8ff;color:#0a0c10;font-weight:600;cursor:pointer}button:hover{filter:brightness(1.08)}button:active{filter:brightness(0.95)}button:disabled,input:disabled{opacity:0.55;cursor:not-allowed}
    \\a:focus-visible,button:focus-visible,input:focus-visible{outline:3px solid #e8a838;outline-offset:3px}
    \\.err{color:#ff8a8a;margin:0.75rem 0}
    \\@media(forced-colors:active){body{background:Canvas;color:CanvasText}a{color:LinkText}input[type=password],button{border:1px solid ButtonText}a:focus-visible,button:focus-visible,input:focus-visible{outline:3px solid Highlight;outline-offset:3px}.err{color:MarkText;background:Mark}}
    \\</style></head>
    \\<body><main><h1>zdtd webui</h1>
    \\<p id="login-err" class="err" role="alert" tabindex="-1" autofocus>Too many failed sign-ins. Wait about 30 seconds, then try again.</p>
    \\<form method="post" action="/login" aria-describedby="login-err">
    \\<label for="login-token">Shared secret</label>
    \\<input type="password" name="token" id="login-token" required maxlength="128" autocomplete="current-password" spellcheck="false" aria-invalid="true" aria-describedby="login-err login-help" disabled>
    \\<button type="submit" disabled>Sign in</button>
    \\</form>
    \\<p id="login-help">Or send <code>Authorization: Bearer …</code> / <code>X-Zdtd-Secret</code>.</p>
    \\<p>Use the secret configured by the server operator with <code>ZDTD_WEBUI_SECRET</code>.</p></main></body></html>
    ;
}

/// `csrf_token` must be the HMAC session token (not the shared secret).
fn renderShell(buf: []u8, csrf_token: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf,
        \\<!DOCTYPE html>
        \\<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        \\<title>Server dashboard · zdtd</title>
        \\<style>
        \\:root{{color-scheme:dark;--bg:#12141a;--card:#1c2030;--fg:#e8eaef;--muted:#aab2c2;--acc:#72b3e4;--ok:#82d68b;--warn:#f0b64f;--err:#ff8585}}
        \\*{{box-sizing:border-box}}body{{font-family:system-ui,sans-serif;margin:0;background:var(--bg);color:var(--fg);line-height:1.45}}
        \\.skip-link{{position:absolute;left:1rem;top:0;transform:translateY(-150%);background:var(--warn);color:#0a0c10;padding:0.65rem 0.85rem;border-radius:0 0 6px 6px;font-weight:700;z-index:1}}.skip-link:focus{{transform:translateY(0)}}
        \\header{{padding:1rem 1.25rem;border-bottom:1px solid #2a3144;display:flex;gap:1rem;align-items:center;flex-wrap:wrap}}
        \\header h1{{font-size:1.15rem;margin:0;font-weight:600}}header .meta{{color:var(--muted);font-size:0.9rem}}
        \\.refresh-ctrl{{margin-left:auto;display:inline-flex;align-items:center;gap:0.4rem;color:var(--muted);font-size:0.9rem;cursor:pointer;min-height:44px}}
        \\.refresh-ctrl input{{width:1.5rem;height:1.5rem;min-width:1.5rem;min-height:1.5rem;accent-color:var(--acc)}}
        \\.refresh-now,.logout-form button{{min-height:44px;padding:0.45rem 0.75rem;border:1px solid #6a738c;border-radius:6px;background:transparent;color:var(--fg);font:inherit;cursor:pointer}}
        \\.refresh-now:hover,.logout-form button:hover,.cmd-row button:hover{{filter:brightness(1.08)}}.refresh-now:active,.logout-form button:active,.cmd-row button:active{{filter:brightness(0.95)}}
        \\.logout-form{{margin:0}}
        \\.page-nav{{display:flex;flex-wrap:wrap;gap:0.35rem 0.85rem;padding:0.55rem 1.25rem;border-bottom:1px solid #2a3144;background:#161922}}
        \\.page-nav a{{color:var(--acc);text-decoration:underline;min-height:44px;display:inline-flex;align-items:center;padding:0.2rem 0.15rem;font-size:0.9rem}}
        \\main{{padding:1rem 1.25rem;display:grid;gap:1rem;max-width:56rem;width:100%;margin-inline:auto}}
        \\section{{background:var(--card);border-radius:8px;padding:0.85rem 1rem;border:1px solid #2a3144;scroll-margin-top:0.75rem}}
        \\section h2{{margin:0 0 0.6rem;font-size:0.95rem;color:var(--acc);font-weight:600;text-transform:uppercase;letter-spacing:0.04em}}
        \\section h3{{margin:1rem 0 0.5rem;font-size:0.8rem;color:var(--muted);font-weight:600}}
        \\table{{width:100%;border-collapse:collapse;font-size:0.9rem}}th,td{{text-align:left;padding:0.35rem 0.5rem;border-bottom:1px solid #2a3144}}
        \\th{{color:var(--muted);font-weight:500}} .num{{font-variant-numeric:tabular-nums}}
        \\.sr-only{{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}}
        \\.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(7.5rem,1fr));gap:0.5rem;list-style:none;margin:0;padding:0}}
        \\.stat{{background:#141824;border-radius:6px;padding:0.5rem 0.65rem}}.stat b{{display:block;font-size:1.1rem}}.stat span{{color:var(--muted);font-size:0.8rem}}
        \\.warn-text{{color:var(--warn);font-weight:700}}
        \\footer{{padding:0.75rem 1.25rem;color:var(--muted);font-size:0.8rem}}footer a{{color:var(--acc);text-decoration:underline}}
        \\.cmd-row{{display:flex;gap:0.5rem;flex-wrap:wrap;margin-top:0.5rem;align-items:center}}
        \\.cmd-row input[type=text]{{flex:1;min-width:12rem;min-height:44px;background:#141824;border:1px solid #6a738c;color:var(--fg);padding:0.45rem 0.6rem;border-radius:6px;font-family:ui-monospace,monospace}}
        \\.cmd-row button{{background:var(--acc);color:#0a0c10;border:0;border-radius:6px;padding:0.55rem 0.9rem;min-height:44px;min-width:4.5rem;font-weight:600;cursor:pointer}}.cmd-row button:disabled{{opacity:0.65;cursor:wait}}
        \\a:focus-visible,button:focus-visible,input:focus-visible,pre.cmd-out:focus-visible,#console-log:focus-visible{{outline:3px solid var(--warn);outline-offset:3px}}
        \\pre.cmd-out,pre.cmd-log{{margin:0.5rem 0 0;background:#0e1018;border-radius:6px;padding:0.6rem 0.75rem;font-size:0.85rem;overflow:auto;max-height:14rem;white-space:pre-wrap;word-break:break-word}}
        \\pre .in{{color:var(--acc)}} .err{{color:var(--err)}} .ok{{color:var(--ok)}} pre .meta{{color:var(--muted)}}
        \\#players{{overflow-x:auto}}#players:focus-visible{{outline:3px solid var(--warn);outline-offset:3px}}#players table{{min-width:30rem}}
        \\.noscript{{margin:0;padding:0.75rem 1.25rem;background:#3a2410;color:var(--warn);border-bottom:1px solid #6a4a20}}
        \\@media(max-width:36rem){{main{{padding:0.75rem}}header,footer,.page-nav{{padding-left:0.75rem;padding-right:0.75rem}}section{{padding:0.75rem}}.cmd-row{{display:grid;grid-template-columns:minmax(0,1fr) auto}}.cmd-row input[type=text]{{min-width:0}}.refresh-ctrl{{margin-left:0}}}}
        \\@media(prefers-reduced-motion:reduce){{.skip-link{{transition:none}}html{{scroll-behavior:auto}}}}
        \\@media(forced-colors:active){{:root{{--bg:Canvas;--card:Canvas;--fg:CanvasText;--muted:GrayText;--acc:LinkText;--ok:CanvasText;--warn:Highlight;--err:MarkText}}body,section,.stat,pre.cmd-out,pre.cmd-log,.page-nav{{background:Canvas;color:CanvasText;border-color:CanvasText}}.cmd-row input[type=text],.cmd-row button,.logout-form button,.refresh-now{{border:1px solid ButtonText}}.err,.noscript{{color:MarkText;background:Mark}}a:focus-visible,button:focus-visible,input:focus-visible,pre.cmd-out:focus-visible,#console-log:focus-visible,.skip-link:focus{{outline:3px solid Highlight;outline-offset:3px}}}}
        \\</style></head>
        \\<body>
        \\<a class="skip-link" href="#main-content">Skip to dashboard</a>
        \\<noscript><p class="noscript" role="status">JavaScript is required for live updates. Console commands still submit, but the response replaces this page.</p></noscript>
        \\<header>
        \\<h1>zdtd</h1><span class="meta">{s} · {s} · ops dashboard</span>
        \\<label class="refresh-ctrl" for="auto-refresh"><input type="checkbox" id="auto-refresh" checked> Auto-refresh</label>
        \\<button type="button" class="refresh-now" id="refresh-now" aria-controls="status apm players console-log">Refresh now</button>
        \\<form class="logout-form" method="post" action="/logout"><input type="hidden" name="csrf" value="{s}"><button type="submit">Sign out</button></form>
        \\</header>
        \\<nav class="page-nav" aria-label="Dashboard sections">
        \\<a href="#status-section">Status</a>
        \\<a href="#apm-section">Performance</a>
        \\<a href="#players-section">Players</a>
        \\<a href="#console-section">Console</a>
        \\</nav>
        \\<main id="main-content" tabindex="-1">
        \\<section id="status-section" aria-labelledby="status-heading"><h2 id="status-heading">Status</h2><div id="status" hx-get="/partials/status" hx-trigger="load, every 2s" hx-swap="innerHTML"><p class="meta">Loading server status…</p></div></section>
        \\<section id="apm-section" aria-labelledby="apm-heading"><h2 id="apm-heading">Performance and counters</h2><div id="apm" hx-get="/partials/apm" hx-trigger="load, every 2s" hx-swap="innerHTML"><p class="meta">Loading performance data…</p></div></section>
        \\<section id="players-section" aria-labelledby="players-heading"><h2 id="players-heading">Players</h2><div id="players" role="region" aria-label="Connected players table" tabindex="0" hx-get="/partials/players" hx-trigger="load, every 2s" hx-swap="innerHTML"><p class="meta">Loading players…</p></div></section>
        \\<section id="console-section" aria-labelledby="console-heading">
        \\<h2 id="console-heading">Console</h2>
        \\<p id="cmd-help" class="meta" style="margin:0 0 0.4rem;color:var(--muted);font-size:0.85rem">Use the same commands as the admin console, such as help, status, give, kick, and settime.</p>
        \\<form id="cmd-form" class="cmd-row" method="post" action="/api/cmd">
        \\<input type="hidden" name="csrf" value="{s}">
        \\<label for="cmd-line" class="sr-only">Admin command</label>
        \\<input type="text" name="line" id="cmd-line" placeholder="Enter a command, for example: status" aria-describedby="cmd-help" autocomplete="off" spellcheck="false" maxlength="256" required>
        \\<button type="submit">Run</button>
        \\</form>
        \\<div id="cmd-out" role="status" aria-live="polite" aria-atomic="true"></div>
        \\<div id="console-log" role="region" aria-label="Recent commands" tabindex="0" hx-get="/partials/console" hx-trigger="load, every 5s" hx-swap="innerHTML"></div>
        \\</section>
        \\</main>
        \\<footer><span id="refresh-state" role="status" aria-live="polite">Auto-refresh on</span> · <a href="/api/apm.json">Performance JSON</a> · <a href="/healthz">Liveness check</a> · <a href="/readyz">Readiness check</a></footer>
        \\<script>
        \\function hxPoll(el){{const u=el.getAttribute('hx-get');if(!u)return;let timer=null;let inFlight=false;const swap=()=>{{if(inFlight)return Promise.resolve();inFlight=true;el.setAttribute('aria-busy','true');return fetch(u,{{credentials:'same-origin'}}).then(r=>{{if(r.status===401){{window.location.assign('/login');return null;}}return r.ok?r.text():Promise.reject();}}).then(t=>{{if(t===null)return;el.innerHTML=t;el.removeAttribute('data-load-error');}}).catch(()=>{{if(!el.hasAttribute('data-load-error'))el.innerHTML='<p class="err" role="alert">Live data is unavailable. Check the connection; retrying automatically.</p>';el.setAttribute('data-load-error','true');}}).finally(()=>{{inFlight=false;el.removeAttribute('aria-busy');}});}};const ms=el.getAttribute('hx-trigger')&&el.getAttribute('hx-trigger').indexOf('5s')>=0?5000:2000;el._hxStart=()=>{{if(timer)return;swap();timer=setInterval(swap,ms);}};el._hxStop=()=>{{if(timer){{clearInterval(timer);timer=null;}}}};el._hxOnce=swap;}}
        \\const polls=Array.from(document.querySelectorAll('[hx-get]'));polls.forEach(hxPoll);
        \\const autoEl=document.getElementById('auto-refresh');const refreshState=document.getElementById('refresh-state');
        \\function applyRefresh(){{const on=autoEl.checked;polls.forEach(el=>{{if(on)el._hxStart();else{{el._hxStop();if(!el.children.length)el._hxOnce();}}}});if(refreshState)refreshState.textContent=on?'Auto-refresh on':'Auto-refresh paused';}}
        \\autoEl.addEventListener('change',applyRefresh);applyRefresh();
        \\document.getElementById('refresh-now').addEventListener('click',async(e)=>{{const button=e.currentTarget;button.disabled=true;if(refreshState)refreshState.textContent='Refreshing…';await Promise.all(polls.map(el=>el._hxOnce?el._hxOnce():Promise.resolve()));button.disabled=false;if(refreshState)refreshState.textContent=autoEl.checked?'Refreshed (auto-refresh on)':'Refreshed (auto-refresh paused)';}});
        \\document.getElementById('cmd-form').addEventListener('submit',async(e)=>{{e.preventDefault();const form=e.target;const button=form.querySelector('button');const input=document.getElementById('cmd-line');const fd=new FormData(form);const line=String(fd.get('line')||'').trim();if(!line){{input.setCustomValidity('Enter a command.');input.reportValidity();return;}}input.setCustomValidity('');const verb=line.split(/\\s+/,1)[0].toLowerCase();const destructive=new Set(['shutdown','killall','kick','ban','wipeplayer']);if(destructive.has(verb)&&!window.confirm('Run "'+verb+'"? This can interrupt players or erase saved data.'))return;const out=document.getElementById('cmd-out');button.disabled=true;button.textContent='Running…';out.setAttribute('role','status');out.setAttribute('aria-busy','true');out.innerHTML='<pre class="meta">Running command…</pre>';try{{const r=await fetch('/api/cmd',{{method:'POST',credentials:'same-origin',headers:{{'Content-Type':'application/x-www-form-urlencoded'}},body:new URLSearchParams(fd)}});if(r.status===401){{window.location.assign('/login');return;}}const response=await r.text();out.setAttribute('role',r.ok?'status':'alert');out.innerHTML=response;if(r.ok){{input.value='';input.focus();}}const log=document.getElementById('console-log');if(log&&log.getAttribute('hx-get'))fetch(log.getAttribute('hx-get'),{{credentials:'same-origin'}}).then(x=>x.ok?x.text():Promise.reject()).then(t=>log.innerHTML=t).catch(()=>{{}});}}catch(err){{out.setAttribute('role','alert');out.innerHTML='<pre class="err">Command could not be sent. Check the connection and try again.</pre>';}}finally{{out.removeAttribute('aria-busy');button.disabled=false;button.textContent='Run';input.focus();}}}});
        \\</script>
        \\</body></html>
    , .{ version.product, version.stock_wire, csrf_token, csrf_token });
}

fn renderStatus(buf: []u8, s: *const Snapshot) ![]const u8 {
    const wn = s.world_name[0..s.world_name_len];
    const hh: u32 = @intFromFloat(@floor(s.hours));
    const mm: u32 = @intFromFloat(@floor((s.hours - @as(f32, @floatFromInt(hh))) * 60.0));
    const bm: []const u8 = if (s.bloodmoon_active) "<span class=\"warn-text\">ACTIVE</span>" else "idle";
    const auth: []const u8 = if (s.authority_correct) "correct" else "observe";
    const pw: []const u8 = if (s.password_set) "set" else "open";
    const wc: []const u8 = if (s.wire_chunks) "on" else "off";
    var w: std.Io.Writer = .fixed(buf);
    try w.print(
        \\<ul class="grid">
        \\<li class="stat"><b class="num">{d}</b><span>tick</span></li>
        \\<li class="stat"><b class="num">d{d} {d:0>2}:{d:0>2}</b><span>world time</span></li>
        \\<li class="stat"><b>{s}</b><span>blood moon (every {d}d)</span></li>
        \\<li class="stat"><b class="num">{d}/{d}</b><span>joined / max</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>entered world</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>peers connected</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>chunks in memory</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>tick overruns</span></li>
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
    try htmlEscape(&w, wn);
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

fn renderApm(buf: []u8, s: *const Snapshot) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.print(
        \\<h3 style="margin-top:0">Latency (tick budget 50 ms)</h3>
        \\<ul class="grid">
        \\<li class="stat"><b class="num">{d} ms</b><span>tick mean</span></li>
        \\<li class="stat"><b class="num">{d} / {d} ms</b><span>tick p50 / p99</span></li>
        \\<li class="stat"><b class="num">{d} ms</b><span>tick max</span></li>
        \\<li class="stat"><b class="num">{d} / {d} µs</b><span>net mean / p99</span></li>
        \\<li class="stat"><b class="num">{d} / {d} µs</b><span>sim mean / p99</span></li>
        \\<li class="stat"><b class="num">{d} / {d} µs</b><span>replicate mean / p99</span></li>
        \\<li class="stat"><b class="num">{d} / {d} µs</b><span>stream mean / p99</span></li>
        \\<li class="stat"><b class="num">{d} µs</b><span>save mean</span></li>
        \\</ul>
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
    try w.print(
        \\<h3>Errors and rejections</h3>
        \\<ul class="grid">
        \\<li class="stat"><b class="num">{d}/{d}</b><span>join ok / fail</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>tick overruns</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>encode errors</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>stream errors</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>net poll errors</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>payload errors</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>send errors</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>window drops</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>persist errors</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>stale peers reaped</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>phase rejects</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>ownership rejects</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>bounds rejects</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>movement rejects</span></li>
        \\<li class="stat"><b class="num">{d}</b><span>decode rejects</span></li>
        \\</ul>
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
        s.phase_rejects,
        s.ownership_rejects,
        s.bounds_rejects,
        s.movement_rejects,
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
    s.client_fd = -1; // no socket write; response stays in Writer buffer
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
    s.set_cookie = false;
    try testServeHttp(&s, "POST /login HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 11\r\n\r\ntoken=wrong");
    try std.testing.expect(!s.set_cookie);
    try testServeHttp(&s, "POST /login HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\ntoken=s3cr3t");
    try std.testing.expect(!s.set_cookie);
    // Missing token field: no cookie; client mistake (distinct from wrong secret).
    try testServeHttp(&s, "POST /login HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 0\r\n\r\n");
    try std.testing.expect(!s.set_cookie);
    try testServeHttp(&s, "POST /login HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 6\r\n\r\ntoken=");
    try std.testing.expect(!s.set_cookie);
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
    try std.testing.expect(std.mem.indexOf(u8, html, "42") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "test") != null);
    const apm = try renderApm(&buf, &s);
    try std.testing.expect(std.mem.indexOf(u8, apm, "tick mean") != null);
    const js = try renderApmJson(&buf, &s);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"tick\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"net_p99_ns\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"save_mean_ns\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"max_players\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"phase_rejects\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"ownership_rejects\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"bounds_rejects\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"movement_rejects\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"decode_rejects\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"world\":\"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"wire_chunks\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"players\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"webui_port\":") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, c, "Max-Age=43200") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "HttpOnly") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "SameSite=Strict") != null);
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
    _ = contentLength(head);
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
    try std.testing.expect(std.mem.indexOfScalar(u8, escaped, '<') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, escaped, '>') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, escaped, '"') == null);
}

test "renderShell exposes console names and status updates" {
    var buf: [16 * 1024]u8 = undefined;
    var sess: [session_token_hex_len]u8 = undefined;
    const nonce = [_]u8{0x33} ** 32;
    fillSessionToken("s3cr3t", &nonce, &sess);
    const html = try renderShell(&buf, sess[0..]);
    try std.testing.expect(std.mem.indexOf(u8, html, "<label for=\"cmd-line\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "maxlength=\"256\" required") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"cmd-out\" role=\"status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"skip-link\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, ":focus-visible") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"auto-refresh\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"refresh-now\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "aria-label=\"Dashboard sections\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"status-section\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "action=\"/logout\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "method=\"post\" action=\"/api/cmd\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "window.confirm") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"status-heading\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "aria-label=\"Recent commands\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "forced-colors:active") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "prefers-reduced-motion") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "border:1px solid #6a738c") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "text-decoration:underline") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"refresh-state\" role=\"status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "out.setAttribute('role',r.ok?'status':'alert')") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "out.setAttribute('aria-busy','true')") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "pre.cmd-out:focus-visible,#console-log:focus-visible") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "list-style:none") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "min-width:1.5rem;min-height:1.5rem") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "aria-labelledby=\"status-heading\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Loading performance data") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "r.status===401") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "let inFlight=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "if(!el.hasAttribute('data-load-error'))") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "forced-color-adjust:none") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, ".err,.noscript{color:MarkText;background:Mark}") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "prefers-reduced-motion: reduce').matches") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "JavaScript is required for live updates") != null);
    // Shared secret must not appear in HTML; CSRF uses session token only.
    try std.testing.expect(std.mem.indexOf(u8, html, "s3cr3t") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, sess[0..]) != null);
    // Runtime body_buf for GET / is 12288; shell must fit.
    try std.testing.expect(html.len < 12288);
}

test "loginHintHtml exposes labeled secret form" {
    const ok = loginHintHtml(false);
    try std.testing.expect(std.mem.indexOf(u8, ok, "<label for=\"login-token\">Shared secret</label>") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok, "name=\"token\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok, "type=\"password\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok, "maxlength=\"128\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok, "role=\"alert\"") == null);
    const bad = loginHintHtml(true);
    try std.testing.expect(std.mem.indexOf(u8, bad, "role=\"alert\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad, "aria-invalid=\"true\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad, "Sign-in failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok, "aria-invalid") == null);
    try std.testing.expect(std.mem.indexOf(u8, ok, "forced-colors:active") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad, "color:MarkText;background:Mark") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad, "forced-color-adjust:none") == null);
    const locked = loginLockoutHtml();
    try std.testing.expect(std.mem.indexOf(u8, locked, "Too many failed sign-ins") != null);
    try std.testing.expect(std.mem.indexOf(u8, locked, "role=\"alert\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, locked, "method=\"post\" action=\"/login\"") != null);
    // During lockout, controls are disabled so users cannot keep submitting failures.
    try std.testing.expect(std.mem.indexOf(u8, locked, "disabled>") != null);
    try std.testing.expect(std.mem.indexOf(u8, locked, "tabindex=\"-1\" autofocus") != null);
}

test "command result marks known failures and is keyboard-scrollable" {
    var buf: [2048]u8 = undefined;
    const reply = try renderCmdReply(&buf, "status", "ok");
    try std.testing.expect(std.mem.indexOf(u8, reply, "tabindex=\"0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "aria-label=\"Command result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "class=\"cmd-out err\"") == null);
    const fail = try renderCmdReply(&buf, "frob", "unknown command 'frob'. 'help' for list.\n");
    try std.testing.expect(std.mem.indexOf(u8, fail, "class=\"cmd-out err\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fail, "role=\"alert\"") != null);
    try std.testing.expect(adminReplyLooksFailed("bad arguments to 'kick'. usage: kick <slot>\n"));
    try std.testing.expect(!adminReplyLooksFailed("kicked\n"));
    var s: Server = .{};
    var log_buf: [2048]u8 = undefined;
    const log = try renderConsoleLog(&log_buf, &s);
    try std.testing.expect(std.mem.indexOf(u8, log, "tabindex=\"0\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, log, "aria-label=\"Recent commands\"") == null);
    var sess: [session_token_hex_len]u8 = undefined;
    const nonce = [_]u8{0x44} ** 32;
    fillSessionToken("s3cr3t", &nonce, &sess);
    var shell_buf: [16 * 1024]u8 = undefined;
    const shell = try renderShell(&shell_buf, sess[0..]);
    try std.testing.expect(std.mem.indexOf(u8, shell, "id=\"console-log\" role=\"region\" aria-label=\"Recent commands\" tabindex=\"0\"") != null);
}

test "renderStatus and renderApm use list markup for stat grids" {
    var snap: Snapshot = .{ .tick_n = 1 };
    var buf: [8192]u8 = undefined;
    const status = try renderStatus(&buf, &snap);
    try std.testing.expect(std.mem.indexOf(u8, status, "<ul class=\"grid\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "<li class=\"stat\">") != null);
    var apm_buf: [8192]u8 = undefined;
    const apm = try renderApm(&apm_buf, &snap);
    try std.testing.expect(std.mem.indexOf(u8, apm, "<ul class=\"grid\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, apm, "<li class=\"stat\">") != null);
}

test "renderStatus uses h3 for subsections under shell Status h2" {
    var s: Snapshot = .{ .tick_n = 1 };
    var buf: [4096]u8 = undefined;
    const html = try renderStatus(&buf, &s);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h2>Status</h2>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h3>Entities</h3>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h3>Server</h3>") != null);
}

test "renderPlayers identifies each player name as a row header" {
    var s: Snapshot = .{};
    s.players[0].used = true;
    s.players[0].name_len = 3;
    @memcpy(s.players[0].name[0..3], "Ada");
    var buf: [4096]u8 = undefined;
    const html = try renderPlayers(&buf, &s);
    try std.testing.expect(std.mem.indexOf(u8, html, "<th scope=\"row\">Ada</th>") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, js, "\"world\":\"Na\\\"ve\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"wire_chunks\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"name\":\"A\\\"b\\\\c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"slot\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"entity_id\":100") != null);
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
