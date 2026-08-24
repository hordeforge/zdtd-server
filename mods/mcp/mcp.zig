// mcp — MCP server addon (ADR 0031, PRD 0002, RFC 0002).
//
// A WebAssembly plugin that implements the Model Context Protocol server side:
// JSON-RPC 2.0 framing, session lifecycle, capabilities, and a tool registry.
// The host owns the transport and the JSON parsing: client frames arrive
// through the `on_mcp_frame` hook, and JSON is parsed by the host with Zig's
// std.json through the `json_parse` / `json_str` / `json_raw` / `json_obj`
// imports (ADR 0031 D1/D3). This module owns only protocol logic; reads come
// from `zdtd.sense`/`zdtd.query` and actions go through `zdtd.queue`, exactly
// like every other plugin (ADR 0020). No hand-rolled JSON parsing.
//
// Freestanding wasm32: no libc, no WASI, no heap. All memory is static; all
// emitting is bounded (overflow tracked, truncated responses dropped). Fail
// closed: malformed input becomes a spec JSON-RPC error, never a truncated
// frame, and unavailable data becomes an `isError` tool result instead of
// invented values (ADR 0014).
//
// Host imports (module "zdtd", bare field names — PLUGIN_DEV.md):
//   log(level, ptr, len)        write a log line
//   tick() -> i64               current server tick
//   queue(ptr, len) -> i32      queue a text SimCommand
//   sense(ptr, len, token)      fill a read-only world snapshot (BOTS_SPEC §3)
//   query(req_ptr, req_len, out_ptr, out_cap) -> i32   point query
//   json_parse(ptr, len) -> i32        std.json parse of the frame; 0 ok, <0 err
//   json_str(path_ptr, path_len, out_ptr, out_cap) -> i32  decoded string at a
//                                      dot path; full length, 0 missing, <0 err
//   json_raw(path_ptr, path_len, out_ptr, out_cap) -> i32  raw JSON at a path
//   json_obj(path_ptr, path_len) -> i32  1 object, 0 missing/other, <0 err
//
// Exports: on_enable, on_shutdown, on_mcp_frame, _zdtd_requires.
//
// Build (zig): see mods/BUILDING.md. Committed as mcp.wasm.

const std = @import("std");
const common = @import("plugin_common");

const mcp_spec_version = "2025-06-18";
const mcp_server_name = "zdtd-mcp";
const mcp_server_version = "0.1.0";

const json_rpc_parse_error = -32700;
const json_rpc_invalid_request = -32600;
const json_rpc_method_not_found = -32601;
const json_rpc_invalid_params = -32602;
const json_rpc_internal_error = -32603;
const mcp_server_not_initialized = -32002;

const sense_scratch_len = 2048; // host_sense_max (src/plugin/wasm.zig)
const query_req_len = 128;
const query_resp_len = 64; // query_resp_max (src/plugin/wasm.zig)
const sense_header_len = 24;
const sense_record_len = 32;
const sbuf_len = 96; // decoded strings: jsonrpc, method, tool name
const vbuf_len = 128; // decoded admin_command verb
const rbuf_len = 96; // raw JSON-RPC id echo

// Session states (RFC 0002 §5): awaiting_initialize accepts only
// initialize and ping; initialize sends the capability response and moves to
// init_sent; the notifications/initialized notification moves to ready.
const session_closed = 0;
const session_await_init = 1;
const session_init_sent = 2;
const session_ready = 3;

// Tool ids in the registry (order matches tools/list output).
const tool_server_status = 0;
const tool_player_list = 1;
const tool_admin_command = 2;
const tool_count = 3;

var out_buf: [common.out_cap]u8 = undefined; // log lines via common.Buf shape

var session_state: i32 = session_await_init;

// ---------------------------------------------------------------------------
// Bounded response writer. On overflow every append still counts (so the
// caller sees it) but bytes stop being written; a final response with
// overflow is dropped by returning 0 (fail closed, ADR 0014).

const Wbuf = struct {
    p: []u8,
    n: usize = 0,
    overflow: bool = false,

    fn putc(w: *Wbuf, c: u8) void {
        if (w.n < w.p.len) w.p[w.n] = c else w.overflow = true;
        w.n += 1;
    }

    fn puts(w: *Wbuf, s: []const u8) void {
        for (s) |c| w.putc(c);
    }

    fn int(w: *Wbuf, v: i64) void {
        var tmp: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return;
        w.puts(s);
    }

    // JSON string with escaping (our data: no control chars besides those handled).
    fn jsonStrN(w: *Wbuf, s: []const u8) void {
        w.putc('"');
        for (s) |c| {
            if (c == '"' or c == '\\') {
                w.putc('\\');
                w.putc(c);
            } else if (c == '\n') {
                w.puts("\\n");
            } else if (c == '\r') {
                w.puts("\\r");
            } else if (c == '\t') {
                w.puts("\\t");
            } else if (c < 0x20) {
                w.puts("\\uFFFD");
            } else {
                w.putc(c);
            }
        }
        w.putc('"');
    }

    // f32 rendered to one decimal place ("100.0", "-3.5"); non-finite -> "0.0".
    fn f32One(w: *Wbuf, v_in: f32) void {
        if (v_in != v_in or v_in > 1e9 or v_in < -1e9) {
            w.puts("0.0");
            return;
        }
        const neg = v_in < 0;
        const v = if (neg) -v_in else v_in;
        var whole: i64 = @intFromFloat(v);
        var frac: i64 = @intFromFloat((v - @as(f32, @floatFromInt(whole))) * 10.0 + 0.5);
        if (frac >= 10) {
            whole += 1;
            frac = 0;
        }
        if (neg) w.putc('-');
        w.int(whole);
        w.putc('.');
        w.putc(@intCast('0' + @as(u8, @intCast(frac))));
    }
};

fn eqStr(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---------------------------------------------------------------------------
// Response envelopes. The id is echoed verbatim (already capped by the caller).

// {"jsonrpc":"2.0","id":<id>,"result":<result>}  (no id for notifications)
fn emitResult(w: *Wbuf, id: []const u8, have_id: bool, result: []const u8) void {
    w.puts("{\"jsonrpc\":\"2.0\",");
    if (have_id) {
        w.puts("\"id\":");
        w.puts(id);
        w.putc(',');
    }
    w.puts("\"result\":");
    w.puts(result);
    w.putc('}');
}

fn emitError(w: *Wbuf, id: []const u8, have_id: bool, code: i32, message: []const u8) void {
    w.puts("{\"jsonrpc\":\"2.0\",");
    if (have_id) {
        w.puts("\"id\":");
        w.puts(id);
        w.putc(',');
    }
    w.puts("\"error\":{\"code\":");
    w.int(code);
    w.puts(",\"message\":");
    w.jsonStrN(message);
    w.puts("}}");
}

// ---------------------------------------------------------------------------
// Tool registry

fn toolName(tool: usize) []const u8 {
    return switch (tool) {
        tool_server_status => "server_status",
        tool_player_list => "player_list",
        tool_admin_command => "admin_command",
        else => "unknown",
    };
}

// tools/list result body (static; small and fixed).
const tools_list_json: []const u8 = "{" ++
    "\"tools\":[" ++
    "{\"name\":\"server_status\",\"description\":\"Server status: tick, world entity counts\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}," ++
    "{\"name\":\"player_list\",\"description\":\"Connected players seen in the current snapshot (id, position, hp)\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}," ++
    "{\"name\":\"admin_command\",\"description\":\"Queue an allowlisted SimCommand verb\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"verb\":{\"type\":\"string\"}},\"required\":[\"verb\"]}}" ++
    "]}";

fn jsonPath(path: [:0]const u8) struct { ptr: i32, len: i32 } {
    return .{ .ptr = @intCast(@intFromPtr(path.ptr)), .len = @intCast(path.len) };
}

fn hostJsonStr(path: [:0]const u8, out: []u8) i32 {
    const p = jsonPath(path);
    return common.json_str(p.ptr, p.len, @intCast(@intFromPtr(out.ptr)), @intCast(out.len));
}

fn hostJsonRaw(path: [:0]const u8, out: []u8) i32 {
    const p = jsonPath(path);
    return common.json_raw(p.ptr, p.len, @intCast(@intFromPtr(out.ptr)), @intCast(out.len));
}

fn hostJsonObj(path: [:0]const u8) i32 {
    const p = jsonPath(path);
    return common.json_obj(p.ptr, p.len);
}

// ---------------------------------------------------------------------------
// Sense snapshot reads (BOTS_SPEC §3). LE reads; wasm32 is little-endian but
// readInt keeps it explicit.

// text result for a tool that reads the snapshot; returns false on overflow.
fn toolTextSnapshot(w: *Wbuf, snap: []const u8, snap_len: usize, tool: usize) bool {
    if (snap_len < sense_header_len or std.mem.readInt(u32, snap[0..4], .little) != 0x3353425a) return false; // 'ZBS3'
    const count = std.mem.readInt(u32, snap[4..8], .little);
    const tick = std.mem.readInt(u32, snap[8..12], .little);
    // Records follow at a fixed stride; the snapshot may also carry a 16-byte
    // event trailer (BOTS_SPEC §3), so iterate only over full records up to
    // count, never past the buffer.
    var players: usize = 0;
    var zombies: usize = 0;
    var bots: usize = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const base = sense_header_len + @as(usize, i) * sense_record_len;
        if (base + sense_record_len > snap_len) break;
        const kind = snap[base + 4];
        switch (kind) {
            0 => players += 1,
            1 => zombies += 1,
            2 => bots += 1,
            else => {},
        }
    }
    if (tool == tool_server_status) {
        w.puts("ticks=");
        w.int(tick);
        w.puts(" entities=");
        w.int(count);
        w.puts(" players=");
        w.int(players);
        w.puts(" zombies=");
        w.int(zombies);
        w.puts(" bots=");
        w.int(bots);
        return !w.overflow;
    }
    // player_list: one line per kind-0 record; a note when the snapshot has none.
    if (players == 0) {
        w.puts("no players in snapshot");
        return !w.overflow;
    }
    var first = true;
    i = 0;
    while (i < count) : (i += 1) {
        const base = sense_header_len + @as(usize, i) * sense_record_len;
        if (base + sense_record_len > snap_len) break;
        if (snap[base + 4] != 0) continue;
        if (!first) w.putc('\n');
        first = false;
        w.puts("id=");
        w.int(std.mem.readInt(i32, snap[base..][0..4], .little));
        w.puts(" x=");
        w.f32One(@bitCast(std.mem.readInt(u32, snap[base + 8 ..][0..4], .little)));
        w.puts(" y=");
        w.f32One(@bitCast(std.mem.readInt(u32, snap[base + 12 ..][0..4], .little)));
        w.puts(" z=");
        w.f32One(@bitCast(std.mem.readInt(u32, snap[base + 16 ..][0..4], .little)));
        w.puts(" hp=");
        w.f32One(@bitCast(std.mem.readInt(u32, snap[base + 20 ..][0..4], .little)));
    }
    return !w.overflow;
}

// tools/call execution. Appends the result body on success, an isError result
// on execution failure; returns false on overflow. `verb` carries the decoded
// params.arguments.verb (already validated when present).
fn runTool(tool: usize, verb: []const u8, w: *Wbuf) bool {
    if (tool == tool_admin_command) {
        // Allowlist: host policy via zdtd.query "mcp.allowlist"; one verb per line.
        // Missing query surface or absent verb -> deny (fail closed).
        var req: [query_req_len]u8 = undefined;
        var resp: [query_resp_len]u8 = undefined;
        const qkey = "mcp.allowlist";
        @memcpy(req[0..qkey.len], qkey);
        req[qkey.len] = 0;
        const got_raw = common.query(
            @intCast(@intFromPtr(&req)),
            @intCast(qkey.len),
            @intCast(@intFromPtr(&resp)),
            resp.len,
        );
        var allowed = false;
        if (got_raw > 0) {
            const got: usize = @intCast(got_raw);
            // resp is newline separated; a verb is allowed when it starts with an
            // allowlist entry (prefix match, so "bot count" allows "bot count 6").
            var line_start: usize = 0;
            var i: usize = 0;
            while (i <= got) : (i += 1) {
                if (i == got or resp[i] == '\n') {
                    const line = resp[line_start..i];
                    if (line.len > 0 and verb.len >= line.len and eqStr(verb[0..line.len], line)) {
                        allowed = true;
                        break;
                    }
                    line_start = i + 1;
                }
            }
        }
        if (!allowed) {
            w.puts("\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"verb not in allowlist\"}]");
            return !w.overflow;
        }
        // Queue the verb as a SimCommand; the ECS drains it with full authority.
        if (verb.len > query_req_len - 1) {
            w.puts("\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"verb too long\"}]");
            return !w.overflow;
        }
        var cmd: [query_req_len]u8 = undefined;
        @memcpy(cmd[0..verb.len], verb);
        cmd[verb.len] = 0;
        const queued = common.queue(@intCast(@intFromPtr(&cmd)), @intCast(verb.len));
        w.puts("\"content\":[{\"type\":\"text\",\"text\":");
        w.putc('"');
        if (queued != 0) {
            w.puts("queue rejected");
        } else {
            w.jsonStrN(cmd[0..verb.len]);
            w.puts(" queued");
        }
        w.puts("\"}]");
        return !w.overflow;
    }
    // Read tools: fill from the bounded sense snapshot; no snapshot -> isError.
    var snap: [sense_scratch_len]u8 = undefined;
    const got = common.sense(@intCast(@intFromPtr(&snap)), snap.len, 0);
    if (got <= 0) {
        w.puts("\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"no world data available\"}]");
        return !w.overflow;
    }
    w.puts("\"content\":[{\"type\":\"text\",\"text\":");
    w.putc('"');
    const ok = toolTextSnapshot(w, &snap, @intCast(got), tool);
    w.puts("\"}]");
    return ok and !w.overflow;
}

// ---------------------------------------------------------------------------
// Frame dispatch (session state machine, RFC 0002 §5). JSON is parsed by
// the host (std.json) into the current doc; field reads go through json_*.

export fn on_mcp_frame(frame_ptr: i32, frame_len: i32, out_ptr: i32, out_cap: i32) i32 {
    if (session_state == session_closed) return 0;
    const frame: [*]const u8 = @ptrFromInt(@as(usize, @intCast(frame_ptr)));
    const n: usize = @intCast(@max(0, frame_len));
    var w = Wbuf{
        .p = @as([*]u8, @ptrFromInt(@as(usize, @intCast(out_ptr))))[0..@intCast(@max(0, out_cap))],
    };

    var sbuf: [sbuf_len]u8 = undefined; // decoded strings (jsonrpc, method, tool name)
    var rbuf: [rbuf_len]u8 = undefined; // raw id echo
    var vbuf: [vbuf_len]u8 = undefined; // decoded admin_command verb

    // Parse the frame with the host's std.json capability; -32700 for invalid
    // JSON, -32600 for valid JSON that is not a JSON-RPC object.
    if (common.json_parse(frame_ptr, frame_len) != 0) {
        emitError(&w, "", false, json_rpc_parse_error, "Parse error");
        return if (w.overflow) 0 else @intCast(w.n);
    }
    const trimmed = std.mem.trim(u8, frame[0..n], " \t\n\r");
    if (trimmed.len == 0 or trimmed[0] != '{') {
        // Batches (arrays) and scalars are refused (JSON-RPC 2.0 allows it).
        emitError(&w, "", false, json_rpc_invalid_request, "Invalid Request");
        return if (w.overflow) 0 else @intCast(w.n);
    }
    const sl = hostJsonStr("jsonrpc", &sbuf);
    if (sl != 3 or !eqStr(sbuf[0..3], "2.0")) {
        emitError(&w, "", false, json_rpc_invalid_request, "Invalid Request");
        return if (w.overflow) 0 else @intCast(w.n);
    }
    const rl_raw = hostJsonRaw("id", &rbuf);
    if (rl_raw < 0 or rl_raw > rbuf_len) {
        // No parsed doc (-1) or an id too long to echo safely: refuse.
        emitError(&w, "", false, json_rpc_invalid_request, "Invalid Request");
        return if (w.overflow) 0 else @intCast(w.n);
    }
    const rl: usize = @intCast(rl_raw);
    const have_id = rl > 0;
    const ml_raw = hostJsonStr("method", &sbuf);
    if (ml_raw <= 0 or ml_raw > sbuf_len) {
        emitError(&w, rbuf[0..rl], have_id, json_rpc_invalid_request, "Invalid Request");
        return if (w.overflow) 0 else @intCast(w.n);
    }
    const ml: usize = @intCast(ml_raw);

    // Notifications carry no id and get no response at all (JSON-RPC 2.0).
    const notif = !have_id;

    if (eqStr(sbuf[0..ml], "initialize")) {
        if (session_state != session_await_init) {
            if (!notif) emitError(&w, rbuf[0..rl], true, json_rpc_invalid_request, "Session already initialized");
            return if (w.overflow) 0 else @intCast(w.n);
        }
        if (notif) return 0; // an initialize notification is meaningless; ignore
        emitResult(&w, rbuf[0..rl], true, "{\"protocolVersion\":\"" ++ mcp_spec_version ++
            "\",\"capabilities\":{\"tools\":{\"listChanged\":false}}," ++ "\"serverInfo\":{\"name\":\"" ++ mcp_server_name ++ "\",\"version\":\"" ++ mcp_server_version ++ "\"}}");
        session_state = session_init_sent;
        return if (w.overflow) 0 else @intCast(w.n);
    }
    if (eqStr(sbuf[0..ml], "notifications/initialized")) {
        // notification; only meaningful after initialize
        if (session_state == session_init_sent or session_state == session_ready)
            session_state = session_ready;
        return 0;
    }
    if (eqStr(sbuf[0..ml], "ping")) {
        if (notif) return 0;
        emitResult(&w, rbuf[0..rl], true, "{}");
        return if (w.overflow) 0 else @intCast(w.n);
    }
    if (session_state != session_ready) {
        if (!notif) emitError(&w, rbuf[0..rl], true, mcp_server_not_initialized, "Server not initialized");
        return if (w.overflow) 0 else @intCast(w.n);
    }
    if (eqStr(sbuf[0..ml], "tools/list")) {
        if (notif) return 0;
        emitResult(&w, rbuf[0..rl], true, tools_list_json);
        return if (w.overflow) 0 else @intCast(w.n);
    }
    if (eqStr(sbuf[0..ml], "tools/call")) {
        if (notif) return 0;
        // params must be an object carrying a tool name.
        if (hostJsonObj("params") != 1) {
            emitError(&w, rbuf[0..rl], true, json_rpc_invalid_params, "Invalid params");
            return if (w.overflow) 0 else @intCast(w.n);
        }
        const nl_raw = hostJsonStr("params.name", &sbuf);
        if (nl_raw <= 0 or nl_raw > sbuf_len) {
            emitError(&w, rbuf[0..rl], true, json_rpc_invalid_params, "Invalid params");
            return if (w.overflow) 0 else @intCast(w.n);
        }
        const nl: usize = @intCast(nl_raw);
        var tool: usize = tool_count;
        var t: usize = 0;
        while (t < tool_count) : (t += 1) {
            if (eqStr(sbuf[0..nl], toolName(t))) {
                tool = t;
                break;
            }
        }
        if (tool == tool_count) {
            emitError(&w, rbuf[0..rl], true, json_rpc_invalid_params, "Unknown tool");
            return if (w.overflow) 0 else @intCast(w.n);
        }
        // arguments must be an object when present.
        const ao = hostJsonObj("params.arguments");
        if (ao < 0) {
            emitError(&w, rbuf[0..rl], true, json_rpc_invalid_params, "Invalid params");
            return if (w.overflow) 0 else @intCast(w.n);
        }
        // admin_command needs a non-empty string verb.
        var vl: i32 = 0;
        if (ao == 1) {
            vl = hostJsonStr("params.arguments.verb", &vbuf);
            if (vl > vbuf_len) {
                emitError(&w, rbuf[0..rl], true, json_rpc_invalid_params, "Invalid params");
                return if (w.overflow) 0 else @intCast(w.n);
            }
            if (vl < 0) vl = 0;
        }
        if (tool == tool_admin_command and vl <= 0) {
            emitError(&w, rbuf[0..rl], true, json_rpc_invalid_params, "Invalid params");
            return if (w.overflow) 0 else @intCast(w.n);
        }
        w.puts("{\"jsonrpc\":\"2.0\",\"id\":");
        w.puts(rbuf[0..rl]);
        w.puts(",\"result\":{");
        const ran = runTool(tool, if (vl > 0) vbuf[0..@intCast(vl)] else "", &w);
        w.putc('}');
        w.putc('}');
        return if (ran and !w.overflow) @intCast(w.n) else 0;
    }
    if (!notif) emitError(&w, rbuf[0..rl], true, json_rpc_method_not_found, "Method not found");
    return if (w.overflow) 0 else @intCast(w.n);
}

// ---------------------------------------------------------------------------
// Lifecycle

export fn on_enable() void {
    session_state = session_await_init;
}

export fn on_shutdown() void {
    session_state = session_closed;
}

comptime {
    // Declarative dependencies (ADR 0030): hooks + host verbs this module needs.
    common.exportRequires("log,tick,sense,query,queue,json_parse,json_str,json_raw,json_obj,on_mcp_frame");
}
