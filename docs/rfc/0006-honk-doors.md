# Vehicle horn opens trader doors — Technical Proposal (RFC 0006)

**Number:** RFC 0006
**Status:** draft
**Source:** `PRD 0006` — the requirements this answers

## 1. Decision to make

Which minimal door simulation and honk signal do we adopt so the V3.2.0
horn-opens-trader-doors behavior can exist, and where does the policy live?

## 2. Current state

zdtd has no door simulation. Doors are static blocks in the world store;
nothing holds an open/closed state, and no C2S or S2C package touches a
door's state. The vehicle sim (`ecs/systems.zig vehicleControl`) moves
hulls and drains fuel but has no horn concept. The power/trigger TE system
(`ecs/electric.zig`) actuates consumers by entity id but has no door
affordance and no proximity detection. Config: `[rules.vehicle]` exists
(accel, steer, fuel) and `toml_bind` auto-binds new fields.

## 3. Options considered

### Option A: client-side relay only (status quo plus horn echo)

Treat doors as client-animated; the server just echoes a horn event to
nearby peers so their clients play the stock door animation. No door state
on the server.

- Pros: smallest change; matches the client-interpolated door look.
- Cons: no authority (a modified client can animate doors anywhere), no
  lock gating, no persistence, and the stock feature's `TraderDoorController`
  is explicitly server-side (dedicated IL). Fails the server-authoritative
  rule for state the client displays.

### Option B: minimal server door TE + honk event + config gate (recommended)

A minimal door TE: `open: bool`, `locked: bool` per door block that declares
a door TE. The vehicle sim raises a honk event when a driver honks. A
TraderDoorController pass each tick finds doors within `honk_open_distance`
of honking vehicles whose honk-open type admits the door (trader-area doors
for "trader"/"trader_outer"/"both", land-claim doors for
"land_claim"/"both", all doors for "all") and toggles them, broadcasting
the resulting state interest-gated.

- Pros: server-authoritative, persistent, stock-faithful (the stock
  controller is server-side), policy is config-shaped
  (`[rules.vehicle] honk_open_doors` enum + `honk_open_distance`).
- Cons: needs the door TE subsystem (the real cost); door-open wire shape
  must match what the stock client reads (RE of the door state package
  needed).

### Option C: plugin verdict for the actuation policy

Door state stays native; which doors open rides a Wasm verdict.

- Pros: custom policies (faction gates, time-of-day) without native work.
- Cons: the boundary has no door verb today (the verdict would need a new
  affordance), and the stock policy is a fixed enum plus distance, which is
  config-shaped per the priority order (config before plugin). A verdict
  adds no value until a custom policy exists.

## 4. Recommendation

Option B, with the policy in `[rules.vehicle]` fields
(`honk_open_doors` enum with the stock `HonkOpenTypes` values, default
"trader" per the stock interior-door change; `honk_open_distance` default
matching the stock trigger volume) and the door TE native (state is sim
mutation, which the boundary cannot carry). The honk event fires from the
vehicle sim (driver input); a plugin `on_honk` observer is a follow-up
boundary extension only if a custom reaction is wanted.

Order: door TE + state wire (RE the stock door state package in
7dtd-engine-research), then honk signal, then the controller pass + rules
fields, then the scenario.

## 5. Open questions

- Which package carries the door open/closed state on the wire, and what is
  its exact body? Needs RE (7dtd-engine-research tile-entities-power /
  door TE docs).
- Does the stock honk arrive as a C2S package or is the honk purely
  client-local with the server raising the event on proximity? The
  changelog says `UseHorn` fires the honk game event; the C2S trigger is
  not pinned.
- The 3.2.0 interior trader doors use the `oldWoodDoorNoHonk` variant;
  does the door's block identity (name prefix) gate honk-open, or only the
  TE property?
