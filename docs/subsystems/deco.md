# Decoration

The decoration subsystem owns the distant props a client renders on the terrain surface: which
species a cell can spawn, where a deco chunk places them, how they reach the wire, and how a placed
prop is mirrored into the block store so collision and harvest agree with what the client draws.
`src/wire/stock_deco.zig` holds the object shape, the sampler and the package framing,
`src/world/deco_mirror.zig` expands one decoration into its multiblock cells, and
`src/server/game/deco.zig` resolves species, suppression and the mirror call.
[`src/server/game/join.zig:100`](../../src/server/game/join.zig) drives the send path at join and on
stream entry. Per [`src/wire/root.zig:1-6`](../../src/wire/root.zig) the wire package may import util,
assets, ECS component shapes and world domain types but must not import server or litenet, so the
sampler takes world facts through callbacks rather than reaching into the game.

Sources: [`src/wire/stock_deco.zig`](../../src/wire/stock_deco.zig),
[`src/world/deco_mirror.zig`](../../src/world/deco_mirror.zig),
[`src/server/game/deco.zig`](../../src/server/game/deco.zig),
[`src/server/game/join.zig`](../../src/server/game/join.zig),
[`src/world/prefabs.zig`](../../src/world/prefabs.zig),
[`src/assets/biome_layers.zig`](../../src/assets/biome_layers.zig)

## The object and its wire

One decoration on the wire is a fixed 17-byte record, not the stock `decoSize = 0x10` literal, which
the assembly declares and never reads (`src/wire/stock_deco.zig:28-33`):

```zig
pub const deco_size: usize = 17;
```

The record itself is (`src/wire/stock_deco.zig:59`):

```zig
pub const DecoObj = struct {
    x: i32,
    y: i32,
    z: i32,
    real_y: f32,
    block_raw: u32,
    state: u8 = deco_state_active,
};
```

Position is packed as three biased 16-bit coordinates through `vector3iToU64`, so the record opens
with a u64 rather than three ints (`src/wire/stock_deco.zig:51-57`). `block_raw` is the full
`BlockValue.rawData`, which carries the type plus the rotation in bits 16 to 20, the same shift the
mirror uses for its child packing, so the mirror and the client read the same rotation
(`src/wire/stock_deco.zig:35-38`).

A body is `firstPackage: bool | dataLen: i32 | count: i32 | objects`
(`src/wire/stock_deco.zig:47-49`), and the header is patched after the objects are written in place
so the count always describes exactly the bytes present (`src/wire/stock_deco.zig:80-92`):

```zig
pub fn finishDecoUpdate(buf: []u8, first_package: bool, count: usize, end: usize) ![]u8 {
```

The stock package cap is 32768 objects; zdtd caps one package at 4096 so a full body of about 68 KiB
frames inside the send buffer (`src/wire/stock_deco.zig:39-45`). The streaming writer cuts a new
package at that cap and marks only the first package `firstPackage = true`, because the client
allocates its loaded set on that flag (`src/wire/stock_deco.zig:103-146`):

```zig
pub const PackageWriter = struct {
    buf: []u8,
    cap: usize,
    count: usize = 0,
    pos: usize = objects_off,
    /// Packages already handed out by `take`.
    sent: usize = 0,
```

## Sampling a deco chunk

A deco chunk is 128 by 128 world cells and receives a fixed 1000 placement attempts; density comes
from the per-biome probabilities, not from an attempt count (`src/wire/stock_deco.zig:148-157`).
`generateForDecoChunk` mirrors the stock sampler (`src/wire/stock_deco.zig:304-311`):

```zig
pub fn generateForDecoChunk(
    out: []DecoObj,
    dcx: i32,
    dcz: i32,
    seed: u64,
    window: Window,
    sampler: Sampler,
) usize {
```

Each attempt draws a cell, draws one roll per species slot, rejects the cell when it or its 5x5
keep-out square is occupied, then walks the biome species list last to first and accepts the first
whose roll beats `prob * 0.125 * 16` (`src/wire/stock_deco.zig:318-346`,
`src/wire/stock_deco.zig:208-244`). The placement is `terrain height + 1`, skipped outside 2 to 250
(`src/wire/stock_deco.zig:353-355`). The random stream is a deterministic mixer over the world seed
and the deco chunk coordinates, so the same chunk decorates identically on every join and every
restart (`src/wire/stock_deco.zig:247-282`). Every attempt is drawn and the species rolls are taken
before the window test, so growing the view radius never moves a prop the client already saw
(`src/wire/stock_deco.zig:319-336`).

Species come from the biome under the cell, or from the subbiome when a subbiome covers it
(`src/server/game/deco.zig:43-76`). A baked world resolves the biome from the biomemap, a procedural
world from the W3 biome field, and an unreadable column returns nothing
(`src/server/game/deco.zig:46-54`). The list also gates on the `deco_trees` feature toggle and on the
presence of biome deco data, because a block id the client cannot resolve does not degrade, it throws
inside the client world-load coroutine (`src/server/game/deco.zig:22-42`).

## The mirror

The mirror expands one decoration into the cells it occupies so the block store holds what the client
renders. Cell offsets come from the block's `MultiBlockDim` (`src/server/game/deco.zig:165-174`,
`src/world/deco_mirror.zig:68-91`):

```zig
pub fn offsetsFor(dim_x: u8, dim_y: u8, dim_z: u8) Offsets {
```

A child cell keeps the parent's block value with the `ischild` bit set and the parent offsets packed
into the meta fields, negated and range-checked so an oversized multiblock is skipped rather than
mis-encoded (`src/world/deco_mirror.zig:93-111`):

```zig
pub fn childRaw(parent_raw: u32, off: Offset) ?u32 {
```

`apply` refuses to overwrite an existing multiblock anchor, writes a single-cell decoration only
into air, and for a multiblock encodes every child before writing any, so a cell that cannot be
encoded aborts the whole decoration instead of half-writing it
(`src/world/deco_mirror.zig:123-151`, `src/world/deco_mirror.zig:153-163`). The server wrapper
resolves the block id to offsets through a small cache and reports the written cell count; a
decoration with unknown dimensions is not mirrored (`src/server/game/deco.zig:145-193`):

```zig
pub fn mirrorDeco(self: *Game, cache: *DecoDimCache, o: packages.stock_deco.DecoObj) bool {
```

The mirror toggle is `[feature] deco_mirror`, on by default (`src/server/game/types.zig:274-277`).

## Suppression

The one suppression rule that removes deco from the world is the POI footprint: a cell inside a
prefab placement whose `AllowDecorations` is not true samples nothing
(`src/server/game/deco.zig:130-143`, `src/world/prefabs.zig:253-261`). The footprints are collected
lazily per deco chunk into a small direct-mapped cache and never invalidated, because prefabs are
load-fixed (`src/server/game/deco.zig:78-128`):

```zig
pub const SuppressCache = struct {
    keys: [suppress_cache_slots]i64 = @splat(0),
    filled: [suppress_cache_slots]bool = @splat(false),
    n: [suppress_cache_slots]u8 = @splat(0),
    rects: [suppress_cache_slots][max_suppress_rects]prefabs.Rect = undefined,
```

A deco chunk whose suppressing-POI count reaches the 16-rect cap counts a `saturated` event and is
reported, so partial suppression is visible rather than assumed complete
(`src/server/game/deco.zig:97-121`). A world without a prefab index, such as a flat or procedural
test world, suppresses nothing (`src/server/game/deco.zig:134-135`). Two further rules keep cells
empty rather than fabricating: a cell whose biome has no deco list places nothing, and the occupancy
keep-out rejects a draw that is too close to an accepted prop
(`src/wire/stock_deco.zig:337-347`, `src/wire/stock_deco.zig:330`).

## The chunk and join path

Decoration is delivered only during join, because the stock client's post-load deco handling differs
from its load-time handling (`src/server/game/join.zig:88-99`). `sendDecoAroundSpawn` walks every
deco chunk in the streaming window, generates its objects, mirrors each one before it is streamed,
and sends a body whenever the package fills (`src/server/game/join.zig:100-168`):

```zig
pub fn sendDecoAroundSpawn(self: *Game, c: *Client, peer: *ln_peer.Peer, wx: i32, wz: i32) !void {
```

Mirroring before the send is deliberate: the chunk payload the client is about to receive must
already contain the blocks it is told to render (`src/server/game/join.zig:153-156`). The burst is
capped at `deco_objects_per_join`, default 8192, and a final package is always sent even with zero
objects because the client needs one `firstPackage = true` to allocate and drain its set
(`src/server/game/join.zig:149-168`, `src/server/game/types.zig:160`). When deco is unavailable an
empty first package is still sent, so the client stops retrying local generation it cannot perform
on a fixed-size world (`src/server/game/join.zig:101-116`). The deco chunks the burst covered are
recorded per client so the stream path does not regenerate them
(`src/server/game/join.zig:169-182`).

A client that later streams into a new deco chunk gets that chunk's objects through
`sendDecoForStreamedChunk`, keyed against the recorded set, sent with `firstPackage = false` and
mirrored the same way (`src/server/game/join.zig:189-231`,
`src/server/game/chunk_stream.zig:354`):

```zig
pub fn sendDecoForStreamedChunk(self: *Game, c: *Client, peer: *ln_peer.Peer, cx: i32, cz: i32) !void {
```

There is no deco save file. The sampler is deterministic from the world seed and the biome data, and
mirrored decoration lands in the block store through the deco block write path, so the streamed
chunk payload carries it without a deco-specific record (`src/world/store.zig:1102-1106`).

## See also

- [`docs/subsystems/chunk-stream.md`](chunk-stream.md) - the per-peer chunk queue and the stream entry that triggers deco.
- [`docs/subsystems/map.md`](map.md) - biomes, the biomemap and the biome layer table.
- [`docs/subsystems/world-store.md`](world-store.md) - the chunk block store and the ZCH3 save channels.
- [`docs/subsystems/wire.md`](wire.md) - binary codec rules and the package registry.
- [`docs/ASSETS.md`](../ASSETS.md) - the AssignIds block id policy every deco id follows.
