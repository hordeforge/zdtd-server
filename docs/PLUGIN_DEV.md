# Writing a zdtd plugin

**Status:** the contract below is designed and the runtime is verified, but the
host wiring is not shipped yet (WORK_PLAN T9). Nothing user-supplied loads today.
This document is written so a plugin author can start from it the day it lands,
and so the contract is reviewable before it is frozen.

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
  imports:  log            ────>  provided by the host, capability-gated
            ...
```

Export only the hooks you need. A missing export means that hook is not
registered, and costs nothing at runtime.

## Rules you cannot get around

These are enforced by the runtime, not by convention.

1. **You get a fuel budget per call.** Every call runs under an instruction
   budget. Exhaust it and the call ends with `OutOfFuel`, your plugin is
   disabled, and the server logs which hook and module. An infinite loop costs
   one tick's budget, not the server. This is verified, not aspirational.
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

## Data across the boundary

Everything crosses as flat bytes in your module's linear memory. The host copies
in and copies out; you never receive a host pointer, and the host never follows
one of yours beyond the length you declare.

The practical consequence: a hook that hands you a structure hands you an offset
and a length into your own memory. Read it, copy what you need, and do not retain
the offset past the call.

## Hooks

| Export | When | Notes |
|---|---|---|
| `on_enable` | once, at enable | Register interest, read config, allocate |
| `on_tick` | late in each tick, after sim and replicate | Keep it cheap; it runs 20 times a second |
| `on_player_join` | a player's first join | Receives the peer slot and entity id |
| `on_shutdown` | once, at shutdown | Flush anything you own |

`on_tick` running at 20 Hz is the one to respect. A hook that burns its budget
every tick will be disabled, which is the system working, but your plugin still
stops.

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
