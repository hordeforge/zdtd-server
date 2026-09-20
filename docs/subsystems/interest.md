# Interest and replication

This subsystem owns the observer set, which peers may see a given entity in a
given tick, and the serialize-once fan-out that turns one encode into N sends.
It also owns the per-tick entity spawn, range-remove, health, and tile-entity
replication paths. It does not own package body layout (`wire/stock_*.zig`),
socket framing (`litenet/`, `src/server/game/net.zig`), the chunk stream pacing
(`src/server/game/chunk_stream.zig`), or the sim mutations that set dirty bits
(`src/ecs/systems.zig`).

The range math and dirty helpers live in `src/ecs/interest.zig`, whose package
root declares: "Dependency direction: may import util only. Must not import
wire, server, world, assets, litenet, or apm. Wire/world/assets may import pure
types from here (components, QuestKind, InvSlot) for catalog → sim mapping;
that assets→ecs edge is intentional and one-way for pure shapes only"
(`src/ecs/root.zig:3`). `src/ecs/root.zig:32` re-exports `interest`, and
`scripts/lint-architecture.sh` enforces the edge in `make check`. The server
layer is the top of the stack and may import every package
(`src/server/root.zig:1`).

Sources: [`src/ecs/interest.zig`](../../src/ecs/interest.zig), [`src/ecs/entity.zig`](../../src/ecs/entity.zig), [`src/ecs/world.zig`](../../src/ecs/world.zig), [`src/ecs/components.zig`](../../src/ecs/components.zig), [`src/server/game/replicate.zig`](../../src/server/game/replicate.zig), [`src/server/replicate_te.zig`](../../src/server/replicate_te.zig), [`src/server/game/replicate_health.zig`](../../src/server/game/replicate_health.zig), [`src/server/game/step.zig`](../../src/server/game/step.zig), [`src/server/game/chunk_stream.zig`](../../src/server/game/chunk_stream.zig)

## Geometry and the observer mask
Interest is a uniform grid, not a spatial index. A cell is the position
floor-divided by `cell_size`, which is 32 blocks (`src/ecs/interest.zig:9`).
The floor, not a truncating cast, matters: "Floor the division, not the
coordinate: truncating first puts every position in (-cell_size, 0) into cell 0
and skews range around the origin" (`src/ecs/interest.zig:17`). Per-client range
is carried in grid cells (`Client.view_radius`, `src/server/game/types.zig:628`),
so `default_view_radius = 7` (`src/server/game/types.zig:177`) is a 15-by-15
cell square centred on the player. The observer set is one word, one bit per
client slot, produced by vector comparison rather than a client loop:
`max_clients = ln_server.max_peers` is 64 (`src/litenet/server.zig:9`), so
`ObsMask` is a `u64`.

The scalar range test is one comparison per axis (src/ecs/interest.zig:27):
```zig
pub fn cellsInRange(acx: i32, acz: i32, bcx: i32, bcz: i32, radius_cells: i32) bool {
    return @abs(acx - bcx) <= radius_cells and @abs(acz - bcz) <= radius_cells;
}
```

The observer-mask type is one unsigned word of `lanes` bits
(src/ecs/interest.zig:55):
```zig
pub fn ObserverMask(comptime lanes: comptime_int) type {
    return @Int(.unsigned, lanes);
}
```

The vectorized per-entity query (src/ecs/interest.zig:68):
```zig
pub fn observerMask(
    comptime lanes: comptime_int,
    cx: *const [lanes]i32,
    cz: *const [lanes]i32,
    radius: *const [lanes]i32,
    active: ObserverMask(lanes),
    ecx: i32,
    ecz: i32,
) ObserverMask(lanes) {
    if (active == 0) return 0;
    const V = @Vector(lanes, i32);
    const U = @Vector(lanes, u32);
    const zero: V = @splat(0);
    const r: V = radius.*;
    // @abs of the signed delta, compared unsigned: mirrors cellsInRange, and a
    // negative radius has no unsigned counterpart so it is rejected outright.
    const ru: U = @intCast(@max(r, zero));
    const dx: U = @abs(@as(V, cx.*) - @as(V, @splat(ecx)));
    const dz: U = @abs(@as(V, cz.*) - @as(V, @splat(ecz)));
    const hit = (dx <= ru) & (dz <= ru) & (r >= zero);
    const bits: ObserverMask(lanes) = @bitCast(hit);
    return bits & active;
}
```

Per-lane semantics are exactly `cellsInRange`, "including a negative radius
never matching" (`src/ecs/interest.zig:67`). `observerMaskRef` is the scalar
form, "Tests only: the vector form is the one on the tick path, and this exists
to prove they agree" (`src/ecs/interest.zig:92`). The comment ties the shape to
stock: "This is stock's per-entity `trackedPlayers` set computed on the fly
(NetEntityDistributionEntry::SendToPlayers, asm.il:800867)"
(`src/ecs/interest.zig:60`). The per-client inputs are filled once per motion
pass
(`src/server/game/replicate.zig:83`): `obs_r[ci]` from `cl.view_radius`, cells
from the player transform via `self.sim.slotOfNetId(cl.entity_id)`
(`src/server/game/replicate.zig:87`), and `active` from clients that are
`joined and entered and peer != null` (`src/server/game/replicate.zig:85`).
Inactive lanes are masked off, so their cell and radius entries need not be
meaningful. Tile-entity broadcasts use a separate
`interest_range: f32 = default_interest_range` of 160 blocks
(`src/server/game/types.zig:99`), compared as squared world distance by
`broadcastNear` (`src/server/game/net.zig:288`, `src/server/game/net.zig:305`).

## Dirty bits: what makes an entity a candidate
The grid is derived per entity from current positions, so nothing rebuilds when
a player walks. What gates work is the per-entity dirty word: four live bits,
with the padding documented as reclaimed space rather than free bits
(src/ecs/components.zig:1235):
```zig
pub const Dirty = packed struct(u8) {
    pos: bool = false,
    rot: bool = false,
    flags: bool = false,
    hp: bool = false,
    /// Padding to the u8 backing type. `spawn`/`remove`/`inv` used to live
    /// here: nothing ever read them, and they were never cleared, so any
    /// entity that set one stayed in `dirty_bits` forever (ECS review
    /// 2026-09-12). Marking an entity dirty is `pos`/`flags`/`hp`.
    _pad: u4 = 0,

    pub fn any(self: Dirty) bool {
        return self.pos or self.rot or self.flags or self.hp;
    }
};
```

The candidate-set helpers intersect and replace that word against `alive_bits`
(src/ecs/world.zig:94):
```zig
    pub fn intersectFromStatic(self: *AtomicBits, src: std.StaticBitSet(max_entities)) void {
        for (&self.words, src.masks) |*w, m| _ = w.fetchAnd(m, .monotonic);
    }

    /// Replace contents with the StaticBitSet source. Main-thread use only
    /// (replicate's heartbeat pass seeds candidates from `alive_bits`).
    pub fn copyFromStatic(self: *AtomicBits, src: std.StaticBitSet(max_entities)) void {
        for (&self.words, src.masks) |*w, m| w.store(m, .monotonic);
    }
```

`docs/ARCHITECTURE.md:513` still lists the bitset as
`POS | ROT | FLAGS | HP | SPAWN | REMOVE`; SPAWN and REMOVE are not in the code
as of this reading, and `docs/ARCHITECTURE.md:525` has `clearAfterReplicate`
clearing a spawn bit the function does not touch. World-side bookkeeping is two
set types. `alive_bits` is a `std.StaticBitSet(max_entities)` mirroring
`alive[]`, owned by spawn and destroy, so replication "walks set bits instead
of probing every slot" (`src/ecs/world.zig:383`). `dirty_bits` is an
`AtomicBits` over the same slot range, wrapping `std.atomic.Value(u64)` words
so parallel workers cannot tear a word shared by adjacent ranges
(`src/ecs/world.zig:52`). Those two helpers exist for the two candidate-set
constructions in `replicate()` (`src/ecs/world.zig:94`,
`src/ecs/world.zig:100`). Clearing is split by consumer: the motion pass clears
pos, rot and flags (`src/ecs/interest.zig:48`) and deliberately leaves hp set,
because the health pass runs after it (comment and test at
`src/ecs/interest.zig:199`).

## The per-tick replicate pass
`replicate()` runs once per tick from `step()` (`src/server/game/step.zig:522`),
in this order: resend pending reliable data per peer
(`src/server/game/replicate.zig:23`); drain each client's pending spawn area
against one shared budget (`src/server/game/replicate.zig:32`); run the chunk
view stream every `chunk_stream_period_ticks` for entered clients
(`src/server/game/replicate.zig:47`); replicate health
(`src/server/game/replicate.zig:62`); then bail if this is not a motion tick
(`src/server/game/replicate.zig:63`) or the sim is empty
(`src/server/game/replicate.zig:67`). Candidate selection is the heartbeat
split (src/server/game/replicate.zig:96):
```zig
    var candidates: ecs.world.AtomicBits = .initEmpty();
    if (!heartbeat) {
        candidates = self.sim.dirty_bits;
        for (self.sim.kind_groups.slice(.zombie)) |s| candidates.set(s);
        for (self.sim.kind_groups.slice(.animal)) |s| candidates.set(s);
        for (self.sim.kind_groups.slice(.trader)) |s| candidates.set(s);
        for (self.sim.kind_groups.slice(.falling_block)) |s| candidates.set(s);
        candidates.intersectFromStatic(self.sim.alive_bits);
    } else {
        // Heartbeat: every live entity is a candidate.
        candidates.copyFromStatic(self.sim.alive_bits);
    }
```

Cost model. On a heartbeat tick every live slot is a candidate
(`max_entities = 512`, `src/ecs/entity.zig:3`), so per-entity cost is paid for
entities no peer can see. On a normal motion tick the set is dirty slots plus
the four moving kinds, intersected with alive. Per candidate the pass computes
one cell and runs one vector mask query over `max_clients` lanes, then walks
only the set bits. The per-client arrays are rebuilt once per motion pass with
one `slotOfNetId` lookup each. Nothing allocates or grows on this path; the
frame scratch is five stack buffers of `replicate_frame_cap = 256` bytes, and
the bot pass adds one more (`src/server/game/replicate.zig:72`,
`src/server/game/replicate.zig:360`, `src/server/game/types.zig:181`). Cadence
defaults are `motion_replicate_period_ticks = 2`
(`src/server/game/types.zig:80`) and `pos_heartbeat_period_ticks = 5`
(`src/server/game/types.zig:83`), so at 20 TPS the full-entity sweep lands once
per 250 ms and motion content is rebuilt every 100 ms.

## No self-echo and the fan-out
The owning peer is excluded by clearing its bit from the in-range mask, for
player entities only (src/server/game/replicate.zig:218):
```zig
        const viewers = if (self.sim.mask[i].player)
            in_range & ~game_mod.bitOfPeerSlot(self.sim.player[i].peer_slot)
        else
            in_range;
```

`bitOfPeerSlot` returns 0 for an out-of-range slot, so a malformed peer slot
degrades to no exclusion rather than an out-of-bounds shift
(`src/server/game.zig:133`). An empty viewer set counts
`replicate_encodes_skipped` and continues (`src/server/game/replicate.zig:222`).

Everything shareable is encoded once, then copied per peer. The PosAndRot body
is built into `self.body_buf` and framed into a stack buffer
(`src/server/game/replicate.zig:228`, `src/server/game/replicate.zig:239`);
zombies and animals add entity speeds, alive flags and a delta-gated velocity
frame (`src/server/game/replicate.zig:261`); turrets add a change-gated
TurretSync frame (`src/server/game/replicate.zig:303`). The fan-out walks the
viewer word: position and speeds go unreliable, alive flags go droppable, turret
sync goes reliable (`src/server/game/replicate.zig:325`,
`src/server/game/replicate.zig:329`). The pass then replays the dirty set,
clearing motion bits one `clearAfterReplicate` plus `syncDirtyBit` per set bit
(`src/server/game/replicate.zig:336`), reconciles dead entities
(`src/server/game/replicate.zig:342`), and runs bot replication between the two
(`src/server/game/replicate.zig:334`). The counters prove fan-out ratio and
skipped encodes inside zdtd; they are not evidence that a stock client accepts
the bytes.

## Spawn, knowledge, and range-remove
Only moving kinds spawn on approach: `is_mob` covers zombie, animal, trader and
falling block (`src/server/game/replicate.zig:118`). For those, the in-range
mask is filtered to viewers that have not received an EntitySpawn for the slot,
using the per-client `known_entities` bitset (`src/server/game/replicate.zig:127`),
which is indexed by ECS slot, not network id (`src/server/game/types.zig:665`).
The spawn body is built once, then sent to every bit in `spawn_mask` while the
knowledge bit is set (`src/server/game/replicate.zig:180`,
`src/server/game/replicate.zig:186`).

Removal mirrors it: for a known mob, any client now outside
`cellsInRange(... cl.view_radius)` gets `NetPackageEntityRemove` with reason
`.unloaded` and loses the knowledge bit (`src/server/game/replicate.zig:196`,
`src/server/game/replicate.zig:201`). Dead knowledge is reconciled lazily, and
only when a slot was freed this tick, as a word-wise intersection of
`known_entities` with `alive_bits` (`src/server/game/tick.zig:1604`,
`src/server/game/tick.zig:1609`).

Host-side bots are not ECS slots and carry their own `known_bots` bitset, "bit
index = bot slot" (`src/server/game/types.zig:670`), max 16
(`src/server/game/bot.zig:17`). They reuse the observer arrays computed for
entities (`src/server/game/replicate.zig:388`), spawn with the player-mesh class
plus a name because "The player-mesh class REQUIRES a player spawn info body"
(`src/server/game/replicate.zig:405`), and are cleaned only in that pass, never
in the ECS reconcile (`src/server/game/replicate.zig:349`). No stealth, hidden,
or per-peer visibility gate exists in this path. Stealth is a sim phase
(`systemStealth` runs before AI, `docs/ARCHITECTURE.md:408`), but nothing in
`interest.zig` or `replicate.zig` reads a stealth or hidden value: the filters
are cell range, the active mask, and mob knowledge.

## Health and tile entities
The health pass runs every tick before the motion cadence check
(`src/server/game/replicate.zig:62`) and walks `dirty_bits` rather than all
slots: "this runs every tick and only an hp-dirty entity can have an update"
(`src/server/game/replicate_health.zig:15`). It snapshots the set first because
"the body destroys and re-marks entities on the death path while it walks"
(`src/server/game/replicate_health.zig:19`), clears the hp bit before sending,
and re-sets it on any send failure so the next tick retries with current HP
(`src/server/game/replicate_health.zig:122`). Recipients are the owner plus
every client that observes the position by a direct `interest.inRange` call
rather than the motion pass mask (`src/server/game/replicate_health.zig:115`,
`src/server/game/replicate_health.zig:134`). Tile entities own the S2C wire out
for workstations, storage containers, vending machines, powered blocks, signs
and authored lights
(`src/server/replicate_te.zig:1`). Their boundary statement: "Everything here
reads sim and world state and writes package bodies; nothing here mutates the
sim" (`src/server/replicate_te.zig:9`). Dirty workstations run on the
workstation tick, not the replicate tick:
`tickWorkstations` ends by calling `broadcastDirtyWorkstations`
(`src/server/game/craft.zig:634`), which encodes each dirty station once and
broadcasts at `interest_range` as `NetPackageTileEntity`
(`src/server/replicate_te.zig:86`). A station whose client-declared array
lengths are unknown is skipped and cleared rather than guessed, because "a
guessed count resizes the client's grids" (`src/server/replicate_te.zig:71`).
`broadcastPowerVisuals` runs every step (`src/server/game/step.zig:268`) and is
edge triggered: a node that did not flip costs one comparison and no packet
(`src/server/replicate_te.zig:189`). Storage, vending, triggered power and
signs are per-peer or per-position sends.
`broadcastStorageTe` is position-scoped because stock
`NetPackageTileEntity::ProcessPackage` rebroadcasts with range 192, so "A global
broadcast sends every chest edit on the map to every peer"
(`src/server/replicate_te.zig:172`). `broadcastVendingTe` is documented as an
approximation: stock notifies the machine's listeners, zdtd uses "the view-radius
interest set - a superset of the open windows"
(`src/server/replicate_te.zig:430`). Newly streamed chunks push all four TE kinds
for that chunk, storage and signs and vending and lights, then workstations
(`src/server/game/chunk_stream.zig:47`, `src/server/game/chunk_stream.zig:55`,
`src/server/game/chunk_stream.zig:62`, `src/server/game/chunk_stream.zig:69`).
Those sends ride `sendGame` or `broadcastNear`, so they use the reliable pump
and its window-drop rules rather than a per-tick cap.

## Per-tick caps
`chunk_adds_per_stream_tick = 8` is a shared drain budget across all clients per
tick (`src/server/game/types.zig:67`, `src/server/game/replicate.zig:32`), which
is what stops concurrent joins from stacking chunk bodies in one tick;
`chunk_stream_period_ticks = 5` paces the view stream
(`src/server/game/types.zig:79`); `replicate_frame_cap = 256` bounds each
serialize-once frame scratch (`src/server/game/types.zig:181`);
`max_streamed_chunks_cap` bounds the per-client streamed-key set
(`src/server/game/types.zig:632`); `max_entities = 512` bounds candidates
(`src/ecs/entity.zig:3`). Entity spawn fan-out has no per-tick counter cap; it
is bounded by the 512-slot table times 64 clients. The reliable pump retry
budget is `window_retry_budget_ns = 16_000_000`
(`src/server/game/types.zig:166`), and a droppable package turns `WindowFull`
into a silent drop (`src/server/game/net.zig:66`).

## See also
- [tick.md](tick.md) - the 20 TPS step this pass is called from.
- [ecs.md](ecs.md) - SoA columns, dirty writes, and schedule order.
- [chunk-stream.md](chunk-stream.md) - view-square streaming and its own pacing.
- [wire.md](wire.md) - the package bodies and framing this fan-out reuses.
- [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md), section 8, for the design intent behind serialize-once.
