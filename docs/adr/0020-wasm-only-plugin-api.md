# 0020. Wasm-only plugin API

- **Status:** accepted (supersedes [0005](0005-native-plugin-api.md))
- **Date:** 2026-08-06

## Context

[ADR 0005](0005-native-plugin-api.md) chose native plugins: Zig statics first,
optional versioned dynamic libraries later, with Wasm listed as a possible guest
"after the native hook table works". The skeleton shipped that way
(`src/plugin/`: static host, `api.zig` hook table, `sample_hello`).

That ordering has two problems for a mod ecosystem:

1. **It picks the modder's language.** A native ABI means writing Zig, or C with
   a hand-matched ABI. Most people who want to extend a game server will not.
2. **A native plugin is unsandboxed.** A dynamic library shares the process
   address space, so "fail closed, one plugin fault disables that plugin" is not
   something the host can honestly promise: a bad plugin can corrupt the sim or
   the wire buffers, and there is no way to bound its syscalls.

Wasm answers both. Any language with a Wasm target produces a `.wasm`, and the
runtime, not the plugin, decides what memory and which host calls exist.

## Decision

1. **Wasm is the only plugin format.** A plugin is a `.wasm` module. There is no
   native plugin ABI, no dynamic library loading, and no in-process C# or
   Harmony.
2. **The existing static host stays as test scaffolding, not a product surface.**
   `src/plugin/` keeps its hook table and `sample_hello` so scenarios can drive
   hooks without a Wasm runtime in the test path. It is not documented as a way
   to ship a plugin and is not loaded from user configuration.
3. **The hook contract is unchanged in shape.** Plugins register for named
   events and receive views plus a `SimCommand` queue; they do not get a raw
   `*Game`, cannot inject arbitrary package bytes, and cannot skip the join state
   machine. Wasm changes the boundary, not the authority model.
4. **The boundary is the ABI.** Host functions and the module's exported hooks
   are the versioned contract. Data crosses as flat bytes in the module's linear
   memory, with the host copying in and out; no host pointers are handed to a
   guest.
5. **Determinism and fuel.** Sim hooks run on the main tick thread in documented
   order. Every guest call runs under a fuel or instruction budget and a memory
   cap, so a plugin that loops forever costs one tick's budget and is disabled,
   rather than hanging the server.
6. **Capability-gated imports.** A module gets only the host functions its
   declared capabilities allow. No filesystem, no sockets, no clock beyond the
   tick time the host passes in, unless a capability grants it.

## Consequences

### Positive

- Modders pick their own language; the deliverable is one `.wasm` file.
- A faulty or hostile plugin is bounded by the runtime rather than by hope.
- The capability list becomes the security review surface, in one place.
- No ABI-versioning treadmill against a native struct layout.

### Negative / costs

- A Wasm runtime is a real dependency and a real amount of work; until it lands
  there is no shipping plugin story at all, only the in-tree test scaffolding.
- Crossing the boundary costs a copy, so hot per-entity hooks need care or need
  to stay out of the plugin surface.
- Debugging a guest is worse than debugging native code.

## Alternatives considered

| Option | Why not |
|---|---|
| Native dynlib (ADR 0005 path) | Picks the modder's language and cannot be sandboxed |
| Lua or another embedded script VM | Also picks the language, and pulls in a second runtime with weaker isolation |
| Both native and Wasm | Two boundaries to secure and version, for one ecosystem; the native one would win by being easier and undo the isolation goal |
| No plugins | The hooks already exist for guard, admin and analytics; refusing an extension story pushes people back to a mod stack we do not want to host |

## Follow-up

Runtime selection is closed: **zwasm v2**, verified under Zig 0.16 on
2026-08-06, including that a module which loops forever is stopped with
`error.OutOfFuel`. WASI is not used. Both are recorded with their evidence in
[PLUGIN_API.md](../PLUGIN_API.md).

T9 landed 2026-08-06: `src/plugin/wasm.zig` loads `[plugin] modules` from
zdtd.toml at init (zwasm v2 runtime, no WASI), registers the host import table
(`zdtd_log` / `zdtd_tick` / `zdtd_queue`), and runs every hook under fuel and
memory budgets (a looping module is disabled within one tick). The T15 event
hooks (on_player_death / on_entity_killed / on_block_damage / on_quest_complete)
and the admin/chat/login seams shipped 2026-08-07. Plugin authors write against
[PLUGIN_DEV.md](../PLUGIN_DEV.md).
