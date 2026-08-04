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
};

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
    if (std.mem.indexOf(u8, name, "Bicycle") != null) return .bicycle;
    if (std.mem.indexOf(u8, name, "Minibike") != null) return .minibike;
    if (std.mem.indexOf(u8, name, "Motorcycle") != null) return .motorcycle;
    if (std.mem.indexOf(u8, name, "Truck4x4") != null or std.mem.indexOf(u8, name, "4x4") != null) return .four_by_four;
    if (std.mem.indexOf(u8, name, "Gyrocopter") != null) return .gyrocopter;
    return null;
}

/// First float from "a, b, c, d" or single value.
fn firstF32(s: []const u8) f32 {
    const comma = std.mem.indexOfScalar(u8, s, ',') orelse s.len;
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
        const vi = std.mem.indexOfPos(u8, clean, i, "<vehicle ") orelse break;
        const vname = xml.attr(clean, vi, "name") orelse {
            i = vi + 9;
            continue;
        };
        const kind = kindFromName(vname) orelse {
            i = vi + 9;
            continue;
        };
        const gt = std.mem.indexOfPos(u8, clean, vi, ">") orelse break;
        const close = std.mem.indexOfPos(u8, clean, gt, "</vehicle>") orelse break;
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
        if (std.mem.indexOf(u8, body, "fuelKmPerL")) |fi| {
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
