# Power and electric grids

This subsystem owns the electric grid of a world: the generators, batteries, relays, switches, triggers and consumers that a player wires together, the flood that decides what is powered, the fuel and battery economy that runs per tick, and the tile-entity and wire packages that carry the result to the client. `ecs/electric.zig` is the sim: it holds a `PowerGrid` of fixed node and wire tables, with no reference to the world store, the asset loaders or the wire layer. `ecs/powerblocks.zig` is the bridge from stock block data to that grid, resolving a blocks.xml `Class` and its power properties into a node kind and a `Resolved` property set. The wire bodies live in `wire/stock_te.zig` and the block-type bytes in `wire/te_types.zig`. The server drives the grid from `server/game/step.zig` and turns its state into packages from `server/replicate_te.zig` and the C2S handlers under `server/c2s/`. Import direction follows the package roots: `ecs` may import `util` only (`src/ecs/root.zig:3`), `wire` may import `util`, `assets`, `ecs` shapes and `world` domain types (`src/wire/root.zig:3`), and `server` may import every package (`src/server/root.zig:3`). The grid is rebuilt from the block plane on chunk load rather than loaded whole, so the sim's node identity is per-session and only player-set state is persisted.

Sources: [`src/ecs/electric.zig`](../../src/ecs/electric.zig), [`src/ecs/powerblocks.zig`](../../src/ecs/powerblocks.zig), [`src/ecs/rules.zig`](../../src/ecs/rules.zig), [`src/ecs/systems.zig`](../../src/ecs/systems.zig), [`src/ecs/world.zig`](../../src/ecs/world.zig), [`src/wire/stock_te.zig`](../../src/wire/stock_te.zig), [`src/wire/te_types.zig`](../../src/wire/te_types.zig), [`src/server/game/step.zig`](../../src/server/game/step.zig), [`src/server/game/chunk_fill.zig`](../../src/server/game/chunk_fill.zig), [`src/server/replicate_te.zig`](../../src/server/replicate_te.zig), [`src/server/c2s/misc.zig`](../../src/server/c2s/misc.zig), [`src/server/persist.zig`](../../src/server/persist.zig).

## The grid model

Four node kinds cover stock's powered blocks: generator, battery, relay and consumer, with turrets, lights and fridges all landing in the last one (`src/ecs/electric.zig:40`). One node carries the block position, its watts, its latch state, the resolved power flag, the optional entity link a turret uses, and the trigger fields a pressure plate or motion sensor needs (`src/ecs/electric.zig:47`):

```zig
pub const PowerNode = struct {
    id: u16 = 0,
    kind: NodeKind = .consumer,
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    /// Watts produced (gen) or drawn (consumer).
    watts: f32 = 0,
    on: bool = true,
    powered: bool = false,
    /// Optional link to game entity (turret entity id).
    entity_id: i32 = -1,
    /// Generator: remaining fuel units (0 = empty, stops output). Battery: stored energy.
    fuel_or_energy: f32 = 0,
```

The grid itself is plain arrays with a monotonic id counter and two totals (`src/ecs/electric.zig:155`):

```zig
pub const PowerGrid = struct {
    nodes: [max_nodes]PowerNode = [_]PowerNode{.{}} ** max_nodes,
    node_n: usize = 0,
    wires: [max_wires]Wire = [_]Wire{.{}} ** max_wires,
    wire_n: usize = 0,
    /// Saved edges waiting for both endpoint nodes to appear (chunks scan
    /// lazily); reconnectPending drains them as the grid rebuilds.
    pending_wires: [max_wires]WirePos = [_]WirePos{.{}} ** max_wires,
    pending_wire_n: usize = 0,
```

The caps are 256 nodes and 512 wires, a zdtd bound rather than a stock rule, and the wire rating ceiling is 100 kW against stock generators near 1 kW (`src/ecs/electric.zig:6`, `:9`). Node ids are monotonic and, on u16 wrap, reuse a retired id rather than collide with a live one, because `indexOfId` would otherwise resolve the duplicate to the wrong node (`src/ecs/electric.zig:264`). Removal swap-compacts the table, so the live set is always the prefix and any index-keyed side table would follow the wrong block; that is why the last-echoed on and powered pair lives on the node itself (`src/ecs/electric.zig:93`). `addNodeAt` is the position-keyed form the world paths use, so a repeated request for one cell cannot stack duplicate nodes until the table fills (`src/ecs/electric.zig:816`). The grid is cleared wholesale when a world is unloaded, which resets the totals and the id counter (`src/ecs/electric.zig:178`).

## Resolve: flood, gates and load shed

Every powered flag is recomputed from scratch by `resolveDay`, a BFS flood from the generators. Generators seed the queue only when on, not solar at night, and not when their tank has a positive capacity and no fuel left (`src/ecs/electric.zig:710`):

```zig
        while (i < self.node_n) : (i += 1) {
            // Generators need fuel (or zero capacity = infinite for tests that zero it).
            if (self.nodes[i].kind == .generator and self.nodes[i].on) {
                if (self.nodes[i].solar and !daylight) continue;
                if (self.nodes[i].capacity > 0 and self.nodes[i].fuel_or_energy <= 0) continue;
                queue[qt] = i;
                qt += 1;
                visited[i] = true;
                self.nodes[i].powered = true;
                self.total_gen += self.nodes[i].watts;
            }
        }
```

The flood is undirected over the wire list, resolved up front through a sorted id-to-index table and a CSR adjacency so the walk visits only incident edges instead of rescanning every wire per dequeued node (`src/ecs/electric.zig:663`). Two node types gate the flood rather than simply passing it: a trigger passes power onward only while it has an active pulse or an `Always` latch, and a switch passes only while latched on. Both stay powered themselves, which is what lights their block meta on the client (`src/ecs/electric.zig:727`). Relays always pass, and any other node must be on to be reached (`src/ecs/electric.zig:737`). Demand is then summed over powered consumers, and if it exceeds generation the load shed walks the table backwards unpowering consumers until the total fits, which is deterministic because node order is (`src/ecs/electric.zig:747`). With no generation at all, every non-generator node is unpowered and the load total is zeroed.

One function decides the `isOn` bit a client reads: a switch reports its latch, a trigger reports an open gate or a running pulse, and everything else reports the powered flag (`src/ecs/electric.zig:101`):

```zig
pub fn nodeIsOn(n: PowerNode) bool {
    if (n.is_switch) return n.on;
    if (n.is_trigger) return n.latched or n.pulse_left > 0;
    return n.powered;
}
```

Trigger actuation is fail-closed: `activateTriggerAt` requires a registered trigger node that is already wired to a live source, resolves connectivity first, and respects the stock delay before opening the gate (`src/ecs/electric.zig:314`). The delay and duration indices are kept as the wire enumeration values rather than converted to seconds, so the tile-entity echo needs no lossy inverse mapping (`src/ecs/electric.zig:81`), and the two conversions that do exist are explicit functions (`src/ecs/electric.zig:15`, `:23`).

## The per-tick order

`PowerGrid.tick` advances fuel, batteries, trigger timers, delays and pulses in six numbered passes, then re-resolves if anything changed (`src/ecs/electric.zig:395`). Fuel burn consumes `burn_rate * dt` and switches a generator off when the tank empties; a solar generator with no capacity only tracks daylight (`src/ecs/electric.zig:400`). Connectivity resolves after the burn so the shed sees the new state (`src/ecs/electric.zig:429`). Batteries then cover a shortfall or absorb a surplus, spread over the powered batteries in table order (`src/ecs/electric.zig:431`). Timer nodes toggle their latch or the first wired consumer when their period elapses (`src/ecs/electric.zig:465`), an armed plate opens its gate when the delay expires (`src/ecs/electric.zig:500`), and an expired pulse clears the signal path (`src/ecs/electric.zig:511`). The whole sequence hangs off one entry point (`src/ecs/electric.zig:397`):

```zig
    pub fn tick(self: *PowerGrid, dt: f32, daylight: bool) bool {
        if (dt <= 0 or self.node_n == 0) return false;
        var dirty = false;
```

The call site is the server step, not the ECS schedule: the sim schedule documents that power resolution stays in `Game.step` because it needs the daylight flag (`src/ecs/schedule.zig:81`). The step computes `daylight` from the director clock and ticks the grid once per frame, then actuates powered doors and pushes the power visuals (`src/server/game/step.zig:265`). Turrets read the grid once per tick rather than scanning it per turret: the parallel turret pass snapshots a per-slot powered flag array first, and a turret with no power clears its target and does not fire (`src/ecs/systems.zig:3449`, `:3463`). A placed turret is registered as a consumer node linked to its entity id, and destroying the turret removes that node and its wires (`src/ecs/world.zig:1757`, `:854`).

## Block data to node properties

`powerblocks.zig` turns stock block data into grid properties and never invents a watt figure. Class mapping is the RE-derived rule: `Generator` and `SolarPanel` are generators, `BatteryBank` is a battery, `Powered`, `ElectricWire`, `TimerRelay` and `Switch` are relays, and the remaining powered classes are consumers (`src/ecs/powerblocks.zig:126`). Trigger and switch classes stay separate predicates, because a switch must not fire when a player walks over it, only when they activate the block (`src/ecs/powerblocks.zig:149`). The resolved property set is what `applyToNode` copies onto a fresh node, including the fuel tank, the burn rate derived from `OutputPerFuel`, and the battery proxies that `[rules.power]` tunes (`src/ecs/powerblocks.zig:35`). The registry is one sorted column set built once at load from the block table, and `push` keeps the lowest block ids when the fixed registry fills, so the simulated block set cannot depend on hash-map iteration order (`src/ecs/powerblocks.zig:177`, `:209`):

```zig
pub const Registry = struct {
    ids: [max_power_entries]u16 = undefined,
    kinds: [max_power_entries]electric.NodeKind = undefined,
    watts: [max_power_entries]f32 = undefined,
    max_fuel: [max_power_entries]f32 = undefined,
    output_per_fuel: [max_power_entries]f32 = undefined,
    output_per_charge: [max_power_entries]f32 = undefined,
    output_per_stack: [max_power_entries]f32 = undefined,
    is_trigger: [max_power_entries]bool = undefined,
    is_switch: [max_power_entries]bool = undefined,
    trigger_type: [max_power_entries]u8 = undefined,
    n: usize = 0,
```

Three values that stock block data does not pin live in the rules rather than in the registry: the battery capacity fallback scale, the initial charge fraction, and the trigger pulse duration (`src/ecs/rules.zig:768`). They are merged from `[rules.power]` and copied onto the registry and the grid at init (`src/server/game/init_assets.zig:820`). Chunk load scans the block plane for powered blocks, adds a node per cell, applies the resolved properties and then drains pending edges and pending player state before resolving once (`src/server/game/chunk_fill.zig:229`, `:254`). Placing a powered block, or a block landing through a placement or downgrade, runs the same registration (`src/server/c2s/inv.zig:961`, `src/server/game/world.zig:388`).

## The tile-entity and wire packages

A powered trigger's server-to-client echo is a `NetPackageTileEntity` whose payload is the outer tile-entity header plus the stock `TileEntityPowered` fields. Its C2S parse mirrors that order field for field, treating everything as untrusted and bounding each list by the declared payload length (`src/wire/stock_te.zig:1460`):

```zig
pub fn parsePoweredTriggerTeBody(body: []const u8) binary.ReadError!PoweredTriggerTe {
    var r: binary.Reader = .{ .data = body };
    var out: PoweredTriggerTe = .{};
    const pay_len = try readOuterTeHeader(&r, &out.handle, &out.world_x, &out.world_y, &out.world_z, &out.block_id);
    if (r.remaining() < pay_len) return error.EndOfStream;
    var pr: binary.Reader = .{ .data = r.data[r.pos .. r.pos + pay_len] };
```

The state struct the echo fills carries the handle, the position, the block id, the parent link, the orientation, the trigger type and the two property bytes, plus the motion sensor's target mask (`src/wire/stock_te.zig:1409`). The parse keeps up to eight wires while recording how many the sender declared, because the count field is a `u8` and a sender may declare up to 255; the outbound builder is bounded by the count field instead, and returns an overflow rather than truncating a list that will not fit (`src/wire/stock_te.zig:1396`, `:1402`). `broadcastPoweredTriggerTe` refuses to describe a cell with no registered trigger, builds the wire list from the grid edges with the parent left at zero because the sim graph is undirected, and propagates an encode failure instead of silently leaving remotes with a stale switch (`src/server/replicate_te.zig:224`, `:249`). On the C2S side, a trigger payload is tried last and gated on the outer block id resolving to a registered power block, so the reader cannot swallow a storage or workstation body (`src/server/c2s/inv.zig:711`). Delay, duration and reset are applied when the trigger type carries them; a switch's state arrives on the block path instead, and a motion sensor's target mask is stored so the echo cannot reset the player's selection to zero (`src/server/c2s/inv.zig:735`).

The stock wiring package is `NetPackageWireActions`, whose body is an operation byte, the child position, a child count and the child positions, with `SetParent` connecting the child to the first declared parent, `RemoveParent` dropping the child's edges, and `SendWires` accepted as a client-only visual with no topology change (`src/ecs/electric.zig:825`, `:844`). The handler takes the same block rate token as `SetBlock`, applies it to the grid, and rebroadcasts the raw package so peers get the client-side wire visual (`src/server/c2s/misc.zig:1266`). A light tile entity is a separate body: the stock `TileEntityLight` network write carries a fixed version 18 and then nine fields, all of which the client always reads on that path, so the builder writes every one and nothing brackets the payload with a size marker (`src/wire/stock_te.zig:1834`). The light data itself is authored per prefab marker, and the sender uses the real world block id at the position because the client drops a tile-entity package whose block id disagrees with the block it holds (`src/server/replicate_te.zig:449`, `:452`). The tile-entity type bytes for the powered family are named constants in `te_types.zig`: powered 0x0F, power source 0x10, light 0x12, trigger 0x13 (`src/wire/te_types.zig:20`).

## Persistence

The grid layout is not saved; it is rebuilt from the block plane when a chunk is first scanned, which the store records as a scan flag (`src/world/store.zig:140`). What is saved is the part a rebuild cannot recover: the wiring edges and the player-set node state, both keyed by world position because node ids are reassigned every session (`src/ecs/electric.zig:115`, `:127`). Edges are written as endpoint position pairs, live and pending in one record, because writing only the live list dropped every edge whose endpoints sat in unvisited chunks (`src/server/persist.zig:1696`). The node record carries the type byte, the position, the fuel or energy value, the delay and duration indices and the target mask, and only a node that differs from a fresh scan is written so an untouched world does not grow the file (`src/server/persist.zig:1736`, `:1747`):

```zig
        const n = self.sim.power.nodes[ni];
        const fuel_default = n.capacity;
        const configured = n.fuel_or_energy != fuel_default or
            n.delay_idx != 0 or n.duration_idx != 1 or n.target_type != 0;
        if (!configured) continue;
        try w.writeByte(zen_rec_power);
        try w.writeI32(n.x);
        try w.writeI32(n.y);
        try w.writeI32(n.z);
        try w.writeF32(n.fuel_or_energy);
        try w.writeByte(n.delay_idx);
        try w.writeByte(n.duration_idx);
        try w.writeI32(n.target_type);
```

On load, an edge whose endpoints have not come back yet queues as a pending wire and `reconnectPending` promotes it after each chunk power scan; node state queues the same way and `applyPendingState` clamps a restored fuel value to the current capacity, because a game-data change can lower it below what the save recorded (`src/ecs/electric.zig:202`, `:238`). The switch latch is deliberately absent from the save: it already rides the block meta, which the block plane persists (`src/ecs/electric.zig:129`). The trigger delay and duration defaults (instant, Triggered) and the pulse duration are the only values that cannot be recovered from block data, and they are the reason the node record exists at all (`src/server/persist.zig:1528`).

## See also

- [`ecs.md`](ecs.md): the SoA world, the entity table and the turret component the grid links to.
- [`tick.md`](tick.md): the sim schedule and why power resolution sits in the server step.
- [`wire.md`](wire.md): the binary helpers and the tile-entity package framing.
- [`persistence.md`](persistence.md): the world save format these records are written into.
- [`world-store.md`](world-store.md): the chunk store and the block plane the grid is rebuilt from.
