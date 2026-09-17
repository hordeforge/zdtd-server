# Admin, console and operator surfaces

This subsystem owns the operator-facing surfaces of the process: the admin TCP (telnet-style) endpoint and its verb set, the pure parser and reply formatters behind every console line, the stock `GameServerInfo` TCP service, the persistent ban/whitelist/permission lists, the guard policy that decides what detector evidence does, and the MCP HTTP transport that carries JSON-RPC frames to a Wasm guest. It does not own what a verb changes: world, inventory and entity mutation happens in `src/ecs/` and `src/server/game/*`, plugin runtimes live in `src/plugin/`, and the encoders it calls live in `src/wire/`. It is the top of the dependency stack, so `src/server/*.zig` may import every other package and no lower package may import back into it: `src/server/root.zig:3` states "Dependency direction: top of the stack. May import all other src packages", and the edge is enforced by `scripts/lint-architecture.sh` (as recorded at `docs/subsystems/config.md:3`). Every surface on this page is polled from the single-threaded tick: `src/server/game/step.zig:84` polls GSI, `:85` the admin console, `:88` MCP, all before the sim step.

Sources: [`src/server/admin.zig`](../../src/server/admin.zig), [`src/server/admin_cmds.zig`](../../src/server/admin_cmds.zig), [`src/server/admin_console.zig`](../../src/server/admin_console.zig), [`src/server/admin_xml.zig`](../../src/server/admin_xml.zig), [`src/server/guard_policy.zig`](../../src/server/guard_policy.zig), [`src/server/serverinfo_tcp.zig`](../../src/server/serverinfo_tcp.zig), [`src/server/evidence.zig`](../../src/server/evidence.zig), [`src/server/mcp_transport.zig`](../../src/server/mcp_transport.zig), [`src/server/game/bans.zig`](../../src/server/game/bans.zig), [`src/server/ally.zig`](../../src/server/ally.zig).

## Admin TCP endpoint and auth

`Server` is a fixed-slot, non-blocking line server: `max_sessions` is 4 and `max_cmd` is 256 (`src/server/admin.zig:9`, `:11`), and `pollLine` accepts a session, then reads at most one newline-terminated line per call (`src/server/admin.zig:249`). Sessions persist across commands, which is what makes it telnet-like, and replies go to the session whose line is being handled.

The bind address is decided by whether a password is set, mirroring the stock rule that a password is the only thing that moves the console off loopback (`src/server/admin.zig:79`). `init_world.zig` sets `auth` and `greeting` before `listen`, and logs whether the console ended up on `127.0.0.1` or `0.0.0.0` (`src/server/game/init_world.zig:169`, `:188`). An unset password accepts every line (`src/server/admin.zig:32`), so it is only safe because the bind is loopback.

The auth record (src/server/admin.zig:17):

```zig
pub const Auth = struct {
    password: []const u8 = "",
    /// TelnetFailedLoginLimit (EnumGamePrefs 0xA5, asm.il:1903939).
    fail_limit: u8 = 10,
    /// TelnetFailedLoginsBlocktime (EnumGamePrefs 0xA6): minutes to refuse further
    /// password attempts after `fail_limit` failures. Process-wide (no peer IP on
    /// the accept path); 0 disables the lockout window (session still closes).
    fail_block_minutes: u16 = 10,

    pub fn enabled(self: Auth) bool {
        return self.password.len > 0;
    }

    /// Constant-time password compare, same helper as the LiteNet connect-key
    /// and webui secret checks. An unset password accepts every line.
    pub fn matches(self: Auth, line: []const u8) bool {
        if (!self.enabled()) return true;
        return secret.constantTimeEql(line, self.password);
    }
};
```

Failed attempts are counted per session *and* process-wide. The per-session counter is cleared when a socket closes, so on its own it throttles nothing; `fails_total` survives reconnects and arms the same lockout, which is what actually bounds the guess rate (`src/server/admin.zig:69`, `:204`). A success logs and clears both counters (`src/server/admin.zig:188`). Two flood guards exist: a session whose 256-byte buffer is full with no newline can never progress and is dropped (`src/server/admin.zig:242`), and when all four slots are busy an unauthenticated session is evicted before an authenticated one (`src/server/admin.zig:122`). Operator-supplied greeting fields pass through `telnetSafe`, which strips CR/LF so a crafted `GameName` cannot forge extra telnet lines (`src/server/admin.zig:320`).

## Parsing: verbs into the Command union

`parseCommand` is a pure function from a line to a `Command` value, allocating nothing and taking no `Game` (`src/server/admin.zig:595`). Slices inside a `Command` point into the caller's line buffer, and a fuzz test asserts that invariant for every arm that carries text, because the dispatcher would otherwise format unrelated memory into an operator reply (`src/server/admin.zig:1312`).

A console target is either a numeric id (entity id, user id, or peer slot) or a name token (src/server/admin.zig:334):

```zig
pub const Target = union(enum) {
    id: i32,
    name: []const u8,
};
```

The three sub-command unions (src/server/admin.zig:369):

```zig
pub const BanSub = union(enum) {
    add: struct { target: Target, seconds: i64, reason: []const u8 },
    remove: Target,
    list,
};

pub const AdminSub = union(enum) {
    add: struct { target: Target, level: u8 },
    remove: Target,
    list,
};

pub const WhitelistSub = union(enum) {
    add: Target,
    remove: Target,
    list,
};
```

`Command` itself (`src/server/admin.zig:387`) is one union of 60-plus arms carrying either plain data (`kickall`, `say`, `settime`, `kill`, `inv`) or `?[]const u8` / `usize` payloads, plus four error arms: `bad_args` for a known zdtd verb with malformed arguments, `err_text` for a verbatim stock error printed as `{prefix}{token}{suffix}`, `wrong_args` for the stock arity message, and `unknown`. Usage strings for known verbs live in one table, `usageFor` (`src/server/admin.zig:536`), which both `help <verb>` and the `bad_args` reply read so the two cannot disagree.

By domain the verbs are: control and ops (`help`, `status`, `guardstats|gs`, `guardreport`, `guardclear|gc`, `evidence|ev`, `apm|metrics`, `save`, `getoptions`, `exportcurrentconfigs`, `loglevel`, `listthreads|lt`, `commandpermission|cp`, `plugin`, `mem`, `chunkcache|cc`, `version`, `shutdown`); players (`list|players`, `listplayers|lp`, `listplayerids|lpi`, `listents|le`, `kick`, `kickall`, `ban`, `unban`, `admin`, `whitelist`, `wipeplayer`, `gamestage`, `give`, `inv`, `kill`, `killall`, `tele|tp`, `say`, `spawnentity|se`); world and time (`gettime|gt`, `settime|st`, `saveworld|sa`, `storm`, `clearweather|stormoff`, `spawnairdrop`); and game prefs and stats (`getgamepref|gg`, `getgamestat|ggs`, `setgamepref|sg`). The `zdtd:` prefix in the help index (`src/server/game/constants.zig:26`) marks the verbs zdtd adds or redefines: `status`, `guardstats`, `guardclear`, `evidence`, `apm`, `plugin`, `inv`, `give`, `tele`, `unban`, `storm`, `clearweather`, `spawnairdrop`, `wipeplayer`, `save`, `getoptions`, `exportcurrentconfigs` and the `list` alias. One stock feature is deliberately absent rather than faked: zdtd has no Steam group concept, so `admin addgroup` / `removegroup` are not parse arms (`src/server/admin.zig:414`). The reply literals are cited to `asm.il` V3.1.0 b14 (`src/server/admin_cmds.zig:6`) while the repo targets the V3.2.0 b10 wire, so a stock-string change between those builds would not have been caught here.

## Dispatch, replies and the player console

`runAdminLine` is the one dispatcher, and every console source funnels through it: the admin TCP poll (`src/server/admin_console.zig:62`), the webui command drain (`:89`), an admin player's F1 in-game console (`:330`), and the webui plugin thunk (`:597`). It trims the line, writes a one-line audit record with the sanitized verb and the source tag, then switches on the parsed `Command` (`src/server/admin_console.zig:1169`). `runAdminLine` itself does not authenticate - auth is the TCP endpoint's job - so a plugin that handles an unknown verb cannot bypass the password gate (`src/server/admin_console.zig:1197`).

Replies go through `adminReply`, which writes to the active TCP session and, when a sink is installed, also appends into a caller buffer so the webui and the in-game console receive the same bytes with no second formatter (`src/server/admin_console.zig:78`). Stock-shaped output is produced by `admin_cmds.zig`, whose formatters take plain data rather than `*Game` so the exact bytes can be asserted without building a world (`src/server/admin_cmds.zig:1`). Unknown verbs get the stock literal `*** ERROR: unknown command '{s}'` (`src/server/admin_cmds.zig:144`) after both plugin hosts have had a chance at the verb (`src/server/admin_console.zig:1154`).

Target resolution is shared by `kick`, `ban`, `admin` and `whitelist`: a numeric target is a peer slot when it is in range and joined, else an entity id, and a name is matched case-insensitively first exactly then by substring, with two substring hits reported as ambiguous (`src/server/admin_console.zig:1071`). Permission keys prefer the `platform:id` composite when the target resolves to an online slot with a platform session, and fall back to the login name (`src/server/admin_console.zig:1141`).

The F1 console is a separate, narrow surface. A read-only allowlist (`gettime`, `listplayers`, `listplayerids`, `listents`, `say`, `version`, and the client-side menu verbs) runs for any player and is answered with `NetPackageConsoleCmdClient` lines; every other verb requires an admin list entry, and then a per-command required level that must not be more privileged than the caller before the line is routed through `runAdminLine` (`src/server/admin_console.zig:291`, `:307`). `permLevelOf` returns the stored list level, else the 1000 default (`src/server/game.zig:3211`), and `commandLevel` returns 0 for a verb with no entry (`src/server/game.zig:3281`), so an unconfigured verb is top-admin-only. `cp` settings live in `Game.command_levels` (`src/server/game.zig:778`) and are never written to disk, so they do not survive a restart.

## Operator lists: bans, whitelist, permissions

Three bounded, allocation-free lists carry operator state: `BanList` (64 entries, `src/server/admin_cmds.zig:180`, `:232`), and two `PermissionList` values for admins and the whitelist (`src/server/admin_cmds.zig:368`, held at `src/server/game.zig:688`). A `Bounded(cap)` string truncates an over-long operator argument instead of failing mid-command (`src/server/admin_cmds.zig:195`).

The ban entry (src/server/admin_cmds.zig:213):

```zig
pub const BanEntry = struct {
    /// EPlatformIdentifier name ("Steam", "EOS", ...). Empty = name-keyed
    /// ban (legacy bans.zsv rows and targets without a platform session).
    platform: Bounded(16) = .{},
    /// The ban key: the platform user id when `platform` is non-empty, else
    /// the login name. Stock AdminBlacklist keys on the platform identifier
    /// (BannedUser.UserIdentifier), so a rename cannot evade a ban.
    id: Bounded(max_id) = .{},
    /// Display name at ban time (stock BannedUser.Name).
    name: Bounded(max_name) = .{},
    reason: Bounded(max_reason) = .{},
    /// Absolute wall-clock expiry so a restart neither resurrects an expired ban
    /// nor silently extends a live one.
    expires_unix: i64 = 0,
    /// Set by the serveradmin.xml loader so a hot-reload can replace the
    /// XML-sourced entries without touching runtime (.zsv) ones.
    from_xml: bool = false,
};
```

Bans are keyed on identity, not address, and are enforced at login: the join path checks the platform-id ban first, then the login name, before the whitelist (`src/server/c2s/join.zig:162`). A ban on an online target additionally drops the session and holds the peer's raw IPv4 in the `ban_ip` table so a reconnect before the next identity check cannot slip through (`src/server/admin_console.zig:663`, table at `src/server/game.zig:630`); `isBanned` is a linear scan of that table (`src/server/game/bans.zig:6`), and the zdtd-only `unban <iphex>` verb removes an entry by parsed hex address (`src/server/admin.zig:726`). The whitelist gates only when it is non-empty, and admins bypass it, matching stock `BansAndWhitelistAuthorizer` (`src/server/c2s/join.zig:179`). A denied login is answered with `NetPackagePlayerDenied` carrying `not_on_whitelist` and then dropped.

Persistence is three line-oriented files beside the world data: `admins.zsv` and `whitelist.zsv` as `level\tid`, `bans.zsv` as `expires \t platform \t id \t name \t reason`, written together by `saveAdminLists` after any mutation (`src/server/admin_console.zig:686`) and read once at startup (`src/server/game/init_world.zig:151`). Deserialization accepts the legacy 2-field and 3-field ban rows and drops rows that are already expired, so a reload cannot resurrect a ban (`src/server/admin_cmds.zig:468`); a corrupt line is skipped and counted, never applied, so a damaged permissions file grants nothing (`src/server/admin_cmds.zig:446`). Field separators are neutralised on write, which is what keeps a written line's field count equal to what the reader will see (`src/server/admin_cmds.zig:550`). Timestamps are printed as `YYYY-MM-DD HH:MM:SS` in UTC, a fixed form rather than stock's locale `DateTime` (`src/server/admin_cmds.zig:558`).

The stock `serveradmin.xml` merges into the same three lists at startup (`src/server/admin_xml.zig:138`), keyed by `platform` + `userid` with the legacy `steamID` fallback (`src/server/admin_xml.zig:37`). Despite the file header's claim that zdtd "applies it at startup, so a serveradmin.xml edit takes effect on restart" (`src/server/admin_xml.zig:13`), there is also an mtime poll: `tickServerAdminReload` re-checks the file every 5 s and re-applies it, clearing only the XML-sourced entries (`src/server/game/tick.zig:1805`). `wipeplayer` erases a player record by login name, dropping any online session first, releasing that name's container claims, and removing ally entries keyed on the dropped identities (`src/server/admin_console.zig:1432`); ally relationships themselves live in `src/server/ally.zig` and persist to `{world_dir}/allies.zal` (`src/server/ally.zig:20`), although the `Game` field comment still describes them as in-memory only (`src/server/game.zig:437`).

## GSI / serverinfo text

Stock `ServerInformationTcpProvider` serves a text document on `ServerPort`; the client reads the advertised `IP` and dials LiteNet at `Port + 2`, so the `Port` value in this text must be `ServerPort`, not the LiteNet bind port (`src/server/serverinfo_tcp.zig:1`). The advertised record set (src/server/serverinfo_tcp.zig:11):

```zig
pub const ServerInfo = struct {
    /// Advertised display / world names.
    game_name: []const u8 = "zdtd",
    game_host: []const u8 = "zdtd",
    level_name: []const u8 = "Navezgane",
    ip: []const u8 = "127.0.0.1",
    /// TCP ServerPort (GameInfoInt Port). Client dials LiteNet at Port+2.
    info_port: u16 = 27015,
    max_players: i32 = 8,
    current_players: i32 = 0,
    server_version: []const u8 = version.stock_wire_gsi_version,
    world_size: i32 = 6144,
    eac_enabled: bool = false,
    /// Stock IsPasswordProtected (ServerPassword set).
    password_protected: bool = false,
    /// GameInfoString 18/19 (RE network.md: SandboxPreset = 0x12, SandboxCode =
    /// 0x13): the browser shows the server's sandbox preset/code. Empty (the
    /// zdtd default, matching GameStats "empty = client default") omits the
    /// keys rather than advertising a blank preset.
    sandbox_preset: []const u8 = "",
    sandbox_code: []const u8 = "",
    /// GameInfoString 3/4/12/13/17 (RE server-browser-prefabs.md): the
    /// operator-configurable browser fields. Empty omits the key (the client
    /// falls back to its defaults), matching the SandboxCode pattern.
    server_description: []const u8 = "",
    server_website_url: []const u8 = "",
    region: []const u8 = "",
    language: []const u8 = "",
    play_group: []const u8 = "",
};
```

`buildInfoText` emits the fixed head of `Key:Value;\r\n` records, then the optional keys, then the stock trailing blank line (`src/server/serverinfo_tcp.zig:72`). Values are escaped the way stock's `GameServerInfo::SetValue` escapes them - `:` becomes `^` and `;` becomes `*` - so an operator's text survives the client's `GetValue` round trip instead of being mangled, and CR/LF are neutralised because a value never contains them and they would break the framing (`src/server/serverinfo_tcp.zig:55`). Responses are wrapped in a 5-ASCII-digit length header plus CRLF (`src/server/serverinfo_tcp.zig:147`). `Provider.poll` accepts at most one client and writes the pre-built text, so the per-tick cost is bounded (`src/server/serverinfo_tcp.zig:196`); the buffered text is rebuilt only when the player count changes, which the main loop does after the sim step (`src/server/game/lifecycle.zig:80`). `start` binds `INADDR_ANY` (`src/server/serverinfo_tcp.zig:173`).

## Guard policy and evidence

The guard is split into three layers with no `Game` import between them. `evidence.zig` owns the vocabulary: `Severity` (`info`, `soft`, `strong`, `hard`), nine `Detector` values (`phase`, `ownership`, `bounds`, `movement`, `decode`, `throttle`, `flood`, `farming`, `other`), an attribution `Surface`, and a fixed 64-entry ring (`src/server/evidence.zig:7`, `:9`, `:16`, `:58`). One recorded event (src/server/evidence.zig:65):

```zig
pub const Event = struct {
    tick: u64 = 0,
    peer_local: i32 = -1,
    entity_id: i32 = -1,
    detector: Detector = .other,
    severity: Severity = .info,
    surface: Surface = .none,
    observed: f32 = 0,
    bound: f32 = 0,
};
```

`guard_policy.zig` is the pure decision layer: no allocator and no wall clock, so windows key off the caller's tick counter and hand-advanced scenario tests stay deterministic (`src/server/guard_policy.zig:1`). The operator switches (src/server/guard_policy.zig:58):

```zig
pub const Policy = struct {
    /// Master switch for the kick rung. Without it the ladder tops out at logs.
    enforce: bool = false,
    /// Even with `enforce`, a kick is only simulated (counted + logged).
    dry_run: bool = true,
    /// Allow the quarantine rung (per-surface C2S denial).
    quarantine: bool = false,
    /// Shed weak evidence + deferrable broadcasts after a tick overrun.
    load_shed: bool = true,
    /// Length of the counting window, in ticks (1200 = 60 s at 20 TPS).
    window_ticks: u64 = 1200,
    /// Distinct Strong detectors inside one window that trip the gate.
    strong_distinct: u8 = 2,
    /// Hard events inside one window that trip the gate.
    hard_repeat: u16 = 25,
    /// Ticks a policy kick waits between the `NetPackagePlayerDenied` send and
    /// the peer drop. 10 ticks at 20 TPS = 0.5 s, matching stock
    /// `GameUtils.disconnectLater(0.5f)` (asm.il:1918548-1918583).
    kick_delay_ticks: u64 = 10,
    /// Ticks the load-shed valve stays open after a tick-budget overrun (2 s).
    shed_hold_ticks: u64 = 40,
    /// Block destroys inside one policy window that trip the weak farming
    /// signal. Heuristic, not stock-derived: nothing in the IL defines a
    /// legitimate harvest rate. Record-only by construction (`.soft`), so
    /// tuning it cannot cause a kick.
    weak_break_rate_per_window: u16 = 900,
```

The struct continues with `clamp`, which repairs zero and over-wide values with a log line rather than panicking (`src/server/guard_policy.zig:87`). Per-client state is `PeerState`: a window start tick, a `strong_mask` of one bit per distinct detector, a `hard_n` counter, a `seen_mask` of (detector, surface) pairs already written to the ring, a one-action-per-window `tripped` latch with its cause detector and tick, the `Quarantine` bits, and an armed `kick_at_tick` (`src/server/guard_policy.zig:124`). `evaluate` rolls the window, folds one event in, and returns a `record` flag plus an `Action` of `none`, `quarantine`, `would_kick` or `kick` (`src/server/guard_policy.zig:167`).

The ladder is structural, not threshold-tuned: `.info` and `.soft` return before any counter is touched, so a weak signal can never open a gate; `kick` additionally requires the server to be in Correct authority mode, `enforce`, and not `dry_run` (`src/server/guard_policy.zig:193`, `:208`). `game/guard.zig` is the only adapter between this layer and the sim. `noteEvidence` applies the load-shed valve, downgrades a `.hard` severity to `.strong` for any detector whose decision weighs client-reported values, calls `evaluate`, records the event and fires the evidence observer plugins, then acts on the returned action (`src/server/game/guard.zig:69`). A tripped quarantine sets the per-surface bits (`:130`); `quarantineDenies` is the check a C2S handler calls at its trust boundary (`:112`); an armed kick sends `NetPackagePlayerDenied` with reason `mod_decision` immediately and sets `kick_at_tick` (`:153`), and the tick's `reapPolicyKicks` drops the peer when that tick arrives (`src/server/game/tick.zig:1592`).

Operator visibility is four verbs: `guardstats` prints the reject counters and then the full policy line plus any quarantined or kick-armed slots (`src/server/admin_console.zig:1251`, `:1887`); `guardreport` prints the dry-run diff, per peer, of which detector would trip the ladder (`src/server/admin_console.zig:945`); `guardclear <slot>` clears one slot's quarantine bits and stops an armed kick (operator escape hatch, `:1267`); `evidence` dumps the ring inline or writes JSONL to a file, defaulting to `<world>/evidence.jsonl`, with the file write failing loudly (`:1276`, `src/server/admin_console.zig:1837`). All of these counters feed the APM harness and appear in the JSON snapshot too (`docs/APM.md:57`).

## MCP transport

`mcp_transport.zig` owns only the bytes: listener, HTTP framing, token auth, and the bounded copy of each JSON-RPC frame into and out of the guest hook. Protocol belongs to the Wasm guest. Like the admin console and webui it is polled from the tick: one connection and at most one complete request per poll call, synchronously, with no extra threads or queues, so a slow or flooding client can only stall the poll step, bounded by the per-request caps (`src/server/mcp_transport.zig:1`, `:108`). The configured shape (src/server/mcp_transport.zig:33):

```zig
pub const Config = struct {
    port: u16 = 0,
    bind_host: []const u8 = "127.0.0.1",
    /// Empty = loopback only, no token. Non-empty tokens are compared in
    /// constant time (util/secret.zig).
    token: []const u8 = "",
};
```

Fail-closed rules are explicit: `listen` rejects a non-loopback bind and an over-long token (`src/server/mcp_transport.zig:74`), the CLI rejects a non-loopback `--mcp-bind` with a message naming a TLS reverse proxy as the remote path (`src/main.zig:630`), only `POST /mcp` is served (`src/server/mcp_transport.zig:205`), a non-empty token is compared in constant time and a miss is 401 (`:219`), `Transfer-Encoding` is refused rather than decoded (`:215`), and the frame cap is 16 KiB inbound with an 8 KiB response buffer (`:24`, `:26`). A guest that returns zero bytes is answered `202 Accepted` with no body, the MCP notification shape, never a fabricated response (`:235`). The handler is a function pointer supplied by `Game`; the frame is routed to the first *live* plugin exporting `on_mcp_frame`, so a trapped module's empty reply cannot swallow the frame forever (`src/server/game/wasm_host.zig:416`). The allowlist for the guest's `admin_command` tool is held as the `mcp_allowlist` string on `Game` (`src/server/game.zig:697`) and served to the guest one prefix per line through the `zdtd.query` verb `mcp.allowlist` (`src/server/game/wasm_host.zig:427`). `deinit` clears the token and nulls the frame handler so a poll after teardown finds no handler rather than a dangling one (`src/server/mcp_transport.zig:87`).

## See also

- [apm.md](apm.md) - the counters and section timers the `apm`, `status` and `guardstats` verbs read.
- [config.md](config.md) - `[authority]` and `[mcp]` keys, and the prefs `setgamepref` writes at runtime.
- [c2s.md](c2s.md) - the trust boundaries whose rejections become guard evidence.
- [`docs/AUTHORITY.md`](../AUTHORITY.md) - the authority mode table and the detector classification the ceiling enforces.
- [`docs/adr/0031-mcp-wasm-module.md`](../adr/0031-mcp-wasm-module.md) - why MCP is a transport plus a Wasm guest.
