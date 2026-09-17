# Adding a C2S handler

> **Use when:** the client sends a package zdtd does not answer yet.
> **Owning reference:** [c2s.md](../subsystems/c2s.md) for the dispatch table,
> the trust boundary and the rate limits, [AUTHORITY.md](../AUTHORITY.md) for
> who owns sim state and which gates enforce it.
> **Standing orders:** [AGENTS.md](../../AGENTS.md) rule 17 (server
> authoritative: validate, apply or reject, broadcast the result), rule 18
> (join/channel phase gates), rule 20 (bounds and caps on untrusted input).
> Writing rules for this folder: [docs/AGENTS.md](../AGENTS.md).

C2S is a request. A decoded package enters through the phase gate, is matched by
name against six domain handlers in a fixed order, and either mutates server
state and broadcasts the resulting state, or is dropped and counted. The handler
never applies a client blob blindly and never writes another player's state.

## 1. Read the owners

| File | What it owns |
|---|---|
| `src/server/c2s/dispatch.zig` | the entry point: id to name, phase gate, domain fanout |
| `src/server/c2s/move.zig` | the smallest complete domain, with ownership checks and relays |
| `src/server/c2s/inv.zig` | rate-limited handlers with parse, apply and broadcast |
| `src/server/phase_gate.zig` | the per-phase name allowlists |
| `src/server/game/rate_limits.zig` | the token buckets, the damage burst and the chat gap |
| `src/server/game/guard.zig` | the shared trust-boundary helpers and the evidence record |

A second worked example of the same shape is `src/server/c2s/blocks.zig` for
world mutation, or `src/server/c2s/quest.zig` for relays.

## 2. Pick the domain file

Find the domain that already owns the package in the table in
[c2s.md](../subsystems/c2s.md), and add an arm inside that file's `handle`.
Do not add an `if (std.mem.eql(u8, name, ...))` chain to `game.zig`: dispatch
fans out to the six domain handlers and nothing else
(`src/server/c2s/dispatch.zig:39`):

```zig
    if (try c2s_join.handle(self, c, peer, name, body)) return;
    if (try c2s_move.handle(self, c, peer, name, body)) return;
```

A name matched by an earlier domain never reaches a later one, so add the arm to
the file whose domain the package belongs to. A new domain file additionally
needs an import and a call site in `dispatch.zig` and a re-export in
`src/server/root.zig` (`src/server/root.zig:74`), or `zig build test` silently
drops its tests.

## 3. Keep the contract

Every domain handler has the same signature and the same contract
(`src/server/c2s/inv.zig:78`):

```zig
/// True when `name` belongs to this domain and was handled.
pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
```

Return `true` when the name belongs to the domain, `false` to fall through. A
`true` return does not mean the package was applied: the arm may have applied
it, rejected it, relayed it, or dropped it as a documented no-op. Every arm
returns `true` on the malformed path too, so the name stays claimed and the
packet is not re-offered to a later domain.

## 4. Phase gate

Dispatch runs the phase gate before any handler
(`src/server/c2s/dispatch.zig:27`), and the gate is a name allowlist per join
state (`src/server/phase_gate.zig:58`):

```zig
pub fn allowed(phase: Phase, name: []const u8) bool {
    return switch (phase) {
        .connecting => nameIn(connecting_allow, name),
        .joined => nameIn(joined_allow, name),
        .playing => true,
    };
}
```

Three consequences for a new arm. A play-world package needs no allowlist entry,
because `playing` admits every name and the handler still validates ownership
and bounds. A package the client legitimately sends before the join bundle
needs an entry in `joined_allow` (`src/server/phase_gate.zig:32`) with the stock
call path named in the comment. Never widen `connecting_allow`
(`src/server/phase_gate.zig:26`): only login and disconnect are legal before an
identity exists, and a pre-login peer reaching an enter or spawn handler gets a
join bundle without one. Illegal early or late packages are dropped with
`phase_rejects` and an evidence record (`src/server/c2s/dispatch.zig:28`).

## 5. Parse and validate at the trust boundary

Parse with the wire parser that owns the body, into fixed storage. On a parse
failure count the reject and return `true`; never act on a partial body
(`src/server/c2s/move.zig:26`).

Then run the checks the surface needs. The shared helpers carry most of the
policy, and using them is what feeds the guard policy as well as the counters:

- Ownership: `rejectIfNotSender` drops a claimed entity id that is not the
  sender's and records an ownership evidence event
  (`src/server/game/guard.zig:46`). A hand-written comparison plus a counter
  tells the guard nothing.
- Reach: `rejectIfBeyondEditRange` compares the acting position with the target
  and drops past `max_edit_range` (`src/server/game/guard.zig:12`).
- Quarantine: `quarantineDenies` refuses one surface for a peer the guard
  quarantined (`src/server/game/guard.zig:112`).
- Caps: every count, slot index, radius, string length and coordinate range is
  checked against a named module `const`, never an inline number. The claimed
  damage cap is the model (`src/server/game/types.zig:93`).
- Text: a client string goes through `src/server/c2s_text.zig`, which bounds and
  sanitizes it without splitting a codepoint.

Claiming the name is not a licence to trust the body. If the shape carries a
client-supplied blob the sim owns, the correct answer may be to accept and drop
it, recorded as a divergence at the arm, which is what several `misc.zig` arms
do.

## 6. Rate limit it

Four gates exist, all keyed on per-client state in `Client`
(`src/server/game/rate_limits.zig:29`):

| Gate | Use for |
|---|---|
| `takeInvToken` | inventory mutation and any package that fans a relay out |
| `takeBlockToken` | world mutation and cosmetic relays |
| `acceptChatRate` | chat bodies |
| `takeDamageToken` | damage claims |

A throttled package is not a hard failure: return `true` so the name stays
claimed and increment `c2s_throttle` (`src/server/c2s/inv.zig:86`):

```zig
        if (!self.takeInvToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
```

Take the token before the expensive work, so a flood is cheap to reject. Caps
and periods are `Game` fields bound from `[sim]`; do not hardcode a second set.

## 7. Apply, then broadcast the result

Write the change into the sim or the world store first, then send the resulting
state to the peers the stock package reaches. Blocks and tile-entity writes go
through `world.setBlockRawWorld` and the interest broadcast helpers
(`src/server/c2s/blocks.zig:377`). Three rules apply to the fanout:

- Never echo to the sender. Use `broadcastExcept` or the interest helpers, and
  assert the exclusion in the scenario (AGENTS rule 19).
- Never relay a raw client body. Re-encode from the parsed fields, or trim to
  the parsed wire length, so a peer cannot append bytes that fan out
  (`src/server/c2s/move.zig:201`).
- Broadcast the result, not the request. If the server clamps a value, peers see
  the clamped value.

If the mutation must survive a restart, write it through the world store or the
player save path (AGENTS rule 21). A green relay without persistence is not a
finished handler.

## 8. Scenario test

Extend `src/server/scenarios.zig`; do not build a second harness. Attach a
joined client whose capture records every send, inject the framed package, and
assert both the effect and the rejection path. The package is framed by name,
so the test also exercises the negotiated id (`src/server/scenarios.zig:1441`).

Assert the trust boundary explicitly by counting the reject before and after a
spoofed send (`src/server/scenarios.zig:1458`):

```zig
    const own_before = g.harness.counters.get(.ownership_rejects);
    const spoof = try packages.buildWaterSetBody(&wbuf, ca.entity_id + 999, &changes);
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageWaterSet", spoof));
    try std.testing.expect(g.harness.counters.get(.ownership_rejects) > own_before);
```

Assert the fanout with the capture, which is also how the no-self-echo rule is
pinned (`src/server/scenarios.zig:1447`):

```zig
    const ws_id = packages.idOf("NetPackageWaterSet").?;
    const b_got = cap_b.findPkgId(ws_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(cap_a.findPkgId(ws_id) == null);
```

`injectFramed` drives the real `onData` path without a socket
(`src/server/game/harness.zig:89`), so the phase gate, the parse and the
handlers all run. Give the scenario its own world directory and remove it
(`freshScenarioDir`), so a second `make check` sees the same state.

## 9. Gates

1. `zig build test`. The scenario runs here, along with the module tests of the
   domain file you edited.
2. `make lint`. `tools/check_docs.py` checks this page; the architecture lint
   checks the `root.zig` barrel and the package edges.
3. `make check`. The full gate.
4. A join smoke from [testing.md](../testing.md) when the handler is on the
   join, spawn, chunk or inventory path, which is most of them. Loadgen counts
   as automation; a stock client with EAC off is the real evidence.

## 10. VERIFY

```bash
zig build test
```

Expect the new scenario to pass, including the spoof-rejection assertion and the
capture assertion. Most scenarios print a `PASS` line when they run; confirm
yours appears (add one if it does not) rather than trusting a green exit code
alone.

Then prove the path on a live connection, because a unit suite with an injected
frame does not exercise the socket, the framing or the challenge echo:

```bash
zig build
bash scripts/smoke-navezgane.sh
```

The smoke boots the stock map and joins with loadgen bots, so a handler that
drops a legal package, kills the peer or stalls the tick shows up there. It
needs the game install and the sibling loadgen build; if either is absent, run
the flat-world equivalent from [testing.md](../testing.md) instead and say so.
If the handler is client-visible, finish with a stock client run with EAC off.

Then check the counters the handler increments on the running server
(`guardstats` on the admin console, or an `apm` dump): `phase_rejects`,
`ownership_rejects`, `bounds_rejects`, `decode_rejects` and `c2s_throttle`
should move only when the scenario says they should.

## See also

- [c2s.md](../subsystems/c2s.md): the dispatch table, the trust boundary and the
  rate limits that this recipe extends.
- [AUTHORITY.md](../AUTHORITY.md): who owns sim state and which gates enforce
  it.
- [wire.md](../subsystems/wire.md): the body parsers a handler calls.
- [README.md](README.md): the other recipes, including the stock package body
  and the scenario.
