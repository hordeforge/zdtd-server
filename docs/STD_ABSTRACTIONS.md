# Zig stdlib abstraction audit (zdtd)

Living map of where we use high-level Zig 0.16 APIs vs thin posix.
Policy: **AGENTS rule 24** (stdlib / `std.Io` over raw `std.os.linux`).

## Target stack

```text
app (server/ecs/world/assets)
  → util/io_fs, util/clock, util/tcp_listen, litenet/udp_socket
  → std.Io / std.Io.net / std.posix (thin)
  → OS
```

**No application `std.os.linux` imports** (only forbid-comments remain).

## Status by subsystem

| Area | Preferred API | State |
|---|---|---|
| **Ordinary FS** | `util/io_fs` → `std.Io.Dir`/`File` | **Done** |
| **Paths** | `std.fs.path`, `std.fs.max_path_bytes` | **OK** |
| **UDP LiteNet** | `litenet/udp_socket` → `std.Io.net` | **Done** |
| **Monotonic time** | `util/clock` → `posix.system.clock_gettime` (vDSO; no Threaded) | **Done** |
| **Sleep** | `posix.system.nanosleep` | **Done** |
| **Thread pool** | `util/parallel` → `std.Io` | **Done** |
| **TCP listen** | `util/tcp_listen` → `IpAddress.listen` + poll/`accept4` | **Done** |
| **Admin TCP** | `tcp_listen` | **Done** |
| **GSI info TCP** | `tcp_listen` | **Done** |
| **WebUI TCP** | `tcp_listen` | **Done** |
| **HTTP framing** | `std.http.Server` | **Done** (`webui.serveHttp`: fixed Reader over recv_buf + Writer → writeAll) |

## WebUI HTTP path

1. Non-blocking TCP accept/read until full request in `recv_buf`
2. `http.Server.init(Io.Reader.fixed(buf), Io.Writer.fixed(out))`
3. `receiveHead` + route on `method`/`target`; body = remainder of fixed reader
4. `request.respond` + flush Writer buffer via `tcp.writeAll`

## Why clock stays on `posix.system`

`monoNs` is on the per-packet hot path. Constructing `Io.Threaded` per call is
too heavy. `posix.system.clock_gettime(CLOCK.MONOTONIC)` hits the vDSO and is the
idiomatic portable thin layer (not `std.os.linux`).

## Why accept uses poll + accept4

`Io.net.Server.accept` treats EAGAIN as a programmer bug when the listen socket
is non-blocking. Listen stays blocking; `poll(0)` gates `accept4(..., NONBLOCK|CLOEXEC)`.

## Residual thin posix (acceptable)

| Call | Where |
|---|---|
| `posix.setsockopt` REUSEADDR | UDP bind (BindOptions has no reuse) |
| `posix.poll` + `system.accept4` | tcp_listen accept |
| `posix.read` / `system.write` / `system.close` | tcp_listen client I/O |
| `system.clock_gettime` / `nanosleep` | clock hot path |

## Checklist for new code

- [ ] No `std.os.linux` imports
- [ ] FS via `io_fs` / `std.Io.Dir`
- [ ] Time via `util/clock`
- [ ] UDP via `litenet/udp_socket`
- [ ] TCP via `util/tcp_listen`
- [ ] Prefer `std.http.Server` for new HTTP surfaces

## Verification

```bash
rg -n 'std\.os\.linux' src --type zig   # comments only
zig build && zig build test
```
