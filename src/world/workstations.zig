//! World-position keyed workstation state (forge/campfire/workbench TE 12).
//! Slots mirror TileEntityWorkstation arrays; craft tick advances the queue.
//!
//! Domain types (`QueueItem`, slot/queue caps) live here so `wire/stock_te`
//! can import them without a world → wire cycle. Wire re-exports the same
//! symbols for encode/decode callers.

const std = @import("std");
const components = @import("../ecs/components.zig");

pub const max_workstations: usize = 64;
/// Stock workstation grid width (fuel/input/tools/output array size).
pub const max_ws_slots: usize = 9;
/// Stock RecipeQueueItem array cap on a workstation TE.
pub const max_ws_queue: usize = 4;
pub const slots_per_group: usize = max_ws_slots;

/// Recipe queue cell shared by sim state and TE wire (stock RecipeQueueItem fields).
pub const QueueItem = struct {
    multiplier: i16 = 0,
    is_crafting: bool = false,
    craft_time_left: f32 = 0,
    one_item_craft_time: f32 = 0,
    /// Recipe output ItemValue.type (absolute); 0 = no recipe.
    output_type: i32 = 0,
    output_count: i32 = 0,
    crafting_time: f32 = 0,
};

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
    queue: [max_ws_queue]QueueItem = [_]QueueItem{.{}} ** max_ws_queue,
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
        if (dt <= 0) return;
        // Timers arrive from the client TE write, so they can be non-finite or far
        // negative; the catch-up loops below only terminate promptly when a timer
        // starts within one period of zero.
        if (!std.math.isFinite(self.burn_time_left) or self.burn_time_left < 0) self.burn_time_left = 0;
        if (self.queue_n > 0) {
            const q0 = &self.queue[0];
            if (!std.math.isFinite(q0.craft_time_left) or q0.craft_time_left < 0) q0.craft_time_left = 0;
            if (!std.math.isFinite(q0.one_item_craft_time)) q0.one_item_craft_time = 0;
        }
        if (self.is_burning) {
            self.burn_time_left -= dt;
            while (self.burn_time_left <= 0) {
                // consume one fuel item = 10s burn (ponytail: flat rate; per-item
                // fuel values from items.xml when the loader grows them)
                if (takeOne(&self.fuel)) {
                    self.burn_time_left += 10.0;
                } else {
                    self.is_burning = false;
                    self.burn_time_left = 0;
                    self.dirty = true;
                    break; // burn_time_left == 0 still satisfies the loop guard
                }
            }
        }
        if (self.queue_n == 0 or !self.is_burning) return;
        var q = &self.queue[0];
        if (!q.is_crafting or q.multiplier <= 0) return;
        q.craft_time_left -= dt;
        while (q.craft_time_left <= 0) {
            q.multiplier -= 1;
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
                return;
            }
            if (q.one_item_craft_time <= 0) return;
            q.craft_time_left += q.one_item_craft_time;
        }
    }

    fn addOutput(slots: []components.InvSlot, item_id: u16, count: u16) void {
        var remaining = count;
        for (slots) |*s| {
            if (s.item_id == item_id and s.count > 0) {
                const room = std.math.maxInt(u16) - s.count;
                const added = @min(room, remaining);
                s.count += added;
                remaining -= added;
                if (remaining == 0) return;
            }
        }
        for (slots) |*s| {
            if (s.count == 0) {
                s.* = .{ .item_id = item_id, .count = remaining };
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

test "workstation catches up multiple crafts and fuel units after a delayed tick" {
    var w: Workstation = .{ .is_burning = true, .burn_time_left = 1 };
    w.fuel[0] = .{ .item_id = 7, .count = 3 };
    w.queue[0] = .{ .multiplier = 3, .is_crafting = true, .craft_time_left = 1, .one_item_craft_time = 1 };
    w.queue_n = 1;
    w.tick(21.5);
    try std.testing.expectEqual(@as(u16, 0), w.fuel[0].count);
    try std.testing.expectEqual(@as(usize, 0), w.queue_n);
}

test "client-written timers cannot stall the tick" {
    var w: Workstation = .{ .is_burning = true, .burn_time_left = -1e9 };
    w.fuel[0] = .{ .item_id = 7, .count = 60000 };
    w.queue[0] = .{
        .multiplier = 32767,
        .is_crafting = true,
        .craft_time_left = -std.math.inf(f32),
        .one_item_craft_time = 0,
    };
    w.queue_n = 1;
    w.tick(0.05);
    try std.testing.expect(w.burn_time_left > 0);
    try std.testing.expectEqual(@as(u16, 59999), w.fuel[0].count);
}

test "workstation output overflow continues into an empty slot" {
    const R = struct {
        fn rv(_: ?*anyopaque, _: i32) u16 {
            return 9;
        }
    };
    var w: Workstation = .{ .is_burning = true, .burn_time_left = 100 };
    w.output[0] = .{ .item_id = 9, .count = 65530 };
    w.queue[0] = .{ .multiplier = 1, .is_crafting = true, .craft_time_left = 0, .one_item_craft_time = 1, .output_type = 1, .output_count = 10 };
    w.queue_n = 1;
    w.tickResolved(0.1, R.rv, null);
    try std.testing.expectEqual(@as(u16, 65535), w.output[0].count);
    try std.testing.expectEqual(@as(u16, 5), w.output[1].count);
}
