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
which is strictly worse than a bald world. Hence species are resolved before
send: `assets/biome_layers.zig` keeps only `<decorations>` rows whose block name
resolves through runtime `maxdamage.idByName` and carries `IsDistantDecoration`,
and `Game.sendDecoAroundSpawn` falls back to the empty firstPackage (log once)
when no species resolve.

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

- `Game.sendBlockIdMapping(peer)` at `RequestToEnterGame`, immediately **before**
  `sendLocalConfigFiles`: the full AssignIds dump as a `blocks` `NameIdMapping`,
  so the client's `Block::AssignIds` uses our ids instead of computing its own.
  Same slot stock uses (`'<RequestToEnterGame>d__195'::MoveNext` IL_01e3,
  asm.il 1872978), because the client only runs `AssignIds` after the ConfigFile
  package (`'<LoadBlocks>d__16'::MoveNext` IL_0058, asm.il 2014542).
  Kill switch: `[feature] block_id_mapping = false`.
- `Game.sendDecoAroundSpawn(c, peer, wx, wz)` at `RequestToEnterGame`: iterate the
  128x128 deco chunks intersecting the join view square, run
  `stock_deco.generateForDecoChunk` on each, mirror every placed object into the
  block store, stream through `stock_deco.PackageWriter` (first `true`,
  continuations `false`).
- Species and density come from biomes.xml. `assets/biome_layers.zig` parses each
  biome's own `<decorations>` group (the one outside `<subbiome>`, which is what
  `IBiomeProvider::GetBiomeOrSubAt` resolves to for most cells), keeps only
  `type="block"` rows whose block resolves *and* carries `IsDistantDecoration`
  after `Extends` resolution, and stores `prob` unscaled. That filter is what
  keeps grass out: `treeShortGrass` sits at prob .85 but extends
  `treeGrassMaster`, which does not set the flag.
- Covered window = the same chunk radius `streamChunksForClient` uses
  (`view_radius` clamped to `chunk_stream_radius_{min,max}` and to
  `max_streamed_chunks`), so `heightWorld`'s `getOrCreate` only touches chunks the
  join streams anyway. Objects are capped at `deco_objects_per_join` (8192).
- The mirror (`world/deco_mirror.zig`, `[feature] deco_mirror`) writes each object
  through `Chunk.setBlockDecoRaw`, which deliberately does **not** move the
  terrain surface height: `heights` feeds spawn placement, void rescue, movement
  validation and the deco height callback itself, and a 7 tall tree would push the
  column surface to the treetop.
- Kill switch: `[feature] deco_trees = false` → today's empty firstPackage.

## Honest gaps

1. **One-shot window.** Anything outside the covered radius is permanently bald
   for the session, and stays bald because the same package makes the client mark
   every `DecoChunk` `isDecorated = true` (that loop is inside the
   `loadedDecos != null` branch, IL_04b1..IL_0528) while `decorateChunkRandom`
   early-returns on a fixed-size world (asm.il 1261400). Sending the whole
   6144×6144 map at this density would be ~1.3M objects / ~22 MB at join.
2. **Id negotiation is unproven on a live client.** The `blocks` mapping ships and
   is byte-checked against `NameIdMapping::SaveToWriter` / `LoadFromReader`, but
   no zdtd test can catch a wrong outcome: encode and decode share code, and the
   failure mode is silent. `LoadFromArray` swallows every exception
   (asm.il 1178553), leaves `Block.nameIdMapping` non-null, and
   `assignIdsFromMapping` + `assignLeftOverBlocks` then renumber whatever the blob
   failed to name, with no client-side error. The builder is therefore
   all-or-nothing: any validation failure, an empty dump, or a compressed frame
   that does not fit skips the package and leaves the old LoadLocal behaviour.
   Validation still needs a live V3.1.x run reading the client log for
   "Received mapping data for: blocks", then "Block IDs with mapping", then a sane
   "Block IDs total {0}, terr {1}, last {2}".
   Sizes measured from the bundled dump: 24808 rows, 953,013 raw bytes,
   ~260 KB after raw deflate (~198 reliable fragments). The frame is built in
   `body_buf` (512 KiB), not `send_buf` (256 KiB), for headroom.
3. **The mirror is not the full stock writeback.** `world/deco_mirror.zig` matches
   `addDistantDecorationBlocks` for what zdtd can represent: single blocks into
   air only, multiblock parent plus `ischild` children with negated parent
   offsets, skip when the anchor is already a decoration. It does not write
   stability 15 (no stability plane) and does not re-apply density explicitly
   (the cell's density is simply left alone, which is what
   `SetDensityRaw(previous)` amounts to). Rotation is always 0, so the child
   offsets are the axis-aligned `MultiBlockDim` box.
4. **Sampling is stock-shaped, not stock-identical.** `generateForDecoChunk`
   reproduces the 128x128 deco chunk, the 1000 attempts, the 5x5 keep-out, the
   last-to-first species walk and the `prob * 0.125f * 16f` accept rule. It does
   not reproduce `GameRandom` (a splitmix64 seeded from world seed + deco chunk
   coords stands in), does not evaluate `CheckOreNoiseAt` (no server-side resource
   Perlin, and every `checkresource` row in stock biomes.xml is a `type="prefab"`
   row zdtd does not send anyway), does not grade occupancy by
   `BigDecorationRadius`, and does not evaluate subbiome noise.
   Consequence worth knowing before an operator files a bug: this is materially
   **sparser** than the old flat `deco_every_n = 29`. Stock's main-biome
   distant-deco probabilities are tiny (pine_forest's own group has
   `treeJuniper4m` at prob .001), because stock's dense forests come from the
   world generator baking trees into chunks, not from `decorateChunkRandom`.
   The burst now shows what biomes.xml actually asks for.
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

`Game.decoSpeciesAt` is the live path: biome map → biomes.xml `<decorations>` →
runtime `idByName`, never a pinned constant. The numeric constants in
`stock_deco.zig` / `assignids_comptime.zig` are offline/test labels (CI-checked
against the dump) and are never sent.
