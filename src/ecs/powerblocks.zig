//! Stock electrical block registry from blocks.xml Class + AssignIds.
//! NodeKind mapping is RE (PowerItemTypes); names/ids/watts/fuel come from game data.

const std = @import("std");
const electric = @import("electric.zig");

pub const max_power_entries: usize = 256;

/// Full power props for one block id (from blocks.xml via maxdamage Table).
pub const Resolved = struct {
    kind: electric.NodeKind,
    watts: f32 = 0,
    /// Generator MaxFuel; 0 = no fuel budget (solar / infinite until empty rule).
    max_fuel: f32 = 0,
    /// Generator OutputPerFuel (watts sustained per fuel unit scaling).
    output_per_fuel: f32 = 0,
    /// Battery OutputPerCharge.
    output_per_charge: f32 = 0,
    /// OutputPerStack (sub-cell scale).
    output_per_stack: f32 = 0,
    /// PressurePlate / TripWire / MotionSensor / Trigger: step-actuated gate.
    is_trigger: bool = false,

    /// Fill PowerNode capacity/burn/energy from stock props. watts already on node.
    pub fn applyToNode(self: Resolved, node: *electric.PowerNode) void {
        node.is_trigger = self.is_trigger;
        if (self.is_trigger) {
            // Idle gate: BFS reaches the plate when wired, but does not flood past
            // until activateTriggerAt sets pulse_left.
            node.on = true;
        }
        switch (self.kind) {
            .generator => {
                if (self.max_fuel > 0) {
                    node.capacity = self.max_fuel;
                    node.fuel_or_energy = self.max_fuel;
                    node.solar = false;
                    // Burn so full tank lasts while producing: fuel/s ≈ watts/OutputPerFuel
                    // when OutputPerFuel set; else burn 0 (solar-like, fuel N/A).
                    if (self.output_per_fuel > 0 and self.watts > 0) {
                        node.burn_rate = self.watts / self.output_per_fuel;
                    } else {
                        node.burn_rate = 0;
                        node.capacity = 0;
                        node.fuel_or_energy = 0;
                    }
                } else {
                    // No MaxFuel (e.g. solar): no fuel drain; day-gated.
                    node.capacity = 0;
                    node.fuel_or_energy = 0;
                    node.burn_rate = 0;
                    node.solar = true;
                }
            },
            .battery => {
                // Capacity ~ MaxPower * scale; prefer OutputPerCharge * stacks proxy.
                const cap = if (self.output_per_charge > 0 and self.watts > 0)
                    self.watts * self.output_per_charge
                else if (self.watts > 0)
                    self.watts * 10
                else
                    0;
                node.capacity = cap;
                node.fuel_or_energy = cap * 0.5;
                node.burn_rate = 0;
            },
            else => {
                node.capacity = 0;
                node.fuel_or_energy = 0;
                node.burn_rate = 0;
            },
        }
    }
};

/// Map blocks.xml Class string → PowerGrid NodeKind.
/// Generator/SolarPanel → generator; BatteryBank → battery;
/// Powered/ElectricWire/TimerRelay → relay; other powered classes → consumer.
/// Class=Light decorative blocks are excluded (no RequiredPower/MaxPower).
pub fn kindFromClass(cls: []const u8) ?electric.NodeKind {
    if (std.mem.eql(u8, cls, "Generator") or std.mem.eql(u8, cls, "SolarPanel"))
        return .generator;
    if (std.mem.eql(u8, cls, "BatteryBank")) return .battery;
    if (std.mem.eql(u8, cls, "Powered") or
        std.mem.eql(u8, cls, "ElectricWire") or
        std.mem.eql(u8, cls, "TimerRelay"))
        return .relay;
    if (std.mem.eql(u8, cls, "Consumer") or
        std.mem.eql(u8, cls, "Trigger") or
        std.mem.eql(u8, cls, "Timer") or
        std.mem.eql(u8, cls, "RangedTrap") or
        std.mem.eql(u8, cls, "PressurePlate") or
        std.mem.eql(u8, cls, "Wire") or
        std.mem.eql(u8, cls, "TripWire") or
        std.mem.eql(u8, cls, "MotionSensor"))
        return .consumer;
    // Any block with power watts but unlisted Class still registers as consumer.
    return null;
}

/// Step-actuated trigger TE classes (pressure plate / tripwire / motion / generic Trigger).
pub fn classIsTrigger(cls: []const u8) bool {
    return std.mem.eql(u8, cls, "PressurePlate") or
        std.mem.eql(u8, cls, "TripWire") or
        std.mem.eql(u8, cls, "MotionSensor") or
        std.mem.eql(u8, cls, "Trigger");
}

/// Resolved id → power props, built once at load from maxdamage Table.
pub const Registry = struct {
    ids: [max_power_entries]u16 = undefined,
    kinds: [max_power_entries]electric.NodeKind = undefined,
    watts: [max_power_entries]f32 = undefined,
    max_fuel: [max_power_entries]f32 = undefined,
    output_per_fuel: [max_power_entries]f32 = undefined,
    output_per_charge: [max_power_entries]f32 = undefined,
    output_per_stack: [max_power_entries]f32 = undefined,
    is_trigger: [max_power_entries]bool = undefined,
    n: usize = 0,

    fn push(
        r: *Registry,
        id: u16,
        kind: electric.NodeKind,
        watts: f32,
        max_fuel: f32,
        opf: f32,
        opc: f32,
        ops: f32,
        is_trigger: bool,
    ) void {
        if (r.n >= max_power_entries) return;
        r.ids[r.n] = id;
        r.kinds[r.n] = kind;
        r.watts[r.n] = watts;
        r.max_fuel[r.n] = max_fuel;
        r.output_per_fuel[r.n] = opf;
        r.output_per_charge[r.n] = opc;
        r.output_per_stack[r.n] = ops;
        r.is_trigger[r.n] = is_trigger;
        r.n += 1;
    }

    fn propsFromTable(table: anytype, name: []const u8) struct { f32, f32, f32, f32, f32 } {
        // Accept *Table or *const Table; methods must exist on the pointed type.
        const T = @TypeOf(table.*);
        const w = table.wattsByName(name) orelse 0;
        const mf: f32 = if (@hasDecl(T, "maxFuelByName")) blk: {
            break :blk table.maxFuelByName(name) orelse 0;
        } else 0;
        const opf: f32 = if (@hasDecl(T, "outputPerFuelByName")) blk: {
            break :blk table.outputPerFuelByName(name) orelse 0;
        } else 0;
        const opc: f32 = if (@hasDecl(T, "outputPerChargeByName")) blk: {
            break :blk table.outputPerChargeByName(name) orelse 0;
        } else 0;
        const ops: f32 = if (@hasDecl(T, "outputPerStackByName")) blk: {
            break :blk table.outputPerStackByName(name) orelse 0;
        } else 0;
        return .{ w, mf, opf, opc, ops };
    }

    /// Sort parallel columns by block id so HashMap insertion order cannot
    /// leak into registry index order (DST / stable dumps when iterating by n).
    fn sortById(r: *Registry) void {
        if (r.n <= 1) return;
        var i: usize = 1;
        while (i < r.n) : (i += 1) {
            var j = i;
            while (j > 0 and r.ids[j] < r.ids[j - 1]) : (j -= 1) {
                std.mem.swap(u16, &r.ids[j], &r.ids[j - 1]);
                std.mem.swap(electric.NodeKind, &r.kinds[j], &r.kinds[j - 1]);
                std.mem.swap(f32, &r.watts[j], &r.watts[j - 1]);
                std.mem.swap(f32, &r.max_fuel[j], &r.max_fuel[j - 1]);
                std.mem.swap(f32, &r.output_per_fuel[j], &r.output_per_fuel[j - 1]);
                std.mem.swap(f32, &r.output_per_charge[j], &r.output_per_charge[j - 1]);
                std.mem.swap(f32, &r.output_per_stack[j], &r.output_per_stack[j - 1]);
                std.mem.swap(bool, &r.is_trigger[j], &r.is_trigger[j - 1]);
            }
        }
    }

    /// `table` must expose idByName, wattsByName, classByName, and power_class_by_name iterator.
    pub fn build(table: anytype) Registry {
        var r: Registry = .{};
        // Prefer Class-driven scan when available.
        if (@hasField(@TypeOf(table.*), "power_class_by_name")) {
            var it = table.power_class_by_name.iterator();
            while (it.next()) |e| {
                if (r.n >= max_power_entries) break;
                const name = e.key_ptr.*;
                const cls = e.value_ptr.*;
                const id = table.idByName(name) orelse continue;
                const kind = kindFromClass(cls) orelse blk: {
                    if (table.wattsByName(name) != null) break :blk electric.NodeKind.consumer;
                    continue;
                };
                const p = propsFromTable(table, name);
                r.push(id, kind, p[0], p[1], p[2], p[3], p[4], classIsTrigger(cls));
            }
            if (r.n > 0) {
                r.sortById();
                return r;
            }
        }
        // Offline fallback: resolve known names if Class map empty.
        const fallback = [_]struct { []const u8, electric.NodeKind, bool }{
            .{ "generatorbank", .generator, false },
            .{ "solarbank", .generator, false },
            .{ "batterybank", .battery, false },
            .{ "electricwirerelay", .relay, false },
            .{ "electricfencepost", .relay, false },
            .{ "electrictimerrelay", .relay, false },
            .{ "switch", .consumer, false },
            .{ "pressureplate", .consumer, true },
            .{ "autoTurret", .consumer, false },
            .{ "dartTrap", .consumer, false },
            .{ "bladeTrap", .consumer, false },
        };
        for (fallback) |e| {
            if (r.n >= max_power_entries) break;
            if (table.idByName(e[0])) |id| {
                const p = propsFromTable(table, e[0]);
                r.push(id, e[1], p[0], p[1], p[2], p[3], p[4], e[2]);
            }
        }
        r.sortById();
        return r;
    }

    pub fn lookup(self: *const Registry, block_id: u16) ?Resolved {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (self.ids[i] == block_id) {
                return .{
                    .kind = self.kinds[i],
                    .watts = self.watts[i],
                    .max_fuel = self.max_fuel[i],
                    .output_per_fuel = self.output_per_fuel[i],
                    .output_per_charge = self.output_per_charge[i],
                    .output_per_stack = self.output_per_stack[i],
                    .is_trigger = self.is_trigger[i],
                };
            }
        }
        return null;
    }
};

const StubTable = struct {
    const Row = struct {
        name: []const u8,
        id: u16,
        watts: ?f32,
        class: []const u8,
        max_fuel: ?f32 = null,
        output_per_fuel: ?f32 = null,
        output_per_charge: ?f32 = null,
    };
    rows: []const Row,
    power_class_by_name: std.StringHashMapUnmanaged([]const u8) = .{},

    fn idByName(self: *const StubTable, name: []const u8) ?u16 {
        for (self.rows) |r| if (std.mem.eql(u8, r.name, name)) return r.id;
        return null;
    }
    fn wattsByName(self: *const StubTable, name: []const u8) ?f32 {
        for (self.rows) |r| if (std.mem.eql(u8, r.name, name)) return r.watts;
        return null;
    }
    fn classByName(self: *const StubTable, name: []const u8) ?[]const u8 {
        for (self.rows) |r| if (std.mem.eql(u8, r.name, name)) return r.class;
        return null;
    }
    fn maxFuelByName(self: *const StubTable, name: []const u8) ?f32 {
        for (self.rows) |r| if (std.mem.eql(u8, r.name, name)) return r.max_fuel;
        return null;
    }
    fn outputPerFuelByName(self: *const StubTable, name: []const u8) ?f32 {
        for (self.rows) |r| if (std.mem.eql(u8, r.name, name)) return r.output_per_fuel;
        return null;
    }
    fn outputPerChargeByName(self: *const StubTable, name: []const u8) ?f32 {
        for (self.rows) |r| if (std.mem.eql(u8, r.name, name)) return r.output_per_charge;
        return null;
    }
    fn outputPerStackByName(_: *const StubTable, _: []const u8) ?f32 {
        return null;
    }
};

test "registry from class map includes fuel props" {
    var stub: StubTable = .{
        .rows = &[_]StubTable.Row{
            .{ .name = "generatorbank", .id = 19186, .watts = 12250, .class = "Generator", .max_fuel = 1000, .output_per_fuel = 11250 },
            .{ .name = "autoTurret", .id = 19208, .watts = 15, .class = "RangedTrap" },
            .{ .name = "batterybank", .id = 19190, .watts = 400, .class = "BatteryBank", .output_per_charge = 90 },
        },
    };
    try stub.power_class_by_name.put(std.testing.allocator, "generatorbank", "Generator");
    try stub.power_class_by_name.put(std.testing.allocator, "autoTurret", "RangedTrap");
    try stub.power_class_by_name.put(std.testing.allocator, "batterybank", "BatteryBank");
    defer stub.power_class_by_name.deinit(std.testing.allocator);

    const reg = Registry.build(&stub);
    const gen = reg.lookup(19186).?;
    try std.testing.expectEqual(electric.NodeKind.generator, gen.kind);
    try std.testing.expectEqual(@as(f32, 12250), gen.watts);
    try std.testing.expectEqual(@as(f32, 1000), gen.max_fuel);
    try std.testing.expectEqual(@as(f32, 11250), gen.output_per_fuel);
    const turret = reg.lookup(19208).?;
    try std.testing.expectEqual(electric.NodeKind.consumer, turret.kind);
    try std.testing.expectEqual(@as(f32, 15), turret.watts);
    const bat = reg.lookup(19190).?;
    try std.testing.expectEqual(electric.NodeKind.battery, bat.kind);
    try std.testing.expectEqual(@as(f32, 90), bat.output_per_charge);

    var node: electric.PowerNode = .{ .kind = .generator, .watts = gen.watts };
    gen.applyToNode(&node);
    try std.testing.expectEqual(@as(f32, 1000), node.capacity);
    try std.testing.expect(node.burn_rate > 0);
}

test "kindFromClass mapping" {
    try std.testing.expectEqual(electric.NodeKind.generator, kindFromClass("Generator").?);
    try std.testing.expectEqual(electric.NodeKind.battery, kindFromClass("BatteryBank").?);
    try std.testing.expectEqual(electric.NodeKind.relay, kindFromClass("ElectricWire").?);
    try std.testing.expectEqual(electric.NodeKind.consumer, kindFromClass("RangedTrap").?);
    try std.testing.expectEqual(@as(?electric.NodeKind, null), kindFromClass("Light"));
}

test "classIsTrigger and registry is_trigger on pressure plate" {
    try std.testing.expect(classIsTrigger("PressurePlate"));
    try std.testing.expect(classIsTrigger("TripWire"));
    try std.testing.expect(!classIsTrigger("RangedTrap"));
    var stub: StubTable = .{
        .rows = &[_]StubTable.Row{
            .{ .name = "pressureplate", .id = 19200, .watts = 1, .class = "PressurePlate" },
            .{ .name = "autoTurret", .id = 19208, .watts = 15, .class = "RangedTrap" },
        },
    };
    try stub.power_class_by_name.put(std.testing.allocator, "pressureplate", "PressurePlate");
    try stub.power_class_by_name.put(std.testing.allocator, "autoTurret", "RangedTrap");
    defer stub.power_class_by_name.deinit(std.testing.allocator);
    const reg = Registry.build(&stub);
    const plate = reg.lookup(19200).?;
    try std.testing.expect(plate.is_trigger);
    var node: electric.PowerNode = .{ .kind = .consumer, .watts = plate.watts };
    plate.applyToNode(&node);
    try std.testing.expect(node.is_trigger);
    try std.testing.expect(!reg.lookup(19208).?.is_trigger);
}
