//! Dense SoA iteration helpers. No allocation; O(capacity) scans.

const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const max_entities = @import("world.zig").max_entities;
const c = @import("components.zig");
const Kind = c.Kind;
const Mask = c.Mask;

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
