# DecoManager.Read NRE (V3.1.x client): RESOLVED

## Verdict

**Not a wire-format bug.** zdtd's `DecoObject` encoding is byte-exact against
stock. The NRE was a **lifecycle** bug: the client has exactly one window for
server deco, at join, and zdtd was sending incremental packages after it closed.

Trees now ship in a single join-time burst (`Game.sendDecoAroundSpawn`), gated by
`[feature] deco_trees` and a fail-closed AssignIds id resolve.

## Root cause (IL, `Assembly-CSharp.dll` V3.1.x)

| Site | Fact |
|---|---|
| `DecoManager::Read` (asm.il 1260645-1260692) | `if (_resetExisting) loadedDecos = new HashSet<DecoObject>(); n = ReadInt32(); for(i<n){ d = new DecoObject(); d.Read(br); loadedDecos.Add(d); }` |
| `Read` IL_0027 + IL_002d | `ldfld loadedDecos` + `callvirt HashSet::Add`, the **only** deref in the method. NREs iff `_resetExisting == false` **and** `loadedDecos == null`. With `n == 0` the loop body never runs, which is why the old empty firstPackage was safe. |
| `DecoManager/'<OnWorldLoaded>d__36'::MoveNext` IL_045f..IL_04aa (asm.il 1258958-1259546) | `if (loadedDecos != null)` → drain every entry through `addLoadedDecoration` → **`loadedDecos = null`** (IL_04aa, asm.il 1259485). Nothing else ever refills or drains it. |
| `DecoManager::TryLoad` (asm.il 1260396-1260500) | returns false immediately on a client (`ConnectionManager.Instance.IsServer` false) without touching the field. |

So on a client `loadedDecos` is null before the first DecoUpdate and null again
after world load:

- `firstPackage=false` + count>0 **after** world load → NRE at `Read` IL_002d.
- `firstPackage=true` + count>0 after world load → no NRE, but the objects land
  in a set nothing reads. No trees, silently.

zdtd's old `sendDecoForTerrainChunk` (per streamed terrain chunk) was
architecturally impossible and has been deleted, along with the per-client
`deco_streamed` / `deco_first_sent` bookkeeping it fed.

## Stock send point

`DecoManager::SendDecosToClient` (asm.il 1263272-1263324) is called from exactly
**one** site in the whole assembly: `GameManager/'<RequestToEnterGame>d__194'::MoveNext`
IL_02c2 (asm.il 1865105), right after `NetPackageWorldInfo` and before
`NetPackageChunkClusterInfo`. It loops `NetPackageDecoUpdate.Setup(decoWriteList, ref idx)`
until `idx == count`, i.e. N packages back to back: first `firstPackage=true`,
rest `false`. zdtd sends at the same point in its `RequestToEnterGame` handler.

## Wire format (confirmed byte-exact)

| Element | Bytes | Source |
|---|---|---|
| `NetPackageDecoUpdate` body | `firstPackage:bool` \| `dataLen:i32` \| `count:i32` \| objects | `write` asm.il 808338-808372, `Setup` 808303-808388 |
| `DecoObject` record | `u64` packed pos \| `f32` realYPos \| `u32` bv.rawData \| `u8` state = **17 B** | `DecoObject::Write` asm.il ends 1264030, `Read` ends 1264056 |
| packed pos | `((x+0x8000)&0xFFFF)<<32 \| ((y+0x8000)&0xFFFF)<<16 \| ((z+0x8000)&0xFFFF)` | `GameUtils::Vector3iToUInt64` asm.il 1920920-1920955 |
| objects per package | `decosPerPackage = 0x8000` (32768), used literally at `Setup` IL_000b | asm.il 808291 |

**Correction to earlier notes:** the stock `NetPackageDecoUpdate.decoSize = 0x10`
literal (asm.il 808289) is **declared and never referenced anywhere in the
assembly** (`grep decoSize` finds only the declaration and an unrelated
`EnumDecoAllowedSize` parameter). It is a stale estimate. The real record is
**17 bytes**; `stock_deco.deco_size` uses 17.

zdtd emits at most `stock_deco.zdtd_decos_per_package = 4096` objects per package
(~68 KiB body) so a package frames inside `Game.send_buf` (256 KiB).

## Hard prerequisite: block ids must resolve on the client

There is no benign fallback for an unknown deco block id. `BlockValue::get_Block`
is `Block.list[rawData & 0xFFFF]` (asm.il 140325); the slot may be null, and:

1. `DecoManager::addLoadedDecoration` (asm.il ends 1262420) calls
   `TryAddToOccupiedMap(bv.Block, ...)` for any `state != Dynamic`, and
   `TryAddToOccupiedMap` starts `IL_0008: ldarg.1; IL_0009: ldfld bool Block::isMultiBlock`
   (asm.il 1262497) with **no null check** → NRE.
2. `DecoChunk/'<UpdateModels>d__21'::MoveNext` calls `DecoObject::GetModelName()`
   (null for a null Block) then `Dictionary<string,_>.TryGetValue(null)` →
   `ArgumentNullException`.

Both abort the client's world-load coroutine and leave the player stuck loading,
which is strictly worse than a bald world. Hence `Game.decoTreeIds` resolves
`treeOakSml01` / `treeDeadTree02` through runtime `maxdamage.idByName` and returns
null (→ empty firstPackage, log once) if either name is missing or resolves to 0.

## State is forced to 0

`DecoState { GeneratedActive=0, GeneratedInactive=1, Dynamic=2 }` (asm.il
1264157). `state=2` would skip the unguarded `TryAddToOccupiedMap`, but
`DecoChunk::RestoreGeneratedDecos` (asm.il ends 1258023) **removes** state-2
decos, and that runs from `ResetDecosForWorldChunk`. zdtd sends
`GeneratedActive` (0), matching `decorateChunkRandom`'s `Init(pos, realY, bv, 0)`
(asm.il 1261790).

## DecoResetWorldChunk on view unload: removed

Stock only broadcasts `NetPackageDecoResetWorldChunk` from
`ResetDecosForWorldChunk`, whose non-deco callers are `RegionFileManager` chunk
deletion (asm.il 1186504) and the C2S reset handler (asm.il 807955), never on
client view unload. zdtd was sending it on every streamed-chunk eviction. It is
now only sent when `deco_trees` is off (no objects in flight to disturb).

## What ships

- `Game.sendDecoAroundSpawn(c, peer, wx, wz)` at `RequestToEnterGame`: resolve ids
  → generate per terrain chunk over the join view square → stream through
  `stock_deco.PackageWriter` (first `true`, continuations `false`).
- Covered window = the same chunk radius `streamChunksForClient` uses
  (`view_radius` clamped to `chunk_stream_radius_{min,max}` and to
  `max_streamed_chunks`), so `heightWorld`'s `getOrCreate` only touches chunks the
  join streams anyway. Default r=6..7 → ~1.5k objects, one package, ~25 KiB.
- Kill switch: `[feature] deco_trees = false` → today's empty firstPackage.

## Honest gaps

1. **One-shot window.** Anything outside the covered radius is permanently bald
   for the session, and stays bald because the same package makes the client mark
   every `DecoChunk` `isDecorated = true` (that loop is inside the
   `loadedDecos != null` branch, IL_04b1..IL_0528) while `decorateChunkRandom`
   early-returns on a fixed-size world (asm.il 1261400). Sending the whole
   6144×6144 map at this density would be ~1.3M objects / ~22 MB at join.
2. **No client id negotiation.** Ids come from the bundled V3.1.4 AssignIds dump,
   not the connected client. `idByName` fails closed only when the *name* is
   absent from our dump; it cannot detect that a modded / different-version client
   computed a different id for the same name. On skew the client throws inside its
   world-load coroutine. zdtd sends no `blocks` `NameIdMapping` (it sends the
   `blocks` config with payload length -1 → `EClientFileState.LoadLocal`), and
   adding one is a separate change. Use the kill switch on non-V3.1.x clients.
3. **Server does not mirror the client writeback.** `ChunkCluster::LightChunk` →
   `addDistantDecorationBlocks` (asm.il 1122638) pulls
   `DecoManager.GetDecorationsOnChunk` and `SetBlockRaw`s the tree into the
   client's chunk. The zdtd world store has air there, so client-side collision
   and harvest targets exist that the server does not know about
   (`treeOakSml01` is `MultiBlockDim 1,7,1`, `BigDecorationRadius 4`;
   `treeDeadTree02` is single-block). Mirroring deco into the world store is a
   larger separate change.
4. **Density / species are not stock.** `generateAroundIds` is a deterministic
   xorshift hash over two species. Stock drives placement from
   `BiomeDefinition.m_DistantDecoBlocks`, Perlin resource noise, per-biome
   probability and occupied-map rejection (1000 attempts per 128×128 deco chunk).
   Plausible deterministic trees, not stock-equivalent ones.
5. **Live-validated 2026-08-05** against a stock **V3.0.1 b4** client:
   server `DecoUpdate objs=1488 pkgs=1 r=6 oak=24629 dead=24626`, client
   `[DECO] read 1488`, **0 exceptions** in the client log, and world load
   completes (`Chunks: 226 CGO: 90`, past the `viewDist^2-10 = 39` gate). The
   17 byte `DecoObject` record and the single join-window lifecycle are
   confirmed on the wire, not just in IL.
   That run also surfaced an unrelated server crash on the same path: a Merged
   datagram reaching `Server.drainControl` made `Peer.pushExtra` `@memcpy` a
   slice onto itself (`popExtra` reclaims `extra_used` to 0 when the queue
   drains), panicking with "arguments alias" so no chunk ever streamed. Fixed
   in `litenet/peer.zig` with an overlap-aware copy plus a regression test.
   Still unproven: a **V3.1.x** client (ids come from the bundled V3.1.4 dump,
   and there is no client id negotiation, see A22).

## Block ids used

`blocks.xml`: `treeMaster` (line 1476) sets `Shape=DistantDecoTree`, a `Model`
prefab, `IsDistantDecoration=true`, `Class=ModelTree`, satisfying the
`Block.shape isinst BlockShapeDistantDeco` check in
`DecoObject::CreateGameObjectCallback` IL_0032. `treeDeadTree02` (76609) and
`treeOakSml01` (76654) both `Extend treeMaster` and override `Model`.
Dump ids: `treeOakSml01` 24629, `treeDeadTree02` 24626
(`src/assets/assignids_v314.embed.txt` lines 24411 / 24408).

## A08/A22 pin labels

`Game.decoTreeIds` is the live path and uses runtime `idByName` only. The numeric
constants in `stock_deco.zig` / `assignids_comptime.zig` are offline/test labels
(CI-checked against the dump) and are never sent.
