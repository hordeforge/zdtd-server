# Operator web UI

The web UI owns the embedded operator pages and the HTTP surface that serves them: the loopback listener, the route table, the shared-secret login, the session cookie and lockout throttle, the read-only `Snapshot` the dashboard renders from, and the TypeScript sources, bundled pages and lint gates that keep the markup honest. Its boundary is HTTP in, HTML and two JSON documents out; since ADR 0040 the dashboard is a Preact app over `GET /api/state.json`, while the sign-in and lockout pages stay server-rendered on purpose. It encodes no package and reads no sim state directly, reaching the game through two narrow paths: the `AdminFn` thunk `Game` installs so a console line runs through the same parser as admin TCP (`Game.webuiAdminThunk`, `src/server/admin_console.zig:597-604`), and the modlet enabled/disabled text file `POST /api/modlet` rewrites through `assets/modlets.zig` (`src/server/webui.zig:1658`). The package sits in `server`, whose facade states the dependency direction: "top of the stack. May import all other src packages" (`src/server/root.zig:3`). Nothing outside `server` imports it except `src/main.zig:16` and `src/fuzz.zig:714`. Nothing here affects stock client compatibility.

Sources: [`src/server/webui.zig`](../../src/server/webui.zig), [`src/server/webui/shell.html`](../../src/server/webui/shell.html), [`src/server/webui/login.html`](../../src/server/webui/login.html), [`src/server/webui/login_lockout.html`](../../src/server/webui/login_lockout.html), [`src/server/webui/ts/shell.tsx`](../../src/server/webui/ts/shell.tsx), [`src/server/webui/ts/chart.ts`](../../src/server/webui/ts/chart.ts), [`src/server/webui/ts/login.ts`](../../src/server/webui/ts/login.ts), [`src/server/webui/ts/lockout.ts`](../../src/server/webui/ts/lockout.ts)

## Enabling and wiring

The server is off unless `--webui-port` is non-zero; the flag defaults to `0` and the bind and secret default to `127.0.0.1` and the empty string (`src/server/game/types.zig:238-241`). The secret may come from `ZDTD_WEBUI_SECRET`, which wins over the CLI only when the CLI value is empty; a CLI secret prints a warning because argv is visible in process listings (`src/main.zig:583-597`). Startup fails closed: a non-zero port without a secret is a usage error, as are a too-short secret and a bind that is not loopback (`src/main.zig:602-614`). Initialization then listens, installs the admin thunk, and returns the error on failure so a requested-but-dead UI cannot look healthy (`src/server/game/init_world.zig:203-224`). Teardown closes the listener (`src/server/game/lifecycle.zig:34`), and the same call runs on the error path of a later init step (`src/server/game.zig:977`).

`Config` carries the port (0 disables), the bind host, the shared secret and the allocator the rare mutating route uses (`src/server/webui.zig:53-61`).

`listen` returns silently for port 0 and otherwise rejects an empty, too-short (under 8), too-long (over 128) or header-unsafe secret, and any bind address that is not IPv4 loopback (`src/server/webui.zig:256-267`). `parseIpv4` maps `0.0.0.0` to `0`, which `isLoopbackIpv4` then refuses, so a public bind is a startup error rather than a surprise (`src/server/webui.zig:1106-1105`, `src/server/webui.zig:1362-1350`).

## Per-tick wiring

There is no HTTP thread. `Game.step` polls the listener up to four times per tick inside the `.net_poll` scope (`src/server/game/step.zig:30`, `src/server/game/step.zig:87`). `Game.pollWebui` first drains up to four queued console lines through `runAdminLine(line, "webui")`, then calls the non-blocking `Server.poll` (`src/server/admin_console.zig:89-103`). Both the run loop and `--once` refresh the snapshot after `step` returns, so the copy happens with the step frame unwound (`src/server/game.zig:4158`, `src/main.zig:1167`). `fillWebuiSnap` returns immediately when the listener is disabled, and otherwise rebuilds only every tenth tick because a browser polls at one second or slower (`src/server/admin_console.zig:107-111`). It zeroes the snapshot in place and copies director clock, client and peer counts, entity census, APM counters, percentiles, config values and host OS gauges into it; the poll thread never reads live game state (`src/server/admin_console.zig:112-253`).

## Listener and request lifecycle

`Server.poll` accepts one client into the single slot, counts polls, drops a request that never completes once polls pass `max_client_polls` (800 polls, roughly 10 s at four polls per 50 ms tick), then reads and serves (`src/server/webui.zig:343-355`). Reads are non-blocking; a complete header block is required before parsing, `Content-Length` is pre-checked so a body is accumulated whole, duplicate or invalid length and any transfer encoding are client faults, and a request over `max_req` (8192 bytes) gets 413 (`src/server/webui.zig:399-453`, `src/server/webui.zig:1043-1036`, `src/server/webui.zig:1127-1128`). Parsing then hands the buffered bytes to `std.http.Server` with a fixed output buffer of `max_shell_html + 4096` bytes, sized for the rendered shell (`src/server/webui.zig:456-464`). A malformed request line or oversized header becomes 400 or 431, not 500 (`src/server/webui.zig:465-475`).

Responses are built by `httpRespond`, which always sends `Cache-Control: no-store`, the hardening headers, and `Connection: close` (`src/server/webui.zig:872-892`, `src/server/webui.zig:1003-1000`). The content security policy is one module constant with inline style and script allowed and `frame-ancestors 'none'` (`src/server/webui.zig:998-985`). Pre-parse failures use `rawRespond`, which writes headers by hand (`src/server/webui.zig:967-968`); when `client_fd` is negative, as in unit tests, the response is copied into `test_resp` instead of a socket (`src/server/webui.zig:955-950`, `src/server/webui.zig:984-976`).

## Routes

`GET`/`HEAD /healthz` and `/readyz` are served before authentication (`src/server/webui.zig:480-510`). Readiness is 503 while `tick_n` is zero and 503 when the last snapshot is older than `readiness_stale_ns` (30 s), so a wedged sim loop cannot report ready (`src/server/webui.zig:1098-1090`). Every other path requires a valid credential (`src/server/webui.zig:608-620`). `GET /login` shows the form, redirects to `/` when the session is valid, and shows the lockout page with 429 while locked; `POST /login` requires a form content type, then answers 400 for a missing or empty `token`, 401 for a wrong secret, 415 for a non-form body, or 303 to `/` with a session cookie (`src/server/webui.zig:533-592`). `POST /logout` requires the form content type and a `csrf` field matching the session token or the shared secret, then answers 303 to `/login` and clears the cookie with `Max-Age=0` (`src/server/webui.zig:638-648`, `src/server/webui.zig:933-939`). `POST /api/cmd` and `POST /api/modlet` are the two mutating routes, both POST-only (`src/server/webui.zig:668-674`).

The pre-auth set is `/healthz`, `/readyz` and `/favicon.svg` (`src/server/webui.zig:480-505`). The GET-only set is enumerated in one predicate: `/`, `/index.html`, `/api/state.json` and `/api/apm.json` (`src/server/webui.zig:1087-1078`). The six former partial routes, `/partials/status`, `/partials/players`, `/partials/modules`, `/partials/apm`, `/partials/settings` and `/partials/console`, match no route and answer 404 like any other unknown path (`src/server/webui.zig:1087-1078`, `src/server/webui.zig:718`). A wrong method on a known path gets 405 with an `Allow` header (`src/server/webui.zig:693-683`). Unauthenticated `/api/*` answers plain 401 plus `WWW-Authenticate: Bearer realm="zdtd-webui"`, while browser routes get the HTML sign-in form (`src/server/webui.zig:624-618`). `GET /favicon.svg` is served before authentication, next to `/healthz`, from an embedded SVG (`src/server/webui.zig:493-505`, `src/server/webui.zig:1454-1457`); all three pages link it (`src/server/webui/shell.html:4`), and gating it would log a 401 for the sign-in page every operator starts on.

`GET /api/state.json` is the whole dashboard state (`src/server/webui.zig:702-697`). Its document has `csrf` (the HMAC session token), `tick` (the `Snapshot` scalars under their Zig field names), `players`, `modules`, `modlets`, `console` (the audit ring, oldest line first) and `apm`, the nested `/api/apm.json` object rather than a string, so the two documents cannot drift (`src/server/webui.zig:1921-1934`, `src/server/webui.zig:1763-1896`). `/api/apm.json` serializes that same snapshot as `{"type":"zdtd_webui_apm",...}` with counters, latency fields, config, OS gauges and a compact player and module roster for tools (`src/server/webui.zig:1756-1742`). The `modlets` key is the XML-only roster, populated regardless of tick freshness (`src/server/webui.zig:1957-1953`).

## Login, session and lockout

Three constants define the throttle and cookie lifetime (src/server/webui.zig:44-49):

```zig
/// Failed POST /login attempts before temporary lockout (brute-force throttle).
pub const login_fail_limit: u32 = 8;
/// Lockout duration after `login_fail_limit` bad tokens (mono ns).
pub const login_lockout_ns: u64 = 30 * std.time.ns_per_s;
/// Session cookie lifetime (seconds). Stolen cookies expire without process restart.
pub const session_cookie_max_age_s: u32 = 43_200;
```

The session token, expiry, client slot, receive buffer, snapshot, audit ring and login throttle live on the `Server` struct (`src/server/webui.zig:190-236`). `fillSessionToken` derives the cookie and CSRF value as the first 16 bytes of `HMAC-SHA256(secret, nonce)` rendered as 32 lowercase hex characters (`src/server/webui.zig:1355-1346`). Each login generates a fresh random nonce and replaces the session token and deadline (`src/server/webui.zig:304-311`); logout clears that state, so a restart requires a new login (`src/server/webui.zig:933-939`). The cookie is `HttpOnly; SameSite=Strict` with the 43200-second Max-Age (`src/server/webui.zig:1398-1390`). Each failed credential presentation increments `login_fails`; on the eighth it arms a 30-second lock, resets the counter and prints a timestamped line (`src/server/webui.zig:331-339`). A locked server answers 429 with `Retry-After` set to the whole seconds remaining, rounded up (`src/server/webui.zig:323-329`). The lockout page substitutes that value into `__ZDTD_RETRY_S__` (`src/server/webui.zig:1501-1488`) and the page script counts down to zero before reloading `/login` (`src/server/webui/ts/lockout.ts:20-28`).

Authorization accepts `Authorization: Bearer <secret>`, `X-Zdtd-Secret: <secret>`, or a `zdtd_webui` cookie whose value equals the session token; the raw secret in a cookie is rejected (`src/server/webui.zig:1060-1069`), and every comparison is constant-time. Mutating routes additionally require a `csrf` form field, or a `token` field on `/api/cmd`, matched against the session token or the secret (`src/server/webui.zig:736-734`, `src/server/webui.zig:1613-1613`). `POST /api/cmd` runs the line inline through the installed thunk; with no thunk it falls back to the single `cmd_pending` slot queue, which answers 429 rather than 503 (`src/server/webui.zig:762-772`, `src/server/webui.zig:373-381`). Console lines must be printable single-line input with no C0 or DEL bytes (`src/server/webui.zig:1018-1009`). Each accepted line and the first line of its reply are pushed into a 24-entry audit ring (`src/server/webui.zig:247-254`) and published as the `console` array (`src/server/webui.zig:1321-1311`, `src/server/webui.zig:1940-1928`). The ring is in memory only; the file-backed ops log is not implemented here as of this reading (`docs/WEBUI.md:279`).

## The snapshot and its published shape

`Snapshot` is a plain by-value struct with fixed-capacity arrays, so the poll thread can serve from it without locking and without allocating. Its head (src/server/webui.zig:85-93):

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
```

The rest of the struct is counter fields mirroring the APM counter set by hand, section mean and p99 latencies, read-only config values, host OS gauges, and the two fixed rosters (`src/server/webui.zig:101-185`). Each roster row is its own record: `PlayerRow` carries the slot, entity id, join and enter flags, position and a length-prefixed name (`src/server/webui.zig:63-74`), and `ModuleRow` carries a loaded Wasm module name and its disabled flag (`src/server/webui.zig:78-83`). The roster capacity is not a webui constant: `max_players_snap` is `litenet.root.max_peers` (`src/server/webui.zig:27-30`), and the module array length is the plugin host's `max_wasm_plugins` (`src/server/webui.zig:184`).

`writeJsonFields` and `writeJsonRows` walk the structs at comptime, so a new `Snapshot` field appears in `tick` with no second hand-maintained list (`src/server/webui.zig:1987-1991`, `src/server/webui.zig:2016-2010`). A row is published only when its `used` flag is set, not when its name is non-empty, because a joined peer can have an empty name and a stale name buffer must not resurrect a row the filler stopped writing (`src/server/webui.zig:2012-2002`). A `[N]u8` field serializes as a JSON string over its `<name>_len` sibling, so `world_name` writes `world_name_len` bytes. An unknown field type, or a missing length sibling, is a compile error (src/server/webui.zig:2002-1989):

```zig
            .array => {
                try w.writeAll("\"");
                try jsonEscapeWrite(w, @field(v, f.name)[0..@field(v, f.name ++ "_len")]);
                try w.writeAll("\"");
            },
            else => @compileError("webui state JSON: unsupported field " ++ f.name ++ " (add a case or a top-level key)"),
```

A document too large for the response buffer fails closed: the route answers 500 with a JSON error instead of truncated JSON (`src/server/webui.zig:703-694`), and `renderStateJson` returns an error rather than a partial body (`src/server/webui.zig:1919-1904`). Client-supplied names, world names and console lines are JSON-escaped by one writer shared with the command replies (`src/server/webui.zig:1735-1733`).

## Pages, TypeScript and the build gates

The three pages are real HTML files embedded at compile time with `@embedFile` and a trailing-newline trim, so nothing is read from disk at runtime and no markup is a Zig string literal (`src/server/webui.zig:1449-1442`). Rendering is one forward pass that replaces `__ZDTD_*__` placeholders; an unknown placeholder is copied through and a buffer that is too small is an error rather than a truncation (`src/server/webui.zig:1519-1520`). The shell takes the product name, stock wire version and the CSRF placeholder (`src/server/webui.zig:1592-1579`); the sign-in page swaps a banner, an invalid flag and an `aria-describedby` value between the plain and failed states (`src/server/webui.zig:1473-1472`).

`max_shell_html` grew to hold the bundled Preact app, and a comptime guard fails the build when the committed page no longer fits (src/server/webui.zig:35-41, src/server/webui.zig:1463-1450):

```zig
fn embedTrimmed(comptime path: []const u8) []const u8 {
    const raw = @embedFile(path);
    return comptime if (raw.len > 0 and raw[raw.len - 1] == '\n') raw[0 .. raw.len - 1] else raw;
}

const login_html = embedTrimmed("webui/login.html");
const login_lockout_html = embedTrimmed("webui/login_lockout.html");
const shell_html = embedTrimmed("webui/shell.html");

comptime {
    // A committed page that no longer fits must fail the build with this
    // message, not 500 every dashboard request at runtime. `+ 4096` is the
    // header/capture headroom the response buffers add on top of max_shell_html.
    if (shell_html.len + 4096 > max_shell_html)
        @compileError("shell.html no longer fits max_shell_html; raise the const and its stack-cost comment");
}
```

The dashboard is a Preact app: `src/server/webui/ts/shell.tsx` renders every tab from the state document, and `src/server/webui/ts/chart.ts` draws the tick latency history from the nested `apm` object, imported by `shell.tsx` (`src/server/webui/ts/shell.tsx:7-11`). Each page keeps only the document, the CSS tokens, the app mount point and the bundle marker, with the compiled bundle spliced between the `/* zdtd-ts:<page> */` markers (`src/server/webui/shell.html:250-272`, `src/server/webui/login.html:79-85`, `src/server/webui/login_lockout.html:82-89`). `scripts/webui-ts-project.sh` stages a cache project with a pinned preact version, copying the committed tsconfig and sources so the tools resolve `preact` without a `node_modules` in the tree (`scripts/webui-ts-project.sh:25`, `scripts/webui-ts-project.sh:36-47`). `scripts/build-webui-ts.sh` runs `bun build --format=iife --minify` per page entry and splices the result into the pages (`scripts/build-webui-ts.sh:38-47`, `scripts/build-webui-ts.sh:63-75`); the Zig build never invokes it and stays offline.

`scripts/lint-webui.sh` is the gate: `tsc --noEmit` in the staged project, oxlint with the anti-slop rule set pinned by SHA and `--deny-warnings`, then a freshness check that regenerates the pages and fails if the committed bytes differ (`scripts/lint-webui.sh:44`, `scripts/lint-webui.sh:32`, `scripts/lint-webui.sh:114-125`). `scripts/lint-html.sh` runs vnu over every repo-owned HTML file including the inline CSS (`scripts/lint-html.sh:27-45`). Both are wired into `make lint` (`Makefile:148`) with `make webui-ts` as the regeneration target (`Makefile:60-61`); the TypeScript compile units are the three page sources in `files` (`src/server/webui/ts/tsconfig.json:30`).

Login and the lockout page stay server-rendered on purpose: authentication must work without JavaScript, so both keep server-rendered forms and small classic scripts, and the shell carries a `noscript` note instead of a working dashboard (ADR 0040 decision 6, `src/server/webui/shell.html:249`).

Not shipped as of this reading, per `docs/WEBUI.md` after the ADR 0040 edit: Alpine modals for destructive commands, player row actions, item-name typeahead from the item table, a ban list UI, a config viewer, chunk and interest heat numbers from apm, reverse-proxy TLS notes, an SSE/EventSource stream instead of the poll, a read-only public status page, and the file-backed ops audit log (`docs/WEBUI.md:279`, `docs/WEBUI.md:289-291`, `docs/WEBUI.md:296-301`).

## See also

- [`docs/subsystems/apm.md`](apm.md) - counters and section timers the snapshot copies.
- [`docs/subsystems/config.md`](config.md) - where the ports, bind and secret are bound.
- [`docs/subsystems/tick.md`](tick.md) - the 50 ms tick the poll loop rides.
- [`docs/WEBUI.md`](../../docs/WEBUI.md) - route table, security model and WU0-WU4 roadmap.
- [`docs/DESIGN-webui.md`](../../docs/DESIGN-webui.md) - the paper cockpit visual contract behind the shell markup.
- [`docs/adr/0018-webui-ops-dashboard.md`](../../docs/adr/0018-webui-ops-dashboard.md) - the settled stack, session and command-path decisions.
- [`docs/adr/0040-webui-preact-json-state.md`](../../docs/adr/0040-webui-preact-json-state.md) - the Preact client over the JSON state endpoint.
