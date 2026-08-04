//! Dense SoA iteration helpers. No allocation; O(capacity) scans.

const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const max_entities = @import("world.zig").max_entities;
const c = @import("components.zig");
const Kind = c.Kind;
const Mask = c.Mask;
const jobs = @import("jobs.zig");

/// True when every bit set in `require` is also set in `have`.
pub fn maskMatches(have: Mask, require: Mask) bool {
    const h: u32 = @bitCast(have);
    const r: u32 = @bitCast(require);
    return (h & r) == r;
}

/// Call `f(ctx, w, slot)` for every alive entity.
pub fn forEachAlive(
    w: *World,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), *World, Slot) void,
) void {
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        if (!w.alive[i]) continue;
        f(ctx, w, i);
    }
}

/// Alive entities whose mask contains all bits set in `require`.
pub fn forEachWith(
    w: *World,
    require: Mask,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), *World, Slot) void,
) void {
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        if (!w.alive[i]) continue;
        if (!maskMatches(w.mask[i], require)) continue;
        f(ctx, w, i);
    }
}

/// Alive entities of a given Kind (requires mask.kind).
pub fn forEachKind(
    w: *World,
    kind: Kind,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), *World, Slot) void,
) void {
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        if (!w.alive[i]) continue;
        if (!w.mask[i].kind) continue;
        if (w.kind[i] != kind) continue;
        f(ctx, w, i);
    }
}

/// Packed-args each: `fn(ctx, w, slot, packed)` where packed is a struct of
/// column pointers (e.g. `struct { t: *Transform, ai: *ZombieAi }`).
/// Caller fills packed from `w` columns for the slot; this only filters mask.
pub fn each(
    w: *World,
    require: Mask,
    ctx: anytype,
    comptime Packed: type,
    comptime make: fn (*World, Slot) Packed,
    comptime f: fn (@TypeOf(ctx), *World, Slot, Packed) void,
) void {
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        if (!w.alive[i]) continue;
        if (!maskMatches(w.mask[i], require)) continue;
        f(ctx, w, i, make(w, i));
    }
}

/// Kind filter with packed column pointers.
pub fn eachKind(
    w: *World,
    kind: Kind,
    ctx: anytype,
    comptime Packed: type,
    comptime make: fn (*World, Slot) Packed,
    comptime f: fn (@TypeOf(ctx), *World, Slot, Packed) void,
) void {
    var i: Slot = 0;
    while (i < max_entities) : (i += 1) {
        if (!w.alive[i]) continue;
        if (!w.mask[i].kind) continue;
        if (w.kind[i] != kind) continue;
        f(ctx, w, i, make(w, i));
    }
}

/// Chunk-style parallel over kind: range-split slots via jobs/parallel when
/// pool available; else serial. `work` must be thread-safe for disjoint slots.
pub fn forEachParallelKind(
    w: *World,
    kind: Kind,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), *World, Slot) void,
) void {
    const Ctx = struct {
        outer: @TypeOf(ctx),
        world: *World,
        k: Kind,
        fn range(jc: @This(), begin: usize, end: usize) void {
            var i: usize = begin;
            while (i < end) : (i += 1) {
                const s: Slot = @intCast(i);
                if (!jc.world.alive[s]) continue;
                if (!jc.world.mask[s].kind) continue;
                if (jc.world.kind[s] != jc.k) continue;
                f(jc.outer, jc.world, s);
            }
        }
    };
    jobs.forSlotRange(max_entities, Ctx{ .outer = ctx, .world = w, .k = kind }, Ctx.range);
}

const std = @import("std");

test "forEachKind counts zombies" {
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnZombie(0, 70, 0, 40);
    _ = w.spawnZombie(1, 70, 0, 40);
    _ = w.spawnPlayer(0, 70, 0, 0);
    var n: u32 = 0;
    forEachKind(&w, .zombie, &n, struct {
        fn f(ctx: *u32, _: *World, _: Slot) void {
            ctx.* += 1;
        }
    }.f);
    try std.testing.expectEqual(@as(u32, 2), n);
}

test "forEachWith mask predicate" {
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0);
    _ = w.spawnZombie(1, 70, 0, 40);
    var n: u32 = 0;
    const req: Mask = .{ .player = true, .inventory = true };
    forEachWith(&w, req, &n, struct {
        fn f(ctx: *u32, _: *World, _: Slot) void {
            ctx.* += 1;
        }
    }.f);
    try std.testing.expectEqual(@as(u32, 1), n);
}

test "forEachAlive visits all" {
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnZombie(0, 70, 0, 40);
    _ = w.spawnTrader("t", 1, 70, 1);
    var n: u32 = 0;
    forEachAlive(&w, &n, struct {
        fn f(ctx: *u32, _: *World, _: Slot) void {
            ctx.* += 1;
        }
    }.f);
    try std.testing.expectEqual(@as(u32, 2), n);
}

test "maskMatches require subset" {
    const have: Mask = .{ .transform = true, .health = true, .player = true };
    const req: Mask = .{ .transform = true, .health = true };
    try std.testing.expect(maskMatches(have, req));
    try std.testing.expect(!maskMatches(have, .{ .vehicle = true }));
}

test "each packed transform" {
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnZombie(1, 70, 2, 40);
    const Packed = struct { t: *c.Transform };
    var n: u32 = 0;
    each(&w, .{ .transform = true, .zombie_ai = true }, &n, Packed, struct {
        fn make(ww: *World, s: Slot) Packed {
            return .{ .t = &ww.transform[s] };
        }
    }.make, struct {
        fn f(ctx: *u32, _: *World, _: Slot, p: Packed) void {
            ctx.* += 1;
            p.t.x += 1;
        }
    }.f);
    try std.testing.expectEqual(@as(u32, 1), n);
}

test "forEachParallelKind counts zombies" {
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnZombie(0, 70, 0, 40);
    _ = w.spawnZombie(1, 70, 0, 40);
    _ = w.spawnPlayer(0, 70, 0, 0);
    var n: std.atomic.Value(u32) = .init(0);
    forEachParallelKind(&w, .zombie, &n, struct {
        fn f(ctx: *std.atomic.Value(u32), _: *World, _: Slot) void {
            _ = ctx.fetchAdd(1, .monotonic);
        }
    }.f);
    try std.testing.expectEqual(@as(u32, 2), n.load(.monotonic));
}
