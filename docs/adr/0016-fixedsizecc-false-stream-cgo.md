# ADR 0016: fixedSizeCC=false + stream radius for CGO / terrain textures

- **Status:** accepted
- **Date:** 2026-08-05
- **Related:** [WIRE_CHUNK.md](../wire/WIRE_CHUNK.md), [../7dtd-research/docs/protocol-packages.md](../../../7dtd-research/docs/protocol-packages.md) §4.2

## Context

Stock `NetPackageWorldInfo` carries `fixedSizeCC`. Two client outcomes:

| `fixedSizeCC` | Client chunk provider | Overlay / CGO | Terrain floor |
|---|---|---|---|
| **true** | `ChunkProviderDummy` | CGO thr=0 (overlay closes fast) | No splat load → grey MicroSplat clay |
| **false** | `ChunkProviderGenerateWorldFromRaw` | Needs CGO ≥ viewDist²−10 | Loads `splat*.png` from world data |

Early join experiments used `true` to clear "Starting game..." quickly, then hit a grey floor and Dummy provider. Stream radius also couples to mesh: only the **inner** ring (radius minus ~2) becomes displayed GOs; r=4 caps CGO ≈25, which fails viewDist 7 (need ≥39).

## Decision

1. **Always send `fixedSizeCC=false`** in `buildWorldInfoBody` for stock maps and default play. Do not toggle per world without a documented Dummy-only use case.
2. **Default stream ring r 7..9** (`default_chunk_stream_radius_*`), with enough adds/tick and `max_streamed` so meshable core clears the overlay gate (CGO needs r≥6 at viewDist 7).
3. Prefer this over client workarounds (connect mod inventing terrain or skipping the gate).

## Consequences

- Join must stream more chunks before play; 50 ms tick holds named stream caps.
- Terrain floor textures work when the operator install has splat assets for the level.
- `fixedSizeCC=true` remains a known footgun: do not reintroduce for "faster overlay" without accepting Dummy + grey floor.

## Alternatives considered

| Option | Notes |
|---|---|
| fixedSizeCC=true always | Overlay closes; grey floor; Dummy provider |
| fixedSizeCC=false + r=4 | CGO stuck below thr; hang on "Starting game" |
| Client-side splat injection | Violates clean-room / server-owns-gaps policy |
