# ADR 0003: No stock Harmony / IModApi host

- **Status:** accepted
- **Date:** 2026-07-22

## Context

Stock 7DTD mods expect Mono, `Assembly-CSharp`, Harmony, and `IModApi`. Workspace
and zdtd AGENTS forbid shipping game DLLs, loading `Mods/`, and papering over
server gaps with client Harmony. Sibling `7dtd-server-guard` is a stock-dedi
DLL, not a zdtd plugin.

## Decision

- zdtd **never** loads stock game assemblies, Harmony, or `Mods/` XML modlets
  as a Unity mod host.
- Stock **content** (XML, maps, TTS) is loaded as data from operator `game-dir`.
- Extension of *this* process, if any, is a **native** plugin API ([ADR 0005](0005-native-plugin-api.md),
  superseded by [0020](0020-wasm-only-plugin-api.md)), not IModApi compatibility.

## Consequences

- No mod ecosystem parity claim; operators use stock dedi + mods if they need that.
- Clean-room wire + sim remain the product.
- Anti-cheat / admin ideas from server-guard are reimplemented in Zig (TODO P4).
