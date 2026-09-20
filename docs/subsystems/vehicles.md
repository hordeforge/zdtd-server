# Vehicles

The vehicle subsystem owns the hull entity: how many seats it has, which rider net id holds each
seat, where the hull sits, and how fast it moves. `src/server/game/vehicle.zig` builds the outgoing
seat and position bodies, `src/server/c2s/misc.zig` validates the mounting and drive requests, and
the authoritative state lives in the ECS (`ecs.Vehicle`, `systemVehicles`, `vehicleAttach`).
Vehicle physicals (kind, maximum speed, tank capacity, base seat count) are read from the stock
`vehicles.xml` by `src/assets/vehicles.zig`, with sim tuning supplied as rules. Mounting and drive
input do not pass through `src/server/c2s/move.zig`; that module carries player position and
attachment relay only, and the vehicle handlers are in `src/server/c2s/misc.zig`. Per
[`src/server/root.zig:1-7`](../../src/server/root.zig) the server package is the top of the stack
and may import every other package, while `src/ecs/root.zig:3-5` pins the reverse direction closed:
the sim may import util only, so the vehicle component never speaks the wire itself.

Sources: [`src/server/game/vehicle.zig`](../../src/server/game/vehicle.zig),
[`src/server/c2s/misc.zig`](../../src/server/c2s/misc.zig),
[`src/ecs/components.zig`](../../src/ecs/components.zig),
[`src/ecs/systems.zig`](../../src/ecs/systems.zig),
[`src/ecs/rules.zig`](../../src/ecs/rules.zig),
[`src/assets/vehicles.zig`](../../src/assets/vehicles.zig),
[`src/wire/packages.zig`](../../src/wire/packages.zig),
[`src/server/persist.zig`](../../src/server/persist.zig)

## The vehicle component

A vehicle is one ECS slot with `mask.vehicle` set, holding a `Vehicle` column entry. The kind set is
closed and matches the stock vehicle list (`src/ecs/components.zig:469`):

```zig
pub const VehicleKind = enum(u8) {
    bicycle = 0,
    minibike = 1,
    motorcycle = 2,
    four_by_four = 3,
    gyrocopter = 4,
};
```

Seat storage is a fixed array of rider net ids, so the component has no heap and no unbounded rider
list (`src/ecs/components.zig:495`):

```zig
pub const Vehicle = struct {
    kind: VehicleKind = .minibike,
    speed: f32 = 0,
    fuel: f32 = 100,
    /// Rider net id per seat, -1 when free. Index is the wire slot carried by
    /// NetPackageEntityAttach (asm.il:844620).
    seats: [max_seats]i32 = [_]i32{-1} ** max_seats,
    /// Usable seats, always clamped to 1..max_seats on spawn.
    seat_count: u8 = 1,
```

`max_seats` is 6, the widest stock base seat block (`Truck4x4` declares `seat0..seat5`), and
`driver_seat` is 0 (`src/ecs/components.zig:477-493`). `usableSeats` re-clamps a corrupt
`seat_count` into `1..max_seats`, so a bad config can never produce a seatless hull
(`src/ecs/components.zig:534-536`). `owner_slot` exists for the parked-vehicle waypoint list, but
both spawn paths are worldgen and the admin console, so every live vehicle is unowned and the
waypoint list is empty (`src/ecs/components.zig:523-527`, `src/server/game/vehicle.zig:84`).

## Seats and riders

Mounting is a sim decision, not a client claim. `vehicleAttach` takes the requested wire slot and
returns the seat that was actually granted, or null (`src/ecs/systems.zig:3379`):

```zig
pub fn vehicleAttach(w: *World, vslot: Slot, player_net: i32, requested: i16) ?u8 {
```

The rules are: a requested slot at or above `usableSeats()` is refused; re-requesting the seat
already held, or `-1` while held, returns that seat unchanged; a fresh mount must be within
`rules.ai.mount_range_sq` of the hull and detaches the rider from any other hull first; a full
vehicle returns null; and an explicit request for an occupied seat is refused rather than evicting
the sitting rider (`src/ecs/systems.zig:3382-3412`). `seat_any` is `-1`, the wire sentinel the stock
client always mounts with (`src/ecs/systems.zig:3346-3348`). `vehicleDetach` resolves the hull from
server occupancy, frees the seat, and stops the hull only when the freed seat is the driver seat
(`src/ecs/systems.zig:3423-3431`).

`seatRider` calls the sim and broadcasts the resolved seat, which is the whole of "passengers render
in the right seat" (`src/server/game/vehicle.zig:19-29`). `unseatRider` broadcasts detach with
vehicle id and slot both `-1`; the sim seat is freed even when the encode fails, because a ghost
seat on remotes is worse than a missing packet (`src/server/game/vehicle.zig:35-51`). A late joiner
gets current occupancy replayed seat by seat (`src/server/game/vehicle.zig:55-71`), and the owning
player receives their parked hulls as an `EntityWaypointList` with list type `Vehicle` (0)
(`src/server/game/vehicle.zig:78-97`, `src/wire/packages.zig:6545-6559`).

## Drive input

The client drives with a zdtd-shaped 13-byte body carried under the stock `NetPackageVehicleSpawn`
name. The handler gates on that exact length, so a real stock body (entity type, position, rotation,
ItemValue, placing entity) can never be decoded as this one (`src/server/c2s/misc.zig:1247`,
`src/wire/packages.zig:6103-6108`). The op byte selects enter, exit or drive, and only seat 0
steers (`src/server/c2s/misc.zig:1251-1257`). The parser rejects non-finite throttle or steer values
(`src/wire/packages.zig:6089`):

```zig
pub fn parseVehicleControl(body: []const u8) !struct { entity_id: i32, op: u8, throttle: f32, steer: f32 } {
```

`NetPackageVehicleDataSync` is relayed, not applied: the sender must name its own entity, the named
vehicle must be a live vehicle, and the sender must be that vehicle's driver, after which the opaque
sync blob is forwarded to every other peer (`src/server/c2s/misc.zig:1236-1244`).
`NetPackageEntityAttach` is sender-gated the same way; a detach type resolves the hull from server
state because the stock detach carries vehicle id `-1`, and an attach type resolves the claimed
vehicle id before asking the sim for a seat (`src/server/c2s/misc.zig:1263-1265`).

Drive physics is `rules.vehicle`, which is zdtd-owned because the stock dedicated server has no
vehicle sim (`src/ecs/rules.zig:598-618`):

```zig
pub const Vehicle = struct {
    /// Throttle acceleration (blocks/s^2) per unit throttle input.
    accel_mps2: f32 = 14.0,
    /// Reverse speed cap as a fraction of max_speed.
    reverse_frac: f32 = 0.3,
    /// Coast decay per second with no throttle (1.0 = full stop instantly).
    coast_decay: f32 = 0.8,
```

`vehicleControl` requires a live vehicle with a seated driver, clamps speed to `max_speed` or the
per-kind default when the XML value is missing, scales yaw by speed fraction and input, and burns
fuel per block travelled for every kind except the bicycle (`src/ecs/systems.zig:3315-3333`). Kind
defaults are the stock `velocityMax_turbo` first components: bicycle 6, minibike 7, motorcycle 9.8,
4x4 10, gyrocopter 9 (`src/ecs/systems.zig:3305-3313`). `vehicleTickHeld` re-applies the last input
every sim tick, because the stock client may send drive packages sparsely
(`src/ecs/systems.zig:3345-3354`).

## Sim tick

`systemVehicles` runs from the ECS schedule, gated by the `vehicles` rule toggle
(`src/ecs/schedule.zig:102`, `src/ecs/rules.zig:41`). It integrates vertical velocity with
`rules.vehicle.gravity`, clamps the hull to the terrain top with no sink below the surface, and then
copies the hull transform onto every seated rider with the Y offset of 1, because the client parents
the rider to the seat itself (`src/ecs/systems.zig:3245-3290`). A rider whose entity no longer
exists frees its seat, and losing seat 0 stops the hull so a dead driver cannot leave an undriveable
vehicle (`src/ecs/systems.zig:3276-3281`).

## Spawn, wire and persistence

`spawnVehicleEx` is the only spawn entry: it creates the base entity, applies the tank capacity from
the vehicles.xml hook or the `[rules.vehicle] fuel_cap` floor, gives a bicycle no tank, and clamps
`seat_count` into `1..max_seats` (`src/ecs/world.zig:1720-1746`). It is called by the demo world
seed, the admin console and the persistence load path
(`src/server/game/init_world.zig:289-298`, `src/server/admin_console.zig:1700-1712`,
`src/server/persist.zig:1810`). The asset side keeps the physicals honest: `loadFromPath` reads
`velocityMax_turbo` (falling back to `velocityMax`), `motorTorque_turbo` and the `fuelTank`
capacity, resolves max HP from the placeable item's `DegradationMax`, and counts only contiguous
unmodded seat blocks (`src/assets/vehicles.zig:15-37`, `src/assets/vehicles.zig:74-84`,
`src/assets/vehicles.zig:108-133`, `src/assets/vehicles.zig:174-204`). An unreadable file is
`error.OpenFailed` rather than an invented default (`src/assets/vehicles.zig:208`). A missing catalog
row fails the demo seed closed instead of
inventing a speed (`src/server/game/init_world.zig:293-297`).

The periodic position broadcast is `NetPackageVehiclePositions`: a count followed by entity id and
three floats per hull, skipped entirely when no client has entered the world
(`src/server/game/vehicle.zig:99-119`). It is sent every `vehicle_pos_send_ticks` (default 5) unless
load shedding is open (`src/server/game/step.zig:406`, `src/server/game/types.zig:88`). The stock
`NetPackageTurretSync` broadcast is disabled, because the stock body is per-entity and a
multi-entity blob breaks the client reader (`src/server/game/vehicle.zig:121-125`).

Persistence stores each vehicle as a 32-byte record: kind, position, yaw, fuel, `seat_count` and
`max_speed`, followed by an optional basket record when the basket holds items
(`src/server/persist.zig:1619-1639`). Load range-checks the raw kind byte before `@enumFromInt`,
because an out-of-range byte would panic on a corrupt `entities.zen`, then restores fuel and yaw on
the respawned hull (`src/server/persist.zig:1796-1815`). Basket records apply to the vehicle written
just before them, and every claimed slot is consumed even when no vehicle is available, so the
record stream stays aligned (`src/server/persist.zig:1852-1863`). Seat occupancy does not persist:
riders re-mount after a restart.

## See also

- [`docs/subsystems/movement.md`](movement.md) - position intake, the attachment relay, and the speed envelope.
- [`docs/subsystems/ecs.md`](ecs.md) - the SoA columns and the system schedule.
- [`docs/subsystems/wire.md`](wire.md) - the attach, position and waypoint body layouts.
- [`docs/subsystems/persistence.md`](persistence.md) - `entities.zen` records and the load path.
- [`docs/DIVERGENCES.md`](../DIVERGENCES.md) - the zdtd-shaped vehicle control body.
