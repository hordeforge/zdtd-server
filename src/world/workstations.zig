//! World-position keyed workstation state (forge/campfire/workbench TE 12).
//! Slots mirror TileEntityWorkstation arrays; craft tick advances the queue.

const std = @import("std");
const components = @import("../ecs/components.zig");
const stock_te = @import("../wire/stock_te.zig");

pub const max_workstations: usize = 64;
pub const slots_per_group: usize = stock_te.max_ws_slots;

/// Resolves a stock output ItemValue.type to an ECS item id (Game supplies
/// items-table reverse lookup; null in unit tests → outputs skipped).
pub const OutputResolver = *const fn (ctx: ?*anyopaque, stock_type: i32) u16;

pub const Workstation = struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    fuel: [slots_per_group]components.InvSlot = [_]components.InvSlot{.{}} ** slots_per_group,
    input: [slots_per_group]components.InvSlot = [_]components.InvSlot{.{}} ** slots_per_group,
    tools: [slots_per_group]components.InvSlot = [_]components.InvSlot{.{}} ** slots_per_group,
    output: [slots_per_group]components.InvSlot = [_]components.InvSlot{.{}} ** slots_per_group,
    queue: [stock_te.max_ws_queue]stock_te.QueueItem = [_]stock_te.QueueItem{.{}} ** stock_te.max_ws_queue,
    queue_n: usize = 0,
    is_burning: bool = false,
    burn_time_left: f32 = 0,
    /// Set when tick changes state; Game re-broadcasts then clears.
    dirty: bool = false,

    /// Advance burn + craft; completed crafts land in output[] when the
    /// resolver maps the recipe's stock output type to an ECS item.
    pub fn tick(self: *Workstation, dt: f32) void {
        self.tickResolved(dt, null, null);
    }

    pub fn tickResolved(self: *Workstation, dt: f32, resolve: ?OutputResolver, ctx: ?*anyopaque) void {
        if (self.is_burning) {
            self.burn_time_left -= dt;
            if (self.burn_time_left <= 0) {
                // consume one fuel item = 10s burn (ponytail: flat rate; per-item
                // fuel values from items.xml when the loader grows them)
                if (takeOne(&self.fuel)) {
                    self.burn_time_left += 10.0;
                } else {
                    self.is_burning = false;
                    self.burn_time_left = 0;
                    self.dirty = true;
                }
            }
        }
        if (self.queue_n == 0 or !self.is_burning) return;
        var q = &self.queue[0];
        if (!q.is_crafting or q.multiplier <= 0) return;
        q.craft_time_left -= dt;
        if (q.craft_time_left > 0) return;
        q.multiplier -= 1;
        q.craft_time_left = q.one_item_craft_time;
        self.dirty = true;
        // Materialize the crafted item into output slots.
        if (resolve) |rv| {
            if (q.output_type != 0 and q.output_count > 0) {
                const iid = rv(ctx, q.output_type);
                if (iid != 0) addOutput(&self.output, iid, @intCast(@min(q.output_count, 65535)));
            }
        }
        if (q.multiplier <= 0) {
            // shift queue left
            var i: usize = 1;
            while (i < self.queue_n) : (i += 1) self.queue[i - 1] = self.queue[i];
            self.queue_n -= 1;
        }
    }

    fn addOutput(slots: []components.InvSlot, item_id: u16, count: u16) void {
        // stack onto same item first, then first empty; overflow drops (rare)
        for (slots) |*s| {
            if (s.item_id == item_id and s.count > 0) {
                s.count +|= count;
                return;
            }
        }
        for (slots) |*s| {
            if (s.count == 0) {
                s.* = .{ .item_id = item_id, .count = count };
                return;
            }
        }
    }

    fn takeOne(slots: []components.InvSlot) bool {
        for (slots) |*s| {
            if (s.count > 0 and s.item_id != 0) {
                s.count -= 1;
                if (s.count == 0) s.* = .{};
                return true;
            }
        }
        return false;
    }
};

pub const WorkstationStore = struct {
    items: [max_workstations]Workstation = undefined,
    used: [max_workstations]bool = .{false} ** max_workstations,

    pub fn get(self: *WorkstationStore, x: i32, y: i32, z: i32) ?*Workstation {
        for (self.items[0..], self.used[0..]) |*w, u| {
            if (u and w.x == x and w.y == y and w.z == z) return w;
        }
        return null;
    }

    pub fn getOrCreate(self: *WorkstationStore, x: i32, y: i32, z: i32) ?*Workstation {
        if (self.get(x, y, z)) |w| return w;
        for (self.items[0..], self.used[0..], 0..) |*w, u, i| {
            if (u) continue;
            w.* = .{ .x = x, .y = y, .z = z };
            self.used[i] = true;
            return w;
        }
        return null;
    }

    pub fn tickAll(self: *WorkstationStore, dt: f32) void {
        self.tickAllResolved(dt, null, null);
    }

    pub fn tickAllResolved(self: *WorkstationStore, dt: f32, resolve: ?OutputResolver, ctx: ?*anyopaque) void {
        for (self.items[0..], self.used[0..]) |*w, u| {
            if (u) w.tickResolved(dt, resolve, ctx);
        }
    }
};

test "workstation craft tick consumes queue and fuel" {
    var w: Workstation = .{ .is_burning = true, .burn_time_left = 100 };
    w.fuel[0] = .{ .item_id = 7, .count = 2 };
    w.queue[0] = .{ .multiplier = 2, .is_crafting = true, .craft_time_left = 1.0, .one_item_craft_time = 1.0 };
    w.queue_n = 1;
    w.tick(0.5);
    try std.testing.expectEqual(@as(i16, 2), w.queue[0].multiplier);
    w.tick(0.6); // crosses 0 → one crafted
    try std.testing.expectEqual(@as(i16, 1), w.queue[0].multiplier);
    w.tick(1.1); // second crafted, queue empties
    try std.testing.expectEqual(@as(usize, 0), w.queue_n);
    try std.testing.expect(w.dirty);
}

test "workstation craft materializes output via resolver" {
    const R = struct {
        fn rv(ctx: ?*anyopaque, stock_type: i32) u16 {
            _ = ctx;
            return if (stock_type == 70000) 9 else 0;
        }
    };
    var w: Workstation = .{ .is_burning = true, .burn_time_left = 100 };
    w.queue[0] = .{
        .multiplier = 2,
        .is_crafting = true,
        .craft_time_left = 0.4,
        .one_item_craft_time = 0.4,
        .output_type = 70000,
        .output_count = 3,
    };
    w.queue_n = 1;
    w.tickResolved(0.5, R.rv, null); // first craft
    try std.testing.expectEqual(@as(u16, 9), w.output[0].item_id);
    try std.testing.expectEqual(@as(u16, 3), w.output[0].count);
    w.tickResolved(0.5, R.rv, null); // second craft stacks
    try std.testing.expectEqual(@as(u16, 6), w.output[0].count);
    try std.testing.expectEqual(@as(usize, 0), w.queue_n);
}

test "workstation burn consumes fuel then stops" {
    var w: Workstation = .{ .is_burning = true, .burn_time_left = 0.4 };
    w.fuel[0] = .{ .item_id = 7, .count = 1 };
    w.tick(0.5); // burn ends, consumes the one fuel → +10s
    try std.testing.expect(w.is_burning);
    try std.testing.expectEqual(@as(u16, 0), w.fuel[0].count);
    w.burn_time_left = 0.1;
    w.tick(0.2); // no fuel left → stops
    try std.testing.expect(!w.is_burning);
}
