//! Electricity / power graph: generators, wires, consumers (turrets, lights, …).
//! Simplified from stock PowerManager concepts (not full wiring UI parity).

const std = @import("std");

pub const max_nodes: usize = 256;
pub const max_wires: usize = 512;

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
};

pub const Wire = struct {
    a: u16 = 0,
    b: u16 = 0,
};

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
        self.nodes[self.node_n] = .{
            .id = id,
            .kind = kind,
            .x = x,
            .y = y,
            .z = z,
            .watts = watts,
            .on = true,
            .powered = kind == .generator,
        };
        self.node_n += 1;
        return id;
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

    /// BFS power flood from generators; batteries store leftover conceptually.
    pub fn resolve(self: *PowerGrid) void {
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

        i = 0;
        while (i < self.node_n) : (i += 1) {
            if (self.nodes[i].kind == .generator and self.nodes[i].on) {
                queue[qt] = i;
                qt += 1;
                visited[i] = true;
                self.nodes[i].powered = true;
                self.total_gen += self.nodes[i].watts;
            }
        }

        while (qh < qt) {
            const u = queue[qh];
            qh += 1;
            const uid = self.nodes[u].id;
            var w: usize = 0;
            while (w < self.wire_n) : (w += 1) {
                const wire = self.wires[w];
                const other_id: u16 = if (wire.a == uid) wire.b else if (wire.b == uid) wire.a else continue;
                const oi = self.indexOfId(other_id) orelse continue;
                if (visited[oi]) continue;
                if (!self.nodes[oi].on and self.nodes[oi].kind != .relay) continue;
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
            const kind: NodeKind = @enumFromInt(body[1]);
            const x = std.mem.readInt(i32, body[2..6], .little);
            const y = std.mem.readInt(i32, body[6..10], .little);
            const z = std.mem.readInt(i32, body[10..14], .little);
            const wbits = std.mem.readInt(u32, body[14..18], .little);
            const watts: f32 = @bitCast(wbits);
            _ = self.addNode(kind, x, y, z, watts);
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
    // One of the consumers should be unpowered
    const pa = g.nodes[g.indexOfId(a).?].powered;
    const pb = g.nodes[g.indexOfId(b).?].powered;
    try std.testing.expect(!(pa and pb));
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
