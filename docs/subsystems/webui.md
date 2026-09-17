# Operator web UI

The web UI owns the embedded operator pages and the HTTP surface that serves them: the loopback listener, the route table, the shared-secret login, the session cookie and lockout throttle, the read-only `Snapshot` the pages are rendered from, and the TypeScript sources, compiled pages and lint gates that keep the markup honest. Its boundary is HTTP in, HTML and one JSON document out. It encodes no package, reads no sim state directly, and reaches the game only through two narrow paths: the `AdminFn` thunk that `Game` installs so a console line runs through the same parser as admin TCP (`src/server/webui.zig:760-765`), and the modlet enable/disable text file that `POST /api/modlet` rewrites through `assets/modlets.zig` (`src/server/webui.zig:1809`). The package sits in `server`, whose facade comment states the dependency direction: "top of the stack. May import all other src packages" (`src/server/root.zig:3`). Nothing outside `server` imports it except `src/main.zig:16`, which reads only `min_secret` for an early usage error, and `src/fuzz.zig:714`. The page is out of band for the stock client wire: nothing here proves or affects stock compatibility.

Sources: [`src/server/webui.zig`](../../src/server/webui.zig), [`src/server/webui/shell.html`](../../src/server/webui/shell.html), [`src/server/webui/login.html`](../../src/server/webui/login.html), [`src/server/webui/ts/shell.ts`](../../src/server/webui/ts/shell.ts), [`src/server/webui/ts/login.ts`](../../src/server/webui/ts/login.ts), [`src/server/webui/ts/lockout.ts`](../../src/server/webui/ts/lockout.ts)

## Enabling and wiring

The server is off unless `--webui-port` is non-zero; the flag defaults to `0` and the bind and secret default to `127.0.0.1` and the empty string (`src/server/game/types.zig:238-241`). The secret may come from `ZDTD_WEBUI_SECRET`, which wins over the CLI only when the CLI value is empty; a CLI secret prints a warning because argv is visible in process listings (`src/main.zig:586-597`). Startup fails closed: a non-zero port without a secret is a usage error, as is a secret shorter than `min_secret` (`src/main.zig:605-613`). Initialization then listens and installs the admin thunk, returning the error on failure so a requested-but-dead UI cannot look healthy (`src/server/game/init_world.zig:203-225`). Teardown closes the listener (`src/server/game/lifecycle.zig:34`) and the same call runs if a later init step fails (`src/server/game.zig:977`).

The listener configuration record (src/server/webui.zig:48-56):

```zig
pub const Config = struct {
    port: u16 = 0,
    bind_host: []const u8 = "127.0.0.1",
    secret: []const u8 = "",
    /// Allocator for the rare mutating admin routes (modlet enable/disable
    /// rewrites one small text file). Defaults to the page allocator so unit
    /// tests need no wiring.
    allocator: std.mem.Allocator = std.heap.page_allocator,
};
```

`listen` returns silently for port 0 and otherwise rejects an empty, too-short (under 8), too-long (over 128) or header-unsafe secret, and any bind address that is not IPv4 loopback (`src/server/webui.zig:256-267`). `parseIpv4` maps `0.0.0.0` to `0`, which `isLoopbackIpv4` then refuses, so a public bind is a startup error rather than a surprise (`src/server/webui.zig:1066`, `src/server/webui.zig:1310-1312`).

## Per-tick wiring

There is no HTTP thread. `Game.step` polls the listener up to four times per tick inside the `.net_poll` scope (`src/server/game/step.zig:30`, `src/server/game/step.zig:86-87`). `Game.pollWebui` first drains up to four queued console lines through `runAdminLine(line, "webui")`, then calls the non-blocking `Server.poll` (`src/server/admin_console.zig:89-103`). Both the run loop and `--once` refresh the snapshot after `step` returns, so the snapshot copy happens with the step frame unwound (`src/server/game.zig:4146-4148`, `src/main.zig:1153-1155`). `fillWebuiSnap` returns immediately when the listener is disabled, and otherwise rebuilds only every tenth tick because browsers poll at one second or slower (`src/server/admin_console.zig:107-111`). It zeroes the snapshot in place and copies director clock, client and peer counts, entity census, APM counters, histogram percentiles, config values and host OS gauges into it; the poll thread never reads live game state (`src/server/admin_console.zig:112-196`).

## Listener and request lifecycle

`Server.poll` accepts at most one client into the single slot, increments `client_polls`, drops a request that never completes once the counter passes `max_client_polls` (800 polls, roughly 10 s at four polls per 50 ms tick), then reads and serves (`src/server/webui.zig:346-358`). Reads are non-blocking; a complete header block is required before parsing, `Content-Length` is pre-checked so a body is accumulated whole, duplicate or invalid length and any transfer encoding are client faults, and a request over `max_req` (8192 bytes) gets 413 (`src/server/webui.zig:402-456`, `src/server/webui.zig:998-1005`, `src/server/webui.zig:1085-1100`). Parsing then hands the buffered bytes to `std.http.Server` with a fixed output buffer of `max_shell_html + 4096` bytes, sized because the rendered shell is the largest body the UI produces (`src/server/webui.zig:459-467`). A malformed request line or oversized header becomes 400 or 431, not 500 (`src/server/webui.zig:468-478`).

Responses are built by `httpRespond`, which always sends `Cache-Control: no-store`, the shared hardening headers, and `Connection: close` (`src/server/webui.zig:830-864`, `src/server/webui.zig:958-969`). The content security policy is a single module constant with inline style and script allowed and `frame-ancestors 'none'` (`src/server/webui.zig:952-954`). Pre-parse failures use `rawRespond`, which writes the header block by hand (`src/server/webui.zig:922-937`); when `client_fd` is negative, as in unit tests, the response is copied into `test_resp` instead of a socket (`src/server/webui.zig:939-949`).

## Routes

`GET`/`HEAD /healthz` and `/readyz` are served before authentication (`src/server/webui.zig:483-513`). Readiness is 503 while `tick_n` is zero and 503 when the last snapshot is older than `readiness_stale_ns` (30 s), so a wedged sim loop cannot report ready (`src/server/webui.zig:1056-1062`). Every other path requires a valid credential (`src/server/webui.zig:597`). `GET /login` shows the form, redirects to `/` when the session is already valid, and shows the lockout page with 429 while locked; `POST /login` requires a form content type, then answers 400 for a missing or empty `token` field, 401 for a wrong secret, or 303 to `/` with a session cookie on success (`src/server/webui.zig:522-595`). `POST /logout` requires the form content type and a `csrf` field matching the session token or the shared secret, then clears the cookie with `Max-Age=0` (`src/server/webui.zig:627-651`, `src/server/webui.zig:891-908`). `POST /api/cmd` and `POST /api/modlet` are the two mutating routes, both POST-only (`src/server/webui.zig:657-677`).

The GET-only set is enumerated in one predicate: `/`, `/index.html`, `/partials/status`, `/partials/players`, `/partials/modules`, `/partials/apm`, `/partials/settings`, `/partials/console` and `/api/apm.json` (`src/server/webui.zig:1040-1050`). Each partial is rendered fresh from the snapshot by its `render*` function (`src/server/webui.zig:687-718`); `/api/apm.json` serializes the same snapshot as `{"type":"zdtd_webui_apm",...}` with counters, latency fields, config, world name, OS gauges and a compact player and module roster for tools (`src/server/webui.zig:2015-2168`). Unknown paths get 404, and a wrong method on a known path gets 405 with an `Allow` header (`src/server/webui.zig:679-686`, `src/server/webui.zig:721`). Unauthenticated `/api/*` answers plain 401 plus `WWW-Authenticate: Bearer realm="zdtd-webui"`, while browser routes get the HTML sign-in form (`src/server/webui.zig:613-621`). Every page references `/favicon.svg` (`src/server/webui/login.html:4`), but no route matches that path, so the icon request falls through to 404 as of this reading.

## Login, session and lockout

Three constants define the throttle and cookie lifetime (src/server/webui.zig:39-44):

```zig
/// Failed POST /login attempts before temporary lockout (brute-force throttle).
pub const login_fail_limit: u32 = 8;
/// Lockout duration after `login_fail_limit` bad tokens (mono ns).
pub const login_lockout_ns: u64 = 30 * std.time.ns_per_s;
/// Session cookie lifetime (seconds). Stolen cookies expire without process restart.
pub const session_cookie_max_age_s: u32 = 43_200;
```

The session state lives on the server struct (src/server/webui.zig:185-197):

```zig
pub const Server = struct {
    listener: tcp.Listener = .{},
    port: u16 = 0,
    bind_addr: u32 = 0x7f000001,
    secret_buf: [max_secret]u8 = undefined,
    secret_len: usize = 0,
    /// HMAC session material for cookie/CSRF (never the raw secret).
    session_token: [session_token_hex_len]u8 = .{'0'} ** session_token_hex_len,
    /// Monotonic deadline for the current browser session. The cookie's
    /// Max-Age is not an authorization boundary because a stolen cookie can be
    /// replayed by a non-browser client after that client-side deadline.
    session_expires_ns: u64 = 0,
    client_fd: tcp.Handle = -1,
```

The login throttle fields follow the audit ring (src/server/webui.zig:227-230):

```zig
    /// POST /login brute-force throttle (process-local; single poll thread).
    login_fails: u32 = 0,
    /// Mono ns until which further login attempts are rejected (0 = unlocked).
    login_lock_until_ns: u64 = 0,
```

`fillSessionToken` derives the cookie and CSRF value as the first 16 bytes of `HMAC-SHA256(secret, nonce)` rendered as 32 lowercase hex characters (`src/server/webui.zig:1292-1297`). Each login generates a fresh random nonce and replaces the session token and deadline. A zero deadline is invalid; logout clears session state, and restart requires a new login (`src/server/webui.zig:294-305`, `src/server/webui.zig:882-886`). The cookie is `HttpOnly; SameSite=Strict` with the 43200-second Max-Age (`src/server/webui.zig:1346-1352`). Each failed credential presentation increments `login_fails`; on the eighth the server arms a 30-second lock, resets the counter and prints a timestamped line, and a locked server answers 429 with `Retry-After` set to the whole seconds remaining (`src/server/webui.zig:334-342`, `src/server/webui.zig:326-332`). The lockout page substitutes that remaining value into `__ZDTD_RETRY_S__` and the page script counts down to zero before reloading `/login` (`src/server/webui.zig:1440-1446`, `src/server/webui/ts/lockout.ts:20-28`).

Authorization accepts `Authorization: Bearer <secret>`, `X-Zdtd-Secret: <secret>`, or a `zdtd_webui` cookie whose value equals the session token; the raw secret in a cookie is rejected (`src/server/webui.zig:1015-1038`). Everything is compared with `util/secret.zig` constant-time equality. Mutating routes additionally require a `csrf` form field (or `token` on `/api/cmd`) matched against the session token or the secret (`src/server/webui.zig:736-746`, `src/server/webui.zig:639-648`, `src/server/webui.zig:1784-1795`). `POST /api/cmd` runs the line inline through the installed thunk (`Game.webuiAdminThunk` to `runAdminLine`, `src/server/admin_console.zig:597-604`); when no thunk is installed it falls back to the single `cmd_pending` slot queue, which answers 429 rather than 503 when full (`src/server/webui.zig:376-384`, `src/server/webui.zig:766-780`). Console lines must be printable single-line input with no C0 or DEL bytes (`src/server/webui.zig:973-978`). Each accepted line and the first line of its reply are pushed into a 24-entry audit ring and rendered by `/partials/console` (`src/server/webui.zig:247-254`, `src/server/webui.zig:1268-1296`). The ring is in memory only; the file-backed ops log in `docs/WEBUI.md:280` is not implemented here as of this reading.

## The snapshot and its published shape

`Snapshot` is a plain by-value struct with fixed-capacity arrays, so the poll thread can render from it without locking and without allocating. Its head (src/server/webui.zig:80-95):

```zig
pub const Snapshot = struct {
    tick_n: u64 = 0,
    /// Monotonic time (clock.monoNs) of the last main-loop tick that refreshed
    /// this snapshot. Read from the webui poll thread; written from Game.step.
    last_tick_ns: u64 = 0,
    day: u32 = 1,
    hours: f32 = 8,
    bloodmoon_active: bool = false,
    bloodmoon_frequency: u32 = 7,
    /// Days to the jittered CalcNextDay horde (999 = disabled); the webui
    /// status line and the ops gettime share this.
    bloodmoon_in_days: u32 = 999,
    joined: u16 = 0,
    entered: u16 = 0,
    peers_alive: u16 = 0,
    max_players: u16 = 8,
```

The rest of the struct is counter fields mirroring the APM counter set by hand, section mean and p99 latencies, read-only config values, host OS gauges, and the two fixed rosters. Each roster row is its own record because the HTML partial and the JSON document render the same data.

The player row (src/server/webui.zig:58-69):

```zig
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
```

The module row (src/server/webui.zig:79-84):

```zig
pub const ModuleRow = struct {
    used: bool = false,
    disabled: bool = false,
    name_len: u8 = 0,
    name: [64]u8 = .{0} ** 64,
};
```

The roster capacity is not a webui constant: `max_players_snap` is `litenet.root.max_peers`, so a full server cannot hide players past a cap the UI invented (`src/server/webui.zig:31-34`), and the module array length is the plugin host's `max_wasm_plugins` (`src/server/webui.zig:185`). Client-supplied names, world names and module names are HTML-escaped at render time (`src/server/webui.zig:1705-1707`, `src/server/webui.zig:1590-1595`, `src/server/webui.zig:1725-1728`), and the JSON writer escapes separately (`src/server/webui.zig:1996-2013`).

## Pages, TypeScript and the build gates

The three pages are real HTML files embedded at compile time with `@embedFile` and a trailing-newline trim, so nothing is read from disk at runtime and no markup lives in a Zig string literal (`src/server/webui.zig:1390-1404`). Rendering is one forward pass that replaces `__ZDTD_*__` placeholders; an unknown placeholder is copied through so a template typo stays visible, and a buffer that is too small is an error rather than a truncation (`src/server/webui.zig:1450-1478`). The shell takes the product name, stock wire version and the CSRF placeholder (`src/server/webui.zig:1519-1525`); the sign-in page swaps a banner, an invalid flag and an `aria-describedby` value between the plain and failed states (`src/server/webui.zig:1406-1430`).

The JavaScript is authored as TypeScript in `src/server/webui/ts/` and committed inside the pages between `/* zdtd-ts:<page> */` markers (`src/server/webui/shell.html:270-271`, `src/server/webui/login.html:79-100`). The shell script implements the htmx-style poller for the `hx-get` regions, the console form and the delegated modlet POST, all against the same partial routes the server exposes (`src/server/webui/ts/shell.ts:1-6`, `src/server/webui/shell.html:237-239`). The visual contract behind the markup (paper ground, one dark terminal, state carried as words in pills) is recorded in `docs/DESIGN-webui.md:5-14`. `scripts/build-webui-ts.sh` runs `tsc` through `bunx` at the pinned `TSC_VERSION` and splices the emitted classic scripts into the pages; `zig build` never invokes it, so the Zig build stays offline. `scripts/lint-webui.sh` is the gate: `tsc --noEmit` against the strict `tsconfig.json`, `oxlint` with the anti-slop rule set at a pinned SHA and `--deny-warnings`, then a freshness check that regenerates the pages into a temp directory and fails if the committed bytes differ. Both scripts are wired into `make lint` (`Makefile:140`) with `make webui-ts` as the regeneration target (`Makefile:58-59`); the HTML and inline CSS are checked separately by `scripts/lint-html.sh` (`Makefile:140`). The TypeScript compile units are exactly the three page sources listed in `files` (`src/server/webui/ts/tsconfig.json:26`).

Not shipped as of this reading, per the design doc: vendor htmx or Alpine assets and any `/static/*` route, Alpine modals for destructive commands, item-name typeahead, a ban list UI, and a config editor (`docs/WEBUI.md:284-302`). The design also describes a bounded command queue with per-tick drain; the shipped server has one `cmd_pending` slot plus the same-request admin thunk (`docs/WEBUI.md:225-233`, `src/server/webui.zig:213-218`).

## See also

- [`docs/subsystems/apm.md`](apm.md) - counters and section timers the snapshot copies.
- [`docs/subsystems/config.md`](config.md) - where the ports, bind and secret are bound.
- [`docs/subsystems/tick.md`](tick.md) - the 50 ms tick the poll loop rides.
- [`docs/WEBUI.md`](../../docs/WEBUI.md) - route table, security model and WU0-WU4 roadmap.
- [`docs/adr/0018-webui-ops-dashboard.md`](../../docs/adr/0018-webui-ops-dashboard.md) - the settled stack, session and command-path decisions.
