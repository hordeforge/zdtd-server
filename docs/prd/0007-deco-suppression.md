# Decoration suppression (AllowDecorations) — Product Requirements (PRD 0007)

**Number:** PRD 0007
**Status:** draft

## 1. Background and problem

Stock V3.2.0 (changelog-3.2.0 §4.5) separates the world-deco-inside-POI
opt-in from the TraderArea setting: a new prefab `AllowDecorations`
property (replacing the removed `AllowTopSoilDecorations`) controls whether
biome world decorations spawn inside the POI's footprint. zdtd already
parses `AllowDecorations` into prefab quest data (2026-08-28), but the
deco sampler (`sendDecoAroundSpawn` / the streamed-deco path) has no POI
footprint gate, so biome trees can currently spawn inside POI buildings.

## 2. Personas

Server operators running stock maps who expect POI interiors to stay clear
of world trees, and modpack authors who set `AllowDecorations` on custom
POIs.

## 3. Goals

1. World (biome) decorations are suppressed inside a POI footprint unless
   the POI declares `AllowDecorations="true"`.
2. The gate is deterministic and bounded: it must not make the join deco
   burst or the per-tick stream scan all POIs per sample cell.
3. Stock POIs (which do not set the property) keep the stock default:
   no world deco inside the footprint.

## 4. Scope

### In scope (MVP)

- POI footprint lookup on the deco sampler with an O(1) (or O(chunk))
   gate, built once at prefab load.
- `AllowDecorations="true"` opts the POI into world deco inside its
  footprint.
- Deterministic across the join burst and the streamed-deco path.

### Out of scope

- The `DesignatedAreaStore` / `DecoSuppressArea` dynamic runtime areas
  (the 3.2.0 companion types for mod-driven suppression); those are a
  follow-up if a plugin surface wants them.

## 5. Design notes

See [RFC 0007](0007-deco-suppression.md).

## 6. Requirements traceability

G1 -> RFC 0007 §4; G2 -> RFC 0007 §4; G3 -> RFC 0007 §4.

## 7. Open questions

See [RFC 0007 §5](0007-deco-suppression.md).

## 8. Acceptance criteria

- A POI without `AllowDecorations` gets no world-deco species inside its
  bounding box on the join burst or the stream path.
- A POI with `AllowDecorations="true"` does.
- The deco burst wall-clock does not regress beyond the apm budget on a
  stock map (the gate must not scan 1000+ POI rects per cell).
- `zig build test` green; a scenario covers both property states.
