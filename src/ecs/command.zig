//! Fixed tick command buffer: systems/plugins enqueue, drain once per tick.
//! Cap 64; drop when full (no heap, no grow). Soft warn once past ~80%.

const std = @import("std");
const World = @import("world.zig").World;
const NetId = @import("entity.zig").NetId;

pub const max_commands: usize = 64;
/// Soft capacity warning threshold (fraction of max_commands).
pub const warn_ratio: f32 = 0.8;
const warn_at: usize = @trunc(@as(f32, @floatFromInt(max_commands)) * warn_ratio);
/// Glide (ADR 0037) window length in ticks: one `glide <id> 1` keeps the
/// movement-envelope exemption for this long (5 s at 20 TPS); the plugin
/// re-arms while gliding. Bounds a stale flag if a module forgets to clear.
pub const glide_window_ticks: u64 = 100;

pub const Op = union(enum) {
    spawn_zombie: struct { x: f32, y: f32, z: f32, hp: f32 },
    despawn: struct { net_id: NetId },
    damage: struct { net_id: NetId, amount: f32 },
    /// Server chat broadcast (announcements): fixed inline buffer so the op
    /// outlives the guest command buffer; longer text is truncated (fail
    /// closed, never a dangling slice). Routed through World.say_fn (Game
    /// wires it to the stock chat broadcast).
    say: struct { text: [64]u8, len: u8 },
    /// Glide flag (ADR 0037): `glide <net_id> <0|1>` sets/clears the player's
    /// glide window (movement-envelope exemption). Attributed per plugin src
    /// like the other verbs; a withdrawn module's applied glide is cleared.
    glide: struct { net_id: NetId, on: bool },
};

pub const DrainResult = struct {
    applied: u32 = 0,
    spawned: u32 = 0,
    despawned: u32 = 0,
    damaged: u32 = 0,
    said: u32 = 0,
    dropped_before: u32 = 0,
    /// Entities the `despawn` verb destroyed, reported so the net layer can
    /// send EntityRemove: the clients hold the model and nothing else will
    /// mention this entity again. `slots` is the pre-destroy slot, which is
    /// what `known_entities` is keyed on. Saturating like the corpse sweep's
    /// report - past the cap the op still applies, so the cap is sized to the
    /// command buffer rather than guessed.
    despawned_ids: [max_commands]i32 = .{0} ** max_commands,
    despawned_slots: [max_commands]u32 = .{0} ** max_commands,
    despawned_n: u32 = 0,
};

pub const Buffer = struct {
    ops: [max_commands]Op = undefined,
    /// Source attribution per op (0 = native/server; else 1-based wasm plugin
    /// slot). Temporal composability: a disabled plugin's pending ops are
    /// dropped by src before drain (paper).
    srcs: [max_commands]i16 = .{0} ** max_commands,
    n: usize = 0,
    /// Applied spawns attributed per source (paper 3.1 held inverse): the
    /// runtime records the spawned net id per plugin src so a withdrawn
    /// module's entities are despawned on removal, not left behind. Ring
    /// capped at max_commands; when full the oldest attribution is dropped
    /// (documented truncation: the most recent spawns stay revertible).
    spawn_srcs: [max_commands]i16 = .{0} ** max_commands,
    spawn_ids: [max_commands]i32 = .{0} ** max_commands,
    spawn_n: usize = 0,
    /// Ring-truncation counter (not cleared on drain).
    spawn_evicted: u32 = 0,
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
    /// down so drain order is preserved. Also hands back the applied spawns
    /// attributed to `src` (the held inverse, paper 3.1) so the caller can
    /// despawn them; returns the count written to `out`. Used when a plugin
    /// disables so its queued effects never execute and its spawned entities
    /// do not outlive it (temporal composability).
    pub fn dropFrom(self: *Buffer, src: i16, out: []i32) usize {
        if (src == 0) return 0;
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
        var n: usize = 0;
        w = 0;
        for (self.spawn_ids[0..self.spawn_n], 0..) |id, si| {
            if (self.spawn_srcs[si] != src) {
                self.spawn_srcs[w] = self.spawn_srcs[si];
                self.spawn_ids[w] = id;
                w += 1;
                continue;
            }
            if (n < out.len) out[n] = id;
            n += 1;
        }
        self.spawn_n = w;
        return n;
    }

    /// After a plugin slot is dropped and later slots compact, decrement every
    /// remaining src above `dropped` so surviving plugins keep their
    /// attribution (pending ops and the applied-spawn ring). `dropped` is the
    /// 1-based src that just left; src 0 (native) is never shifted.
    pub fn shiftSrcsAfter(self: *Buffer, dropped: i16) void {
        if (dropped <= 0) return;
        for (self.srcs[0..self.n]) |*s| {
            if (s.* > dropped) s.* -= 1;
        }
        for (self.spawn_srcs[0..self.spawn_n]) |*s| {
            if (s.* > dropped) s.* -= 1;
        }
    }

    pub fn clear(self: *Buffer) void {
        self.n = 0;
    }

    /// Record an applied spawn for its source. Ring capped at max_commands:
    /// when full the oldest attribution is dropped so the newest spawns stay
    /// revertible (the guarantee degrades gracefully, never silently).
    fn recordSpawn(self: *Buffer, src: i16, net_id: i32) void {
        if (src == 0) return;
        if (self.spawn_n >= max_commands) {
            std.mem.copyForwards(i16, self.spawn_srcs[0 .. self.spawn_n - 1], self.spawn_srcs[1..self.spawn_n]);
            std.mem.copyForwards(i32, self.spawn_ids[0 .. self.spawn_n - 1], self.spawn_ids[1..self.spawn_n]);
            self.spawn_n -= 1;
            self.spawn_evicted += 1;
        }
        self.spawn_srcs[self.spawn_n] = src;
        self.spawn_ids[self.spawn_n] = net_id;
        self.spawn_n += 1;
    }

    pub fn len(self: *const Buffer) usize {
        return self.n;
    }

    /// Live-source gate for one op during the drain. `fn_` is asked with the
    /// op's 1-based plugin src after every apply, so a module that disabled
    /// itself while an earlier op was being applied (a verdict hook that
    /// trapped) cannot keep executing the ops it queued before that.
    pub const SrcGate = struct {
        ctx: ?*anyopaque = null,
        fn_: ?*const fn (?*anyopaque, i16) bool = null,

        fn withdrew(self: SrcGate, src: i16) bool {
            if (src == 0) return false; // native ops are never withdrawn
            const f = self.fn_ orelse return false;
            return f(self.ctx, src);
        }
    };

    /// Apply the ops queued at entry, then clear them; ops pushed during
    /// drain stay for the next tick. Safe to call with empty buffer.
    /// Profiling: ecs must not import apm (cycle). Callers may time around
    /// drain via apm sections; `applied` / Buffer.dropped counters suffice.
    pub fn drain(self: *Buffer, w: *World) DrainResult {
        return self.drainWith(w, .{});
    }

    /// `drain` with a live per-op source gate (see SrcGate). An op whose source
    /// withdrew during this same drain is skipped and counted as applied
    /// nothing, exactly as if the pre-drain pass had dropped it.
    pub fn drainWith(self: *Buffer, w: *World, gate: SrcGate) DrainResult {
        var r: DrainResult = .{ .dropped_before = self.dropped };
        // Snapshot the count: ops applied below can push more commands.
        // Those stay deferred to the next tick instead of running in this
        // pass or being wiped by the clear.
        const count = self.n;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (gate.withdrew(self.srcs[i])) continue;
            switch (self.ops[i]) {
                .spawn_zombie => |z| {
                    if (w.spawnZombie(z.x, z.y, z.z, z.hp)) |nid| {
                        self.recordSpawn(self.srcs[i], nid);
                        r.spawned += 1;
                        r.applied += 1;
                    }
                },
                .despawn => |d| {
                    if (w.slotOfNetId(d.net_id)) |s| {
                        if (r.despawned_n < r.despawned_ids.len) {
                            r.despawned_ids[r.despawned_n] = d.net_id;
                            r.despawned_slots[r.despawned_n] = s;
                            r.despawned_n += 1;
                        }
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
                .say => |s| {
                    if (w.say_fn) |f| {
                        f(w.say_ctx, s.text[0..s.len]);
                        r.said += 1;
                        r.applied += 1;
                    }
                },
                .glide => |gl| {
                    if (w.slotOfNetId(gl.net_id)) |s| {
                        if (w.mask[s].player) {
                            if (gl.on) {
                                w.player[s].glide_until_tick = w.sim_tick + glide_window_ticks;
                                w.player[s].glide_src = self.srcs[i];
                            } else {
                                w.player[s].glide_until_tick = 0;
                                w.player[s].glide_src = 0;
                            }
                            r.applied += 1;
                        }
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

/// Test double for the mid-drain withdrawal case: `say` stands in for the op
/// whose apply reaches a verdict hook, and flips the disabled flag the gate
/// reads.
const DrainGateCtx = struct {
    withdrawn_src: i16 = 2,
    disabled: bool = false,
    said: u32 = 0,

    fn say(ctx: ?*anyopaque, _: []const u8) void {
        const c: *DrainGateCtx = @ptrCast(@alignCast(ctx.?));
        c.said += 1;
        // The verdict hook trapped on the first op this src produced.
        c.disabled = true;
    }

    fn gate(ctx: ?*anyopaque, src: i16) bool {
        const c: *const DrainGateCtx = @ptrCast(@alignCast(ctx.?));
        return c.disabled and src == c.withdrawn_src;
    }
};

test "a source that disables during the drain stops running its own later ops" {
    // The mid-drain case the pre-drain pass cannot see (ADR 0030): the verdict
    // reached from op 1 traps, so its module is withdrawn while ops 2 and 3
    // (queued before the trap) are still in the snapshot being drained. The
    // gate is asked per op, so only that module's later ops are withheld.
    var ctx: DrainGateCtx = .{};
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    w.say_ctx = &ctx;
    w.say_fn = &DrainGateCtx.say;
    w.op_src_withdrawn_ctx = &ctx;
    w.op_src_withdrawn_fn = &DrainGateCtx.gate;

    try std.testing.expect(w.commands.pushSrc(2, .{ .say = .{ .text = undefined, .len = 0 } }));
    try std.testing.expect(w.commands.pushSrc(2, .{ .say = .{ .text = undefined, .len = 0 } }));
    try std.testing.expect(w.commands.pushSrc(3, .{ .say = .{ .text = undefined, .len = 0 } }));
    const dr = w.drainCommands();
    // src 2's first op ran and disabled it; its second op was withheld; src 3's
    // op still ran, because the gate is per src and not a global stop. `said`
    // counts applied ops, so it is 2 (src 2's first and src 3's), not 3.
    try std.testing.expectEqual(@as(u32, 2), dr.said);
    try std.testing.expectEqual(@as(u32, 2), ctx.said);
}

test "drainWith skips ops whose source withdrew, and nothing else" {
    // Temporal composability (ADR 0030): a module can disable itself while an
    // earlier op is being applied (a verdict hook that traps), and its
    // remaining ops are already in the snapshot the drain is walking. The gate
    // is asked per op, so exactly that src's ops are withheld while native
    // (src 0) and other live sources still apply.
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    var w2: World = .{};
    defer w2.deinit();
    try w2.ensureNetMap(std.testing.allocator);

    const only_two = struct {
        fn f(_: ?*anyopaque, src: i16) bool {
            return src == 2;
        }
    }.f;

    try std.testing.expect(w.commands.pushSrc(0, .{ .spawn_zombie = .{ .x = 1, .y = 70, .z = 1, .hp = 40 } }));
    try std.testing.expect(w.commands.pushSrc(2, .{ .spawn_zombie = .{ .x = 4, .y = 70, .z = 4, .hp = 40 } }));
    try std.testing.expect(w.commands.pushSrc(3, .{ .spawn_zombie = .{ .x = 7, .y = 70, .z = 7, .hp = 40 } }));
    const gated = w.commands.drainWith(&w, .{ .fn_ = &only_two });
    try std.testing.expectEqual(@as(u32, 2), gated.spawned);
    try std.testing.expectEqual(@as(usize, 2), w.countKind(.zombie));

    // src 0 (native) is never withdrawn even if the gate would say so.
    const all_sources = struct {
        fn f(_: ?*anyopaque, _: i16) bool {
            return true;
        }
    }.f;
    try std.testing.expect(w2.commands.pushSrc(0, .{ .spawn_zombie = .{ .x = 1, .y = 70, .z = 1, .hp = 40 } }));
    _ = w2.commands.drainWith(&w2, .{ .fn_ = &all_sources });
    try std.testing.expectEqual(@as(usize, 1), w2.countKind(.zombie));
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
    var out: [max_commands]i32 = undefined;
    _ = buf.pushSrc(0, .{ .damage = .{ .net_id = 1, .amount = 1 } }); // native
    _ = buf.pushSrc(1, .{ .damage = .{ .net_id = 2, .amount = 2 } }); // plugin 1
    _ = buf.pushSrc(1, .{ .damage = .{ .net_id = 3, .amount = 3 } }); // plugin 1
    _ = buf.pushSrc(2, .{ .damage = .{ .net_id = 4, .amount = 4 } }); // plugin 2
    try std.testing.expectEqual(@as(usize, 0), buf.dropFrom(1, &out));
    try std.testing.expectEqual(@as(usize, 2), buf.len());
    try std.testing.expectEqual(@as(i16, 0), buf.srcs[0]);
    try std.testing.expectEqual(@as(i16, 2), buf.srcs[1]);
    // Order preserved: net 1 then net 4.
    try std.testing.expectEqual(@as(i32, 1), buf.ops[0].damage.net_id);
    try std.testing.expectEqual(@as(i32, 4), buf.ops[1].damage.net_id);
    // src 0 (native) is never withdrawable.
    try std.testing.expectEqual(@as(usize, 0), buf.dropFrom(0, &out));
    try std.testing.expectEqual(@as(usize, 2), buf.len());
}

test "dropFrom hands back a plugin's applied spawns (held inverse)" {
    // Paper 3.1: the runtime holds the spawn inverse and replays it on
    // withdrawal, so a disabled module's entities do not outlive it.
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);

    _ = w.commands.pushSrc(1, .{ .spawn_zombie = .{ .x = 1, .y = 70, .z = 2, .hp = 40 } });
    _ = w.commands.pushSrc(2, .{ .spawn_zombie = .{ .x = 3, .y = 70, .z = 4, .hp = 40 } });
    const dr = w.commands.drain(&w);
    try std.testing.expectEqual(@as(u32, 2), dr.spawned);
    try std.testing.expectEqual(@as(u32, 2), w.countKind(.zombie));

    // Withdraw plugin 1: its spawned entity id is returned, plugin 2's is not.
    // The caller (Game withdraw) despawns what dropFrom hands back.
    var out: [max_commands]i32 = undefined;
    const n = w.commands.dropFrom(1, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    if (w.slotOfNetId(out[0])) |es| w.destroy(es);
    try std.testing.expectEqual(@as(u32, 1), w.countKind(.zombie));
    try std.testing.expect(w.slotOfNetId(out[0]) == null);

    // Withdraw plugin 2: the last spawn is returned and despawned.
    const n2 = w.commands.dropFrom(2, &out);
    try std.testing.expectEqual(@as(usize, 1), n2);
    if (w.slotOfNetId(out[0])) |es| w.destroy(es);
    try std.testing.expectEqual(@as(u32, 0), w.countKind(.zombie));
    try std.testing.expect(w.slotOfNetId(out[0]) == null);
}

test "spawn ring truncates oldest attribution at cap" {
    var buf: Buffer = .{};
    // Fill past the ring cap: the newest attribution survives withdrawal.
    for (0..max_commands + 4) |i| {
        buf.recordSpawn(1, @intCast(100 + i));
    }
    try std.testing.expectEqual(@as(u32, 4), buf.spawn_evicted);
    try std.testing.expectEqual(max_commands, buf.spawn_n);
    var out: [max_commands]i32 = undefined;
    const n = buf.dropFrom(1, &out);
    try std.testing.expectEqual(max_commands, n);
    // The oldest 4 are gone; the newest max_commands survive.
    try std.testing.expectEqual(@as(i32, 100 + 4), out[0]);
    try std.testing.expectEqual(@as(i32, 100 + max_commands + 3), out[max_commands - 1]);
}

test "shiftSrcsAfter remaps remaining plugin srcs after a slot drop" {
    // Failed middle-plugin reload compact the slot table; pending ops and
    // the spawn ring must follow so later withdrawal still matches.
    var buf: Buffer = .{};
    _ = buf.pushSrc(1, .{ .damage = .{ .net_id = 1, .amount = 1 } });
    _ = buf.pushSrc(3, .{ .damage = .{ .net_id = 3, .amount = 3 } });
    buf.recordSpawn(3, 30);
    buf.recordSpawn(1, 10);
    buf.shiftSrcsAfter(2);
    try std.testing.expectEqual(@as(i16, 1), buf.srcs[0]);
    try std.testing.expectEqual(@as(i16, 2), buf.srcs[1]);
    try std.testing.expectEqual(@as(i16, 2), buf.spawn_srcs[0]);
    try std.testing.expectEqual(@as(i16, 1), buf.spawn_srcs[1]);
    // Native src 0 is untouched; a non-positive dropped is a no-op.
    _ = buf.pushSrc(0, .{ .damage = .{ .net_id = 9, .amount = 1 } });
    buf.shiftSrcsAfter(0);
    try std.testing.expectEqual(@as(i16, 0), buf.srcs[2]);
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

test "glide op arms and clears the player glide window (ADR 0037)" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const nid = w.spawnPlayer(0, 70, 0, 0) orelse return error.MissingSpawn;
    const s = w.slotOfNetId(nid).?;
    try std.testing.expect(w.mask[s].player);

    // Arm: glide window set + src attributed.
    try std.testing.expect(w.commands.push(.{ .glide = .{ .net_id = nid, .on = true } }));
    _ = w.commands.drain(&w);
    try std.testing.expect(w.player[s].glide_until_tick > w.sim_tick);
    try std.testing.expectEqual(@as(i16, 0), w.player[s].glide_src);

    // Clear.
    try std.testing.expect(w.commands.push(.{ .glide = .{ .net_id = nid, .on = false } }));
    _ = w.commands.drain(&w);
    try std.testing.expectEqual(@as(u64, 0), w.player[s].glide_until_tick);

    // Non-player net id is ignored.
    try std.testing.expect(w.commands.push(.{ .glide = .{ .net_id = 999999, .on = true } }));
    const dr = w.commands.drain(&w);
    try std.testing.expectEqual(@as(u32, 0), dr.applied);
}
