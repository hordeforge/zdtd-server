# Structural stability

The stability subsystem owns the support value of every placed block and decides which blocks fall
when that value reaches zero. `src/world/stability.zig` holds the plane representation, the support
distribution and the removal relaxation; the caller supplies per-block facts through a function
pointer, so the module never touches the XML tables itself. The server side lives in
`src/server/game/stability.zig`, which resolves those facts from the max damage table and converts a
lost cell into an air block plus a falling-block entity. Per
[`src/world/root.zig:1-6`](../../src/world/root.zig) the world package may import util and assets and
must not import wire, server or litenet, which is why the collapse broadcast is built outside the
module. Block storage and the chunk save format are owned by the world store page.

Sources: [`src/world/stability.zig`](../../src/world/stability.zig),
[`src/server/game/stability.zig`](../../src/server/game/stability.zig),
[`src/world/store.zig`](../../src/world/store.zig),
[`src/server/c2s/blocks.zig`](../../src/server/c2s/blocks.zig),
[`src/ecs/systems.zig`](../../src/ecs/systems.zig)

## The plane

Each chunk carries a lazily allocated byte plane, one value per block cell, parallel to the block
id plane (`src/world/store.zig:132-135`). The scale is stock's grid (`src/world/stability.zig:31-40`):

```zig
pub const stability_full: u8 = 15;
/// Cap on one removal relaxation: cells visited beyond this are dropped
/// (stock physicsIsolation stops at 1000 per run; we give the whole removal
/// a larger budget so a big structure still collapses in one pass).
pub const max_relax_cells: usize = 8192;
/// Cap on the caller-provided fallen output per removal pass.
pub const max_fallen: usize = 4096;
```

Fifteen is a fully supported block, one is a supported block that cannot itself carry support, and
zero means the cell has none. The plane is not stored in the chunk save: `ZCH3` persists heights
plus the optional raw block, texture, density and damage channels, so support is recomputed on first
touch after a load rather than saved (`src/world/store.zig:1-4`). The plane is freed when the chunk
is released, and `ensureStability` reallocates it on demand (`src/world/store.zig:198-202`,
`src/world/store.zig:261-266`).

The module stays table-agnostic through a caller-supplied probe (`src/world/stability.zig:44-51`):

```zig
pub const Facts = struct {
    support: bool,
    ignore: bool,
};
```

The server resolves those two flags by block name through the max damage table; an unknown id is
treated as supporting and not ignored (`src/server/game/stability.zig:11-18`).

## Support computation

`ensureComputed` is the lazy first pass: it seeds every solid cell to fifteen when it supports and
one when it does not, skips ignored blocks, then distributes (`src/world/stability.zig:83-104`):

```zig
pub fn ensureComputed(w: *store.World, c: *store.Chunk, allocator: std.mem.Allocator, fctx: ?*anyopaque, facts: FactsFn) !void {
```

```zig
pub fn distribute(w: *store.World, c: *store.Chunk, fctx: ?*anyopaque, facts: FactsFn) void {
```

Distribution spreads from every cell whose value is above one. Horizontal spread decays one per
step, caps a non-support cell at one, and crosses chunk borders by resolving the neighbour chunk,
so a wall anchored in one chunk supports a floor in the next (`src/world/stability.zig:122-138`).
A cell that is air, water or stability-ignoring is skipped, and the spread never enters a chunk
whose plane has not been computed, because an uncomputed chunk reads zero everywhere and the value
check could not stop the recursion (`src/world/stability.zig:140-160`). Vertical spread keeps the
value going up and decays one per block going down (`src/world/stability.zig:161-165`).

Recomputation of one cell is stock's channel calculation: take the maximum stability over the six
neighbours that are stability-support blocks, separately remember the value from directly below, and
use the maximum unchanged when it came from below versus maximum minus one otherwise, floored at
zero; a non-support block is then capped at one (`src/world/stability.zig:205-236`). A neighbour
counts as support for a falling check when it holds any solid, non-water block with stability above
one (`src/world/stability.zig:238-253`).

## Placement and removal

`removeBlockAt` assumes the caller has already written air and recomputes the region
(`src/world/stability.zig:255-270`):

```zig
pub fn removeBlockAt(
    w: *store.World,
    x: i32,
    y: i32,
    z: i32,
    allocator: std.mem.Allocator,
    fctx: ?*anyopaque,
    facts: FactsFn,
    fallen: []Pos,
) usize {
```

Its walk zeroes each cell as it enters, reports the dependency chain as fallen, and treats a
stability-one non-support neighbour as falling too unless some other neighbour still supports it
(`src/world/stability.zig:292-347`). The value that chain follows is one less than the level above
it, or equal to it for a step upward, which is what expresses a column carrying load through
itself (`src/world/stability.zig:350-365`). After the chain is consumed, the affected neighbours are
relaxed to a fixpoint, and a lowered cell propagates to its own neighbours so a second-order loss is
not missed (`src/world/stability.zig:369-413`). The walk uses fixed stack arrays, so a removal never
allocates, and it stops at the named caps rather than growing (`src/world/stability.zig:280-290`,
`src/world/stability.zig:324`).

`placeBlockAt` is the mirror and the cheap path (`src/world/stability.zig:417-438`):

```zig
pub fn placeBlockAt(
    w: *store.World,
    x: i32,
    y: i32,
    z: i32,
    allocator: std.mem.Allocator,
    fctx: ?*anyopaque,
    facts: FactsFn,
) void {
```

It recomputes the placed cell, writes the value only when it rose, and spreads horizontally only
when the cell is above one, so a placement is local unless it genuinely adds support.

## Collapse behaviour

The server wrapper is `stabilityAfterSetBlock` (`src/server/game/stability.zig:24`):

```zig
pub fn stabilityAfterSetBlock(self: *Game, x: i32, y: i32, z: i32, old_id: u16, new_id: u16) usize {
```

A removal runs the relaxation and then, for each collapsed cell, snapshots the raw block value
before clearing, drops the block health, the claim and the raw entry, and routes the removal through
the one helper that owns bedroll, power, container and vending consequences
(`src/server/game/stability.zig:45-60`). A placement runs `placeBlockAt`
(`src/server/game/stability.zig:85-87`). The caller already wrote the new block, so the module never
writes the block id plane itself.

Collapse is bounded. The relaxation is capped at 8192 visited cells and the fallen output at 4096
positions, and the entity spawn stops at the 32-cell falling group cap
(`src/world/stability.zig:35-40`, `src/server/game/stability.zig:45-48`). A cell becomes a falling
entity only when the block declares a model on fall; otherwise it is simply gone
(`src/server/game/stability.zig:76-83`). The entities themselves are ECS kind `falling_block`, ticked
by their own schedule phase gated on the `falling` rule, which is why turning that rule off while
SetBlock collapses continue lets fallers accumulate (`src/ecs/rules.zig:41-46`,
`src/ecs/schedule.zig:106`, `src/ecs/systems.zig:3094`).

## When it runs

Stability runs on the block edit, not on a timer. The C2S block handler calls the wrapper only when
the block type actually changed, after the world write and the tile entity bookkeeping
(`src/server/c2s/blocks.zig:377-394`). There is no periodic stability pass in the tick; the only
recurring stability-shaped name in the tick path is `bloodMoonDayFor`, which is a clock helper that
happens to live in the same file (`src/server/game/step.zig:234`). A chunk loaded from disk gets its
plane on the first edit that touches it, because `removeBlockAt` and `placeBlockAt` both call
`ensureComputed` before reading the plane.

## What the client is told

The client is told about the result, never about the support value. Each collapsed cell is broadcast
as a `NetPackageSetBlock` whose raw value is zero, meaning air, with the damage fields set to no
damage and no owner (`src/server/game/stability.zig:63-74`). The stability module has no wire import
by construction (`src/world/root.zig:1-6`), so the support byte cannot be sent; a client that
predicts support differently is corrected by the block update. Falling entities reach clients
through the ordinary entity spawn and interest path, so their visibility rules belong to the
interest page. Their sim kind is `falling_block` (`src/ecs/components.zig:15`).

## See also

- [`docs/subsystems/world-store.md`](world-store.md) - chunk storage, the ZCH3 save channels and the block write path.
- [`docs/subsystems/ecs.md`](ecs.md) - the falling-block entity kind and the systems schedule.
- [`docs/subsystems/wire.md`](wire.md) - the SetBlock body layout.
- [`docs/subsystems/c2s.md`](c2s.md) - the block edit handler, its rate gate and its trust checks.
- [`docs/DIVERGENCES.md`](../DIVERGENCES.md) - the removal budget and the collapse caps.
