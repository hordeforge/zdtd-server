# World store: chunks, tile entities, flush

The world store owns the authoritative block world as resident 16x256x16 chunks, the world-position-keyed tile-entity tables (containers, signs, vending machines, lights, workstations), the `dirty` tracking that decides what reaches disk, the ZCH3 per-chunk file format, and the flush path that writes those files. It does not own the wire encoders: `src/world/` may import `util` and `assets` and the pure ECS component shape `InvSlot`, and must not import `wire`, `server` or `litenet` (`src/world/root.zig:3-6`, enforced by `scripts/lint-architecture.sh:50`). The importers are `server` (which owns `Game` and the tick) and `wire`, which re-exports the TE domain types and builds the stock TileEntity network bodies at send time (`src/world/root.zig:5`). The on-disk `.zch` overlay is a zdtd-owned format, not a stock Unity region binary (ADR 0011).

Sources: [`src/world/store.zig`](../../src/world/store.zig), [`src/world/chunk_flush.zig`](../../src/world/chunk_flush.zig), [`src/world/containers.zig`](../../src/world/containers.zig), [`src/world/signs.zig`](../../src/world/signs.zig), [`src/world/vending.zig`](../../src/world/vending.zig), [`src/world/light_te.zig`](../../src/world/light_te.zig), [`src/world/workstations.zig`](../../src/world/workstations.zig), [`src/world/stability.zig`](../../src/world/stability.zig), [`src/world/deco_mirror.zig`](../../src/world/deco_mirror.zig), [`src/world/terrain_snapshot.zig`](../../src/world/terrain_snapshot.zig)

## Chunk record and residency

A chunk is 16 blocks on X and Z and 256 on Y (`src/world/store.zig:37-39`), 65536 cells (`blocks_per_chunk`, `src/world/store.zig:53`). Every plane is addressed by `lx + lz * 16 + y * 256` (`Chunk.blockIndex`, `src/world/store.zig:158-161`). The block, texture, density, damage and stability planes are all optional slices allocated lazily on first write; a chunk that was only streamed never allocates them (`src/world/store.zig:121-135`).

The chunk record (`src/world/store.zig:100`, with doc comments and unrelated neighbours trimmed):

```zig
pub const Chunk = struct {
    pos: ChunkPos,
    y_dim: u32 = 256,
    terrain: ?*const TerrainIds = null,
    heights: [256]u8 = .{sea_level} ** 256,
    topsoil: [32]u8 = [_]u8{0} ** 32,
    blocks: ?[]u32 = null,
    textures: ?[]u64 = null,
    densities: ?[]u8 = null,
    dens_set: ?[]u8 = null, // bitset: 1 = densities[i] is valid TTS paint
    damages: ?[]u16 = null,
    stability: ?[]u8 = null,
    dirty: bool = false,
    te_scanned: bool = false,
    power_scanned: bool = false,
    biome_id: ?u8 = null,
    last_touch: u64 = 0,
    allocator: ?std.mem.Allocator = null,
```

`terrain` points at `World.terrain_ids`, so the heightmap fallback in `rawAt` synthesizes live AssignIds terrain rather than module pins (`src/world/store.zig:408-418`). `topsoil` is the stock `m_bTopSoilBroken` bitfield, one bit per XZ column (`src/world/store.zig:112-119`); it is set, never cleared, by `setTopSoilBroken` (`src/world/store.zig:307-311`) including the 1-wide neighbour-chunk pass (`markTopSoilBroken`, `src/world/store.zig:1071-1083`).

`World.chunks` is a pointer-stable map of `*Chunk`, so a `*Chunk` held across a re-entrant `getOrCreate` survives a map resize; chunks are freed only on eviction or `deinit` (`src/world/store.zig:530-537`). Residency is capped at `max_resident_chunks = 4096` (`src/world/store.zig:825`); `evictOneChunk` picks the coldest `last_touch` (minimum key on ties, never HashMap order, so DST replay is stable), saves it, then frees it (`src/world/store.zig:827-857`). The `World` fields that matter here (`src/world/store.zig:529`, trimmed):

```zig
pub const World = struct {
    chunks: std.AutoHashMapUnmanaged(u64, *Chunk),
    world_dir: []u8,
    allocator: std.mem.Allocator,
    heightmap: ?dtm.Heightmap = null,
    prefabs: ?prefabs_mod.Index = null,
    water: ?water_mod.Sources = null,
    leveler: water_mod.Leveler = .{},
    biomes: ?biomes_mod.BiomeMap = null,
    biome_layers_table: biome_layers.Table = .{},
    terrain_source: TerrainSource = .flat,
    profile: protocol.WireProfile = .{},
    // ... (geometry, worldgen, id-oracle hooks, terrain_ids omitted)
    async_flush: bool = false,
    flush: chunk_flush.Flusher = .{},
    sync_fallbacks: std.atomic.Value(u64) = .init(0),
    touch_seq: u64 = 0,
```

`getOrCreate` is the single entry point for materialization (`src/world/store.zig:859-1026`). It stamps `last_touch`, then tries the disk first: a v3 record carrying blocks is authoritative for every channel regeneration would produce, so the terrain rebuild is skipped (`src/world/store.zig:886-899`). Otherwise it fills heights from DTM, procedural noise or the flat sea level, stamps biome layer columns, applies prefab `.tts` paint plus authored damage, then pours water sources (`src/world/store.zig:900-1011`). A heights-only (ZCH2/v2) record is re-loaded after regen so player edits win over the rebuild (`src/world/store.zig:1012-1022`). World-space writes (`setBlockWorld`, `setBlockRawWorld`, `setBlockTexDensWorld`) all route through `getOrCreate` and then `markTopSoilBroken` (`src/world/store.zig:1044-1062`).

## ZCH3 on-disk format

One file per chunk at `{world_dir}/c_{x}_{z}.zch` (`chunkPath`, `src/world/store.zig:1329-1331`). `encodeChunk` writes a 16-byte header, the 256-byte height plane, then the optional channels in a fixed order, and finishes with the 32-byte topsoil bitfield (`src/world/store.zig:1391-1450`). Header construction (`src/world/store.zig:1399-1409`):

```zig
        hdr[0] = 'Z';
        hdr[1] = 'C';
        hdr[2] = 'H';
        hdr[3] = if (tall) '4' else '3';
        std.mem.writeInt(i32, hdr[4..8], c.pos.x, .little);
        std.mem.writeInt(i32, hdr[8..12], c.pos.z, .little);
        hdr[12] = @intFromBool(has_blocks);
        hdr[13] = @intFromBool(has_textures);
        hdr[14] = @intFromBool(has_densities);
        hdr[15] = @intFromBool(has_damages);
        if (tall) std.mem.writeInt(u32, hdr[16..20], c.y_dim, .little);
```

Channel order after the heights is blocks (u32 per cell), textures (u64), densities plus the `dens_set` bitset, damages (u16), then topsoil (`src/world/store.zig:1410-1448`). Flags 12 to 14 match ADR 0011; flag 15 (the damage plane) and the ZCH4 variant, written only when the column height is not 256, postdate that ADR table and are specified in the source comment (`src/world/store.zig:1379-1390`). The topsoil tail is optional on read: a file saved before the field existed loads all-clear (`src/world/store.zig:1613-1620`).

`loadChunk` validates the whole record before mutating the resident chunk - magic, stored `x`/`z` against the requested position, every flag byte in `{0,1}`, the ZCH4 height against the active profile, and the total length against the channels the flags claim (`src/world/store.zig:1519-1554`). A torn save is rejected so a half-loaded plane can never suppress terrain materialization. ZCH2 is accepted for its heights only and its u16 block plane is deliberately ignored, because a type-only plane would lose rotation and meta (`src/world/store.zig:1557-1572`). `validateChunkBytes` is the same bounds check as a standalone function, used by fuzz harnesses rather than by `loadChunk` (`src/world/store.zig:1336-1377`). The encode path allocates its buffer from `std.heap.page_allocator`, because it runs on parallel workers and `World.allocator` is a debug allocator that is not thread-safe (`src/world/store.zig:1389-1391`).

## Dirty tracking and the flush path

`dirty` is set by every mutating setter: `setBlockRaw` (`setBlockTexDens` routes through it), `setDmg` and `clearDmg`, `setTopSoilBroken`, and `setHeight` (`src/world/store.zig:243,251,310,348,450`). `setBlockDecoRaw` deliberately does not set it (`src/world/store.zig:465-475`): decoration mirror writes are derived state, so a clean session writes no files (see the persistence test at `src/world/store.zig:1794-1826`).

`saveAll` collects the dirty keys, sorts them so write order is independent of HashMap history (deterministic fault injection), and walks them in slices of 512 (`src/world/store.zig:1632-1672`). `saveChunkSlice` writes serially below `parallel.min_parallel_items` and otherwise fans out with `parallel.forRanges`, clearing `dirty` per chunk as it succeeds and returning `error.SaveFailed` if any worker did (`src/world/store.zig:1674-1708`). `saveChunk` skips a clean chunk in a procedural world, since it regenerates deterministically from the seed; baked worlds persist clean chunks because disk reload beats DTM plus prefab regen (`src/world/store.zig:1460-1468`).

The async path encodes on the tick thread and hands `path` and `payload` to one background writer (the `Entry` ring and `Flusher`, `src/world/chunk_flush.zig:36`, trimmed):

```zig
const Entry = struct {
    key: u64,
    path: []u8,
    payload: []u8,
};

pub const Flusher = struct {
    mu: std.Io.Mutex = .init,
    work_cv: std.Io.Condition = .init,
    done_cv: std.Io.Condition = .init,
    ring: [max_pending]Entry = undefined,
    head: usize = 0,
    n: usize = 0,
    bytes: usize = 0,
    cur_key: u64 = 0,
    cur_active: bool = false,
    shutdown: bool = false,
    thread: ?std.Thread = null,
    started: std.atomic.Value(bool) = .init(false),
    queued: std.atomic.Value(u64) = .init(0),
    written: std.atomic.Value(u64) = .init(0),
    errors: std.atomic.Value(u64) = .init(0),
    waits: std.atomic.Value(u64) = .init(0),
```

The queue is bounded by 512 entries and 64 MiB (`src/world/chunk_flush.zig:32-34`); a full queue or a shut-down flusher falls back to an inline write rather than dropping the save, counted in `World.sync_fallbacks` (`src/world/store.zig:1474-1489`). The shape mirrors stock `RegionFileManager`: `waitKey` refuses to let a read race a queued or in-flight write for the same key, and `loadChunk` calls it before reading (`src/world/chunk_flush.zig:7-10,124-135`; `src/world/store.zig:1500-1505`). `deinit` drains the ring and joins the writer, never detaches it (`src/world/chunk_flush.zig:160-182`). Async is off by default and forced off under serial replay, so `io_fs.injectWriteFailures` still surfaces as an error return from `saveAll` (`World.asyncEnabled`, `src/world/store.zig:1453-1458`; `src/world/chunk_flush.zig:21-24`).

## Tile entity stores

Each TE store is a fixed-capacity array of records plus a `used` flag array, keyed by world position. Containers and signs additionally keep a compact `keys` mirror so `get` scans a few KiB instead of striding roughly 500-byte records (`src/world/containers.zig:104-115`; `src/world/signs.zig:38-60`). Positions are absolute world coordinates including Y, so a container in a cave and one on the surface at the same X/Z are distinct entries.

The container record (`src/world/containers.zig:28`, doc comments trimmed):

```zig
pub const Container = struct {
    pos: PosKey = .{ .x = 0, .y = 0, .z = 0 },
    block_id: i32 = 0,
    inv_guid: [16]u8 = .{0} ** 16,
    slots: [max_container_slots]components.InvSlot = [_]components.InvSlot{.{}} ** max_container_slots,
    slot_count: u16 = 8, // default 2x4
    size_x: u8 = 0,
    size_y: u8 = 0,
    touched: bool = false,
    touched_day: u32 = 0,
    player_storage: bool = true,
    loot_list: []const u8 = "",
```

`inv_guid` is deterministic from the position rather than a random GUID, so a client-issued inventory key resolves back to the same container across restarts (`guidFromPos`/`posFromGuid`, `src/world/containers.zig:66-88`); it is the key the C2S inventory path resolves (`src/server/c2s/inv.zig:1011`). The table holds 4096 containers (`src/world/containers.zig:14`). When it fills, `getOrCreate` evicts a world container (`player_storage == false`), which regenerates from the next chunk scan, and refuses to evict a player-placed one (`src/world/containers.zig:133-163`). Persisted to `containers.zct` as ZCT2, which adds `touched_day` and the observed `size_x`/`size_y`; ZCT1 records load with size 0 (`src/world/containers.zig:198-204,269-340`).

The other stores are keyed the same way: signs and vending reuse `containers.PosKey`, lights and workstations carry plain `x`/`y`/`z` fields (`src/world/signs.zig:19`; `src/world/vending.zig:17`; `src/world/light_te.zig:18-22`; `src/world/workstations.zig:249-252`). Their record declarations are quoted verbatim below, with unrelated comments and blank lines trimmed. Signs (`src/world/signs.zig:29`):

```zig
pub const Sign = struct {
    pos: PosKey = .{ .x = 0, .y = 0, .z = 0 },
    block_id: i32 = 0,
    len: u16 = 0,
    body: [max_body]u8 = undefined,
};
```

Vending (`src/world/vending.zig:64`):

```zig
pub const Vending = struct {
    pos: PosKey = .{ .x = 0, .y = 0, .z = 0 },
    block_id: i32 = 0,
    trader_id: i32 = 0,
    available_money: i32 = 0,
    stock: [max_vending_stock]StockEntry = [_]StockEntry{.{}} ** max_vending_stock,
    stock_n: u8 = 0,
    is_locked: bool = false,
    owner: UserRef = .{},
    password_hash: [max_password_hash]u8 = .{0} ** max_password_hash,
    password_len: u8 = 0,
    allowed: [max_allowed_users]UserRef = [_]UserRef{.{}} ** max_allowed_users,
    allowed_n: u8 = 0,
    rental_end_day: i32 = 0,
    rentable: bool = false,
    next_auto_buy: u64 = 0,
};
```

Lights (`src/world/light_te.zig:24`):

```zig
pub const Light = struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    intensity: f32 = 1.0,
    range: f32 = 10.0,
    color: u32 = 0xffffffff,
    light_type: u8 = 1,
    angle: f32 = 0,
    shadows: u8 = 1,
    state: u8 = 0,
    rate: f32 = 0,
    delay: f32 = 0,
};
```

Signs store the applied composite TE body verbatim, handle included, and replay it patched to the unsolicited `255`; the body is not re-encoded from parsed fields (`src/world/signs.zig:8-13`). The budget is 512 bytes per body and 256 signs, with an over-long body or a full table dropping the record while the edit still echoes (`src/world/signs.zig:24-25,62-91`). Persisted to `signs.zsg` (magic ZSG1, `src/world/signs.zig:122-127`). Vending holds 128 machines, 48 stock entries and 8 allowed users each, and persists to `vending.zvn` (magic ZVNM, `src/world/vending.zig:11-15,159,196`). Lights hold 2048 entries (`src/world/light_te.zig:16`).

Workstations are the largest record: four 12-slot item groups (fuel, input, tools, output), the display-only `last_input` blob, a 4-deep craft queue, a craft-complete list, per-slot melt timers, and the on-wire array lengths (`src/world/workstations.zig:249-291`). Key fields (`src/world/workstations.zig:249`, trimmed):

```zig
pub const Workstation = struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    block_id: i32 = 0,
    fuel: [slots_per_group]components.InvSlot = [_]components.InvSlot{.{}} ** slots_per_group,
    input: [slots_per_group]components.InvSlot = [_]components.InvSlot{.{}} ** slots_per_group,
    tools: [slots_per_group]components.InvSlot = [_]components.InvSlot{.{}} ** slots_per_group,
    output: [slots_per_group]components.InvSlot = [_]components.InvSlot{.{}} ** slots_per_group,
    last_input: [last_input_blob_max]u8 = [_]u8{0} ** last_input_blob_max,
    last_input_blob_len: u16 = 0,
    queue: [max_ws_queue]QueueItem = [_]QueueItem{.{}} ** max_ws_queue,
    craft_complete: [max_craft_complete]CraftComplete = [_]CraftComplete{.{}} ** max_craft_complete,
    craft_complete_n: u8 = 0,
    melt: [max_ws_melt]f32 = [_]f32{0} ** max_ws_melt,
    fuel_len: u8 = stock_fuel_len,
    input_len: u8 = stock_input_len,
    tools_len: u8 = stock_tools_len,
    output_len: u8 = stock_output_len,
    last_input_len: u8 = stock_last_input_len,
    queue_len: u8 = stock_queue_len,
    melt_len: u8 = stock_melt_len,
    is_burning: bool = false,
    burn_time_left: f32 = 0,
    // ... (module flags, is_player_placed, geometry_known omitted)
    dirty: bool = false,
```

The `*_len` fields are on-wire array lengths, not used prefixes, so nothing is sent before a client write has told the server the real geometry (`geometry_known`, `src/world/workstations.zig:268-275,286-291`). The store holds 256 stations and persists to `workstations.zws` (magic ZWS1) with records sorted by position (`src/world/workstations.zig:23,702-708`). `removeAt` exists because an entry that outlived its block kept broadcasting and kept coming back from the save file with its old fuel and queue (`src/world/workstations.zig:682-698`).

Instantiation happens on the chunk fill path: containers are seeded from the prefab TE scan and the storage-id block scan (`src/server/game/chunk_fill.zig:306-307,366-386`), lights are parsed from their `.tts` persistency payload (`src/server/game/chunk_fill.zig:348-351`), and C2S block and inventory packages create, mutate and remove entries (`src/server/c2s/inv.zig:512,540,597`; `src/server/c2s/blocks.zig:244-248,396-404`).

## Derived state that is not persisted

The stability plane is derived and explicitly never written: a chunk computes it once on first touch by resetting every support block to 15 and capping non-support blocks at 1, then running the spread, and block edits use the incremental path (`src/world/stability.zig:2-27,85-106`). Removing a block relaxes the affected region to a fixpoint and returns the cells whose byte hit 0, which `Game` turns into falling blocks and air (`src/world/stability.zig:261-269`; `src/server/game/stability.zig:24-88`). Placing re-spreads (`src/world/stability.zig:419-426`). The storage-medium consequence is that a restarted server recomputes stability from the persisted block plane, which is the same derivation.

The decoration mirror is the next one: `deco_mirror.apply` writes single-block decorations only into air and multiblock decorations across their full offset set, encoding each child with `ischild` and a negated parent offset (`src/world/deco_mirror.zig:71-151`). These writes go through `setBlockDecoWorld` and are left out of `dirty` on purpose, so they are re-derived on every stream and reload instead of saved (`src/world/store.zig:465-475`).

`biome_id`, `te_scanned`, `power_scanned` and `last_touch` are per-session: `biome_id` caches the dominant biome because the biome map is static (`src/world/store.zig:142-144`; `src/server/game/chunk_fill.zig:57-72`), the two `*_scanned` flags gate the one-time per-chunk storage and power scans (`src/server/game/chunk_fill.zig:209-214,261-268`), and the storage scan is documented as re-running after a restart because the flag is not persisted (`src/server/game/chunk_fill.zig:381`). The power grid itself is runtime state rebuilt from the persisted blocks. Light tile entities are memory-only in the same sense: they are authored world data that regenerates from the prefab scan on chunk fill, so the light store has no save file (`src/world/light_te.zig:10-12`; `src/server/game/chunk_fill.zig:348-351`). `terrain_snapshot.Snapshot` is rebuilt every tick when enabled and holds no authority of its own (`src/world/terrain_snapshot.zig:46-58`).

What does survive a restart is the chunk record plus the TE files: heights, blocks (u32 `rawData` including rotation and meta), paint, density, damage, topsoil, container contents, sign bodies, vending state and workstation state. What does not: stability bytes, decoration-mirror blocks that were never edited, per-chunk scan flags, the terrain snapshot, and every container past the eviction policy that was a world (non-player) container.

## Per-tick and shutdown wiring

`Game.step` runs the store in a fixed order. Water leveling drains the bounded edit queue once per tick, each filled cell going out through the `water_fill` hook because the chunk `dirty` flag is persistence-only and does not re-send (`src/server/game/step.zig:162-166`; `World.levelWaterTick`, `src/world/store.zig:1184-1193`). The terrain snapshot rebuilds before the AI phase so A* probes answer lock-free (`src/server/game/step.zig:95-102`), with misses sampled into a counter (`src/server/game/step.zig:245-246`).

Workstations tick every `sleeper_tick_ticks` (10 by default), which is 0.5 s of simulated time on a 20 TPS tick; that pass refreshes the block-derived material-input flag, runs `tickAllResolved` with the item resolvers and caps, and re-broadcasts the stations whose tick set `dirty` (`src/server/game/step.zig:254-258`; `src/server/game/craft.zig:596-605`; `src/server/game/types.zig:89`).

Every `save_interval_ticks` (100 by default, so 5 s) the tick writes the world and all TE stores: `world.saveAll`, containers, sign texts, workstations, vending, then the non-world stores (`src/server/game/step.zig:525-534`; `src/server/game/types.zig:91`). Shutdown follows the same list, then `world.flushWait()` under an APM scope before the stores are freed, so a queued async write is not lost with the writer thread (`src/server/game/lifecycle.zig:12-25`). Chunk TE delivery to a joining or streaming client re-scans each store for entries inside the chunk rectangle, in a fixed order: containers, signs, vending, lights, workstations (`src/server/game/chunk_stream.zig:37-85`). The TE stores are fields on `Game` (`src/server/game.zig:606-618`), loaded at startup from `world_dir` (`src/server/game.zig:1099-1123`), and the admin `save` path calls the same `persist.saveAllStores` helper (`src/server/persist.zig:48-60`).

Sending TE state is wire work and lives outside this subsystem: `wire` re-exports the domain types and builds the stock TileEntity bodies, so the store only hands over records. A round trip through zdtd's own encode and decode paths is self-consistency evidence only; it does not by itself establish stock compatibility for any of these bodies.

## See also

- [`chunk-stream.md`](chunk-stream.md): how resident chunks and their TE records reach a peer.
- [`persistence.md`](persistence.md): the non-world save files and the shutdown ordering.
- [`map.md`](map.md): DTM, prefabs, water and biome sources that feed `getOrCreate`.
- [`../ARCHITECTURE.md`](../ARCHITECTURE.md) section 7 for the chunk lifecycle diagram.
- [`../adr/0011-custom-zch-world-overlay.md`](../adr/0011-custom-zch-world-overlay.md) for why the overlay is not a stock region format.
