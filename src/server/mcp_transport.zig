//! MCP transport bridge (ADR 0031, RFC 0002 §3): a dedicated HTTP
//! listener that carries MCP JSON-RPC frames between clients and the MCP
//! plugin guest. The guest owns protocol; this file owns the bytes on the
//! wire: listener, HTTP framing, token auth, and the bounded copy of each
//! frame into / response out of the guest hook.
//!
//! Like webui.zig and the admin console, the transport is polled from the
//! main loop (ADR 0012 single-threaded tick): one connection and one full
//! request per poll call, processed synchronously through the frame handler.
//! There are no extra threads, no queues, and no condvars; a slow or flooding
//! client only stalls the poll step, bounded by the per-request caps.
//!
//! Fail closed: wrong path/method, malformed framing, an oversized frame, and
//! a missing token are HTTP errors; a guest that replies with nothing is
//! answered 202 (MCP notification semantics), never a fake body (ADR 0014).

const std = @import("std");
const tcp = @import("../util/tcp_listen.zig");
const http = std.http;
const secret_mod = @import("../util/secret.zig");

/// Inbound JSON-RPC frame cap (RFC 0002 §7 `max_frame_kib`).
pub const max_frame: usize = 16 * 1024;
/// Guest response cap (RFC 0002 §7 `out_buf`).
pub const max_resp: usize = 8 * 1024;
/// Full HTTP request cap: frame plus headers.
const max_req: usize = max_frame + 4096;
const max_token: usize = 128;
/// Polls before an incomplete request is dropped (~10 s at 4 polls per tick).
const max_client_polls: u32 = 800;

pub const Config = struct {
    port: u16 = 0,
    bind_host: []const u8 = "127.0.0.1",
    /// Empty = loopback only, no token. Non-empty tokens are compared in
    /// constant time (util/secret.zig).
    token: []const u8 = "",
};

/// The Game-side frame handler: takes one client JSON-RPC frame and writes
/// the guest's response into `out`, returning bytes written (0 = nothing to
/// send: notification, closed session, or overflowed response).
pub const FrameFn = *const fn (ctx: *anyopaque, frame: []const u8, out: []u8) usize;

pub const Transport = struct {
    listener: tcp.Listener = .{},
    port: u16 = 0,
    client_fd: i32 = -1,
    client_polls: u32 = 0,
    recv_buf: [max_req]u8 = undefined,
    recv_len: usize = 0,
    token_buf: [max_token]u8 = undefined,
    token_len: usize = 0,
    frame_fn: ?FrameFn = null,
    frame_ctx: ?*anyopaque = null,
    /// Requests served (observability; a client seeing 200s while `served`
    /// does not advance has lost its connection).
    served: u64 = 0,
    /// When `client_fd < 0` (unit tests), the last response is captured here
    /// so assertions can check status lines without a real socket.
    test_resp_len: usize = 0,
    test_resp: [max_resp + 2048]u8 = undefined,

    pub fn enabled(self: *const Transport) bool {
        return self.listener.enabled();
    }

    pub fn setFrameHandler(self: *Transport, ctx: *anyopaque, f: FrameFn) void {
        self.frame_ctx = ctx;
        self.frame_fn = f;
    }

    pub fn listen(self: *Transport, cfg: Config) !void {
        if (cfg.port == 0) return;
        if (cfg.token.len > max_token) return error.TokenTooLong;
        const addr_host = try parseIpv4(cfg.bind_host);
        if (!isLoopbackIpv4(addr_host)) return error.LoopbackRequired;
        try self.listener.listen(addr_host, cfg.port, 8);
        @memcpy(self.token_buf[0..cfg.token.len], cfg.token);
        self.token_len = cfg.token.len;
        self.port = self.listener.port;
        self.client_fd = -1;
        self.recv_len = 0;
    }

    pub fn deinit(self: *Transport) void {
        if (self.client_fd >= 0) tcp.closeFd(self.client_fd);
        self.client_fd = -1;
        self.recv_len = 0;
        self.listener.deinit();
        self.port = 0;
        if (self.token_len > 0) @memset(self.token_buf[0..self.token_len], 0);
        self.token_len = 0;
    }

    fn token(self: *const Transport) []const u8 {
        return self.token_buf[0..self.token_len];
    }

    /// One poll call: accept a connection if idle, then serve at most one
    /// complete request (mirrors webui.zig poll/readAndServe).
    pub fn poll(self: *Transport) void {
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

    fn acceptOne(self: *Transport) void {
        if (self.client_fd >= 0) return;
        const cfd = self.listener.accept() catch return orelse return;
        self.client_fd = cfd;
        self.client_polls = 0;
        self.recv_len = 0;
    }

    fn closeClient(self: *Transport) void {
        if (self.client_fd >= 0) tcp.closeFd(self.client_fd);
        self.client_fd = -1;
        self.client_polls = 0;
        self.recv_len = 0;
    }

    fn readAndServe(self: *Transport) void {
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

        // Wait until headers are complete before handing off to std.http.
        const head_end = std.mem.find(u8, self.recv_buf[0..self.recv_len], "\r\n\r\n") orelse {
            if (self.recv_len >= max_req) self.closeClient();
            return;
        };
        // Pre-check Content-Length so we accumulate a full body (non-blocking).
        const clen = peekContentLength(self.recv_buf[0 .. head_end + 4]) catch |err| {
            const msg: []const u8 = switch (err) {
                error.UnsupportedTransferEncoding => "unsupported transfer encoding\n",
                error.DuplicateContentLength => "duplicate content length\n",
                error.InvalidContentLength => "invalid content length\n",
            };
            self.rawRespond(400, msg);
            self.closeClient();
            return;
        };
        const prefix = head_end + 4;
        if (clen > max_req or prefix > max_req or clen > max_req - prefix) {
            self.rawRespond(413, "request too large\n");
            self.closeClient();
            return;
        }
        const need = prefix + clen;
        if (self.recv_len < need) return;

        self.serveHttp() catch |err| {
            std.debug.print("zdtd: mcp request failed: {s}\n", .{@errorName(err)});
            self.rawRespond(500, "internal error\n");
        };
        self.closeClient();
    }

    /// Parse and respond with `std.http.Server` over the buffered request
    /// bytes. Only POST /mcp is served; everything else is an HTTP error.
    fn serveHttp(self: *Transport) !void {
        var in_r: std.Io.Reader = .fixed(self.recv_buf[0..self.recv_len]);
        var out_buf: [max_resp + 2048]u8 = undefined;
        var out_w: std.Io.Writer = .fixed(&out_buf);
        var http_srv = http.Server.init(&in_r, &out_w);
        var req = http_srv.receiveHead() catch |err| {
            switch (err) {
                error.HttpHeadersInvalid => self.rawRespond(400, "bad request\n"),
                error.HttpHeadersOversize => self.rawRespond(431, "header fields too large\n"),
                else => {},
            }
            return;
        };

        const path = pathOnly(req.head.target);
        if (!std.mem.eql(u8, path, "/mcp")) {
            try self.httpRespond(&req, .not_found, "text/plain; charset=utf-8", "not found\n", &.{});
            return;
        }
        if (req.head.method != .POST) {
            try self.httpRespond(&req, .method_not_allowed, "text/plain; charset=utf-8", "method not allowed\n", &.{
                .{ .name = "Allow", .value = "POST" },
            });
            return;
        }
        if (req.head.transfer_encoding != .none) {
            try self.httpRespond(&req, .bad_request, "text/plain; charset=utf-8", "unsupported transfer encoding\n", &.{});
            return;
        }
        if (self.token_len > 0 and !requestAuthorized(&req, self.token())) {
            try self.httpRespond(&req, .unauthorized, "text/plain; charset=utf-8", "unauthorized\n", &.{});
            return;
        }
        const body = self.recv_buf[in_r.seek..in_r.end];
        if (body.len > max_frame) {
            try self.httpRespond(&req, .payload_too_large, "text/plain; charset=utf-8", "frame too large\n", &.{});
            return;
        }
        const ff = self.frame_fn orelse {
            try self.httpRespond(&req, .service_unavailable, "text/plain; charset=utf-8", "no mcp module\n", &.{});
            return;
        };
        var resp_buf: [max_resp]u8 = undefined;
        const n = ff(self.frame_ctx orelse return error.NoFrameHandler, body, &resp_buf);
        self.served += 1;
        if (n == 0) {
            // Notification / no reply: MCP says 202 Accepted with no body.
            try self.httpRespond(&req, .accepted, "", "", &.{});
        } else {
            try self.httpRespond(&req, .ok, "application/json", resp_buf[0..n], &.{});
        }
    }

    fn httpRespond(
        self: *Transport,
        req: *http.Server.Request,
        status: http.Status,
        content_type: []const u8,
        body: []const u8,
        extra: []const http.Header,
    ) !void {
        var hdrs: [8]http.Header = undefined;
        var n: usize = 0;
        if (content_type.len > 0) {
            hdrs[n] = .{ .name = "Content-Type", .value = content_type };
            n += 1;
        }
        hdrs[n] = .{ .name = "Cache-Control", .value = "no-store" };
        n += 1;
        hdrs[n] = .{ .name = "Connection", .value = "close" };
        n += 1;
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
        const out = req.server.out.buffered();
        const fd = self.client_fd;
        if (fd < 0) {
            self.captureTestResp(out);
        } else {
            tcp.writeAll(fd, out);
        }
    }

    /// Early raw response before std.http.Server is set up.
    fn rawRespond(self: *Transport, status: u16, body: []const u8) void {
        var hdr: [384]u8 = undefined;
        const h = std.fmt.bufPrint(
            &hdr,
            "HTTP/1.1 {d} {s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
            .{ status, httpReasonPhrase(status), body.len },
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

    fn captureTestResp(self: *Transport, data: []const u8) void {
        const space = self.test_resp.len - self.test_resp_len;
        const n = @min(data.len, space);
        if (n == 0) return;
        @memcpy(self.test_resp[self.test_resp_len..][0..n], data[0..n]);
        self.test_resp_len += n;
    }

    fn testResp(self: *const Transport) []const u8 {
        return self.test_resp[0..self.test_resp_len];
    }
};

// ---------------------------------------------------------------------------
// Small HTTP helpers (mirror webui.zig idioms; private to this file).

fn pathOnly(target: []const u8) []const u8 {
    return target[0 .. std.mem.findScalar(u8, target, '?') orelse target.len];
}

fn httpReasonPhrase(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        202 => "Accepted",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        413 => "Payload Too Large",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "Error",
    };
}

fn peekContentLength(buf: []const u8) !usize {
    var clen: ?usize = null;
    var it = std.mem.splitSequence(u8, buf, "\r\n");
    _ = it.next(); // request line
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            const n = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
            if (clen != null) return error.DuplicateContentLength;
            clen = n;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            return error.UnsupportedTransferEncoding;
        }
    }
    return clen orelse 0;
}

fn headerFromReq(req: *const http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

fn requestAuthorized(req: *const http.Server.Request, token: []const u8) bool {
    if (headerFromReq(req, "Authorization")) |auth| {
        const v = std.mem.trim(u8, auth, " \t");
        if (v.len > 7 and std.ascii.eqlIgnoreCase(v[0..7], "bearer ")) {
            if (secret_mod.constantTimeEql(v[7..], token)) return true;
        }
    }
    if (headerFromReq(req, "X-Zdtd-Secret")) |v| {
        if (secret_mod.constantTimeEql(std.mem.trim(u8, v, " \t"), token)) return true;
    }
    return false;
}

fn parseIpv4(host: []const u8) !u32 {
    if (std.mem.eql(u8, host, "localhost")) return 0x7f000001;
    var it = std.mem.splitScalar(u8, host, '.');
    var out: u32 = 0;
    var i: u3 = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return error.InvalidIpv4;
        const oct = std.fmt.parseInt(u8, part, 10) catch return error.InvalidIpv4;
        out = (out << 8) | oct;
    }
    if (i != 4) return error.InvalidIpv4;
    return out;
}

fn isLoopbackIpv4(addr: u32) bool {
    return (addr & 0xff000000) == 0x7f000000;
}

// ---------------------------------------------------------------------------
// Tests

/// Test/ops helper (mirrors webui.zig testServeHttp): load one complete
/// HTTP/1.1 request into recv_buf and run the std.http path without a real
/// socket; the response is captured into test_resp for assertions.
pub fn testServeHttp(s: *Transport, request: []const u8) !void {
    if (request.len > s.recv_buf.len) return error.Overflow;
    @memcpy(s.recv_buf[0..request.len], request);
    s.recv_len = request.len;
    s.client_fd = -1; // no socket write; response is captured into test_resp
    s.test_resp_len = 0;
    try s.serveHttp();
}

const Stub = struct {
    var resp: []const u8 = "";
    var seen: [256]u8 = undefined;
    var seen_len: usize = 0;

    fn frameFn(ctx: *anyopaque, frame: []const u8, out: []u8) usize {
        _ = ctx;
        const n = @min(frame.len, seen.len);
        @memcpy(seen[0..n], frame[0..n]);
        seen_len = n;
        const m = @min(resp.len, out.len);
        @memcpy(out[0..m], resp[0..m]);
        return m;
    }
};

test "mcp transport: POST /mcp round-trips a frame and the response" {
    var t: Transport = .{};
    t.setFrameHandler(&t, Stub.frameFn);
    Stub.resp = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
    defer {
        Stub.resp = "";
        Stub.seen_len = 0;
    }
    try testServeHttp(&t, "POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 40\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}");
    try std.testing.expect(std.mem.find(u8, t.testResp(), "HTTP/1.1 200 ") != null);
    try std.testing.expect(std.mem.find(u8, t.testResp(), Stub.resp) != null);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}", Stub.seen[0..Stub.seen_len]);
    try std.testing.expectEqual(@as(u64, 1), t.served);
}

test "mcp transport: zero reply is a 202 (notification semantics)" {
    var t: Transport = .{};
    t.setFrameHandler(&t, Stub.frameFn);
    Stub.resp = "";
    defer Stub.resp = "";
    try testServeHttp(&t, "POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}");
    try std.testing.expect(std.mem.find(u8, t.testResp(), "HTTP/1.1 202 ") != null);
}

test "mcp transport: path, method and token gates fail closed" {
    var t: Transport = .{};
    t.setFrameHandler(&t, Stub.frameFn);
    Stub.resp = "{}";
    defer Stub.resp = "";
    // Wrong path is 404.
    try testServeHttp(&t, "POST /nope HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}");
    try std.testing.expect(std.mem.find(u8, t.testResp(), "HTTP/1.1 404 ") != null);
    // GET is 405.
    try testServeHttp(&t, "GET /mcp HTTP/1.1\r\n\r\n");
    try std.testing.expect(std.mem.find(u8, t.testResp(), "HTTP/1.1 405 ") != null);
    // With a token configured, an anonymous request is 401.
    @memcpy(t.token_buf[0..6], "s3cr3t");
    t.token_len = 6;
    try testServeHttp(&t, "POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}");
    try std.testing.expect(std.mem.find(u8, t.testResp(), "HTTP/1.1 401 ") != null);
    // The right bearer token passes.
    try testServeHttp(&t, "POST /mcp HTTP/1.1\r\nAuthorization: Bearer s3cr3t\r\nContent-Length: 2\r\n\r\n{}");
    try std.testing.expect(std.mem.find(u8, t.testResp(), "HTTP/1.1 200 ") != null);
    // A wrong token is 401.
    try testServeHttp(&t, "POST /mcp HTTP/1.1\r\nAuthorization: Bearer wrong\r\nContent-Length: 2\r\n\r\n{}");
    try std.testing.expect(std.mem.find(u8, t.testResp(), "HTTP/1.1 401 ") != null);
    t.token_len = 0;
}

test "mcp transport: oversized frame and transfer encoding are rejected" {
    var t: Transport = .{};
    t.setFrameHandler(&t, Stub.frameFn);
    Stub.resp = "{}";
    defer Stub.resp = "";
    try testServeHttp(&t, "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n");
    try std.testing.expect(std.mem.find(u8, t.testResp(), "HTTP/1.1 400 ") != null);
    // A body over the frame cap is 413 (fail closed, never truncated).
    var body: [max_frame + 1024]u8 = undefined;
    @memset(&body, 'x');
    var req_buf: [max_req]u8 = undefined;
    const head = try std.fmt.bufPrint(&req_buf, "POST /mcp HTTP/1.1\r\nContent-Length: {d}\r\n\r\n", .{body.len});
    @memcpy(req_buf[head.len..][0..body.len], &body);
    try testServeHttp(&t, req_buf[0 .. head.len + body.len]);
    try std.testing.expect(std.mem.find(u8, t.testResp(), "HTTP/1.1 413 ") != null);
}

test "mcp transport: binding is loopback only" {
    try std.testing.expect(isLoopbackIpv4(try parseIpv4("127.0.0.1")));
    try std.testing.expect(isLoopbackIpv4(try parseIpv4("localhost")));
    try std.testing.expect(!isLoopbackIpv4(try parseIpv4("0.0.0.0")));
    try std.testing.expect(!isLoopbackIpv4(try parseIpv4("192.168.1.2")));
    var t: Transport = .{};
    try std.testing.expectError(error.LoopbackRequired, t.listen(.{ .port = 28015, .bind_host = "0.0.0.0" }));
}

// ---------------------------------------------------------------------------
// End-to-end: the real MCP guest behind the transport (ADR 0031 M2 harness).
// The transport serves raw HTTP frames in test mode; the frame handler runs
// mods/mcp/mcp.wasm with a sense/query Cap standing in for Game.

const plugin_mod = @import("../plugin/wasm.zig");

test "mcp transport e2e: real guest over HTTP (initialize, tools, call)" {
    const Cap = struct {
        var queued: [2][64]u8 = undefined;
        var queued_len: [2]usize = undefined;
        var queued_n: usize = 0;

        fn logFn(_: *plugin_mod.HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *plugin_mod.HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *plugin_mod.HostCtx, _: i16, cmd: []const u8) void {
            if (queued_n >= queued.len) return;
            const n = @min(cmd.len, queued[queued_n].len);
            @memcpy(queued[queued_n][0..n], cmd[0..n]);
            queued_len[queued_n] = n;
            queued_n += 1;
        }
        fn writeRec(b: []u8, base: usize, net: i32, kind: u8, x: f32, y: f32, z: f32, hp: f32) void {
            const r = b[base .. base + 32];
            std.mem.writeInt(i32, r[0..4], net, .little);
            r[4] = kind;
            r[5] = 0; // is_self
            r[6] = 1; // alive
            r[7] = 0; // pad
            std.mem.writeInt(u32, r[8..12], @bitCast(x), .little);
            std.mem.writeInt(u32, r[12..16], @bitCast(y), .little);
            std.mem.writeInt(u32, r[16..20], @bitCast(z), .little);
            std.mem.writeInt(u32, r[20..24], @bitCast(hp), .little);
            std.mem.writeInt(u32, r[24..28], @bitCast(@as(f32, 0.0)), .little);
            std.mem.writeInt(i32, r[28..32], -1, .little);
        }
        fn senseFn(_: *plugin_mod.HostCtx, out: []u8) usize {
            // header: magic 'ZBS3' (24 bytes), 1 record (player 2000), tick 42, self -1
            std.mem.writeInt(u32, out[0..4], 0x3353425a, .little);
            std.mem.writeInt(u32, out[4..8], 1, .little);
            std.mem.writeInt(u32, out[8..12], 42, .little);
            std.mem.writeInt(i32, out[12..16], -1, .little);
            std.mem.writeInt(u32, out[16..20], 0, .little); // world_time
            std.mem.writeInt(u32, out[20..24], 0, .little); // blood_moon
            writeRec(out, 24, 2000, 0, 10.0, 0.0, 10.0, 100.0);
            return 24 + 32;
        }
        fn queryFn(_: *plugin_mod.HostCtx, req: []const u8, out: []u8) usize {
            if (!std.mem.eql(u8, req, "mcp.allowlist")) return 0;
            const allow = "bot count\nsay";
            const n = @min(out.len, allow.len);
            @memcpy(out[0..n], allow[0..n]);
            return n;
        }
    };
    Cap.queued_n = 0;

    var ctx = plugin_mod.HostCtx{
        .log_fn = &Cap.logFn,
        .tick_fn = &Cap.tickFn,
        .queue_fn = &Cap.queueFn,
        .sense_fn = &Cap.senseFn,
        .query_fn = &Cap.queryFn,
    };
    var host: plugin_mod.WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"mods/mcp/mcp.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expectEqual(@as(usize, 1), host.count());

    // The Game-side frame handler: first plugin exporting on_mcp_frame wins
    // (mirrors wasm_host.mcpFrameThunk).
    const E2e = struct {
        var h: *plugin_mod.WasmHost = undefined;
        fn frameFn(_: *anyopaque, frame: []const u8, out: []u8) usize {
            for (h.slots[0..h.n]) |*p| {
                if (p.hook_present[@intFromEnum(plugin_mod.Hook.on_mcp_frame)]) {
                    const rep = p.callMcpFrame(frame, out) orelse return 0;
                    return rep.len;
                }
            }
            return 0;
        }
    };
    E2e.h = &host;

    var t: Transport = .{};
    t.setFrameHandler(&host, E2e.frameFn); // ctx unused; the thunk uses E2e.h
    var req_buf: [2048]u8 = undefined;

    const send = struct {
        fn post(tr: *Transport, body: []const u8, buf: []u8) !void {
            const req = try std.fmt.bufPrint(buf, "POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
            try testServeHttp(tr, req);
        }
    }.post;

    // initialize negotiates the pinned version.
    try send(&t, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"e2e\",\"version\":\"1\"}}}", &req_buf);
    try std.testing.expect(std.mem.find(u8, t.testResp(), "HTTP/1.1 200 ") != null);
    try std.testing.expect(std.mem.find(u8, t.testResp(), "\"protocolVersion\":\"2025-06-18\"") != null);
    try std.testing.expect(std.mem.find(u8, t.testResp(), "\"serverInfo\"") != null);

    // The initialized notification gets 202 (no response body).
    try send(&t, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}", &req_buf);
    try std.testing.expect(std.mem.find(u8, t.testResp(), "HTTP/1.1 202 ") != null);

    // tools/list advertises the registry.
    try send(&t, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", &req_buf);
    try std.testing.expect(std.mem.find(u8, t.testResp(), "\"tools\":[") != null);
    try std.testing.expect(std.mem.find(u8, t.testResp(), "\"name\":\"server_status\"") != null);

    // tools/call reads real snapshot data through the plugin boundary.
    try send(&t, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"server_status\"}}", &req_buf);
    try std.testing.expect(std.mem.find(u8, t.testResp(), "ticks=42") != null);
    try std.testing.expect(std.mem.find(u8, t.testResp(), "players=1") != null);

    // admin_command queues an allowlisted verb through the plugin boundary.
    try send(&t, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"admin_command\",\"arguments\":{\"verb\":\"bot count 6\"}}}", &req_buf);
    try std.testing.expect(std.mem.find(u8, t.testResp(), "queued") != null);
    try std.testing.expectEqual(@as(usize, 1), Cap.queued_n);
    try std.testing.expect(std.mem.eql(u8, Cap.queued[0][0..Cap.queued_len[0]], "bot count 6"));

    // A malformed frame still yields a JSON-RPC parse error inside a 200 body
    // (the transport never sees it; the guest fails closed).
    try send(&t, "{nope", &req_buf);
    try std.testing.expect(std.mem.find(u8, t.testResp(), "HTTP/1.1 200 ") != null);
    try std.testing.expect(std.mem.find(u8, t.testResp(), "-32700") != null);
}
