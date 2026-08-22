//! Fixed tick command buffer: systems/plugins enqueue, drain once per tick.
//! Cap 64; drop when full (no heap, no grow). Soft warn once past ~80%.

const std = @import("std");
const World = @import("world.zig").World;
const NetId = @import("entity.zig").NetId;

pub const max_commands: usize = 64;
/// Soft capacity warning threshold (fraction of max_commands).
pub const warn_ratio: f32 = 0.8;
const warn_at: usize = @trunc(@as(f32, @floatFromInt(max_commands)) * warn_ratio);

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
    /// Source attribution per op (0 = native/server; else 1-based wasm plugin
    /// slot). Temporal composability: a disabled plugin's pending ops are
    /// dropped by src before drain (paper).
    srcs: [max_commands]i16 = .{0} ** max_commands,
    n: usize = 0,
    /// Lifetime drop counter (not cleared on drain).
    dropped: u32 = 0,
    /// Once: soft warning when n crosses warn_at.
    cap_warned: bool = false,

    pub fn push(self: *Buffer, op: Op) bool {
        return self.pushSrc(0, op);
    }

    pub fn pushSrc(self: *Buffer, src: i16, op: Op) bool {
        if (self.n >= max_commands) {
            self.dropped +%= 1;
            return false;
        }
        self.ops[self.n] = op;
        self.srcs[self.n] = src;
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

    /// Withdraw (drop) every pending op attributed to `src`; later ops shift
    /// down so drain order is preserved. Used when a plugin disables so its
    /// queued effects never execute (temporal composability).
    pub fn dropFrom(self: *Buffer, src: i16) void {
        if (src == 0) return;
        var w: usize = 0;
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (self.srcs[i] == src) continue;
            if (w != i) {
                self.ops[w] = self.ops[i];
                self.srcs[w] = self.srcs[i];
            }
            w += 1;
        }
        self.n = w;
    }

    pub fn clear(self: *Buffer) void {
        self.n = 0;
    }

    pub fn len(self: *const Buffer) usize {
        return self.n;
    }

    /// Apply the ops queued at entry, then clear them; ops pushed during
    /// drain stay for the next tick. Safe to call with empty buffer.
    /// Profiling: ecs must not import apm (cycle). Callers may time around
    /// drain via apm sections; `applied` / Buffer.dropped counters suffice.
    pub fn drain(self: *Buffer, w: *World) DrainResult {
        var r: DrainResult = .{ .dropped_before = self.dropped };
        // Snapshot the count: ops applied below can push (spawn observers →
        // pushCommand). Those stay deferred to the next tick instead of
        // running in this pass or being wiped by the clear.
        const count = self.n;
        var i: usize = 0;
        while (i < count) : (i += 1) {
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
        const leftover = self.n - count;
        if (leftover > 0) {
            std.mem.copyForwards(Op, self.ops[0..leftover], self.ops[count..self.n]);
            std.mem.copyForwards(i16, self.srcs[0..leftover], self.srcs[count..self.n]);
        }
        self.n = leftover;
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

test "dropFrom withdraws a plugin's pending effects, preserving drain order" {
    // Temporal composability (paper): ops attributed to a disabled plugin are
    // dropped before drain; remaining ops shift down and keep their order.
    var buf: Buffer = .{};
    _ = buf.pushSrc(0, .{ .damage = .{ .net_id = 1, .amount = 1 } }); // native
    _ = buf.pushSrc(1, .{ .damage = .{ .net_id = 2, .amount = 2 } }); // plugin 1
    _ = buf.pushSrc(1, .{ .damage = .{ .net_id = 3, .amount = 3 } }); // plugin 1
    _ = buf.pushSrc(2, .{ .damage = .{ .net_id = 4, .amount = 4 } }); // plugin 2
    buf.dropFrom(1);
    try std.testing.expectEqual(@as(usize, 2), buf.len());
    try std.testing.expectEqual(@as(i16, 0), buf.srcs[0]);
    try std.testing.expectEqual(@as(i16, 2), buf.srcs[1]);
    // Order preserved: net 1 then net 4.
    try std.testing.expectEqual(@as(i32, 1), buf.ops[0].damage.net_id);
    try std.testing.expectEqual(@as(i32, 4), buf.ops[1].damage.net_id);
    // src 0 (native) is never withdrawable.
    buf.dropFrom(0);
    try std.testing.expectEqual(@as(usize, 2), buf.len());
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
