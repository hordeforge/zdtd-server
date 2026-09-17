# Movement and position authority

The movement subsystem owns the player transform as the server holds it. It parses the C2S
position, rotation, motion and attach packages, rejects or clamps what the client claims,
writes the surviving coordinates into the ECS transform column, and answers with a
correction when it disagrees. Spawn, respawn and teleport placement and vehicle seat
assignment belong here, as does the grid path planner the AI walks. It owns no block,
damage, inventory or interest logic: `c2s/move.zig` returns `true` only for its own
package names, and `game/replicate.zig` decides which peers see the result. Per
`src/server/root.zig:3-4` the server package may import every other `src` package;
`src/litenet/root.zig:3-6` forbids the reverse.

Sources: [`src/server/movement.zig`](../../src/server/movement.zig),
[`src/server/game/movement_helpers.zig`](../../src/server/game/movement_helpers.zig),
[`src/server/c2s/move.zig`](../../src/server/c2s/move.zig),
[`src/server/game/rescue.zig`](../../src/server/game/rescue.zig),
[`src/ecs/path.zig`](../../src/ecs/path.zig)

## What the client claims, and what the server owns

Every C2S package reaches the subsystem through one chain: phase gate, then `c2s_join`,
`c2s_move`, `c2s_inv`, `c2s_blocks`, `c2s_quest`, `c2s_misc`
(`src/server/c2s/dispatch.zig:25-45`). The phase gate runs first, so a peer below
`.playing` never reaches a handler.

`NetPackageEntityPosAndRot` is absolute; its parser rejects a body under 30 bytes and
reads rotation only to skip it (`src/wire/packages.zig:987-1004`):

```zig
pub fn parsePosAndRotBody(body: []const u8) !struct { entity_id: i32, x: f32, y: f32, z: f32, on_ground: bool, wire_len: usize } {
```

The handler keeps the yaw already in the sim column rather than the parsed rotation,
because that rotation is not stored and passing `0` would fabricate a north facing on
every move (`src/server/c2s/move.zig:47-52`). `NetPackageEntityRelPosAndRot` is a delta in
1/32-block i16 units on a variable-width rotation base, so the delta offset is 21 when
`bUseQRotation` is set and 11 otherwise; a fixed offset 11 would decode quaternion bytes
as movement (`src/server/c2s/move.zig:136-156`). Both packages must name the sender's own
entity id (`src/server/c2s/move.zig:30-33`, `src/server/c2s/move.zig:131-135`).

Motion claims are relayed, never applied. `NetPackageEntityAliveFlags` stores the client
word verbatim and fans a re-encoded body rather than the raw one, because the parsers
accept a minimum while stock's bodies are exactly i32+u16 and 13 bytes, so trailing bytes
must not be forwarded (`src/server/c2s/move.zig:196-206`). `NetPackageEntitySpeeds` sets
sprint magnitude and movement tag the same way (`src/server/c2s/move.zig:208-241`).
`NetPackageEntityAddVelocity` is ownership checked and reduced to a dirty bit
(`src/server/c2s/move.zig:278-287`, `docs/DIVERGENCES.md` 1.6). `NetPackageEntityPhysics`
is length-validated against the stock 58-byte body and dropped, since zdtd's movement,
vehicle and falling-block sims are authoritative (`src/server/c2s/misc.zig:245-259`,
`docs/DIVERGENCES.md` 1.4). The per-client envelope sample, updated by `noteAcceptedMove`
from the server tick counter, with `vy_blocks_per_s` derived from the previous accepted
position and power-grid triggers activated at the feet cell and the cell below
(`src/server/game/movement_helpers.zig:13-38`), is (`src/server/game/types.zig:680-689`):

```zig
    /// Last movement-envelope sample (horizontal speed gate).
    move_valid: bool = false,
    move_x: f32 = 0,
    move_y: f32 = 0,
    move_z: f32 = 0,
    move_tick: u64 = 0,
    /// Server-derived vertical velocity (blocks/s) from the C2S position
    /// history (ADR 0037): fed to the sense v4 record so plugins observe the
    /// player's fall without a sim-side physics model.
    vy_blocks_per_s: f32 = 0,
```

## Bounds and the speed envelope

The envelope is policy, not stock data: module defaults are 20 m/s horizontal, 25 m/s
vertical, a 1/40 s floor on dt and a 1 s cap (`src/server/movement.zig:9-19`). The live
values are the `Game` fields `max_horizontal_speed_mps` and `max_vertical_speed_mps`
(`src/server/game/types.zig:376-379`), bound from `zdtd.toml [authority]`
(`src/server/zdtd_config.zig:398-402`). Elapsed time is the server tick delta, floored at
1/40 s and capped at 1 s (`src/server/movement.zig:21-24`,
`src/server/movement.zig:86-90`). The horizontal clamp scales the xz delta toward the last
good position so travel stays within `max_speed * dt`, failing closed to that position on
a non-finite distance or a non-positive budget (`src/server/movement.zig:37-62`);
`clampVertical` bounds only the Y delta, which the horizontal clamp cannot see
(`src/server/movement.zig:67-83`).

The gate both feed is `applyMovementEnvelope`
(`src/server/game/movement_helpers.zig:50-51`), and its first check is a rejection rather
than a clamp: any axis outside `coordInRange` drops the packet without applying it,
because the tick path casts transforms to block indices and a clamped attacker coordinate
would still be a teleport to the ceiling (`src/server/game/movement_helpers.zig:52-61`).
The sim ceiling is `max_player_coord` = 1_000_000 blocks
(`src/server/game/constants.zig:10-24`); the wire parser holds a separate, wider `1 << 24`
limit (`src/wire/packages.zig:944-954`). The first packet after spawn applies directly,
because `move_valid` is false and there is no prior sample to measure against
(`src/server/game/movement_helpers.zig:62-64`). The vertical cap is not fixed: an armed
glide flag replaces it with `rules.glide.sink_vy_mps`, and a positive
`rules.glide.fall_sink_vy_mps` applies a global fall sink
(`src/server/game/movement_helpers.zig:77-89`, `src/ecs/rules.zig:106-116`).

## Rejection, correction, and evidence

`applyMovementEnvelope` returns `{ x, y, z, applied }`. When a clamp ran, the violation is
recorded through `noteEvidence` as detector `.movement`, severity `.strong`
(`src/server/game/movement_helpers.zig:99`), and the authority mode decides the outcome
(`src/server/game/movement_helpers.zig:100-111`):

- `correct`: increment `movement_rejects`, log the first and every hundredth
  reject, send the peer a `NetPackageEntityPosAndRot` body carrying the clamped
  position with `on_ground = true`, and apply the clamped position.
- `observe`: apply the client position unchanged, with no counter and no
  correction packet, because `movement_rejects` counts enforced rejections only
  (`docs/AUTHORITY.md`, observe row).

A bounds rejection differs from a clamp: the packet is dropped before any sim write and no
correction is sent, since `applied = false` makes the caller return early
(`src/server/c2s/move.zig:34-35`). Otherwise a rejected move is never acknowledged; the
peer learns the truth from the next replicated position or from the clamp snap.

`NetPackageEntityTeleport` runs the same envelope as an absolute position, so a client
cannot bypass the gate and rebaseline it through `noteAcceptedMove`
(`src/server/c2s/move.zig:252-266`). Only an unclamped teleport is relayed, trimmed to the
parsed body length, so trailing bytes and a clamped or Y-only-clamped claim never reach
peers (`src/server/c2s/move.zig:267-275`). Denial policy sits above this module:
`.movement` is `client_informed`, so its `.hard` severity is downgraded and a kick needs
the guard ladder; its surface is `.none`, so a quarantine locks all three surfaces
(`docs/AUTHORITY.md`).

## Spawn, respawn, teleport, and void rescue

Join, respawn and the admin `tele` verb place a player through the same envelope reset.
`sendJoinBundle` sets `move_valid = false` and seeds the sample from the surface cell
`spawnSurface` resolved, so the first packet of a new life is a baseline rather than a
measurement against the previous one (`src/server/game.zig:2785-2790`,
`src/server/game.zig:2720-2767`).

Respawn calls `World.respawnPlayer`, which revives the slot, clears death buffs, restores
each stat to its own maximum, writes the transform and marks position and health dirty
(`src/ecs/world.zig:872-896`); `c2s/join.zig:480-534` then runs the DeathPenalty-selected
`game_on_respawn_*` sequence and sends `NetPackagePlayerSpawnedInWorld` followed by a
stock `EntityTeleport`. The admin path clamps each axis to `max_player_coord`, resets the
envelope for the owning peer, and broadcasts `NetPackageEntityTeleport`
(`src/server/admin_console.zig:437-456`).

A player who falls out of the mesh is caught by (`src/server/game/rescue.zig:9`):

```zig
pub fn rescueDeepVoid(self: *Game, peer: *ln_peer.Peer, entity_id: i32, x: f32, y: f32, z: f32, do_teleport: bool) !?f32 {
```

The threshold is `y < -1.0`; the rescue snaps the player to the terrain surface height
plus 0.9, sends `EntityTeleport` when asked, and returns that Y
(`src/server/game/rescue.zig:12-27`). The absolute-position and teleport paths pass
`do_teleport = true` and reset the envelope afterwards, so interim client packets still
falling are not counted as rejects against a legitimate player
(`src/server/c2s/move.zig:36-46`, `src/server/c2s/move.zig:256-262`). The
relative-position path can also walk Y into the void, so it re-snaps and only then records
the accepted move (`src/server/c2s/move.zig:165-170`).

## Vehicles and attached entities

Seating is a server decision. A C2S `NetPackageEntityAttach` is sender-gated; a detach
resolves the hull from server state rather than from the packet, and a mount resolves the
claimed vehicle id and asks the sim (`src/server/c2s/misc.zig:1228-1244`).
`systems.vehicleAttach` refuses a requested seat at or above the usable count, returns the
seat already held, and otherwise requires the rider within `rules.ai.mount_range_sq` and
detaches from any other hull first (`src/ecs/systems.zig:3368-3386`). `seatRider`
broadcasts the resolved seat index, which is the whole of "passengers render in the right
seat"; `unseatRider` broadcasts detach with vehicle id and slot both -1, and a late joiner
gets current occupancy replayed (`src/server/game/vehicle.zig:14-71`). The sim copies the
hull transform onto every seated rider each tick, offset by 1 in Y, because the client
parents the rider to the seat itself; a rider whose entity is gone frees the seat, and
freeing seat 0 stops the vehicle (`src/ecs/systems.zig:3260-3277`). The movement-relevant
field subset, interior fields trimmed, is (`src/ecs/components.zig:506-521`):

```zig
pub const Vehicle = struct {
    kind: VehicleKind = .minibike,
    /// Rider net id per seat, -1 when free. Index is the wire slot carried by
    /// NetPackageEntityAttach (asm.il:844620).
    seats: [max_seats]i32 = [_]i32{-1} ** max_seats,
    /// Usable seats, always clamped to 1..max_seats on spawn.
    seat_count: u8 = 1,
    vy: f32 = 0,
    max_speed: f32 = 0,
    throttle: f32 = 0,
    steer: f32 = 0,
```

Drive input arrives as a 13-byte zdtd-shaped control body under the stock
`NetPackageVehicleSpawn` name, gated on that exact length because a real stock body is at
least 32 bytes and can never be read as this one (`src/server/c2s/misc.zig:1212-1226`,
`src/wire/packages.zig:6106-6135`). Only seat 0 steers
(`src/server/c2s/misc.zig:1220-1222`). zdtd implements no client-requested vehicle
spawning, so a stock `VehicleSpawn` body falls through unhandled (`docs/DIVERGENCES.md`,
"Six zdtd-shaped bodies" 1a4).

## Grid path planning for AI chase

`src/ecs/path.zig` is a pure planner with no world state: it follows a caller-supplied
move predicate and fills a fixed point buffer, keyed on x and z only, so a column
reachable at two heights resolves to whichever height the search reached first
(`src/ecs/path.zig:1-39`):

```zig
pub const max_path: usize = 32;

pub const Point = struct { x: i32, z: i32, y: i32 };

pub const StepFn = *const fn (?*anyopaque, i32, i32, i32, i32, i32) ?i32;

pub const Path = struct {
    points: [max_path]Point = undefined,
    len: usize = 0,
    cursor: usize = 0,
```

The predicate returns the destination feet Y or null for a blocked move, so step-up, drop
and a floor under a roof are expressible (`src/ecs/path.zig:15-21`). `greedyToward` is the
fallback; `bfsToward` and `aStarToward` cap expansions and node count and fall back to
greedy when the goal is unreachable, which the AI reads as `path_blocked`
(`src/ecs/path.zig:119-181`, `src/ecs/path.zig:234-330`). The sim caller is the zombie
chase planner (`src/ecs/systems.zig:2580-2600`); the fuzz target drives the same
invariants (`src/fuzz.zig:1594`). Replans are metered per tick at 16
replans with a stride cap of 8 ticks, and the granted count feeds an APM counter
(`src/ecs/world.zig:898-911`, `src/ecs/systems.zig:4096`).

## Per-tick work, wire traffic, and persistence

No player position is integrated on the server. The sim holds the transform the client
claimed and the envelope validated; `systemVehicles` and the AI path are the only other
producers of transforms here. The tick contributes three fan-outs: motion replication,
where `replicate` returns early unless the tick is a `motion_replicate_period_ticks`
multiple and then sends `NetPackageEntityPosAndRot` from the sim transform, with the
owner's own peer slot excluded from the viewer mask so there is no self-echo
(`src/server/game/replicate.zig:63`, `src/server/game/replicate.zig:216-239`); vehicle
positions every `vehicle_pos_send_ticks` (default 5), skipped while guard load shedding is
open (`src/server/game/step.zig:406`, `src/server/game/vehicle.zig:99-119`,
`src/server/game/types.zig:85-88`); and the sprint lapse, where `sprint_stale_cd` expiry
stops the reported sprint speed and movement tag from being claimed
(`src/server/game/tick.zig:1203-1206`), whose tag maps state 0 to idle, 1 and 2 to walking
and everything else to running (`src/server/game/types.zig:531-537`).

Persistence is partial. The player record stores world x, y, z and wallet, with `y < 2`
substituted by the primary spawn height (`src/server/persist.zig:852-859`), and the load
path restores the transform with the same floor and yaw 0
(`src/server/persist.zig:1282-1290`). Vehicles persist kind, position, yaw, fuel,
`seat_count` and `max_speed` in `entities.zen` (`src/server/persist.zig:1618-1632`); seat
occupancy does not persist, and `owner_slot` is set by no production path, which leaves
the parked-vehicle waypoint list empty (`src/ecs/components.zig:533-538`).

Stock fidelity here rests on package shapes, not on a proven behavioural match; a round
trip through zdtd's own encode and decode shows self-consistency only. The envelope has no
stock counterpart, because stock trusts the reported position. The cost is that a
legitimately fast claim beyond the cap is clamped and answered with a snap instead of
applied; raising `zdtd.toml [authority] max_horizontal_speed_mps` above the fastest
legitimate vehicle speed trades that cost for the anti-teleport property.

## See also

- [`docs/AUTHORITY.md`](../AUTHORITY.md) - authority modes, guard ladder, movement detector.
- [`docs/DIVERGENCES.md`](../DIVERGENCES.md) - rows 1.4 and 1.6, vehicle control body.
- [`docs/wire/PACKAGES.md`](../wire/PACKAGES.md) - position and attach body layouts.
- [`docs/adr/0037-parachute-glide.md`](../adr/0037-parachute-glide.md) - glide flag and vertical cap.
