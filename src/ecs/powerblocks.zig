//! Stock electrical block registry: maps a runtime AssignIds block id to the
//! PowerGrid NodeKind and watts to register on placement.
//!
//! Each entry's NodeKind is grounded in the block's Class in stock blocks.xml
//! (Data/Config/blocks.xml) and the PowerItem/PowerItemTypes enum
//! (asm.il:892784): Generator/SolarPanel -> .generator; BatteryBank -> .battery;
//! Powered/ElectricWire/TimerRelay (ElectricWireRelay family) -> .relay;
//! everything else (Consumer/Trigger/Timer/RangedTrap/PressurePlate/…) -> .consumer.
//! Plain Class=Light decorative blocks are BlockLight, not BlockPowered, and are
//! intentionally excluded (no wiring in stock).

const std = @import("std");
const electric = @import("electric.zig");

pub const Entry = struct { name: []const u8, kind: electric.NodeKind };

/// Stock electrical blocks whose names/watts are grounded in blocks.xml. Names
/// not present in the loaded AssignIds dump silently resolve to nothing.
pub const stock_power_blocks = [_]Entry{
    // Sources (Class=Generator / SolarPanel, block MaxPower).
    .{ .name = "generatorbank", .kind = .generator },
    .{ .name = "solarbank", .kind = .generator },
    // Storage (Class=BatteryBank).
    .{ .name = "batterybank", .kind = .battery },
    // Relays (Class=Powered / ElectricWire / TimerRelay).
    .{ .name = "electricwirerelay", .kind = .relay },
    .{ .name = "electricfencepost", .kind = .relay },
    .{ .name = "electrictimerrelay", .kind = .relay },
    // Consumers / triggers (RequiredPower drivers; actuation is a documented gap).
    .{ .name = "switch", .kind = .consumer },
    .{ .name = "pressureplate", .kind = .consumer },
    .{ .name = "pressureplateLong", .kind = .consumer },
    .{ .name = "tripwirepost", .kind = .consumer },
    .{ .name = "motionsensor", .kind = .consumer },
    .{ .name = "autoTurret", .kind = .consumer },
    .{ .name = "dartTrap", .kind = .consumer },
    .{ .name = "bladeTrap", .kind = .consumer },
    .{ .name = "mineCandyTin", .kind = .consumer },
    .{ .name = "speaker", .kind = .consumer },
    .{ .name = "spotlightPlayer", .kind = .consumer },
    .{ .name = "ceilingLight01_player", .kind = .consumer },
};

pub const Resolved = struct { kind: electric.NodeKind, watts: f32 };

/// Resolved id -> {kind, watts}, built once at load from the maxdamage Table.
/// Fixed-size; no allocation. Entries whose name is absent from the dump (or
/// whose id drifts across client versions) are skipped, so lookup no-ops rather
/// than mis-registering.
pub const Registry = struct {
    ids: [stock_power_blocks.len]u16 = undefined,
    kinds: [stock_power_blocks.len]electric.NodeKind = undefined,
    watts: [stock_power_blocks.len]f32 = undefined,
    n: usize = 0,

    /// `table` must expose `idByName([]const u8) ?u16` and
    /// `wattsByName([]const u8) ?f32` (the maxdamage.Table shape).
    pub fn build(table: anytype) Registry {
        var r: Registry = .{};
        inline for (stock_power_blocks) |e| {
            if (table.idByName(e.name)) |id| {
                r.ids[r.n] = id;
                r.kinds[r.n] = e.kind;
                r.watts[r.n] = table.wattsByName(e.name) orelse 0;
                r.n += 1;
            }
        }
        return r;
    }

    pub fn lookup(self: *const Registry, block_id: u16) ?Resolved {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (self.ids[i] == block_id) {
                return .{ .kind = self.kinds[i], .watts = self.watts[i] };
            }
        }
        return null;
    }
};

const StubTable = struct {
    const Row = struct { name: []const u8, id: u16, watts: ?f32 };
    rows: []const Row,
    fn idByName(self: *const StubTable, name: []const u8) ?u16 {
        for (self.rows) |r| if (std.mem.eql(u8, r.name, name)) return r.id;
        return null;
    }
    fn wattsByName(self: *const StubTable, name: []const u8) ?f32 {
        for (self.rows) |r| if (std.mem.eql(u8, r.name, name)) return r.watts;
        return null;
    }
};

test "registry maps ids to kind and watts, unknown to null" {
    const stub = StubTable{ .rows = &.{
        .{ .name = "generatorbank", .id = 19186, .watts = 12250 },
        .{ .name = "autoTurret", .id = 19208, .watts = 15 },
        // present name without watts -> honest 0, not invented.
        .{ .name = "batterybank", .id = 19190, .watts = null },
    } };
    const reg = Registry.build(&stub);
    const gen = reg.lookup(19186).?;
    try std.testing.expectEqual(electric.NodeKind.generator, gen.kind);
    try std.testing.expectEqual(@as(f32, 12250), gen.watts);
    const turret = reg.lookup(19208).?;
    try std.testing.expectEqual(electric.NodeKind.consumer, turret.kind);
    try std.testing.expectEqual(@as(f32, 15), turret.watts);
    const bat = reg.lookup(19190).?;
    try std.testing.expectEqual(electric.NodeKind.battery, bat.kind);
    try std.testing.expectEqual(@as(f32, 0), bat.watts);
    try std.testing.expectEqual(@as(?Resolved, null), reg.lookup(12345));
}
