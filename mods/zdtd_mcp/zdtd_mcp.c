// zdtd_mcp - MCP server addon (ADR 0031, docs/MCP_PRD.md, docs/MCP_DESIGN.md).
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
// Host imports (module "zdtd", bare field names - PLUGIN_DEV.md):
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
// Build (clang, committed as mods/zdtd_mcp/zdtd_mcp.wasm). `-fno-builtin` keeps
// clang from lowering the small loops into libc calls (strlen/memcmp) that a
// freestanding target has no definitions for:
//   clang --target=wasm32 -nostdlib -O2 -fno-builtin -Wl,--no-entry -Wl,--export-all \
//     -o mods/zdtd_mcp/zdtd_mcp.wasm mods/zdtd_mcp/zdtd_mcp.c

__attribute__((import_module("zdtd"), import_name("log")))
extern void zdtd_log(int level, int ptr, int len);
__attribute__((import_module("zdtd"), import_name("tick")))
extern long long zdtd_tick(void);
__attribute__((import_module("zdtd"), import_name("queue")))
extern int zdtd_queue(int ptr, int len);
__attribute__((import_module("zdtd"), import_name("sense")))
extern int zdtd_sense(int ptr, int len, int token);
__attribute__((import_module("zdtd"), import_name("query")))
extern int zdtd_query(int req_ptr, int req_len, int out_ptr, int out_cap);
__attribute__((import_module("zdtd"), import_name("json_parse")))
extern int zdtd_json_parse(int ptr, int len);
__attribute__((import_module("zdtd"), import_name("json_str")))
extern int zdtd_json_str(int path_ptr, int path_len, int out_ptr, int out_cap);
__attribute__((import_module("zdtd"), import_name("json_raw")))
extern int zdtd_json_raw(int path_ptr, int path_len, int out_ptr, int out_cap);
__attribute__((import_module("zdtd"), import_name("json_obj")))
extern int zdtd_json_obj(int path_ptr, int path_len);

// ---------------------------------------------------------------------------
// Constants

#define MCP_SPEC_VERSION "2025-06-18"
#define MCP_SERVER_NAME "zdtd-mcp"
#define MCP_SERVER_VERSION "0.1.0"

#define JSON_RPC_PARSE_ERROR (-32700)
#define JSON_RPC_INVALID_REQUEST (-32600)
#define JSON_RPC_METHOD_NOT_FOUND (-32601)
#define JSON_RPC_INVALID_PARAMS (-32602)
#define JSON_RPC_INTERNAL_ERROR (-32603)
#define MCP_SERVER_NOT_INITIALIZED (-32002)

#define SENSE_SCRATCH_LEN 2048   // host_sense_max (src/plugin/wasm.zig)
#define QUERY_REQ_LEN 128
#define QUERY_RESP_LEN 64        // query_resp_max (src/plugin/wasm.zig)
#define SENSE_HEADER_LEN 16
#define SENSE_RECORD_LEN 32
#define SBUF_LEN 96              // decoded strings: jsonrpc, method, tool name
#define VBUF_LEN 128             // decoded admin_command verb
#define RBUF_LEN 96              // raw JSON-RPC id echo

// Session states (MCP_DESIGN.md §5): awaiting_initialize accepts only
// initialize and ping; initialize sends the capability response and moves to
// init_sent; the notifications/initialized notification moves to ready.
#define SESSION_CLOSED 0
#define SESSION_AWAIT_INIT 1
#define SESSION_INIT_SENT 2
#define SESSION_READY 3

// Tool ids in the registry (order matches tools/list output).
#define TOOL_SERVER_STATUS 0
#define TOOL_PLAYER_LIST 1
#define TOOL_ADMIN_COMMAND 2
#define TOOL_COUNT 3

// ---------------------------------------------------------------------------
// Tiny memory helpers (no libc)

static int mcp_len(const char *s) {
  int n = 0;
  while (s[n]) n++;
  return n;
}

static int mcp_eq(const char *a, const char *b, int n) {
  for (int i = 0; i < n; i++)
    if (a[i] != b[i]) return 0;
  return 1;
}

static int mcp_eq_str(const char *a, int n, const char *b) {
  int bl = mcp_len(b);
  if (n != bl) return 0;
  return mcp_eq(a, b, n);
}

static const char *skip_ws(const char *p, const char *end) {
  while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
  return p;
}

// ---------------------------------------------------------------------------
// Bounded response writer. On overflow every append still counts (so the
// caller sees it) but bytes stop being written; a final response with
// overflow is dropped by returning 0 (fail closed, ADR 0014).

typedef struct { char *p; int cap; int n; int overflow; } wbuf_t;

static void wb_putc(wbuf_t *w, char c) {
  if (w->n < w->cap) w->p[w->n] = c;
  else w->overflow = 1;
  w->n++;
}

static void wb_puts(wbuf_t *w, const char *s) {
  while (*s) wb_putc(w, *s++);
}

static void wb_puts_n(wbuf_t *w, const char *s, int n) {
  for (int i = 0; i < n; i++) wb_putc(w, s[i]);
}

static void wb_int(wbuf_t *w, long long v) {
  if (v == 0) { wb_putc(w, '0'); return; }
  char tmp[24];
  int i = 24;
  unsigned long long u = v < 0 ? (unsigned long long)(-(v + 1)) + 1 : (unsigned long long)v;
  while (u) { tmp[--i] = (char)('0' + u % 10); u /= 10; }
  if (v < 0) wb_putc(w, '-');
  while (i < 24) wb_putc(w, tmp[i++]);
}

// JSON string with escaping (our data: no control chars besides those handled).
static void wb_json_str_n(wbuf_t *w, const char *s, int n) {
  wb_putc(w, '"');
  for (int i = 0; i < n; i++) {
    char c = s[i];
    if (c == '"' || c == '\\') { wb_putc(w, '\\'); wb_putc(w, c); }
    else if (c == '\n') wb_puts(w, "\\n");
    else if (c == '\r') wb_puts(w, "\\r");
    else if (c == '\t') wb_puts(w, "\\t");
    else if ((unsigned char)c < 0x20) wb_puts(w, "\\uFFFD");
    else wb_putc(w, c);
  }
  wb_putc(w, '"');
}

static void wb_json_str(wbuf_t *w, const char *s) {
  wb_json_str_n(w, s, mcp_len(s));
}

// f32 rendered to one decimal place ("100.0", "-3.5"); non-finite -> "0.0".
static void wb_f32_1(wbuf_t *w, float v) {
  if (v != v || v > 1e9f || v < -1e9f) { wb_puts(w, "0.0"); return; }
  int neg = v < 0;
  if (neg) v = -v;
  long long whole = (long long)v;
  long long frac = (long long)((v - (float)whole) * 10.0f + 0.5f);
  if (frac >= 10) { whole++; frac = 0; }
  if (neg) wb_putc(w, '-');
  wb_int(w, whole);
  wb_putc(w, '.');
  wb_putc(w, (char)('0' + frac));
}

// ---------------------------------------------------------------------------
// Response envelopes. The id is echoed verbatim (already capped by the caller).

// {"jsonrpc":"2.0","id":<id>,"result":<result>}  (no id for notifications)
static void emit_result(wbuf_t *w, const char *id, int id_len, int have_id, const char *result) {
  wb_puts(w, "{\"jsonrpc\":\"2.0\",");
  if (have_id) {
    wb_puts(w, "\"id\":");
    wb_puts_n(w, id, id_len);
    wb_putc(w, ',');
  }
  wb_puts(w, "\"result\":");
  wb_puts(w, result);
  wb_putc(w, '}');
}

static void emit_error(wbuf_t *w, const char *id, int id_len, int have_id, int code, const char *message) {
  wb_puts(w, "{\"jsonrpc\":\"2.0\",");
  if (have_id) {
    wb_puts(w, "\"id\":");
    wb_puts_n(w, id, id_len);
    wb_putc(w, ',');
  }
  wb_puts(w, "\"error\":{\"code\":");
  wb_int(w, code);
  wb_puts(w, ",\"message\":");
  wb_json_str(w, message);
  wb_puts(w, "}}");
}

// ---------------------------------------------------------------------------
// Tool registry

static const char *tool_name(int tool) {
  switch (tool) {
    case TOOL_SERVER_STATUS: return "server_status";
    case TOOL_PLAYER_LIST: return "player_list";
    case TOOL_ADMIN_COMMAND: return "admin_command";
  }
  return "unknown";
}

// tools/list result body (static; small and fixed).
static const char *tools_list_json(void) {
  return "{"
    "\"tools\":["
    "{\"name\":\"server_status\",\"description\":\"Server status: tick, world entity counts\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},"
    "{\"name\":\"player_list\",\"description\":\"Connected players seen in the current snapshot (id, position, hp)\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},"
    "{\"name\":\"admin_command\",\"description\":\"Queue an allowlisted SimCommand verb\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"verb\":{\"type\":\"string\"}},\"required\":[\"verb\"]}}"
    "]}";
}

static int tool_by_name(const char *name, int len) {
  for (int t = 0; t < TOOL_COUNT; t++)
    if (mcp_eq_str(name, len, tool_name(t))) return t;
  return -1;
}

// ---------------------------------------------------------------------------
// Sense snapshot reads (BOTS_SPEC §3). LE reads; wasm32 is little-endian but
// byte-assemble anyway so the code is obviously endian-correct.

typedef union { unsigned int u; float f; } u32f32_t;

static unsigned int rd_u32(const unsigned char *p) {
  return (unsigned int)p[0] | ((unsigned int)p[1] << 8) | ((unsigned int)p[2] << 16) | ((unsigned int)p[3] << 24);
}

static int rd_i32(const unsigned char *p) { return (int)rd_u32(p); }

static float rd_f32(const unsigned char *p) {
  u32f32_t x;
  x.u = rd_u32(p);
  return x.f;
}

// text result for a tool that reads the snapshot; returns 0 on overflow.
static int tool_text_snapshot(wbuf_t *w, const unsigned char *snap, int snap_len, int tool) {
  if (snap_len < SENSE_HEADER_LEN || rd_u32(snap) != 0x3253425a) return 0; // 'ZBS2'
  unsigned int count = rd_u32(snap + 4);
  unsigned int tick = rd_u32(snap + 8);
  // Records follow at a fixed stride; the snapshot may also carry a 16-byte
  // event trailer (BOTS_SPEC §3), so iterate only over full records up to
  // count, never past the buffer.
  int players = 0, zombies = 0, bots = 0;
  for (unsigned int i = 0; i < count; i++) {
    const unsigned char *r = snap + SENSE_HEADER_LEN + i * SENSE_RECORD_LEN;
    if ((unsigned long)(r + SENSE_RECORD_LEN) > (unsigned long)(snap + snap_len)) break;
    int kind = (int)r[4];
    if (kind == 0) players++;
    else if (kind == 1) zombies++;
    else if (kind == 2) bots++;
  }
  if (tool == TOOL_SERVER_STATUS) {
    wb_puts(w, "ticks=");
    wb_int(w, (long long)tick);
    wb_puts(w, " entities=");
    wb_int(w, (long long)count);
    wb_puts(w, " players=");
    wb_int(w, (long long)players);
    wb_puts(w, " zombies=");
    wb_int(w, (long long)zombies);
    wb_puts(w, " bots=");
    wb_int(w, (long long)bots);
    return !w->overflow;
  }
  // player_list: one line per kind-0 record; -1 when the snapshot has none.
  if (players == 0) {
    wb_puts(w, "no players in snapshot");
    return !w->overflow;
  }
  int first = 1;
  for (unsigned int i = 0; i < count; i++) {
    const unsigned char *r = snap + SENSE_HEADER_LEN + i * SENSE_RECORD_LEN;
    if ((unsigned long)(r + SENSE_RECORD_LEN) > (unsigned long)(snap + snap_len)) break;
    if (r[4] != 0) continue;
    if (!first) wb_putc(w, '\n');
    first = 0;
    wb_puts(w, "id=");
    wb_int(w, rd_i32(r));
    wb_puts(w, " x=");
    wb_f32_1(w, rd_f32(r + 8));
    wb_puts(w, " y=");
    wb_f32_1(w, rd_f32(r + 12));
    wb_puts(w, " z=");
    wb_f32_1(w, rd_f32(r + 16));
    wb_puts(w, " hp=");
    wb_f32_1(w, rd_f32(r + 20));
  }
  return !w->overflow;
}

// tools/call execution. Appends the result body on success, an isError result
// on execution failure; returns 0 on overflow. `verb`/`verb_len` carry the
// decoded params.arguments.verb (already validated when present).
static int run_tool(int tool, const char *verb, int verb_len, wbuf_t *w) {
  if (tool == TOOL_ADMIN_COMMAND) {
    // Allowlist: host policy via zdtd.query "mcp.allowlist"; one verb per line.
    // Missing query surface or absent verb -> deny (fail closed).
    static char req[QUERY_REQ_LEN];
    static char resp[QUERY_RESP_LEN];
    int req_len = 0;
    const char *qkey = "mcp.allowlist";
    while (req_len < QUERY_REQ_LEN - 1 && qkey[req_len]) { req[req_len] = qkey[req_len]; req_len++; }
    req[req_len] = 0;
    int got = zdtd_query((int)(unsigned long)req, req_len, (int)(unsigned long)resp, QUERY_RESP_LEN);
    int allowed = 0;
    if (got > 0) {
      // resp is newline separated; a verb is allowed when it starts with an
      // allowlist entry (prefix match, so "bot count" allows "bot count 6").
      int line_start = 0;
      for (int i = 0; i <= got; i++) {
        if (i == got || resp[i] == '\n') {
          int line_len = i - line_start;
          if (line_len > 0 && verb_len >= line_len &&
              mcp_eq(resp + line_start, verb, line_len)) { allowed = 1; break; }
          line_start = i + 1;
        }
      }
    }
    if (!allowed) {
      wb_puts(w, "\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"verb not in allowlist\"}]");
      return !w->overflow;
    }
    // Queue the verb as a SimCommand; the ECS drains it with full authority.
    static char cmd[QUERY_REQ_LEN];
    if (verb_len > QUERY_REQ_LEN - 1) {
      wb_puts(w, "\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"verb too long\"}]");
      return !w->overflow;
    }
    for (int i = 0; i < verb_len; i++) cmd[i] = verb[i];
    cmd[verb_len] = 0;
    int queued = zdtd_queue((int)(unsigned long)cmd, verb_len);
    wb_puts(w, "\"content\":[{\"type\":\"text\",\"text\":\"");
    if (queued != 0) {
      wb_puts(w, "queue rejected");
    } else {
      wb_json_str_n(w, cmd, verb_len);
      wb_puts(w, " queued");
    }
    wb_puts(w, "\"}]");
    return !w->overflow;
  }
  // Read tools: fill from the bounded sense snapshot; no snapshot -> isError.
  static unsigned char snap[SENSE_SCRATCH_LEN];
  int got = zdtd_sense((int)(unsigned long)snap, SENSE_SCRATCH_LEN, 0);
  if (got <= 0) {
    wb_puts(w, "\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"no world data available\"}]");
    return !w->overflow;
  }
  wb_puts(w, "\"content\":[{\"type\":\"text\",\"text\":\"");
  if (!tool_text_snapshot(w, snap, got, tool)) return 0;
  wb_puts(w, "\"}]");
  return !w->overflow;
}

// ---------------------------------------------------------------------------
// Frame dispatch (session state machine, MCP_DESIGN.md §5). JSON is parsed by
// the host (std.json) into the current doc; field reads go through json_*.

static int session_state = SESSION_AWAIT_INIT;

// Returns bytes written to out (0 = no response: notification, closed, or
// overflowed). A trap here disables only this module (host side).
int on_mcp_frame(int frame_ptr, int frame_len, int out_ptr, int out_cap) {
  if (session_state == SESSION_CLOSED) return 0;
  const char *frame = (const char *)(unsigned long)frame_ptr;
  wbuf_t w;
  w.p = (char *)(unsigned long)out_ptr;
  w.cap = out_cap;
  w.n = 0;
  w.overflow = 0;

  static char sbuf[SBUF_LEN];   // decoded strings (jsonrpc, method, tool name)
  static char rbuf[RBUF_LEN];   // raw id echo
  static char vbuf[VBUF_LEN];   // decoded admin_command verb

  // Parse the frame with the host's std.json capability; -32700 for invalid
  // JSON, -32600 for valid JSON that is not a JSON-RPC object.
  if (zdtd_json_parse(frame_ptr, frame_len) != 0) {
    emit_error(&w, 0, 0, 0, JSON_RPC_PARSE_ERROR, "Parse error");
    return w.overflow ? 0 : w.n;
  }
  const char *fp = skip_ws(frame, frame + frame_len);
  if (fp >= frame + frame_len || *fp != '{') {
    // Batches (arrays) and scalars are refused (JSON-RPC 2.0 allows it).
    emit_error(&w, 0, 0, 0, JSON_RPC_INVALID_REQUEST, "Invalid Request");
    return w.overflow ? 0 : w.n;
  }
  int sl = zdtd_json_str((int)(unsigned long)"jsonrpc", 7, (int)(unsigned long)sbuf, SBUF_LEN);
  if (sl != 3 || !mcp_eq(sbuf, "2.0", 3)) {
    emit_error(&w, 0, 0, 0, JSON_RPC_INVALID_REQUEST, "Invalid Request");
    return w.overflow ? 0 : w.n;
  }
  int rl = zdtd_json_raw((int)(unsigned long)"id", 2, (int)(unsigned long)rbuf, RBUF_LEN);
  if (rl < 0 || rl > RBUF_LEN) {
    // No parsed doc (-1) or an id too long to echo safely: refuse.
    emit_error(&w, 0, 0, 0, JSON_RPC_INVALID_REQUEST, "Invalid Request");
    return w.overflow ? 0 : w.n;
  }
  int have_id = rl > 0;
  int ml = zdtd_json_str((int)(unsigned long)"method", 6, (int)(unsigned long)sbuf, SBUF_LEN);
  if (ml <= 0 || ml > SBUF_LEN) {
    emit_error(&w, rbuf, rl, have_id, JSON_RPC_INVALID_REQUEST, "Invalid Request");
    return w.overflow ? 0 : w.n;
  }

  // Notifications carry no id and get no response at all (JSON-RPC 2.0).
  int notif = !have_id;

  if (mcp_eq_str(sbuf, ml, "initialize")) {
    if (session_state != SESSION_AWAIT_INIT) {
      if (!notif) emit_error(&w, rbuf, rl, 1, JSON_RPC_INVALID_REQUEST, "Session already initialized");
      return w.overflow ? 0 : w.n;
    }
    if (notif) return 0; // an initialize notification is meaningless; ignore
    emit_result(&w, rbuf, rl, 1,
      "{\"protocolVersion\":\"" MCP_SPEC_VERSION "\","
      "\"capabilities\":{\"tools\":{\"listChanged\":false}},"
      "\"serverInfo\":{\"name\":\"" MCP_SERVER_NAME "\",\"version\":\"" MCP_SERVER_VERSION "\"}}");
    session_state = SESSION_INIT_SENT;
    return w.overflow ? 0 : w.n;
  }
  if (mcp_eq_str(sbuf, ml, "notifications/initialized")) {
    // notification; only meaningful after initialize
    if (session_state == SESSION_INIT_SENT || session_state == SESSION_READY)
      session_state = SESSION_READY;
    return 0;
  }
  if (mcp_eq_str(sbuf, ml, "ping")) {
    if (notif) return 0;
    emit_result(&w, rbuf, rl, 1, "{}");
    return w.overflow ? 0 : w.n;
  }
  if (session_state != SESSION_READY) {
    if (!notif) emit_error(&w, rbuf, rl, 1, MCP_SERVER_NOT_INITIALIZED, "Server not initialized");
    return w.overflow ? 0 : w.n;
  }
  if (mcp_eq_str(sbuf, ml, "tools/list")) {
    if (notif) return 0;
    emit_result(&w, rbuf, rl, 1, tools_list_json());
    return w.overflow ? 0 : w.n;
  }
  if (mcp_eq_str(sbuf, ml, "tools/call")) {
    if (notif) return 0;
    // params must be an object carrying a tool name.
    if (zdtd_json_obj((int)(unsigned long)"params", 6) != 1) {
      emit_error(&w, rbuf, rl, 1, JSON_RPC_INVALID_PARAMS, "Invalid params");
      return w.overflow ? 0 : w.n;
    }
    int nl = zdtd_json_str((int)(unsigned long)"params.name", 11, (int)(unsigned long)sbuf, SBUF_LEN);
    if (nl <= 0 || nl > SBUF_LEN) {
      emit_error(&w, rbuf, rl, 1, JSON_RPC_INVALID_PARAMS, "Invalid params");
      return w.overflow ? 0 : w.n;
    }
    int tool = tool_by_name(sbuf, nl);
    if (tool < 0) {
      emit_error(&w, rbuf, rl, 1, JSON_RPC_INVALID_PARAMS, "Unknown tool");
      return w.overflow ? 0 : w.n;
    }
    // arguments must be an object when present.
    int ao = zdtd_json_obj((int)(unsigned long)"params.arguments", 16);
    if (ao < 0) {
      emit_error(&w, rbuf, rl, 1, JSON_RPC_INVALID_PARAMS, "Invalid params");
      return w.overflow ? 0 : w.n;
    }
    // admin_command needs a non-empty string verb.
    int vl = 0;
    if (ao == 1) {
      vl = zdtd_json_str((int)(unsigned long)"params.arguments.verb", 21, (int)(unsigned long)vbuf, VBUF_LEN);
      if (vl > VBUF_LEN) {
        emit_error(&w, rbuf, rl, 1, JSON_RPC_INVALID_PARAMS, "Invalid params");
        return w.overflow ? 0 : w.n;
      }
      if (vl < 0) vl = 0;
    }
    if (tool == TOOL_ADMIN_COMMAND && vl <= 0) {
      emit_error(&w, rbuf, rl, 1, JSON_RPC_INVALID_PARAMS, "Invalid params");
      return w.overflow ? 0 : w.n;
    }
    wb_puts(&w, "{\"jsonrpc\":\"2.0\",\"id\":");
    wb_puts_n(&w, rbuf, rl);
    wb_puts(&w, ",\"result\":{");
    int ran = run_tool(tool, vl > 0 ? vbuf : 0, vl, &w);
    wb_putc(&w, '}');
    wb_putc(&w, '}');
    return (ran && !w.overflow) ? w.n : 0;
  }
  if (!notif) emit_error(&w, rbuf, rl, 1, JSON_RPC_METHOD_NOT_FOUND, "Method not found");
  return w.overflow ? 0 : w.n;
}

// ---------------------------------------------------------------------------
// Lifecycle

void on_enable(void) {
  session_state = SESSION_AWAIT_INIT;
}

void on_shutdown(void) {
  session_state = SESSION_CLOSED;
}

// Declarative dependencies (ADR 0030): hooks + host verbs this module needs.
// ptr in low 32 bits, len in high 32 (host: probeRequires).
long long _zdtd_requires(void) {
  static const char spec[] =
    "log,tick,sense,query,queue,json_parse,json_str,json_raw,json_obj,on_mcp_frame";
  return (long long)(unsigned long)spec |
         ((long long)(unsigned long)(sizeof(spec) - 1) << 32);
}
