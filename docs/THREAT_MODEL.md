# Threat model

> **What this is:** the CISO-facing map of zdtd's attack surface: entry points, trust boundaries, assets, ranked threats, and mitigations that exist in code versus gaps. Point vulnerabilities belong to sec-review; this page aims the work.
> **Related:** [AUTHORITY.md](AUTHORITY.md) · [WEBUI.md](WEBUI.md) · [PLUGIN_API.md](PLUGIN_API.md) · [RELEASES.md](RELEASES.md) · [../SECURITY.md](../SECURITY.md) · [adr/0004-server-authoritative-c2s.md](adr/0004-server-authoritative-c2s.md) · [adr/0007-player-inventory-c2s-trust.md](adr/0007-player-inventory-c2s-trust.md) · [adr/0020-wasm-only-plugin-api.md](adr/0020-wasm-only-plugin-api.md) · [adr/0022-anti-cheat-architecture.md](adr/0022-anti-cheat-architecture.md)

**Last reviewed:** 2026-09-21 (code citations verified against this tree).
**Scope:** the `zdtd` process built from this repo (LiteNet play path, TCP GameServerInfo, optional admin/webui/MCP, Wasm plugins, world/save I/O). Not stock Unity dedi, not client mods, not deployment orchestration outside this binary.

This page is intentionally short. Prefer an accurate ranked model over an exhaustive checklist that drifts.

## Risk-ranked summary

| Rank | Risk | Boundary | Impact if abused | Primary mitigations in code | Gap |
|---|---|---|---|---|---|
| 1 | Operator console / webui / MCP taken over | Operator → process | Kick/ban, give items, shutdown, config export, arbitrary admin verbs | Loopback bind defaults; webui secret required; admin password gates public bind; MCP loopback + optional Bearer; constant-time compares | Empty telnet password is intentional loopback-open; MCP empty token is loopback-open; CLI secrets visible in `ps` |
| 2 | Hostile LiteNet peer (joined or connecting) | Internet → sim | World/inv corruption, grief, tick stall, other-player overwrite | Phase gate; typed C2S; reach/ownership/caps; join IP rate limit; ServerPassword connect key | Player hold inventory is client-trusting ([ADR 0007](adr/0007-player-inventory-c2s-trust.md)); empty ServerPassword = open join |
| 3 | Malicious or buggy Wasm plugin | Build/runtime → host | Host verb abuse, fuel exhaustion, queued side effects | Fuel/memory budgets; declare-required hooks; attributed `zdtd.queue` withdraw on disable; operator deny/allow | Operator-loaded `.wasm` is trusted at load; host still executes queued sim commands the boundary allows |
| 4 | Unauthenticated GSI / connect probe | Internet → info TCP / UDP | Server fingerprinting, password brute force noise, UDP load | GSI is public by stock design; connect rejects + sampled logs; join rate limit | GSI binds all interfaces; no auth on info text |
| 5 | Corrupt or hostile on-disk world/config | Disk → process | Crash, wire disclosure of adjacent memory, hung parse | Length clamps on many loaders; fail-closed XML; DebugAllocator leak checks in tests | Save files and `Mods/` XML are operator-trusted; history shows length bugs recur on new formats |

Ranks are relative exploitability × blast radius for a typical LAN/public dedi, not CVSS scores.

## Attack surface inventory

### Network listeners (process)

| Surface | Default | Bind | Auth gate | Code |
|---|---|---|---|---|
| TCP GameServerInfo (`ServerPort`) | on when `--port` ≠ 0 | `INADDR_ANY` | none (stock browser/list text) | `src/server/serverinfo_tcp.zig:173` |
| UDP LiteNet (`ServerPort+2`) | on with info port | UDP bind of chosen port | `ServerPassword` as LiteNet connect key; empty = open | `src/litenet/server.zig:84`, `src/litenet/packet.zig:147` |
| TCP admin / telnet | off (`--admin-port` / TelnetPort 0) | loopback if password empty; `0.0.0.0` if password set | line password when set; else any line on loopback | `src/server/admin.zig:79` |
| HTTP webui | off (`--webui-port` 0) | loopback only | shared secret required to listen; HMAC session cookie | `src/server/webui.zig:260` |
| HTTP MCP | off (`--mcp-port` 0) | loopback only | Bearer/token when configured; empty token = loopback anonymous | `src/server/mcp_transport.zig:75` |

CLI and env that arm the surface: `src/main.zig:28` (usage text), flag parse from `src/main.zig:380`, webui secret env preference `src/main.zig:623`, loopback enforcement `src/main.zig:645` / `src/main.zig:668`.

### Other inputs

| Input | Trust assumption in code | Code |
|---|---|---|
| C2S package bodies after LiteNet deframe | untrusted; phase + typed parse + hard checks | `src/server/phase_gate.zig:58`, `src/server/c2s/dispatch.zig:19` |
| `serverconfig.xml` / `zdtd.toml` / presets | operator-trusted at start | `src/server/config.zig`, `src/server/zdtd_config.zig` |
| World save overlays (`.zch`, player, TE stores) | operator-trusted; must still length-check | `src/server/persist.zig`, `src/world/` |
| Stock `game-dir` + `Mods/` XML / assetbundles | operator-supplied data; XPath patches applied | `src/assets/`, modlet load path |
| Wasm modules under `plugins/` / `mods/` | operator-selected code in sandbox | `src/plugin/wasm.zig:1` |
| CLI argv / env (`ZDTD_WEBUI_SECRET`, passwords) | secrets enter here; never log values | `src/main.zig:1075` |

### Surfaces listed nowhere else as security-critical

- **Join IP throttle** (500 ms class, loopback exempt): `src/litenet/server.zig:18`.
- **Webui login lockout** after failed POSTs: `src/server/webui.zig:45`.
- **Admin failed-login lockout** (process-wide): `src/server/admin.zig:69`.
- **Plugin fuel/memory budgets**: `src/plugin/wasm.zig:72`.

No separate debug HTTP port or metrics scrape listener exists beyond webui/APM dump paths documented in [APM.md](APM.md) (operator-triggered, not an open Prometheus bind in this tree).

## Trust boundaries

### 1. Internet → process (unauthenticated)

**Crosses:** UDP ConnectRequest and any pre-login datagrams; TCP GameServerInfo reads.

**Must validate:** connect key (`src/litenet/server.zig:118`); rate limit (`src/litenet/server.zig:36`); after accept, only phase-legal packages (`src/server/phase_gate.zig:26` connecting allowlist).

**Privilege transition:** ConnectRequest success allocates a peer slot (`src/litenet/server.zig`); PlayerLogin acceptance moves `connecting` → `joined` (see [AUTHORITY.md](AUTHORITY.md)).

### 2. Authenticated game peer → sim

**Crosses:** all play-phase C2S (move, block, damage, inv, TE, chat, …).

**Must validate:** ownership of entity/slots, reach, damage caps, land claim, PvP mode, decode bounds. Inventory hold is an explicit trust exception ([ADR 0007](adr/0007-player-inventory-c2s-trust.md)): the peer may overwrite its own hold/bag slots via C2S.

**Privilege transition:** none to operator; peer remains a player. Admin verbs from in-game chat/commands follow `serveradmin.xml` permission levels (operator grant path), not this boundary's default.

### 3. Operator → process (admin TCP, webui, MCP)

**Crosses:** console lines and HTTP that reach `runAdminLine` / MCP frame handler.

**Must authenticate:** admin password or webui secret/session; MCP token when set. Webui refuses to listen without a secret (`src/server/webui.zig:262`). Admin without password warns and binds loopback only (`src/main.zig:1053`, `src/server/admin.zig:81`).

**Privilege transition:** authenticated operator runs the full admin verb surface (kick, ban, give, shutdown, plugin reload, …). Treat possession of the secret/password/token as root on the game process.

### 4. Plugin guest → host

**Crosses:** Wasm imports (`zdtd.sense` / `zdtd.queue` / `zdtd.query` and hooks). Guests do not speak LiteNet directly.

**Must constrain:** fuel/memory; declared hooks; verb deny/allow; withdraw pending effects on disable ([ADR 0020](adr/0020-wasm-only-plugin-api.md)).

**Privilege transition:** a queued host command executes with server authority attributed to the plugin slot.

### 5. Secrets → code

| Secret | Enters | Lives | Leaves |
|---|---|---|---|
| ServerPassword | config / init options | `litenet.Server.server_password` slice | never logged as value (`src/main.zig:1075` prints `set`/`open`) |
| TelnetPassword | config | `admin.Auth.password` | compared constant-time (`src/server/admin.zig:32`) |
| Webui secret | CLI or `ZDTD_WEBUI_SECRET` | `webui` secret buffer; session is HMAC, not raw secret | cookie carries session token only (`src/server/webui.zig:200`) |
| MCP token | CLI | transport token buffer; zeroed on deinit | Bearer header compare (`src/server/mcp_transport.zig:395`) |

CLI `--webui-secret` is warned as visible in process listings (`src/main.zig:623`). No in-repo rotation protocol beyond restart with a new value.

### 6. Build → runtime

Release bits come from `make release` / repro gate ([RELEASES.md](RELEASES.md)). Committed `.wasm` plugins are rebuild-gated (`scripts/lint-plugins.sh`). Operators can still load additional modules via config; that is a runtime trust decision, not a CI gate.

## Assets

| Asset | Why it matters | Where it lives |
|---|---|---|
| World + player persistence | grief, wipe, item dupe persistence | `worlds/` overlays, persist path |
| Operator secrets | full process control | config, env, argv |
| Peer identities / bans / permissions | lockout and admin escalation | `serveradmin.xml` path, admin XML loaders |
| Tick budget (20 TPS) | DoS equals unplayable server | main loop; caps on streams and frames |
| Plugin host integrity | escape from guest policy | `src/plugin/` |
| Reputation / wire fidelity | wrong packets break stock clients | `src/wire/`, join SM |

PII is limited to player display names and platform ids handled for admin lists; no payment or personal account store in this process. Privacy mapping is out of scope here.

## Threats per boundary (concrete)

### Internet → process

- **Spoofing:** ConnectRequest with guessed ServerPassword; reconnect storms. Mitigations: constant-time key compare (`src/litenet/packet.zig:147`); join rate limit; reject counters (`src/litenet/server.zig:31`).
- **Tampering:** malformed LiteNet / package bodies. Mitigations: parse-fail closed; phase gate drops illegal early C2S.
- **Information disclosure:** GSI text exposes mode/world/player counts on all interfaces (`src/server/serverinfo_tcp.zig:176`). Accepted stock behavior; firewall if undesireable.
- **Denial of service:** UDP flood, fragment reassembly, chunk/stream queue growth. Mitigations: fixed peer table (`src/litenet/server.zig:9` `max_peers`); streaming caps elsewhere (see [AUTHORITY.md](AUTHORITY.md), [SCALE.md](SCALE.md)). Residual: single-threaded tick means a heavy poll path stalls everyone (`src/server/mcp_transport.zig:7` notes MCP stalls the poll step).

### Peer → sim

- **Elevation / tampering:** forged inventory (ADR 0007), reach checks bypass attempts, cross-player entity ids. Mitigations: ownership and reach hard checks; gap: hold/bag C2S trust.
- **DoS:** chat/damage spam. Partial rate helpers exist (e.g. chat accept path via `Game.acceptChatRate`); not a full global QoS fabric.

### Operator surfaces

- **Spoofing / elevation:** stolen webui cookie or telnet password. Mitigations: session expiry (`src/server/webui.zig:52`); login lockouts; CSRF on mutating webui POSTs ([WEBUI.md](WEBUI.md)). Gap: single shared webui session model (one browser session token space per process).
- **Disclosure:** `--webui-secret` on argv; admin greeting fields must not inject CR/LF (`src/server/admin.zig` telnetSafe path documented in [subsystems/admin.md](subsystems/admin.md)).

### Plugin guest → host

- **DoS:** fuel burn disables the module (`src/plugin/wasm.zig:174` class behavior). Gap: malicious module still consumes host time until disabled.
- **Tampering:** queue commands within allowlist. Mitigation: operator deny/allow (`src/server/zdtd_config.zig:211`); withdraw on disable.

### Disk → process

- **Tampering / disclosure:** corrupt saves historically leaked adjacent memory onto the wire (workstation lengths; fixed, recorded in CHANGELOG). New loaders remain a recurring class for sec-review.

## Mitigations mapping

| Control | Threats covered | Evidence |
|---|---|---|
| ServerPassword connect key | open join, trivial spoof join | `src/litenet/server.zig:118` |
| Join IP rate limit | connect brute / storm | `src/litenet/server.zig:36` |
| Phase gate | pre-auth play packages | `src/server/phase_gate.zig:58` |
| C2S hard checks + authority mode | grief, illegal state | [AUTHORITY.md](AUTHORITY.md), `src/server/c2s/` |
| Admin bind rule + password + lockout | remote console takeover | `src/server/admin.zig:79` |
| Webui loopback + secret + CSRF + lockout | remote ops UI takeover | `src/server/webui.zig:260` |
| MCP loopback + frame caps + token | remote tool exec | `src/server/mcp_transport.zig:24`, `:75` |
| Wasm fuel/memory + effect withdraw | runaway / sticky plugin effects | `src/plugin/wasm.zig:72` |
| Constant-time secret compare | timing oracle on passwords | `src/util/secret.zig` (via admin/webui/MCP/LiteNet) |

### Single points of failure

- **One shared webui secret** protects the entire ops HTTP surface.
- **ServerPassword** is the only network join secret; empty means public join on the LiteNet port.
- **Operator-loaded Wasm** inherits whatever host verbs policy allows; sandbox limits compute, not intent.

### Documentation vs code

Claims in [WEBUI.md](WEBUI.md) (loopback-only bind, secret required) match `src/server/webui.zig:262` and `src/main.zig:645`. Do not assume TLS inside zdtd: plain HTTP on loopback only; reverse proxy is operator-side.

## Abuse cases (authenticated hostile player)

Documented for aiming controls; not demonstration steps.

1. **Inventory fabrication:** peer sends `NetPackagePlayerInventory` / bag C2S to materialize items in its own hold. Enabling path: ADR 0007 client-trusting apply. Server does not S2C-echo PlayerInventory.
2. **Quota / stream pressure:** peer stays in interest range and forces chunk/entity streams up to configured caps. Enabling path: chunk stream + interest systems; caps exist but tick is shared.
3. **Permission gaming:** peer with elevated `serveradmin.xml` level uses in-game admin-like verbs. Enabling path: admin permission checks on command dispatch (trusted TCP/webui leave actor at highest trust; in-game path is level-gated).

Client-side UI restrictions are not a control boundary; only server checks count.

## Response readiness (notes only)

- Webui keeps a small in-memory audit ring for operator commands (`src/server/webui.zig:251`); this is not a durable SIEM trail.
- Guard/evidence rings support anti-cheat investigation ([AUTHORITY.md](AUTHORITY.md)); they are not a substitute for host auth logs.
- Vulnerability → fix → ship path for versions is described in [RELEASES.md](RELEASES.md) and [../SECURITY.md](../SECURITY.md). No separate in-repo IR runbook.

## Maintenance

When adding a listener, auth gate, or trust exception: update the inventory and risk table in the same change, with a `file:LINE` citation. Prefer deleting stale rows over leaving “planned” mitigations.
