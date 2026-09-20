# Persistence and restart durability

This page covers what survives a process restart in zdtd: chunk files, player records, the persistent entity, claim, container, workstation, sleeper and trader stores, the world clock, weather and sparse block meta. The subsystem owns the save/load helpers reached as `self.saveX()` on `Game` (`src/server/persist.zig`), the per-store serializers they call (`src/world/store.zig`, `src/world/containers.zig`, `src/world/workstations.zig`, `src/world/sleepers.zig`, `src/world/vending.zig`, `src/server/game/blockmeta.zig`, `src/server/game/clock_persist.zig`), and the atomic file primitive all of them write through (`src/util/io_fs.zig`). Store writes are the only writers of the save files in this directory, and a mutation that must survive a restart goes through a store, not through an interest cache. Package direction is enforced: the server package sits at the top of the stack and may import every other package (`src/server/root.zig:3`), while the world package may import only util and assets and must not import wire, server or litenet (`src/world/root.zig:3`), so path selection, owner re-mapping and error policy live in `server/` and the store stays wire-free.

Sources: [`src/server/persist.zig`](../../src/server/persist.zig), [`src/server/game/clock_persist.zig`](../../src/server/game/clock_persist.zig), [`src/world/store.zig`](../../src/world/store.zig), [`src/server/game/chunk_fill.zig`](../../src/server/game/chunk_fill.zig), [`src/server/game/lifecycle.zig`](../../src/server/game/lifecycle.zig), [`src/util/io_fs.zig`](../../src/util/io_fs.zig).

## What survives a restart and what does not

Durable state is one flat overlay directory, `world_dir` (`src/world/store.zig:538`): chunk files, `players.zsv`, `entities.zen` (vehicles, turrets, power wires and nodes, death bags), `claims.zlc`, `containers.zct`, `workstations.zws`, `vending.zvn`, `allies.zal`, `sleepers_cleared.zsc` and `sleepers_triggered.zst`, `traders.zst`, `blockmeta.zbm`, `weather.zwt` and `clock.zcl`. `saveAllStores` is the canonical ladder over all of them, documented so an operator-triggered save covers what the autosave tick covers (`src/server/persist.zig:52`):

```zig
pub fn saveAllStores(self: *Game) bool {
    var ok = true;
    const note = struct {
        fn f(o: *bool, g: *Game, what: []const u8, err: anyerror) void {
            o.* = false;
            logPersistErr(g, what, err);
        }
    }.f;
```

The periodic autosave in `Game.step` and graceful shutdown in `lifecycle.deinit` write the same store set as `saveAllStores` (traders and sleeper markers included). The tick path still skips `savePlayers` when `players_dirty` is false; admin `.save` / `.saveworld` always flush players.

Nothing else is durable and none of it is meant to be: peer and interest caches, reliable windows and per-session client state reset on reconnect; the plugin runtime reloads and its budgets re-arm with no persisted plugin state; apm counters and histograms are per-process; admin TCP is a fresh connection per attach (`docs/prd/0004-hot-restart.md:61`). Inside a chunk, the per-block stability plane is derived state that is explicitly never persisted (`src/world/store.zig:135`), and the `te_scanned` and `power_scanned` flags are runtime-only, so the storage-TE scan and the power-grid rebuild repeat on first touch after a restart (`src/world/store.zig:137`, `src/server/game/chunk_fill.zig:52`).

Every format here is zdtd-owned: the magics are `ZPV<version>`, `ZEN2` (legacy `ZENT` still loads), `ZCLC`, `ZCL2`, `ZWTH1`, `ZBM2`, `ZCT3` (legacy `ZCT1`/`ZCT2` still load), `ZWS1` and `ZCH3`/`ZCH4`. None of these files is the stock dedicated server's region or PlayerDataFile format, and nothing in the read paths emits one; the persistence inventory is the contract the PRD tracks, not a stock-save compatibility claim (`docs/prd/0004-hot-restart.md:69`).

## Files on disk

Paths are built by `fmt.bufPrint` into a caller stack buffer per store, keyed on `self.world.world_dir`; chunks are named by position. `World.chunkPath` (`src/world/store.zig:1329`):

```zig
    fn chunkPath(self: *World, pos: ChunkPos, buf: []u8) ![]const u8 {
        return try std.fmt.bufPrint(buf, "{s}/c_{d}_{d}.zch", .{ self.world_dir, pos.x, pos.z });
    }
```

Player records live in `players.zsv` under the same directory (`src/server/persist.zig:576`). The world clock is a fixed 28-byte record with its own reader that accepts the older 12-byte form; `saveClock` (`src/server/game/clock_persist.zig:12`):

```zig
pub fn saveClock(self: *const Game) !void {
    var path: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/clock.zcl", .{self.world.world_dir});
    var buf: [28]u8 = undefined;
    @memcpy(buf[0..4], "ZCL2");
    const clk = &self.sim.director.clock;
    std.mem.writeInt(u64, buf[4..12], clk.worldTimeBits(), .little);
```

The blood-moon schedule follows at bytes 12..28 as four `u32` fields (`bm_cycle`, `bm_day_last`, `next_bm`, `bm_freq`), saved as-is because the schedule is advanced lazily by the day queries (`src/server/game/clock_persist.zig:19`). `restoreClock` reparses `worldTime` into `day` and `hours` and treats a `ZCL1` file, or a short `ZCL2` one, as clock-only and recomputes the schedule (`src/server/game/clock_persist.zig:41`). Weather is a variable-length `ZWTH1` blob under the same policy: an unreadable or mismatched file is logged and a fresh roll is kept (`src/server/game/blockmeta.zig:83`). Sparse block meta is `ZBM2` with a `u64` key and `u32` raw value per record; damage HP moved to the chunk damage plane, so a `ZBM1` file is accepted and ignored (`src/server/game/blockmeta.zig:54`).

## Atomic write path

Every store write goes through one helper, so the crash behaviour is one decision rather than one per store. It materializes a temporary file and replaces the target (`src/util/io_fs.zig:85`):

```zig
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, rel_path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic_file.deinit(io);
    var wbuf: [4096]u8 = undefined;
    var file_writer = atomic_file.file.writer(io, &wbuf);
    file_writer.interface.writeAll(data) catch return file_writer.err.?;
    try file_writer.flush();
    try atomic_file.replace(io);
```

`createFileAtomic` also creates missing parent directories, so no store has to pre-mkdir. The helper carries the deterministic-simulation fault injectors: `injectWriteFailures` and `injectReadFailures` (`src/util/io_fs.zig:23`) make the next write return `error.DiskQuota` and the next read `error.InputOutput`, which is how a restart or mid-save fault is replayed and how the `persistence_errors` counter is exercised (`src/server/persist.zig:24`). Failure of one store never aborts the rest of the ladder; `saveAllStores` returns false so an admin reply cannot claim success over a disk error (`src/server/admin_console.zig:1310`).

## Chunk files

A chunk is a 16x256x16 column with a dense block plane, optional texture, density and damage planes, and the stock topsoil bitfield. The persisted subset (`src/world/store.zig:100`):

```zig
pub const Chunk = struct {
    pos: ChunkPos,
    y_dim: u32 = 256,
    heights: [256]u8 = .{sea_level} ** 256,
    topsoil: [32]u8 = [_]u8{0} ** 32,
    blocks: ?[]u32 = null,
    textures: ?[]u64 = null,
    densities: ?[]u8 = null,
    dens_set: ?[]u8 = null, // bitset: 1 = densities[i] is valid TTS paint
    damages: ?[]u16 = null,
    stability: ?[]u8 = null,
    dirty: bool = false,
```

`encodeChunk` writes a 16-byte header (20 for a taller wire profile) and then only the planes that exist, with one flag byte per plane (`src/world/store.zig:1392`):

```zig
        const has_blocks = c.blocks != null;
        const has_textures = c.textures != null;
        const has_densities = c.densities != null and c.dens_set != null;
        const has_damages = c.damages != null;
        const tall = c.y_dim != 256;
        const hdr_len: usize = if (tall) 20 else 16;
        var hdr: [20]u8 = undefined;
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

The topsoil tail is appended last and is optional on read, so a pre-topsoil file loads all-clear (`src/world/store.zig:1445`). A proc world regenerates untouched terrain from its seed, so `saveChunk` returns without writing unless the chunk is dirty (`src/world/store.zig:1468`): only edits grow the save directory in an infinite world. Baked worlds keep persisting clean chunks because disk reload beats DTM plus prefab regeneration on a finite map. `saveAll` walks the dirty set only, sorts the keys so the write order is independent of the hash map walk, and hands batches of up to 512 chunks to `saveChunkSlice`, which writes inline below `parallel.min_parallel_items` and otherwise splits across the parallel pool (`src/world/store.zig:1632`, `src/world/store.zig:1674`). When the async flusher is enabled a chunk write is submitted to the background writer, and a full queue falls back to an inline write for that key rather than dropping the payload (`src/world/store.zig:1480`).

`loadChunk` validates the header (magic, position, flag bytes, `y_dim` for `ZCH4`), computes the required length from the flags, and rejects the file before mutating the resident chunk, so a torn save regenerates instead of leaving a half-loaded plane (`src/world/store.zig:1546`). An eviction-then-reload waits on any queued write for the same key first (`src/world/store.zig:1505`). A resident miss during streaming calls the same loader through `World.getOrCreate`, so a chunk restored from disk reaches the client through `sendSpawnChunk` exactly like a generated one (`src/server/game/chunk_fill.zig:40`).

## Player records

`players.zsv` is a header plus a record per player; the header count is patched in last from the records actually appended, because a count predicted up front drifts when a joined client has no ECS player slot (`src/server/persist.zig:629`). The written magic byte is `'H'`, that is ZPV17, and older files stay readable (`src/server/persist.zig:632`). The record layout, as documented next to `playersPath` (`src/server/persist.zig:576`):

```zig
/// Record layout (v5+): magic ZPVN | n:u32 | records…
/// each: name_len:u8 | name | x,y,z:f32 | coins:u32 |
///   inv_n:u8 | inv_n×(item:u16, count:u16, quality:u8, meta:u16[, use_times:f32 from v7]) |
///   jn:u8 | jn×(def_id:u16, quest_code:i32, flags:u8, progress:u16, phase:u8,
///     name_len:u8, name, poi_valid:u8, poi rect:f32×6)
///   prog:u8 (1 = present) | level:u16 | xp:u64 | food/max/water/max:f32×4 |
///   hp:f32 (v8+) | born_world_time:u64 (v9+) |
///   buff_n:u8 | buff_n×(def_id:u16, stack:u8, flags:u8, dur_ticks:u32,
```

The version this build writes and the stride each generation used are one pair of functions, so a reader for an old file and the writer cannot disagree (`src/server/persist.zig:132`, `src/server/persist.zig:134`):

```zig
pub fn zpvSlotStride(version: u8) usize {
    if (version >= 17) return ecs.components.inv_slot_persist_stride; // 52 + flags + mod_n + 4 qualities
    if (version >= 16) return 52; // 21 + stats_n u8 + 6 x (effect u8, two i16) (ZPV16)
    if (version >= 12) return 21; // 13 + 4 mod ids (ZPV12)
    if (version >= 10) return 13;
    return if (version >= 7) 11 else 7;
}
```

The v11 skill tail, the v13 dropped-bag markers, the v14 kill/death counters, the v15 identity section and the v16 item stats each ride only when the progression tail is present, and each is walked by `zpvRecordSpan` (`src/server/persist.zig:301`), which returns the record length plus the offset of the optional identity section (`src/server/persist.zig:289`):

```zig
pub const RecordSpan = struct {
    len: usize,
    identity_off: usize = 0,
};
```

Since ZPV15 a record can be keyed to an account instead of a login name, because a name key let any client load another player's save by typing their name (`src/server/persist.zig:101`). An identity-bearing row belongs to that account and nothing else (`src/server/persist.zig:419`):

```zig
const ZpvIdentity = struct {
    present: bool = false,
    primary: platform_user.Stored = .{},
    native: platform_user.Stored = .{},

    /// True when this record should restore into `cl`. An identity-bearing row
    /// belongs to that account and nothing else: a matching name is not enough
    /// once the row has an identity, and an absent or different identity never
    /// inherits it (fail closed). A legacy row with no identity is still
    /// matched by name so an existing world upgrades in place on the next save.
    fn matchesClient(self: ZpvIdentity, cl: *const Client, name_matches: bool) bool {
        if (!self.present) return name_matches;
        const theirs = self.primary.get() orelse return false;
        const mine = cl.puid_primary.get() orelse return false;
        return platform_user.Id.eql(mine, theirs);
    }
};
```

`savePlayers` is a merge write, not a rewrite: it reads the existing file, carries every record whose player is not currently live and re-encodes the ones whose layout predates the current version, so offline players and legacy shapes survive an autosave (`src/server/persist.zig:573`). One live record is written per joined client with a sim player slot; the vehicle-style truncation the store uses elsewhere is not acceptable here, so a `comptime` block proves a 4096-byte record can hold name, position, wallet, inventory count and every inventory slot at the current stride (`src/server/persist.zig:840`). A carried record is dropped only when this save rewrites that client's state fresh, and the rewrite predicate matches the write predicate exactly so a connected-but-not-spawned player cannot lose its record (`src/server/persist.zig:615`). Restore happens at login: `tryRestorePlayer` is called once the client has a sim entity (`src/server/c2s/join.zig:230`), and again on the enter-game path when the entity was created there (`src/server/c2s/join.zig:257`). The same file backs `wipePlayerRecordsByName`, which reports how many records it removed (`src/server/persist.zig:1056`).

## Save triggers

The periodic save is a modulo on the tick counter and is the primary writer of every store (`src/server/game/step.zig:523`):

```zig
    if (self.tick_n % self.save_interval_ticks == 0) {
        const ss = apm.profiler.scope(&self.harness.prof, .save_io);
        defer ss.end();
        {
            const es = apm.profiler.scope(&self.harness.prof, .save_encode);
            defer es.end();
            self.world.saveAll() catch |e| game_mod.logPersistErr(self, "save world", e);
        }
```

`save_interval_ticks` defaults to 100 ticks (`src/server/game/types.zig:91`) and is a bound field, so `[stream] save_interval_ticks` in `zdtd.toml` overrides it without a parse arm (`src/server/game/types.zig:370`). At 20 TPS that is a 5 s RPO for store files on a healthy disk; crash or kill -9 can still lose the open interval. The player save inside that block is gated on `players_dirty`, which is set by the character-sheet update path (`src/server/c2s/misc.zig:353`) and cleared when the save runs (`src/server/game/step.zig:547`). The block is instrumented with the `save_io` and `save_encode` apm sections because it runs on the tick.

Per-event saves cover state a periodic write could lose: a dropped or reaped session saves that player before its data disappears (`src/server/game/session_drop.zig:28`, `src/server/game/tick.zig:1545`). Shutdown saves players first and flushes chunks before anything else, waits on the background chunk writer, then drains the remaining stores (including traders and sleepers) and tears the process down (`src/server/game/lifecycle.zig:9`). Admin `.save` and `.saveworld` both run the full `saveAllStores` ladder and reply with the ladder's own success value (`src/server/admin_console.zig:1310`, `src/server/admin_console.zig:1761`). `wipeplayer` copies `players.zsv` to `players.zsv.bak` before rewriting so a mistaken wipe can be undone on the same host (`src/server/persist.zig:1056`).

Startup restore runs in `Game.createWithOptions` in a fixed order: containers, sign texts, vending, workstations (`src/server/game.zig:1123`), claims, entities, allies (`src/server/game.zig:1130`), block meta, then assets, then traders after `initWorld` re-rolled the stock XML stock (`src/server/game.zig:1196`), with weather and clock restored from the assets init path (`src/server/game/init_assets.zig:799`, `src/server/game/init_assets.zig:810`). Every store loader in this init sequence treats `error.OpenFailed` as "no file, fresh world" and surfaces any other read failure, so a corrupt file is logged before the next save could clobber it.

## Operator backup and restore

Atomic temp+rename protects one open write (`src/util/io_fs.zig:87`); it is not a backup. Instance loss, disk failure, or a deleted `world_dir` needs a copy outside that directory (and preferably off the host). `scripts/backup-world.sh` copies a world dir into a timestamped sibling under a backup root, keeps a fixed rotation, and exits non-zero on failure. Restore: stop zdtd, replace `world_dir` with a backup tree (or copy `players.zsv.bak` over `players.zsv` for a wipe undo), start with the same `--world` path. RTO is the time to copy the tree back and restart; measure it once on the operator's disk. Backups co-located on the same volume share that disk's failure domain.

The two design docs in this area lag the code on versions: `docs/prd/0004-hot-restart.md:76` records player records as ZPV13 and `docs/ARCHITECTURE.md:655` as ZPV12, while this build writes ZPV16 (`src/server/persist.zig:124`) and reads ZPV2 and later (`src/server/persist.zig:587`). PRD 0004 section 5 is otherwise the operator-visible inventory to keep in sync when a store or field is added (`docs/prd/0004-hot-restart.md:110`).

## See also

- [World store](world-store.md) - the chunk, container, workstation and terrain stores this page persists.
- [Join and login](join.md) - the login path that calls `tryRestorePlayer` and re-maps claim and turret owners.
- [Tick loop](tick.md) - where the autosave modulo and its apm sections live.
- [Configuration](config.md) - `save_interval_ticks` and the other bound tunables.
- [ARCHITECTURE.md](../ARCHITECTURE.md) - section 10.3 has the save-ladder diagram.
- [PRD 0004: hot restart](../prd/0004-hot-restart.md) - the restart contract and the persistence inventory.
