# Threat model

> **What this is:** the CISO-facing map of zdtd's attack surface: entry points, boundaries, assets, ranked threats, and mitigations that exist in code versus gaps. Point vulnerabilities belong to sec-review; this page aims the work.
> **Related:** [AUTHORITY.md](AUTHORITY.md) · [WEBUI.md](WEBUI.md) · [PLUGIN_API.md](PLUGIN_API.md) · [RELEASES.md](RELEASES.md) · [../SECURITY.md](../SECURITY.md) · [adr/0004-server-authoritative-c2s.md](adr/0004-server-authoritative-c2s.md) · [adr/0007-player-inventory-c2s-trust.md](adr/0007-player-inventory-c2s-trust.md) · [adr/0020-wasm-only-plugin-api.md](adr/0020-wasm-only-plugin-api.md) · [adr/0022-anti-cheat-architecture.md](adr/0022-anti-cheat-architecture.md)

**Last reviewed:** 2026-09-27 (code citations verified against this tree).
**Scope:** the `zdtd` process built from this repo (LiteNet play path, TCP GameServerInfo, optional admin/webui/MCP, Wasm plugins, world/save I/O). Not stock Unity dedi, not client mods, not deployment outside this binary. Kept short on purpose: an accurate ranked model beats an exhaustive checklist that drifts.

## Risk-ranked summary

| Rank | Risk | Boundary | Impact if abused | Primary mitigations in code | Gap |
|---|---|---|---|---|---|
| 1 | Operator console / webui / MCP taken over | Operator → process | Kick/ban, give items, shutdown, modlet state edits, arbitrary admin verbs | Loopback bind defaults; webui secret required; admin password gates public bind; MCP loopback + optional Bearer; constant-time compares | Empty telnet password and empty MCP token are loopback-open by design; CLI secrets visible in `ps` |
| 2 | Hostile LiteNet peer (joined or connecting) | Internet → sim | World/inv corruption, grief, tick stall, other-player overwrite | Phase gate; typed C2S; reach/ownership/caps; join IP rate limit; ServerPassword connect key | Player hold inventory is client-trusting ([ADR 0007](adr/0007-player-inventory-c2s-trust.md)); empty ServerPassword = open join |
| 3 | Malicious or buggy Wasm plugin | Build/runtime → host | Host verb abuse, fuel exhaustion, queued side effects | Fuel/memory budgets; declare-required hooks; attributed `zdtd.queue` withdraw on dispose/reload (`src/plugin/wasm.zig:1292`); per-module `deny` + operator `allow` (`src/server/zdtd_config.zig:216`) | Operator-loaded `.wasm` is trusted at load; host still executes queued sim commands the boundary allows |
| 4 | Unauthenticated GSI / connect probe | Internet → info TCP / UDP | Server fingerprinting, password brute force noise, UDP load | GSI is public by stock design; connect rejects + sampled logs; join rate limit | GSI binds all interfaces; no auth on info text |
| 5 | Corrupt or hostile on-disk world/config | Disk → process | Crash, wire disclosure of adjacent memory, hung parse | Length clamps on many loaders; fail-closed XML; DebugAllocator leak checks in tests | Save files and `Mods/` XML are operator-trusted; history shows length bugs recur on new formats |

Ranks are relative exploitability × blast radius for a typical LAN/public dedi, not CVSS scores.

## Attack surface inventory

### Network listeners (process)

| Surface | Default | Bind | Auth gate | Code |
|---|---|---|---|---|
| TCP GameServerInfo (`ServerPort`) | on when `--port` ≠ 0 | `INADDR_ANY` | none (stock browser/list text) | `src/server/serverinfo_tcp.zig:177` |
| UDP LiteNet (`ServerPort+2`) | on with info port | UDP bind of chosen port | `ServerPassword` as LiteNet connect key; empty = open | `src/litenet/server.zig:84`, `src/litenet/packet.zig:147` |
| TCP admin / telnet | off (`--admin-port` / TelnetPort 0) | loopback if password empty; `0.0.0.0` if password set | line password when set; else any line on loopback | `src/server/admin.zig:79` |
| HTTP webui | off (`--webui-port` 0) | loopback only, enforced (`src/server/webui.zig:292`) | shared secret required to listen; HMAC session cookie | `src/server/webui.zig:281` |
| HTTP MCP | off (`--mcp-port` 0) | loopback only | Bearer/token when configured; empty token = loopback anonymous | `src/server/mcp_transport.zig:77` |

CLI and env that arm the surface: usage text `src/main.zig:30`, option loop `src/main.zig:370` (positionals refused, `src/main.zig:380`), webui secret env preference `src/main.zig:620`, MCP token env `src/main.zig:633`, webui loopback enforcement `src/main.zig:674`, MCP loopback enforcement `src/main.zig:704`.

### Webui HTTP routes (operator surface)

Every route below is behind the secret/session check at `src/server/webui.zig:675`; the mutating ones also require the CSRF token unless the request authenticates with a header (`src/server/webui.zig:1300`).

| Route | Method | Effect | Code |
|---|---|---|---|
| `/login` | GET, POST | exchange the shared secret for an HMAC session cookie | `src/server/webui.zig:602` |
| `/logout` | POST | drop the session (CSRF gated) | `src/server/webui.zig:706` |
| `/api/cmd` | POST | runs a privileged console line via `runAdminLine` (`src/server/game.zig:1353`) | `src/server/webui.zig:742` |
| `/api/modlet` | POST | writes the modlet enable/disable state on disk (`src/assets/modlets.zig:291`); applied at the next restart | `src/server/webui.zig:733` |
| `/api/state.json`, `/api/apm.json` | GET, HEAD | roster, world state, recent console ring, metrics snapshot | `src/server/webui.zig:779`, `src/server/webui.zig:789` |
| `/`, `/index.html` | GET, HEAD | ops dashboard shell | `src/server/webui.zig:763` |

`/api/modlet` is the only authenticated route that writes outside the process: a stolen session can change which `Mods/<name>` configs load on the next start, a code-adjacent foothold rather than a UI change.

### Other inputs

| Input | Trust assumption in code | Code |
|---|---|---|
| C2S package bodies after LiteNet deframe | untrusted; phase + typed parse + hard checks | `src/server/phase_gate.zig:58`, `src/server/c2s/dispatch.zig:19` |
| `serverconfig.xml` / `zdtd.toml` / presets | operator-trusted at start; a credential key in `zdtd.toml` is refused at load | `src/server/config.zig`, `src/server/zdtd_config.zig:383` |
| World save overlays (`.zch`, player, TE stores) | operator-trusted; must still length-check | `src/server/persist.zig`, `src/world/` |
| Stock `game-dir` + `Mods/` XML / assetbundles | operator-supplied data; XPath patches applied | `src/assets/`, modlet load path |
| Wasm modules under `plugins/` / `mods/` | operator-selected code in sandbox | `src/plugin/wasm.zig:1` |
| CLI argv / env (`ZDTD_WEBUI_SECRET`, `ZDTD_MCP_TOKEN`, passwords) | secrets enter here; values are never printed | `src/main.zig:620`, `src/main.zig:633` |

### Surfaces listed nowhere else as security-critical

- **Join IP throttle** (500 ms class, loopback exempt): `src/litenet/server.zig:36`.
- **Webui login lockout** after failed sign-ins: `src/server/webui.zig:52`, armed at `src/server/webui.zig:389`.
- **Admin failed-login lockout** (process-wide, survives reconnects): `src/server/admin.zig:74`.
- **Per-client C2S rate limits** (inventory and block token buckets, damage burst, chat gap): `src/server/game/rate_limits.zig:31`, `:38`, `:39`, `:49`.
- **Plugin fuel/memory budgets**: `src/plugin/wasm.zig:78`.

No debug port or metrics scrape listener exists beyond the operator-triggered webui/APM dump paths ([APM.md](APM.md)).

## Trust boundaries

### 1. Internet → process (unauthenticated)

**Crosses:** UDP ConnectRequest and any pre-login datagrams; TCP GameServerInfo reads.

**Must validate:** connect key (`src/litenet/server.zig:118`); rate limit (`src/litenet/server.zig:36`); after accept, only phase-legal packages (`src/server/phase_gate.zig:26` connecting allowlist).

**Privilege transition:** ConnectRequest success allocates a peer slot (`src/litenet/server.zig`); PlayerLogin acceptance moves `connecting` → `joined` (see [AUTHORITY.md](AUTHORITY.md)).

### 2. Authenticated game peer → sim

**Crosses:** all play-phase C2S (move, block, damage, inv, TE, chat, …).

**Must validate:** entity/slot ownership, reach, damage caps, land claim, PvP mode, decode bounds. Inventory hold is an explicit trust exception ([ADR 0007](adr/0007-player-inventory-c2s-trust.md)): a peer may overwrite its own hold/bag slots via C2S.

**Privilege transition:** none; the peer stays a player. In-game admin verbs follow `serveradmin.xml` permission levels (operator grant path).

### 3. Operator → process (admin TCP, webui, MCP)

**Crosses:** console lines and HTTP that reach `runAdminLine` / MCP frame handler.

**Must authenticate:** admin password or webui secret/session; MCP token when set. Webui refuses to listen without a secret (`src/server/webui.zig:283`) or off loopback (`src/server/webui.zig:292`), and the secret is length- and charset-checked (`:284`, `:288`). Admin without a password binds loopback only (`src/server/admin.zig:79`) and warns at startup (`src/main.zig:1083`).

**Privilege transition:** an authenticated operator runs the full admin verb surface (kick, ban, give, shutdown, plugin reload, …). Possession of the secret, password or token is root on the game process.

### 4. Plugin guest → host

**Crosses:** Wasm imports (`zdtd.sense` / `zdtd.queue` / `zdtd.query` and hooks). Guests do not speak LiteNet directly.

**Must constrain:** fuel/memory; declared hooks; verb deny/allow; withdraw pending effects on dispose ([ADR 0020](adr/0020-wasm-only-plugin-api.md)).

**Privilege transition:** a queued host command executes with server authority attributed to the plugin slot.

### 5. Secrets → code

| Secret | Enters | Lives | Leaves |
|---|---|---|---|
| ServerPassword | config / init options | `litenet.Server.server_password` (`src/litenet/server.zig:17`, assigned `src/server/game/init_world.zig:104`) | never printed; only `connect_rejects` counters and sampled reject logs (`src/litenet/server.zig:118`) |
| TelnetPassword | config | `admin.Auth.password` | compared constant-time (`src/server/admin.zig:34`) |
| Webui secret | CLI or `ZDTD_WEBUI_SECRET` | `webui` secret buffer, zeroed on deinit (`src/server/webui.zig:311`); session is HMAC, not raw secret | cookie carries session token only (`src/server/webui.zig:989`) |
| MCP token | CLI or `ZDTD_MCP_TOKEN` | transport token buffer; zeroed on deinit | Bearer header compare (`src/server/mcp_transport.zig:401`) |

CLI secrets are warned as visible in process listings (`src/main.zig:628`, `src/main.zig:640`); a credential key in `zdtd.toml` is fatal at load (`src/main.zig:828`). No in-repo rotation beyond restart with a new value.

### 6. Build → runtime

Release bits come from `make release` / the repro gate ([RELEASES.md](RELEASES.md)); committed `.wasm` plugins are rebuild-gated (`scripts/lint-plugins.sh`). Extra operator-loaded modules are a runtime trust decision, not a CI gate.

## Assets

| Asset | Why it matters | Where it lives |
|---|---|---|
| World + player persistence | grief, wipe, item dupe persistence | `worlds/` overlays, persist path |
| Operator secrets | full process control | config, env, argv |
| Peer identities / bans / permissions | lockout and admin escalation | `serveradmin.xml` path, admin XML loaders |
| Tick budget (20 TPS) | DoS equals unplayable server | main loop; caps on streams and frames |
| Plugin host integrity | escape from guest policy | `src/plugin/` |
| Reputation / wire fidelity | wrong packets break stock clients | `src/wire/`, join SM |

PII is limited to player display names and platform ids in admin lists; no payment or account store in this process.

## Threats per boundary (concrete)

### Internet → process

- **Spoofing:** guessed ServerPassword; reconnect storms. Mitigations: constant-time key compare (`src/litenet/packet.zig:147`); join rate limit; reject counters (`src/litenet/server.zig:31`).
- **Tampering:** malformed frames or bodies. Mitigations: fail-closed parse; phase gate drops illegal early C2S.
- **Information disclosure:** GSI text exposes mode, world and player counts on all interfaces (`src/server/serverinfo_tcp.zig:176`). Stock behavior; firewall it off if unwanted.
- **Denial of service:** UDP flood, fragment reassembly, chunk/stream queue growth. Mitigations: fixed peer table (`src/litenet/server.zig:9` `max_peers`); streaming caps ([SCALE.md](SCALE.md)). Residual: the tick is single-threaded, so a flooding client on a poll-step listener stalls everyone (`src/server/mcp_transport.zig:10`).

### Peer → sim

- **Elevation / tampering:** forged inventory (ADR 0007), reach bypass attempts, cross-player entity ids. Mitigations: ownership and reach checks; gap: hold/bag C2S trust.
- **DoS:** chat, block, damage and inventory spam. Mitigations: per-client token buckets and gaps (`src/server/game/rate_limits.zig:31`, `:38`, `:39`, `:49`), all config-bound. Gap: per-client budgets only; N clients can still spend the whole tick, and there is no per-source global quota.

### Operator surfaces

- **Spoofing / elevation:** stolen webui cookie or telnet password. Mitigations: server-side session deadline (`src/server/webui.zig:348`); login lockout (`src/server/webui.zig:389`); CSRF on `/logout`, `/api/cmd`, `/api/modlet` (`src/server/webui.zig:721`, `:812`, `:1873`). Gap: one shared session token space per process, and a valid session is full operator authority including disk writes.
- **Disclosure:** `--webui-secret` on argv; the audit ring and `/api/state.json` carry player names and recent console lines (`src/server/webui.zig:245`); admin greeting fields must not inject CR/LF ([subsystems/admin.md](subsystems/admin.md)).

### Plugin guest → host

- **DoS:** fuel burn traps the module and it stops being called (`src/plugin/wasm.zig:187`). Gap: the host still pays the fuel before the trap, and nothing schedules the disable.
- **Tampering:** queue commands within the boundary's allowlist. Mitigation: per-module `deny` and operator `allow` overrides (`src/server/zdtd_config.zig:216`, `:220`); withdraw on dispose/reload.

### Disk → process

- **Tampering / disclosure:** corrupt saves historically leaked adjacent memory onto the wire (workstation lengths, fixed per CHANGELOG). New loaders stay a recurring class for sec-review.

## Mitigations mapping

| Control | Threats covered | Evidence |
|---|---|---|
| ServerPassword connect key | open join, trivial spoof join | `src/litenet/server.zig:118` |
| Join IP rate limit | connect brute / storm | `src/litenet/server.zig:36` |
| Phase gate | pre-auth play packages | `src/server/phase_gate.zig:58` |
| C2S hard checks + authority mode | grief, illegal state | [AUTHORITY.md](AUTHORITY.md), `src/server/c2s/` |
| Admin bind rule + password + lockout | remote console takeover | `src/server/admin.zig:79` |
| Webui loopback + secret + CSRF + lockout | remote ops UI takeover, silent modlet state edits | `src/server/webui.zig:281`, `:1300` |
| MCP loopback + frame caps + token | remote tool exec | `src/server/mcp_transport.zig:26`, `:77`, `:401` |
| Wasm fuel/memory + effect withdraw | runaway / sticky plugin effects | `src/plugin/wasm.zig:78`, `src/plugin/wasm.zig:1292` |
| Per-client C2S rate limits | chat/block/damage/inventory spam | `src/server/game/rate_limits.zig:31` |
| Constant-time secret compare | timing oracle on passwords | `src/util/secret.zig` (admin/webui/MCP/LiteNet) |

### Single points of failure

- **One shared webui secret** protects the entire ops HTTP surface.
- **ServerPassword** is the only network join secret; empty means public join on the LiteNet port.
- **Operator-loaded Wasm** inherits whatever host verbs policy allows; sandbox limits compute, not intent.

### Documentation vs code

Claims in [WEBUI.md](WEBUI.md) (loopback-only bind, secret required) match `src/server/webui.zig:292` and `src/main.zig:674`. No in-process TLS: plain HTTP on loopback, reverse proxy is operator-side.

## Abuse cases (authenticated hostile player)

Documented for aiming controls; not demonstration steps.

1. **Inventory fabrication:** peer sends `NetPackagePlayerInventory` / bag C2S to materialize items in its own hold. Enabling path: ADR 0007 client-trusting apply. Server does not S2C-echo PlayerInventory.
2. **Quota / stream pressure:** peer stays in interest range and forces chunk/entity streams up to configured caps. Enabling path: chunk stream + interest systems; caps exist but the tick is shared.
3. **Permission gaming:** peer with an elevated `serveradmin.xml` level uses in-game admin-like verbs. Enabling path: permission checks on command dispatch.
4. **Modlet state flip:** a host with (or who steals) the webui session POSTs `/api/modlet` to disable a config modlet so the next start loads different catalog data. Enabling path: `src/server/webui.zig:733` into `src/assets/modlets.zig:291`.

Client-side UI restrictions are not a control boundary; only server checks count.

## Response readiness (notes only)

- Webui keeps a small in-memory audit ring of operator console lines (`src/server/webui.zig:270`); not a durable SIEM trail. Process logs go to stderr only.
- Guard/evidence rings support anti-cheat investigation ([AUTHORITY.md](AUTHORITY.md)), not host auth logs.
- The report → fix → ship path is in [RELEASES.md](RELEASES.md) and [../SECURITY.md](../SECURITY.md); no in-repo IR runbook.

## Maintenance

When adding a listener, HTTP route, auth gate, or trust exception: update the inventory and risk table in the same change with a `file:LINE` citation. Delete stale rows rather than leaving “planned” mitigations.
