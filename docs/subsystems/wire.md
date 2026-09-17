# Wire: frames, binary codec, stock package bodies

The wire package owns the byte-level contract between zdtd and a stock 7 Days to Die client: the little-endian reader/writer pair that mirrors .NET `BinaryReader`/`BinaryWriter`, the LiteNet channel envelope that carries one or more packages, the ordered package-name registry that supplies every numeric package id, and the per-package body builders for the stock shapes the server sends or parses. It owns bytes only. It does not decide which peer sees a package, when a package is legal, or what a body means in the simulation; those live in `server/`, `ecs/`, and `world/`. The package `//!` comment (`src/wire/root.zig:1`) states the boundary: wire may import `util`, `assets` (id pins, Unity hashes), `ecs` component shapes, and `world` container/workstation domain types for tile-entity apply, and must not import `server` or `litenet`. `scripts/lint-architecture.sh` enforces that edge (`docs/ARCHITECTURE.md:174`); only `server`, `main`, and tests call in.

Sources: [`src/wire/root.zig`](../../src/wire/root.zig), [`src/wire/binary.zig`](../../src/wire/binary.zig), [`src/wire/frame.zig`](../../src/wire/frame.zig), [`src/wire/packages.zig`](../../src/wire/packages.zig), [`src/protocol.zig`](../../src/protocol.zig). The stock body modules are [`src/wire/stock_*.zig`](../../src/wire), with [`src/wire/platform_user.zig`](../../src/wire/platform_user.zig) and [`src/wire/te_types.zig`](../../src/wire/te_types.zig).

## Reader and Writer: .NET binary semantics

`binary.zig` is the only endian path in the repo (`src/wire/root.zig:8`). Integers are little-endian two's complement via `std.mem.readInt`/`writeInt` with `.little` (`src/wire/binary.zig:29`, `src/wire/binary.zig:130`). A float is its IEEE-754 bit pattern, not a converted numeric value, so negative zero survives a round trip (`src/wire/binary.zig:58`, test at `src/wire/binary.zig:325`).

Strings follow `BinaryReader.ReadString`: a 7-bit encoded byte length, then that many UTF-8 bytes. The byte count is counted in bytes, not characters (`src/wire/binary.zig:242`). The two ends:

The writer's string and length-prefix primitives (src/wire/binary.zig:168):

```zig
    pub fn writeString(self: *Writer, s: []const u8) error{Overflow}!void {
        try self.write7BitEncodedInt(@intCast(s.len));
        try self.writeBytes(s);
    }
```

The reader's counterpart plus the truncating variant (src/wire/binary.zig:63):

```zig
    fn readStringLen(self: *Reader) ReadError!usize {
        // Same encoding as read7BitEncodedInt; map Overflow so string paths keep
        // InvalidString (callers and tests distinguish bad length from buffer fit).
        const n = read7BitEncodedInt(self) catch |err| switch (err) {
            error.Overflow => return error.InvalidString,
            else => |e| return e,
        };
        return n;
    }
```

`ReadError` is `error{ EndOfStream, InvalidString, Overflow }` (`src/wire/binary.zig:5`). A 7-bit prefix longer than five bytes is `InvalidString`, never a shift overflow (`src/wire/binary.zig:196`, `src/wire/binary.zig:279`). `readString` fails `Overflow` when the declared length exceeds the caller buffer and leaves `pos` at the payload, so a caller can choose to skip instead (`src/wire/binary.zig:290`). `readStringTruncating` keeps the buffer-sized prefix but still consumes the whole field, so a display string that is longer than its destination does not abandon the fields behind it (`src/wire/binary.zig:89`, test at `src/wire/binary.zig:305`).

`Writer` writes into a caller slice and returns `error.Overflow` rather than growing (`src/wire/binary.zig:113`). It has no allocator and no fallible-free path; sizing is the caller's job through the named `*_size` and `max_*` constants.

## Channel envelope and the two framers

An inbound game message is not a `NetPackage` body: it is the channel envelope `channel u8 | payloadSize i32 | compressed u8 | encrypted u8 | count u16`, then `count` packages of `contentLen i32 | id u16 | body`, where `contentLen` covers the id and body only (`src/wire/frame.zig:98`, pinned by the offset test at `src/wire/frame.zig:257`). `payloadSize` counts bytes after the 9-byte header (`src/wire/frame.zig:136`).

`framePackage` writes the uncompressed single-package form, which is the common S2C path (`src/wire/frame.zig:213`). `packages.framed` resolves the id and channel, then delegates to it (`src/wire/packages.zig:2523`).

The parsed package record (src/wire/frame.zig:28):

```zig
pub const Package = struct {
    id: u16,
    body: []const u8,
};
```

`Package.body` slices either the input buffer or a module-level inflate buffer, so it is valid only until the next `parseChannelPayload` (`src/wire/frame.zig:20`). Compressed C2S envelopes inflate into that storage, capped at 512 KiB absolute and 64x the input size (`src/wire/frame.zig:13`, `src/wire/frame.zig:18`). Nested parses that would need inflate return zero instead of clobbering the outer body (`src/wire/frame.zig:105`). Encrypted payloads are rejected (`src/wire/frame.zig:122`).

Outbound compressed packages use a streaming framer, because the largest one (the `blocks` `NameIdMapping`, roughly 950 KB uncompressed) fits no body buffer (`src/wire/frame.zig:139`).

The streaming deflate framer state (src/wire/frame.zig:151, nested doc comment trimmed):

```zig
pub const DeflateFramer = struct {
    buf: []u8,
    sink: std.Io.Writer,
    comp: flate.Compress,

    /// Window the deflate matcher needs; callers own the storage.
    pub const window_len: usize = flate.max_window_len;
```

Callers must pass a `body_len` to `begin` before the first body byte, then push exactly that many bytes and call `finish`, which patches `payloadSize` with the post-compression count (`src/wire/frame.zig:199`, `src/wire/frame.zig:205`). The 64 KiB window is a buffer size, not a wire divergence: `flate.max_window_len` is twice `flate.history_len`, and the emitted back-reference distance stays inside stock's 32 KiB (`src/wire/frame.zig:351`). Only the six stock `get_Compress`-true package names zdtd emits take this path (`src/server/game/net.zig:111`).

`channelFor` returns 1 for exactly five names (`NetPackageChunk`, `NetPackageChunkRemove`, `NetPackageDynamicMesh`, `NetPackageMapChunks`, `NetPackageWorldFolder`) and 0 otherwise (`src/wire/packages.zig:2514`, `src/wire/packages.zig:2528`). The separate `protocol.zig` root leaf owns the challenge echo (`0xCA` plus 16 GUID bytes), the 20 TPS constants, the wire geometry profile, and the damage-type table; it is imported directly and deliberately not re-exported by `wire` (`src/protocol.zig:10`, `src/protocol.zig:5`).

## Package ids: registry and resolution

`packages.zig` holds one ordered name list. Its index is the numeric package id, and `idOf` is the only lookup (`src/wire/packages.zig:75`, `src/wire/packages.zig:290`).

The registry head (src/wire/packages.zig:27):

```zig
pub const PackageName = enum {
    NetPackagePackageIds,
    NetPackagePlayerLogin,
    NetPackagePlayerLoginAnswer,
    NetPackagePlayerId,
    NetPackagePlayerSpawnedInWorld,
    NetPackageRequestToSpawnPlayer,
    NetPackageEntityPosAndRot,
    NetPackageEntityRelPosAndRot,
    NetPackageEntityAliveFlags,
    NetPackageDamageEntity,
    NetPackageEntityRemove,
    NetPackageSetBlock,
    NetPackageChunk,
    NetPackageWorldTime,
    NetPackageSimpleChat,
    NetPackageEntityLookAt,
    // Extended systems (appended so join ids 0..15 stay stable for fixtures).
    NetPackageQuestObjectiveUpdate,
```

The matching `default_mappings` array (`src/wire/packages.zig:76`) has 191 names (`docs/wire/PACKAGES.md:10`). Ids are dynamic per AGENTS rule 4, so no numeric id may be treated as stable across game versions or builds; the array index is a server-side choice that the client adopts by reading the advertised list. `default_mappings` is advertised verbatim at join (`src/wire/packages.zig:319` writes the mapping table; call site `src/server/game/net_handlers.zig:54`), and it is also the inbound decode table: the dispatch entry point rejects any id at or above the list length and otherwise takes the name from the same index (`src/server/c2s/dispatch.zig:20`, `src/server/c2s/dispatch.zig:25`). There is no per-peer inbound map in this reading; only the outbound id is looked up per send.

A duplicated name is a wire fault, not a typo: `StaticStringMap` would keep one entry and shift every later id. The build rejects it at compile time (`src/wire/packages.zig:270`). `id_map` is built with `initComptime`, so `idOf` cannot allocate (`src/wire/packages.zig:287`).

The advertised version triple is pinned to the 3.2.0 wire and must agree with the login gate (`src/wire/packages.zig:294`):

```zig
pub const VersionInfo = struct {
    release_type: u8 = 1,
    major: i32 = 3,
    /// Raw Minor for the 3.2.0 wire (changelog-3.2.0 §1: minor 10->20,
    /// §8: build 9->10; version.zig `stock_wire_gsi_version` = "V.3.20.10").
    minor: i32 = 20,
    build: i32 = 10,
```

A name absent from the registry returns `null` from `idOf`, and send helpers fail closed rather than inventing an id (`src/server/game/send_extra.zig:21`).

## Body builder convention

Every stock shape has exactly one builder (AGENTS rule 14). The contract is stated in the facade header: `buildXxx*` takes a caller-owned `buf` and returns the written slice, and no builder allocates (`src/wire/packages.zig:5`). `packages.zig` re-exports every `stock_*.zig` module, which `lint-architecture.sh` enforces, so callers import the facade and leaf files stay reachable for the owning domain (`src/wire/packages.zig:1`, `src/server/game/join.zig:513`).

Server-side buffers are preallocated on `Game`: `send_buf` is 256 KiB and `body_buf` is 512 KiB (`src/server/game.zig:456`, `src/server/game.zig:457`). A body that does not fit is an error, not a truncation; the chunk builder reserves its own header bytes and rejects an undersized buffer up front (`src/wire/stock_chunk.zig:852`). The full blocks mapping is the one body that cannot be built into `body_buf`; it streams through `DeflateFramer` instead, and the `IdMapping` send site logs and skips when it would not fit (`src/server/game.zig:2499`, `src/server/game.zig:2520`).

Parse-side entry points live in the same modules as their builders, with the same field order. Rotation is parsed but discarded, and the parser returns `wire_len` because the `bUseQRotation` branch makes the stock body length variable: a relay must forward `body[0..wire_len]` (`src/wire/packages.zig:987`). Coordinates from the wire pass `readWorldF32`, which rejects non-finite and out-of-world values before the simulation sees them (`src/wire/packages.zig:948`, `src/wire/packages.zig:950`).

## Stock body modules by domain

| Module | Domain and representative builders |
|---|---|
| `packages.zig` | Join and motion bodies that have no separate module: `buildPackageIdsBody`, `buildLoginAnswerBody`, `buildPlayerIdBody*`, `buildSpawnedBody`, `buildPosAndRotBody`, `buildRelPosBody`, `buildAliveFlagsBody`, `buildEntitySpeedsBody`, `buildLocalizationBody`, `buildConfigFileBody`, `buildTraderDataStock` (`src/wire/packages.zig:319`, `src/wire/packages.zig:466`, `src/wire/packages.zig:819`, `src/wire/packages.zig:882`) |
| `stock_inv.zig` | `ItemValue`/`ItemStack`/`Bag`/`Equipment` encode and parse: `writeItemValue`, `writeItemStackList`, `writeBag`, `writeEquipment`, `writePlayerInventory`, `buildFromEcsResolved`, `buildBagPackage`, `buildPersistentPlayerState`, `parseBagBody` (`src/wire/stock_inv.zig:111`, `src/wire/stock_inv.zig:210`, `src/wire/stock_inv.zig:273`, `src/wire/stock_inv.zig:749`) |
| `stock_chunk.zig` | `NetPackageChunk` payload: `buildNetPackageChunkNew` plus the density, terrain-id, and water helpers (`src/wire/stock_chunk.zig:852`) |
| `stock_entity.zig` | `NetPackageEntitySpawn` (`EntityCreationData`) and `NetPackageWorldSpawnPoints`: `buildEntitySpawnStock`, `writePlayerProfile`, `writeTraderDataBody`, `buildWorldSpawnPointsBody` (`src/wire/stock_entity.zig:363`, `src/wire/stock_entity.zig:347`, `src/wire/stock_entity.zig:922`) |
| `stock_te.zig` | `NetPackageTileEntity` bodies for storage, sign, workstation, vending, powered trigger, and light, both directions (`src/wire/stock_te.zig:100`, `src/wire/stock_te.zig:583`, `src/wire/stock_te.zig:1245`, `src/wire/stock_te.zig:1517`, `src/wire/stock_te.zig:1861`) |
| `stock_deco.zig` | `NetPackageDecoUpdate` / `DecoResetWorldChunk`: `writeDecoObject`, `buildDecoUpdate`, `buildDecoResetWorldChunk` (`src/wire/stock_deco.zig:68`, `src/wire/stock_deco.zig:95`, `src/wire/stock_deco.zig:660`) |
| `stock_quest.zig` | Quest journal, NPC list, shared quest, and quest events: `writeQuestJournal`, `writeStockQuest`, `buildNpcQuestListFetch`, `buildSharedQuestShare`, `parseQuestEventHead` (`src/wire/stock_quest.zig:247`, `src/wire/stock_quest.zig:166`, `src/wire/stock_quest.zig:149`, `src/wire/stock_quest.zig:338`) |
| `stock_sign.zig` | `NetPackageSignDataResponse` batches: `writeSignData`, `buildSignDataResponseBatch`, capped at 48 KiB per batch (`src/wire/stock_sign.zig:21`, `src/wire/stock_sign.zig:148`, `src/wire/stock_sign.zig:15`) |
| `stock_party.zig` | `NetPackagePartyActions` / `PartyData` / `SharedPartyKill`: `buildActionsBody`, `buildDataBody`, `buildSharedKillBody`, `readActions` (`src/wire/stock_party.zig:62`, `src/wire/stock_party.zig:85`, `src/wire/stock_party.zig:111`) |
| `stock_xp.zig` | Progression bodies: `buildAddExpClientBody`, `buildAddScoreBody`, `buildPlayerStatsBody`, `buildEntitySetSkillLevelBody` (`src/wire/stock_xp.zig:26`, `src/wire/stock_xp.zig:224`, `src/wire/stock_xp.zig:102`, `src/wire/stock_xp.zig:248`) |
| `stock_buff.zig` | `NetPackageAddRemoveBuff` and the `EntityBuffs` blob: `buildAddRemoveBuffBody`, `writeEntityBuffs`, `parseAddRemoveBuff` (`src/wire/stock_buff.zig:100`, `src/wire/stock_buff.zig:60`, `src/wire/stock_buff.zig:116`) |
| `stock_nameid.zig` | The `NameIdMapping` blob carried by `NetPackageIdMapping`: `measure` then `write`, both iterator based and allocation free (`src/wire/stock_nameid.zig:82`, `src/wire/stock_nameid.zig:102`) |
| `platform_user.zig` | `PlatformUserIdentifierAbs` codec used by every package or tile entity carrying an identity: `read`, `skip`, `write`, and the fixed `Stored` record (`src/wire/platform_user.zig:72`, `src/wire/platform_user.zig:89`, `src/wire/platform_user.zig:105`) |
| `te_types.zig` | Stock `TileEntityType` discriminants plus `isStorageLike` / `isSignLike` (`src/wire/te_types.zig:7`, `src/wire/te_types.zig:33`) |

Two structural decisions inside that set are worth naming. Identifier wire is single-form because the five stock subtypes share an empty custom-data tail, so a flat `present | version | platform | id` covers all of them (`src/wire/platform_user.zig:37`). The deco record is 17 bytes, not the stock `decoSize` literal `0x10`, which is declared and never referenced in the assembly (`src/wire/stock_deco.zig:28`).

The named shapes commonly inspected while changing this subsystem. First, the encoded slot record (`src/wire/stock_inv.zig:45`, comments trimmed here):

```zig
pub const StockSlot = struct {
    type_id: i32 = 0,
    count: u16 = 0,
    quality: u16 = 0,
    meta: u16 = 0,
    use_times: f32 = 0,
    seed: u16 = 0,
    flags: u8 = 0,
    ammo_index: u8 = 0,
    mods: [4]u16 = .{0} ** 4,
    mod_n: u8 = 0,
    mod_qualities: [4]u8 = .{0} ** 4,
    stats: [max_item_stats]StatEntry = .{StatEntry{}} ** max_item_stats,
    stats_n: u8 = 0,
};
```

The matching wire widths are pinned at compile time against the ECS subset (`src/wire/stock_inv.zig:36`): toolbelt 10, bag 45, equipment 12 (`src/wire/stock_inv.zig:23`, `src/wire/stock_inv.zig:30`, `src/wire/stock_inv.zig:33`). The deco object record (`src/wire/stock_deco.zig:59`):

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

Stock's `DecoObject::Write` packs the position into a `u64` through `vector3iToU64`, which is why six fields occupy 17 bytes (`src/wire/stock_deco.zig:52`). The buff value record (`src/wire/stock_buff.zig:23`, comments trimmed here):

```zig
pub const BuffValueWire = struct {
    name: []const u8,
    stack_mult: u8 = 1,
    duration_ticks: u32 = 0,
    instigator_id: i32 = -1,
    flags: u8 = 0,
    update_ticks: u16 = 0,
    instigator_x: i32 = 0,
    instigator_y: i32 = 0,
    instigator_z: i32 = 0,
};
```

The version written is 3 (`src/wire/stock_buff.zig:11`), and the cvar section of the blob is written empty because zdtd holds no cvars (`src/wire/stock_buff.zig:49`).

## Fail-closed encode rules

The governing rule is AGENTS rule 24: if a body cannot be built correctly, omit it or send the stock empty or error form. Never truncate mid-field, zero-pad to a guessed size, or desync the client's `BinaryReader`. The code follows it in several distinct ways.

Buffer exhaustion is an error at the builder, not a short body. `Writer.ensure` returns `Overflow` before any byte moves (`src/wire/binary.zig:113`), and `DeflateFramer.begin` rejects a buffer it cannot complete rather than emitting a partial frame (`src/wire/frame.zig:167`, test at `src/wire/frame.zig:396`).

A mapping blob is all-or-nothing. A truncated blob does not disable the client mapping: `LoadFromArray` swallows the failure and leaves the mapping live, so `AssignIds` renumbers every block the blob failed to name, silently (`src/wire/stock_nameid.zig:11`). `measure` therefore rejects an empty name, an over-long name, an out-of-range id, a duplicate id, and a header/row mismatch before any byte is written, and `write` re-checks the count it promised (`src/wire/stock_nameid.zig:82`, `src/wire/stock_nameid.zig:102`).

A body whose item must be real is not faked. `NetPackageEntitySpawnResponse` dereferences `ItemValue.ItemClass` on the client, so an empty sentinel there is a null dereference; the builder is only used on place or throw, never on join (`src/wire/packages.zig:901`).

An identity is never truncated. `Stored.set` rejects an over-long platform or id instead of cutting it, because two accounts collapsing onto one identity is worse than a rejected packet (`src/wire/platform_user.zig:112`). `readString` likewise fails rather than silently shortening a parsed value (`src/wire/binary.zig:74`).

Where a value is informational rather than structural, the code chooses the aligned variant explicitly: `readStringTruncating` keeps a display prefix and still consumes the field, so the reader stays positioned for what follows (`src/wire/binary.zig:83`).

## See also

- [LiteNet transport](litenet.md)
- [Inventory and item wire](inventory.md)
- [Chunk streaming](chunk-stream.md)
- [Quests](quests.md)
- [NetPackage catalog](../wire/PACKAGES.md)
- [Architecture, net stack and framing](../ARCHITECTURE.md)
