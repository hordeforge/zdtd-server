# Chunk streaming

This subsystem owns the server side of terrain delivery to one client: the per-peer set of chunk keys the client already holds, the per-tick budget that bounds how many stock `NetPackageChunk` bodies go out, the join-time spawn-area burst and its paced drain, and the tile-entity and decoration follow-ups that ride a newly streamed chunk. It does not own chunk storage or materialization (`src/world/store.zig`, `World.getOrCreate` at `src/world/store.zig:859`), the stock body layout (`src/wire/stock_chunk.zig`), the reliable-window retry pump (`src/server/game/net.zig:183`), or per-block edit replication, which travels as `NetPackageSetBlock` from the block-mutation paths (for example `src/server/game/chunk_fill.zig:891`). The code lives in the `server` package, whose facade declares it top of the stack and able to import every other package (`src/server/root.zig:1-7`); the reverse edges, such as `world` importing `wire` or `server`, are forbidden by the architecture lint listed in `AGENTS.md`, so this subsystem is importable only from `server` code and from tests and scenarios.

Sources: [`src/server/game/chunk_stream.zig`](../../src/server/game/chunk_stream.zig), [`src/server/game/chunk_fill.zig`](../../src/server/game/chunk_fill.zig), [`src/wire/stock_chunk.zig`](../../src/wire/stock_chunk.zig), [`src/world/store.zig`](../../src/world/store.zig), [`src/server/game/deco.zig`](../../src/server/game/deco.zig).

## Ownership and wiring

`Game` holds thin forwarders so the entry points stay visible from `game.zig` (`sendSpawnChunk` at `src/server/game.zig:3929`, `sendContainersInChunk` at `src/server/game.zig:3975`, `sendSpawnArea` at `src/server/game.zig:3979`, `drainSpawnArea` at `src/server/game.zig:3986`, `streamChunksForClient` at `src/server/game.zig:3993`). The bodies live in `game/chunk_stream.zig` and `game/chunk_fill.zig`.

The driver is `replicate`, once per tick (`src/server/game/replicate.zig:20`). It first drains every peer's pending spawn area against one shared budget (`src/server/game/replicate.zig:32-46`), then, on the `chunk_stream_period_ticks` gate and only for peers that are `entered` or `world_ready`, runs the view stream per client (`src/server/game/replicate.zig:47-61`). That whole pass is the `.replicate` apm section; the stream adds `.chunk_stream` (`src/server/game/chunk_stream.zig:261`), chunk generation `.chunk_gen` (`src/server/game/chunk_fill.zig:45`), the TE scan `.te_scan` (`src/server/game/chunk_fill.zig:273`), and the drain `.join_drain` (`src/server/game/chunk_stream.zig:221`).

Join calls `sendSpawnArea` from two C2S phases, `WorldInitInfoRequest` (`src/server/c2s/join.zig:436`) and `RequestToSpawnPlayer` (`src/server/c2s/join.zig:563`), plus the death-respawn path (`src/server/game.zig:2992`). The call is idempotent across them: a second call with the same center keeps the drain's ring progress instead of restarting it (`src/server/game/chunk_stream.zig:198-208`).

## The per-peer stream queue

The queue is a flat membership array plus a count, sized by a compile-time cap, with the spawn-area drain cursor and a once-only capacity warning as the rest of the per-client stream state.

The streamed set and view radius (`src/server/game/types.zig:628-633`):

```zig
    view_radius: i32 = default_view_radius,
    name: [32]u8 = .{0} ** 32,
    name_len: usize = 0,
    /// Chunk keys currently known streamed to this client (WorldChunkCache keys).
    streamed: [max_streamed_chunks_cap]i64 = undefined,
    streamed_n: usize = 0,
```

The drain cursor (`src/server/game/types.zig:617-621`):

```zig
    pending_area_r: i32 = -1,
    pending_area_cx: i32 = 0,
    pending_area_cz: i32 = 0,
    pending_area_ring: i32 = 0,
    pending_area_idx: u32 = 0,
```

The warning latch (`src/server/game/types.zig:693`):

```zig
    stream_cap_warned: bool = false,
```

`clientAddStreamed` is the only writer (`src/server/game/chunk_stream.zig:95-113`):

```zig
pub fn clientAddStreamed(self: *Game, c: *Client, key: i64) void {
    if (clientHasStreamed(c, key)) return;
    if (c.streamed_n >= max_streamed_chunks_cap) {
        // drop oldest (FIFO shift; order only matters for this policy)
        var i: usize = 1;
        while (i < c.streamed_n) : (i += 1) c.streamed[i - 1] = c.streamed[i];
        c.streamed_n -= 1;
    }
    c.streamed[c.streamed_n] = key;
    c.streamed_n += 1;
    const warn_at = @max(@as(usize, 1), (self.max_streamed_chunks * 4) / 5);
    if (!c.stream_cap_warned and c.streamed_n >= warn_at) {
        c.stream_cap_warned = true;
        std.debug.print(
            "peer {d} stream queue near capacity n={d}/{d} (warn>={d})\n",
            .{ c.slot, c.streamed_n, self.max_streamed_chunks, warn_at },
        );
    }
}
```

Three properties matter for anyone changing this file. Membership is a linear scan (`clientHasStreamed`, `src/server/game/chunk_stream.zig:87-93`), so both the add and remove paths are O(streamed_n). Removal is a swap-remove that ignores order (`clientRemoveStreamed`, `src/server/game/chunk_stream.zig:115-124`), and the removal loop deliberately does not advance its index after a swap (`src/server/game/chunk_stream.zig:318-319`). The array is a dedupe set, not a work queue: a key is recorded only after its send is confirmed (`src/server/game/chunk_stream.zig:344`), so a chunk that failed to send is retried on the next pass instead of leaving a permanent hole, which is why `sendSpawnChunk` returns a boolean rather than an error on a full window (`src/server/game.zig:3921-3928`). For the add pass the same membership is mirrored into `std.StaticBitSet(640)` (`src/server/game/chunk_stream.zig:282`), so the raster scan probes a bit instead of scanning the array per cell; the bit is set on add (`src/server/game/chunk_stream.zig:345`) and the array is still probed as a backstop (`src/server/game/chunk_stream.zig:338`).

## Caps and constants

The defaults live in `src/server/game/types.zig:61-67`:

```zig
pub const max_streamed_chunks_cap: usize = zdtd_config.max_streamed_chunks_cap;

/// Default stream/authority values (also InitOptions / Game field defaults).
pub const default_max_streamed_chunks: usize = max_streamed_chunks_cap;
pub const default_chunk_stream_radius_min: i32 = 7;
pub const default_chunk_stream_radius_max: i32 = 12;
pub const default_chunk_adds_per_stream_tick: u32 = 8;
```

Further named constants: `default_chunk_stream_period_ticks = 5` (`src/server/game/types.zig:79`), `default_spawn_area_radius_max = 8` (`src/server/game/types.zig:92`), `default_view_radius = 7` (`src/server/game/types.zig:177`), `default_te_scan_block_cap = 32` and `default_te_scan_te_cap = 48` (`src/server/game/types.zig:43-44`). The join ACK yield is `join_ack_yield_ns = 500_000` (`src/server/game/chunk_stream.zig:32`). The compile cap is `max_streamed_chunks_cap = 625` (`src/server/zdtd_config.zig:486`), a 25x25 square sized for the stock client's view distance 12 request.

The per-instance values are `Game` fields filled from `zdtd.toml` (`src/server/game.zig:715-719`):

```zig
    max_streamed_chunks: usize = default_max_streamed_chunks,
    chunk_stream_radius_min: i32 = default_chunk_stream_radius_min,
    chunk_stream_radius_max: i32 = default_chunk_stream_radius_max,
    chunk_adds_per_stream_tick: u32 = default_chunk_adds_per_stream_tick,
    chunk_stream_period_ticks: u64 = default_chunk_stream_period_ticks,
```

`sanitizeInitOptions` owns the clamps (`src/server/zdtd_config.zig:490-541`): `max_streamed_chunks` is raised to 1 and lowered to 625; both stream radii are clamped to `max_radius_for_budget`, the largest radius whose `(2r+1)^2` fits `max_streamed_chunks` (`src/server/zdtd_config.zig:502-526`); a zero adds-per-tick, stream period or spawn radius becomes 1. Two docs are stale against this code and should be read as gaps, not specification: `docs/GAME_OPTIONS.md:163` still says the compile cap is 169, and `docs/wire/WIRE_CHUNK.md:105` still describes the topsoil bitfield as all `0xFF`, while the encoder now writes the chunk's real bitfield (`src/wire/stock_chunk.zig:590`).

## What triggers a send

Four triggers exist. The join burst runs `sendSpawnArea` synchronously for the collision-mesh core, the spawn chunk plus its 8 neighbours, so the client can mesh the area before `World.IsPositionAvailable` succeeds (`src/server/game/chunk_stream.zig:153-193`). The paced spawn drain continues the outer rings of the same area from the cursor at `chunk_adds_per_stream_tick` per tick, shared across clients. The per-tick view walk runs for an entered client whose ECS player slot resolves, adding any chunk inside the budget square that the client does not hold and removing any key outside it (`src/server/game/chunk_stream.zig:260-356`); this is what follows the player as they move.

A client request steers it only indirectly: `NetPackageRequestToSpawnPlayer.chunkViewDim` sets `c.view_radius`, clamped to `max_spawn_chunk_view_dim = 8` (`src/server/c2s/join.zig:31`, `src/server/c2s/join.zig:441-450`), and the next view pass then covers a different square. No C2S package asks for one named chunk: no handler in `src/server/c2s/` matches a chunk-request package. The second join-phase package that touches streaming state is `WorldInitInfoRequest` (`src/server/c2s/join.zig:384`), which marks the client's chunk cache ready; `RequestToSpawnPlayer` also calls `sendSpawnArea` directly (`src/server/c2s/join.zig:561-564`).

A block edit is not a trigger. An already-streamed chunk is never re-encoded for that client: the only call to `clientRemoveStreamed` is the view-square removal (`src/server/game/chunk_stream.zig:318`), and edits instead broadcast `NetPackageSetBlock` (`src/server/game/chunk_fill.zig:891-892`). A client that misses a `SetBlock` for a chunk it still holds has no resend path until that chunk leaves and re-enters the view square.

## The per-tick view pass

The radius is derived per pass from the client's own `view_radius`, clamped to the configured band, then shrunk until the square fits `max_streamed_chunks` (`src/server/game/chunk_stream.zig:270-274`):

```zig
        var r: i32 = @min(@max(c.view_radius, self.chunk_stream_radius_min), self.chunk_stream_radius_max);
        // Shrink to a square that fits the budget: truncating the raster scan
        // instead would leave a southern band, not the centered hole-free disk
        // the comment above requires (radius 7 wants 225 vs a 169 cap).
        while (r > 1 and @as(usize, @intCast((2 * r + 1) * (2 * r + 1))) > self.max_streamed_chunks) r -= 1;
```

Removals run first: every streamed key outside the square gets `NetPackageChunkRemove` (body `chunkKey: i64`, `src/wire/packages.zig:4175-4179`), the key is dropped from the set, and, only when `deco_trees` is off, a `NetPackageDecoResetWorldChunk` follows (`src/server/game/chunk_stream.zig:305-318`). The gate is deliberate: with join-time deco objects live, the reset would run `RestoreGeneratedDecos` over terrain deco the server can never resend (`src/server/game/chunk_stream.zig:308-317`).

Adds run as a row-major raster inside the square, skipping bits already set, charging the budget per attempt and stopping the pass on a refused send (`src/server/game/chunk_stream.zig:331-343`):

```zig
                if (added >= self.chunk_adds_per_stream_tick) break :outer;
                const bit: usize = @intCast((dx + r) + (dz + r) * side);
                if (bit < 640 and in_view.isSet(bit)) continue;
                const cx = tcx + dx;
                const cz = tcz + dz;
                const key = packages.makeChunkKey(cx, cz);
                // Cap path / race: bitset miss but list still holds key.
                if (clientHasStreamed(c, key)) continue;
                // Charge the per-pass budget per ATTEMPT (see drainSpawnArea):
                // a refused send already paid worldgen + encode, and scanning
                // on past it let one wedged peer walk the whole view square.
                added += 1;
                if (!try self.sendSpawnChunk(peer, cx, cz)) break :outer;
```

Budget accounting is the load-bearing detail. The view pass allows at most `chunk_adds_per_stream_tick` attempts per client per pass, and the spawn drain shares a single budget of the same size across all clients in a tick (`src/server/game/replicate.zig:32-45`). Both charge per attempt, not per delivery, because a refused send has already paid world generation and encode (`src/server/game/chunk_stream.zig:239-247`). The work bound is therefore `chunk_adds_per_stream_tick` chunk generations per tick for the whole server, not per peer.

The drop policy is "leave the key unrecorded". `sendSpawnChunk` builds the body into `Game.body_buf`, sends, and compares the `.net_packets_out` counter before and after; when the counter did not move, the chunk was not delivered and the call returns false (`src/server/game/chunk_fill.zig:180-190`). Under the hood `NetPackageChunk` is in the droppable set (`src/server/game/net.zig:66-93`), so a full reliable window is counted as `reliable_window_drops` and swallowed rather than propagated (`src/server/game/net.zig:162-171`). It is also a compressed package (`src/server/game/net.zig:51-59`) and gets a much larger retry budget than other droppable packages: 4000 attempts instead of 64 (`src/server/game/net.zig:148-153`), each attempt pumping the fragment window and polling the socket (`src/server/game/net.zig:183-211`). Several chunks in a row can therefore sit inside one tick's send call, and the ACK yields in the join paths exist to keep that window draining (`src/server/game/chunk_stream.zig:185-190`, `src/server/game/chunk_stream.zig:248-253`).

## The spawn-area burst and paced drain

`sendSpawnArea` clamps the requested radius to `spawn_area_radius_max` (`src/server/game/chunk_stream.zig:144-145`) and defines the synchronous core as rings 0 and 1 (`src/server/game/chunk_stream.zig:160`). Ring 0 sends the spawn chunk; each outer core ring walks its perimeter through `ringCell`, which enumerates the `(2r+1)^2` square center-out, `8r` cells per ring (`src/server/game/chunk_stream.zig:126-140`, `src/server/game/chunk_stream.zig:161-193`). After each core chunk the path polls the socket and sleeps `join_ack_yield_ns` (`src/server/game/chunk_stream.zig:189-190`), a one-time join cost, never part of the per-tick stream (`src/server/game/chunk_stream.zig:23-32`).

The drain then continues the remaining rings from the cursor (`src/server/game/chunk_stream.zig:218-255`), reusing `ringCell`, skipping held keys, charging the shared budget per attempt and returning on the first refusal so the rest retries next tick (`src/server/game/chunk_stream.zig:240-247`). It is a no-op when `pending_area_r < 0` (`src/server/game/chunk_stream.zig:220`) and marks the area complete by setting that field back to -1 (`src/server/game/chunk_stream.zig:225-228`). Overlap with the view stream is harmless because both paths dedupe through the same key set (`src/server/game/chunk_stream.zig:214-217`).

## Building and reusing a chunk body

One send does four things before it encodes (`src/server/game/chunk_fill.zig:40-179`): materialize the chunk under the `.chunk_gen` scope, run the once-per-chunk storage scan, rebuild the power grid, and resolve the chunk's dominant biome, caching it on the chunk so later sends to other clients skip the lookup (`src/server/game/chunk_fill.zig:44-74`). The once-per-session flags that make this reuse safe are runtime-only and live on the stored chunk (`src/world/store.zig:136-144`):

```zig
    dirty: bool = false,
    /// Runtime-only: server finished its one-time storage-TE scan of this chunk.
    te_scanned: bool = false,
    /// Power nodes re-derived from this chunk's blocks after a restart (GAP
    /// power persistence); the grid is runtime state rebuilt on first touch.
    power_scanned: bool = false,
```

```zig
    /// Runtime-only: dominant biome, computed once per resident chunk (the
    /// biome map is static). Recomputing costs 256 map lookups per chunk send.
    biome_id: ?u8 = null,
```

The TE scan is bounded and can be truncated by `te_scan_block_cap` / `te_scan_te_cap`; `te_scanned` is written only when the prefab TE walk completed under the cap, so a truncated scan retries on the next send (`src/server/game/chunk_fill.zig:318`, `src/server/game/chunk_fill.zig:401-410`). A clean procedural chunk skips the 65536-cell walk entirely (`src/server/game/chunk_fill.zig:260-269`). `scanChunkPower` re-fetches the chunk by position and guards on `power_scanned`, because the storage scan can re-enter the chunk store and move the map (`src/server/game/chunk_fill.zig:205-214`).

Encoding goes through `packages.stock_chunk.buildNetPackageChunkNew` into `Game.body_buf` (`src/server/game/chunk_fill.zig:130`). `body_buf` is 512 KiB (`src/server/game.zig:457`) and the encode reuses one raw-plane scratch buffer per `Game` (`chunk_raws`, 65536 u32, `src/server/game.zig:461`). That scratch is the build-once reuse inside a single send: the dense per-cell `BlockValue` plane is materialized once and the block-layer loop, the density channel and the water channel all read it, instead of re-invoking the per-cell callback three times (`src/wire/stock_chunk.zig:487-509`, `src/wire/stock_chunk.zig:643-656`). The knob is explicit in the option struct (`src/wire/stock_chunk.zig:104-108`):

```zig
    raws: ?*const [65536]u32 = null,
    /// Caller-owned scratch for `raws` (pre-allocated; no hot-path heap). Used
    /// only when `raws` is null. Null disables the memoization: channels fall
    /// back to the block_at callback.
    raws_scratch: ?*[65536]u32 = null,
```

The envelope is a five-byte prefix around the network-mode `Chunk.write` payload (`src/wire/stock_chunk.zig:852-867`), with `bOverwriteExisting = false` so the client allocates and `Chunk.read`s during package read (`src/wire/stock_chunk.zig:850-851`). The payload's own entity count and tile entity count are zero (`src/wire/stock_chunk.zig:661-664`); tile entities travel as separate `NetPackageTileEntity` bodies from `sendContainersInChunk`, which `sendSpawnChunk` calls after a delivery is confirmed (`src/server/game/chunk_fill.zig:188-190`). That scan walks the container, sign, vending, light and workstation stores and sends every entry whose position falls in the 16x16 column, with workstations gated on known geometry (`src/server/game/chunk_stream.zig:37-85`, `src/server/game/replicate_te.zig:105-110`). The decoration follow-up for a newly streamed chunk is `game_join.sendDecoForStreamedChunk`, tracked per 128-block deco chunk (`src/server/game/chunk_stream.zig:346-353`, `src/server/game/join.zig:195-231`).

Two costs are worth naming. The body is rebuilt per recipient, because `sendSpawnChunk` takes one peer and encodes again for the next one; what is shared across peers is the chunk's planes and the cached scan/cursor flags, not the encoded bytes. Encode failure is fail-closed: an error from the builder propagates, and a delivery whose counter did not move returns false so the key is never recorded (`src/server/game/chunk_fill.zig:184-187`).

Persistence: nothing in this subsystem survives a restart. The `streamed` set, `streamed_n`, `pending_area_*`, `te_scanned`, `power_scanned` and `biome_id` are per-session runtime state (`src/server/game/types.zig:617-633`, `src/world/store.zig:136-144`). The terrain, paint, density and damage planes persist through the world store's ZCH3 writer, and containers and workstations persist in their own stores, per `docs/wire/WIRE_CHUNK.md:76-97`. Stock fidelity boundary: the encoder implements the network-mode `Chunk.write` layout, and the live path is a stock client that meshes these chunks, but full bit-diff goldens against a stock dedicated capture are still open (`docs/wire/WIRE_CHUNK.md:22-24`), so a green zdtd-to-zdtd round trip is not evidence of stock compatibility.

## See also

- [`world-store.md`](world-store.md)
- [`wire.md`](wire.md)
- [`interest.md`](interest.md)
- [`../wire/WIRE_CHUNK.md`](../wire/WIRE_CHUNK.md)
- [`../ARCHITECTURE.md`](../ARCHITECTURE.md)
