//! Fixed tick command buffer: systems/plugins enqueue, drain once per tick.
//! Cap 64; drop when full (no heap, no grow). Soft warn once past ~80%.

const std = @import("std");
const World = @import("world.zig").World;
const NetId = @import("entity.zig").NetId;

pub const max_commands: usize = 64;
/// Soft capacity warning threshold (fraction of max_commands).
pub const warn_ratio: f32 = 0.8;
const warn_at: usize = @intFromFloat(@as(f32, @floatFromInt(max_commands)) * warn_ratio);

pub const Op = union(enum) {
    spawn_zombie: struct { x: f32, y: f32, z: f32, hp: f32 },
    despawn: struct { net_id: NetId },
    damage: struct { net_id: NetId, amount: f32 },
};

pub const DrainResult = struct {
    applied: u32 = 0,
    spawned: u32 = 0,
    despawned: u32 = 0,
    damaged: u32 = 0,
    dropped_before: u32 = 0,
};

pub const Buffer = struct {
    ops: [max_commands]Op = undefined,
    n: usize = 0,
    /// Lifetime drop counter (not cleared on drain).
    dropped: u32 = 0,
    /// Once: soft warning when n crosses warn_at.
    cap_warned: bool = false,

    pub fn push(self: *Buffer, op: Op) bool {
        if (self.n >= max_commands) {
            self.dropped +%= 1;
            return false;
        }
        self.ops[self.n] = op;
        self.n += 1;
        if (!self.cap_warned and self.n >= warn_at) {
            self.cap_warned = true;
            std.debug.print(
                "zdtd: command buffer near capacity n={d}/{d} (warn>={d})\n",
                .{ self.n, max_commands, warn_at },
            );
        }
        return true;
    }

    pub fn clear(self: *Buffer) void {
        self.n = 0;
    }

    pub fn len(self: *const Buffer) usize {
        return self.n;
    }

    /// Apply all queued ops then clear. Safe to call with empty buffer.
    pub fn drain(self: *Buffer, w: *World) DrainResult {
        var r: DrainResult = .{ .dropped_before = self.dropped };
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            switch (self.ops[i]) {
                .spawn_zombie => |z| {
                    if (w.spawnZombie(z.x, z.y, z.z, z.hp) != null) {
                        r.spawned += 1;
                        r.applied += 1;
                    }
                },
                .despawn => |d| {
                    if (w.slotOfNetId(d.net_id)) |s| {
                        w.destroy(s);
                        r.despawned += 1;
                        r.applied += 1;
                    }
                },
                .damage => |d| {
                    if (w.slotOfNetId(d.net_id) != null) {
                        _ = w.damage(d.net_id, d.amount);
                        r.damaged += 1;
                        r.applied += 1;
                    }
                },
            }
        }
        self.n = 0;
        return r;
    }
};

test "command buffer spawn damage despawn" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);

    try std.testing.expect(w.commands.push(.{ .spawn_zombie = .{ .x = 1, .y = 70, .z = 2, .hp = 40 } }));
    const dr = w.commands.drain(&w);
    try std.testing.expectEqual(@as(u32, 1), dr.spawned);
    try std.testing.expectEqual(@as(u32, 1), w.countKind(.zombie));

    const zid = w.next_net_id - 1;
    try std.testing.expect(w.commands.push(.{ .damage = .{ .net_id = zid, .amount = 10 } }));
    _ = w.commands.drain(&w);
    const s = w.slotOfNetId(zid).?;
    try std.testing.expectApproxEqAbs(@as(f32, 30), w.health[s].hp, 0.01);

    try std.testing.expect(w.commands.push(.{ .despawn = .{ .net_id = zid } }));
    const dr2 = w.commands.drain(&w);
    try std.testing.expectEqual(@as(u32, 1), dr2.despawned);
    try std.testing.expect(w.slotOfNetId(zid) == null);
}

test "command buffer drops at cap" {
    var buf: Buffer = .{};
    var i: usize = 0;
    while (i < max_commands) : (i += 1) {
        try std.testing.expect(buf.push(.{ .despawn = .{ .net_id = @intCast(i) } }));
    }
    try std.testing.expect(!buf.push(.{ .despawn = .{ .net_id = 999 } }));
    try std.testing.expectEqual(@as(u32, 1), buf.dropped);
    try std.testing.expectEqual(max_commands, buf.len());
    try std.testing.expect(buf.cap_warned);
    buf.clear();
    try std.testing.expectEqual(@as(usize, 0), buf.len());
}

test "command buffer soft warn at warn_ratio" {
    var buf: Buffer = .{};
    var i: usize = 0;
    while (i < warn_at - 1) : (i += 1) {
        try std.testing.expect(buf.push(.{ .despawn = .{ .net_id = @intCast(i) } }));
        try std.testing.expect(!buf.cap_warned);
    }
    try std.testing.expect(buf.push(.{ .despawn = .{ .net_id = 9000 } }));
    try std.testing.expect(buf.cap_warned);
    try std.testing.expectEqual(warn_at, buf.len());
}
