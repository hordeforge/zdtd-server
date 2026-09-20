# Decoration suppression (AllowDecorations) - Technical Proposal (RFC 0007)

**Number:** RFC 0007
**Status:** decided (shipped 2026-09-12), with one realization change
**Source:** `PRD 0007` - the requirements this answers

## 1. Decision to make

Which spatial structure gates the deco sampler against POI footprints so
the V3.2.0 `AllowDecorations` behavior lands without blowing the 50 ms
tick / join-burst budget?

## 2. Current state (at proposal time)

`AllowDecorations` is parsed into `QuestData` (`world/prefabs.zig`,
2026-08-28). Before this RFC shipped, the deco sampler (`sendDecoAroundSpawn`
and the streamed-deco path in `server/game/join.zig`) called a biome species
callback per sample cell with no POI awareness. The prefab index has
`boundsXZ(i)` (O(1) per decoration) and a linear `items` walk; a stock map
ships ~1500 POIs, and the join burst samples thousands of cells, so a
per-cell linear scan is O(cells x POIs) and out of budget.

## 3. Options considered

### Option A: linear POI scan per sample cell

For each deco sample, walk the prefab index and stop at the first
footprint containing the cell; skip unless `allow_decorations`.

- Pros: no new structure.
- Cons: ~1500 rect tests per sample cell; the join burst (thousands of
  cells) becomes millions of tests. Fails the budget goal.

### Option B: chunk-keyed POI footprint bitmap (recommended)

Build once at prefab load (or lazily per chunk): for each chunk that
intersects a POI footprint, store the set of POI rects (or a per-cell
bitmap of "in-POI-without-allowance"). The sampler looks up its chunk's
entry: O(1) per sample.

- Pros: O(1) per sample after a one-time build; deterministic; reuses the
  existing chunk-key space; the build is amortized into prefab load.
- Cons: memory for the footprint map (bounded: one rect list per touched
  chunk; a 4k map touches ~60k chunks, each holding a handful of rects);
  the bitmap needs invalidation if POIs change (they do not at runtime).

### Option C: plugin/query surface for suppression

A plugin decides per position.

- Pros: custom suppression policies.
- Cons: a Wasm call per deco sample cell is a hot-path budget decision,
  and the stock policy is a prefab XML property, which is data-shaped.
  The boundary extension belongs with a future `DecoSuppressArea` dynamic
  surface, not the static property.

## 4. Recommendation

Option B. Build a chunk-keyed footprint map at prefab load: for each
decoration (skipping `isPart`), mark the chunks its bounding box covers
with the decoration rect; the sampler's species callback consults the map
for its chunk and skips when the cell is inside a footprint whose
`AllowDecorations` is false. The map is built once (prefab load, allowed
to allocate), read on the hot path with no allocation, and keyed by the
same chunk coords the stream already uses. `AllowDecorations="true"` skips
the gate for that POI.

Order: footprint map in `world/prefabs.zig`, gate in the deco sampler
callbacks, scenario covering both property states, apm check on the join
burst.

## 5. Open questions

Resolved in §6 (2026-09-12):

- Does the stock sampler test the full AABB or the rotated footprint?
  Answered by existing `boundsXZ`, which swaps axes for rotations 1/3; the
  AABB is the rotated footprint as stock's decorator uses it.
- Should the gate apply to the streamed-deco path identically to the join
  burst? Yes: both go through the single `decoSpeciesAt` resolver.

## 6. What shipped (2026-09-12)

Option B, realized **lazily per 128-block deco chunk** rather than as an eager
map built at prefab load. The reason is the same one that makes the eager map
attractive: the footprint filter needs each prefab's `AllowDecorations`, which
lives in the prefab XML that `world/prefabs.zig` reads lazily and caches. An
eager build would read all ~1487 prefab XMLs at boot; the lazy build reads only
the prefabs that intersect a deco chunk the sampler actually walks.

- `world/prefabs.zig` `collectDecoSuppressors(region, out)`: one pass over the
  decoration list for the region, skipping `isPart`, keeping the footprints
  whose quest data does not opt in.
- `server/game/deco.zig` `SuppressCache`: eight direct-mapped entries keyed by
  the deco-chunk key (the sampler walks one deco chunk at a time), each holding
  up to 16 rects; an entry that fills the rect cap increments `saturated` so
  partial suppression is visible instead of assumed complete. `decoSuppressedAt`
  is a key lookup plus a few rect tests per sample cell, no allocation.
- The gate sits in the single `decoSpeciesAt` resolver, so both the join burst
  and the streamed-deco path (RFC §5 second question) are covered; the
  duplicated local copy in `server/game/join.zig` was removed in the same
  change, so the tests that call `Game.decoSpeciesAt` now exercise the live
  resolver instead of a stale copy.

`RFC §5` first question (axis-aligned vs rotated containment) is answered by
the existing `boundsXZ`, which already swaps the axes for rotations 1/3, so the
AABB is the rotated footprint as stock's decorator uses it.

Gates: `world.prefabs` unit test (both property states, part skip, region miss,
cap truncation) and the Navezgane integration test (a real non-opted-in POI is
suppressed, its sampler yields no species, 4000 blocks away is not suppressed,
and the map ships both kinds).
