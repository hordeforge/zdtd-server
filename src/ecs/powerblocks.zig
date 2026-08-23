//! Stock electrical block registry from blocks.xml Class + AssignIds.
//! NodeKind mapping is RE (PowerItemTypes); names/ids/watts/fuel come from game data.

const std = @import("std");
const electric = @import("electric.zig");

pub const max_power_entries: usize = 256;

/// Stock PowerTrigger/TriggerTypes (asm.il:900244). The byte rides the
/// TileEntityPoweredTrigger payload and decides which optional fields follow it.
pub const TriggerType = enum(u8) {
    @"switch" = 0,
    pressure_plate = 1,
    timer_relay = 2,
    motion = 3,
    trip_wire = 4,
};

/// Registry column sentinel for "this block is not a PowerTrigger tile entity".
const trigger_type_none: u8 = 0xff;

/// Stock PowerItem/PowerItemTypes byte for a trigger's PowerItem. PowerTrigger
/// reports Trigger=3 (asm.il:900326), PowerPressurePlate 11 (asm.il:901440) and
/// PowerTripWireRelay 10 (asm.il:901576); the TE payload carries this byte, not
/// the TriggerTypes one.
pub fn powerItemTypeOf(t: TriggerType) u8 {
    return switch (t) {
        .pressure_plate => 11,
        .trip_wire => 10,
        else => 3,
    };
}

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
    /// Switch / ConsumerToggle: player-latched gate (BlockSwitch meta bit 0x2).
    is_switch: bool = false,
    /// Stock TriggerTypes for the TE payload; null when the block has no
    /// TileEntityPoweredTrigger (generators, relays, plain consumers).
    trigger_type: ?TriggerType = null,
    /// Battery capacity/energy proxies (zdtd power sim, R8): stock battery
    /// energy is per-stack OutputPerCharge when present; these are the
    /// fallback scale and the initial charge fraction when the block only
    /// exposes MaxPower. Copied from the Registry at lookup; the Registry is
    /// synced from `[rules.power]` (battery_capacity_scale /
    /// battery_initial_charge_frac).
    battery_capacity_scale: f32 = 10.0,
    battery_initial_charge_frac: f32 = 0.5,

    /// Fill PowerNode capacity/burn/energy from stock props. watts already on node.
    pub fn applyToNode(self: Resolved, node: *electric.PowerNode) void {
        node.is_trigger = self.is_trigger;
        node.is_switch = self.is_switch;
        if (self.is_trigger) {
            // Idle gate: BFS reaches the plate when wired, but does not flood past
            // until activateTriggerAt sets pulse_left.
            node.on = true;
        }
        if (self.is_switch) {
            // A freshly placed switch has meta 0, so it starts latched off and
            // the client's rendered state and the grid agree from tick one.
            node.on = false;
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
                    self.watts * self.battery_capacity_scale
                else
                    0;
                node.capacity = cap;
                node.fuel_or_energy = cap * self.battery_initial_charge_frac;
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
/// Powered/ElectricWire/TimerRelay/Switch → relay; other powered classes → consumer.
/// A Switch gates the branch below it rather than drawing from it, so it is a
/// relay; ConsumerToggle is a load you can switch off, so it stays a consumer.
/// Class=Light decorative blocks are excluded (no RequiredPower/MaxPower).
pub fn kindFromClass(cls: []const u8) ?electric.NodeKind {
    if (std.mem.eql(u8, cls, "Generator") or std.mem.eql(u8, cls, "SolarPanel"))
        return .generator;
    if (std.mem.eql(u8, cls, "BatteryBank")) return .battery;
    if (std.mem.eql(u8, cls, "Powered") or
        std.mem.eql(u8, cls, "ElectricWire") or
        std.mem.eql(u8, cls, "TimerRelay") or
        std.mem.eql(u8, cls, "Switch"))
        return .relay;
    if (std.mem.eql(u8, cls, "ConsumerToggle")) return .consumer;
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

/// Player-latched gate classes. Kept apart from classIsTrigger: a switch must not
/// fire when a player walks over it, only when they activate the block.
pub fn classIsSwitch(cls: []const u8) bool {
    return std.mem.eql(u8, cls, "Switch") or std.mem.eql(u8, cls, "ConsumerToggle");
}

/// blocks.xml Class → stock TriggerTypes for blocks backed by a
/// TileEntityPoweredTrigger. Everything else has no trigger payload.
pub fn triggerTypeFromClass(cls: []const u8) ?TriggerType {
    if (classIsSwitch(cls)) return .@"switch";
    if (std.mem.eql(u8, cls, "PressurePlate")) return .pressure_plate;
    if (std.mem.eql(u8, cls, "TimerRelay") or std.mem.eql(u8, cls, "Timer")) return .timer_relay;
    if (std.mem.eql(u8, cls, "MotionSensor")) return .motion;
    if (std.mem.eql(u8, cls, "TripWire")) return .trip_wire;
    // Class=Trigger has no dedicated stock TriggerTypes value; treat it as the
    // pressure plate it behaves like rather than inventing a byte.
    if (std.mem.eql(u8, cls, "Trigger")) return .pressure_plate;
    return null;
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
    is_switch: [max_power_entries]bool = undefined,
    trigger_type: [max_power_entries]u8 = undefined,
    n: usize = 0,
    /// Battery fallback proxies, synced from `[rules.power]` at init (the
    /// build() result is copied onto Game.power_registry then adjusted).
    battery_capacity_scale: f32 = 10.0,
    battery_initial_charge_frac: f32 = 0.5,

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
        is_switch: bool,
        trigger_type: ?TriggerType,
    ) void {
        var at = r.n;
        if (r.n == max_power_entries) {
            // Keep the lowest ids when the fixed registry is full. Class rows
            // arrive from a hash map, so keeping the first 256 would make the
            // simulated block set depend on unspecified hash iteration order.
            at = 0;
            var i: usize = 1;
            while (i < r.n) : (i += 1) {
                if (r.ids[i] > r.ids[at]) at = i;
            }
            if (id >= r.ids[at]) return;
        } else {
            r.n += 1;
        }
        r.ids[at] = id;
        r.kinds[at] = kind;
        r.watts[at] = watts;
        r.max_fuel[at] = max_fuel;
        r.output_per_fuel[at] = opf;
        r.output_per_charge[at] = opc;
        r.output_per_stack[at] = ops;
        r.is_trigger[at] = is_trigger;
        r.is_switch[at] = is_switch;
        r.trigger_type[at] = if (trigger_type) |t| @intFromEnum(t) else trigger_type_none;
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
                std.mem.swap(bool, &r.is_switch[j], &r.is_switch[j - 1]);
                std.mem.swap(u8, &r.trigger_type[j], &r.trigger_type[j - 1]);
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
                const name = e.key_ptr.*;
                const cls = e.value_ptr.*;
                const id = table.idByName(name) orelse continue;
                const kind = kindFromClass(cls) orelse blk: {
                    if (table.wattsByName(name) != null) break :blk electric.NodeKind.consumer;
                    continue;
                };
                const p = propsFromTable(table, name);
                r.push(id, kind, p[0], p[1], p[2], p[3], p[4], classIsTrigger(cls), classIsSwitch(cls), triggerTypeFromClass(cls));
            }
            if (r.n > 0) {
                r.sortById();
                return r;
            }
        }
        // Offline fallback: resolve known names if Class map empty. The Class
        // string is spelled out so the trigger/switch columns come from the same
        // mapping the Class-driven scan uses.
        const fallback = [_]struct { []const u8, electric.NodeKind, []const u8 }{
            .{ "generatorbank", .generator, "Generator" },
            .{ "solarbank", .generator, "SolarPanel" },
            .{ "batterybank", .battery, "BatteryBank" },
            .{ "electricwirerelay", .relay, "ElectricWire" },
            .{ "electricfencepost", .relay, "ElectricWire" },
            .{ "electrictimerrelay", .relay, "TimerRelay" },
            .{ "switch", .relay, "Switch" },
            .{ "pressureplate", .consumer, "PressurePlate" },
            .{ "autoTurret", .consumer, "RangedTrap" },
            .{ "dartTrap", .consumer, "RangedTrap" },
            .{ "bladeTrap", .consumer, "RangedTrap" },
        };
        for (fallback) |e| {
            if (r.n >= max_power_entries) break;
            if (table.idByName(e[0])) |id| {
                const p = propsFromTable(table, e[0]);
                r.push(id, e[1], p[0], p[1], p[2], p[3], p[4], classIsTrigger(e[2]), classIsSwitch(e[2]), triggerTypeFromClass(e[2]));
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
                    .is_switch = self.is_switch[i],
                    .trigger_type = if (self.trigger_type[i] == trigger_type_none)
                        null
                    else
                        @enumFromInt(self.trigger_type[i]),
                    .battery_capacity_scale = self.battery_capacity_scale,
                    .battery_initial_charge_frac = self.battery_initial_charge_frac,
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
    try std.testing.expectEqual(electric.NodeKind.relay, kindFromClass("Switch").?);
    try std.testing.expectEqual(electric.NodeKind.consumer, kindFromClass("ConsumerToggle").?);
    try std.testing.expectEqual(@as(?electric.NodeKind, null), kindFromClass("Light"));
}

test "triggerTypeFromClass maps to the stock TriggerTypes byte" {
    try std.testing.expectEqual(TriggerType.@"switch", triggerTypeFromClass("Switch").?);
    try std.testing.expectEqual(TriggerType.@"switch", triggerTypeFromClass("ConsumerToggle").?);
    try std.testing.expectEqual(TriggerType.pressure_plate, triggerTypeFromClass("PressurePlate").?);
    try std.testing.expectEqual(TriggerType.pressure_plate, triggerTypeFromClass("Trigger").?);
    try std.testing.expectEqual(TriggerType.timer_relay, triggerTypeFromClass("TimerRelay").?);
    try std.testing.expectEqual(TriggerType.motion, triggerTypeFromClass("MotionSensor").?);
    try std.testing.expectEqual(TriggerType.trip_wire, triggerTypeFromClass("TripWire").?);
    try std.testing.expectEqual(@as(?TriggerType, null), triggerTypeFromClass("Generator"));
    try std.testing.expectEqual(@as(?TriggerType, null), triggerTypeFromClass("NotAClass"));
    // A switch is a gate, never a step-actuated plate.
    try std.testing.expect(classIsSwitch("Switch"));
    try std.testing.expect(!classIsTrigger("Switch"));
    try std.testing.expect(!classIsSwitch("PressurePlate"));
}

test "registry carries switch columns through the id sort" {
    var stub: StubTable = .{
        .rows = &[_]StubTable.Row{
            .{ .name = "switch", .id = 19300, .watts = 0, .class = "Switch" },
            .{ .name = "pressureplate", .id = 19100, .watts = 1, .class = "PressurePlate" },
            .{ .name = "generatorbank", .id = 19200, .watts = 100, .class = "Generator" },
        },
    };
    try stub.power_class_by_name.put(std.testing.allocator, "switch", "Switch");
    try stub.power_class_by_name.put(std.testing.allocator, "pressureplate", "PressurePlate");
    try stub.power_class_by_name.put(std.testing.allocator, "generatorbank", "Generator");
    defer stub.power_class_by_name.deinit(std.testing.allocator);
    const reg = Registry.build(&stub);
    // sortById hand-swaps every parallel column; a missed one scrambles rows.
    try std.testing.expectEqual(@as(u16, 19100), reg.ids[0]);
    try std.testing.expectEqual(@as(u16, 19300), reg.ids[2]);
    const sw = reg.lookup(19300).?;
    try std.testing.expect(sw.is_switch);
    try std.testing.expect(!sw.is_trigger);
    try std.testing.expectEqual(TriggerType.@"switch", sw.trigger_type.?);
    const plate = reg.lookup(19100).?;
    try std.testing.expect(plate.is_trigger);
    try std.testing.expect(!plate.is_switch);
    try std.testing.expectEqual(TriggerType.pressure_plate, plate.trigger_type.?);
    const gen = reg.lookup(19200).?;
    try std.testing.expectEqual(@as(?TriggerType, null), gen.trigger_type);
    // A placed switch starts latched off so its meta (0) and the grid agree.
    var node: electric.PowerNode = .{ .kind = .relay };
    sw.applyToNode(&node);
    try std.testing.expect(node.is_switch);
    try std.testing.expect(!node.on);
}

test "registry cap selection is independent of insertion order" {
    var ascending: Registry = .{};
    var descending: Registry = .{};
    const input_n = max_power_entries + 32;
    var i: usize = 0;
    while (i < input_n) : (i += 1) {
        const lo: u16 = @intCast(i);
        const hi: u16 = @intCast(input_n - 1 - i);
        ascending.push(lo, .consumer, @floatFromInt(lo), 0, 0, 0, 0, false, false, null);
        descending.push(hi, .consumer, @floatFromInt(hi), 0, 0, 0, 0, false, false, null);
    }
    ascending.sortById();
    descending.sortById();
    try std.testing.expectEqual(max_power_entries, ascending.n);
    try std.testing.expectEqualSlices(u16, ascending.ids[0..ascending.n], descending.ids[0..descending.n]);
    try std.testing.expectEqual(@as(u16, 0), ascending.ids[0]);
    try std.testing.expectEqual(@as(u16, max_power_entries - 1), ascending.ids[ascending.n - 1]);
    for (ascending.ids[0..ascending.n], ascending.watts[0..ascending.n]) |id, watts| {
        try std.testing.expectEqual(@as(f32, @floatFromInt(id)), watts);
    }
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
