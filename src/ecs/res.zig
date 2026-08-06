//! Typed resource accessors over World fields (P3 ergonomics).
//! Thin aliases: no new storage, no heap. Prefer these over ad-hoc field walks
//! when a system only needs one resource.

const World = @import("world.zig").World;
const electric = @import("electric.zig");
const aidirector = @import("aidirector.zig");
const InvLedger = @import("inv_ledger.zig").Ledger;
const CommandBuffer = @import("command.zig").Buffer;
const PowerGrid = electric.PowerGrid;
const Director = aidirector.Director;

/// Immutable view of a World resource field.
pub fn Res(comptime T: type) type {
    return struct {
        ptr: *const T,
        pub fn get(self: @This()) *const T {
            return self.ptr;
        }
    };
}

/// Mutable view of a World resource field.
pub fn ResMut(comptime T: type) type {
    return struct {
        ptr: *T,
        pub fn get(self: @This()) *T {
            return self.ptr;
        }
    };
}

pub fn power(w: *const World) Res(PowerGrid) {
    return .{ .ptr = &w.power };
}
pub fn powerMut(w: *World) ResMut(PowerGrid) {
    return .{ .ptr = &w.power };
}

pub fn director(w: *const World) Res(Director) {
    return .{ .ptr = &w.director };
}

pub fn invLedger(w: *const World) Res(InvLedger) {
    return .{ .ptr = &w.inv_ledger };
}
pub fn invLedgerMut(w: *World) ResMut(InvLedger) {
    return .{ .ptr = &w.inv_ledger };
}

pub fn commands(w: *const World) Res(CommandBuffer) {
    return .{ .ptr = &w.commands };
}
pub fn commandsMut(w: *World) ResMut(CommandBuffer) {
    return .{ .ptr = &w.commands };
}

const std = @import("std");

test "Res/ResMut power" {
    var w: World = .{};
    try std.testing.expect(power(&w).get() == &w.power);
    try std.testing.expect(powerMut(&w).get() == &w.power);
    try std.testing.expect(director(&w).get() == &w.director);
    try std.testing.expect(invLedger(&w).get() == &w.inv_ledger);
    try std.testing.expect(invLedgerMut(&w).get() == &w.inv_ledger);
    try std.testing.expect(commands(&w).get() == &w.commands);
    try std.testing.expect(commandsMut(&w).get() == &w.commands);
}
