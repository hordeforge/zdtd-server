# Writing a zdtd plugin

**Status:** shipped (T9 runtime 2026-08-06; T15 event hooks + deny/adjust
2026-08-07). The runtime loads `.wasm` modules named in zdtd.toml and calls the
lifecycle/event hooks under fuel and memory budgets. The host import table is
deliberately small and documented below; read-only sim views are still open.

A plugin is a single `.wasm` file. Any language that targets WebAssembly works:
Rust, TinyGo, Zig, C, AssemblyScript. You do not link against zdtd, you do not
match a native ABI, and you do not need the zdtd source to build.

- Decision and rationale: [ADR 0020](adr/0020-wasm-only-plugin-api.md)
- Host-side design: [PLUGIN_API.md](PLUGIN_API.md)

## The shape of a plugin

You export functions; the server calls them. You import functions; the server
provides them. Nothing else crosses.

```
your .wasm                        zdtd
  exports:  on_enable      <────  called once when the plugin is enabled
            on_tick        <────  called late in each server tick
            on_player_join <────  called on a player's first join
            on_shutdown    <────  called once at shutdown
            on_player_death <───  verdict hook: deny/adjust (T15)
            on_entity_killed <──  verdict hook: deny/adjust (T15)
            on_block_damage <───  verdict hook: deny/adjust (T15)
            on_quest_complete <─  verdict hook: deny/adjust (T15)
            on_admin_command <──  first handler with reply wins
            on_chat <───────────  filter hook: deny/rewrite
            on_player_login <───  join gate: first deny wins
  imports:  log            ────>  provided by the host, capability-gated
            ...
```

Export only the hooks you need. A missing export means that hook is not
registered, and costs nothing at runtime. Every signature is listed under
[Hooks](#hooks) below; export a hook with the wrong signature and the call
fails, which disables your module.

## Enabling a plugin

List `.wasm` files in `[plugin] modules` in zdtd.toml (world dir or CWD,
see [GAME_OPTIONS.md](GAME_OPTIONS.md)):

```toml
[plugin]
modules = "mods/my_plugin.wasm, mods/stats.wasm"
```

Modules load once at startup; a missing or unloadable module is logged and
skipped, it does not stop the server. `on_enable` runs right after load,
`on_tick` runs late in every tick, `on_player_join` runs on a player's first
join, `on_shutdown` runs at shutdown, and the four event hooks run at their
game events (death, kill, block damage, quest completion).

## Host imports

The host provides five functions, all in the `zdtd` module namespace. The
import **field** names are bare (`log`, not `zdtd_log`); importing
`zdtd.zdtd_log` fails to instantiate.

| Import | Signature | Notes |
|---|---|---|
| `zdtd` . `log` | `(level: i32, ptr: i32, len: i32) -> ()` | Write `len` bytes at `ptr` to the server log; `level` 0..3 (debug/info/warn/err). Sanitized and truncated to 200 bytes |
| `zdtd` . `tick` | `() -> i64` | Current server tick number (1-based, 20 Hz) |
| `zdtd` . `queue` | `(ptr: i32, len: i32) -> i32` | Queue a text `SimCommand`; returns 0 when the bytes were read, 1 when `ptr`/`len` is out of bounds |
| `zdtd` . `sense` | `(ptr: i32, len: i32, token: i32) -> i32` | Read-only world snapshot into the guest's memory at `ptr` (BOTS_SPEC §3); returns bytes written (0 = no sense surface) |
| `zdtd` . `query` | `(req_ptr: i32, req_len: i32, out_ptr: i32, out_cap: i32) -> i32` | Reverse-direction point query (BOTS_SPEC §3): write a text request at `req_ptr`, the host answers at `out_ptr`; returns response bytes (0 = no answer) |

You choose the local symbol name; only the module and field names have to
match. In C:

```c
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
```

In Rust the same table is `#[link(wasm_import_module = "zdtd")] extern "C" { fn
log(level: i32, ptr: i32, len: i32); }`; in Zig, `extern "zdtd" fn log(i32, i32,
i32) void;`.

Every host call reads flat bytes from your linear memory at the offset and
length you declare. There is no filesystem, no socket, no thread and no clock
beyond the tick time `zdtd_tick` returns. WASI is deliberately not used; a
module importing `wasi_snapshot_preview1` fails to instantiate.

### Queued commands

`zdtd_queue` accepts one command per call, as UTF-8 text (bounds: 128 bytes):

| Command | Effect |
|---|---|
| `spawn x y z hp` | Queue a zombie spawn at the block coords with the given HP |
| `despawn id` | Queue removal of the entity with the given net id |
| `damage id amount` | Queue damage to the entity with the given net id |

Commands are applied by the sim on a later tick's drain (the fixed 64-slot
command buffer; a full buffer drops new commands). Unknown or malformed
commands are dropped with a log line. The guest never touches sim state
directly: everything goes through this queue.

## Rules you cannot get around

These are enforced by the runtime, not by convention.

1. **You get one fuel budget for the whole instance, not per call.** Fuel is
   armed once at instantiate (default 100 000 000) and decremented per
   instruction for the life of the process; it is never re-armed between hooks.
   Exhaust it and the call ends with `OutOfFuel`, your plugin is disabled, and
   the server logs which hook and module. An infinite loop costs one tick, not
   the server. This is verified, not aspirational. Budget accordingly: at
   20 Hz, a plugin spending 10 000 fuel per tick exhausts the default budget in
   about eight minutes, so `on_tick` work has to be genuinely small; an operator
   can raise `[plugin] fuel` in zdtd.toml.
2. **You get a linear-memory cap.** Ask for more and instantiation fails.
3. **You only get the host functions your capabilities allow.** There is no
   filesystem, no socket, no thread and no clock beyond the tick time the host
   passes you, unless a capability grants it. WASI is deliberately not used:
   the import table is small on purpose so it can be audited.
4. **You cannot touch the wire.** You may ask for high-level operations the
   server already understands, and you may deny or adjust a request. You cannot
   emit package bytes, invent wire types, or skip the join state machine. This is
   the same authority rule the server applies to clients
   ([AUTHORITY.md](AUTHORITY.md)).
5. **Sim hooks run on the tick thread, in a documented order.** Two servers with
   the same plugins and the same inputs step identically. Do not expect threads.

## What belongs in a plugin (and what must stay native)

**Principle (AGENTS.md rule 29):** anything that is *technically* expressible
over the plugin boundary ships as a Wasm plugin. "It is core" is not a reason
to keep something native; prove that the boundary cannot carry it. When a
feature needs an affordance the boundary lacks, extend the boundary (an
ADR-worthy decision) rather than adding native behavior. This is the general
form of the bot rule (ADR 0026): a bot is a plugin because its brain is
behavior, not server.

### Expressibility audit (native surface vs the boundary)

| Native domain | Status | Boundary affordance |
|---|---|---|
| Chat filtering / commands / reactions | **Plugin already** | `on_chat` (rewrite/suppress, `c2s/misc.zig:42`) |
| Kill / death / quest events | **Plugin already** | `on_entity_killed` / `on_player_death` / `on_quest_complete` verdicts; `mods/zdtd_killfeed` is the reference |
| Quest reward scaling | **Plugin already** | `on_quest_complete` verdict `>0` scales the payout (`step.zig`) |
| Block-damage policy | **Plugin already** | `on_block_damage` verdict (`world.zig:20`) |
| Player-death policy | **Plugin already** | `on_player_death` verdict (`killVerdict`) |
| Admin commands / tooling | **Plugin already** | `on_admin_command` |
| Login gate (allow/deny names) | **Plugin already** | `on_player_login` deny gate (`join.zig:72`) |
| Bot brains | **Plugin already** | `mods/zdtd_bot` (ADR 0026) |
| Player-damage policy (PvP / friendly-fire rules) | **Not yet** — technically expressible with one new verdict | Needs `on_player_damage`-style affordance; until then PvP gate is native authority |
| Guard / anti-cheat policy ladder | **Not yet** — technically expressible but needs per-peer counter/quarantine verbs | Guard state is rate/authority; a plugin verdict surface for it is a deliberate boundary extension |
| Announcements wired to join/leave | **Plugin already** | `on_player_join` / `on_player_leave` (the latter added 2026-08-19; `session_drop.zig`) — `mods/zdtd_killfeed` logs both |
| Announcements wired to more events (trader, vehicle) | **Not yet** — technically expressible | Missing hooks for those events; add hooks, do not add native announcement code |
| Wire encode/emit, LiteNet, chunk stream, interest/replication | **Cannot be a plugin** | Boundary never touches wire bytes or package layout (enforced) |
| ECS sim mutation: inventory, blocks, quests, trading authority | **Cannot be a plugin** | Plugins mutate only via `queue` verbs the server already understands; no direct sim access |
| World store, persistence (ZCH3/ZPV3/…), config loading | **Cannot be a plugin** | Filesystem/capability-gated; init-time, not tick |
| Plugin runtime, APM instrumentation | **Cannot be a plugin** | They host the plugins / measure them |

The audit's rule of thumb: a feature that *decides* is a plugin; a feature
that *emits wire or mutates sim state directly* is native by construction.
Anything in the "Not yet" rows is a boundary-extension candidate: implement
the affordance, then move the behavior into a module.

**Belongs in a plugin (behavior / policy):**

- Bots and bot brains (`mods/zdtd_bot` is the reference implementation).
- Chat commands, filters, and moderation reactions (the `on_chat` hook and
  `queue`).
- Announcements, kill-feeds, scoreboards, stat hooks (the `on_player_death` /
  `on_entity_killed` / `on_quest_complete` verdict hooks).
- Custom game rules expressed as verdicts (deny a kill, alter quest rewards,
  react to block damage).
- Admin automation and operator tooling (`on_admin_command`).
- Event-driven integrations (webhook-style observers, logging).

**Must stay native Zig (the server itself):** wire encode/decode and package
building, LiteNet framing, interest/replication and the chunk stream, ECS
authority (inventory, blocks, quests, trading), world store and persistence,
config loading (`serverconfig.xml` / `zdtd.toml`), the plugin runtime itself,
and APM instrumentation. These run on the 20 TPS hot path, and the plugin
boundary is deliberately narrow: plugins never touch wire bytes or sim memory
directly, they only see `sense` snapshots, `query` answers, and the verbs
`queue` accepts. A feature that must emit wire or mutate sim state directly is
native by construction; a feature that *decides* about such things is a plugin.

**When adding a feature, default to a plugin.** If it cannot be expressed over
`sense`/`queue`/`query` + the hooks, either extend the boundary deliberately
(an ADR-worthy decision) or document why the native placement is required.

**Reference modules shipped in this repo (production plugins, committed
`.wasm`):**

- `mods/zdtd_bot/zdtd_bot.wasm` — the bot brain (ADR 0026): sense → decide →
  `bot <verb>` commands; the flagship plugin.
- `mods/zdtd_killfeed/zdtd_killfeed.wasm` — a minimal event observer: logs
  kills, player deaths and quest completions via the verdict hooks and keeps
  every outcome (0). Use it as the template for announcements, kill-feeds,
  scoreboards and integrations.

## Data across the boundary

Everything crosses as flat bytes in your module's linear memory. The host copies
in and copies out; you never receive a host pointer, and the host never follows
one of yours beyond the length you declare.

The practical consequence: a hook that hands you a structure hands you an offset
and a length into your own memory. Read it, copy what you need, and do not retain
the offset past the call.

## Hooks

Observe / lifecycle hooks (all return `void`):

| Export | Signature | When |
|---|---|---|
| `on_enable` | `() -> ()` | once, at enable: register interest, read config, allocate |
| `on_tick` | `() -> ()` | late in each tick, after sim and replicate; keep it cheap, it runs 20 times a second |
| `on_player_join` | `(peer_slot: i32, entity_id: i32) -> ()` | a player's first join |
| `on_shutdown` | `() -> ()` | once, at shutdown: flush anything you own |

Event hooks (T15, return a verdict):

| Export | Signature | Verdict return |
|---|---|---|
| `on_player_death` | `(victim_entity_id: i32) -> i32` | `<0` deny: the victim survives at 1 hp and the hit is consumed |
| `on_entity_killed` | `(killed_entity_id: i32, killer_entity_id: i32) -> i32` | `<0` deny the kill; `killer` is `-1` when the attacker is unknown (AI melee accumulator) |
| `on_block_damage` | `(x: i32, y: i32, z: i32, dmg: i32) -> i32` | `<0` deny (no damage); `>0` apply that percent (`200` doubles) |
| `on_quest_complete` | `(player_entity_id: i32, quest_def_id: i32) -> i32` | `<0` withhold the payout; `>0` pay that percent of items/exp |

The return convention is: **below 0 denies the proposed outcome, 0 keeps
today's behaviour, above 0 adjusts as a percent** (where a percent is
meaningful). A module that does not export the hook costs nothing and the
default holds. Verdicts are taken in plugin load order, first non-zero wins;
a plugin that traps or exhausts its fuel is disabled and reports keep, so one
broken module cannot veto the game.

Request/reply hooks (the host copies a payload into your memory and reads a
reply back out of it):

| Export | Signature | Return |
|---|---|---|
| `on_admin_command` | `(cmd_ptr, cmd_len, out_ptr, out_cap: i32) -> i32` | `>0` bytes of reply written at `out_ptr` (handled); `<=0` not handled, so the next plugin, then core's `unknown`, gets a turn |
| `on_chat` | `(sender, msg_ptr, msg_len, out_ptr, out_cap: i32) -> i32` | `<0` deny the message; `0` keep it unchanged; `>0` bytes of the rewritten body at `out_ptr`. A rewrite that is not valid chat text is treated as deny |
| `on_player_login` | `(peer_slot, name_ptr, name_len, out_ptr, out_cap: i32) -> i32` | `0` allow; non-zero deny, where the magnitude is the number of reason bytes written at `out_ptr` (`-4` and `4` both mean "deny, 4 bytes of reason"). A deny with 0 bytes reads back as "denied" |

For all three the first plugin that responds wins, and a trap or fuel
exhaustion disables that module while the request proceeds as if it had not
been exported (login stays open, chat is kept, the command falls through).
`on_player_login` runs after the name is sanitized and before the identity ban
check.

The payload the host hands you lives in your own linear memory, at an offset the
host reserves from freshly grown pages, so it does not overlap your statics or
stack. Do not retain either offset past the call.

`on_tick` running at 20 Hz is the one to respect. A hook that burns its budget
every tick will be disabled, which is the system working, but your plugin still
stops.

Fixtures exercising the full surface: `assets/fixtures/plugin_rules.c`
(deny/double verdicts), `assets/fixtures/plugin_trap.c` (trapping hook),
`plugin_admin.c`, `plugin_chat.c` and `plugin_login.c` (the request/reply
hooks), plus `mods/example_chat_filter/` as a drop-in mod layout.

## Building one

Nothing here is zdtd-specific: you are producing a plain WebAssembly module with
no WASI imports.

**Rust**

```sh
cargo build --release --target wasm32-unknown-unknown
# target/wasm32-unknown-unknown/release/my_plugin.wasm
```

```rust
#[no_mangle]
pub extern "C" fn on_tick() { /* ... */ }
```

**Zig**

```sh
zig build-lib plugin.zig -target wasm32-freestanding -dynamic -rdynamic -OReleaseSmall
```

```zig
export fn on_tick() void { }
```

**TinyGo**

```sh
tinygo build -o plugin.wasm -target=wasm-unknown ./plugin
```

**C**

```sh
clang --target=wasm32 -nostdlib -Wl,--no-entry -Wl,--export-all -o plugin.wasm plugin.c
```

Use `wasm32-unknown-unknown` or an equivalent freestanding target rather than a
WASI target. A module that imports `wasi_snapshot_preview1` will fail to
instantiate, because the host does not provide those imports.

## Checking your module before shipping

```sh
wasm-objdump -x plugin.wasm | grep -A20 "Export\[\|Import\["
```

Confirm that the exports are the hook names you meant, and that the import list
contains only host functions you were granted. An unexpected import is the usual
reason a module fails to instantiate.

## What the server runs it on

zdtd embeds [zwasm](https://github.com/clojurewasm/zwasm) v2, a WebAssembly
runtime written in Zig, so there is no C dependency and no FFI boundary in the
server. Its interpreter is the hardened default. Budgets come from the runtime
itself (`InstantiateOpts.fuel`, `max_memory_pages`), which is why the limits
above are enforcement rather than intent.

Verified on 2026-08-06 against zwasm 2.4.1 under Zig 0.16: a typed export call
returns correctly, fuel accounting reports remaining budget, and a module that
loops forever is stopped with `OutOfFuel` instead of hanging the caller.

## Not supported, on purpose

| Want | Why not |
|---|---|
| WASI | A large surface to audit for no benefit here; the import table is deliberately small |
| Filesystem or network from a plugin | Would defeat the sandbox; ask for a capability and a host function instead |
| Threads | Sim hooks are deterministic and single-threaded by design |
| Emitting raw packages | The server owns the wire; see rule 4 |
| Hot reload | Not in the first version |
