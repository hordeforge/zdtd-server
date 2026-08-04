//! Operator web UI HTTP listener (WU0 + WU1 read-only dashboard).
//! Loopback by default; shared secret required when enabled.
//! Polled from Game.step (non-blocking). Snapshot filled on main thread.
//! Design: docs/WEBUI.md

const std = @import("std");
const linux = std.os.linux;
const version = @import("../version.zig");

pub const max_req: usize = 8192;
pub const max_secret: usize = 128;
pub const max_players_snap: usize = 16;
pub const max_name: usize = 32;
/// Max admin line from web console POST /api/cmd (Game.pollWebui).
pub const max_cmd_line: usize = 256;
pub const max_cmd_out: usize = 4096;

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

pub const Server = struct {
    fd: i32 = -1,
    port: u16 = 0,
    bind_addr: u32 = 0x7f000001,
    secret_buf: [max_secret]u8 = undefined,
    secret_len: usize = 0,
    client_fd: i32 = -1,
    recv_buf: [max_req]u8 = undefined,
    recv_len: usize = 0,
    snap: Snapshot = .{},
    set_cookie: bool = false,
    /// Queued console line from POST /api/cmd (drained by Game.pollWebui).
    cmd_pending: bool = false,
    cmd_line_buf: [max_cmd_line]u8 = undefined,
    cmd_line_len: usize = 0,
    /// Response text filled by Game via finishCmd after runAdminLine.
    cmd_out_buf: [max_cmd_out]u8 = undefined,
    cmd_out_len: usize = 0,

    pub fn enabled(self: *const Server) bool {
        return self.fd >= 0;
    }

    pub fn listen(self: *Server, cfg: Config) !void {
        if (cfg.port == 0) return;
        if (cfg.secret.len == 0) return error.SecretRequired;
        if (cfg.secret.len > max_secret) return error.SecretTooLong;

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

    pub fn publishSnap(self: *Server, s: Snapshot) void {
        self.snap = s;
    }

    fn secret(self: *const Server) []const u8 {
        return self.secret_buf[0..self.secret_len];
    }

    pub fn poll(self: *Server) void {
        if (self.fd < 0) return;
        self.acceptOne();
        if (self.client_fd < 0) return;
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
        self.recv_len = 0;
    }

    fn closeClient(self: *Server) void {
        if (self.client_fd >= 0) _ = linux.close(self.client_fd);
        self.client_fd = -1;
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
        self.serveRequest(self.recv_buf[0..head_end]) catch {
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

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/login")) {
            if (queryToken(target)) |tok| {
                if (constantTimeEql(tok, self.secret())) {
                    self.set_cookie = true;
                    self.respondRedirect("/");
                    return;
                }
            }
            self.respond(401, "text/html; charset=utf-8", loginHintHtml());
            return;
        }

        if (!requestAuthorized(head, target, self.secret())) {
            self.respond(401, "text/html; charset=utf-8", loginHintHtml());
            return;
        }
        if (queryToken(target)) |tok| {
            if (constantTimeEql(tok, self.secret())) self.set_cookie = true;
        }

        if (!std.mem.eql(u8, method, "GET")) {
            self.respond(405, "text/plain; charset=utf-8", "method not allowed\n");
            return;
        }

        var body_buf: [12288]u8 = undefined;
        if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
            self.respond(200, "text/html; charset=utf-8", try renderShell(&body_buf));
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
        if (std.mem.eql(u8, path, "/api/apm.json")) {
            self.respond(200, "application/json; charset=utf-8", try renderApmJson(&body_buf, &self.snap));
            return;
        }
        self.respond(404, "text/plain; charset=utf-8", "not found\n");
    }

    fn respondRedirect(self: *Server, loc: []const u8) void {
        const fd = self.client_fd;
        if (fd < 0) return;
        var hdr: [640]u8 = undefined;
        const cookie_part = if (self.set_cookie)
            std.fmt.bufPrint(hdr[400..], "Set-Cookie: zdtd_webui={s}; Path=/; HttpOnly; SameSite=Strict\r\n", .{self.secret()}) catch ""
        else
            "";
        // Build header in two steps
        var hbuf: [768]u8 = undefined;
        const h = if (self.set_cookie)
            std.fmt.bufPrint(&hbuf, "HTTP/1.1 302 Found\r\nLocation: {s}\r\nSet-Cookie: zdtd_webui={s}; Path=/; HttpOnly; SameSite=Strict\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{ loc, self.secret() }) catch return
        else
            std.fmt.bufPrint(&hbuf, "HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{loc}) catch return;
        _ = cookie_part;
        writeAll(fd, h);
    }

    fn respond(self: *Server, status: u16, content_type: []const u8, body: []const u8) void {
        const fd = self.client_fd;
        if (fd < 0) return;
        const reason: []const u8 = switch (status) {
            200 => "OK",
            400 => "Bad Request",
            401 => "Unauthorized",
            404 => "Not Found",
            405 => "Method Not Allowed",
            413 => "Payload Too Large",
            500 => "Internal Server Error",
            else => "Error",
        };
        var hdr: [768]u8 = undefined;
        const h = if (self.set_cookie)
            std.fmt.bufPrint(&hdr, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nSet-Cookie: zdtd_webui={s}; Path=/; HttpOnly; SameSite=Strict\r\n\r\n", .{ status, reason, content_type, body.len, self.secret() }) catch return
        else
            std.fmt.bufPrint(&hdr, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n", .{ status, reason, content_type, body.len }) catch return;
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

fn queryToken(target: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "token=")) return pair["token=".len..];
    }
    return null;
}

fn requestAuthorized(head: []const u8, target: []const u8, secret: []const u8) bool {
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
    if (headerValue(head, "Cookie")) |ck| {
        if (cookieValue(ck, "zdtd_webui")) |cv| {
            if (constantTimeEql(cv, secret)) return true;
        }
    }
    if (queryToken(target)) |tok| {
        if (constantTimeEql(tok, secret)) return true;
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

fn loginHintHtml() []const u8 {
    return
    \\<!DOCTYPE html>
    \\<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    \\<title>zdtd webui login</title>
    \\<style>body{font-family:system-ui,sans-serif;margin:2rem;max-width:36rem;line-height:1.5;color:#e8e8e8;background:#1a1a1a}
    \\code{background:#333;padding:0.15em 0.4em;border-radius:3px}a{color:#7eb8ff}</style></head>
    \\<body><main><h1>zdtd webui</h1>
    \\<p>Unauthorized. Open <code>/login?token=YOUR_SECRET</code> once to set a cookie, or send
    \\<code>Authorization: Bearer …</code> / <code>X-Zdtd-Secret</code>.</p>
    \\<p>See docs/WEBUI.md</p></main></body></html>
    ;
}

fn renderShell(buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf,
        \\<!DOCTYPE html>
        \\<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        \\<title>zdtd webui</title>
        \\<style>
        \\:root{{--bg:#12141a;--card:#1c2030;--fg:#e8eaef;--muted:#9aa3b5;--acc:#5b9fd4;--ok:#6bcb77;--warn:#e8a838}}
        \\*{{box-sizing:border-box}}body{{font-family:system-ui,sans-serif;margin:0;background:var(--bg);color:var(--fg);line-height:1.45}}
        \\header{{padding:1rem 1.25rem;border-bottom:1px solid #2a3144;display:flex;gap:1rem;align-items:baseline;flex-wrap:wrap}}
        \\header h1{{font-size:1.15rem;margin:0;font-weight:600}}header .meta{{color:var(--muted);font-size:0.9rem}}
        \\main{{padding:1rem 1.25rem;display:grid;gap:1rem;max-width:56rem}}
        \\section{{background:var(--card);border-radius:8px;padding:0.85rem 1rem;border:1px solid #2a3144}}
        \\section h2{{margin:0 0 0.6rem;font-size:0.95rem;color:var(--acc);font-weight:600;text-transform:uppercase;letter-spacing:0.04em}}
        \\table{{width:100%;border-collapse:collapse;font-size:0.9rem}}th,td{{text-align:left;padding:0.35rem 0.5rem;border-bottom:1px solid #2a3144}}
        \\th{{color:var(--muted);font-weight:500}} .num{{font-variant-numeric:tabular-nums}}
        \\.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(7.5rem,1fr));gap:0.5rem}}
        \\.stat{{background:#141824;border-radius:6px;padding:0.5rem 0.65rem}}.stat b{{display:block;font-size:1.1rem}}.stat span{{color:var(--muted);font-size:0.75rem}}
        \\footer{{padding:0.75rem 1.25rem;color:var(--muted);font-size:0.8rem}}
        \\</style></head>
        \\<body>
        \\<header><h1>zdtd</h1><span class="meta">{s} · {s} · webui WU1</span></header>
        \\<main>
        \\<section id="status" hx-get="/partials/status" hx-trigger="load, every 2s" hx-swap="innerHTML"><p class="meta">loading…</p></section>
        \\<section><h2>Players</h2><div id="players" hx-get="/partials/players" hx-trigger="load, every 2s" hx-swap="innerHTML"></div></section>
        \\<section><h2>APM</h2><div id="apm" hx-get="/partials/apm" hx-trigger="load, every 2s" hx-swap="innerHTML"></div></section>
        \\</main>
        \\<footer>Auto-refresh 2s · <a href="/api/apm.json" style="color:var(--acc)">/api/apm.json</a> · <a href="/healthz" style="color:var(--acc)">/healthz</a></footer>
        \\<script>
        \\/* minimal hx-get poller (no CDN) */
        \\function hxPoll(el){{const u=el.getAttribute('hx-get');if(!u)return;const swap=()=>fetch(u,{{credentials:'same-origin'}}).then(r=>r.ok?r.text():Promise.reject()).then(t=>{{el.innerHTML=t;}}).catch(()=>{{}});swap();setInterval(swap,2000);}}
        \\document.querySelectorAll('[hx-get]').forEach(hxPoll);
        \\</script>
        \\</body></html>
    , .{ version.product, version.stock_wire });
}

fn renderStatus(buf: []u8, s: *const Snapshot) ![]const u8 {
    const wn = s.world_name[0..s.world_name_len];
    const hh: u32 = @intFromFloat(@floor(s.hours));
    const mm: u32 = @intFromFloat(@floor((s.hours - @as(f32, @floatFromInt(hh))) * 60.0));
    const bm: []const u8 = if (s.bloodmoon_active) "ACTIVE" else "idle";
    const auth: []const u8 = if (s.authority_correct) "correct" else "observe";
    const pw: []const u8 = if (s.password_set) "set" else "open";
    const wc: []const u8 = if (s.wire_chunks) "on" else "off";
    return std.fmt.bufPrint(buf,
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
        \\<h2 style="margin-top:1rem">Server</h2>
        \\<div class="grid">
        \\<div class="stat"><b>{s}</b><span>world</span></div>
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
        s.tick_n,      s.day,                 hh,               mm,
        bm,            s.bloodmoon_frequency, s.joined,         s.max_players,
        s.entered,     s.peers_alive,         s.chunks,         s.tick_overruns,
        s.zombies,     s.max_spawned_zombies, s.animals,        s.players_ent,
        s.traders,     s.vehicles,            s.turrets,        s.loot_bags,
        wn,            s.info_port,           s.info_port +% 2, s.webui_port,
        s.view_radius, s.max_streamed_chunks, s.interest_range, s.max_edit_range,
        auth,          pw,                    wc,
    });
}

fn renderPlayers(buf: []u8, s: *const Snapshot) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("<table><thead><tr><th>#</th><th>Name</th><th>Ent</th><th>Pos</th><th>State</th></tr></thead><tbody>");
    var any = false;
    for (s.players) |p| {
        if (!p.used) continue;
        any = true;
        const nm = p.name[0..p.name_len];
        const st: []const u8 = if (p.entered) "entered" else if (p.joined) "joined" else "...";
        try w.print(
            \\<tr><td class="num">{d}</td><td>{s}</td><td class="num">{d}</td><td class="num">{d:.0},{d:.0},{d:.0}</td><td>{s}</td></tr>
        , .{ p.slot, nm, p.entity_id, p.x, p.y, p.z, st });
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
    return std.fmt.bufPrint(buf,
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
        ms(s.tick_mean_ns),      ms(s.tick_p50_ns),    ms(s.tick_p99_ns),    ms(s.tick_max_ns),
        us(s.net_mean_ns),       us(s.net_p99_ns),     us(s.sim_mean_ns),    us(s.sim_p99_ns),
        us(s.repl_mean_ns),      us(s.repl_p99_ns),    us(s.stream_mean_ns), us(s.stream_p99_ns),
        us(s.save_mean_ns),      s.net_packets_in,     s.net_packets_out,    s.net_bytes_in,
        s.net_bytes_out,         s.packages_encoded,   s.packages_broadcast, s.entities_ticked,
        s.join_ok,               s.join_fail,          s.tick_overruns,      s.encode_errors,
        s.stream_errors,         s.net_poll_errors,    s.net_payload_errors, s.net_send_errors,
        s.reliable_window_drops, s.persistence_errors, s.stale_peers_reaped,
    });
}

fn renderApmJson(buf: []u8, s: *const Snapshot) ![]const u8 {
    return std.fmt.bufPrint(buf,
        \\{{"type":"zdtd_webui_apm","tick":{d},"day":{d},"hours":{d:.2},"joined":{d},"entered":{d},"peers":{d},"zombies":{d},"chunks":{d},"tick_overruns":{d},"encode_errors":{d},"stream_errors":{d},"tick_mean_ns":{d},"tick_p50_ns":{d},"tick_p99_ns":{d},"join_ok":{d},"join_fail":{d}}}
        \\
    , .{
        s.tick_n,
        s.day,
        s.hours,
        s.joined,
        s.entered,
        s.peers_alive,
        s.zombies,
        s.chunks,
        s.tick_overruns,
        s.encode_errors,
        s.stream_errors,
        s.tick_mean_ns,
        s.tick_p50_ns,
        s.tick_p99_ns,
        s.join_ok,
        s.join_fail,
    });
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
    const h2 = "GET / HTTP/1.1\r\nCookie: zdtd_webui=s3cr3t; other=1\r\n";
    try std.testing.expect(requestAuthorized(h2, "/", "s3cr3t"));
    try std.testing.expect(!requestAuthorized(h2, "/", "nope"));
}

test "listen refuses empty secret" {
    var s: Server = .{};
    defer s.deinit();
    try std.testing.expectError(error.SecretRequired, s.listen(.{ .port = 1, .secret = "" }));
}

test "render status fits buffer" {
    var s: Snapshot = .{ .tick_n = 42, .day = 3, .hours = 14.5, .joined = 2, .max_players = 8 };
    @memcpy(s.world_name[0..4], "test");
    s.world_name_len = 4;
    var buf: [2048]u8 = undefined;
    const html = try renderStatus(&buf, &s);
    try std.testing.expect(std.mem.indexOf(u8, html, "42") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "test") != null);
}
