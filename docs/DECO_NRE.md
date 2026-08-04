# DecoManager.Read NRE (V3.1.0 client)

## Symptom

Sending `NetPackageDecoUpdate` with object payloads causes
`NullReferenceException` in `DecoManager.Read` on stock V3.1.0 (EAC off). Empty
`firstPackage=true` with zero objects is safe and required so the client can
allocate deco state after world load.

zdtd policy: **empty firstPackage only** until wire matches client Read
(`src/server/game.zig` `sendDecoAroundSpawn`).

## RE ground truth

| Source | Fact |
|---|---|
| `7dtd-research/docs/protocol-packages.md` § NetPackageDecoUpdate | `firstPackage:bool` + `dataLen:i32` + payload (`count:i32` + objects) |
| `7dtd-research/docs/chunk-providers.md` §5 DecoObject | Write order: `packedPos:u64`, `realYPos:f32`, `bv.rawData:u32`, `state:u8` |
| zdtd `wire/stock_deco.zig` | Same field order via `writeDecoObject` |

Payload layout appears correct. NRE is likely **lifecycle**, not field order:

1. Client calls `DecoManager.Read(reader, int.MaxValue, firstPackage)` under lock.
2. `firstPackage=true` must run when DecoManager exists and occupied maps are ready
   (after world load / Init path), not only after random mid-stream packages.
3. Object payloads may require prior `NameIdMapping` / block registry entries for
   the deco block ids (tree AssignIds) that the client has not finished applying.
4. Incremental (`firstPackage=false`) packages may assume per-chunk buckets already
   created by the first package.

## What to RE next (in 7dtd-research, not zdtd)

1. Dump `DecoManager.Read` IL for V3.1.0 b14: null deref site (loadedDecos,
   occupied map, NameIdMapping, chunk bucket).
2. Capture stock dedi join: order of DecoUpdate vs WorldInfo / chunks / id map.
3. Confirm whether firstPackage payload may be empty then objects only on later
   packages once `OnWorldLoaded` finished.
4. Test tree block ids: only blocks with `BlockShapeDistantDeco` + Model; wrong
   class may NRE on instantiate after Read succeeds.

## zdtd when unblocked

1. Keep empty firstPackage at join (current).
2. After client has entered + id map + first chunks, send incremental DecoUpdate
   with `generateAroundIds` using live `idByName` oak/dead pins.
3. Cap objects per package; never send before `entered`.
4. Unit test: golden firstPackage empty + one-object incremental layout.

## A08/A22 pin labels

Module pins in `stock_deco.zig` / assignids_comptime remain for offline tests.
Live stream must use runtime AssignIds only. Labels stay documented until object
payloads are safe.
