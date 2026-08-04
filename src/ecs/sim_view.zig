//! Narrow mut surface over World for inv/transform (plugin / handler boundary).
//! No heap. Prefer this over raw *World when only these mutators are needed.

const World = @import("world.zig").World;
const NetId = @import("entity.zig").NetId;
const Slot = @import("entity.zig").Slot;
const c = @import("components.zig");
const Kind = c.Kind;
const Transform = c.Transform;
const Health = c.Health;

pub const SimView = struct {
    w: *World,

    pub fn wrap(w: *World) SimView {
        return .{ .w = w };
    }

    pub fn entityExists(self: SimView, net_id: NetId) bool {
        return self.w.slotOfNetId(net_id) != null;
    }

    pub fn slotOf(self: SimView, net_id: NetId) ?Slot {
        return self.w.slotOfNetId(net_id);
    }

    pub fn getTransform(self: SimView, net_id: NetId) ?Transform {
        const s = self.w.slotOfNetId(net_id) orelse return null;
        if (!self.w.mask[s].transform) return null;
        return self.w.transform[s];
    }

    pub fn getHealth(self: SimView, net_id: NetId) ?Health {
        const s = self.w.slotOfNetId(net_id) orelse return null;
        if (!self.w.mask[s].health) return null;
        return self.w.health[s];
    }

    pub fn getKind(self: SimView, net_id: NetId) ?Kind {
        const s = self.w.slotOfNetId(net_id) orelse return null;
        if (!self.w.mask[s].kind) return null;
        return self.w.kind[s];
    }

    pub fn setPos(self: SimView, net_id: NetId, x: f32, y: f32, z: f32, yaw: f32) void {
        self.w.setPos(net_id, x, y, z, yaw);
    }

    /// Add items to entity inventory (toolbelt/bag). Uses catalog stack caps.
    /// False if missing inv or full / stack overflow.
    pub fn addItem(self: SimView, net_id: NetId, item_id: u16, count: u16) bool {
        const s = self.w.slotOfNetId(net_id) orelse return false;
        const ok = self.w.depositItem(s, item_id, count);
        if (ok) self.w.markDirty(s, .{ .inv = true });
        return ok;
    }

    pub fn removeItem(self: SimView, net_id: NetId, item_id: u16, count: u16) bool {
        const s = self.w.slotOfNetId(net_id) orelse return false;
        if (!self.w.mask[s].inventory) return false;
        const ok = self.w.inventory[s].removeItem(item_id, count);
        if (ok) self.w.markDirty(s, .{ .inv = true });
        return ok;
    }

    pub fn countItem(self: SimView, net_id: NetId, item_id: u16) u32 {
        const s = self.w.slotOfNetId(net_id) orelse return 0;
        if (!self.w.mask[s].inventory) return 0;
        return self.w.inventory[s].countItem(item_id);
    }

    pub fn pushCommand(self: SimView, op: @import("command.zig").Op) bool {
        return self.w.pushCommand(op);
    }
};

const std = @import("std");

test "SimView setPos and inv" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    var v = SimView.wrap(&w);
    v.setPos(p, 1, 71, 2, 90);
    const t = v.getTransform(p).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1), t.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 90), t.yaw, 0.001);
    try std.testing.expect(v.addItem(p, 1, 3));
    try std.testing.expectEqual(@as(u32, 3), v.countItem(p, 1));
    try std.testing.expect(v.removeItem(p, 1, 1));
    try std.testing.expectEqual(@as(u32, 2), v.countItem(p, 1));
    try std.testing.expectEqual(Kind.player, v.getKind(p).?);
}
