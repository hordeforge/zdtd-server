//! vehicles.xml physical attributes → sim VehicleKind defaults.

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const paths = @import("paths.zig");
const components = @import("../ecs/components.zig");

pub const max_vehicles: usize = 32;

pub const Def = struct {
    name: []const u8 = "",
    kind: components.VehicleKind = .minibike,
    /// Forward velocity max (m/s-ish stock units).
    velocity_max: f32 = 7,
    /// Motor torque forward (stock units).
    motor_torque: f32 = 400,
    /// Max HP when used as entity (from entityclasses if linked; else default).
    max_hp: f32 = 200,
    fuel_km_per_l: f32 = 0.2,
    /// Usable seats without vehicle mods (see seatCountFromBody).
    seat_count: u8 = 1,
};

/// Vehicle::SetSeats walks seat0..seat98 (asm.il:1344168 IL_0085).
const max_seat_scan: usize = 99;

pub const Table = struct {
    defs: []const Def = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn empty() Table {
        return .{};
    }

    pub fn deinit(self: *Table) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = .{};
    }

    pub fn byName(self: *const Table, name: []const u8) ?Def {
        for (self.defs) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    pub fn byKind(self: *const Table, kind: components.VehicleKind) ?Def {
        for (self.defs) |d| {
            if (d.kind == kind) return d;
        }
        return null;
    }
};

fn kindFromName(name: []const u8) ?components.VehicleKind {
    if (std.mem.find(u8, name, "Bicycle") != null) return .bicycle;
    if (std.mem.find(u8, name, "Minibike") != null) return .minibike;
    if (std.mem.find(u8, name, "Motorcycle") != null) return .motorcycle;
    if (std.mem.find(u8, name, "Truck4x4") != null or std.mem.find(u8, name, "4x4") != null) return .four_by_four;
    if (std.mem.find(u8, name, "Gyrocopter") != null) return .gyrocopter;
    return null;
}

/// Contiguous `<property class="seatN">` blocks from N = 0, stopping at the
/// first block that declares a `mod` (Vehicle::SetSeats, asm.il:1344168): the
/// mod budget is EffectManager.GetValue(PassiveEffects::VehicleSeats, ...)
/// (asm.il:733849), which is 0 without an installed seat mod. zdtd has no
/// vehicle mod slots, so the budget stays 0 and only base seats count.
/// A vehicle with no readable seat block falls back to one seat rather than
/// zero, so an unparsable config still yields a rideable vehicle.
fn seatCountFromBody(body: []const u8) u8 {
    var needle_buf: [24]u8 = undefined;
    var n: u8 = 0;
    var i: usize = 0;
    while (i < max_seat_scan and n < components.max_seats) : (i += 1) {
        const needle = std.fmt.bufPrint(&needle_buf, "class=\"seat{d}\"", .{i}) catch break;
        const at = std.mem.find(u8, body, needle) orelse break;
        const rest = at + needle.len;
        // Bound the block by its close tag, or by the next class block when the
        // seat element is self-closing and therefore has no children at all.
        var end = std.mem.findPos(u8, body, rest, "</property>") orelse body.len;
        if (std.mem.findPos(u8, body, rest, "<property class=\"")) |next| {
            if (next < end) end = next;
        }
        if (std.mem.find(u8, body[rest..end], "name=\"mod\"") != null) break;
        n += 1;
    }
    return if (n == 0) 1 else n;
}

/// First float from "a, b, c, d" or single value.
fn firstF32(s: []const u8) f32 {
    const comma = std.mem.findScalar(u8, s, ',') orelse s.len;
    const t = std.mem.trim(u8, s[0..comma], " \t");
    return std.fmt.parseFloat(f32, t) catch 0;
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Table {
    const raw = try io_fs.readFileAll(allocator, path);
    defer allocator.free(raw);
    const clean = try xml.stripComments(allocator, raw);
    defer allocator.free(clean);

    var arena_holder = try allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var list: std.ArrayList(Def) = .empty;
    defer list.deinit(allocator);

    var i: usize = 0;
    while (i < clean.len and list.items.len < max_vehicles) {
        const vi = std.mem.findPos(u8, clean, i, "<vehicle ") orelse break;
        const vname = xml.attr(clean, vi, "name") orelse {
            i = vi + 9;
            continue;
        };
        const kind = kindFromName(vname) orelse {
            i = vi + 9;
            continue;
        };
        const gt = std.mem.findPos(u8, clean, vi, ">") orelse break;
        const close = std.mem.findPos(u8, clean, gt, "</vehicle>") orelse break;
        const body = clean[gt + 1 .. close];

        var vel: f32 = 7;
        var torque: f32 = 400;
        var fuel: f32 = 0.2;
        if (xml.propertyValue(body, "velocityMax_turbo")) |v| {
            const f = firstF32(v);
            if (f > 0) vel = f;
        } else if (xml.propertyValue(body, "velocityMax")) |v| {
            const f = firstF32(v);
            if (f > 0) vel = f;
        }
        if (xml.propertyValue(body, "motorTorque_turbo")) |v| {
            const f = firstF32(v);
            if (f > 0) torque = f;
        }
        // engine fuelKmPerL may be nested; scan body
        if (std.mem.find(u8, body, "fuelKmPerL")) |fi| {
            if (xml.attr(body, fi, "value")) |v| {
                const f = firstF32(v);
                if (f > 0) fuel = f;
            }
        }

        try list.append(allocator, .{
            .name = try arena.dupe(u8, vname),
            .kind = kind,
            .velocity_max = vel,
            .motor_torque = torque,
            .fuel_km_per_l = fuel,
            .max_hp = if (kind == .gyrocopter) 250 else if (kind == .four_by_four) 300 else 200,
            .seat_count = seatCountFromBody(body),
        });
        i = close + 10;
    }

    if (list.items.len == 0) return error.OpenFailed;
    const defs = try arena.alloc(Def, list.items.len);
    @memcpy(defs, list.items);
    return .{ .defs = defs, .arena_ptr = arena_holder };
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?Table {
    return paths.tryLoadConfig("vehicles.xml", Table, loadFromPath, allocator, game_dir, config_dir);
}

test "load vehicles.xml when present" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/vehicles.xml";
    var t = loadFromPath(std.testing.allocator, p) catch return error.SkipZigTest;
    defer t.deinit();
    try std.testing.expect(t.defs.len >= 4);
    const mb = t.byName("vehicleMinibike").?;
    try std.testing.expectEqual(components.VehicleKind.minibike, mb.kind);
    try std.testing.expect(mb.velocity_max > 0);
    try std.testing.expect(t.byKind(.bicycle) != null);
}

test "seat count stops at the first modded seat" {
    // Minibike shape: one base seat, the second needs the seat mod.
    const minibike =
        \\<property class="seat0"><property name="pose" value="20"/></property>
        \\<property class="seat1"><property name="pose" value="21"/><property name="mod" value="seat"/></property>
    ;
    try std.testing.expectEqual(@as(u8, 1), seatCountFromBody(minibike));

    // Truck4x4 shape: four base seats, seat4/seat5 gated behind the seat mod.
    const truck =
        \\<property class="seat0"><property name="pose" value="40"/></property>
        \\<property class="seat1"><property name="pose" value="41"/></property>
        \\<property class="seat2"><property name="pose" value="42"/></property>
        \\<property class="seat3"><property name="pose" value="43"/></property>
        \\<property class="seat4"><property name="mod" value="seat"/></property>
        \\<property class="seat5"><property name="mod" value="seat"/></property>
    ;
    try std.testing.expectEqual(@as(u8, 4), seatCountFromBody(truck));
}

test "seat count edge cases: absent, non contiguous, self closing, over cap" {
    // No seat classes at all: fall back to one rideable seat.
    try std.testing.expectEqual(@as(u8, 1), seatCountFromBody("<property class=\"motor0\"/>"));
    try std.testing.expectEqual(@as(u8, 1), seatCountFromBody(""));

    // Gyrocopter shape: both seats unmodded.
    const gyro =
        \\<property class="seat0"><property name="pose" value="50"/></property>
        \\<property class="seat1"><property name="pose" value="51"/></property>
    ;
    try std.testing.expectEqual(@as(u8, 2), seatCountFromBody(gyro));

    // Contiguity runs from index 0: a lone seat1 counts as nothing.
    try std.testing.expectEqual(@as(u8, 1), seatCountFromBody("<property class=\"seat1\"></property>"));

    // Self-closing seat elements have no children, so a later block's mod
    // property must not leak into them.
    const self_closing =
        \\<property class="seat0"/>
        \\<property class="seat1"/>
        \\<property class="wheel0"><property name="mod" value="plow"/></property>
    ;
    try std.testing.expectEqual(@as(u8, 2), seatCountFromBody(self_closing));

    // seat10 must not satisfy the seat1 needle.
    const ten =
        \\<property class="seat0"></property>
        \\<property class="seat10"></property>
    ;
    try std.testing.expectEqual(@as(u8, 1), seatCountFromBody(ten));

    // More base seats than the ECS can hold clamps at components.max_seats.
    var wide: [512]u8 = undefined;
    var o: usize = 0;
    for (0..components.max_seats + 3) |i| {
        const chunk = try std.fmt.bufPrint(wide[o..], "<property class=\"seat{d}\"></property>", .{i});
        o += chunk.len;
    }
    try std.testing.expectEqual(@as(u8, components.max_seats), seatCountFromBody(wide[0..o]));
}

test "stock vehicles.xml seat counts match Vehicle::SetSeats" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/vehicles.xml";
    var t = loadFromPath(std.testing.allocator, p) catch return error.SkipZigTest;
    defer t.deinit();
    // Base (unmodded) seats: Bicycle/Minibike/Motorcycle 1, Gyrocopter 2, Truck4x4 4.
    try std.testing.expectEqual(@as(u8, 1), t.byName("vehicleBicycle").?.seat_count);
    try std.testing.expectEqual(@as(u8, 1), t.byName("vehicleMinibike").?.seat_count);
    try std.testing.expectEqual(@as(u8, 1), t.byName("vehicleMotorcycle").?.seat_count);
    try std.testing.expectEqual(@as(u8, 2), t.byName("vehicleGyrocopter").?.seat_count);
    try std.testing.expectEqual(@as(u8, 4), t.byName("vehicleTruck4x4").?.seat_count);
}
