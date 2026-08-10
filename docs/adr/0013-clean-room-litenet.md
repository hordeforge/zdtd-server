# ADR 0013: Clean-room LiteNet stack (no stock LiteNetLib runtime)

- **Status:** accepted
- **Date:** 2026-08-04

## Context

7DTD V3.x multiplayer uses **LiteNetLib**-style UDP (connect key, reliable
channels, merged packets, challenge 0xCA, package id map). Options:

1. Host or FFI the stock C# / LiteNetLib stack  
2. Embed a third-party C LiteNet clone  
3. Reimplement the wire-compatible subset in Zig from RE + goldens  

Clean-room policy forbids shipping or linking TFP/Unity assemblies as the dedi
runtime. The Zig process must speak the **client wire** with EAC off.

## Decision

1. Implement a **minimal LiteNet-compatible UDP stack** in `src/litenet/`
   (framing, peers, connect password, reliable window, merged payloads) driven
   by RE docs and loadgen/stock-client evidence, not by shipping stock DLLs.
2. Keep sockets on the **existing batched Linux UDP path** until a deliberate
   net I/O migration; do not invent a second raw net stack for ordinary
   features (AGENTS legacy note).
3. **Game packages** stay in `src/wire/`; LiteNet only moves bytes and peer
   lifecycle. Package name→id maps remain dynamic (ADR 0009).
4. Reject connecting peers that fail password/challenge rules; do not soft-accept
   broken connect frames that would desync BinaryReader.

## Consequences

- Full control of alloc/tick interaction and peer caps on the 50 ms budget.
- Protocol bugs are owned here; must track client version with goldens, not
  by upgrading a black-box DLL.
- Incomplete LiteNet features (rare channels, NAT punch beyond GSI) stay
  explicit gaps rather than accidental stock behavior.
- The stock `UnsyncedEvents=true` receive-thread design races
  `ConnectionManager.Clients` enumeration under join churn (a managed race,
  not native: research `docs/network.md` §4.0); the clean-room stack owns its
  event dispatch and avoids that class of bug by construction.

## Alternatives considered

| Option | Notes |
|---|---|
| Embed stock LiteNetLib / Mono | Violates clean-room; process model mismatch |
| Third-party C LiteNet as core | Another ABI and version surface; still need RE for game packages |
| TCP-only custom protocol | Stock client will not join without LiteNet wire |
