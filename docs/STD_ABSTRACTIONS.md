# Zig stdlib abstraction audit (zdtd)

Living map of where we use high-level Zig 0.16 APIs vs residual low-level
paths. Policy: **AGENTS rule 24** (stdlib / `std.Io` over raw `std.os.linux`).

## Target stack

```text
app (server/ecs/world/assets)
  → util/io_fs, util/clock, litenet/udp_socket, (future tcp_listen)
  → std.Io / std.Io.net / std.http / std.posix (thin)
  → OS
```

Do **not** open-code `std.os.linux.*` for ordinary FS, time, or new net code.

## Status by subsystem

| Area | Preferred API | Current state | Notes |
|---|---|---|---|
| **Ordinary FS** | `util/io_fs` → `std.Io.Dir`/`File` | **Done** | No raw open/getdents in app code |
| **Paths** | `std.fs.path`, `std.fs.max_path_bytes` | **OK** | Constants only |
| **UDP LiteNet** | `std.Io.net` bind/send/receiveTimeout | **Done** (`litenet/udp_socket.zig`) | Peers store `IpAddress`; `posix.setsockopt` only for REUSEADDR |
| **Monotonic time / sleep** | `std.Io.Clock.awake` + `Duration.sleep` | **Done** (`util/clock.zig`) | Virtual clock for tests unchanged |
| **Thread pool** | `std.Io` mutex/cond via `util/parallel` | **Done** | No spawn-per-tick |
| **WebUI HTTP** | `std.Io.net` listen + **`std.http.Server`** | **Open** (`webui.zig` still `std.os.linux` TCP + hand parsers) | Best next migration: listen/accept via `IpAddress.listen`, parse/respond via `http.Server.init` + `receiveHead` + `respond` |
| **Admin TCP** | `std.Io.net` listen/accept + Stream reader | **Open** (`admin.zig` linux sockets) | Line protocol, not HTTP; share a small `util/tcp_listen.zig` with GSI |
| **GSI info TCP** | same as admin | **Open** (`serverinfo_tcp.zig`) | Accept + one-shot write |
| **HTTP Client** | `std.http.Client` | N/A | Not used (no outbound HTTP) |

## Residual `std.os.linux` (as of this doc)

| File | Why still there | Migration |
|---|---|---|
| `src/server/webui.zig` | Non-blocking TCP + manual HTTP | `IpAddress.listen` + `Server.accept` with zero/timeout accept; request path → `std.http.Server` |
| `src/server/admin.zig` | Non-blocking multi-session TCP | `std.Io.net` Server + Stream.Reader; poll with WouldBlock accept |
| `src/server/serverinfo_tcp.zig` | Accept + write GSI blob | Same TCP helper as admin |
| `src/litenet/udp_socket.zig` | Comment only; `posix.setsockopt` | Acceptable thin posix (no `std.os.linux`) |
| `src/util/io_fs.zig` | Comment forbidding linux | OK |

## `std.http` fit for webui

Zig 0.16 `std.http.Server` is a **per-connection** protocol state machine:

- `http.Server.init(*Io.Reader, *Io.Writer)`
- `receiveHead()` → `Request` with `method`, `target`, headers
- `request.respond(body, .{ .status, .extra_headers, .keep_alive })`

It does **not** open the listen socket. Pair with:

```zig
const addr: Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } };
var tcp = try addr.listen(io, .{ .reuse_address = true, .mode = .stream, .protocol = .tcp });
// non-blocking accept: catch error.WouldBlock
const stream = try tcp.accept(io);
var r_buf: [8192]u8 = undefined;
var w_buf: [8192]u8 = undefined;
var r = stream.reader(io, &r_buf);
var w = stream.writer(io, &w_buf);
var http_srv = std.http.Server.init(&r.interface, &w.interface);
var req = try http_srv.receiveHead();
// route on req.head.method + req.head.target
try req.respond(body, .{ .status = .ok, .extra_headers = &.{
    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
}});
```

WebUI constraints to preserve:

- Polled from `Game.step` (no dedicated thread): accept must be non-blocking
- Shared secret auth (Bearer / cookie / CSRF)
- Single in-flight client is OK (current design)

## Shared TCP listen helper (recommended)

Extract once for admin + GSI + (optional) webui listen shell:

```text
src/util/tcp_listen.zig
  TcpListener { io_impl, server: Io.net.Server }
  listen(bind_ip4, port, backlog) !void
  acceptNonblock() !?Stream   // null on WouldBlock
  deinit()
```

Keep line/HTTP framing in the callers.

## Explicit non-migrations

| Keep as-is | Reason |
|---|---|
| LiteNet packet framing | Protocol, not OS |
| `posix.setsockopt` REUSEADDR on UDP | BindOptions lacks reuse; one-liner is fine |
| `page_allocator` for `Io.Threaded` bookkeeping | Documented; not tick heap |
| Parallel pool internals | Already on `std.Io` primitives |

## Checklist for new code

- [ ] No new `std.os.linux` imports
- [ ] FS via `io_fs` / `std.Io.Dir`
- [ ] Time via `util/clock` (or inject `Io` if long-lived)
- [ ] UDP via `litenet/udp_socket`
- [ ] TCP via `std.Io.net` (or shared helper when landed)
- [ ] HTTP prefer `std.http.Server` / `Client` over hand parsers

## Verification

```bash
rg -n 'std\.os\.linux' src --type zig   # should shrink to zero app uses
zig build && zig build test
```
