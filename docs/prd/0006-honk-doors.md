# Vehicle horn opens trader doors — Product Requirements (PRD 0006)

**Number:** PRD 0006
**Status:** draft

## 1. Background and problem

Stock V3.2.0 (changelog-3.2.0 §4.1) lets a vehicle horn open trader outer
doors: `TEFeatureDoor` gained `PropHonkOpenType`/`PropHonkOpenDistance`,
`TraderDoorController` detects vehicles in the door trigger volume and
`EntityVehicle.UseHorn` plays the horn and fires the honk game event.
zdtd has no door simulation at all: doors are static blocks, nothing holds
their open/closed state, and no C2S or S2C path touches them. The 3.2.0
feature cannot exist until a minimal door TE exists, and the policy
(which doors honk-open, at what distance) needs a config surface.

## 2. Personas

Server operators who want stock-faithful trader-door behavior (drive up,
honk, doors open) without client mods, and modpack authors who tune door
behavior through `zdtd.toml` / mode packs.

## 3. Goals

1. A minimal door TE (open/closed state, lockable state) that survives the
   world tick and persists.
2. Vehicle-horn detection: a driver honking within the configured distance
   of a door actuates it per the door's honk-open type.
3. Config surface: `[rules.vehicle] honk_open_doors` (enum: none, trader,
   trader_outer, land_claim, both, all) and `honk_open_distance` (m),
   defaulting to stock-faithful behavior.
4. The actuation broadcasts the resulting door state to observers (interest
   gated), never a client-originated state.

## 4. Scope

### In scope (MVP)

- Door TE: open state + locked state, spawned for door blocks with door TEs.
- Vehicle honk signal (the vehicle sim raises the honk event on driver input).
- TraderDoorController equivalent: proximity + honk gate, actuate per
  honk-open type.
- `[rules.vehicle] honk_open_doors` / `honk_open_distance` (auto-bound).
- Interest-gated door-state broadcast.

### Out of scope

- Door lock/ownership UIs, lock picking, player door interactions beyond
  the horn.
- Per-door `PropHonkOpenType`/`PropHonkOpenDistance` XML parsing
  (the fixed `HonkOpenTypes` enum + global distance cover stock behavior).

## 5. Design notes

See [RFC 0006](0006-honk-doors.md). The policy decision (which doors
honk-open) is config-shaped; a plugin verdict is reserved for
departures-from-stock custom rules.

## 6. Requirements traceability

G1 -> RFC 0006 §4; G2 -> RFC 0006 §4; G3 -> RFC 0006 §4; G4 -> RFC 0006 §4.

## 7. Open questions

See [RFC 0006 §5](0006-honk-doors.md).

## 8. Acceptance criteria

- A vehicle with a driver honking within `honk_open_distance` of a
  trader-area door opens it; the state reaches observing clients.
- Honk-open type "none" never opens doors; "trader" opens only
  trader-area doors.
- Doors do not open without a driver.
- The door state round-trips a server restart.
- `zig build test` green; a scenario covers horn-open and the type gate.
