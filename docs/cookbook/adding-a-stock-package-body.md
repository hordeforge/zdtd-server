# Adding a stock package body

> **Use when:** the client must be sent a stock package zdtd does not build yet.
> **Owning reference:** [wire.md](../subsystems/wire.md) for the codec and the
> builder convention, [PACKAGES.md](../wire/PACKAGES.md) for the package
> catalog and direction.
> **Standing orders:** [AGENTS.md](../../AGENTS.md) rule 14 (one stock package
> shape maps to one builder), rule 16 (RE before wire, no guessed layouts),
> rule 24 (fail closed on encode). Writing rules for this folder:
> [docs/AGENTS.md](../AGENTS.md).

One stock shape has exactly one builder. The builder writes into a caller-owned
buffer and returns the written slice; it never allocates, and it never emits a
partial body (`src/wire/packages.zig:5`):

```zig
//! Buffer contract: every `buildXxx*` takes a caller-owned `buf` and returns
//! the written slice (`![]u8`); no builder allocates. Callers size `buf` from
//! the named `*_size` / `max_*` constants and handle error.Overflow.
```

`src/wire/stock_party.zig` is the smallest complete example: a builder, a
parser, and the golden layout test that pins the field order. Copy its shape.

## 1. Confirm the shape is stock, and pin the field order

Do not invent a package. Confirm the name in the
[PACKAGES.md](../wire/PACKAGES.md) catalog table, which also gives the
direction and the stock `BinaryReader` head. The V3.2.0 row changes are in the
delta table at the top of that page.

Then read the stock `Write`/`Read` method in the IL dumps under
`../7dtd-engine-research/il/` and note the exact field order and widths. Field
order is the contract; a body that reads back correctly in zdtd proves
self-consistency, never stock compatibility. Put the RE path in the module's
`//!` header and above each non-obvious write, which is what every existing
stock module does.

## 2. Choose the module

| Domain | Module |
|---|---|
| join, motion, damage, spawn | `src/wire/packages.zig` directly |
| inventory, item, bag, equipment | `src/wire/stock_inv.zig` |
| chunk payload | `src/wire/stock_chunk.zig` |
| entity spawn, player profile, trader data | `src/wire/stock_entity.zig` |
| tile entity | `src/wire/stock_te.zig` |
| deco | `src/wire/stock_deco.zig` |
| quest, journal, NPC list | `src/wire/stock_quest.zig` |
| sign | `src/wire/stock_sign.zig` |
| party, shared kill | `src/wire/stock_party.zig` |
| progression (XP, score, stats, skill) | `src/wire/stock_xp.zig` |
| buffs | `src/wire/stock_buff.zig` |

The full mapping with representative builders is in
[wire.md](../subsystems/wire.md). Add the builder to the domain module that
already owns that shape. A new `src/wire/stock_<domain>.zig` file must be
re-exported from the facade (`src/wire/packages.zig:23`) and from the package
barrel (`src/wire/root.zig:23`); `scripts/lint-architecture.sh` fails on a
`stock_*.zig` the facade does not name.

## 3. Write the builder

The shape is: an args struct for readability, a `binary.Writer` over the caller
buffer, writes in stock `Write` order, `w.written()` at the end
(`src/wire/stock_party.zig:111`):

```zig
pub fn buildSharedKillBody(buf: []u8, args: SharedKillArgs) ![]u8 {
    var w = binary.Writer{ .buf = buf };
    try w.writeI32(args.entity_type);
    try w.writeI32(args.xp);
    try w.writeI32(args.entity_id);
    try w.writeI32(args.killer_id);
    return w.written();
}
```

Rules that come from the codec, not from style:

- Use `src/wire/binary.zig` only. Integers are little-endian two's complement
  (`src/wire/binary.zig:127`), a float is its IEEE-754 bit pattern rather than a
  converted value (`src/wire/binary.zig:158`), and a string is a 7-bit encoded
  byte length then UTF-8 bytes (`src/wire/binary.zig:168`). There is no second
  endian path.
- Keep the stock field order even when it is inconvenient. Comment it.
- Name every cap and size as a module `const`. No magic numbers on the wire.
- Add the parser next to the builder when zdtd receives the shape too, with the
  same field order and the same module.

## 4. Register the package name if it is new

Ids are dynamic and resolve through the negotiated name map, never through a
literal (`src/wire/packages.zig:290`):

```zig
pub fn idOf(name: []const u8) ?u16 {
    return id_map.get(name);
}
```

If the package name is already in `default_mappings`, nothing to do: that is
the common case, because the map is the stock catalog. If the name is new,
append it to `default_mappings` (`src/wire/packages.zig:76`) and never insert or
reorder, so the ids earlier entries advertise stay stable for fixtures. The map
is checked at compile time for duplicate names (`src/wire/packages.zig:270`),
because a duplicate silently shifts every id after it.

The mapping table is advertised to the client at join
(`src/server/game/net_handlers.zig:54`) and is also the inbound decode table
that turns a received id back into a name
(`src/server/c2s/dispatch.zig:20`). One appended entry therefore affects both
directions, and [PACKAGES.md](../wire/PACKAGES.md) records the advertised count.

If the stock package overrides `get_Channel`, add it to `channelFor`
(`src/wire/packages.zig:2514`). The channel for every advertised name is pinned
by a table test (`src/wire/packages.zig:2528`), so a missing or extra override
fails there.

## 5. Send it

Build into a caller buffer, then send by name
(`src/server/game/social.zig:263`):

```zig
    var pbuf: [256]u8 = undefined;
    const body = try packages.stock_party.buildDataBody(&pbuf, .{
```

Small bodies use a stack buffer at the call site, as above. Larger ones use the
preallocated `Game` buffers (`send_buf` at `src/server/game.zig:456`, `body_buf`
at `src/server/game.zig:457`) rather than allocating on the tick path.
`sendGame` takes the package name, not an id, so the send site never touches a
numeric id (`src/server/game/net.zig:95`). For more than one recipient use the
interest helpers in `src/server/game/net.zig` and obey the no-self-echo rule
(AGENTS rule 19).

## 6. Fail closed

If the body cannot be built correctly, omit the send. Never truncate mid-field
or zero-pad to a guessed size, because that desyncs the client's `BinaryReader`
(AGENTS rule 24). The writer already guarantees this: `ensure` returns
`Overflow` before any byte moves (`src/wire/binary.zig:113`):

```zig
    pub fn ensure(self: *Writer, n: usize) error{Overflow}!void {
        if (self.pos + n > self.buf.len) return error.Overflow;
    }
```

So the caller's job is to count the failure and skip the send, which is the
shape used for every optional S2C body (`src/server/c2s/move.zig:201`):

```zig
        const flags_body = packages.buildAliveFlagsBody(&flags_buf, f.entity_id, f.flags) catch {
            self.harness.counters.inc(.encode_errors);
            return true;
        };
```

Do the same for a missing catalog entry or an unknown domain value: omit, or
send the stock empty/error form. A body the client cannot `Read` is worse than
no body.

## 7. Golden layout test

Every builder the stock client reads gets a test that pins the exact length and
the field order. The pattern asserts the byte count first, then reads the fields
back in stock order and checks the reader is drained
(`src/wire/stock_party.zig:155`):

```zig
test "shared kill body round-trips the four stock fields" {
    var buf: [32]u8 = undefined;
    const body = try buildSharedKillBody(&buf, .{ .entity_type = 3, .xp = 90, .entity_id = 42, .killer_id = 7 });
    try std.testing.expectEqual(@as(usize, 16), body.len);
```

Put the test at the bottom of the owning file, next to the builder. Add a
second case for the variable-length branch when the stock body has one, and a
failure case that proves the buffer cap is enforced (a too-small `buf` returns
`error.Overflow` and writes nothing).

## 8. Gates

1. `zig build test`. The golden layout test runs here. Wire builders are part of
   `zig build test` because the modules are re-exported by the facade and the
   barrel.
2. `make lint`. `scripts/lint-architecture.sh` checks the facade re-exports,
   `scripts/lint-wire.sh` checks the wire heuristics, and
   `tools/check_docs.py` checks the page you edited.
3. `make check`. The full gate.

## 9. VERIFY

Two levels, both required. First the unit proof:

```bash
zig build test
```

Expect the golden layout test for the new builder to pass, including the byte
count assertion. A green suite alone proves the bytes are self-consistent, not
that the send site is reached.

Second, extend `src/server/scenarios.zig` so the shape is observed on the wire
at the advertised id. The pattern attaches a joined client whose capture records
every send, then finds the frame by id and parses the body
(`src/server/scenarios.zig:1448`):

```zig
    const ws_id = packages.idOf("NetPackageWaterSet").?;
    const b_got = cap_b.findPkgId(ws_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(cap_a.findPkgId(ws_id) == null);
```

`attachJoinedClient(&cap)` and `g.injectFramed(c, framed)` are the harness
entry points (`src/server/game/harness.zig:89`); they drive the same
`onData` path as a socket without opening one. Run `zig build test` again. The
scenario proves three things at once: the id resolves, the frame is emitted, and
the recipient set is right.

If the shape is client-visible on the join path, finish with the join smoke
named in [testing.md](../testing.md) or a stock client run with EAC off.
Unit green alone is not evidence for a wire change.

## See also

- [wire.md](../subsystems/wire.md): the codec, the framing, and the builder
  convention.
- [PACKAGES.md](../wire/PACKAGES.md): the stock package catalog, direction and
  read head for every row.
- [config.md](../subsystems/config.md): the surfaces behind the runtime
  constants the send site may read.
- [README.md](README.md): the other recipes, including the scenario recipe.
