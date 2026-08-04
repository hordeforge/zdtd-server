//! Electricity / power graph: generators, wires, consumers (turrets, lights, …).
//! Simplified from stock PowerManager concepts (not full wiring UI parity).

const std = @import("std");

pub const max_nodes: usize = 256;
pub const max_wires: usize = 512;
/// Sanity ceiling for a wire-supplied node rating; stock generators are ~1 kW.
pub const max_node_watts: f32 = 100_000;
/// Pressure plate / tripwire pulse duration (seconds). ~10 ticks at 20 TPS.
pub const default_trigger_pulse_s: f32 = 0.5;

pub const NodeKind = enum(u8) {
    generator = 0,
    battery = 1,
    relay = 2,
    consumer = 3, // turret, light, fridge, etc.
};

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
    /// Generator max fuel / battery capacity (set at add).
    capacity: f32 = 0,
    /// Generator: fuel burn per second when on. Battery unused.
    burn_rate: f32 = 0,
    /// Trigger/timer: seconds remaining until next toggle (0 = idle).
    timer_left: f32 = 0,
    /// Trigger: seconds between actuations when armed (0 = not a timer).
    timer_period: f32 = 0,
    /// Solar (no MaxFuel): only contributes when daylight is true.
    solar: bool = false,
    /// PressurePlate / TripWire / MotionSensor / Trigger: step actuation.
    is_trigger: bool = false,
    /// Seconds of active trigger pulse remaining (0 = idle).
    pulse_left: f32 = 0,
};

pub const Wire = struct {
    a: u16 = 0,
    b: u16 = 0,
};

/// Binary search a sorted (id << 16 | node_index) table for `id`.
/// Returns the node index, or maxInt(u16) when the id is absent.
fn findNodeIdx(sorted: []const u32, id: u16) u16 {
    var lo: usize = 0;
    var hi: usize = sorted.len;
    const key = @as(u32, id) << 16;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (sorted[mid] < key) lo = mid + 1 else hi = mid;
    }
    if (lo < sorted.len and (sorted[lo] >> 16) == id) return @truncate(sorted[lo]);
    return std.math.maxInt(u16);
}

pub const PowerGrid = struct {
    nodes: [max_nodes]PowerNode = [_]PowerNode{.{}} ** max_nodes,
    node_n: usize = 0,
    wires: [max_wires]Wire = [_]Wire{.{}} ** max_wires,
    wire_n: usize = 0,
    next_id: u16 = 1,
    total_gen: f32 = 0,
    total_load: f32 = 0,

    pub fn clear(self: *PowerGrid) void {
        self.node_n = 0;
        self.wire_n = 0;
        self.next_id = 1;
        self.total_gen = 0;
        self.total_load = 0;
    }

    pub fn addNode(self: *PowerGrid, kind: NodeKind, x: i32, y: i32, z: i32, watts: f32) ?u16 {
        if (self.node_n >= max_nodes) return null;
        const id = self.next_id;
        self.next_id +%= 1;
        // Fuel/capacity/burn left 0 unless caller applies stock props (powerblocks.Resolved).
        self.nodes[self.node_n] = .{
            .id = id,
            .kind = kind,
            .x = x,
            .y = y,
            .z = z,
            .watts = watts,
            .on = true,
            .powered = kind == .generator,
            .fuel_or_energy = 0,
            .capacity = 0,
            .burn_rate = 0,
        };
        self.node_n += 1;
        return id;
    }

    /// Place or update node at position, then apply stock fuel/SoC props.
    pub fn addNodeAtResolved(
        self: *PowerGrid,
        kind: NodeKind,
        x: i32,
        y: i32,
        z: i32,
        watts: f32,
        apply: *const fn (*PowerNode) void,
    ) ?u16 {
        const id = self.addNodeAt(kind, x, y, z, watts) orelse return null;
        if (self.indexOfId(id)) |i| apply(&self.nodes[i]);
        return id;
    }

    /// Arm a trigger/timer node: period seconds between on/off toggles of `target_id` consumer.
    pub fn armTimer(self: *PowerGrid, id: u16, period_s: f32) bool {
        const i = self.indexOfId(id) orelse return false;
        if (period_s <= 0) return false;
        self.nodes[i].timer_period = period_s;
        self.nodes[i].timer_left = period_s;
        return true;
    }

    /// Actuate a pressure plate / tripwire at world position. Fail closed: requires an
    /// `is_trigger` node that is already powered (wired to a live generator). Starts a
    /// pulse so BFS floods past the gate for `default_trigger_pulse_s`.
    /// Returns false if no trigger, unpowered, or missing node.
    pub fn activateTriggerAt(self: *PowerGrid, x: i32, y: i32, z: i32) bool {
        const i = self.indexOfPosition(x, y, z) orelse return false;
        if (!self.nodes[i].is_trigger) return false;
        // Ensure connectivity is current before the powered gate.
        self.resolve();
        if (!self.nodes[i].powered) return false;
        self.nodes[i].pulse_left = default_trigger_pulse_s;
        self.resolve();
        return true;
    }

    /// Advance fuel burn, battery charge/discharge, and trigger timers. Call after resolve intent.
    /// `dt` in seconds. `daylight` gates solar generators (no MaxFuel). Returns true if state changed.
    pub fn tick(self: *PowerGrid, dt: f32, daylight: bool) bool {
        if (dt <= 0 or self.node_n == 0) return false;
        var dirty = false;
        // 1) Burn generator fuel when capacity>0 (MaxFuel from XML). Solar: on only in daylight.
        var i: usize = 0;
        while (i < self.node_n) : (i += 1) {
            var n = &self.nodes[i];
            if (n.kind != .generator) continue;
            if (n.solar) {
                // Solar: keep desired on flag; resolve skips when !daylight via powered gate.
                if (n.on and !daylight and n.powered) {
                    n.powered = false;
                    dirty = true;
                }
                continue;
            }
            if (!n.on or n.capacity <= 0) continue;
            if (n.fuel_or_energy <= 0) {
                n.on = false;
                n.powered = false;
                dirty = true;
                continue;
            }
            if (n.burn_rate > 0) {
                n.fuel_or_energy = @max(0, n.fuel_or_energy - n.burn_rate * dt);
                if (n.fuel_or_energy <= 0) {
                    n.on = false;
                    n.powered = false;
                    dirty = true;
                }
            }
        }
        // 2) Resolve connectivity + load shed with current on flags.
        self.resolveDay(daylight);
        // 3) Battery: discharge to cover shortfall, charge on surplus.
        var gen_now: f32 = 0;
        var load_now: f32 = 0;
        i = 0;
        while (i < self.node_n) : (i += 1) {
            const n = &self.nodes[i];
            if (n.kind == .generator and n.on and n.powered) gen_now += n.watts;
            if (n.kind == .consumer and n.powered) load_now += n.watts;
        }
        const shortfall = load_now - gen_now;
        if (shortfall > 0) {
            var need = shortfall * dt;
            i = 0;
            while (i < self.node_n and need > 0) : (i += 1) {
                var n = &self.nodes[i];
                if (n.kind != .battery or !n.powered) continue;
                const take = @min(n.fuel_or_energy, need);
                n.fuel_or_energy -= take;
                need -= take;
            }
            // Residual need: batteries empty; consumers already load-shed vs gen-only.
            if (need > 0.001) dirty = true;
        } else if (shortfall < 0) {
            var surplus = (-shortfall) * dt;
            i = 0;
            while (i < self.node_n and surplus > 0) : (i += 1) {
                var n = &self.nodes[i];
                if (n.kind != .battery or !n.powered) continue;
                const room = n.capacity - n.fuel_or_energy;
                const add = @min(room, surplus);
                n.fuel_or_energy += add;
                surplus -= add;
            }
        }
        // 4) Trigger timers: when period elapses, toggle linked consumer by entity or self.on.
        i = 0;
        while (i < self.node_n) : (i += 1) {
            var n = &self.nodes[i];
            if (n.timer_period <= 0) continue;
            if (!n.powered and n.kind != .generator) continue;
            n.timer_left -= dt;
            if (n.timer_left > 0) continue;
            n.timer_left = n.timer_period;
            // Toggle self if consumer/relay; else toggle first wired consumer.
            if (n.kind == .consumer or n.kind == .relay) {
                n.on = !n.on;
                dirty = true;
            } else if (n.entity_id >= 0) {
                if (self.indexOfEntity(n.entity_id)) |ti| {
                    self.nodes[ti].on = !self.nodes[ti].on;
                    dirty = true;
                }
            } else {
                // Toggle nearest wired consumer.
                const uid = n.id;
                var w: usize = 0;
                while (w < self.wire_n) : (w += 1) {
                    const wire = self.wires[w];
                    const other: u16 = if (wire.a == uid) wire.b else if (wire.b == uid) wire.a else continue;
                    if (self.indexOfId(other)) |oi| {
                        if (self.nodes[oi].kind == .consumer) {
                            self.nodes[oi].on = !self.nodes[oi].on;
                            dirty = true;
                            break;
                        }
                    }
                }
            }
        }
        // 5) Trigger pulses: count down; expire clears signal path (re-resolve).
        i = 0;
        while (i < self.node_n) : (i += 1) {
            var n = &self.nodes[i];
            if (n.pulse_left <= 0) continue;
            n.pulse_left -= dt;
            if (n.pulse_left <= 0) {
                n.pulse_left = 0;
                dirty = true;
            }
        }
        if (dirty) self.resolveDay(daylight);
        return dirty;
    }

    /// Refuel generator at position (admin/console/item use). Returns false if no gen there.
    pub fn refuelAt(self: *PowerGrid, x: i32, y: i32, z: i32, amount: f32) bool {
        const i = self.indexOfPosition(x, y, z) orelse return false;
        if (self.nodes[i].kind != .generator) return false;
        if (self.nodes[i].capacity <= 0) {
            // Establish a fuel tank if stock props were never applied (tests/admin).
            self.nodes[i].capacity = amount;
            self.nodes[i].fuel_or_energy = amount;
        } else {
            self.nodes[i].fuel_or_energy = @min(self.nodes[i].capacity, self.nodes[i].fuel_or_energy + amount);
        }
        if (self.nodes[i].fuel_or_energy > 0 and !self.nodes[i].on) {
            self.nodes[i].on = true;
            self.resolve();
        }
        return true;
    }

    pub fn indexOfId(self: *const PowerGrid, id: u16) ?usize {
        var i: usize = 0;
        while (i < self.node_n) : (i += 1) {
            if (self.nodes[i].id == id) return i;
        }
        return null;
    }

    pub fn indexOfPosition(self: *const PowerGrid, x: i32, y: i32, z: i32) ?usize {
        var i: usize = 0;
        while (i < self.node_n) : (i += 1) {
            const n = self.nodes[i];
            if (n.x == x and n.y == y and n.z == z) return i;
        }
        return null;
    }

    /// Register a node at a world position. Idempotent: if a node already occupies
    /// the position, returns its existing id rather than duplicating.
    pub fn addNodeAt(self: *PowerGrid, kind: NodeKind, x: i32, y: i32, z: i32, watts: f32) ?u16 {
        if (self.indexOfPosition(x, y, z)) |i| return self.nodes[i].id;
        return self.addNode(kind, x, y, z, watts);
    }

    /// Remove all wires referencing an id, compacting the wire array.
    fn removeWiresForId(self: *PowerGrid, id: u16) void {
        var w: usize = 0;
        while (w < self.wire_n) {
            const wire = self.wires[w];
            if (wire.a == id or wire.b == id) {
                self.wires[w] = self.wires[self.wire_n - 1];
                self.wire_n -= 1;
            } else {
                w += 1;
            }
        }
    }

    /// Delete the node at a position and every wire incident to it. Returns false
    /// if no node occupies the position.
    pub fn removeAt(self: *PowerGrid, x: i32, y: i32, z: i32) bool {
        const idx = self.indexOfPosition(x, y, z) orelse return false;
        const id = self.nodes[idx].id;
        self.removeWiresForId(id);
        self.nodes[idx] = self.nodes[self.node_n - 1];
        self.node_n -= 1;
        return true;
    }

    /// Delete a node by identity and every wire incident to it. Positions are not
    /// unique (addNode does not dedupe), so owners that hold an id must remove by
    /// id or they unplug whichever node happens to share the cell.
    pub fn removeById(self: *PowerGrid, id: u16) bool {
        const idx = self.indexOfId(id) orelse return false;
        self.removeWiresForId(id);
        self.nodes[idx] = self.nodes[self.node_n - 1];
        self.node_n -= 1;
        return true;
    }

    /// Connect two nodes identified by their world positions. Returns false if
    /// either position has no node.
    pub fn connectByPos(self: *PowerGrid, ax: i32, ay: i32, az: i32, bx: i32, by: i32, bz: i32) bool {
        const ai = self.indexOfPosition(ax, ay, az) orelse return false;
        const bi = self.indexOfPosition(bx, by, bz) orelse return false;
        return self.connect(self.nodes[ai].id, self.nodes[bi].id);
    }

    /// Undirected simplification of stock RemoveParent: drop every wire incident
    /// to the node at a position. Returns false if no node occupies it.
    pub fn removeParentAt(self: *PowerGrid, x: i32, y: i32, z: i32) bool {
        const idx = self.indexOfPosition(x, y, z) orelse return false;
        self.removeWiresForId(self.nodes[idx].id);
        return true;
    }

    pub fn indexOfEntity(self: *const PowerGrid, eid: i32) ?usize {
        var i: usize = 0;
        while (i < self.node_n) : (i += 1) {
            if (self.nodes[i].entity_id == eid) return i;
        }
        return null;
    }

    pub fn connect(self: *PowerGrid, a: u16, b: u16) bool {
        if (a == b) return false;
        if (self.indexOfId(a) == null or self.indexOfId(b) == null) return false;
        // no dup
        var i: usize = 0;
        while (i < self.wire_n) : (i += 1) {
            const w = self.wires[i];
            if ((w.a == a and w.b == b) or (w.a == b and w.b == a)) return true;
        }
        if (self.wire_n >= max_wires) return false;
        self.wires[self.wire_n] = .{ .a = a, .b = b };
        self.wire_n += 1;
        return true;
    }

    /// BFS power flood from generators (daylight=true for solar).
    pub fn resolve(self: *PowerGrid) void {
        self.resolveDay(true);
    }

    /// BFS power flood; solar generators only source when `daylight`.
    pub fn resolveDay(self: *PowerGrid, daylight: bool) void {
        // Reset
        self.total_gen = 0;
        self.total_load = 0;
        var i: usize = 0;
        while (i < self.node_n) : (i += 1) {
            self.nodes[i].powered = false;
        }

        // Mark reachable from any on generator via wires (undirected).
        var visited: [max_nodes]bool = .{false} ** max_nodes;
        var queue: [max_nodes]usize = undefined;
        var qh: usize = 0;
        var qt: usize = 0;

        // Resolve wire endpoints to node indices once up front via a sorted
        // (id << 16 | index) table: indexOfId is a linear scan, and per-endpoint
        // lookups made this O(wires x nodes) per tick.
        const no_node: u16 = std.math.maxInt(u16);
        var id_idx: [max_nodes]u32 = undefined;
        var k: usize = 0;
        while (k < self.node_n) : (k += 1) {
            id_idx[k] = (@as(u32, self.nodes[k].id) << 16) | @as(u32, @intCast(k));
        }
        const sorted = id_idx[0..self.node_n];
        std.sort.pdq(u32, sorted, {}, std.sort.asc(u32));
        var wire_ai: [max_wires]u16 = undefined;
        var wire_bi: [max_wires]u16 = undefined;
        var wi: usize = 0;
        while (wi < self.wire_n) : (wi += 1) {
            wire_ai[wi] = findNodeIdx(sorted, self.wires[wi].a);
            wire_bi[wi] = findNodeIdx(sorted, self.wires[wi].b);
        }

        // Adjacency (CSR) so the BFS visits only incident edges instead of
        // rescanning every wire per dequeued node (was O(nodes x wires)).
        var deg: [max_nodes]u16 = .{0} ** max_nodes;
        wi = 0;
        while (wi < self.wire_n) : (wi += 1) {
            if (wire_ai[wi] == no_node or wire_bi[wi] == no_node) continue;
            deg[wire_ai[wi]] += 1;
            deg[wire_bi[wi]] += 1;
        }
        var adj_start: [max_nodes + 1]u16 = undefined;
        adj_start[0] = 0;
        k = 0;
        while (k < self.node_n) : (k += 1) adj_start[k + 1] = adj_start[k] + deg[k];
        var cursor: [max_nodes]u16 = undefined;
        @memcpy(cursor[0..self.node_n], adj_start[0..self.node_n]);
        var adj: [2 * max_wires]u16 = undefined;
        wi = 0;
        while (wi < self.wire_n) : (wi += 1) {
            const a = wire_ai[wi];
            const b = wire_bi[wi];
            if (a == no_node or b == no_node) continue;
            adj[cursor[a]] = b;
            cursor[a] += 1;
            adj[cursor[b]] = a;
            cursor[b] += 1;
        }

        i = 0;
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

        while (qh < qt) {
            const u: u16 = @intCast(queue[qh]);
            qh += 1;
            // Trigger gates: only flood past the plate while a pulse is active.
            // The trigger node itself stays powered (visited when enqueued).
            if (self.nodes[u].is_trigger and self.nodes[u].pulse_left <= 0) continue;
            for (adj[adj_start[u]..adj_start[u + 1]]) |other| {
                const oi: usize = other;
                if (visited[oi]) continue;
                // Relays always pass; triggers can be reached (to become powered);
                // other nodes need .on.
                if (!self.nodes[oi].on and self.nodes[oi].kind != .relay and !self.nodes[oi].is_trigger) continue;
                visited[oi] = true;
                queue[qt] = oi;
                qt += 1;
                self.nodes[oi].powered = true;
            }
        }

        // Load vs gen: if total consumer demand on powered graph exceeds gen, drop lowest priority (highest id consumers).
        var demand: f32 = 0;
        i = 0;
        while (i < self.node_n) : (i += 1) {
            if (self.nodes[i].powered and self.nodes[i].kind == .consumer) {
                demand += self.nodes[i].watts;
            }
        }
        self.total_load = demand;
        if (demand > self.total_gen and self.total_gen > 0) {
            // Unpower consumers from the end until under budget.
            var over = demand - self.total_gen;
            var j: isize = @intCast(self.node_n);
            while (j > 0 and over > 0) {
                j -= 1;
                const ji: usize = @intCast(j);
                if (self.nodes[ji].powered and self.nodes[ji].kind == .consumer) {
                    self.nodes[ji].powered = false;
                    over -= self.nodes[ji].watts;
                    self.total_load -= self.nodes[ji].watts;
                }
            }
        } else if (self.total_gen <= 0) {
            i = 0;
            while (i < self.node_n) : (i += 1) {
                if (self.nodes[i].kind != .generator) self.nodes[i].powered = false;
            }
            self.total_load = 0;
        }
    }

    pub fn isEntityPowered(self: *const PowerGrid, eid: i32) bool {
        if (self.indexOfEntity(eid)) |i| return self.nodes[i].powered;
        return false;
    }

    /// Wire action body: op u8 (0=add_node,1=connect,2=toggle), then fields.
    /// connect: a u16, b u16
    /// toggle: id u16
    pub fn applyWireAction(self: *PowerGrid, body: []const u8) bool {
        if (body.len < 1) return false;
        const op = body[0];
        if (op == 1 and body.len >= 5) {
            const a = std.mem.readInt(u16, body[1..3], .little);
            const b = std.mem.readInt(u16, body[3..5], .little);
            const ok = self.connect(a, b);
            if (ok) self.resolve();
            return ok;
        }
        if (op == 2 and body.len >= 3) {
            const id = std.mem.readInt(u16, body[1..3], .little);
            if (self.indexOfId(id)) |i| {
                self.nodes[i].on = !self.nodes[i].on;
                self.resolve();
                return true;
            }
        }
        if (op == 0 and body.len >= 1 + 1 + 12 + 4) {
            // kind u8, x i32, y i32, z i32, watts f32 bits
            if (body[1] > @intFromEnum(NodeKind.consumer)) return false;
            const kind: NodeKind = @enumFromInt(body[1]);
            const x = std.mem.readInt(i32, body[2..6], .little);
            const y = std.mem.readInt(i32, body[6..10], .little);
            const z = std.mem.readInt(i32, body[10..14], .little);
            const wbits = std.mem.readInt(u32, body[14..18], .little);
            const watts: f32 = @bitCast(wbits);
            // total_gen/total_load accumulate across resolve() and are never
            // re-derived, so one NaN from the wire poisons every powered check.
            if (!std.math.isFinite(watts) or watts < 0 or watts > max_node_watts) return false;
            // addNodeAt, not addNode: repeated requests must not stack duplicate
            // nodes on one cell until max_nodes is exhausted.
            _ = self.addNodeAt(kind, x, y, z, watts);
            self.resolve();
            return true;
        }
        return false;
    }

    /// Parse the stock NetPackageWireActions body (payload after the package id):
    ///   [0]=currentOperation u8 {0=SetParent,1=RemoveParent,2=SendWires}
    ///   [1..13]=tileEntityPosition Vector3i (3x i32 LE, the CHILD)
    ///   [13]=childCount u8; then childCount * Vector3i (12 bytes each)
    ///   if op != 2: trailing 4 bytes wiringEntityID i32 LE (unused here)
    /// Grounded in NetPackageWireActions::read (asm.il:842779) and ProcessPackage
    /// SetParent (asm.il:842922) / RemoveParent (asm.il:843021). SetParent wires
    /// tileEntityPosition (child) to wireChildren[0] (parent); RemoveParent drops
    /// the child's parent edge. Returns false on malformed input.
    pub fn applyWireActionsStock(self: *PowerGrid, body: []const u8) bool {
        if (body.len < 14) return false;
        const op = body[0];
        const tx = std.mem.readInt(i32, body[1..5], .little);
        const ty = std.mem.readInt(i32, body[5..9], .little);
        const tz = std.mem.readInt(i32, body[9..13], .little);
        const child_count = body[13];
        // Reject if the declared children do not fit the buffer.
        const children_bytes = @as(usize, child_count) * 12;
        if (body.len < 14 + children_bytes) return false;
        switch (op) {
            0 => { // SetParent: connect child -> wireChildren[0] (only [0] used).
                if (child_count < 1) return false;
                const px = std.mem.readInt(i32, body[14..18], .little);
                const py = std.mem.readInt(i32, body[18..22], .little);
                const pz = std.mem.readInt(i32, body[22..26], .little);
                const ok = self.connectByPos(tx, ty, tz, px, py, pz);
                if (ok) self.resolve();
                return ok;
            },
            1 => { // RemoveParent: drop edges incident to the child node.
                const ok = self.removeParentAt(tx, ty, tz);
                if (ok) self.resolve();
                return ok;
            },
            2 => return true, // SendWires: client visual only, no topology change.
            else => return false,
        }
    }
};

test "generator powers wired consumer" {
    var g: PowerGrid = .{};
    const gen = g.addNode(.generator, 0, 70, 0, 100).?;
    const load = g.addNode(.consumer, 5, 70, 0, 40).?;
    try std.testing.expect(g.connect(gen, load));
    g.resolve();
    try std.testing.expect(g.nodes[g.indexOfId(load).?].powered);
    try std.testing.expectEqual(@as(f32, 100), g.total_gen);
    try std.testing.expectEqual(@as(f32, 40), g.total_load);
}

test "overload drops consumers" {
    var g: PowerGrid = .{};
    const gen = g.addNode(.generator, 0, 70, 0, 30).?;
    const a = g.addNode(.consumer, 1, 70, 0, 20).?;
    const b = g.addNode(.consumer, 2, 70, 0, 20).?;
    _ = g.connect(gen, a);
    _ = g.connect(gen, b);
    g.resolve();
    // Load shed walks nodes from the end: higher index (b) drops first so demand fits gen.
    try std.testing.expect(g.nodes[g.indexOfId(a).?].powered);
    try std.testing.expect(!g.nodes[g.indexOfId(b).?].powered);
    try std.testing.expectEqual(@as(f32, 30), g.total_gen);
    try std.testing.expectEqual(@as(f32, 20), g.total_load);
}

test "wire action connect" {
    var g: PowerGrid = .{};
    const gen = g.addNode(.generator, 0, 70, 0, 50).?;
    const load = g.addNode(.consumer, 1, 70, 0, 10).?;
    var body: [5]u8 = undefined;
    body[0] = 1;
    std.mem.writeInt(u16, body[1..3], gen, .little);
    std.mem.writeInt(u16, body[3..5], load, .little);
    try std.testing.expect(g.applyWireAction(&body));
    try std.testing.expect(g.nodes[g.indexOfId(load).?].powered);
}

test "addNodeAt is idempotent by position" {
    var g: PowerGrid = .{};
    const a = g.addNodeAt(.generator, 3, 70, 4, 100).?;
    const b = g.addNodeAt(.consumer, 3, 70, 4, 50).?;
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(usize, 1), g.node_n);
}

test "connectByPos and removeAt drop incident wires" {
    var g: PowerGrid = .{};
    _ = g.addNodeAt(.generator, 0, 70, 0, 100).?;
    const load = g.addNodeAt(.consumer, 5, 70, 0, 40).?;
    try std.testing.expect(g.connectByPos(0, 70, 0, 5, 70, 0));
    g.resolve();
    try std.testing.expect(g.nodes[g.indexOfId(load).?].powered);
    // Removing the generator drops the wire and unpowers the consumer.
    try std.testing.expect(g.removeAt(0, 70, 0));
    try std.testing.expectEqual(@as(usize, 0), g.wire_n);
    g.resolve();
    try std.testing.expect(!g.nodes[g.indexOfId(load).?].powered);
}

fn writeVec3i(buf: []u8, x: i32, y: i32, z: i32) void {
    std.mem.writeInt(i32, buf[0..4], x, .little);
    std.mem.writeInt(i32, buf[4..8], y, .little);
    std.mem.writeInt(i32, buf[8..12], z, .little);
}

test "stock SetParent then RemoveParent toggles powered" {
    var g: PowerGrid = .{};
    // Placed nodes: generator at (0,70,0), consumer (child) at (5,70,0).
    _ = g.addNodeAt(.generator, 0, 70, 0, 100).?;
    const load = g.addNodeAt(.consumer, 5, 70, 0, 40).?;
    // SetParent body: op=0, tileEntityPosition=child(5,70,0), childCount=1,
    // wireChildren[0]=parent(0,70,0), trailing wiringEntityID.
    var set: [30]u8 = undefined;
    set[0] = 0;
    writeVec3i(set[1..13], 5, 70, 0);
    set[13] = 1;
    writeVec3i(set[14..26], 0, 70, 0);
    std.mem.writeInt(i32, set[26..30], 99, .little);
    try std.testing.expect(g.applyWireActionsStock(&set));
    try std.testing.expect(g.nodes[g.indexOfId(load).?].powered);
    // RemoveParent body: op=1, tileEntityPosition=child, childCount=0, trailing id.
    var rem: [18]u8 = undefined;
    rem[0] = 1;
    writeVec3i(rem[1..13], 5, 70, 0);
    rem[13] = 0;
    std.mem.writeInt(i32, rem[14..18], 99, .little);
    try std.testing.expect(g.applyWireActionsStock(&rem));
    try std.testing.expect(!g.nodes[g.indexOfId(load).?].powered);
}

test "stock wire action rejects malformed child count" {
    var g: PowerGrid = .{};
    _ = g.addNodeAt(.generator, 0, 70, 0, 100).?;
    // op=0 declares 3 children but body only holds one Vector3i.
    var bad: [26]u8 = undefined;
    bad[0] = 0;
    writeVec3i(bad[1..13], 5, 70, 0);
    bad[13] = 3;
    writeVec3i(bad[14..26], 0, 70, 0);
    try std.testing.expect(!g.applyWireActionsStock(&bad));
    // Too short for even the header.
    try std.testing.expect(!g.applyWireActionsStock(&[_]u8{ 0, 1, 2 }));
}

test "generator fuel burn empties and unpowers" {
    var g: PowerGrid = .{};
    const gen = g.addNodeAt(.generator, 0, 70, 0, 100).?;
    const load = g.addNodeAt(.consumer, 5, 70, 0, 40).?;
    try std.testing.expect(g.connect(gen, load));
    // Stock-like props (tests apply explicitly; production uses powerblocks.Resolved).
    const gi = g.indexOfId(gen).?;
    g.nodes[gi].capacity = 1000;
    g.nodes[gi].fuel_or_energy = 1000;
    g.nodes[gi].burn_rate = 1;
    g.resolve();
    try std.testing.expect(g.nodes[g.indexOfId(load).?].powered);
    // Fast-burn: set tiny fuel and high burn rate.
    g.nodes[gi].fuel_or_energy = 2;
    g.nodes[gi].burn_rate = 10;
    _ = g.tick(1.0, true);
    try std.testing.expect(g.nodes[gi].fuel_or_energy <= 0);
    try std.testing.expect(!g.nodes[gi].on);
    try std.testing.expect(!g.nodes[g.indexOfId(load).?].powered);
    // Refuel restores.
    try std.testing.expect(g.refuelAt(0, 70, 0, 100));
    try std.testing.expect(g.nodes[gi].on);
    try std.testing.expect(g.nodes[g.indexOfId(load).?].powered);
}

test "battery charges on surplus and discharges on shortfall" {
    var g: PowerGrid = .{};
    const gen = g.addNodeAt(.generator, 0, 70, 0, 100).?;
    const bat = g.addNodeAt(.battery, 2, 70, 0, 0).?;
    const load = g.addNodeAt(.consumer, 5, 70, 0, 40).?;
    try std.testing.expect(g.connect(gen, bat));
    try std.testing.expect(g.connect(bat, load));
    const bi = g.indexOfId(bat).?;
    g.nodes[bi].fuel_or_energy = 100;
    g.nodes[bi].capacity = 1000;
    _ = g.tick(1.0, true);
    // Surplus gen: battery should gain energy.
    try std.testing.expect(g.nodes[bi].fuel_or_energy > 100);
    // Kill gen fuel: battery still holds charge (gen off after burn).
    const gi = g.indexOfId(gen).?;
    g.nodes[gi].fuel_or_energy = 0;
    g.nodes[gi].on = false;
    g.resolve();
    // Without gen, consumers unpowered (battery is buffer not infinite source in this model).
    try std.testing.expect(!g.nodes[g.indexOfId(load).?].powered);
}

test "timer toggles consumer on" {
    var g: PowerGrid = .{};
    const gen = g.addNodeAt(.generator, 0, 70, 0, 100).?;
    const load = g.addNodeAt(.consumer, 5, 70, 0, 40).?;
    try std.testing.expect(g.connect(gen, load));
    g.resolve();
    try std.testing.expect(g.nodes[g.indexOfId(load).?].on);
    try std.testing.expect(g.armTimer(gen, 0.5));
    _ = g.tick(0.6, true);
    // Generator timer toggles wired consumer.
    try std.testing.expect(!g.nodes[g.indexOfId(load).?].on);
}

test "solar generator day gate" {
    var g: PowerGrid = .{};
    const gen = g.addNodeAt(.generator, 0, 70, 0, 100).?;
    const load = g.addNodeAt(.consumer, 5, 70, 0, 40).?;
    try std.testing.expect(g.connect(gen, load));
    const gi = g.indexOfId(gen).?;
    g.nodes[gi].solar = true;
    g.nodes[gi].capacity = 0;
    g.nodes[gi].burn_rate = 0;
    g.resolveDay(true);
    try std.testing.expect(g.nodes[g.indexOfId(load).?].powered);
    g.resolveDay(false);
    try std.testing.expect(!g.nodes[g.indexOfId(load).?].powered);
    _ = g.tick(1.0, true);
    try std.testing.expect(g.nodes[g.indexOfId(load).?].powered);
}

test "trigger gate powers children only while pulsing" {
    var g: PowerGrid = .{};
    const gen = g.addNodeAt(.generator, 0, 70, 0, 100).?;
    const plate = g.addNodeAt(.consumer, 2, 70, 0, 1).?;
    const load = g.addNodeAt(.consumer, 5, 70, 0, 40).?;
    const pi = g.indexOfId(plate).?;
    g.nodes[pi].is_trigger = true;
    try std.testing.expect(g.connect(gen, plate));
    try std.testing.expect(g.connect(plate, load));
    g.resolve();
    // Idle plate is powered but does not pass power to the load.
    try std.testing.expect(g.nodes[pi].powered);
    try std.testing.expect(!g.nodes[g.indexOfId(load).?].powered);
    // Step on plate: pulse opens the gate.
    try std.testing.expect(g.activateTriggerAt(2, 70, 0));
    try std.testing.expect(g.nodes[pi].pulse_left > 0);
    try std.testing.expect(g.nodes[g.indexOfId(load).?].powered);
    // After pulse expires, load drops.
    _ = g.tick(default_trigger_pulse_s + 0.1, true);
    try std.testing.expectEqual(@as(f32, 0), g.nodes[pi].pulse_left);
    try std.testing.expect(!g.nodes[g.indexOfId(load).?].powered);
}

test "activateTriggerAt fails closed without trigger or power" {
    var g: PowerGrid = .{};
    // No node.
    try std.testing.expect(!g.activateTriggerAt(1, 2, 3));
    // Plain consumer is not a trigger.
    _ = g.addNodeAt(.consumer, 1, 70, 1, 10).?;
    try std.testing.expect(!g.activateTriggerAt(1, 70, 1));
    // Trigger present but not wired to a generator: unpowered.
    const plate = g.addNodeAt(.consumer, 4, 70, 4, 1).?;
    g.nodes[g.indexOfId(plate).?].is_trigger = true;
    try std.testing.expect(!g.activateTriggerAt(4, 70, 4));
}
