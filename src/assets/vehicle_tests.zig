//! Vehicle catalog tests: HP, velocity, seats.
//!
//! Split out of assets/vehicles.zig (same tests, moved verbatim).

const std = @import("std");
const vehicles = @import("vehicles.zig");
const Def = vehicles.Def;
const Table = vehicles.Table;
const loadFromPath = vehicles.loadFromPath;
const placeableItemName = vehicles.placeableItemName;
const seatCountFromBody = vehicles.seatCountFromBody;
const components = @import("../ecs/components.zig");
const xml = @import("xml_util.zig");
const stock_paths = @import("../util/stock_paths.zig");
const io_fs = @import("../util/io_fs.zig");

test "resolveMaxHp takes the placeable item's DegradationMax" {
    // Vehicle::SetItemValue IL=65: Stats.Health.BaseMax = ItemValue.MaxUseTimes
    // (ItemValue::get_MaxUseTimesBase IL=25 -> DegradationMax = passive 8), so
    // a truck4x4 is 8000 HP, not the offline floor 200.
    const Hooks = struct {
        fn lookup(_: ?*anyopaque, name: []const u8) ?u32 {
            if (std.mem.eql(u8, name, "vehicleTruck4x4Placeable")) return 8000;
            if (std.mem.eql(u8, name, "vehicleBicyclePlaceable")) return 1500;
            return null;
        }
    };
    var defs = [_]Def{
        .{ .name = "vehicleTruck4x4", .kind = .four_by_four },
        .{ .name = "vehicleBicycle", .kind = .bicycle },
        .{ .name = "vehicleUnknown", .kind = .minibike },
    };
    var t: Table = .{ .defs = &defs };
    t.resolveMaxHp(&Hooks.lookup, undefined);
    try std.testing.expectEqual(@as(f32, 8000), defs[0].max_hp);
    try std.testing.expectEqual(@as(f32, 1500), defs[1].max_hp);
    // No item row for the kind keeps the offline floor.
    try std.testing.expectEqual(@as(f32, 200), defs[2].max_hp);
    try std.testing.expectEqualStrings("vehicleGyrocopterPlaceable", placeableItemName(.gyrocopter).?);
}

test "missing velocityMax fails closed to 0" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/vehicles.xml", .{dir});
    const src =
        \\<vehicles>
        \\  <vehicle name="vehicleMinibike">
        \\    <property name="motorTorque_turbo" value="200"/>
        \\  </vehicle>
        \\</vehicles>
    ;
    try io_fs.writeFile(path, src);
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const mb = t.byName("vehicleMinibike").?;
    try std.testing.expectEqual(@as(f32, 0), mb.velocity_max);
    try std.testing.expectEqual(@as(f32, 200), mb.motor_torque);
}

test "load vehicles.xml when present" {
    const p = stock_paths.configFile("vehicles.xml");
    if (!io_fs.fileExists(p)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, p);
    defer t.deinit();
    try std.testing.expect(t.defs.len >= 4);
    const mb = t.byName("vehicleMinibike").?;
    try std.testing.expectEqual(components.VehicleKind.minibike, mb.kind);
    try std.testing.expect(mb.velocity_max > 0);
    try std.testing.expect(t.byKind(.bicycle) != null);
    // fuelTank capacity from vehicles.xml (minibike 40; not the flat 100).
    try std.testing.expectEqual(@as(f32, 40), mb.tank_capacity);
    const gyr = t.byName("vehicleGyrocopter").?;
    try std.testing.expectEqual(@as(f32, 80), gyr.tank_capacity);
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
    const p = stock_paths.configFile("vehicles.xml");
    if (!io_fs.fileExists(p)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, p);
    defer t.deinit();
    // Base (unmodded) seats: Bicycle/Minibike/Motorcycle 1, Gyrocopter 2, Truck4x4 4.
    try std.testing.expectEqual(@as(u8, 1), t.byName("vehicleBicycle").?.seat_count);
    try std.testing.expectEqual(@as(u8, 1), t.byName("vehicleMinibike").?.seat_count);
    try std.testing.expectEqual(@as(u8, 1), t.byName("vehicleMotorcycle").?.seat_count);
    try std.testing.expectEqual(@as(u8, 2), t.byName("vehicleGyrocopter").?.seat_count);
    try std.testing.expectEqual(@as(u8, 4), t.byName("vehicleTruck4x4").?.seat_count);
}
